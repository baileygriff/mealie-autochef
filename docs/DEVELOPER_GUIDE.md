# Mealie AutoChef — Developer Guide

This guide covers code structure, key abstractions, how to extend the system, and known sharp edges. For the full feature spec and design decisions, see `MEALIE_AUTOMATION_PLAN.md`. For end-user setup and operation, see `docs/USER_GUIDE.md`.

---

## Architecture overview

AutoChef is a **CLI batch job**, not a web app or long-running agent. Each command runs, does its work, and exits. The exception is `main.rb serve`, which runs the Telegram bot (blocking) and a rufus-scheduler (background threads) in the same process for the duration of the week.

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
│   ├── shopping.rb                # list gen, scaling, staples, product map
│   ├── recurring.rb               # cadence-based staple injection
│   ├── notify.rb                  # Telegram bot + approval flow
│   ├── reminders.rb               # thaw / morning-ping rufus-scheduler jobs
│   ├── safety.rb                  # spending cap, kill switch, idempotency
│   ├── feedback.rb                # post-week learning: times_cooked, tag_weights
│   └── models/
│       ├── recipe_stat.rb
│       ├── tag_weight.rb
│       ├── recurring_item.rb
│       ├── product_map.rb
│       ├── manual_addition.rb
│       ├── plan_history.rb
│       └── order_history.rb
│
├── db/migrate/                    # 8 migrations, run by Database.migrate! at startup
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
│   └── safety_spec.rb
│
└── docker/
    ├── Dockerfile
    └── docker-compose.yml
```

---

## Database schema

All 8 migrations run at process startup via `Autochef::Database.migrate!`.

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

```ruby
llm = Autochef::LlmPlanner.new(cfg, planner: planner)
result = llm.plan(pool:, scored_ids:, freeform_note: nil, recent_plans: [])

result.week_plan     # WeekPlan
result.via_llm       # true | false
result.llm_error     # String | nil (set on fallback)
```

### `Autochef::Notifier`

Telegram bot (blocking long-poll loop via `run_bot`) plus one-shot notification methods called from `main.rb` and `reminders.rb`.

**Public notification methods (called externally):**

| Method | Called from |
|---|---|
| `send_draft(plan_history_id:)` | `main.rb cmd_plan` |
| `send_cart_ready(result, dry_run:, deviation_warning:)` | `main.rb cmd_build_cart` |
| `send_cart_aborted(reason)` | `main.rb cmd_build_cart` |
| `send_thaw_reminder(date:, recipe_name:)` | `lib/autochef/reminders.rb` |
| `send_morning_ping(date:, recipe_name:)` | `lib/autochef/reminders.rb` |

Private methods (internal bot callbacks, plan building, etc.) are behind the `private` keyword.

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
  "est_total": null,
  "cart_total": 87.40,
  "pickup_slot": "Sun 10:00 AM - 12:00 PM",
  "flagged_items": ["saffron"],
  "screenshot_path": "data/cart_screenshots/autochef-2026-06-28.png",
  "cart_url": "https://www.foodlion.com/shop/cart"
}
```

**Exit codes:** `0` = ran to completion (check `status` field). Non-zero = unexpected crash; Ruby treats this as a hard failure and raises `CartClient::CartBuilderError`.

**Known limitation:** `est_total` is never populated in the current `cart.py` implementation (`run_build_cart` calls `make_output` without computing a pre-cart estimate). The `deviation_warning` check in `safety.rb` always receives `nil` for `est_total` and therefore never fires.

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
# → 34 examples, 0 failures
```

Tests use in-memory SQLite (`:memory:`) and wrap each example in a transaction that rolls back — no `data/autochef.db` is touched. `spec/spec_helper.rb` runs all 8 migrations against the in-memory DB at suite startup.

### Inspecting the database

```bash
sqlite3 data/autochef.db
.tables
SELECT * FROM recipe_stats LIMIT 10;
SELECT * FROM order_history ORDER BY created_at DESC LIMIT 5;
```

---

## Known-fragile areas

- **Cart builder** (`cart_builder/cart.py`) automates a consumer website not built for automation. Expect selector rot when Food Lion / Instacart ships UI changes. The `SELECTOR MAINTENANCE` section in `cart.py` documents the recovery procedure (Playwright Codegen). Keep `dry_run: true` and manual checkout as permanent defaults.
- **Product map key matching** — `main.rb`'s `resolve_cart_item` looks up `product_map` by `item['note']` (Mealie display_name), but `product_map.key` is indexed by food_name (as seeded by `seed_product_map.rb`). When display_name ≠ food_name the lookup silently falls back to the raw item name. This surfaces as an "unmapped" warning even when the product is in the map.
- **`est_total` never populated** — `cart.py`'s `run_build_cart` doesn't compute a pre-cart estimate, so `safety.deviation_warning` always receives `nil` and never fires.
- **LLM output** — always JSON-validated with a deterministic fallback. A bad model response can never break a run; at worst it adds a `llm_error` note to the plan output.
