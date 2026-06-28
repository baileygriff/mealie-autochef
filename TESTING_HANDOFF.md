# Testing & Feedback Agent Briefing — Mealie AutoChef

Paste this file's contents as your opening prompt when starting a new agent session for testing, enhancement, or debugging this project.

---

## Who you are working with

**Bailey Griffin** — Ruby/Rails developer, self-hoster. Primary fluency is Ruby. Python is secondary. When suggesting code, default to Ruby patterns. The one Python file (`cart_builder/cart.py`) stays Python because Playwright's best bindings are Python — that decision is locked, don't suggest replacing it.

Bailey self-hosts on an **Unraid box** (192.168.1.64): Jellyfin (8096), Immich (2283), Pi-hole, Tailscale, Mealie (3000), Uptime Kuma (3001). This project runs in Docker alongside that stack.

Bailey sends screenshots of app behavior and wants help interpreting them, diagnosing issues, and making targeted fixes. He does not want lengthy explanations of things he can already see — get to the diagnosis and fix.

### Working style

- Bailey reviews the app top to bottom across phases, session by session
- He runs commands, shares output or screenshots, and expects targeted diagnosis + fix
- Don't refactor surrounding code or add features beyond what's asked
- When bugs are found mid-flow, fix them before moving on
- Re-run the command after every fix to verify before reporting done

---

## What this project is

**Mealie AutoChef** — a weekly meal-planning → shopping-list → grocery-cart automation.

Flow:
1. Thursday evening: Claude Haiku scores eligible recipes, builds a week plan, sends a Telegram message with inline Approve/Swap/Regenerate buttons
2. Bailey approves via Telegram
3. AutoChef generates a Mealie shopping list + builds a Food Lion To Go pickup cart via Playwright
4. Bailey reviews the cart and taps "Place Order" himself — AutoChef never auto-checks-out (`dry_run: true` is the default and should stay that way)
5. Sunday: Bailey picks up groceries
6. Post-pickup: `main.rb feedback` closes the loop (updates recipe scores based on what was eaten)

Stack: Ruby (ActiveRecord, no Rails), one Python file for Playwright cart automation, Telegram bot for approval UI, Docker on Unraid for production.

---

## Repository layout (key files)

```
mealie-autochef-ruby/
├── main.rb                        # CLI entrypoint — all commands live here
├── config.yaml                    # Week layout, store, schedule, safety settings
├── .env                           # Secrets (never committed)
├── Gemfile / Gemfile.lock
│
├── lib/autochef/
│   ├── config.rb                  # Config loader + validator (raises ConfigError loudly)
│   ├── database.rb                # AR setup, migrations (AR 7.2 API — see gotchas)
│   ├── mealie_client.rb           # All Mealie API calls (paginate, get, post, patch)
│   ├── scoring.rb                 # Recipe scoring (rating, recency, tag affinity)
│   ├── planner.rb                 # Deterministic week layout + perishability ordering
│   ├── llm_planner.rb             # Claude Haiku arrangement layer (wraps planner.rb)
│   ├── notify.rb                  # Telegram bot — polling, inline buttons, approval flow
│   ├── shopping.rb                # Shopping list generation → Mealie list
│   ├── recurring.rb               # Staples / recurring items
│   ├── cart_client.rb             # Ruby side of Ruby↔Python IPC (calls cart.py)
│   ├── safety.rb                  # Spending cap, kill switch, deviation check
│   ├── feedback.rb                # Post-cook feedback signals → recipe_stats
│   ├── reminders.rb               # rufus-scheduler: thaw reminders, morning pings
│   ├── sinatra_prefs_source.rb    # DB-backed prefs provider for week configurator
│   ├── web/app.rb                 # Sinatra week configurator (http://localhost:3456/week)
│   └── models/                    # AR models: RecipeStat, PlanHistory, ProductMap, Budget, WeekPref
│
├── cart_builder/
│   ├── cart.py                    # Playwright Food Lion automation (Python)
│   └── requirements.txt           # playwright>=1.45
│
├── scripts/
│   ├── tag_recipes.rb             # Interactive tagger (run once per new recipe batch)
│   ├── seed_product_map.rb        # Map ingredients → Food Lion search terms
│   └── import_recipes.rb          # Bulk recipe importer (POST+PATCH Mealie API)
│
├── spec/                          # RSpec — 44 examples, all pass, in-memory SQLite
├── data/                          # SQLite DB, playwright_state.json, backups
├── docker/                        # Dockerfile + docker-compose.yml
│
├── HANDOFF.md                     # Orientation doc — read before touching code
├── TESTING_HANDOFF.md             # This file — agent briefing for test/feedback sessions
├── testing_feedback.md            # Bug history, known issues, cart.py state, test suite
├── testing_verifications.md       # Per-feature verification status (✅ tested / ❌ untested / 🔧 needs test)
├── future_enhancements.md         # Full feature specs and priority-ordered backlog
├── README.md                      # Setup and CLI reference
└── docs/
    ├── SETUP_WALKTHROUGH.md       # 10-step first-run guide
    ├── USER_GUIDE.md
    └── DEVELOPER_GUIDE.md
```

---

## Current state as of 2026-06-28 (twelfth session)

| Step | Status | Notes |
|---|---|---|
| `bundle install` | ✓ | 72 gems |
| `.env` filled in | ✓ | All secrets present |
| `config.yaml` filled in | ✓ | See config decisions below |
| `main.rb check` | ✓ | `Result: OK`, Mealie v3.19.2 connected |
| Recipes in Mealie | ✓ | 17 total, 11 tagged for dinner pool |
| Tagged with `auto-plan` + metadata | ✓ | Via API |
| `main.rb sync` | ✓ | 11 recipe stats in local DB |
| Python venv + Playwright | ✓ | `.venv/bin/python3`, playwright 1.60 |
| `CART_BUILDER_PYTHON` in `.env` | ✓ | Points to `.venv/bin/python3` |
| Food Lion login | ✓ | Re-done with full auth + 2FA, `playwright_state.json` refreshed |
| `main.rb plan` (LLM) | ✓ | plan_history id=5 approved (with 1 swap — Pulled Pork → Chicken Breasts) |
| `main.rb serve` | ✓ | Bot + Sinatra form both start cleanly |
| Telegram approval + swap | ✓ | Swap flow + approval both confirmed with plan id=5 |
| `main.rb shop` | ✓ | 35 items pushed to Mealie "Next Order" (plan id=5 recipes) |
| `seed_product_map.rb` | ✓ | Covered by plan id=4; plan id=5 unmapped (Feature 6 now handles this) |
| `main.rb build-cart` | ✓ | 24/24 items added (consolidated), $119.45 total, 0 flagged (plan id=4) |
| Week configurator (Sinatra form) | ✓ | Starts clean; Telegram link TODO until Docker deploy on Unraid |
| Enhancement 2 — LLM qty consolidation | ✓ | `lib/autochef/llm_qty_consolidator.rb`; runs after Enhancement 1 pass |
| Telegram UX: Food Lion link, /shop, screenshot | ✓ | Markdown link, /shop bot command, photo upload |
| `est_total` populated in cart.py output | ✓ | Now set to `cart_total`; deviation_warning can execute |
| Crash alert on plan failure | ✓ | `Notifier.send_crash_alert`; top-level rescue in `cmd_plan` |
| `/wrapup` session skill | ✓ | `.claude/commands/wrapup.md` — updates all docs + commits/pushes |
| `testing_verifications.md` | ✓ | Per-feature verification tracker; linked from README + TESTING_HANDOFF |
| Feature 6 — LLM Assisted Recipe Mapping | ✓ | Verified end-to-end: 35/35 plan id=5 items mapped correctly; bug fixed (key suffix + key mismatch) |
| `/add` multi-item LLM flow | ✓ | `LlmItemParser`, preview + confirm/edit/cancel buttons, triggers cart rebuild on confirm |
| Automap Telegram report reformatted | ✓ | Sectioned: Grocery additions (bullet, qty/unit) + Pantry skips (compact comma list) |
| Docker deployment | **NOT YET** | After confirmed stable local operation |
| Uptime Kuma push URL | **NOT YET** | Bailey needs to create Push monitor in Kuma |

See [testing_feedback.md](testing_feedback.md) for the full bug history, known issues, cart.py state, and test suite details.

---

## Config decisions (important for debugging)

```yaml
# config.yaml — key non-default values
store:
  name: "3415 Avent Ferry Rd, Raleigh, NC 27609"

schedule:
  weekly_run: "Mon 18:00"         # plan generated Monday evenings
  pickup_window_pref: "Thu 17:00-18:00"
  pickup_day: "Thu"               # CHANGED from default Sun

meals:
  week_layout:
    Sun: cook
    Mon: cook
    Tue: leftover
    Wed: cook
    Thu: leftover
    Fri: cook
    Sat: leftover

safety:
  dry_run: true                   # always — never auto-checkout
  spending_cap_usd: 300
```

Pickup is **Thursday**, not Sunday. Perishability-aware scheduling means seafood/fish recipes should land Sun or Mon (1–2 days post-pickup). If you see scheduling warnings about perishable items landing late in the week, that's why.

---

## How to run things

```bash
# Check config + DB + Mealie connectivity
bundle exec ruby main.rb check

# Generate this week's plan (sends Telegram message with buttons)
bundle exec ruby main.rb plan

# Start the Telegram bot (long-running — handles Approve/Swap/Regen buttons)
# Also starts Sinatra week configurator on port 3456 (http://localhost:3456/week)
bundle exec ruby main.rb serve

# After approving — generate Mealie shopping list
bundle exec ruby main.rb shop

# Build Food Lion cart (requires playwright_state.json and CART_BUILDER_PYTHON)
bundle exec ruby main.rb build-cart

# Post-pickup feedback
bundle exec ruby main.rb feedback

# Backup SQLite DB to data/backups/
bundle exec ruby main.rb backup

# Run test suite
bundle exec rspec

# Import new recipes to Mealie
bundle exec ruby scripts/import_recipes.rb

# Interactive recipe tagger
bundle exec ruby scripts/tag_recipes.rb --untagged

# Seed product map (requires an approved plan in DB)
bundle exec ruby scripts/seed_product_map.rb
```

---

## Key gotchas before touching code

**AR 7.2 migration API** — `ActiveRecord::MigrationContext.new` takes 3 args: `[path]`, `pool.schema_migration`, `pool.internal_metadata`. The standalone `ActiveRecord::SchemaMigration` constant was removed in 7.2. See `lib/autochef/database.rb`.

**Week is pickup-day-anchored, not Sunday-anchored.** `pickup_day: "Thu"` — perishability is measured from Thursday's pickup date. Seafood has 2-day shelf life → assigned Sun or Mon.

**`config.yaml` week_layout keys load as symbols** (`:Sun`, `:Mon`, etc.) due to `symbolize_names: true` in the YAML loader. If you add code that reads `week_layout`, use symbol keys.

**`CART_BUILDER_PYTHON` must point at the venv Python** — system `python3` won't have playwright installed. Current value in `.env`: `/Users/baileygriffin/Projects/mealie-autochef-ruby/.venv/bin/python3`. In Docker, this is set by the Dockerfile.

**Food Lion uses Chrome, not Playwright's Chromium** — `channel="chrome"` in both `run_login()` and `setup_context()`. If you see bot detection errors again, check that Chrome is installed at `/Applications/Google Chrome.app`.

**`dry_run: true` is the default and must stay that way** — AutoChef builds the cart and stops. Bailey places the order. Don't change this.

**Mealie is at port 3000** on `192.168.1.64` (not the default 9000). In Docker it's `http://mealie:9000` on `mealie_net`. `MEALIE_URL` in `.env` overrides `config.yaml` for local dev.

**`last_planned` is set on approval, not on draft save** — this was a bug fixed 2026-06-28. Don't move it back. Drafts only update `times_planned`.

**`LlmRecipeMapper` uses numbered items + index echo** — items sent as `1. {note}`, `2. {note}`, ...  and the LLM must return `"index": N` in each response. The save loop uses `unmapped[index - 1]['note']` as the product_map key, NOT `s['ingredient_name']`. This ensures keys match what `resolve_cart_item` looks up (the full Mealie note). Do not revert to using `s['ingredient_name']` as the key — it strips quantity prefixes and breaks the lookup.

**`/add` flow with LLM enabled** — `cmd_add` routes to `cmd_add_llm` which shows a preview with [✅ Add to cart] [✏️ Edit] [❌ Cancel] buttons before touching Mealie. Pending state `{ action: :waiting_add_confirmation, items: [...] }` is stored in `@pending_states[chat_id]`. Confirmation triggers `execute_add_items` which saves ManualAddition records, pushes to Mealie, and spawns `build-cart --force` in a background thread.

---

## What to do when Bailey sends a screenshot

1. **Read the screenshot carefully** — look for error messages, unexpected output, missing data, wrong values, UI state
2. **Identify the command or flow** — which `main.rb` command or which script produced this?
3. **Locate the relevant file** — use the file map above to narrow down fast
4. **Check [testing_feedback.md](testing_feedback.md) known issues** — it might be a documented limitation
5. **Make a targeted fix** — don't refactor surrounding code, don't add features, fix what's broken
6. **Re-run the command** to verify the fix works before reporting done
7. If the screenshot shows a **Telegram message**, it came from `lib/autochef/notify.rb`
8. If it shows a **plan output in terminal**, it came from `main.rb`'s `cmd_plan` / `lib/autochef/planner.rb` / `lib/autochef/llm_planner.rb`
9. If it shows a **Food Lion browser**, it came from `cart_builder/cart.py`

---

## What's coming next

**Rule: address feedback and improvements first, then new features.** See [future_enhancements.md](future_enhancements.md) for full specs.

### New features (feedback items 1–4 cleared in ninth session; Feature 6 verified in twelfth)
5. Debug screenshots
6. ✅ LLM Assisted Recipe Mapping — verified twelfth session; bug fixed (product_map key mismatch)
7. LLM Cart Review (auto after build-cart, screenshot+vision, auto-apply corrections)
8. LLM Aided Shopping (toggleable via Telegram, PreferenceNote model, skip+note on bad match)
9. Recipe Sleep feature
10. LLM Recipe Suggestions (`/newrecipes`)

### Added this session
- ✅ `/add` multi-item LLM flow — `LlmItemParser`, preview/confirm/edit/cancel, cart rebuild on confirm (`lib/autochef/llm_item_parser.rb`, `lib/autochef/notify.rb`)
- ✅ Automap Telegram report reformatted — Grocery additions section (search_term + qty/unit) + Pantry skips (compact comma list)

### Infrastructure (after stable local operation)
11. Docker deployment on Unraid
12. Uptime Kuma push monitor
13. MCP setup

---

## When starting a new session

1. Read this file in full
2. Read [testing_feedback.md](testing_feedback.md) — known issues and recent bugs
3. Read [testing_verifications.md](testing_verifications.md) — per-feature verification status
4. Read [future_enhancements.md](future_enhancements.md) — the full feature queue with specs
5. Run `bundle exec ruby main.rb check` to verify connectivity
6. Check DB state:
   ```bash
   bundle exec ruby -e "
     require_relative 'lib/autochef/database'
     Autochef::Database.connect!
     require_relative 'lib/autochef/models/plan_history'
     require_relative 'lib/autochef/models/product_map'
     puts \"Pending plans: #{Autochef::Models::PlanHistory.where(approved: 0).count}\"
     puts \"Product map entries: #{Autochef::Models::ProductMap.count}\"
   "
   ```
7. Pick up from "What's coming next" above — **feedback items before new features**

At the end of each session, update this file: mark completed steps, add newly discovered bugs, and update "What's coming next." Move bug details to [testing_feedback.md](testing_feedback.md). Move new feature specs to [future_enhancements.md](future_enhancements.md).
