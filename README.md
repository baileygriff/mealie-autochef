# Mealie AutoChef

Weekly meal-planning → shopping-list → grocery-cart automation for a
self-hosted Mealie instance, with a human approval gate (Telegram) and a
manual final checkout. Target store: Food Lion, pickup.

Read `MEALIE_AUTOMATION_PLAN.md` for the full spec and `MEMORY.md` for
running project context, locked decisions, and gotchas. **Read both before
making changes** — several decisions (pickup-only, manual checkout,
Playwright over an AI browser agent, Ruby+ActiveRecord with one isolated
Python file) are intentional and shouldn't be relitigated without a
documented reason.

## Language: Ruby, with one Python file

This project is Ruby (plain Ruby + ActiveRecord/ActiveModel, no Rails app —
see "Why no Rails app" below) for everything except
`cart_builder/cart.py`, which stays Python because Playwright's official,
best-supported bindings are Python/Node/Java/.NET, not Ruby. See the
docstring at the top of `cart_builder/cart.py` for the full reasoning and
the IPC contract — Ruby's `lib/autochef/cart_client.rb` shells out to it
as a subprocess and parses JSON on stdout. That file pair is the one place
in the codebase where this boundary matters; everything else is just Ruby.

### Why no Rails app

ActiveRecord and ActiveModel both work standalone — `ActiveRecord::Base
.establish_connection` (see `lib/autochef/database.rb`) doesn't require a
Rails app, and neither does `ActiveModel::Validations` (see
`lib/autochef/config.rb`, which replaces what would've been a pydantic
config layer in Python). This project is a CLI batch job, not a web app —
no controllers, views, or asset pipeline — so a full `rails new` would add
Zeitwerk autoloading and multi-environment config conventions this project
doesn't need, for ~6 models. Revisit this if the project ever grows a real
web UI.

## ⚠️ Important note on what's been tested vs. not

This scaffolding was built in a sandbox **without access to rubygems.org**
(only a small domain allowlist — apt/npm/pip registries, GitHub — was
reachable; Ruby itself was installable via `apt`, gems were not). That means:

- **Verified, actually run in-sandbox:** Ruby syntax (`ruby -c`) on every
  `.rb` file; the full `cart_client.rb` ↔ `cart.py` subprocess round-trip,
  including the malformed-input path — this part is real, working code.
- **NOT verified — needs your editor-agent to run it first:**
  `Gemfile.lock` doesn't exist yet (run `bundle install` to generate it);
  `Autochef::Config.load`, the ActiveRecord migrations, and `main.rb check`
  have never actually executed, since `activerecord`, `sqlite3`,
  `activemodel`, `httparty`, and `dotenv` were all unreachable here.

**First thing to do in the editor:** `bundle install`, then
`bundle exec ruby main.rb check` (after setting up `.env` and `mealie_net`
per below), and fix whatever that surfaces. Treat the Ruby files as a
strong first draft, not as tested code, until that's been run once.

## Setup

### 1. Network

Autochef expects to reach Mealie at `http://mealie:9000` over a shared
Docker network called `mealie_net`. Create it once and attach your existing
Mealie container/compose stack to it:

```bash
docker network create mealie_net
# then add `mealie_net` to Mealie's own compose file under its service's
# `networks:`, or `docker network connect mealie_net <mealie_container_name>`
```

If your Mealie container has a different name than `mealie`, update
`mealie.url` in `config.yaml` accordingly.

### 2. Secrets

```bash
cp .env.example .env
```

Fill in:
- `MEALIE_API_TOKEN` — Mealie UI → user settings → create an API token
- `ANTHROPIC_API_KEY` — for the weekly LLM planning draft
- `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` — message `@BotFather` to create
  a bot, then `@userinfobot` to get your chat id
- `FOODLION_USERNAME` / `FOODLION_PASSWORD` — used once interactively in
  Phase 5 to seed `data/playwright_state.json`; not needed yet
- `UPTIME_KUMA_PUSH_URL` — Uptime Kuma → Monitors → a Push-type monitor →
  copy its Push URL (looks like `http://<kuma-host>/api/push/<token>?status=up&msg=OK`)

### 3. Config

Open `config.yaml` and fill in the values marked `FILL IN`:
- `store.name` — preferred Food Lion location
- `schedule.pickup_window_pref` — preferred pickup day/time slot
- `safety.spending_cap_usd` — confirm or change the $150 default

See `MEALIE_AUTOMATION_PLAN.md` section 11 for the full list of open
decisions needed before the first real run.

### 4. Install dependencies

```bash
bundle install                                    # Ruby gems

python3 -m venv .venv                              # Python, for cart_builder/ ONLY
source .venv/bin/activate
pip install -r cart_builder/requirements.txt
playwright install --with-deps chromium
deactivate
export CART_BUILDER_PYTHON="$(pwd)/.venv/bin/python3"   # so cart_client.rb finds it
```

### 5. Run locally (no Docker)

```bash
bundle exec ruby main.rb check
```

This validates config, runs ActiveRecord migrations against
`data/autochef.db`, checks Mealie connectivity, and pings Uptime Kuma.
Expect the Mealie check to fail unless `mealie` resolves on your network
(i.e. unless you're running this inside Docker on `mealie_net`, or you've
pointed `mealie.url` at a reachable host).

### 6. Run via Docker

```bash
docker network create mealie_net   # if not already created
cd docker
docker compose up -d --build
docker compose logs -f
```

The Dockerfile builds both runtimes: Ruby (the app) and a Python venv
scoped to `cart_builder/` (Playwright). `CART_BUILDER_PYTHON` is set via
`ENV` in the Dockerfile so `cart_client.rb` finds the right interpreter
automatically inside the container.

## Repo

```bash
git init
git add .
git commit -m "Phase 0: scaffolding (Ruby + ActiveRecord, Python isolated to cart_builder/)"
git branch -M main
git remote add origin https://github.com/baileygriff/mealie-autochef.git
git push -u origin main
```

## Project layout

```
mealie-autochef/
├── Gemfile                  # Ruby deps (no Gemfile.lock yet — generate with `bundle install`)
├── main.rb                  # CLI entrypoint
├── config.yaml, .env.example
├── lib/autochef/
│   ├── config.rb             # ActiveModel-validated config loader
│   ├── database.rb           # ActiveRecord connection + migration runner
│   ├── cart_client.rb        # subprocess bridge to cart_builder/cart.py
│   └── models/                # one ActiveRecord model per table
├── db/migrate/               # ActiveRecord migrations (run via Database.migrate!)
├── cart_builder/              # the ONE Python piece — see cart.py's docstring
│   ├── cart.py, requirements.txt
├── docker/Dockerfile, docker-compose.yml   # dual Ruby+Python runtime
├── scripts/, spec/            # Ruby utility scripts, rspec tests (later phases)
```

See `MEALIE_AUTOMATION_PLAN.md` section 5 for the original (Python-era)
intended layout — file names map 1:1 conceptually (`scoring.py` →
`scoring.rb`, etc.) for files not yet written.
