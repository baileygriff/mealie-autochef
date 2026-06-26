# HANDOFF — Mealie AutoChef

> **Read this file first, before anything else in this repo.** It's the
> entry point for an agent (or human) picking up this project cold inside
> a code editor. It tells you what order to read things in, what's actually
> been tested vs. not, and exactly what to do next.

## Read order

1. **This file** — orientation, immediate next steps.
2. **`MEMORY.md`** — durable project context, locked decisions, gotchas.
   Short, living document. Read this before touching any code.
3. **`MEALIE_AUTOMATION_PLAN.md`** — the full original spec: architecture,
   data model, feature specs, phase breakdown, safety requirements. This
   was written before the Ruby switch, so it describes a Python stack in
   sections 4–5 — there's an amendment note at the top of that file
   pointing you back here / to `MEMORY.md` for what's actually current.
   Everything else in it (architecture, schema, feature behavior, phase
   definitions of done) is still the active spec.
4. **`README.md`** — mechanical setup steps (network, secrets, install,
   run). Use this once you're ready to actually execute something.

## What this project is, in one paragraph

A weekly meal-planning → shopping-list → grocery-cart automation for a
self-hosted Mealie instance. A deterministic Ruby backend scores and
schedules recipes, Claude (Haiku, via the Anthropic API) arranges the
weekly draft, Bailey approves/swaps over Telegram, and a Playwright
(Python) script builds the Food Lion pickup cart — but always stops before
checkout. A human taps the final "place order" button. Runs in Docker on
an Unraid box alongside an existing Jellyfin/Immich/Pi-hole/Tailscale
stack.

## Why this is Ruby with one Python file

Bailey's primary fluency is Ruby/Rails, not Python. The project started as
pure Python, then was deliberately rewritten to plain Ruby +
ActiveRecord/ActiveModel (no Rails app — see "Why no Rails app" in
`README.md`) partway through Phase 0. The **one exception** is
`cart_builder/cart.py`: Playwright's official, best-maintained bindings
are Python (also Node/Java/.NET) — Ruby's option is a smaller community
wrapper around the same driver — and the cart builder is already the
single most fragile part of the system (it automates a consumer site that
was never built to be automated). That's the wrong place to stack a
second "less-proven library" risk on top of an already-fragile piece.

Ruby talks to `cart.py` via a subprocess, JSON in on stdin, JSON out on
stdout. The full contract is documented in two places that must stay in
sync if you ever touch this boundary:
- `cart_builder/cart.py` — module docstring, INPUT_SCHEMA / OUTPUT_SCHEMA
- `lib/autochef/cart_client.rb` — the Ruby-side caller

This decision is logged in `MEMORY.md`'s "Locked decisions" section.
Don't relitigate it without a documented reason — but if you ever do, it's
contained to those two files plus the Docker dual-runtime setup.

## ⚠️ What's actually been tested vs. not (read before assuming anything works)

This scaffolding was built in a sandbox **with no access to
rubygems.org** — only a small domain allowlist (apt, npm/pip registries,
GitHub) was reachable. Concretely:

**Verified — actually executed, real output checked:**
- Every `.rb` file passes `ruby -c` (syntax only, no semantic guarantee)
- `cart_builder/cart.py`'s Phase 0 stub, called directly with both valid
  and malformed JSON on stdin — confirmed it returns the right shape and
  exit code in both cases
- The full `lib/autochef/cart_client.rb` → `cart_builder/cart.py`
  subprocess round-trip, using only Ruby stdlib (`Open3`, `JSON`) — no
  gems required for this, so it's genuinely been run, not just written

**NOT verified — nothing below this line has ever actually executed:**
- `bundle install` (no `Gemfile.lock` exists yet — you're generating it
  fresh)
- `Autochef::Config.load` (`lib/autochef/config.rb`) — the
  `ActiveModel::Validations` logic, the YAML parsing, the env-var overlay
- The ActiveRecord migrations in `db/migrate/` — schema correctness,
  column types, defaults, whether they actually run against SQLite
  cleanly
- Every ActiveRecord model in `lib/autochef/models/` — table_name/
  primary_key overrides, validations, scopes
- `main.rb check` — the whole sanity-check command, including Mealie
  connectivity and Uptime Kuma ping logic

None of this is a reason for alarm — it's straightforward, well-precedented
Ruby/ActiveRecord code, written carefully against a clear schema spec. But
treat it as a **strong first draft**, not as working code, until you've
run it once yourself. Don't skip straight to Phase 1 assuming Phase 0 is solid.

## Next steps, in order

1. **`bundle install`** from the repo root. Fix whatever gem resolution
   issues come up (there's no lockfile yet — this run creates one).
2. **Set up `.env`** — `cp .env.example .env`, fill in `MEALIE_API_TOKEN`
   at minimum (the other secrets — Anthropic, Telegram, Food Lion,
   Uptime Kuma — aren't needed until later phases, but `main.rb check`
   will warn loudly about whichever are missing; that warning is expected
   and not a bug).
3. **Set up `mealie_net`** — `docker network create mealie_net`, then
   attach your existing Mealie container to it (see `README.md` section 1
   for exact commands). If you're testing locally without Docker first,
   you can instead point `mealie.url` in `config.yaml` at wherever Mealie
   is actually reachable from your dev machine.
4. **Run `bundle exec ruby main.rb check`.** This is the real first test
   of everything in "not verified" above. Expect to need to fix things —
   that's the point of running it now rather than after Phase 1 is also
   built on top of an unverified foundation. Work through errors in this
   rough order: config load → DB connect/migrate → Mealie reachability →
   Uptime Kuma ping (the last two are allowed to fail gracefully; only
   config and DB failures should block you).
5. **Set up the Python side for `cart_builder/`** — separate venv, per
   README section 4 (`python3 -m venv`, `pip install -r
   cart_builder/requirements.txt`, `playwright install --with-deps
   chromium`, `export CART_BUILDER_PYTHON=...`). Not urgent for Phase 1,
   but cheap to do now while you're in setup mode.
6. **Once `main.rb check` passes cleanly** (or you've made a deliberate,
   documented call to defer something — e.g. Mealie isn't deployed yet so
   that check stays red for now), update `MEMORY.md`'s build-status
   checklist: change Phase 0 from `[~]` to `[x]`, and remove the "rebuilt
   in Ruby... not yet run" gotcha line once it's no longer true.
7. **Start Phase 1** — `lib/autochef/mealie_client.rb` (Mealie REST API
   wrapper) and `scripts/tag_recipes.rb` (bulk-tag perishability/cuisine/
   effort, seed `shelf_life_days` extras + On-Hand flags). Full spec in
   `MEALIE_AUTOMATION_PLAN.md` sections 7.1 and 10 (Phase 1's definition
   of done: "eligible pool queryable; perishability resolvable for every
   eligible recipe").

   Before writing code, you'll need from Bailey: confirmation his Mealie
   instance is populated with recipes, and a Mealie API token (Mealie UI
   → user settings → create API token) if one doesn't exist in `.env` yet.

## Where to find documentation

- **Mealie API:** https://docs.mealie.io/documentation/getting-started/api-usage/
- **Mealie features** (Plan Rules, shopping lists, On-Hand flag, labels):
  https://docs.mealie.io/documentation/getting-started/features/
- **ActiveRecord standalone usage** (no Rails app): search "ActiveRecord
  without Rails" — the pattern used here is
  `ActiveRecord::Base.establish_connection(adapter: "sqlite3", database:
  ...)` followed by `ActiveRecord::MigrationContext.new(path,
  ActiveRecord::SchemaMigration).migrate`, both in
  `lib/autochef/database.rb`.
- **ActiveModel::Validations standalone:** same idea — it's documented as
  part of Rails but works as a plain `include ActiveModel::Validations`
  mixin with no Rails app required. See `lib/autochef/config.rb` for the
  pattern in use (`ValidatedStruct` base class).
- **Claude API / pricing:** https://docs.claude.com/en/docs/about-claude/pricing
  (model in use: `claude-haiku-4-5-20251001`, config-flaggable to
  `claude-sonnet-4-6`)
- **Playwright for Python:** https://playwright.dev/python/
- **telegram-bot-ruby:** check its GitHub repo/README directly — it's a
  smaller gem than Python's `python-telegram-bot`; the spec's approval
  flow (inline buttons + slash commands) is achievable with it, but the
  bot-construction patterns will look different from the
  `python-telegram-bot` examples the original spec doc had in mind.
- **rufus-scheduler** (in-process cron, for later phases):
  https://github.com/jmettraux/rufus-scheduler

## The full phase plan (from `MEALIE_AUTOMATION_PLAN.md` section 10)

| Phase | What | Definition of done |
|---|---|---|
| 0 | Scaffolding | Container/process runs, reads config, connects to Mealie, creates the DB. **Currently: structure done, execution unverified — see above.** |
| 1 | Data layer | `mealie_client.rb`, `scripts/tag_recipes.rb`. Eligible pool queryable; perishability resolvable for every eligible recipe. |
| 2 | Selection | `scoring.rb` + `planner.rb` + `llm_planner.rb`. `main.rb plan` produces a valid, perishability-correct week. |
| 3 | Approval | `notify.rb` Telegram bot — Approve/Swap/Regenerate/Add-note, manual-add commands. Swaps logged. |
| 4 | Shopping list | `shopping.rb` + `recurring.rb` + product map. Correct, scaled, deduped "Next Order" list. |
| 5 | Cart builder | `cart_builder/cart.py` real Playwright flow + `safety.rb`. Cart populated, slot selected, **no order placed**. |
| 6 | Feedback & polish | Order/plan logging, reminders, backups. Full week runs end-to-end with only approval + final checkout manual. |
| 7 | (Optional) Auto-checkout | Behind `dry_run: false`. **Recommended to leave off indefinitely.** |

Each phase's full spec (not just the one-line summary above) is in
`MEALIE_AUTOMATION_PLAN.md` sections 8 (feature specs) and 10 (phases +
DoD). Read the relevant section 8 subsection before starting each phase —
the one-liners above are not enough detail to build from.

## Things that are easy to get wrong if you skim

- **`store.fulfillment` is hard-validated to only accept `"pickup"`**
  (`lib/autochef/config.rb`, `StoreConfig`). This is intentional, not a
  bug — it's a locked decision per `MEMORY.md`. If requirements ever
  change, that's a one-line `inclusion` list to widen, but treat it as a
  deliberate, discussed change.
- **The cart builder must never place an order itself.** `safety.dry_run`
  defaults `true` everywhere for a reason — Phase 7 (auto-checkout) is
  explicitly recommended to stay off indefinitely. Don't "helpfully" flip
  this while implementing Phase 5.
- **Out-of-stock items get flagged, never silently substituted** — this
  applies to both ingredient-to-product mapping (Phase 4) and the cart
  builder itself (Phase 5). Don't let either layer guess.
- **`cart_client.rb`'s `CART_BUILDER_PYTHON` env var** needs to point at
  the `cart_builder/` venv's Python, not system Python — it defaults to
  bare `python3` on PATH, which won't have `playwright` installed unless
  you've exported it (see Next Steps step 5, and README section 4).
- **Mealie does not auto-backup.** That's explicitly this project's job
  (Phase 6, `scripts/backup.rb` — not yet written).
