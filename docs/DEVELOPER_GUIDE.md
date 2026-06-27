# Mealie AutoChef — Developer Guide

This guide covers the code structure, key abstractions, and how to extend the system. For the feature spec and build plan, see `MEALIE_AUTOMATION_PLAN.md`. For end-user setup and operation, see `docs/USER_GUIDE.md`.

---

## Architecture overview

AutoChef is a **CLI batch job**, not a web app or long-running agent. Each command (`main.rb plan`, `main.rb sync`, etc.) runs, does its work, and exits. A scheduler (rufus-scheduler inside Docker, or Unraid cron) fires the commands on a weekly cadence.

```
config.yaml / .env
      │
      ▼
main.rb (CLI entrypoint)
      │
      ├─► MealieClient  ───► Mealie REST API (recipes, foods, shopping lists)
      │
      ├─► Scorer        ───► recipe_stats (SQLite, via ActiveRecord)
      │
      ├─► Planner       ───► cook-day scheduling + perishability ordering
      │
      ├─► LLMPlanner    ───► Anthropic API (claude-haiku-4-5, JSON output)
      │
      ├─► Notify        ───► Telegram bot (approval gate + manual commands)
      │
      ├─► Shopping      ───► "Next Order" Mealie list (scaled, deduped, staples added)
      │
      └─► CartClient    ───► cart_builder/cart.py subprocess (Playwright / Food Lion)
```

**Design principle:** deterministic code owns all data plumbing, scoring, scaling, and safety. The LLM is used only for the one step where nuance is hard to encode as rules: arranging the week's meals.

---

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| Language | Ruby (plain, no Rails) | AR/AM work standalone; this is a CLI batch job, not a web app |
| ORM | ActiveRecord (standalone) | Schema migrations + query DSL without a framework |
| Validation | ActiveModel | Same ergonomics as Rails form objects, zero overhead |
| HTTP | httparty | Simple synchronous calls; no async needed for a weekly batch job |
| Database | SQLite (`data/autochef.db`) | Single-file, zero-admin, lives on the Unraid array |
| LLM | Anthropic API (`claude-haiku-4-5`) | ~$0.03/week; strict JSON output with deterministic fallback |
| Browser automation | Playwright (Python, `cart_builder/cart.py`) | Best official Playwright bindings are Python; isolated to one file |
| Notifications | Telegram bot (`telegram-bot-ruby`) | Push notifications + inline keyboard for approval flow |
| Scheduling | rufus-scheduler (Phase 6) | In-container cron; or Unraid User Scripts firing the CLI |

**The Ruby/Python boundary** is exactly one file pair: `lib/autochef/cart_client.rb` shells out to `cart_builder/cart.py` as a subprocess and parses JSON from stdout. Everything else is Ruby. See `cart_client.rb`'s comments and `cart.py`'s docstring for the IPC contract.

---

## Project structure

```
mealie-autochef/
├── main.rb                        # CLI entrypoint; one cmd_* method per command
├── config.yaml                    # human-editable settings (see Config reference)
├── .env / .env.example            # secrets (never commit .env)
│
├── lib/autochef/
│   ├── config.rb                  # loads + validates config.yaml + .env
│   ├── database.rb                # ActiveRecord connection + migration runner
│   ├── mealie_client.rb           # HTTP wrapper over Mealie REST API   ← Phase 1
│   ├── cart_client.rb             # subprocess bridge to cart_builder/cart.py
│   ├── scoring.rb                 # deterministic preference scorer      ← Phase 2
│   ├── planner.rb                 # cook-day scheduling + perishability  ← Phase 2
│   ├── llm_planner.rb             # Claude weekly draft, strict JSON     ← Phase 2
│   ├── shopping.rb                # list gen, scaling, staples, product map ← Phase 4
│   ├── recurring.rb               # cadence injection                    ← Phase 4
│   ├── notify.rb                  # Telegram bot + approval flow         ← Phase 3
│   ├── reminders.rb               # thaw / night-before nudges           ← Phase 6
│   └── safety.rb                  # cap, kill switch, idempotency        ← Phase 5
│   └── models/
│       ├── recipe_stat.rb         # per-recipe planning history + score
│       ├── tag_weight.rb          # per-tag affinity weight
│       ├── recurring_item.rb      # staple cadences
│       ├── product_map.rb         # ingredient → Food Lion product mapping
│       ├── manual_addition.rb     # one-off additions from the bot
│       ├── plan_history.rb        # weekly plan archive
│       └── order_history.rb       # order archive + idempotency keys
│
├── db/migrate/
│   └── 001_create_recipe_stats.rb … 007_create_order_history.rb
│
├── cart_builder/
│   ├── cart.py                    # Playwright Food Lion automation (Python only)
│   └── requirements.txt
│
├── scripts/
│   ├── tag_recipes.rb             # interactive recipe/food tagger       ← Phase 1
│   └── seed_product_map.rb        # interactive product-map seeder       ← Phase 4
│
├── docs/
│   ├── USER_GUIDE.md
│   └── DEVELOPER_GUIDE.md         # ← you are here
│
└── docker/
    ├── Dockerfile
    └── docker-compose.yml
```

Items marked `← Phase N` are either implemented at that phase or planned for it.

---

## Key abstractions

### `Autochef::Config`

Loads `config.yaml` + `.env` into a tree of `ActiveModel`-validated objects. Raises `ConfigError` immediately if anything is missing or invalid — bad config fails loudly at startup, never silently mid-run.

```ruby
cfg = Autochef::Config.load
cfg.mealie.url           # => "http://mealie:9000"
cfg.safety.dry_run       # => true
cfg.meals.week_layout    # => {"Sun"=>"cook", "Mon"=>"leftover", ...}
```

`MEALIE_URL` in `.env` overrides `config.yaml`'s `mealie.url` — useful for local dev outside Docker.

**To add a new config field:** add an `attr_reader` + `validates` line to the appropriate `ValidatedStruct` subclass. The struct raises `ConfigError` on bad data so failures surface at load time.

### `Autochef::Database`

Two class methods, called once at startup:

```ruby
Autochef::Database.connect!   # establishes ActiveRecord connection to data/autochef.db
Autochef::Database.migrate!   # runs any pending migrations in db/migrate/
```

**To add a new table:** create `db/migrate/NNN_create_<table>.rb` (next sequential number). `Database.migrate!` picks it up on the next run.

### `Autochef::MealieClient`

Thin HTTP wrapper over Mealie's REST API. Handles pagination transparently — all list methods return flat arrays.

```ruby
client = Autochef::MealieClient.new(base_url: cfg.mealie.url, api_token: cfg.mealie.api_token)

client.ping                            # GET /api/app/about (no auth required)
client.recipes                         # all recipes, all pages
client.eligible_pool("auto-plan")      # recipes tagged "auto-plan", client-side filter
client.recipe("lemon-herb-chicken")    # full recipe detail by slug or UUID
client.add_recipe_tags("slug", ["cuisine:american", "effort:quick"])
client.update_food_extras("food-id", { "shelf_life_days" => 3 })
```

Raises `MealieClient::AuthError` (401), `MealieClient::NotFound` (404), or `MealieClient::Error` (other HTTP failures).

**To add a new Mealie API call:** add a public method that calls the private `get`, `patch`, or `post` helpers. They handle auth headers, timeout, and error translation automatically.

### `Autochef::Models::RecipeStat`

ActiveRecord model over `recipe_stats`. Fields sourced from Mealie (written by `main.rb sync`):
- `avg_rating` — Mealie recipe rating
- `last_cooked` — Mealie `lastMade` date

Fields owned by AutoChef (never overwritten by sync):
- `times_planned`, `times_cooked`, `times_swapped_out` — incremented by the planner/feedback loop
- `score` — computed by `Scorer` (Phase 2); cached here

`recipe_id` is Mealie's UUID (stable across recipe renames).

### `MealieClient.suggest_shelf_life(food_name)`

Class method. Pattern-matches food names against a priority list and returns a suggested `shelf_life_days` integer. Returns `365` (pantry default) if no pattern matches. Used by `scripts/tag_recipes.rb` to suggest values; the human always confirms.

---

## Build phases

| Phase | Status | What's in it |
|---|---|---|
| 0 | ✅ Verified | Scaffolding: config, DB migrations, Docker, Uptime Kuma ping |
| 1 | ✅ Implemented (not yet verified against live Mealie) | `MealieClient`, `main.rb sync`, `scripts/tag_recipes.rb` |
| 2 | ⬜ Not started | `scoring.rb`, `planner.rb`, `llm_planner.rb`, `main.rb plan` |
| 3 | ⬜ Not started | `notify.rb` Telegram approval bot + manual-add commands |
| 4 | ⬜ Not started | `shopping.rb`, `recurring.rb`, `scripts/seed_product_map.rb` |
| 5 | ⬜ Not started | `cart.py` Playwright flow, `safety.rb`, `main.rb build-cart` |
| 6 | ⬜ Not started | `reminders.rb`, feedback logging, backup script, rufus-scheduler |
| 7 | Optional | Auto-checkout (behind `dry_run: false`; leave off by default) |

---

## Local development

### Prerequisites

- Ruby 3.2+ (`ruby --version`)
- Bundler (`gem install bundler`)
- Python 3.9+ with pip (only for `cart_builder/` work)

### First-time setup

```bash
bundle install

# Python side (only needed if working on cart_builder/)
python3 -m venv .venv
source .venv/bin/activate
pip install -r cart_builder/requirements.txt
playwright install --with-deps chromium
deactivate
```

### Running commands

```bash
bundle exec ruby main.rb check     # verify config + DB + Mealie connectivity
bundle exec ruby main.rb sync      # pull Mealie data → recipe_stats
bundle exec ruby scripts/tag_recipes.rb  # interactive recipe/food setup
```

### Connecting to Mealie outside Docker

Mealie's default config URL is `http://mealie:9000` (Docker internal hostname). For local dev, add to `.env`:

```
MEALIE_URL=http://localhost:9000   # or whatever port your Mealie is on
```

### Database inspection

```bash
sqlite3 data/autochef.db
.tables
SELECT * FROM recipe_stats LIMIT 10;
```

### Running tests

RSpec is in the Gemfile. Tests land in `spec/` — not yet written (Phase 2+).

```bash
bundle exec rspec
```

---

## How to extend

### Add a new scoring signal

1. Add a column to `recipe_stats` (new migration in `db/migrate/`)
2. Populate it in `main.rb sync` (pull from Mealie or compute locally)
3. Add a weight in `config.yaml` → `selection.scoring_weights`
4. Add the weight to `ScoringWeights` in `config.rb` (one `attr_reader` + `validates` line)
5. Include it in `scoring.rb`'s formula

### Add a new Mealie API method

Add a public method to `MealieClient` that calls the `get`, `patch`, or `post` private helpers. Example:

```ruby
def shopping_lists
  paginate("/api/households/shopping/lists")
end
```

### Add a new recurring staple cadence type

Add a row to `recurring_items` with the appropriate `cadence_type` (`every_order`, `every_n_orders`, `every_n_days`) and `cadence_value`. The `recurring.rb` injector reads these.

### Add a new recipe tag convention

Tags are free-form in Mealie. The conventions AutoChef uses are:

| Prefix | Examples | Used for |
|---|---|---|
| `cuisine:` | `cuisine:italian`, `cuisine:asian` | Variety cap |
| `protein:` | `protein:chicken`, `protein:beef` | Protein diversity + nutrition fit |
| `effort:` | `effort:quick`, `effort:project` | Avoid back-to-back project meals |
| (none) | `auto-plan`, `makes-leftovers` | Pool eligibility, leftover scheduling |

To add a new convention: update `scripts/tag_recipes.rb` to prompt for it, and handle it in `scoring.rb`/`planner.rb` as needed.

---

## Known-fragile areas

These are documented honestly in `MEALIE_AUTOMATION_PLAN.md` section 13 — short version:

- **Cart builder** (`cart_builder/cart.py`) automates a consumer website not built for automation. Expect selector rot when Food Lion / Instacart ships UI changes. Keep `dry_run: true` and manual checkout as permanent defaults.
- **Product mapping** (`product_map` table) needs a one-time human seeding pass per new ingredient. Never silently guess pack sizes.
- **LLM output** is always JSON-validated with a deterministic fallback — a bad model response can never break a run.

---

## Data flow cheat sheet

```
Mealie recipes/foods/ratings
        │
        │  MealieClient (Phase 1)
        ▼
recipe_stats (SQLite)
        │
        │  Scorer (Phase 2) — reads rating, last_cooked, tag_weights, times_swapped_out
        ▼
scored_pool (in-memory sorted list)
        │
        │  Planner (Phase 2) — cook-day scheduling + perishability ordering
        ▼
draft_plan {date: recipe_id, servings, meal_type}
        │
        │  LLMPlanner (Phase 2) — Claude arranges + adds rationale, JSON validated
        ▼
final_plan (with LLM rationale; falls back to deterministic on parse failure)
        │
        │  Notify (Phase 3) — Telegram approval gate
        ▼
approved_plan
        │
        │  Shopping (Phase 4) — scale servings, inject staples, apply product map
        ▼
"Next Order" list in Mealie
        │
        │  CartClient → cart.py (Phase 5) — Playwright builds Food Lion cart
        ▼
cart_ready (total + screenshot + link) → Telegram → you tap checkout
```
