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
│   ├── scorer.rb                  # Recipe scoring (rating, recency, tag affinity)
│   ├── planner.rb                 # Deterministic week layout + perishability ordering
│   ├── llm_planner.rb             # Claude Haiku arrangement layer (wraps planner.rb)
│   ├── notify.rb                  # Telegram bot — polling, inline buttons, approval flow
│   ├── shopping.rb                # Shopping list generation → Mealie list
│   ├── recurring.rb               # Staples / recurring items
│   ├── cart_client.rb             # Ruby side of Ruby↔Python IPC (calls cart.py)
│   ├── safety.rb                  # Spending cap, kill switch, deviation check
│   ├── feedback.rb                # Post-cook feedback signals → recipe_stats
│   ├── reminders.rb               # rufus-scheduler: thaw reminders, morning pings
│   ├── week_prefs_source.rb       # WeekPrefs structs + WeekPrefsSource interface (planned)
│   ├── sinatra_prefs_source.rb    # DB-backed prefs provider (planned)
│   ├── web/app.rb                 # Sinatra form app (planned)
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
├── spec/                          # RSpec — 34 examples, all pass, in-memory SQLite
├── data/                          # SQLite DB, playwright_state.json, backups
├── docker/                        # Dockerfile + docker-compose.yml
│
├── HANDOFF.md                     # Orientation doc — read before touching code
├── TESTING_HANDOFF.md             # This file — agent briefing for test/feedback sessions
├── WEEK_PLANNER_PLAN.md           # Implementation plan for the week configurator feature
├── MEALIE_AUTOMATION_PLAN.md      # Full original spec (sections 4-5 are historical)
├── README.md                      # Setup and CLI reference
└── docs/
    ├── SETUP_WALKTHROUGH.md       # 10-step first-run guide
    ├── USER_GUIDE.md
    └── DEVELOPER_GUIDE.md
```

---

## Current state as of 2026-06-28 (eighth session)

### What's been completed

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
| `main.rb plan` (LLM) | ✓ | plan_history id=4 approved |
| `main.rb serve` | ✓ | Bot + Sinatra form both start cleanly |
| Telegram approval | ✓ | Plan id=4 approved |
| `main.rb shop` | ✓ | 59 items pushed to Mealie "Next Order" |
| `seed_product_map.rb` | ✓ | All items mapped or pantry-skipped |
| `main.rb build-cart` | ✓ | 24/24 items added (consolidated), $119.45 total, 0 flagged — `clear_cart()` confirmed working |
| Week configurator (Sinatra form) | ✓ | Implemented + documented |
| Docker deployment | **NOT YET** | After confirmed stable local operation |
| Uptime Kuma push URL | **NOT YET** | Bailey needs to create Push monitor in Kuma |

### Product map state

- **59 items** in Mealie "Next Order" (from plan id=4: Greek Salmon, Lemon Pasta, Bailey's Chili, Jambalaya)
- **29 items** marked as pantry-skip (`__skip__` sentinel) — dropped silently by `resolve_cart_item`
- **30 items** are real grocery mappings — these are what cart.py will search for on Food Lion
- `seed_product_map.rb --list` to inspect all entries

### Config decisions (important for debugging)

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

### Approved plan (id=4)

- Thu Jul 2: Greek Salmon (2 srv) — perishable seafood, placed first
- Fri Jul 3: Lemon Pasta with Salmon (2 srv) — second seafood before shelf-stable proteins
- Sun Jul 5: Bailey's Chili (4 srv) — makes leftovers (covers Mon Jul 6)
- Tue Jul 7: Jambalaya (4 srv) — makes leftovers (covers Wed Jul 8)

### Recipes in the dinner pool (11 tagged `auto-plan`)

| Slug | Cuisine | Protein | Effort | Leftovers |
|---|---|---|---|---|
| jambalaya | american | chicken | project | yes |
| bailey-s-chili | american | beef | project | yes |
| wild-mushroom-risotto | italian | vegetarian | project | no |
| greek-salmon | mediterranean | seafood | quick | no |
| easy-oven-cooked-pulled-pork | american | pork | project | yes |
| the-best-potato-leek-soup | american | vegetarian | project | yes |
| easy-pan-roasted-chicken-breasts-with-lemon-and-rosemary-pan-sauce-recipe | american | chicken | quick | no |
| spicy-sriracha-noodles | asian | vegetarian | quick | no |
| easy-pan-roasted-pork-tenderloin-with-bourbon-soaked-figs-recipe | american | pork | quick | no |
| lemon-pasta-with-salmon | mediterranean | seafood | quick | no |
| fish-tacos-recipe | mexican | seafood | quick | no |

---

## Bugs fixed — 2026-06-26 code audit

**Critical — `lib/autochef/notify.rb` private method visibility**
`send_cart_ready`, `send_cart_aborted`, `send_thaw_reminder`, `send_morning_ping` were
defined after the `private` keyword. Fixed: moved to public section.

**Minor — `lib/autochef/recurring.rb` missing `require 'date'`**
Fixed: added require at top.

**gitignore — `data/backups/` not excluded**
Fixed: added to .gitignore.

---

## Bugs fixed — 2026-06-27 first-run session

**Mealie v3 tag API requires `slug` field on PATCH**
`MealieClient#add_recipe_tags` sent `[{"name": "auto-plan"}]` — v3 needs full tag object with slug+id.
Fix: added `ensure_tag(name)` helper to MealieClient; updated `add_recipe_tags` and `set_recipe_tags`.
File: `lib/autochef/mealie_client.rb`

**Mealie v3 recipe import requires two-step flow**
`POST /api/recipes/create/html-or-json` broken in v3. Working flow: POST to create by name → PATCH with details.
File: `scripts/import_recipes.rb`

**Food Lion bot detection — cart.py `run_login()` lacked stealth args**
Playwright's bundled Chromium triggered Kasada detection. Fix: both `run_login()` and `setup_context()`
now use `channel="chrome"` (real Chrome), `--disable-blink-features=AutomationControlled`,
and `navigator.webdriver` patch. Removed hardcoded user-agent from `setup_context`.
File: `cart_builder/cart.py`

---

## Bugs fixed — 2026-06-28 second session

**Pool exhaustion: `last_planned` stamped on every draft save**
Running `main.rb plan` twice marked 7/11 recipes as recently planned → pool exhausted on
the third run. Root cause: `last_planned` was being set in both the draft-save block in
`main.rb` and the regenerate callback in `notify.rb`.
Fix: removed `last_planned` update from both draft-save paths. Now only set in
`callback_approve` in `notify.rb` — when the plan is actually approved.
Files: `main.rb`, `lib/autochef/notify.rb`
DB reset required: ran one-off script to clear spurious `last_planned` stamps. Clean state
restored. Future drafts will not stamp `last_planned`.

**LLM validation failure was silent**
`parse_and_validate` in `llm_planner.rb` swallowed all errors with `rescue StandardError; nil`,
so the fallback message was always "LLM response failed validation" with no cause.
Also: the `to_set(&:recipe_id)` call used the wrong Enumerable form.
Fix: removed the internal rescue; errors now bubble to `attempt_llm_refinement`'s rescue
block which includes the actual exception message in `llm_error`. Also strips markdown code
fences from the raw LLM response before parsing (Haiku sometimes emits them despite the prompt).
File: `lib/autochef/llm_planner.rb`

**LLM error not visible in initial Telegram plan message**
`send_draft` called `build_plan_message(history)` without a note, so the `llm_error` was
only printed to stdout — invisible when running via cron/scheduler.
Fix: `send_draft` now accepts `note:` kwarg and passes it through to `build_plan_message`.
`main.rb` passes `result.llm_error` as the note when calling `send_draft`.
Files: `lib/autochef/notify.rb`, `main.rb`

**Stale leftover-coverage warnings after LLM refinement**
The LLM may assign a makes-leftovers recipe to a slot where the deterministic planner gave
up and logged a "no makes-leftovers recipe available" warning. Those warnings were blindly
inherited by the LLM-refined plan, producing false alerts.
Fix: `parse_and_validate` now filters out any leftover-coverage warning whose cook date has
a makes-leftovers assignment in the refined plan.
File: `lib/autochef/llm_planner.rb`

---

## Implemented — 2026-06-28 third session

**Week configurator (Sinatra form)**
Per-week plan preferences form at http://192.168.1.64:3456/week (Tailscale-accessible).
Per-day controls: meal type (cook/leftover/skip), dinner/lunch servings, vibe (Feed Me/Treat), dietary notes.
Global controls: protein-exclude chips (No Seafood/Beef/Pork, Vegetarian only), freeform note.
`main.rb serve` starts the form in a background thread. Plan draft message now shows a "⚙ Configure week" button.
`main.rb plan` and regenerate in the bot both apply saved prefs before calling LlmPlanner.
Key files: `lib/autochef/sinatra_prefs_source.rb`, `lib/autochef/web/app.rb`, migration 009.

**`spec/config_spec.rb` Dotenv leak fixed**
The config spec's around hook now uses a real empty temp `.env` file (instead of `/nonexistent/.env`)
so `Dotenv.load` doesn't load the project `.env` and pollute test fixtures with `MEALIE_URL`.

---

## Bugs fixed — 2026-06-28 fourth session

**`rackup` gem missing — `main.rb serve` crashed immediately**
Sinatra 4.x requires the `rackup` gem separately (no longer bundled with Rack).
Fix: added `gem 'rackup', '~> 2.1'` to Gemfile.
File: `Gemfile`

**Mealie v3 shopping list endpoints moved from `/api/groups/` to `/api/households/`**
All six shopping methods in `mealie_client.rb` used `/api/groups/shopping/lists/...`.
Mealie v3 returns 404 for those paths. Verified correct paths by probing the live API:
- List CRUD: `/api/households/shopping/lists` (GET, POST)
- Single list: `/api/households/shopping/lists/{id}` (GET)
- Item create: `/api/households/shopping/items` (POST — no list ID in path)
- Item delete: `/api/households/shopping/items/{id}` (DELETE — no list ID in path)
Fix: updated all six methods in `mealie_client.rb`. `remove_shopping_list_item` signature
kept `list_id` parameter (unused, marked with `_list_id`) for call-site compatibility.
File: `lib/autochef/mealie_client.rb`

**`seed_product_map.rb` could not find ingredient names to map**
Script read `ing['food_name']` from `entry['ingredients']` in the plan JSON, but
`ShoppingListBuilder` never writes ingredient data back to the plan JSON — ingredients
live only in Mealie. Result: "No ingredient data embedded" → manual entry prompt →
blank input → "All ingredients already mapped" with 0 mappings made.
Fix: script now fetches autochef-managed items directly from the live Mealie "Next Order"
shopping list and uses their `note` text as the map key. This also aligns the key with
what `resolve_cart_item` uses when looking up mappings during `build-cart`.
File: `scripts/seed_product_map.rb`

---

## Bugs fixed — 2026-06-28 eighth session

**`clear_cart()` never clicked the "Remove this item from your cart?" confirmation dialog**
Food Lion shows an OK/Cancel confirmation after each trash-button click. `clear_cart()` incremented `removed` after clicking the trash button but never clicked OK, so no items were actually removed. On the first `build-cart --force` run, only 1 item was "cleared" but the cart was untouched — the 30 leftover items from the previous run plus 24 new items pushed the total to $312.66, which exceeded the $300 cap.
Fix: added `SEL_CART_ITEM_REMOVE_CONFIRM = ['button:has-text("OK")', ...]` constant and a `try_click(page, SEL_CART_ITEM_REMOVE_CONFIRM, timeout=2000)` call inside the clear loop, immediately after the trash-button click. Verified: cleared 27–60 items correctly on subsequent runs.
File: `cart_builder/cart.py`

**Telegram Markdown parse errors in `send_cart_ready` (multiple root causes)**
After the cart-ready message was sent, Telegram returned `400 Bad Request: Can't find end of the entity starting at byte offset N` on every run. Three separate causes:

1. `_Use /add <item>...--force_` — the closing `_` was adjacent to the alphanumeric `e` in `force`, which Telegram Markdown v1 doesn't recognize as a closing italic marker. The entity was left open.
2. `[Open cart in Food Lion](url)` — the actual cart URL (captured from `page.url` after clicking the cart icon) contains underscores in query parameters. Underscores in `[text](url_with_underscores)` break Markdown v1 link parsing.
3. `Screenshot: data/cart_screenshots/autochef-...png` — `cart_screenshots` contains `_`, which Telegram v1 parses as an italic-open entity that's never closed.

Fix:
- Removed all `_..._` italic markers from `send_cart_ready` hint lines (plain text is fine; `*bold*` retained).
- Converted cart URL from `[Open cart in Food Lion](url)` to `Cart: url` (plain text).
- Wrapped screenshot path in backticks: `` Screenshot: `data/cart_screenshots/...` `` — underscores inside code spans are not parsed as Markdown.
File: `lib/autochef/notify.rb`

---

## Bugs fixed / implemented — 2026-06-28 seventh session

**Cart not cleared before re-run — duplicate items on `--force`**
Each `build-cart --force` run added items on top of the previous run's cart, creating duplicates.
Fix: added `clear_cart()` to `cart_builder/cart.py`. Runs after `navigate_to_store`, before any items are added. Opens the cart sidebar and iterates through all remove buttons until the cart is empty, then returns to the store page.
Items added via the Telegram `/add` command are in the Mealie "Next Order" list and are re-added by the normal build flow — they are not lost.
New selector: `SEL_CART_ITEM_REMOVE`.
File: `cart_builder/cart.py`

**Telegram Markdown crash on cart-ready message (screenshot line)**
`_Screenshot: \`data/cart_screenshots/...\`_` mixed underscore italic with backtick code — Telegram Markdown v1 cannot parse nested formatting. Results in 400 Bad Request at byte offset ~1187.
Fix: rewrote to plain text `Screenshot: data/cart_screenshots/...`.
File: `lib/autochef/notify.rb`

**Enhancement 1 — Quantity consolidation for duplicate search terms**
Multiple recipes needing the same item (e.g. "salmon fillet" × 2, "garlic" × 3) were sent as separate cart entries, causing cart.py to search and add them individually.
Fix: in `cmd_build_cart` in `main.rb`, after resolving cart items, `group_by(:search_term)` and sum `default_qty`. Items that are consolidated are printed to stdout so Bailey can verify the math.
File: `main.rb`

---

## Bugs fixed — 2026-06-28 sixth session

**Pantry items not visible to Bailey anywhere in the flow**
`cmd_build_cart` silently dropped `__skip__` items with no output. Added visibility in two places:
- stdout: prints all pantry-skipped items before invoking cart.py, with `/add` hint
- Telegram cart-ready message: new "Pantry assumed on hand" section with same hint
Fix also added `skipped_items:` kwarg to `send_cart_ready` in `notify.rb`.
Files: `main.rb`, `lib/autochef/notify.rb`

**Telegram markdown crash on cart-ready message**
`send_cart_ready` added a line with backtick inside underscore formatting
(`` _...`build-cart --force`_ ``). Telegram Markdown v1 can't parse nested formatting
— resulted in a 400 error from the Telegram API.
Fix: rewrote hint line to plain text with no nested formatting.
File: `lib/autochef/notify.rb`

**Food Lion blocks headless Chrome (Kasada bot detection)**
`setup_context()` used `headless=True`. Food Lion's Kasada protection detects headless
Chrome and shows "Access is temporarily restricted" before the store page loads,
making all search bar lookups fail. Headed Chrome is much harder to fingerprint.
Fix: changed `setup_context(p, headless=True)` → `headless=False` in `build_cart`.
File: `cart_builder/cart.py`

**Food Lion session was unauthenticated — Sign In modal appeared mid-automation**
The old `playwright_state.json` had no login cookies (session from initial run didn't
include authentication). After bypassing Kasada with headed Chrome, a Sign In modal
appeared during cart building and blocked Add button clicks.
Fix: re-ran `python3 cart_builder/cart.py --login`, solved Kasada slider manually,
signed in with email/password, completed 2FA. New `playwright_state.json` saved with
full authenticated session. Future runs won't need login until session expires.

**"Pick a Shopping Method" modal blocks Add button clicks**
After login, a "Pick a Shopping Method" modal appears on every `foodlion.com/shop`
load. Playwright's keyboard events (`page.keyboard.press("Escape")`) are filtered
as untrusted synthetic events by Food Lion's JS. CSS/text selectors for "Continue
Shopping" also failed. JS `evaluate()` with `offsetParent` visibility check also failed.
Fix: `dismiss_modals()` now uses `page.mouse.click(10, 10)` (backdrop click, outside
any centered modal) + JS click fallback. Also called before each Add button click since
the modal can persist during item searches.
File: `cart_builder/cart.py`

**`SEL_ADD_BTN` too broad — matched "Add to List" instead of "Add to Cart"**
`'button:has-text("Add")'` and `'button[aria-label*="Add" i]'` matched Food Lion's
"Add to List" button (saved shopping list feature) instead of the "Add to Cart" button
(active To Go pickup cart). Items were silently added to the wrong place.
Fix: replaced broad selectors with specific "Add to Cart" text variants only.
File: `cart_builder/cart.py`

---

## Bugs fixed — 2026-06-28 fifth session

**Pantry staples: `"On Hand"` toggle in Mealie does not work for free-text ingredients**
The `onHand` check in `shopping.rb` only fires when an ingredient is linked to a Mealie food
object (`food && food['onHand']`). Bailey's imported recipes use free-text notes with no food
linkage, so `food` is always nil and the check never runs. The 200 foods in Mealie's food DB
are a generic demo set (juices, supplements) — none match the actual recipe ingredients.
Fix: added pantry-skip support to `seed_product_map.rb` and `main.rb`:
- Pressing `s` at the search term prompt saves `search_term = '__skip__'`
- `resolve_cart_item` returns `nil` for `__skip__` entries
- `cmd_build_cart` uses `filter_map` to drop nils — skipped items never reach cart.py
- `--list` output shows "(pantry staple — excluded from cart)" for skipped entries
Files: `scripts/seed_product_map.rb`, `main.rb`

**HTTParty `timeout:` only sets `open_timeout`, not `read_timeout`**
A single Mealie POST mid-way through pushing 54 items stalled indefinitely despite
`timeout: 30`. HTTParty's `timeout:` option reliably sets `open_timeout` but not always
`read_timeout` in all Net::HTTP versions.
Fix: replaced `timeout: 30` with `open_timeout: 10, read_timeout: 30` on all four HTTP
verbs (get, post, patch, delete) in `mealie_client.rb`.
File: `lib/autochef/mealie_client.rb`

**`CART_BUILDER_PYTHON` constant evaluated before `Dotenv.load` runs**
`CartClient::PYTHON_BIN` was a class-level constant set at require time (line 35 of `main.rb`).
`Config.load` (which calls `Dotenv.load`) isn't called until later inside `main`. Result:
`ENV['CART_BUILDER_PYTHON']` was always nil → fallback to system `python3` → no playwright.
Fix: removed the constant; read `ENV.fetch('CART_BUILDER_PYTHON', 'python3')` inside
`build_cart` at call time, after Dotenv has already loaded.
File: `lib/autochef/cart_client.rb`

**Bailey's Chili compound toppings ingredient**
Recipe had a single ingredient line: "Shredded cheese, diced avocado, sliced jalapeños,
sour cream, hot sauce, cilantro (for topping)". This appeared as one unmappable line in the
shopping list and seed script.
Fix: PATCHed the recipe via Mealie API to split into 6 individual ingredient lines.
After `main.rb shop` was re-run: 59 items total (was 54 — net +5 from the split).

---

## Known issues (not yet fixed)

**`est_total` never populated (deviation warning can't fire)**
`cart.py`'s `make_output(...)` call never passes `est_total`. `safety.deviation_warning` receives `nil` and returns immediately. No impact on correctness, but the budget deviation feature is silently disabled.

**No Telegram alert on total plan failure**
If `main.rb plan` crashes before sending the Telegram message (e.g. Mealie unreachable),
nothing is sent. Scheduled runs would fail silently. Mitigation: Uptime Kuma push monitor
(not yet set up). A "crash alert" rescue in the scheduler is a future improvement.

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

---

## What to do when Bailey sends a screenshot

1. **Read the screenshot carefully** — look for error messages, unexpected output, missing data, wrong values, UI state
2. **Identify the command or flow** — which `main.rb` command or which script produced this?
3. **Locate the relevant file** — use the file map above to narrow down fast
4. **Check the known issues list** — it might be a documented limitation
5. **Make a targeted fix** — don't refactor surrounding code, don't add features, fix what's broken
6. **Re-run the command** to verify the fix works before reporting done
7. If the screenshot shows a **Telegram message**, it came from `lib/autochef/notify.rb`
8. If it shows a **plan output in terminal**, it came from `main.rb`'s `cmd_plan` / `lib/autochef/planner.rb` / `lib/autochef/llm_planner.rb`
9. If it shows a **Food Lion browser**, it came from `cart_builder/cart.py`

---

## What's coming next (in order)

1. ~~**Verify cart clearing**~~ — **DONE** (eighth session). `clear_cart()` confirmed working: cleared 27–60 items including the OK confirmation dialog. Selectors verified live.

2. **Enhancement 2 — LLM quantity consolidation** — smart grocery consolidation: "2 recipes both need a squeeze of lemon juice → 1 lemon". Post-resolve injection (after `resolve_cart_item` runs) — Haiku receives resolved `cart_items` and merges/rationalizes quantities respecting real-world pack sizes. Lower risk than pre-shop injection since the product map is already applied.

3. **LLM tagging / auto product mapping** — `scripts/auto_map.rb`: Haiku suggests `search_term`/qty/unit for new ingredients → Playwright confirms the product exists on Food Lion → writes to `product_map`. Falls back to interactive `seed_product_map.rb` prompt for anything Haiku can't confidently map.

4. **Post-build cart review** — check the Food Lion cart manually. Note any items that resolved to the wrong product and fix their search terms via `seed_product_map.rb --update`.

5. **Telegram UX improvements** (three items, see full spec below):
   - Food Lion link should open the native app, not Telegram browser
   - `/shop` bot command to trigger a cart rebuild from Telegram (replaces the "re-run CLI" hint)
   - Screenshot should be sent as a Telegram photo, not a plain text path

6. **Recipe Sleep feature** — see full spec below.

7. **LLM Recipe Suggestions (`/newrecipes`)** — see full spec below.

8. **Debug screenshots** — see spec below.

8. **Docker deployment** on Unraid — after stable local operation confirmed

9. **Uptime Kuma push monitor** — Bailey creates a Push monitor in Kuma at 192.168.1.64:3001; paste the push URL into `.env` as `UPTIME_KUMA_PUSH_URL`

10. **MCP setup** — Docker MCP server so Claude Code can manage containers directly

---

## Feature spec: Recipe Sleep

Allow Bailey to put a recipe to sleep from the plan approval or swap flow. Sleeping recipes are excluded from the eligible pool until the sleep expires.

### Sleep duration progression

Each recipe tracks how many times it has been slept (`sleep_count`). Duration increases per sleep:

| `sleep_count` before this sleep | Duration |
|---|---|
| 0 | 2 weeks |
| 1 | 4 weeks |
| 2 | 16 weeks |
| 3 | 32 weeks |
| 4+ | 52 weeks (cap — recipe always returns within a year) |

Reset: clears `sleep_count` to 0 and `sleep_until` to nil for a specific recipe. Available via `/sleeping` command.

### DB changes (new migration 010)

Add to `recipe_stats`:
- `sleep_until` DATE nullable — date when the sleep expires (nil = not sleeping)
- `sleep_count` INTEGER NOT NULL DEFAULT 0 — how many times this recipe has been slept

### Eligibility check

In `scorer.rb` / `planner.rb`: exclude any `RecipeStat` where `sleep_until IS NOT NULL AND sleep_until > Date.today`.

### Bot flow

**In plan approval message** — add a Sleep button per recipe alongside the existing Swap button. Inline keyboard layout per recipe:
```
[✅ Keep] [🔁 Swap] [😴 Sleep]
```

**In swap flow** — when Bailey taps Swap on a recipe, present Sleep as the first option before swap candidates:
```
[😴 Sleep this recipe instead] [Swap candidate 1] [Swap candidate 2] ...
```

**After tapping Sleep:**
- Compute duration from `sleep_count`
- Set `sleep_until = Date.today + duration_days`
- Increment `sleep_count`
- Auto-swap the slept recipe with the next best candidate
- Bot replies: "😴 [Recipe] sleeping for N weeks (returns [date]). Swapped with [replacement]."

### `/sleeping` Telegram command

Lists all currently sleeping recipes:
```
*Sleeping recipes:*
  • Greek Salmon — wakes up Thu Jul 30 (2 wks, sleep #1)
  [Reset]
```
The Reset button on each entry clears `sleep_until` and `sleep_count` for that recipe.

### Key files to create/modify

- `lib/autochef/database.rb` — migration 010 (`sleep_until`, `sleep_count` columns)
- `lib/autochef/models/recipe_stat.rb` — add `sleep_duration_weeks` helper + eligibility scope
- `lib/autochef/scorer.rb` — filter out sleeping recipes before scoring
- `lib/autochef/notify.rb` — Sleep buttons in plan message + swap flow; `/sleeping` response
- `main.rb` — `cmd_sleeping`; callback handlers for `sleep_recipe`, `reset_sleep`
- `config.yaml` / `lib/autochef/config.rb` — no change needed (progression is hardcoded in RecipeStat)

---

## Feature spec: LLM Recipe Suggestions (`/newrecipes`)

Bailey can trigger a new-recipe suggestion round from Telegram at any time. The LLM looks at what Bailey likes and finds 3 new recipes — using web search when possible, falling back to generation.

### Context sent to LLM

Pull from DB + Mealie:
- Recipes with `times_planned >= 2` OR Mealie `rating >= 4` OR positive feedback score → "liked" recipes
- Their cuisine, protein, effort, tags from Mealie
- The current recipe pool (to avoid re-suggesting something already in Mealie)

Build a context summary: "Here are recipes Bailey likes and has made often: [list with metadata]. He tends toward [cuisines]. Suggest 3 new complementary recipes he hasn't tried."

### LLM call

- **Model**: Claude Sonnet (has `web_search` tool support)
- **Web search**: try first → find real recipe URLs from reputable sources (Serious Eats, NYT Cooking, The Food Lab, AllRecipes)
- **Fallback**: if web search returns nothing or fails, generate recipe ideas from training data (mark `source: generated`)
- **Output per suggestion**: `{name, source_url | null, description (2 sentences), why_it_fits}`

### Telegram flow

Bot sends one message per suggestion:
```
*[Recipe Name]*
[2-sentence description]
Source: [URL] — or — Generated by Claude
Why it fits: [brief rationale]

[✅ Import] [❌ Skip] [💬 Feedback]
```

- **✅ Import**: calls Mealie import flow (POST to create by name → PATCH with auto-plan tag + metadata → `main.rb sync` equivalent). Notifies: "✅ [Recipe] added to Mealie and tagged auto-plan."
- **❌ Skip**: records skip in DB + text log with no comment.
- **💬 Feedback**: bot prompts "What didn't you like about this suggestion?" → records text response in DB + text log.

### Feedback storage

**DB table `recipe_suggestion_feedback`** (new migration 011):
- `id`, `recipe_name`, `source_url`, `action` (imported/skipped/feedback), `feedback_text`, `suggested_at`, `acted_at`

**Text export `data/suggestion_feedback.txt`**: append-only log, one line per action:
```
2026-07-01 | Greek Chicken Bowl | https://... | skipped | "not a fan of bowl meals"
```

Text file is easy to attach when handing off to a new agent.

**Future LLM context**: when `/newrecipes` is called, include the last N feedback entries in the prompt so the LLM can refine suggestions over time.

### Key files to create/modify

- `lib/autochef/llm_recipe_suggester.rb` — new file: builds context, calls Claude API with web search tool, parses suggestions
- `lib/autochef/models/recipe_suggestion_feedback.rb` — new AR model
- `lib/autochef/database.rb` — migration 011 (`recipe_suggestion_feedback` table)
- `lib/autochef/notify.rb` — new `send_recipe_suggestions` method; suggestion message + buttons
- `main.rb` — `cmd_newrecipes`; bot command handler for `/newrecipes`; callbacks for `import_suggestion`, `skip_suggestion`, `feedback_suggestion`
- `data/suggestion_feedback.txt` — auto-created on first feedback action

---

## Feature spec: Debug screenshots

Take screenshots at each meaningful step of the cart build (not video — lower memory, no duplicate frames, directly Claude-analyzable). Keep a rolling window of the last 2 full run directories.

### Screenshots to capture (in order)

1. After `navigate_to_store` + modal dismissal — confirm we're on the right page
2. After `clear_cart` — confirm cart is empty
3. After `set_pickup_mode` — confirm pickup tab active
4. After each `add_item_to_cart` success — confirm item appeared in cart count / cart area
5. After `capture_cart_summary` — the final cart view (same as current `run_key.png`)
6. On any exception — error screenshot (already exists)

### Implementation

In `run_build_cart()`, pass a `debug_dir` path to each step function. Screenshot each step:
```python
debug_dir = SCREENSHOT_DIR / run_key
debug_dir.mkdir(parents=True, exist_ok=True)
page.screenshot(path=str(debug_dir / "01_store_loaded.png"))
```

Rolling window: at the start of `run_build_cart()`, list all subdirectories of `SCREENSHOT_DIR` sorted by mtime. If more than 1 exists, delete the oldest (keeps 2).

The final summary screenshot (`run_key.png`) remains as-is for the Telegram notification.

**Env var** `DEBUG_SCREENSHOTS_PATH`: if set, rsync or copy the debug run directory to that path on Unraid after the run completes.

### Accessing screenshots for Claude analysis

Screenshots are in `data/cart_screenshots/{run_key}/`. To review with Claude: share each image file from the most recent run. Claude can read any `.png` directly.

Add `main.rb debug-screenshots` (or just `ls data/cart_screenshots/` instructions) to list available debug runs.

### Key files to modify

- `cart_builder/cart.py` — `run_build_cart()` (per-step screenshots, rolling cleanup, optional copy to `DEBUG_SCREENSHOTS_PATH`)
- `.env.example` — document `DEBUG_SCREENSHOTS_PATH`

---

## Enhancement: Telegram UX improvements

Three UX issues surfaced from live testing:

### 1. Food Lion link opens Telegram browser, not the app

The cart-ready message currently sends `Cart: https://foodlion.com/shop` as plain text. Even as a tappable URL, Telegram opens it in its in-app browser, not the Food Lion app.

Fix: send as a proper Markdown hyperlink. Food Lion's app uses Universal Links (`https://www.foodlion.com`) — iOS/Android will route the tap to the native app if installed. Hardcode the URL to `https://www.foodlion.com/shop` (no underscores → safe in Markdown v1):
```ruby
lines << "[Open cart in Food Lion To Go](https://www.foodlion.com/shop)"
```
File: `lib/autochef/notify.rb`

### 2. "re-run build-cart --force" is not actionable from Telegram

The pantry hint currently says "then re-run: build-cart --force" — Bailey can't run CLI commands from his phone. Replace with a `/shop` bot command.

**`/shop` command** — rebuilds the cart from the current Mealie "Next Order" list. Flow:
1. Bailey taps `/add <item>` in Telegram (already works) for any pantry restocks
2. Bailey sends `/shop` in Telegram
3. Bot replies immediately: "Cart rebuild started — this takes a few minutes."
4. Bot spawns `bundle exec ruby main.rb build-cart --force` as a background subprocess
5. When done, the normal `send_cart_ready` notification fires (already implemented)

Implementation in `notify.rb`'s `handle_message`:
```ruby
when /^\/shop(\s|$)/
  bot.api.send_message(chat_id: update.chat.id, text: "Cart rebuild started...")
  Thread.new { system("cd #{project_root} && bundle exec ruby main.rb build-cart --force") }
```
Update pantry hint message: `"Use /add <item> to restock pantry staples, then send /shop to rebuild the cart."`
Files: `lib/autochef/notify.rb`, `main.rb`

### 3. Screenshot path is plain text — not useful in Telegram

`Screenshot: \`data/cart_screenshots/autochef-...\`` is a local server path that Bailey can't open from his phone. Replace with an actual Telegram photo upload.

Fix: after sending the text cart-ready message, call `bot_api.send_photo` with the screenshot file:
```ruby
if result['screenshot_path'] && File.exist?(result['screenshot_path'])
  bot_api.send_photo(chat_id: @chat_id, photo: Faraday::UploadIO.new(result['screenshot_path'], 'image/png'), caption: "Cart as of #{run_key}")
end
```
Remove the `Screenshot: \`...\`` text line from the message entirely.
File: `lib/autochef/notify.rb`

---

### cart.py state as of eighth session

- `headless=False` — headed Chrome required; Food Lion blocks headless
- `clear_cart()` — **confirmed working**: cleared 27–60 items on live runs; includes `SEL_CART_ITEM_REMOVE_CONFIRM` click for the OK confirmation dialog
- `dismiss_modals()` — backdrop click at (10,10); called at startup AND before each Add click
- `SEL_ADD_BTN` — confirmed working: matched `text='Add to cart'` on all 24 items in the verified run
- `playwright_state.json` — refreshed with full auth + 2FA on 2026-06-28; will eventually expire

### If Food Lion session expires

```bash
source .venv/bin/activate && python3 cart_builder/cart.py --login
# Solve Kasada slider → dismiss welcome modal → sign in with email/password → complete 2FA → press Enter
```

### When starting a new session

1. Read this file in full
2. Check memory files at `~/.claude/projects/-Users-baileygriffin-Projects-mealie-autochef-ruby/memory/`
3. Run `bundle exec ruby main.rb check` to verify connectivity
4. Check DB state: `bundle exec ruby -e "require_relative 'lib/autochef/database'; Autochef::Database.connect!; require_relative 'lib/autochef/models/plan_history'; require_relative 'lib/autochef/models/product_map'; puts \"Pending plans: #{Autochef::Models::PlanHistory.where(approved: 0).count}\"; puts \"Product map entries: #{Autochef::Models::ProductMap.count}\""`
5. Pick up from "What's coming next" above

At the end of each session, update this file: mark completed steps, add newly discovered bugs, and update "What's coming next."
