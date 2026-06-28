# Testing Feedback & Bug History — Mealie AutoChef

Historical record of bugs found, fixes applied, and known issues. Updated at the end of each session.

---

## Known Issues (not yet fixed)

**`est_total` never populated — deviation warning silently disabled**
`cart.py`'s `make_output(...)` never passes `est_total`. `safety.deviation_warning` receives `nil` and returns immediately. No impact on correctness, but budget deviation checking is silently disabled. Fix tracked in [future_enhancements.md](future_enhancements.md) § 3.

**No Telegram alert on total plan failure**
If `main.rb plan` crashes before sending the Telegram message (e.g. Mealie unreachable), nothing is sent. Scheduled runs fail silently. Mitigation: Uptime Kuma push monitor (not yet set up). Fix tracked in [future_enhancements.md](future_enhancements.md) § 4.

---

## Test Suite State (2026-06-28, 44 examples, 0 failures)

| Spec file | Examples |
|---|---|
| spec/config_spec.rb | 5 |
| spec/scoring_spec.rb | 4 |
| spec/planner_spec.rb | 5 |
| spec/feedback_spec.rb | 6 |
| spec/safety_spec.rb | 14 |
| spec/week_prefs_spec.rb | 10 |

---

## cart.py State (as of eighth session)

- `headless=False` — headed Chrome required; Food Lion blocks headless
- `clear_cart()` — confirmed working: cleared 27–60 items on live runs; includes `SEL_CART_ITEM_REMOVE_CONFIRM` click for the OK confirmation dialog
- `dismiss_modals()` — backdrop click at (10,10); called at startup AND before each Add click
- `SEL_ADD_BTN` — confirmed working: matched `text='Add to cart'` on all 24 items in the verified run
- `playwright_state.json` — refreshed with full auth + 2FA on 2026-06-28; will eventually expire

### If Food Lion session expires

```bash
source .venv/bin/activate && python3 cart_builder/cart.py --login
# Solve Kasada slider → dismiss welcome modal → sign in with email/password → complete 2FA → press Enter
```

---

## Product Map State (as of 2026-06-28)

- **59 items** in Mealie "Next Order" (from plan id=4: Greek Salmon, Lemon Pasta, Bailey's Chili, Jambalaya)
- **29 items** marked as pantry-skip (`__skip__` sentinel) — dropped silently by `resolve_cart_item`
- **30 items** are real grocery mappings — consolidated to 24 unique search terms for cart.py
- Bailey's Chili compound toppings ingredient was split into 6 via Mealie API PATCH

Run `bundle exec ruby scripts/seed_product_map.rb --list` to inspect all entries.

---

## Approved Plan (id=4)

- Thu Jul 2: Greek Salmon (2 srv) — perishable seafood, placed first
- Fri Jul 3: Lemon Pasta with Salmon (2 srv) — second seafood before shelf-stable proteins
- Sun Jul 5: Bailey's Chili (4 srv) — makes leftovers (covers Mon Jul 6)
- Tue Jul 7: Jambalaya (4 srv) — makes leftovers (covers Wed Jul 8)

---

## Recipes in the Dinner Pool (11 tagged `auto-plan`)

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

## Bugs Fixed — 2026-06-28 (eighth session)

**`clear_cart()` never clicked the "Remove this item from your cart?" confirmation dialog**
Food Lion shows an OK/Cancel confirmation after each trash-button click. `clear_cart()` incremented `removed` after clicking the trash button but never clicked OK, so no items were actually removed. On the first `build-cart --force` run, only 1 item was "cleared" but the cart was untouched — the 30 leftover items from the previous run plus 24 new items pushed the total to $312.66, which exceeded the $300 cap.
Fix: added `SEL_CART_ITEM_REMOVE_CONFIRM = ['button:has-text("OK")', ...]` constant and a `try_click(page, SEL_CART_ITEM_REMOVE_CONFIRM, timeout=2000)` call inside the clear loop, immediately after the trash-button click. Verified: cleared 27–60 items correctly on subsequent runs.
File: `cart_builder/cart.py`

**Telegram Markdown parse errors in `send_cart_ready` (multiple root causes)**
After the cart-ready message was sent, Telegram returned `400 Bad Request: Can't find end of the entity starting at byte offset N` on every run. Three separate causes:

1. `_Use /add <item>...--force_` — the closing `_` was adjacent to the alphanumeric `e` in `force`, which Telegram Markdown v1 doesn't recognize as a closing italic marker.
2. `[Open cart in Food Lion](url)` — the actual cart URL (captured from `page.url`) contains underscores in query parameters. Underscores in `[text](url_with_underscores)` break Markdown v1 link parsing.
3. `Screenshot: data/cart_screenshots/autochef-...png` — `cart_screenshots` contains `_`, parsed as an italic-open entity that's never closed.

Fix: removed all `_..._` italic markers; converted cart URL to plain text `Cart: url`; wrapped screenshot path in backticks.
File: `lib/autochef/notify.rb`

---

## Bugs Fixed / Implemented — 2026-06-28 (seventh session)

**Cart not cleared before re-run — duplicate items on `--force`**
Each `build-cart --force` run added items on top of the previous run's cart. Fix: added `clear_cart()` to `cart_builder/cart.py`. Runs after `navigate_to_store`, before any items are added. Iterates through all remove buttons until the cart is empty, then returns to the store page.
File: `cart_builder/cart.py`

**Telegram Markdown crash on cart-ready message (screenshot line)**
`_Screenshot: \`data/cart_screenshots/...\`_` mixed underscore italic with backtick code — Telegram Markdown v1 can't parse nested formatting.
Fix: rewrote to plain text.
File: `lib/autochef/notify.rb`

**Enhancement 1 — Quantity consolidation for duplicate search terms**
Multiple recipes needing the same item were sent as separate cart entries. Fix: in `cmd_build_cart` in `main.rb`, after resolving cart items, `group_by(:search_term)` and sum `default_qty`. Consolidations printed to stdout.
File: `main.rb`

---

## Bugs Fixed — 2026-06-28 (sixth session)

**Pantry items not visible to Bailey anywhere in the flow**
`cmd_build_cart` silently dropped `__skip__` items. Fix: added stdout visibility (list of pantry-skipped items + `/add` hint) and a "Pantry assumed on hand" section in the Telegram cart-ready message. Added `skipped_items:` kwarg to `send_cart_ready`.
Files: `main.rb`, `lib/autochef/notify.rb`

**Telegram markdown crash on cart-ready message**
`` _...`build-cart --force`_ `` — nested formatting, Telegram Markdown v1 can't parse. Fix: rewrote hint to plain text.
File: `lib/autochef/notify.rb`

**Food Lion blocks headless Chrome (Kasada bot detection)**
`setup_context()` used `headless=True`. Fix: changed to `headless=False`.
File: `cart_builder/cart.py`

**Food Lion session was unauthenticated — Sign In modal appeared mid-automation**
Old `playwright_state.json` had no login cookies. Fix: re-ran `python3 cart_builder/cart.py --login`, solved Kasada slider, signed in, completed 2FA. New `playwright_state.json` saved.

**"Pick a Shopping Method" modal blocks Add button clicks**
Playwright keyboard events filtered as untrusted. Fix: `dismiss_modals()` now uses `page.mouse.click(10, 10)` (backdrop click) + JS click fallback. Also called before each Add button click.
File: `cart_builder/cart.py`

**`SEL_ADD_BTN` too broad — matched "Add to List" instead of "Add to Cart"**
`'button:has-text("Add")'` matched Food Lion's "Add to List" button. Fix: replaced with specific "Add to Cart" text variants only.
File: `cart_builder/cart.py`

---

## Bugs Fixed — 2026-06-28 (fifth session)

**Pantry staples: `"On Hand"` toggle in Mealie does not work for free-text ingredients**
`onHand` check only fires when an ingredient is linked to a Mealie food object. Bailey's recipes use free-text notes with no food linkage. Fix: added pantry-skip support via `__skip__` sentinel in `seed_product_map.rb`; `resolve_cart_item` returns `nil`; `cmd_build_cart` uses `filter_map` to drop nils.
Files: `scripts/seed_product_map.rb`, `main.rb`

**HTTParty `timeout:` only sets `open_timeout`, not `read_timeout`**
A Mealie POST stalled indefinitely despite `timeout: 30`. Fix: replaced with explicit `open_timeout: 10, read_timeout: 30` on all four HTTP verbs.
File: `lib/autochef/mealie_client.rb`

**`CART_BUILDER_PYTHON` constant evaluated before `Dotenv.load` runs**
`CartClient::PYTHON_BIN` was a class-level constant set at require time. Fix: removed the constant; read `ENV.fetch('CART_BUILDER_PYTHON', 'python3')` inside `build_cart` at call time.
File: `lib/autochef/cart_client.rb`

**Bailey's Chili compound toppings ingredient**
Single ingredient line "Shredded cheese, diced avocado, sliced jalapeños, sour cream, hot sauce, cilantro (for topping)" was unmappable as one line. Fix: PATCHed the recipe via Mealie API to split into 6 individual ingredient lines. Shopping list went from 54 to 59 items.

---

## Bugs Fixed — 2026-06-28 (fourth session)

**`rackup` gem missing — `main.rb serve` crashed immediately**
Sinatra 4.x requires the `rackup` gem separately. Fix: added `gem 'rackup', '~> 2.1'` to Gemfile.
File: `Gemfile`

**Mealie v3 shopping list endpoints moved from `/api/groups/` to `/api/households/`**
All six shopping methods used the wrong base path. Fix: updated all six methods.
- List CRUD: `/api/households/shopping/lists`
- Item create: `/api/households/shopping/items` (no list ID in path)
- Item delete: `/api/households/shopping/items/{id}` (no list ID in path)
`remove_shopping_list_item` keeps `list_id` parameter (unused, marked `_list_id`) for call-site compatibility.
File: `lib/autochef/mealie_client.rb`

**`seed_product_map.rb` could not find ingredient names to map**
Script read `ing['food_name']` from embedded plan JSON — `ShoppingListBuilder` never writes ingredient data to the plan JSON. Fix: script now fetches items directly from the live Mealie "Next Order" shopping list.
File: `scripts/seed_product_map.rb`

---

## Implemented — 2026-06-28 (third session)

**Week configurator (Sinatra form)**
Per-week plan preferences form at `http://192.168.1.64:3456/week` (Tailscale-accessible). Per-day controls: meal type, servings, vibe. Global controls: protein-exclude chips, freeform note. `main.rb serve` starts the form in a background thread. Plan draft message shows a "⚙ Configure week" button. `main.rb plan` and regenerate both apply saved prefs before calling LlmPlanner.
Key files: `lib/autochef/sinatra_prefs_source.rb`, `lib/autochef/web/app.rb`, migration 009.

**`spec/config_spec.rb` Dotenv leak fixed**
Config spec's around hook now uses a real empty temp `.env` file so `Dotenv.load` doesn't pollute test fixtures with `MEALIE_URL`.

---

## Bugs Fixed — 2026-06-28 (second session)

**Pool exhaustion: `last_planned` stamped on every draft save**
Running `main.rb plan` twice marked 7/11 recipes as recently planned → pool exhausted on third run. Root cause: `last_planned` set in both the draft-save block in `main.rb` and the regenerate callback in `notify.rb`. Fix: removed `last_planned` update from both draft-save paths. Now only set in `callback_approve` — when the plan is actually approved. DB reset required to clear spurious stamps.
Files: `main.rb`, `lib/autochef/notify.rb`

**LLM validation failure was silent**
`parse_and_validate` in `llm_planner.rb` swallowed all errors with `rescue StandardError; nil`. Also: `to_set(&:recipe_id)` used wrong Enumerable form. Fix: removed internal rescue; errors bubble to `attempt_llm_refinement`'s rescue block. Also strips markdown code fences from raw LLM response before parsing.
File: `lib/autochef/llm_planner.rb`

**LLM error not visible in initial Telegram plan message**
`send_draft` called `build_plan_message(history)` without a note, so `llm_error` was only printed to stdout. Fix: `send_draft` now accepts `note:` kwarg and passes it through. `main.rb` passes `result.llm_error` as the note.
Files: `lib/autochef/notify.rb`, `main.rb`

**Stale leftover-coverage warnings after LLM refinement**
Warnings about "no makes-leftovers recipe available" were inherited by the LLM-refined plan even when the LLM assigned a makes-leftovers recipe to that slot. Fix: `parse_and_validate` filters out any leftover-coverage warning whose cook date has a makes-leftovers assignment in the refined plan.
File: `lib/autochef/llm_planner.rb`

---

## Bugs Fixed — 2026-06-27 (first-run session)

**Mealie v3 tag API requires `slug` field on PATCH**
`MealieClient#add_recipe_tags` sent `[{"name": "auto-plan"}]` — v3 needs full tag object with slug+id. Fix: added `ensure_tag(name)` helper; updated `add_recipe_tags` and `set_recipe_tags`.
File: `lib/autochef/mealie_client.rb`

**Mealie v3 recipe import requires two-step flow**
`POST /api/recipes/create/html-or-json` broken in v3. Working flow: POST to create by name → PATCH with details.
File: `scripts/import_recipes.rb`

**Food Lion bot detection — `cart.py` `run_login()` lacked stealth args**
Playwright's bundled Chromium triggered Kasada detection. Fix: both `run_login()` and `setup_context()` now use `channel="chrome"` (real Chrome), `--disable-blink-features=AutomationControlled`, and `navigator.webdriver` patch. Removed hardcoded user-agent from `setup_context`.
File: `cart_builder/cart.py`

---

## Bugs Fixed — 2026-06-26 (code audit)

**Critical — `lib/autochef/notify.rb` private method visibility**
`send_cart_ready`, `send_cart_aborted`, `send_thaw_reminder`, `send_morning_ping` were defined after the `private` keyword. Fix: moved to public section.

**Minor — `lib/autochef/recurring.rb` missing `require 'date'`**
Fixed: added require at top.

**gitignore — `data/backups/` not excluded**
Fixed: added to .gitignore.
