# MEMORY.md — Mealie AutoChef

> Persistent project context. Read this alongside `TESTING_HANDOFF.md` before
> touching any code. Keep this file concise; add durable facts and gotchas as
> they're learned.

---

## What this is

A weekly meal-planning → shopping-list → grocery-cart automation for a
self-hosted Mealie instance. A deterministic Ruby backend scores and schedules
recipes, Claude Haiku arranges the weekly draft, Bailey approves/swaps over
Telegram, and a Playwright (Python) script builds the Food Lion pickup cart —
always stopping before checkout. Runs in Docker on an Unraid box alongside
an existing Jellyfin/Immich/Pi-hole/Tailscale stack.

---

## Locked decisions (don't relitigate without reason)

| Decision | Choice |
|---|---|
| Fulfillment | **Pickup only** — no delivery API exists for Food Lion |
| Meal scope | **Dinner first**, lunch-expandable; `meal_types` is a list |
| LLM | **Claude Haiku** for weekly draft (~$0.03/week); Sonnet is a one-line config bump |
| Final checkout | **Manual** (`dry_run: true`). Auto-checkout is opt-in Phase 7, leave off indefinitely |
| Browser automation | **Playwright (Python)** — best official bindings; isolated to one file |
| Language | **Ruby (plain + ActiveRecord/ActiveModel, no Rails)**, one Python file for Playwright |
| Notifications | **Telegram** (not ntfy) — inline buttons + slash commands required for approval gate |
| Default servings | **2**, per-meal override supported |

**The Python file (`cart_builder/cart.py`) is intentionally the only Python.** Ruby calls it
as a subprocess (JSON in on stdin, JSON out on stdout). The IPC contract is documented in two
places that must stay in sync: `cart_builder/cart.py` module docstring and
`lib/autochef/cart_client.rb`. Don't replace it with a Ruby Playwright wrapper without a
strong reason.

---

## Architecture in one line

Deterministic code owns scoring, scaling, safety, and plumbing. The LLM is used *only* to
arrange the weekly plan. Everything is a cron-triggered batch job, not a long-lived agent.

---

## Source-of-truth conventions

- **Eligible recipe pool** = recipes tagged `auto-plan` in Mealie
- **Perishability** = `{"shelf_life_days": N}` in each food's Mealie `extras`; code has a category fallback
- **Pantry staples (free-text recipes)** = mark `__skip__` via `seed_product_map.rb` (press `s` at prompt). Mealie's "On Hand" food flag only fires when the ingredient is linked to a Mealie food object; free-text imported recipes bypass it.
- **The cart** = one Mealie shopping list named **"Next Order"** — meal items, recurring staples, and manual adds all funnel there
- **Recipe tags:** `cuisine:*`, `protein:*`, `effort:quick|project`, `makes-leftovers`
- **State** = SQLite at `data/autochef.db` (gitignored). Food Lion auth = `data/playwright_state.json` (gitignored)

---

## Hard safety rules (never weaken silently)

- `data/PAUSE` file present → no ordering actions run; check first in every ordering path
- Hard `spending_cap_usd` → abort/flag above it
- Out-of-stock → flag, never silently substitute
- Cart total deviates > `cart_deviation_alert_pct` from estimate → re-confirm
- LLM output is always JSON-validated with a deterministic fallback
- Secrets in `.env` only; card data never touches the codebase

---

## Verified state (2026-06-28)

All 6 phases implemented and verified end-to-end against live services. 44 RSpec smoke tests pass.

| Phase | Status |
|---|---|
| 0 — Scaffolding (config, DB, Docker, Uptime Kuma) | ✓ verified |
| 1 — Data layer (MealieClient, sync, tag_recipes.rb) | ✓ verified vs. live Mealie v3.19.2 |
| 2 — Selection (scoring.rb, planner.rb, llm_planner.rb) | ✓ verified vs. live Claude Haiku |
| 3 — Approval (notify.rb Telegram bot, Approve/Swap/Regen) | ✓ verified vs. live Telegram |
| 4 — Shopping list (shopping.rb, shop command, product map) | ✓ verified vs. live Mealie |
| 5 — Cart builder (cart.py, safety.rb, build-cart) | ✓ verified live: 24/24 items, $119.45 |
| 6 — Feedback & polish (feedback.rb, reminders.rb, backup) | ✓ implemented |
| Week configurator (Sinatra form, migration 009) | ✓ running at :3456/week |
| 7 — Auto-checkout | not implemented; leave off indefinitely |

9 ActiveRecord migrations (001–009). See `testing_feedback.md` for full bug/fix history.

---

## Gotchas (append as learned)

**AR 7.2 migration API** — `ActiveRecord::MigrationContext.new` takes three args:
`[path]`, `pool.schema_migration`, `pool.internal_metadata`. The standalone
`ActiveRecord::SchemaMigration` constant was removed in 7.2. See `lib/autochef/database.rb`.

**Week is pickup-day-anchored, not Sunday-anchored.** `pickup_day: "Thu"` in this deployment.
Perishability is measured from Thursday. Seafood (shelf_life: 2d) must land Sun or Mon.

**`config.yaml` week_layout keys load as symbols** (`:Sun`, `:Mon`, etc.) due to
`symbolize_names: true`. Use symbol keys in any code reading `week_layout`.

**Food Lion uses real Chrome, not Playwright's Chromium.** `channel="chrome"` in both
`run_login()` and `setup_context()`. Playwright's bundled Chromium triggers Kasada bot
detection. Chrome must be installed at `/Applications/Google Chrome.app` (local) or via
the Dockerfile (Docker).

**Mealie v3 shopping list endpoints are at `/api/households/`**, not `/api/groups/`.
All six shopping methods in `mealie_client.rb` use the correct v3 paths. Tag PATCH also
requires a full tag object with `slug` + `id`, not just `name`.

**`last_planned` is set on approval, not on draft save.** Moving it back to draft-save
exhausts the eligible pool on repeated plan generations. Only `callback_approve` in
`notify.rb` should set it.

**`CART_BUILDER_PYTHON` must point at the venv Python.** System `python3` won't have
playwright. In Docker, set automatically via `Dockerfile ENV`. Locally:
`export CART_BUILDER_PYTHON="$(pwd)/.venv/bin/python3"` (add to `.env`).
Read at call time (inside `build_cart`), not at require time — `Dotenv.load` runs after require.

**Pantry staples for free-text ingredients** — Mealie "On Hand" flag only works when
ingredients link to Mealie food objects. Free-text imported recipes bypass it. Use `s` at
the `seed_product_map.rb` prompt to mark an ingredient `__skip__`. It's excluded from cart.py
and listed to stdout + Telegram so Bailey can verify stock before pickup.

**HTTParty `timeout:` only sets `open_timeout`.** Use explicit
`open_timeout: 10, read_timeout: 30` on all HTTP verbs in `mealie_client.rb`.

**`mealie_net` is `external: true` in docker-compose.yml.** Create it once
(`docker network create mealie_net`) and attach Mealie's container manually —
Compose won't create or attach it automatically.

**Mealie does not auto-backup.** The nightly `main.rb backup` command must trigger it.

**`store.fulfillment` only accepts `"pickup"`** — intentional, locked via ActiveModel
validator in `StoreConfig`. One-line change to widen if this ever needs to change.
