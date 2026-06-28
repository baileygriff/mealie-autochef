# Mealie AutoChef — Developer Guide

This guide covers code structure, key abstractions, how to extend the system, and known sharp edges. For the full feature spec and design decisions, see `MEALIE_AUTOMATION_PLAN.md`. For end-user setup and operation, see `docs/USER_GUIDE.md`.

---

## Architecture overview

AutoChef is a **CLI batch job**, not a web app or long-running agent. Each command runs, does its work, and exits. The exception is `main.rb serve`, which runs the Telegram bot (blocking), a Sinatra web form on port 3456 (Puma, background thread), and a rufus-scheduler (background threads) in the same process for the duration of the week.

```
config.yaml / .env
      │
      ▼
main.rb (CLI entrypoint — one cmd_* method per command)
      │
      ├─► MealieClient  ───► Mealie REST API (recipes, foods, shopping lists)
      │
      ├─► Scorer        ───► recipe_stats (SQLite, via ActiveRecord)
      │
      ├─► Planner       ───► cook-day scheduling + perishability ordering
      │
      ├─► LlmPlanner    ───► Anthropic API (claude-haiku-4-5, strict JSON output)
      │
      ├─► Notifier      ───► Telegram bot (approval gate + manual commands)
      │
      ├─► Reminders     ───► rufus-scheduler (thaw + morning-ping jobs)
      │
      ├─► ShoppingListBuilder ► "Next Order" Mealie list (scaled, deduped, staples)
      │
      ├─► LlmQtyConsolidator ► Claude Haiku rationalizes cart qty to pack sizes
      │
      ├─► CartClient    ───► cart_builder/cart.py subprocess (Playwright / Food Lion)
      │
      ├─► Safety        ───► kill switch, spending cap, idempotency key
      │
      └─► FeedbackApplier ──► post-week learning loop
```

**Design principle:** deterministic code owns all data plumbing, scoring, scaling, and safety. Claude is used only for the one step where nuance is hard to encode as rules: arranging the week's meals. A bad LLM response triggers the deterministic fallback — a Claude failure can never break a run.

---

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| Language | Ruby (plain, no Rails) | AR/AM work standalone; this is a CLI batch job, not a web app |
| ORM | ActiveRecord (standalone) | Schema migrations + query DSL without a framework |
| Validation | ActiveModel | Same ergonomics as Rails form objects, zero framework overhead |
| HTTP | httparty | Simple synchronous calls; no async needed for a weekly batch job |
| Database | SQLite (`data/autochef.db`) | Single-file, zero-admin, lives on the Unraid array |
| LLM | Anthropic API (`claude-haiku-4-5-20251001`) | ~$0.03/week; strict JSON output with deterministic fallback |
| Browser automation | Playwright (Python, `cart_builder/cart.py`) | Best official Playwright bindings are Python; isolated to one file |
| Notifications | `telegram-bot-ruby` gem | Push notifications + inline keyboard for the approval flow |
| Scheduling | `rufus-scheduler` (inside `main.rb serve`) | In-container cron; or Unraid User Scripts firing the CLI |

---

## Project structure

```
mealie-autochef/
├── main.rb                        # CLI entrypoint; one cmd_* method per command
├── config.yaml                    # human-editable settings
├── .env / .env.example            # secrets (never commit .env)
│
├── lib/autochef/
│   ├── config.rb                  # loads + validates config.yaml + .env
│   ├── database.rb                # ActiveRecord connection + migration runner
│   ├── mealie_client.rb           # HTTP wrapper over Mealie REST API
│   ├── cart_client.rb             # subprocess bridge to cart_builder/cart.py
│   ├── scoring.rb                 # deterministic preference scorer
│   ├── planner.rb                 # cook-day scheduling + perishability ordering
│   ├── llm_planner.rb             # Claude weekly draft, strict JSON + fallback
│   ├── llm_qty_consolidator.rb    # Claude Haiku: rationalize cart quantities to pack sizes
│   ├── shopping.rb                # list gen, scaling, staples, product map
│   ├── recurring.rb               # cadence-based staple injection
│   ├── notify.rb                  # Telegram bot + approval flow
│   ├── reminders.rb               # thaw / morning-ping rufus-scheduler jobs
│   ├── safety.rb                  # spending cap, kill switch, idempotency
│   ├── feedback.rb                # post-week learning: times_cooked, tag_weights
│   ├── week_prefs_source.rb       # WeekPrefs/DayPrefs structs + source interface
│   ├── sinatra_prefs_source.rb    # DB-backed WeekPrefsSource implementation
│   ├── web/app.rb                 # Sinatra form app — served at :3456/week
│   └── models/
│       ├── recipe_stat.rb
│       ├── tag_weight.rb
│       ├── recurring_item.rb
│       ├── product_map.rb
│       ├── manual_addition.rb
│       ├── plan_history.rb
│       ├── order_history.rb
│       └── week_pref.rb
│
├── db/migrate/                    # 9 migrations (001–009), run by Database.migrate! at startup
│
├── cart_builder/
│   ├── cart.py                    # Playwright Food Lion automation (Python only)
│   └── requirements.txt
│
├── scripts/
│   ├── tag_recipes.rb             # interactive recipe/food tagger
│   └── seed_product_map.rb        # interactive product-map seeder
│
├── spec/
│   ├── spec_helper.rb             # in-memory SQLite, transaction rollback isolation
│   ├── config_spec.rb
│   ├── scoring_spec.rb
│   ├── planner_spec.rb
│   ├── feedback_spec.rb
│   ├── safety_spec.rb
│   └── week_prefs_spec.rb
│
└── docker/
    ├── Dockerfile
    └── docker-compose.yml
```

---

## Database schema

All 9 migrations run at process startup via `Autochef::Database.migrate!`.

### `recipe_stats` (primary key: `recipe_id`)

```sql
CREATE TABLE recipe_stats (
  recipe_id         TEXT    PRIMARY KEY NOT NULL,
  times_planned     INTEGER DEFAULT 0,
  times_cooked      INTEGER DEFAULT 0,
  times_swapped_out INTEGER DEFAULT 0,
  last_planned      DATE,
  last_cooked       DATE,
  avg_rating        REAL,             -- sourced from Mealie (written by sync)
  score             REAL    DEFAULT 0, -- computed by Scorer, cached here
  updated_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

`recipe_id` is Mealie's UUID (stable across recipe renames).
Fields written by `main.rb sync`: `avg_rating`, `last_cooked`.
Fields owned by AutoChef (never overwritten by sync): `times_planned`, `times_cooked`, `times_swapped_out`, `score`.

### `tag_weights` (primary key: `tag`)

```sql
CREATE TABLE tag_weights (
  tag        TEXT  PRIMARY KEY NOT NULL,
  weight     REAL  DEFAULT 0,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

Stores per-tag affinity weights nudged by `FeedbackApplier`. Tags follow the convention `cuisine:italian`, `protein:chicken`, etc.

### `recurring_items`

```sql
CREATE TABLE recurring_items (
  id             INTEGER PRIMARY KEY,
  name           TEXT    NOT NULL,
  product_ref    TEXT,               -- -> product_map.key
  quantity       REAL    DEFAULT 1,
  unit           TEXT,
  cadence_type   TEXT    NOT NULL,   -- 'every_order' | 'every_n_orders' | 'every_n_days'
  cadence_value  INTEGER DEFAULT 1,
  last_added     DATE,
  active         BOOLEAN DEFAULT 1
);
```

### `product_map` (primary key: `key`)

```sql
CREATE TABLE product_map (
  key                  TEXT PRIMARY KEY NOT NULL,  -- normalized mealie food name
  display_name         TEXT,
  search_term          TEXT,                       -- what to search in Food Lion
  preferred_product_id TEXT,                       -- Food Lion/Instacart product ID if known
  pack_size            REAL,
  pack_unit            TEXT,                       -- 'oz' | 'lb' | 'ct'
  default_qty          INTEGER DEFAULT 1,
  rounding             TEXT    DEFAULT 'up',
  substitution_notes   TEXT,
  updated_at           TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### `manual_additions`

```sql
CREATE TABLE manual_additions (
  id        INTEGER  PRIMARY KEY,
  name      TEXT     NOT NULL,
  quantity  REAL     DEFAULT 1,
  unit      TEXT,
  added_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  consumed  BOOLEAN  DEFAULT 0
);
```

Items added via the `/add` bot command. Consumed and cleared by `ShoppingListBuilder`.

### `plan_history`

```sql
CREATE TABLE plan_history (
  id         INTEGER   PRIMARY KEY,
  week_start DATE,
  plan_json  TEXT,     -- {iso_date: {recipe_id, recipe_name, servings, meal_type, rationale}}
  approved   BOOLEAN   DEFAULT 0,
  swaps_json TEXT,     -- {iso_date: [recipe_id, ...]}
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX ON plan_history (week_start);
```

### `week_prefs`

```sql
CREATE TABLE week_prefs (
  id           INTEGER   PRIMARY KEY,
  week_start   DATE      NOT NULL UNIQUE,
  prefs_json   TEXT      NOT NULL,  -- serialized WeekPrefs struct
  created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX ON week_prefs (week_start);
```

Stores per-week plan preferences submitted via the Sinatra form (`/week`). Read by `cmd_plan` and `run_regenerate` in `main.rb` before calling `LlmPlanner`. One row per week (keyed by the Monday date). Overwritten if the form is resubmitted.

### `order_history`

```sql
CREATE TABLE order_history (
  id               INTEGER   PRIMARY KEY,
  week_start       DATE,
  items_json       TEXT,
  est_total        REAL,
  actual_total     REAL,
  status           TEXT,     -- 'cart_built' | 'approved' | 'placed' | 'aborted'
  pickup_slot      TEXT,
  run_key          TEXT,     -- idempotency key: 'autochef-YYYY-MM-DD'
  notes            TEXT,
  feedback_applied BOOLEAN   DEFAULT 0  NOT NULL,
  created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX ON order_history (week_start);
CREATE INDEX ON order_history (run_key);
```

---

## Key abstractions

### `Autochef::Config`

Loads `config.yaml` + `.env` into a tree of `ActiveModel`-validated structs. Raises `ConfigError` at startup if anything is missing or invalid — bad config fails loudly, never silently mid-run.

```ruby
cfg = Autochef::Config.load
cfg.mealie.url               # => "http://mealie:9000"
cfg.safety.dry_run           # => true
cfg.meals.week_layout        # => {:Sun=>"cook", :Mon=>"leftover", ...}  (symbol keys)
cfg.schedule.morning_ping_enabled?  # => false
```

`MEALIE_URL` in `.env` overrides `config.yaml`'s `mealie.url` — useful for local dev outside Docker.

**Note:** `YAML.safe_load_file` is called with `symbolize_names: true`. All config hash keys are symbols throughout the tree — including `week_layout` keys (`:Sun`, not `"Sun"`).

**To add a new config field:** add `attr_reader` + `validates` to the appropriate `ValidatedStruct` subclass in `config.rb`. It raises `ConfigError` on bad data so failures surface at load time, not mid-run.

### `Autochef::Database`

Two class methods, called once at startup in every command:

```ruby
Autochef::Database.connect!   # establishes ActiveRecord connection to data/autochef.db
Autochef::Database.migrate!   # runs any pending migrations in db/migrate/
```

**ActiveRecord 7.2 migration API gotcha:** `ActiveRecord::MigrationContext.new` requires three arguments:

```ruby
ActiveRecord::MigrationContext.new(
  [MIGRATIONS_PATH],
  pool.schema_migration,
  pool.internal_metadata
).migrate
```

The standalone `ActiveRecord::SchemaMigration` constant was removed in AR 7.2. Always use `pool.schema_migration` (where `pool = ActiveRecord::Base.connection_pool`). See `lib/autochef/database.rb` for the exact pattern.

**To add a new migration:** create `db/migrate/NNN_create_<table>.rb` with the next sequential number. `Database.migrate!` picks it up on the next run.

### `Autochef::MealieClient`

Thin HTTP wrapper over Mealie's REST API. Handles pagination transparently.

```ruby
client = Autochef::MealieClient.new(base_url: cfg.mealie.url, api_token: cfg.mealie.api_token)

client.ping                                      # GET /api/app/about (no auth required)
client.recipes                                   # all recipes, all pages
client.eligible_pool("auto-plan")               # client-side filter by tag
client.recipe("uuid-or-slug")                   # full recipe detail
client.add_recipe_tags("slug", ["cuisine:italian"])
client.update_food_extras("food-id", {"shelf_life_days" => 3})
client.find_or_create_shopping_list("Next Order")
client.shopping_list("list-id")
client.trigger_backup                           # POST /api/admin/backups
```

Raises `MealieClient::AuthError` (401), `MealieClient::NotFound` (404), `MealieClient::Error` (other).

**To add a new Mealie API call:** add a public method calling the private `get`, `patch`, or `post` helpers. They handle auth headers, timeout, and error translation.

### `Autochef::Scorer`

```ruby
scorer = Autochef::Scorer.new(cfg)
scorer.update_scores!(recipe_map, nutrition_map: {})
```

Reads from `recipe_stats` and `tag_weights`, computes a composite score for each recipe using the configured weights, and writes `score` back to `recipe_stats`. Formula:

```
score = (avg_rating / 5.0 * weight.rating)
      + (tag_affinity_sum * weight.tag_affinity)
      - (times_swapped_out * weight.swap_penalty)
      - (recency_penalty_value * weight.recency_penalty)
      + (nutrition_fit_value * weight.nutrition_fit)
```

All weights are zero-safe (disabled when set to `0` in config).

### `Autochef::Planner`

```ruby
planner = Autochef::Planner.new(cfg)
week_plan = planner.plan(pool:, scored_ids:, week_start:)

week_plan.assignments  # Array of Assignment objects
week_plan.warnings     # Array of String
```

Assigns recipes to `cook` days for the given week. Sorts the pool by score, then re-orders assignments so more perishable recipes land on earlier cook days. Emits a warning string for any recipe assigned beyond its `shelf_life_days` from the pickup (Sunday) date.

Week is always **Sunday-anchored**. Perishability is measured from Sunday.

### `Autochef::LlmPlanner`

Wraps `Planner` with a Claude Haiku call. Sends the deterministic plan + scored pool to the API and asks Claude to arrange and annotate. Validates the JSON response strictly; falls back to the deterministic plan on any parse failure, schema violation, or API error. A Claude failure can never break a run.

`cmd_plan` and `run_regenerate` in `main.rb` load the current week's `WeekPrefs` from `SinatraPrefsSource` before calling `LlmPlanner` — protein excludes, layout overrides, servings overrides, and the combined note are all applied at that point.

```ruby
llm = Autochef::LlmPlanner.new(cfg, planner: planner)
result = llm.plan(pool:, scored_ids:, freeform_note: nil, recent_plans: [])

result.week_plan     # WeekPlan
result.via_llm       # true | false
result.llm_error     # String | nil (set on fallback)
```

### `Autochef::WeekPrefsSource` / `Autochef::SinatraPrefsSource`

`WeekPrefsSource` is the interface (two methods: `prefs_for(week_start)` and `save(week_start, prefs)`). `SinatraPrefsSource` is the DB-backed implementation backed by the `week_prefs` table.

`WeekPrefs` and `DayPrefs` are plain structs (defined in `week_prefs_source.rb`):

```ruby
WeekPrefs = Struct.new(
  :protein_excludes,   # Array<String> — e.g. ["seafood", "beef"]
  :day_overrides,      # Hash<String, DayPrefs> — keyed by ISO date
  :note,               # String | nil — freeform guidance appended to LLM prompt
  keyword_init: true
)

DayPrefs = Struct.new(
  :meal_type,          # "cook" | "leftover" | "skip" | nil (use config default)
  :dinner_servings,    # Integer | nil
  :lunch_servings,     # Integer | nil
  :vibe,               # "normal" | "treat" | nil
  :notes,              # String | nil
  keyword_init: true
)
```

The Sinatra form at `http://<host>:3456/week` is the only write path — no CLI command writes `week_prefs` directly.

### `Autochef::Notifier`

Telegram bot (blocking long-poll loop via `run_bot`) plus one-shot notification methods called from `main.rb` and `reminders.rb`.

**Public notification methods (called externally):**

| Method | Called from |
|---|---|
| `Notifier.send_crash_alert(cfg, cmd, error)` | `main.rb cmd_plan` rescue block |
| `send_draft(plan_history_id:, note:)` | `main.rb cmd_plan` |
| `send_cart_ready(result, dry_run:, deviation_warning:, skipped_items:)` | `main.rb cmd_build_cart` |
| `send_cart_aborted(reason)` | `main.rb cmd_build_cart` |
| `send_thaw_reminder(date:, recipe_name:)` | `lib/autochef/reminders.rb` |
| `send_morning_ping(date:, recipe_name:)` | `lib/autochef/reminders.rb` |

`send_crash_alert` is a class method using a one-shot Telegram POST (no polling loop). It swallows its own errors so an alert failure never masks the original exception.

Private methods (internal bot callbacks, plan building, etc.) are behind the `private` keyword.

**Telegram Markdown v1 constraint:** `send_cart_ready` uses `parse_mode: 'Markdown'`. Markdown v1 does not support nested formatting. Do not use underscores in URLs inside `[text](url)` links — they break the parser. The cart URL uses `https://www.foodlion.com/shop` (no underscores) deliberately. Screenshots are sent as a separate `send_photo` call rather than embedding the path as text.

### `Autochef::Safety`

```ruby
safety = Autochef::Safety.new(cfg)

safety.check_kill_switch!          # raises KillSwitchError if data/PAUSE exists
safety.check_idempotency!(run_key) # raises IdempotencyError if cart already built this week
safety.check_spending_cap!(total)  # raises SpendingCapError if total > cap; nil → skip
safety.deviation_warning(est, actual) # returns String | nil
safety.idempotency_key(week_start) # => "autochef-YYYY-MM-DD"
```

The kill switch check is the **first** thing in every ordering flow. Do not reorder.

### `Autochef::CartClient`

```ruby
result = Autochef::CartClient.build_cart(input_hash)
# => {"status" => "cart_built", "cart_total" => 87.40, "flagged_items" => [], ...}
```

Shells out to `cart_builder/cart.py` as a subprocess. Passes `input_hash` as JSON on stdin, reads JSON from stdout. The Python interpreter path comes from `ENV['CART_BUILDER_PYTHON']` (default: `python3`). Raises `CartClient::CartBuilderError` on non-zero exit.

See `cart_builder/cart.py`'s module docstring for the full `INPUT_SCHEMA` and `OUTPUT_SCHEMA`.

### `Autochef::FeedbackApplier`

```ruby
applier = Autochef::FeedbackApplier.new(mealie_client: client_or_nil)
result  = applier.apply(order_history_record, force: false)

result.already_applied  # true if skipped (idempotency)
result.cooked_count     # number of recipes updated
result.tag_updates      # number of tag_weight rows nudged
```

Idempotent: checks `order_history.feedback_applied` before running. Pass `force: true` to re-apply.

---

## Data flow

```
Mealie recipes + ratings + foods
        │
        │  MealieClient.eligible_pool + MealieClient.recipe (for shelf_life/nutrition)
        ▼
recipe pool (in-memory array of recipe hashes)
        │
        │  Scorer.update_scores! — reads recipe_stats, tag_weights → writes score
        ▼
scored_pool (scored_ids hash: recipe_id => Float)
        │
        │  SinatraPrefsSource.prefs_for(week_start) — protein excludes, layout overrides,
        │  servings, freeform note (submitted via /week form; no-op if form not used)
        │
        │  Planner.plan — cook-day assignment, perishability ordering, warnings
        ▼
WeekPlan (assignments, warnings)
        │
        │  LlmPlanner — Claude Haiku arranges + annotates; falls back to WeekPlan on failure
        ▼
annotated WeekPlan + PlanHistory saved to DB (approved: false)
        │
        │  Notifier.send_draft — Telegram inline keyboard sent to Bailey
        ▼
Bailey approves (or swaps/regenerates)
        │  (Notifier.run_bot handles callbacks, updates PlanHistory.approved = true)
        ▼
approved PlanHistory
        │
        │  ShoppingListBuilder.build_and_push
        │  — scales servings, resolves product_map, injects recurring staples
        │  — pushes items to Mealie "Next Order" list (autochef_managed: true extra)
        ▼
Mealie "Next Order" list
        │
        │  CartClient.build_cart → cart.py subprocess (Playwright)
        │  — Safety checks: kill switch, idempotency, spending cap
        ▼
cart_built OrderHistory + Telegram cart-ready notification
        │
Bailey reviews cart + taps checkout (manual step)
        │
        │  FeedbackApplier.apply (run manually after pickup)
        ▼
recipe_stats updated (times_cooked, last_cooked)
tag_weights nudged (cuisine/protein tags from kept plan)
```

---

## Ruby ↔ Python IPC contract

Ruby calls `cart_builder/cart.py` as a subprocess via `Open3.capture3`.

**Input (Ruby → Python, JSON on stdin):**

```json
{
  "run_key": "autochef-2026-06-28",
  "store_name": "Food Lion - City, State",
  "pickup_window_pref": "Sun 10:00-12:00",
  "spending_cap_usd": 150.0,
  "cart_deviation_alert_pct": 20.0,
  "dry_run": true,
  "items": [
    {"search_term": "boneless chicken thighs", "default_qty": 2, "pack_unit": "lb"}
  ]
}
```

**Output (Python → Ruby, JSON on stdout only — all logs go to stderr):**

```json
{
  "status": "cart_built",
  "abort_reason": null,
  "est_total": 87.40,
  "cart_total": 87.40,
  "pickup_slot": "Sun 10:00 AM - 12:00 PM",
  "flagged_items": ["saffron"],
  "screenshot_path": "data/cart_screenshots/autochef-2026-06-28.png",
  "cart_url": "https://www.foodlion.com/shop/cart"
}
```

**Exit codes:** `0` = ran to completion (check `status` field). Non-zero = unexpected crash; Ruby treats this as a hard failure and raises `CartClient::CartBuilderError`.

**`est_total`:** `cart.py` sets `est_total = cart_total` in its output (both come from the same cart summary page). This populates `order_history.est_total` and allows `deviation_warning` to run; deviation will always be 0% since both values are the same source. A meaningful pre-build estimate (e.g. last week's total) could be wired in later without changing the contract.

---

## Recipe tag conventions

Tags are free-form in Mealie. AutoChef uses these conventions:

| Prefix | Examples | Used for |
|---|---|---|
| `cuisine:` | `cuisine:italian`, `cuisine:asian` | Variety cap (`max_same_cuisine_per_week`) |
| `protein:` | `protein:chicken`, `protein:beef` | Protein diversity + nutrition scoring |
| `effort:` | `effort:quick`, `effort:project` | Avoids back-to-back project meals |
| (none) | `auto-plan`, `makes-leftovers` | Pool eligibility, leftover scheduling |

To add a new convention: update `scripts/tag_recipes.rb` to prompt for it, and handle it in `scoring.rb` or `planner.rb` as needed.

---

## How to extend

### Add a new scoring signal

1. Add a column to `recipe_stats` (new migration `db/migrate/NNN_...rb`)
2. Populate it in `main.rb sync` or `main.rb plan`'s `resolve_nutrition` helper
3. Add a weight key to `config.yaml` under `selection.scoring_weights`
4. Add the attr_reader + validates line to `ScoringWeights` in `config.rb`
5. Include it in `scoring.rb`'s formula

### Add a new Mealie API method

Add a public method to `MealieClient` using the private `get`, `patch`, or `post` helpers:

```ruby
def shopping_lists
  paginate("/api/households/shopping/lists")
end
```

### Add a new recurring staple cadence type

Add a row to `recurring_items` with `cadence_type` of `every_order`, `every_n_orders`, or `every_n_days` and the appropriate `cadence_value`. `Recurring` reads these every time `shop` runs.

### Add a new bot command

1. Add a `when '/mycommand'` branch in `Notifier`'s private `handle_update` method
2. Add a private `cmd_mycommand` method with the implementation
3. Update `USER_GUIDE.md`'s bot commands table

---

## Local development

### Prerequisites

- Ruby 3.2+ and Bundler
- Python 3.11+ and pip (only for `cart_builder/` work)
- SQLite3

### Setup

```bash
bundle install

# Python side (only needed for cart_builder/ work)
python3 -m venv .venv
source .venv/bin/activate
pip install -r cart_builder/requirements.txt
playwright install --with-deps chromium
deactivate
```

### Connecting to Mealie outside Docker

```
MEALIE_URL=http://localhost:9000   # add to .env
```

### Running tests

```bash
bundle exec rspec
# → 44 examples, 0 failures
```

Tests use in-memory SQLite (`:memory:`) and wrap each example in a transaction that rolls back — no `data/autochef.db` is touched. `spec/spec_helper.rb` runs all 9 migrations against the in-memory DB at suite startup.

### Inspecting the database

```bash
sqlite3 data/autochef.db
.tables
SELECT * FROM recipe_stats LIMIT 10;
SELECT * FROM order_history ORDER BY created_at DESC LIMIT 5;
```

---

## Known-fragile areas

- **Cart builder** (`cart_builder/cart.py`) automates a consumer website not built for automation. Expect selector rot when Food Lion ships UI changes. The `SELECTOR MAINTENANCE` section in `cart.py` documents the recovery procedure (Playwright Codegen). Keep `dry_run: true` and manual checkout as permanent defaults.
- **`SEL_CART_ITEM_REMOVE` selectors** — confirmed working as of 2026-06-28 (cleared 27–60 items on live runs, including `SEL_CART_ITEM_REMOVE_CONFIRM` for the OK dialog). If selectors break after a Food Lion UI update, use Playwright Codegen to find the new remove-button selector.
- **Product map key matching** — `main.rb`'s `resolve_cart_item` looks up `product_map` by `item['note']` (the Mealie shopping list item's display text). `seed_product_map.rb` keys entries by the same `note` text fetched from the live "Next Order" list, so they agree for standard use. The edge case: if a `ProductMap` record has a `display_name` override set, `push_ingredient` will write that override as the Mealie item `note`, which then won't match the product map's `food_name`-based key. Avoid setting `display_name` unless you also update the `key` to match.
- **`est_total` baseline** — `cart.py` sets `est_total = cart_total` (same source). Deviation warning runs but always shows 0%. A real estimate (e.g. previous week's actual) would require additional wiring on the Ruby side.
- **LLM output** — always JSON-validated with a deterministic fallback. A bad model response can never break a run; at worst it adds a `llm_error` note to the plan output.

## `cmd_build_cart` pipeline (main.rb)

The full item resolution and consolidation pipeline inside `cmd_build_cart`:

```
Mealie "Next Order" listItems (raw)
        │
        │  resolve_cart_item(item)
        │  — looks up product_map by item['note']
        │  — returns nil for __skip__ entries (pantry items) → filter_map drops them
        │  — returns {search_term, default_qty, pack_unit} for mapped items
        │  — falls back to raw item name + Mealie quantity for unmapped items
        ▼
cart_items (resolved)
        │
        │  group_by(:search_term) → sum default_qty per term (Enhancement 1)
        │  — consolidates duplicate terms from multiple recipes
        │  — attaches 'sources' (ingredient names) for LLM context
        ▼
cart_items (consolidated by search_term)
        │
        │  LlmQtyConsolidator.consolidate (Enhancement 2, when llm.enabled)
        │  — Claude Haiku rationalizes quantities for grocery pack sizes
        │  — 2 lemons → 1, 5 garlic cloves → 1 head, 3 cups broth → 1 carton, etc.
        │  — 'sources' field stripped before sending to cart.py
        ▼
cart_items (pack-size rationalized)
        │
        │  CartClient.build_cart(input) → cart.py subprocess
        │  — clear_cart() runs first, removing all prior items
        │  — adds each item via Food Lion search → "Add to cart" click
        ▼
OrderHistory saved + Telegram cart-ready notification
```
