# Mealie AutoChef

Weekly meal-planning → shopping-list → grocery-cart automation for a
self-hosted Mealie instance. Bailey approves the weekly plan over Telegram,
then taps one button in Food Lion To Go to place the order. Everything
in between is automated.

Target store: Food Lion, pickup only.

## Documentation

- [Setup Walkthrough](docs/SETUP_WALKTHROUGH.md) — concrete 10-step first-run guide (start here)
- [User Guide](docs/USER_GUIDE.md) — weekly operation, Telegram commands, configuration reference, troubleshooting
- [Developer Guide](docs/DEVELOPER_GUIDE.md) — architecture, schema, data flow, how to extend

For running project context and locked decisions, see `MEMORY.md`.
**Read it before making changes** — several decisions (pickup-only, manual
checkout, Playwright over AI browsing, Ruby+ActiveRecord with one isolated
Python file) are intentional and documented.

For testing status (what's been verified end-to-end vs. still needs testing), see
[testing_verifications.md](testing_verifications.md).

---

## What it does

```
Thursday ~6 pm — AutoChef picks this week's dinners
  → Claude Haiku arranges them into a perishability-aware schedule
  → sends a Telegram message: plan + inline Approve/Swap/Regenerate buttons
  → "⚙ Configure week" button links to the web form at :3456/week

You (optionally, before approving)
  → open the week configurator form
  → set protein excludes, per-day overrides, servings, vibes, freeform note
  → tap Regenerate in Telegram to apply

You (before the weekend) — tap Approve

AutoChef (on Approve)
  → scales servings, injects recurring staples, resolves product map
  → consolidates duplicate search terms (quantities summed)
  → pushes "Next Order" list to Mealie
  → opens Food Lion To Go in a headed Chrome browser
  → clears any items from a previous run
  → adds every item, selects a pickup slot, STOPS before checkout
  → sends "Cart ready: $XX.XX — tap here to review and place"

You — tap the link → review the cart → place the order
```

The cart builder never places an order. That is always you.

---

## Language: Ruby, with one Python file

Everything is Ruby (plain Ruby + ActiveRecord/ActiveModel, no Rails) except
`cart_builder/cart.py`, which stays Python because Playwright's official
best-supported bindings are Python/Node/Java/.NET. See the docstring at the
top of `cart_builder/cart.py` for the full reasoning and the IPC contract.
Ruby shells out to it as a subprocess and parses JSON from stdout.

### Why no Rails app

ActiveRecord and ActiveModel work standalone. This project is a CLI batch
job — no controllers, views, or asset pipeline. A full Rails app would add
Zeitwerk autoloading and multi-environment conventions this project doesn't
need, for ~7 models. Revisit only if a real web UI appears.

---

## Prerequisites

- Ruby 3.2+ (`ruby --version`)
- Bundler (`gem install bundler`)
- Python 3.11+ with pip (cart_builder only)
- SQLite3
- Docker + Docker Compose (for production Unraid deployment)
- A running self-hosted Mealie instance
- A Telegram bot (for plan approval and notifications)

---

## Quick start

For a full walkthrough with expected output at each step, see
[docs/SETUP_WALKTHROUGH.md](docs/SETUP_WALKTHROUGH.md). The short version:

```bash
# 1. Install Ruby deps
bundle install

# 2. Configure secrets
cp .env.example .env
# → fill in MEALIE_API_TOKEN, ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID

# 3. Fill in config.yaml (three FILL IN values: store.name, pickup_window_pref, spending_cap_usd)

# 4. Verify everything wires together
bundle exec ruby main.rb check

# 5. Python side (cart_builder only)
python3 -m venv .venv && source .venv/bin/activate
pip install -r cart_builder/requirements.txt
playwright install chrome
python3 cart_builder/cart.py --login   # interactive browser session setup
deactivate
export CART_BUILDER_PYTHON="$(pwd)/.venv/bin/python3"
```

---

## CLI commands

All commands follow the pattern `bundle exec ruby main.rb <command>`.

| Command | Phase | What it does |
|---|---|---|
| `check` | 0/1 | Validate config, run migrations, ping Mealie and Uptime Kuma |
| `sync` | 1 | Pull `avg_rating` and `lastMade` from Mealie into `recipe_stats` |
| `plan [note]` | 2+3 | Score recipes, build week plan, send Telegram draft for approval |
| `serve` | 3+6 | Long-running Telegram bot + Sinatra week configurator (port 3456) + rufus-scheduler |
| `shop` | 4 | Scale ingredients, inject staples, push "Next Order" list to Mealie |
| `automap` | 4 | LLM-map unmapped ingredients in "Next Order" to Food Lion search terms |
| `build-cart [--force]` | 5 | Fetch Next Order list → drive Food Lion cart via Playwright |
| `feedback [--force]` | 6 | Increment times_cooked, update tag_weights from kept plan |
| `budget` | 6 | Print monthly/YTD spend from order_history |
| `backup` | 6 | Copy `data/autochef.db` to `data/backups/`, trigger Mealie backup |

---

## Setup

### 1. Network (Docker)

AutoChef expects Mealie at `http://mealie:9000` on a shared Docker network
called `mealie_net`:

```bash
docker network create mealie_net
docker network connect mealie_net <your_mealie_container_name>
```

If your Mealie container has a different hostname, update `mealie.url` in
`config.yaml`. For local development outside Docker, set `MEALIE_URL` in
`.env`:

```
MEALIE_URL=http://localhost:9000
```

### 2. Secrets

```bash
cp .env.example .env
```

| Variable | Where to get it |
|---|---|
| `MEALIE_API_TOKEN` | Mealie UI → your username → API Tokens → create one |
| `ANTHROPIC_API_KEY` | console.anthropic.com |
| `TELEGRAM_BOT_TOKEN` | Telegram → `@BotFather` → `/newbot` |
| `TELEGRAM_CHAT_ID` | Telegram → `@userinfobot` (your personal chat ID with the bot) |
| `FOODLION_USERNAME` | Your Food Lion / Instacart account email |
| `FOODLION_PASSWORD` | Your Food Lion / Instacart account password |
| `UPTIME_KUMA_PUSH_URL` | Uptime Kuma → Monitors → Push-type monitor → Push URL |
| `MEALIE_URL` | Local dev override only (e.g. `http://localhost:9000`) |

`FOODLION_USERNAME` / `FOODLION_PASSWORD` are used once to seed the
browser session (`python3 cart_builder/cart.py --login`). After that, only
the saved `data/playwright_state.json` is used.

### 3. Config

Open `config.yaml` and fill in the three `FILL IN` values:

```yaml
store:
  name: "Food Lion - City, State"   # your preferred pickup location
schedule:
  pickup_window_pref: "Sun 10:00-12:00"
safety:
  spending_cap_usd: 150
```

### 4. Install Ruby dependencies

```bash
bundle install
```

`Gemfile.lock` is committed. This should be deterministic.

### 5. Verify setup

```bash
bundle exec ruby main.rb check
```

Expect `PARTIAL` if running outside Docker (Mealie unreachable). Config + DB
OK is enough to proceed with recipe setup.

### 6. Tag recipes in Mealie

```bash
bundle exec ruby scripts/tag_recipes.rb
```

Interactive script — walks every Mealie recipe and prompts for the tags
AutoChef uses: `auto-plan`, `cuisine:*`, `protein:*`, `effort:*`,
`makes-leftovers`. Also sets `shelf_life_days` on each food for
perishability-aware scheduling.

### 7. Sync to local DB

```bash
bundle exec ruby main.rb sync
```

Pulls `avg_rating` and `lastMade` from Mealie into `recipe_stats`. Re-run
any time ratings or cook history change.

### 8. Python side (cart_builder)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r cart_builder/requirements.txt
playwright install chrome

# One-time interactive login to Food Lion — saves session to data/playwright_state.json
python3 cart_builder/cart.py --login

deactivate
export CART_BUILDER_PYTHON="$(pwd)/.venv/bin/python3"
```

### 9. Seed the product map

After the first `main.rb shop`, map unmapped ingredients to Food Lion search terms.

**LLM-assisted (recommended):**
```bash
bundle exec ruby main.rb automap
```
Claude Haiku suggests search terms, quantities, and pantry-skip flags for all
unmapped ingredients in one batch. Auto-saves everything. Also `/automap` in
Telegram.

**Manual fallback:**
```bash
bundle exec ruby scripts/seed_product_map.rb
```
Interactive — walks each unmapped item and prompts for search term, pack size,
default quantity, and rounding rule.

**First run:** expect ~50 items (all ingredients from your initial recipe pool).
**Steady state:** only new ingredients from newly-added recipes need mapping.
`main.rb shop` reports unmapped items and lists both paths.

Manual flags: `--list` (show existing mappings), `--update` (re-map already-mapped items).

---

## Run via Docker (production)

```bash
docker network create mealie_net   # if not already created
cd docker
docker compose up -d --build
docker compose logs -f
```

The Dockerfile builds both Ruby and Python runtimes. `CART_BUILDER_PYTHON`
is set via `ENV` in the Dockerfile so `cart_client.rb` finds the right
Python interpreter automatically inside the container.

---

## Project layout

```
mealie-autochef/
├── main.rb                       # CLI entrypoint; one cmd_* method per command
├── config.yaml                   # human-editable settings
├── .env / .env.example           # secrets (never commit .env)
│
├── lib/autochef/
│   ├── config.rb                 # ActiveModel-validated config loader
│   ├── database.rb               # ActiveRecord connection + migration runner
│   ├── mealie_client.rb          # HTTP wrapper over Mealie REST API
│   ├── cart_client.rb            # subprocess bridge to cart_builder/cart.py
│   ├── scoring.rb                # deterministic preference scorer
│   ├── planner.rb                # cook-day scheduling + perishability ordering
│   ├── llm_planner.rb            # Claude Haiku weekly draft, strict JSON output
│   ├── llm_qty_consolidator.rb   # LLM pack-size rationalization after deduplication
│   ├── llm_recipe_mapper.rb      # LLM-assisted product map seeder (automap)
│   ├── shopping.rb               # list gen, scaling, staples, product map
│   ├── recurring.rb              # cadence-based staple injection
│   ├── notify.rb                 # Telegram bot + approval flow
│   ├── reminders.rb              # thaw / night-before push notifications
│   ├── safety.rb                 # spending cap, kill switch, idempotency
│   ├── feedback.rb               # post-week learning loop
│   ├── week_prefs_source.rb      # WeekPrefs/DayPrefs structs + source interface
│   ├── sinatra_prefs_source.rb   # DB-backed implementation of WeekPrefsSource
│   ├── web/app.rb                # Sinatra form served at :3456/week
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
├── db/migrate/
│   ├── 001_create_recipe_stats.rb
│   ├── 002_create_tag_weights.rb
│   ├── 003_create_recurring_items.rb
│   ├── 004_create_product_map.rb
│   ├── 005_create_manual_additions.rb
│   ├── 006_create_plan_history.rb
│   ├── 007_create_order_history.rb
│   ├── 008_add_feedback_applied_to_order_history.rb
│   └── 009_create_week_prefs.rb
│
├── cart_builder/
│   ├── cart.py                   # Playwright Food Lion automation (Python only)
│   └── requirements.txt
│
├── scripts/
│   ├── tag_recipes.rb            # interactive recipe/food tagger
│   ├── seed_product_map.rb       # interactive product-map seeder (manual fallback)
│   └── auto_map.rb               # LLM-assisted product-map seeder (Feature 6)
│
├── spec/
│   ├── spec_helper.rb            # in-memory SQLite, transaction rollback isolation
│   ├── config_spec.rb
│   ├── scoring_spec.rb
│   ├── planner_spec.rb
│   ├── feedback_spec.rb
│   ├── safety_spec.rb
│   ├── week_prefs_spec.rb
│   └── manual_addition_spec.rb   # ManualAddition model + resolve logic invariants
│
├── MEMORY.md                     # locked decisions, gotchas, verified state
├── TESTING_HANDOFF.md            # agent briefing for test/feedback sessions
├── testing_feedback.md           # bug history and known issues
├── testing_verifications.md      # per-feature verification status (✅/❌/🔧)
└── future_enhancements.md        # feature backlog index (links to docs/features/)
│
├── docs/
│   ├── SETUP_WALKTHROUGH.md
│   ├── USER_GUIDE.md
│   ├── DEVELOPER_GUIDE.md
│   └── features/                 # one spec file per feature/improvement/infra item
│       ├── feature_NN_name.md    # complete spec or ❓ placeholder with open questions
│       ├── improvement_name.md
│       └── infra_NN_name.md
│
└── docker/
    ├── Dockerfile
    └── docker-compose.yml
```

---

## Safety features

All are on by default. The system is designed to require human action
at every meaningful step.

| Feature | What it does |
|---|---|
| **Dry-run mode** (`safety.dry_run: true`) | Cart built but never auto-placed. Keep this on. |
| **Spending cap** (`safety.spending_cap_usd`) | Cart total > cap → abort + Telegram alert |
| **Kill switch** | `touch data/PAUSE` halts all ordering; `rm data/PAUSE` resumes |
| **Idempotency** | Each weekly run has a unique key; re-running reconciles, not double-builds |
| **Deviation alert** | Built cart total deviates >20% from estimate → Telegram warning |
| **Out-of-stock policy** | Never silently substitutes — flagged items need human review |

---

## Running tests

```bash
bundle exec rspec
```

50 examples, 0 failures. Tests use in-memory SQLite (`:memory:`) and
transaction rollback isolation — they never touch `data/autochef.db`.

---

## Cart builder behavior

- **Headed Chrome** — `headless=False` is required; Food Lion's bot-detection blocks headless browsers.
- **Cart cleared on every run** — `build-cart` empties the existing Food Lion cart before adding items, so `--force` re-runs are safe and never create duplicates.
- **Quantity consolidation** — if multiple recipes need the same Food Lion search term (e.g. "salmon fillet" for two recipes), their quantities are summed into one cart entry before cart.py is called.
- **Pantry items** — ingredients marked `s` in `seed_product_map.rb` are excluded from the cart and listed to stdout + Telegram so you can verify stock before pickup.
- **`/add` items** are in the Mealie "Next Order" list and are always re-added by the normal build flow — they survive a cart clear.

---

## Unraid deployment notes

See `MEALIE_AUTOMATION_PLAN.md` section 12 for Docker Compose configuration
and Unraid User Scripts setup. The key points:

- Mount `data/` as a persistent volume on your array
- Mount `.env` as a read-only secret or use Unraid's Docker secrets
- `data/playwright_state.json` must be pre-seeded on the host (it's in `.gitignore`)
- `main.rb serve` runs the bot continuously; the weekly `plan` command can be
  fired by Unraid User Scripts on a Thursday schedule or left to rufus-scheduler
  inside the `serve` process
