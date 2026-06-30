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
├── spec/                          # RSpec — 50 examples, all pass, in-memory SQLite
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

## Current state as of 2026-06-30 (twenty-fifth session)

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
| Testing practice standard | ✓ | Documented in "Testing practice" section; decision table, pre-define success/failure, prefer specs |
| `spec/manual_addition_spec.rb` | ✓ | 6 examples; tests ManualAddition model, resolve logic, pending scope (50 total, 0 failures) |
| Previous Purchases URL fix | ✓ | `PREV_PURCHASES_URL` corrected to `/past-purchases`; `SEL_MY_ITEMS_LINK` updated; tab click removed |
| Session expiry detection (Option 1) | ✓ | `detect_session_state()` in `cart.py`; `session_expired` status; Telegram alert + inline rebuild button |
| `detect_session_state` happy path | ✓ | Confirmed via live run: session valid, run continued normally; now logs "Session check: valid" |
| `cart_builder/probe_pp.py` | ✓ | Diagnostic tool — navigates to Past Purchases, tries all selectors, dumps inventory; 30s, no cart ops |
| PP horizontal carousel scroll | ✓ | `_collect_prev_purchase_items` scrolls `.pdl-carousel_slider` / `.pdl-carousel_container` |
| Previous Purchases card selectors | ✓ | Confirmed via probe (seventeenth session): `li.product-grid-cell` (66 cards), `[class*="product-tile_detail-title"]`; live `build-cart --force` still needed to verify matching + add |
| Previous Purchases live verification | ✓ | `build-cart --force` (eighteenth session): 66 cards found, 3/24 from PP, 21 via search; $102.86, 0 flagged |
| Telegram screenshot photo send | ✓ | Fixed `File.open` → `Faraday::UploadIO.new(path, 'image/png')` in `notify.rb` |
| Application Orchestrator Refactor — Section 1 | ✓ | `lib/autochef/errors.rb` — unified error hierarchy; `ConfigError` moved here from config.rb; 50/50 specs green |
| Cart Builder Package Refactor — Step 2 | ✓ | Python skeleton: `cart_builder/__init__.py`, `base.py` (GroceryProvider ABC + types), `providers/__init__.py`, `tests/__init__.py`, fixture JSON files |
| Feature 16 — Nutrition Goals & Macro-Aware Planning | 🗂️ | Spec in [docs/features/feature_16_nutrition_goals.md](docs/features/feature_16_nutrition_goals.md) |
| CapSolver Kasada auto-solving (Option 2) | 🔧 | Detection now works; CapSolver fires but fails — `CAPSOLVER_PROXY` required (CapSolver routes request from proxy IP; without it: `InvalidRequestError`). Need proxy at Bailey's outgoing IP (70.131.45.67). |
| Automated login flow (`--login`) | 🔧 | `run_login()` auto-fills credentials; timing fix applied (7s wait); blocked until proxy is set (CapSolver still needed to solve login Kasada) |
| Debug screenshots | ✓ | Per-step screenshots in `data/cart_screenshots/<run_key>/`; rolling 2-run cleanup; `01_store_loaded.png` now captures page state at the Kasada detection point |
| Cart Builder Package Refactor — Steps 3–6 | 🗂️ | Spec in [docs/features/improvement_cart_builder_refactor.md](docs/features/improvement_cart_builder_refactor.md) |
| Application Orchestrator Refactor — Sections 2–8 | 🗂️ | Spec in [docs/features/improvement_orchestrator_refactor.md](docs/features/improvement_orchestrator_refactor.md) |
| Feature backlog refactor + new features 21–24 | ✓ | All specs migrated to `docs/features/`; Features 21–24 + Doc 01 added as placeholders |
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

**Past Purchases URL is confirmed** — Food Lion's past purchases page is at `https://www.foodlion.com/past-purchases` (confirmed 2026-06-28; `PREV_PURCHASES_URL` updated). There is no "My Items" tab — it's a direct page in the top nav under "Past Purchases". `SEL_PREV_PURCHASES_TAB` is now an empty list (no tab click needed). `SEL_PREV_PRODUCT_CARD` and `SEL_PREV_PRODUCT_NAME` are still best-guess Instacart DOM patterns — if the Previous Purchases pass reports 0 items found despite real past purchases being present, **run `probe_pp.py` first** (see below), not a full `build-cart --force`. The feature falls back to full search if it finds 0 cards — existing behavior is never regressed.

**Past Purchases page uses a horizontal carousel, not vertical scroll.** First live `build-cart --force` run confirmed `available=0` — the page arranges product cards side-by-side in a horizontally scrollable container. `_collect_prev_purchase_items` now runs JS to scroll carousel containers (`[data-testid*="carousel"]`, `[data-testid*="items-container"]`, `[class*="carousel"]`) horizontally before falling back to window vertical scroll. Card selectors still unverified against the live carousel DOM.

**Use `probe_pp.py` for PP selector investigation, not `build-cart --force`.** `cart_builder/probe_pp.py` is a ~30-second targeted diagnostic: opens Chrome with saved auth, navigates to Past Purchases, reports all horizontally-scrollable containers, tries every card/name selector before and after scrolling, dumps the full `data-testid` inventory. Run it with `source .venv/bin/activate && python3 cart_builder/probe_pp.py` and paste the output to determine which selectors need updating. Only run `build-cart --force` after selectors are confirmed via the probe.

**Food Lion sessions expire frequently — possibly within hours.** The Kasada bot-detection challenge (or actual cookie expiry) can trigger on any new build-cart run. `detect_session_state()` in `cart.py` now catches this early (immediately after `navigate_to_store`) and returns `"session_expired"` with `abort_reason: "kasada_challenge"` or `"login_required"` instead of crashing. `main.rb` sends a Telegram alert with a `[✅ Session Refreshed — Rebuild Cart]` inline button. To fix: run `source .venv/bin/activate && python3 cart_builder/cart.py --login`, solve the challenge, log in, complete 2FA, press Enter. Then tap the Telegram button to rebuild. See Option 2 (CapSolver) in `future_enhancements.md` for a fully automated path.

**FlareSolverr cannot solve Kasada.** FlareSolverr (already on Unraid) is Cloudflare-specific (CF_Clearance / Turnstile). Food Lion uses Kasada — a different vendor. FlareSolverr has no Kasada support and cannot be used here. CapSolver is the right tool for Option 2.

**Kasada fires asynchronously after page load — `run_build_cart()` now waits 6s before detection.** Food Lion's SPA renders the search bar briefly before Kasada JS fires and overlays the page (~2–5s after load). The fix (twenty-fifth session): `pace(6000)` is called after `navigate_to_store()` and before `detect_session_state()`, ensuring Kasada has had time to overlay the page before we check. `run_login()` uses a 7s wait. Screenshot `01_store_loaded.png` is taken after the wait so it shows the actual state at detection time.

**Kasada also fires on subsequent store page loads mid-build.** `add_from_previous_purchases()` ends with `page.goto(FOODLION_TOGO_URL)` — Kasada can fire on that return navigation too. Fix (twenty-fifth session): a 3s re-check is run after PP returns, before the search loop. Additionally, `add_item_to_cart()` calls `detect_session_state()` if the search bar fill fails — if Kasada is detected, the search loop aborts immediately rather than timing out on all remaining items.

**`detect_session_state()` uses search bar visibility as the primary Kasada indicator (twenty-fifth session).** The Kasada slider challenge replaces the page content but `document.body.innerText` returns empty `''` (content hidden in shadow DOM or similar). The search bar visibility check (`page.locator(SEL_SEARCH[0]).is_visible()`) is what reliably catches all Kasada variants — if the search bar is gone after the wait, Kasada is active. Other checks (frame URLs, DOM attributes, title, body text, slider text) are tried first as faster paths. Detection now logs url, title, and body[:150] for debugging.

**CapSolver `AntiKasadaTask` requires a proxy pointing to Bailey's outgoing IP.** CapSolver needs to make the Kasada-solving request from the same IP the browser uses (70.131.45.67 based on the challenge page). Without a proxy, the API returns `InvalidRequestError: unable to process task request`. Set `CAPSOLVER_PROXY` in `.env` to an HTTP/SOCKS5 proxy that routes through Bailey's outgoing IP. Options: run `tinyproxy` or `squid` on Unraid and port-forward, or use a commercial proxy at that IP. Until this is set, CapSolver falls back to Option 1 (Telegram alert for manual refresh).

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

## Testing practice

**Minimum representative testing.** Chrome/Playwright runs are slow (2–5 min each), Mealie API calls require live connectivity, and the overall pipeline is long. Run the full pipeline only when you actually need to validate end-to-end behavior. For everything else, find the shortest feedback loop that genuinely tests the thing you care about.

**Autonomous testing standard.** The agent runs tests itself whenever possible — it doesn't ask Bailey to run commands and paste output. After implementing a change, the agent runs the appropriate test, analyzes the result, and reports findings. Bailey is only asked when the agent genuinely cannot proceed alone (see "Bailey's involvement" column below).

**Decision guide — who runs what:**

| What you're verifying | Preferred approach | Bailey's involvement |
|---|---|---|
| Ruby model behavior, DB queries, scopes | `bundle exec rspec` (in-memory SQLite, < 1s) | None — agent runs and reports |
| A new Ruby helper / utility function | Write a unit spec; don't run main.rb | None |
| Config loading / validation | `bundle exec rspec spec/config_spec.rb` | None |
| Mealie API path / JSON parsing | `main.rb check` (< 5s) | None |
| Shopping list generation | `main.rb shop` (fast, no browser) | None |
| Cart-building logic (no browser) | Spec the Ruby side (consolidation, resolve_cart_item, etc.) | None |
| Session state check | `python3 cart_builder/probe_pp.py`-style probe script | None |
| Previous Purchases selector investigation | `python3 cart_builder/probe_pp.py` (30s, no cart ops) | None |
| End-to-end cart build with browser | `main.rb build-cart --force` — agent runs, watches output | Bailey watches browser if he wants; no interaction required |
| Plan generation + Telegram flow | `main.rb plan` | Bailey approves in Telegram |
| Food Lion login / session refresh | `python3 cart_builder/cart.py --login` | Bailey enters 2FA code when terminal prompts |
| External account setup (CapSolver, Kuma, etc.) | N/A — agent can't create accounts | Bailey does this; agent picks up after |

**Check in between building and testing, not instead.** After implementing a change, the agent checks in ("here's what I built, running the test now…") and immediately proceeds — it doesn't wait for approval to run tests it can handle itself. It only stops for Bailey when it hits a genuinely human-gated step.

**Pre-define success and failure before running.** Before any test (especially a browser run):
- State what output / log line / DB state counts as success
- State what counts as failure
- State what you'll do if the result is ambiguous

**Prefer specs over live runs for new Ruby code.** Any new function that can be tested without a browser, a live Mealie instance, or real Telegram credentials should have an RSpec example before it's considered done. Use the in-memory DB + existing spec_helper fixtures. See `spec/manual_addition_spec.rb` for an example of testing model + resolve logic without loading all of main.rb.

**If genuinely stuck — stop and ask.** Don't grind through a 5-minute browser run hoping it'll reveal the problem. Don't make assumptions about what Bailey would want. A short question saves everyone time.

**See [future_enhancements.md § Cart Builder Package Refactor](future_enhancements.md) and [§ Application Orchestrator Refactor](future_enhancements.md) for the two planned refactors that will make this codebase fully unit-testable without live dependencies.**

---

## What's coming next

**Rule: address feedback and improvements first, then new features.** See [future_enhancements.md](future_enhancements.md) for full specs.

### New features (feedback items 1–4 cleared in ninth session; Feature 6 verified in twelfth)
5. ✅ Debug screenshots — implemented twenty-fourth session; [spec](docs/features/improvement_debug_screenshots.md)
6. ✅ LLM Assisted Recipe Mapping — verified twelfth session; bug fixed (product_map key mismatch)
7. **Cart Review, Auto-Fix + /cart-correction** — [spec](docs/features/feature_07_cart_review.md)
8. LLM Aided Shopping — [spec](docs/features/feature_08_llm_aided_shopping.md)
9. Recipe Sleep feature — [spec](docs/features/feature_09_recipe_sleep.md)
10. LLM Recipe Suggestions (`/newrecipes`) — [spec](docs/features/feature_10_newrecipes.md)
11. **Recipe Telegram Commands** (`/recipelist`, `/recipe`) — [spec](docs/features/feature_11_recipe_commands.md)
16. Nutrition Goals & Macro-Aware Planning — [spec](docs/features/feature_16_nutrition_goals.md)
17. Recipe Display Refactor (depends on F16) — [spec](docs/features/feature_17_recipe_display_refactor.md)
18. Dietary Preferences in Recipe Searcher ❓ interview needed — [spec](docs/features/feature_18_dietary_preferences.md)
19. Web UI ❓ interview needed — [spec](docs/features/feature_19_web_ui.md)
20. Multi-user Support ❓ interview needed — [spec](docs/features/feature_20_multi_user.md)
21. AI Spend Kill Switch ❓ interview needed — [spec](docs/features/feature_21_ai_spend_killswitch.md)
22. `/set-meal` Manual Recipe Selection ❓ interview needed — [spec](docs/features/feature_22_set_meal.md)
23. Telegram Command Audit & NLP Generalization ❓ interview needed — [spec](docs/features/feature_23_telegram_command_audit.md)
24. Streamline Telegram User Flow ❓ interview needed — [spec](docs/features/feature_24_telegram_ux_flow.md)
- Doc 01: Pipeline Documentation ❓ interview needed — [spec](docs/features/doc_01_pipeline_documentation.md)

### Infrastructure
12. **Unraid Docker Display (Xvfb)** — [spec](docs/features/infra_12_xvfb.md)
13. Docker Deployment on Unraid (depends on Xvfb) — [spec](docs/features/infra_13_docker_deploy.md)
14. Uptime Kuma push monitor — [spec](docs/features/infra_14_uptime_kuma.md)
15. MCP Setup — [spec](docs/features/infra_15_mcp.md)

### Added this session (twenty-fifth)
- ✓ **Kasada detection timing fix** — `pace(6000)` in `run_build_cart()` and `pace(7000)` in `run_login()` before `detect_session_state()`. Kasada fires ~2–5s after page load; fixed wait ensures challenge is overlaying before we check. `01_store_loaded.png` taken after wait.
- ✓ **`detect_session_state()` overhaul** — search bar `is_visible()` is now the primary Kasada indicator (Kasada empties `body.innerText`). Layers: frame URL → DOM attributes → title keywords → `page.evaluate(body.innerText)` → slider text → search bar visibility → sign-in button. Logs url/title/body[:150].
- ✓ **Pre-search-loop re-check** — 3s wait + `_handle_session_state` after PP returns, before search loop. Aborts immediately if Kasada fires on the return navigation.
- ✓ **Fail-fast Kasada in `add_item_to_cart()`** — if search bar fill fails, calls `detect_session_state()`; returns `"kasada_challenge"` immediately and search loop aborts. Eliminates 5 selectors × 6s × N items of stall time.
- ✓ **Ruby `session_expired` crash fix** — removed `write_order_history()` call for `session_expired` branch in `main.rb`; `OrderHistory` validates status and `session_expired` isn't in the allowed list.
- 🔧 **CapSolver proxy support** — `CAPSOLVER_PROXY` env var added; `solve_kasada_challenge()` passes it to `AntiKasadaTask`. Without proxy, CapSolver returns `InvalidRequestError`. Proxy at Bailey's outgoing IP (70.131.45.67) still needed.

### Added this session (twenty-fourth)
- ✓ **Debug screenshots** — `_debug_screenshot()` and `_rolling_cleanup_debug_dirs()` helpers added to `cart.py`. `run_build_cart()` now captures: `01_store_loaded.png` (after `navigate_to_store`, before `detect_session_state` — key shot for Kasada timing debug), `02_cart_cleared.png`, `03_pickup_mode.png`, `04_slot_selected.png`, `05_item_NN_<term>.png` per successful search-based add, `06_cart_summary.png`, `error.png` on exception. All screenshots go into `data/cart_screenshots/<run_key>/`. Rolling cleanup keeps last 2 run directories (`shutil.rmtree` on oldest). `DEBUG_SCREENSHOTS_PATH` env var documented in `.env.example` as a placeholder for optional copy-to-NAS behavior (not yet implemented). RSpec: 50/50 green, no Ruby changes.
- ✓ **Spec updated** — `docs/features/improvement_debug_screenshots.md` now shows ✅ status with actual directory layout and rolling window behavior.

### Added this session (twenty-third)
- 🔧 **CapSolver Kasada auto-solving** — `solve_kasada_challenge()` implemented in `cart.py`; `AntiKasadaTask` confirmed supported; CapSolver account set up ($6 balance); `capsolver>=1.0.0` in `requirements.txt`; `CAPSOLVER_API_KEY` in `.env` and `.env.example`. Code runs but CapSolver never fired in testing — Kasada detection timing issue means challenge is detected too early (before Kasada overlays the page). See gotcha above.
- 🔧 **Automated login flow** — `run_login()` now auto-fills `FOODLION_USERNAME`/`FOODLION_PASSWORD` from `.env`, solves Kasada via CapSolver at each step, and pauses only for 2FA. New selectors: `SEL_SIGNIN_LINK`, `SEL_EMAIL_INPUT`, `SEL_PASSWORD_INPUT`, `SEL_LOGIN_CONTINUE`, `SEL_LOGIN_SUBMIT`. Falls back to manual mode if credentials absent.
- ✓ **`detect_session_state()` improved** — added body-text detection for Kasada "Verification Required" variant (image/audio challenge page); added `"verification required"` to title keyword list.
- ✓ **Async Kasada detection guard** — `run_build_cart()` now uses `wait_for(state="visible", timeout=5000)` on the search bar after initial session check; if search bar not visible, re-runs `detect_session_state()`. Still not reliable (see timing gotcha).
- ✓ **Autonomous testing standard** — "Testing practice" section rewritten; agent now runs all tests itself and only checks in with Bailey for 2FA, Telegram approvals, and external account setup. `feedback_autonomous_testing.md` saved to memory.

### Added this session (twenty-second)
- ✓ **Feature priority section added to `future_enhancements.md`** — reviewed all pending TODOs across feedback/improvements, features, and infrastructure. Added three-tier priority table: Tier 1 (all remaining Feedback/Improvements in order: CapSolver → Cart Builder Refactor → Orchestrator Refactor → Debug Screenshots), Tier 2 (new features ordered by impact/effort: Recipe Sleep → Recipe Commands → Cart Review → Nutrition Goals → /newrecipes), Tier 3 (interview-needed items + infrastructure). New feature rule baked in: any item added to backlog must be assigned a tier immediately; default is Tier 3. No code written, no specs changed, no tests run.

### Added this session (twenty-first)
- ✓ **Feature backlog fully migrated to `docs/features/`** — all inline specs extracted to individual files. `future_enhancements.md` is now a clean index table with links and status indicators (🗂️ = complete spec, ❓ = placeholder/interview needed).
- 🗂️ **Features 21–24 added to backlog** with placeholder specs: AI Spend Kill Switch (21), `/set-meal` Manual Recipe Selection (22), Telegram Command Audit & NLP Generalization (23), Streamline Telegram User Flow (24). Each placeholder includes what Bailey described + open questions for the next spec interview.
- 🗂️ **Doc 01 added**: Pipeline Documentation & Architecture Diagrams — placeholder spec with format/audience questions.
- ✓ **`cspell.json` updated** — added `killswitch`, `Xvfb`, `xvfb`, `Mermaid`, `mermaid`, `multiuser`, `setmeal`, `NlpCommand`, `nlp`.
- ✗ **Feature: Bundle Mealie into Docker** — evaluated and scrapped. Mealie and autochef stay as separate containers.

### Added this session (twentieth)
- 🗂️ **Feature 16 — Nutrition Goals & Macro-Aware Planning** — fully specced via deep interview. Spec in `docs/features/feature_16_nutrition_goals.md`. 4-macro storage in `recipe_stats`, 3-tier scorer redesign (0–10 dials, ×100/×10/×1 multipliers), per-macro ⚠️ flags in plan draft, `/newrecipes` macro context hook, `scripts/backfill_macros.rb`.
- 🗂️ **Feature 17 stub** — Recipe Display Refactor. Depends on Feature 16.
- ✓ **`/plan-remaining` skill written** — `.claude/commands/plan-remaining.md`.

### Added this session (nineteenth)
- 🗂️ **Feature 7 spec revised: Cart Review, Auto-Fix + /cart-correction** — fully supersedes old Feature 7 (LLM Cart Review). New spec in `future_enhancements.md § 7`: per-item `items_added` output from cart.py, `LlmCartReviewer` (vision LLM), one-attempt auto-fix for clear wrong products/variants, structured review table in cart-ready message (Needs attention / Quantity notes / Auto-corrected / High confidence), `/cart-correction` natural language command → correction preview → product_map update → build-cart --force → fresh table.
- 🗂️ **Feature 11 spec: Recipe Telegram Commands** — `/recipelist` (cook days from current approved plan, local DB only) and `/recipe` (by day or fuzzy title against current week, full Mealie recipe with scaled ingredients + instructions, split across 2 messages if long, inline button disambiguation). Scope limited to current week; global `/recipepool` search is a logged future item. LLM-woven ingredient-in-instructions format also logged as Phase 2 future item.
- 🗂️ **Infrastructure 12 spec: Unraid Docker Display (Xvfb)** — `apt-get install xvfb`, `docker/entrypoint.sh` starts `Xvfb :99` before main process, `DISPLAY=:99` in compose env vars. Must be done before Docker deployment on Unraid. Local dev unchanged. Full verification steps documented.
- ✓ **`recipelist` added to `cspell.json`** — spell-check word list updated.

### Added this session (eighteenth)
- ✓ **Previous Purchases live `build-cart --force` verified** — 66 cards found via `li.product-grid-cell`; 3/24 items matched from Previous Purchases (chicken thighs 75%, lemons 100%, parmesan 67%); 21 via search. $102.86 total, 0 flagged. PP optimization is fully verified end-to-end. Note: word-overlap matcher doesn't distinguish chicken cuts (thighs matched for "bone-in skin-on chicken breast") — known fuzzy-match limitation, not a bug.
- ✓ **Bug fix: Telegram screenshot photo send** — `File.open(path, 'rb')` was passed raw to Faraday's multipart middleware, which couldn't encode it correctly; Telegram received a string and rejected it as an invalid file identifier. Fixed: `Faraday::UploadIO.new(path, 'image/png')` — the proper Faraday multipart type. `notify.rb` line 147.

### Added in seventeenth session
- ✓ **PP selectors confirmed via `probe_pp.py`** — Food Lion uses PDL (Peapod Digital Labs) components with no `data-testid` attributes. Probe found `li.product-grid-cell` (66 cards) as card selector and `[class*="product-tile_detail-title"]` as name selector. Name text stripped at first `\n` (PDL button embeds price suffix). Carousel JS scroll updated to target `.pdl-carousel_slider` explicitly. `probe_pp.py` updated with confirmed selectors as primary entries.
- ✓ **Application Orchestrator Refactor — Section 1 (`errors.rb`)** — `lib/autochef/errors.rb` created with unified error hierarchy: `Autochef::Error` base, `ConfigError`, `LlmError`, `MealieError`, `PlanError`, `ShopError`, `FeedbackError`, `CartError`, `SessionExpiredError` (with `reason` attr), `SpendingCapError` (with `total`/`cap` attrs). `ConfigError` removed from `config.rb`; `require_relative 'errors'` added. 50/50 specs green.
- ✓ **Cart Builder Package Refactor — Step 2 (Python skeleton + `base.py`)** — `cart_builder/__init__.py`, `cart_builder/base.py` (`GroceryProvider` ABC, `CartItem`, `CartSummary`, `SessionExpiredError`), `cart_builder/providers/__init__.py`, `cart_builder/tests/__init__.py`, fixture JSON files. No behavior change. `cart.py` still works as-is.

### Added in sixteenth session
- ✓ **`detect_session_state` happy path confirmed** — live `build-cart --force` run after session refresh: session was valid, run continued past step 1b normally. Added `log("  Session check: valid")` so the happy path is now visible in stderr.
- ✓ **PP page is a horizontal carousel** — first live run returned `available=0`. Bailey confirmed the page side-scrolls. `_collect_prev_purchase_items` now executes JS to scroll carousel containers horizontally before falling back to vertical window scroll.
- ✓ **`cart_builder/probe_pp.py`** — new 30-second diagnostic tool. Navigates to Past Purchases, reports all horizontally-scrollable containers, tries every card/name selector before and after horizontal scroll, dumps the full `data-testid` inventory. Use this for PP selector investigation — not `build-cart --force`.
- ✓ **`testing_verifications.md` updated** — PP row now says to use `probe_pp.py` first; "Upcoming — Needs Verification" section updated to match.
- 🗂️ **Cart Builder Package Refactor** — comprehensive spec in `future_enhancements.md`. Supersedes "Modular Testability Refactor". Coarse 5-method `GroceryProvider` ABC, `cart_builder/` Python package structure, `FixtureProvider` for tests, `--fixture` CLI flag, `README.md`. 6-step migration.
- 🗂️ **Application Orchestrator Refactor** — comprehensive 8-section spec in `future_enhancements.md`. One orchestrator per `main.rb` command, constructor injection with defaults, per-function LLM model config (`cfg.llm.models.planner` etc.), `LlmProvider` abstraction, `Notifier` interface, `BotServer` extraction. `main.rb` ends up as a ~80-line router.

### Added in fifteenth session
- ✓ **Session expiry detection (Option 1)** — `detect_session_state()` in `cart.py` detects Kasada bot-detection challenges and login redirects immediately after `navigate_to_store()`. Returns `"session_expired"` status (clean exit, not crash) with `abort_reason` of `"kasada_challenge"` or `"login_required"`. `main.rb` routes to `send_session_expired_alert` which sends a context-aware Telegram message + `[✅ Session Refreshed — Rebuild Cart]` inline button. `callback_session_refresh` edits the message and spawns `build-cart --force` in a background thread.
- 🗂️ **CapSolver Kasada auto-solving (Option 2)** — full spec in `future_enhancements.md`. Adds `solve_kasada_challenge()` to `cart.py`; auto-fires when `CAPSOLVER_API_KEY` set in `.env`; only handles `kasada_challenge` (not `login_required`); falls back to Option 1 alert on failure. Setup walkthrough included in spec.
- ✓ **FlareSolverr ruled out** — already on Unraid but is Cloudflare-specific (CF_Clearance/Turnstile); has no Kasada support and cannot be used here.

### Added in fourteenth session
- ✓ **Previous Purchases URL confirmed and fixed** — `PREV_PURCHASES_URL` corrected from `/shop/my_items` to `/past-purchases` (confirmed from live account screenshot). `SEL_MY_ITEMS_LINK` updated for "Past Purchases" nav link. `SEL_PREV_PURCHASES_TAB` emptied (no tab — direct page). URL check updated to accept `past-purchases`. **Card selectors still unverified** — run `probe_pp.py` to inspect live DOM.
- ✓ **Testing practice standard** — new section in TESTING_HANDOFF; decision table (fastest loop per scenario), pre-define success/failure rule, prefer specs over live runs, ask-if-stuck rule.
- ✓ **`spec/manual_addition_spec.rb`** — 6 examples: ManualAddition pending scope, resolve logic (ProductMap lookup + fallback), persistence invariant. 50 total, 0 failures.
- 🗂️ **Cart Builder Package Refactor planned** — full spec in `future_enhancements.md` (supersedes earlier "Modular Testability Refactor" stub).

### Added in thirteenth session
- ✓ Previous Purchases cart optimization implemented (`add_from_previous_purchases`, word-overlap matching, graceful fallback, `previous_purchases_stats` in output)

### Completed in earlier sessions
- ✅ `/add` multi-item LLM flow — `LlmItemParser`, preview/confirm/edit/cancel, cart rebuild on confirm (`lib/autochef/llm_item_parser.rb`, `lib/autochef/notify.rb`) (twelfth session)
- ✅ Automap Telegram report reformatted — Grocery additions section (search_term + qty/unit) + Pantry skips (compact comma list) (twelfth session)

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
