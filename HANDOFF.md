# HANDOFF — Mealie AutoChef

> **Read this file first, before anything else in this repo.** It is the
> entry point for an agent (or human) picking up this project cold inside
> a code editor. It tells you what order to read things, what is actually
> verified vs. not, what bugs have been found and fixed, and exactly what
> to do next.

## Read order

1. **This file** — orientation, current state, known issues.
2. **`MEMORY.md`** — durable project context, locked decisions, key gotchas.
   Short, living document. Read this before touching any code.
3. **`MEALIE_AUTOMATION_PLAN.md`** — the full original spec: architecture,
   data model, feature specs, phase breakdown, safety requirements. There
   is an amendment note at the top pointing to `MEMORY.md` for the Ruby
   switch; sections 4–5 are historical Python-era content. Everything else
   (architecture, schema, feature behavior, phase definitions of done) is
   the active spec.
4. **`README.md`** — mechanical setup (network, secrets, install, run).
5. **`docs/SETUP_WALKTHROUGH.md`** — concrete 10-step first-run guide
   (exact commands, expected output, Food Lion session seeding).

## What this project is, in one paragraph

A weekly meal-planning → shopping-list → grocery-cart automation for a
self-hosted Mealie instance. A deterministic Ruby backend scores and
schedules recipes, Claude Haiku (via Anthropic API) arranges the weekly
draft, Bailey approves/swaps over Telegram, and a Playwright (Python)
script builds the Food Lion pickup cart — always stopping before checkout.
A human taps the final "place order" button. Runs in Docker on an Unraid
box alongside an existing Jellyfin/Immich/Pi-hole/Tailscale stack.

## Why Ruby with one Python file

Bailey's primary fluency is Ruby/Rails. The project was deliberately
written as plain Ruby + ActiveRecord/ActiveModel (no Rails app) for
everything except `cart_builder/cart.py`, which stays Python because
Playwright's official, best-maintained bindings are Python/Node/Java/.NET
— not Ruby. The cart builder is already the most fragile part of the
system (automating a consumer website). That's the wrong place to stack
a "less-proven library" risk on top.

Ruby calls `cart.py` as a subprocess — JSON in on stdin, JSON out on
stdout. The full contract is documented in two places that must stay in
sync if you ever touch this boundary:

- `cart_builder/cart.py` — module docstring, `INPUT_SCHEMA`, `OUTPUT_SCHEMA`
- `lib/autochef/cart_client.rb` — the Ruby-side caller

This decision is locked in `MEMORY.md`. Don't relitigate without a
documented reason.

---

## What's been implemented and what's been verified

**All 6 phases are implemented.** Nothing is a stub. The code is complete.

### What IS verified (run, confirmed, or unit-tested)

- **34 RSpec smoke tests pass** (in-memory SQLite, no live services):
  - `spec/config_spec.rb` — 5 examples (valid config, missing fields, bad values)
  - `spec/scoring_spec.rb` — 4 examples (score written to DB, rating/swap/tag signals)
  - `spec/planner_spec.rb` — 5 examples (cook days, perishability ordering, warnings)
  - `spec/feedback_spec.rb` — 6 examples (times_cooked, idempotency, force override)
  - `spec/safety_spec.rb` — 14 examples (kill switch, spending cap, idempotency, deviation)
- **All 8 ActiveRecord migrations** run cleanly on SQLite (verified by the test suite)
- **`Autochef::Config.load`** validates all fields, raises `ConfigError` loudly on bad input
- **`cart_builder/cart.py` subprocess contract** — the Ruby ↔ Python IPC, input/output JSON shape,
  and exit code semantics have been verified against the schema in the file's docstring

### What is NOT verified (never run against live services)

- **Mealie connectivity** — `MealieClient` is untested against a real Mealie instance
  (Mealie is only reachable inside Docker on `mealie_net`; local testing was blocked by this)
- **Telegram bot** — `notify.rb` bot commands and approval flow untested against the real API
- **Food Lion cart builder** — `cart_builder/cart.py`'s real Playwright flow has never
  run against foodlion.com (requires a live session + `playwright_state.json`)
- **Uptime Kuma ping** — health-check endpoint untested against a live Kuma instance
- **`main.rb check`** end-to-end with all services live — expected to require some fixes
  when first run inside Docker with real Mealie/Telegram tokens

---

## Bugs found and fixed (this audit session)

### Critical — would have caused `NoMethodError` at runtime

**`lib/autochef/notify.rb` — private method visibility**

`send_cart_ready`, `send_cart_aborted`, `send_thaw_reminder`, and
`send_morning_ping` were defined after the `private` keyword, making them
private. They are called from outside the class:

- `main.rb` lines ~577, ~599, ~609 (`build-cart` command)
- `lib/autochef/reminders.rb` lines ~48, ~55 (reminder scheduler jobs)

**Fix applied:** moved all four methods to the public section of the class
(between `run_bot` and the `private` keyword), then deleted the duplicate
private copies. The public/private boundary in `notify.rb` is now explicit.

### Minor — fragile `require` ordering

**`lib/autochef/recurring.rb` — missing `require 'date'`**

The file uses `Date.today` and `.to_date` without explicitly requiring the
stdlib. This worked in practice because `shopping.rb` loads `date` before
requiring `recurring`, but would break if `recurring.rb` were loaded in
isolation (e.g., from a test file).

**Fix applied:** added `require 'date'` at the top of `recurring.rb`.

### gitignore — `data/backups/` not excluded

`cmd_backup` writes SQLite snapshots to `data/backups/autochef_YYYYMMDD.db`.
This directory was not in `.gitignore`.

**Fix applied:** added `data/backups/` to `.gitignore`.

---

## Known limitations (not bugs, but document before extending)

### `est_total` is never populated by `cart.py`

`cart.py`'s `run_build_cart` function constructs `make_output(...)` but
never passes `est_total`. The `deviation_warning` check in `safety.rb`
compares `est_total` to `cart_total` — but with `est_total` always `nil`,
`deviation_warning` can never fire (it returns `nil` immediately).

There is no pre-cart estimate source currently. To fix this:
- Either have `cart.py` compute an estimate before adding items to the cart,
- Or compute one on the Ruby side (e.g., from Mealie ingredient costs, if available).

### `resolve_cart_item` key mismatch (latent bug)

`main.rb`'s `resolve_cart_item` looks up `ProductMap` by `item['note']`
(a Mealie shopping list display_name), but `product_map.key` is indexed
by food_name (as seeded by `seed_product_map.rb`). When `display_name ≠
food_name`, the lookup silently falls back to the raw item name rather than
the mapped product. This will manifest as "unmapped" warnings for items
that are in the product map but under a different key.

---

## Where to find documentation

- **Mealie API:** https://docs.mealie.io/documentation/getting-started/api-usage/
- **telegram-bot-ruby:** gem GitHub repo (patterns differ from Python's `python-telegram-bot`)
- **rufus-scheduler:** https://github.com/jmettraux/rufus-scheduler
- **Playwright Python:** https://playwright.dev/python/
- **Anthropic API:** https://docs.anthropic.com/en/api/

---

## Phase table (all implemented, none fully verified live)

| Phase | What | Status |
|---|---|---|
| 0 | Scaffolding — config, DB, Docker, Uptime Kuma | Implemented; unit tests pass |
| 1 | Data layer — `MealieClient`, `sync`, `tag_recipes.rb` | Implemented; untested vs. live Mealie |
| 2 | Selection — `scoring.rb`, `planner.rb`, `llm_planner.rb`, `plan` command | Implemented; unit tests pass |
| 3 | Approval — `notify.rb` Telegram bot, Approve/Swap/Regenerate/Add-note | Implemented; untested vs. live Telegram |
| 4 | Shopping list — `shopping.rb`, `recurring.rb`, `seed_product_map.rb`, `shop` command | Implemented; untested vs. live Mealie |
| 5 | Cart builder — real Playwright flow, `safety.rb`, `build-cart` command | Implemented; untested vs. live Food Lion |
| 6 | Feedback & polish — `feedback.rb`, `reminders.rb`, `budget`, `backup` commands, rufus-scheduler | Implemented; untested vs. live services |
| 7 | (Optional) Auto-checkout — behind `dry_run: false` | Not implemented; leave off indefinitely |

---

## Things easy to get wrong if you skim

- **`store.fulfillment` only accepts `"pickup"`** — intentional, not a bug.
  It's a locked decision in `MEMORY.md`. One-line change to widen if
  requirements ever change.
- **The cart builder never places an order itself.** `safety.dry_run`
  defaults `true`. Phase 7 (auto-checkout) is explicitly recommended to
  stay off indefinitely. Don't flip this.
- **Out-of-stock items are flagged, never silently substituted.** This
  applies to both the product map and the cart builder.
- **`CART_BUILDER_PYTHON` must point at the venv Python**, not system
  Python — defaults to `python3` on PATH, which won't have `playwright`
  installed. Inside the Docker container this is set automatically via
  `Dockerfile ENV`; outside Docker, `export CART_BUILDER_PYTHON=...`.
- **AR 7.2 migration API** — `ActiveRecord::MigrationContext.new` takes
  three arguments: `[MIGRATIONS_PATH]`, `pool.schema_migration`,
  `pool.internal_metadata`. The standalone `ActiveRecord::SchemaMigration`
  constant was removed in 7.2. See `memory/feedback_ar72_migration.md` and
  `lib/autochef/database.rb` for the correct pattern.
- **Week is Sunday-anchored.** `WEEKDAY_ORDER` in `planner.rb` starts Sun.
  Pickup day is Sunday; perishability is measured from Sunday's date.
