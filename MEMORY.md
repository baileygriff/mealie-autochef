# MEMORY.md — Mealie AutoChef

> Persistent project context for any agent picking this up. Read this first, then `MEALIE_AUTOMATION_PLAN.md` for the full spec. Keep this file short and current; append durable facts and gotchas as they're learned.

## What this is
A weekly meal-planning → shopping-list → grocery-cart automation for a self-hosted **Mealie** instance, with a human approval gate and **manual final checkout**. Store: **Food Lion**, **pickup**. Runs in Docker on an **Unraid** server next to an existing media/self-hosting stack (Jellyfin, Immich, Pi-hole, Tailscale, etc.).

## Locked decisions (don't relitigate without reason)
- **Pickup**, not delivery. Cart flow targets Food Lion To Go pickup + slot selection.
- **Dinner first**, lunch-expandable, no breakfast. `meal_types` is a list; ship `[dinner]`.
- **Claude `claude-haiku-4-5`** for the weekly draft. ~$0.03/week. Don't self-host a model on this box (16GB RAM, already loaded). Sonnet is a one-line config bump if quality needs it.
- **Manual checkout** (`dry_run: true`). System builds the cart and stops. Auto-checkout is opt-in Phase 7 and probably stays off.
- **Playwright (Python)**, not an AI browser agent, for the cart step. Boring + reliable wins for the money-adjacent unattended step.
- Default **servings = 2**, per-meal override.
- **Telegram** (not ntfy) for approval/notify — the spec's approval gate and manual-add flow assume inline buttons + slash commands, which ntfy can't natively do.
- **Ruby (plain Ruby + ActiveRecord/ActiveModel, no Rails app), not Python** — switched after Phase 0's first pass, because Bailey's primary fluency is Ruby/Rails. The ONE exception is `cart_builder/cart.py`: Playwright's official, best-supported bindings are Python (Node/Java/.NET also beat Ruby's community wrapper), and the cart builder is already the most fragile part of the system — not the place to add a second "less-proven library" risk. Ruby talks to it via subprocess + JSON over stdin/stdout (`lib/autochef/cart_client.rb` ↔ `cart_builder/cart.py`); see that file pair for the documented IPC contract. No Rails app shell (no controllers/views) — this is a CLI batch job, and ActiveRecord/ActiveModel work fine standalone via `establish_connection`.

## Architecture in one line
Deterministic code owns scoring/scaling/safety/plumbing; the LLM is used *only* to arrange the weekly plan (nuance + variety + perishability order). Everything is a cron-triggered batch job, not a long-lived agent.

## Source-of-truth conventions
- **Eligible recipe pool** = recipes tagged `auto-plan` in Mealie.
- **Perishability** lives in each **food's `extras`** as `{"shelf_life_days": N}`; code has a category fallback.
- **Pantry staples** = Mealie food **"On Hand"** flag (auto-excluded from lists). No separate config.
- **The cart** = one Mealie shopping list named **"Next Order"**. Meal items, recurring staples, and manual adds all funnel there. Cart builder reads only this list.
- **Tags:** `cuisine:*`, `protein:*`, `effort:quick|project`, `makes-leftovers`.
- **State** = SQLite at `data/autochef.db` (gitignored). **Food Lion auth** = `data/playwright_state.json` (gitignored).

## Why pickup is the only automation target
Food Lion has no first-party ordering API. "Food Lion To Go" is Instacart-powered, and Instacart's developer APIs are partner-facing (embed fulfillment / build shoppable links), not for placing orders on a personal account. So the storefront UI is the only path → browser automation → keep a human at checkout.

## Hard safety rules (never weaken silently)
- `data/PAUSE` file present → no ordering actions run. Check it first in every ordering path.
- Hard `spending_cap_usd` → abort/flag above it.
- Out-of-stock → flag, never silently substitute up in price.
- Cart total deviates > `cart_deviation_alert_pct` from estimate → re-confirm.
- LLM output is always JSON-validated with a deterministic fallback.
- Secrets in `.env` only; card data never touches the codebase (entered once in the Food Lion account, ideally a dedicated low-limit card).

## Gotchas / lessons (append as learned)
- Mealie does **not** auto-backup — our nightly job must trigger it.
- Opus-4.7+ tokenizers can use up to ~35% more tokens; we're on Haiku so cost stays trivial, but don't assume token counts across model families.
- Perishability scheduling is anchored to `pickup_day`: a recipe is only valid on a cook day if `shelf_life_days >= (cook_day_index − pickup_day_index)`. Flag violations in the approval message.
- The cart builder is the most fragile piece; expect selector breakage on Food Lion/Instacart UI changes. This is the expected maintenance surface.
- `lib/autochef/config.rb` hard-rejects `store.fulfillment != "pickup"` via an ActiveModel inclusion validator, per the locked decision above. If this ever needs to change, it's one validator to widen in `StoreConfig` — but treat that as a deliberate, discussed change, not a quick patch.
- Dockerfile installs Playwright + Chromium in Phase 0 (not deferred to Phase 5), to avoid a slow rebuild later. Trade-off: heavier image from day one.
- `mealie_net` is declared `external: true` in `docker-compose.yml` — it must be created once (`docker network create mealie_net`) and Mealie's own container must be attached to it separately. Compose won't create or attach it automatically.
- **ActiveRecord 7.2 migration API fix (applied):** `ActiveRecord::Base.connection` does not have `migration_context`; use `ActiveRecord::Base.connection_pool.migration_context`. Also `ActiveRecord::SchemaMigration` is no longer a class constant usable as a constructor arg — get `schema_migration` and `internal_metadata` from the pool: `ActiveRecord::MigrationContext.new([path], pool.schema_migration, pool.internal_metadata).migrate`. This fix is in `lib/autochef/database.rb`.
- `cart_client.rb` resolves the Python interpreter via `CART_BUILDER_PYTHON` env var (defaults to bare `python3` on PATH). In Docker this is set automatically to the venv path; running locally outside Docker, export it yourself after creating `cart_builder`'s venv (see README setup step 4) or it'll try to use system Python, which won't have `playwright` installed.

## Build status
- [x] Phase 0 — scaffolding (config + DB verified: `bundle install` ran clean, all 7 migrations applied, `main.rb check` shows config/DB OK; Mealie connectivity is PARTIAL — expected until deployed on `mealie_net` / Docker)
- [ ] Phase 1 — data layer
- [ ] Phase 2 — selection (scorer + planner + LLM draft)
- [ ] Phase 3 — Telegram approval + manual add
- [ ] Phase 4 — shopping list (scaling, staples, product map)
- [ ] Phase 5 — Playwright cart builder + safety
- [ ] Phase 6 — feedback, reminders, backups
- [ ] Phase 7 — (optional) auto-checkout — leave off unless justified

## Still needed from owner before first real run
Preferred store · pickup day/time + weekly run time · week layout (cook/leftover/out/skip) · ~~notify channel (Telegram vs ntfy)~~ **decided: Telegram** · dedicated card + cap amount · dislikes/allergies · initial staples + cadences · keep protein weighting on?
