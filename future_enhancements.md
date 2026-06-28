# Future Enhancements — Mealie AutoChef

**Rule: address feedback and improvements first, then new features.**
When asked "what's next," pick the next unchecked item from the Feedback section before moving to New Features.

---

## Feedback / Improvements (do these first)

### 1. Enhancement 2 — LLM Quantity Consolidation

**Priority: next up.**

Post-resolve pass: after `resolve_cart_item` runs on all items, Haiku receives the resolved `cart_items` list and merges/rationalizes quantities for real-world grocery pack sizes. This is a smarter layer on top of Enhancement 1 (which only deduplicates by exact `search_term`).

**Examples of what this catches:**
- 2 recipes each call for "a squeeze of lemon juice" → resolved as 2× "lemon" → LLM consolidates to 1 lemon
- Recipe A needs 3 garlic cloves, recipe B needs 2 → LLM suggests 1 head of garlic (not 5 loose cloves)
- 1 cup chicken broth + 2 cups chicken broth → 1 box/carton (32 oz)

**Context sent to LLM:**
- Resolved `cart_items`: `[{search_term, qty, unit, recipe_sources: ["Greek Salmon", "Lemon Pasta"]}]`
- Request: merge where semantically equivalent, rationalize to real-world pack sizes, return adjusted qty per item

**Output**: Updated `cart_items` with rationalized quantities. Consolidations printed to stdout so Bailey can verify.

**Key files:**
- `lib/autochef/llm_qty_consolidator.rb` — new file; calls Claude Haiku
- `main.rb` — call after the `resolve_cart_item` pass, before invoking `cart_client.rb`

---

### 2. Telegram UX Improvements (3 items)

#### 2a. Food Lion link opens native app, not Telegram browser

The cart-ready message currently sends `Cart: https://foodlion.com/shop` as plain text. Even as a tappable URL, Telegram opens it in its in-app browser, not the Food Lion app.

Fix: send as a proper Markdown hyperlink. `https://www.foodlion.com/shop` has no underscores → safe in Markdown v1:
```ruby
lines << "[Open cart in Food Lion To Go](https://www.foodlion.com/shop)"
```
File: `lib/autochef/notify.rb`

#### 2b. `/shop` Telegram command — rebuild cart from phone

The pantry hint currently says "re-run: build-cart --force" — not actionable from a phone. Replace with a bot command.

**`/shop` flow:**
1. Bailey taps `/add <item>` for any pantry restocks (already works)
2. Bailey sends `/shop`
3. Bot replies immediately: "Cart rebuild started — this takes a few minutes."
4. Bot spawns `bundle exec ruby main.rb build-cart --force` as a background thread
5. When done, normal `send_cart_ready` fires

Update pantry hint: `"Use /add <item> to restock pantry staples, then send /shop to rebuild the cart."`

Implementation in `notify.rb`'s `handle_message`:
```ruby
when /^\/shop(\s|$)/
  bot.api.send_message(chat_id: update.chat.id, text: "Cart rebuild started...")
  Thread.new { system("cd #{project_root} && bundle exec ruby main.rb build-cart --force") }
```
Files: `lib/autochef/notify.rb`, `main.rb`

#### 2c. Screenshot sent as Telegram photo (not plain-text path)

`Screenshot: \`data/cart_screenshots/autochef-...\`` is a server-local path — useless on a phone. Replace with an actual Telegram photo upload.

Fix: after sending the text cart-ready message, call `bot_api.send_photo`:
```ruby
if result['screenshot_path'] && File.exist?(result['screenshot_path'])
  bot_api.send_photo(
    chat_id: @chat_id,
    photo: Faraday::UploadIO.new(result['screenshot_path'], 'image/png'),
    caption: "Cart as of #{run_key}"
  )
end
```
Remove the `Screenshot: \`...\`` text line from the message.
File: `lib/autochef/notify.rb`

---

### 3. Fix `est_total` Never Populated

**Known issue — deviation warning is silently disabled.**

`cart.py`'s `make_output(...)` never passes `est_total`. `safety.deviation_warning` receives `nil` and returns immediately — budget deviation checking never fires.

Fix: parse the cart total from the cart summary page in `cart.py` and include it in the JSON output as `est_total`. `safety.rb` already handles it; just needs the value piped through.

Files: `cart_builder/cart.py`, `lib/autochef/cart_client.rb`

---

### 4. Crash Alert on Total Plan Failure

**Known issue — scheduled runs can fail silently.**

If `main.rb plan` crashes before sending the Telegram draft (e.g. Mealie unreachable), nothing is sent. Mitigation: Uptime Kuma push monitor (not yet set up — see infrastructure section).

Fix: add a top-level rescue around `cmd_plan` that sends a minimal Telegram alert on unhandled exception:
```ruby
rescue => e
  Autochef::Notify.send_crash_alert("plan", e)
end
```
`send_crash_alert` should use a bare HTTP POST (no bot polling dependency) so it works even if the bot thread never started.

File: `lib/autochef/notify.rb`, `main.rb`

---

## New Features

### 5. Debug Screenshots

Take screenshots at each meaningful step of the cart build. Keep a rolling window of the last 2 full run directories.

**Screenshots to capture (in order):**
1. After `navigate_to_store` + modal dismissal — confirm we're on the right page
2. After `clear_cart` — confirm cart is empty
3. After `set_pickup_mode` — confirm pickup tab active
4. After each `add_item_to_cart` success — confirm item appeared in cart count
5. After `capture_cart_summary` — the final cart view (same as current `run_key.png`)
6. On any exception — error screenshot (already exists)

**Implementation:**
```python
debug_dir = SCREENSHOT_DIR / run_key
debug_dir.mkdir(parents=True, exist_ok=True)
page.screenshot(path=str(debug_dir / "01_store_loaded.png"))
```

Rolling window: at the start of `run_build_cart()`, list all subdirectories of `SCREENSHOT_DIR` sorted by mtime. If more than 1 exists, delete the oldest.

The final summary screenshot (`run_key.png`) stays as-is for the Telegram notification.

**Env var** `DEBUG_SCREENSHOTS_PATH`: if set, rsync/copy the debug run directory there after completion.

**Key files:**
- `cart_builder/cart.py` — `run_build_cart()`: per-step screenshots, rolling cleanup, optional copy to `DEBUG_SCREENSHOTS_PATH`
- `.env.example` — document `DEBUG_SCREENSHOTS_PATH`

---

### 6. LLM Assisted Recipe Mapping

Replaces the manual `seed_product_map.rb` interactive flow. Claude Haiku suggests `search_term`, `qty`, `unit` for new ingredients, auto-saves them, and generates a Telegram review report. Also flags suspicious existing mappings.

**Triggers:**
- Automatically after a recipe is imported via the `/newrecipes` flow (see spec below)
- Telegram command `/automap` — runs on-demand for any unmapped ingredients in the active shopping list
- `bundle exec ruby scripts/auto_map.rb` — CLI fallback

**What it does:**
1. Fetches unmapped ingredients from the Mealie "Next Order" shopping list (same source as `seed_product_map.rb`)
2. For each: LLM suggests `{search_term, qty, unit, pantry_skip: bool}` given the ingredient name, quantity, unit, recipe name, and serving size
3. Auto-saves all suggestions to `product_map`
4. For existing entries: flags any that look suspicious (qty seems off for serving size, search term too generic, `__skip__` on something that should be real, etc.) — flags go in the report, no auto-overwrite
5. Sends Telegram report: "Mapped 8 new ingredients. Flagged 2 suspicious existing — run `seed_product_map.rb --list` to inspect."

**Scope:** unmapped ingredients are auto-saved; suspicious existing entries are flagged only (Bailey corrects via `seed_product_map.rb --update`).

**Key files:**
- `scripts/auto_map.rb` — new CLI entry point
- `lib/autochef/llm_recipe_mapper.rb` — new: builds context, calls Claude Haiku, parses suggestions, writes to product_map
- `lib/autochef/notify.rb` — new `send_automap_report` method
- `main.rb` — `/automap` Telegram command handler; call `LlmRecipeMapper` after recipe import in `/newrecipes` flow

---

### 7. LLM Cart Review

After every `build-cart` run, the LLM reviews the cart via screenshot + Claude vision, compares against the original shopping list, identifies issues, and auto-applies corrections via Playwright before the cart-ready message is sent.

**Trigger:** Always runs automatically after `cart.py` completes. Runs before the Telegram notification is sent.

**Data format:** Screenshot of the final cart view (same screenshot already captured by cart.py). Intermediate review screenshots are deleted after the review completes — only the final summary screenshot is kept and sent to Telegram.

**What the LLM checks:**
- Wrong product for the recipe need (e.g. "imitation lemon juice" when recipe needs a fresh lemon)
- Quantities that are off for the serving size (e.g. 2.5lb salmon when plan calls for 1 serving)
- Missing items visible in the shopping list but not in the cart
- Consolidation/rationalization issues (the "2 squeezes of lemon → 1 lemon" category)

**Correction flow:**
1. LLM receives the cart screenshot + original `cart_items` list (search terms and intended qtys)
2. LLM returns a correction plan: `[{action: "remove" | "add" | "adjust_qty", item: "...", reason: "..."}]`
3. `cart_client.rb` passes the correction plan to `cart.py` via IPC (JSON, same pipe as normal cart build)
4. `cart.py` executes corrections: remove item, re-search with corrected term, add correct item
5. After corrections, `cart.py` takes a fresh final screenshot for the Telegram notification

**When LLM cannot correct:**
- Product genuinely not available on Food Lion
- LLM is uncertain and won't guess
- → Adds a note to the Telegram cart-ready message: "⚠️ Salmon fillet: 2.4lb pack only — verify manually."

**Key files:**
- `lib/autochef/llm_cart_reviewer.rb` — new: calls Claude vision API, returns correction plan
- `cart_builder/cart.py` — accept `--corrections` JSON argument; execute correction steps
- `lib/autochef/cart_client.rb` — invoke cart.py twice if corrections exist (build pass, then correction pass)
- `lib/autochef/notify.rb` — `send_cart_ready`: add `correction_notes:` kwarg
- `main.rb` — `cmd_build_cart`: after cart.py returns, call `LlmCartReviewer.review`, pass corrections back

---

### 8. LLM Aided Shopping

Before adding each item to the Food Lion cart, the LLM reviews available search results (via screenshot) and picks the best match based on recipe needs and stored preferences. Toggleable from Telegram — on by default.

**Toggle:** On by default. Toggle with Telegram `/shopping-llm on` or `/shopping-llm off`. State persisted in DB. When off, `cart.py` falls back to the existing "add first result" behavior — normal build-cart always works.

**Flow per item (when enabled):**
1. `cart.py` searches for the item (existing behavior)
2. Instead of immediately clicking Add, captures a screenshot of the search results page
3. Screenshot + context (recipe need, qty, unit, matching `PreferenceNote`s) sent to LLM
4. LLM returns: `{action: "add" | "skip", result_index: N, reason: "..."}`
5. `cart.py` adds the selected result, or skips and records the reason
6. Skip/flag reasons collected across all items → included in Telegram cart-ready message

**PreferenceNote model (new AR model, migration 012):**
- `ingredient_pattern` STRING — matched against cart item search term (substring match)
- `note` TEXT — freeform: "always get Organic Valley 2% milk", "store brand OK for butter", "never imitation"
- `created_at`, `updated_at`

**How preferences are collected (naturally, non-disruptive):**
- When the LLM skips an item, the Telegram skip note prompts: "Skipped: shredded cheese — no preference on file. Use `/prefs add 'shredded cheese' 'Kraft Mexican blend 8oz'` to set one."
- Bailey can ignore the hint entirely — the flow still works, LLM just picks best available next time
- `/prefs list`, `/prefs add <pattern> <note>`, `/prefs delete <id>` — Telegram commands

**Tuning:**
- Preferences narrow the LLM's choices for specific items
- For items with no preference, LLM picks based on recipe need and common sense (brand swap OK, fake substitute not OK)
- `seed_product_map.rb --update` still works for fixing search terms; preferences are separate from the product map

**Fallback (LLM can't pick a good option):**
- Item is skipped — not added to cart
- Telegram note: "⚠️ Could not find a good match for [item] — add manually."
- No bad options added; small substitutions OK (brand swap), genuine different product is not OK

**Feasibility notes:**
- Adds 1–3 seconds per item (Playwright screenshot) + LLM call overhead
- Est. API cost: ~$0.01–0.05 per build-cart run at 24 items
- Food Lion search results are fairly consistent but watch for DOM changes
- Toggle off immediately if it breaks; normal cart build is always the fallback

**Key files:**
- `lib/autochef/models/preference_note.rb` — new AR model
- `lib/autochef/database.rb` — migration 012 (`preference_notes` table)
- `lib/autochef/llm_shopping_selector.rb` — new: screenshot → LLM → selection decision per item
- `cart_builder/cart.py` — accept `--llm-shopping` flag; capture search result screenshots; receive LLM decisions
- `lib/autochef/cart_client.rb` — pass toggle state and preference notes to cart.py
- `lib/autochef/notify.rb` — handle skip notes in `send_cart_ready`
- `main.rb` — `/prefs` and `/shopping-llm` Telegram command handlers

---

### 9. Recipe Sleep

Allow Bailey to put a recipe to sleep from the plan approval or swap flow. Sleeping recipes are excluded from the eligible pool until the sleep expires.

**Sleep duration progression:**

| `sleep_count` before this sleep | Duration |
|---|---|
| 0 | 2 weeks |
| 1 | 4 weeks |
| 2 | 16 weeks |
| 3 | 32 weeks |
| 4+ | 52 weeks (cap — recipe always returns within a year) |

Reset: clears `sleep_count` to 0 and `sleep_until` to nil. Available via `/sleeping` command.

**DB changes (new migration 010):**
Add to `recipe_stats`:
- `sleep_until` DATE nullable — date when sleep expires (nil = not sleeping)
- `sleep_count` INTEGER NOT NULL DEFAULT 0

**Eligibility check:**
In `scorer.rb` / `planner.rb`: exclude any `RecipeStat` where `sleep_until IS NOT NULL AND sleep_until > Date.today`.

**Bot flow — plan approval message:**
```
[✅ Keep] [🔁 Swap] [😴 Sleep]
```

**Swap flow** — Sleep is the first option presented before swap candidates:
```
[😴 Sleep this recipe instead] [Swap candidate 1] [Swap candidate 2] ...
```

**After tapping Sleep:**
- Compute duration from `sleep_count`
- Set `sleep_until = Date.today + duration_days`, increment `sleep_count`
- Auto-swap the slept recipe with the next best candidate
- Bot replies: "😴 [Recipe] sleeping for N weeks (returns [date]). Swapped with [replacement]."

**`/sleeping` command:**
```
*Sleeping recipes:*
  • Greek Salmon — wakes up Thu Jul 30 (2 wks, sleep #1)
  [Reset]
```
Reset button clears `sleep_until` and `sleep_count` for that recipe.

**Key files:**
- `lib/autochef/database.rb` — migration 010
- `lib/autochef/models/recipe_stat.rb` — `sleep_duration_weeks` helper + eligibility scope
- `lib/autochef/scorer.rb` — filter sleeping recipes before scoring
- `lib/autochef/notify.rb` — Sleep buttons in plan + swap flow; `/sleeping` handler
- `main.rb` — `cmd_sleeping`; `sleep_recipe`, `reset_sleep` callback handlers

---

### 10. LLM Recipe Suggestions (`/newrecipes`)

Bailey can trigger a new-recipe suggestion round from Telegram at any time. Claude Sonnet looks at what Bailey likes and finds 3 new recipes — using web search first, generating from training data as fallback.

**Context sent to LLM:**
- Recipes with `times_planned >= 2` OR Mealie `rating >= 4` OR positive feedback → "liked" recipes with cuisine/protein/effort tags
- Current recipe pool (to avoid re-suggesting something already in Mealie)
- Last N suggestion feedback entries (so suggestions improve over time)

**LLM call:**
- Model: Claude Sonnet (has `web_search` tool)
- Web search: finds real recipe URLs from reputable sources (Serious Eats, NYT Cooking, AllRecipes)
- Fallback: generation from training data, marked `source: generated`
- Output per suggestion: `{name, source_url | null, description, why_it_fits}`

**Telegram flow — one message per suggestion:**
```
*[Recipe Name]*
[2-sentence description]
Source: [URL] — or — Generated by Claude
Why it fits: [rationale]

[✅ Import] [❌ Skip] [💬 Feedback]
```

- **✅ Import**: Mealie import flow (POST create by name → PATCH with tags + metadata → sync equivalent) → "✅ [Recipe] added to Mealie." → then triggers LLM Assisted Recipe Mapping for the new recipe's ingredients
- **❌ Skip**: records skip in DB + log, no comment required
- **💬 Feedback**: bot prompts "What didn't you like?" → records text in DB + log

**Feedback storage — `recipe_suggestion_feedback` table (migration 011):**
- `id`, `recipe_name`, `source_url`, `action` (imported/skipped/feedback), `feedback_text`, `suggested_at`, `acted_at`

**Text export `data/suggestion_feedback.txt`:** append-only log:
```
2026-07-01 | Greek Chicken Bowl | https://... | skipped | "not a fan of bowl meals"
```

**Key files:**
- `lib/autochef/llm_recipe_suggester.rb` — new
- `lib/autochef/models/recipe_suggestion_feedback.rb` — new AR model
- `lib/autochef/database.rb` — migration 011
- `lib/autochef/notify.rb` — `send_recipe_suggestions` + suggestion buttons
- `main.rb` — `cmd_newrecipes`; `/newrecipes` bot command; `import_suggestion`, `skip_suggestion`, `feedback_suggestion` callbacks

---

## Infrastructure

### 11. Docker Deployment on Unraid

After stable local operation is confirmed.

Dockerfile and `docker-compose.yml` already exist in `docker/`. Key considerations:
- `CART_BUILDER_PYTHON` in Docker will point to the venv Python inside the container
- `headless=False` in `cart.py` requires a display (Xvfb) in Docker — needs `DISPLAY=:99` and `xvfb-run`
- `playwright_state.json` must be volume-mounted (persists across container restarts)
- Mealie URL switches from `http://192.168.1.64:3000` to `http://mealie:9000` on `mealie_net`

### 12. Uptime Kuma Push Monitor

Bailey creates a Push monitor in Kuma at `192.168.1.64:3001`, pastes the push URL into `.env` as `UPTIME_KUMA_PUSH_URL`. `main.rb plan` already has a stub to POST to this URL after a successful run.

### 13. MCP Setup

Docker MCP server so Claude Code can manage containers directly. Deferred until Docker deployment is stable.
