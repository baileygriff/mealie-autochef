# Feature 8 — LLM Aided Shopping

> **Status:** Spec — not yet implemented.
>
> **Lifecycle:** Once implemented, remove the Key Files section, fill in actual LLM prompt details,
> observed token costs per run, and any Food Lion DOM notes about search result screenshots.

---

## Goal

Before adding each item to the Food Lion cart, an LLM reviews available search results (via
screenshot) and picks the best match based on recipe needs and stored preferences. Toggleable
from Telegram — on by default, with a graceful fallback to the current "add first result" behavior.

---

## What this does NOT do

- Does not replace the product map — preferences are layered on top
- `seed_product_map.rb --update` still works for fixing search terms
- When off, cart build works exactly as before

---

## Toggle

On by default. Toggle with `/shopping-llm on` or `/shopping-llm off`. State persisted in DB.

---

## Flow per item (when enabled)

1. `cart.py` searches for the item (existing behavior)
2. Instead of immediately clicking Add, captures a screenshot of the search results page
3. Screenshot + context (recipe need, qty, unit, matching `PreferenceNote`s) sent to LLM
4. LLM returns: `{action: "add" | "skip", result_index: N, reason: "..."}`
5. `cart.py` adds the selected result, or skips and records the reason
6. Skip/flag reasons collected → included in Telegram cart-ready message

---

## PreferenceNote model (new, migration 012)

| Field | Type | Purpose |
|---|---|---|
| `ingredient_pattern` | STRING | Matched against cart item search term (substring match) |
| `note` | TEXT | Freeform: "always get Organic Valley 2% milk", "store brand OK for butter" |
| `created_at`, `updated_at` | | |

### How preferences are collected naturally

When the LLM skips an item, the Telegram skip note prompts:
> "Skipped: shredded cheese — no preference on file. Use `/prefs add 'shredded cheese' 'Kraft Mexican blend 8oz'` to set one."

Bailey can ignore the hint — the flow still works.

**Telegram commands:**
- `/prefs list` — show all preference notes
- `/prefs add <pattern> <note>` — add a preference
- `/prefs delete <id>` — remove one

---

## Tuning

- With a preference: LLM narrows choices to the specified product/variant
- Without a preference: LLM picks based on recipe need and common sense (brand swap OK, fake substitute not OK)

---

## Fallback (LLM can't pick a good option)

- Item is skipped — not added to cart
- Telegram note: "⚠️ Could not find a good match for [item] — add manually."
- No bad options added; small substitutions OK (brand swap), genuinely different product is not OK

---

## Feasibility notes

- Adds 1–3 seconds per item (Playwright screenshot) + LLM call overhead
- Est. API cost: ~$0.01–0.05 per build-cart run at 24 items (Claude Haiku or Sonnet with vision)
- Toggle off immediately if it breaks; normal cart build is always the fallback
- Food Lion search results are fairly consistent but watch for DOM changes

---

## Key files

| File | Change |
|---|---|
| `lib/autochef/models/preference_note.rb` | New AR model |
| `lib/autochef/database.rb` | Migration 012 (`preference_notes` table) |
| `lib/autochef/llm_shopping_selector.rb` | New: screenshot → LLM → selection decision per item |
| `cart_builder/cart.py` | Accept `--llm-shopping` flag; capture search result screenshots; receive LLM decisions |
| `lib/autochef/cart_client.rb` | Pass toggle state and preference notes to `cart.py` |
| `lib/autochef/notify.rb` | Handle skip notes in `send_cart_ready`; `/prefs` and `/shopping-llm` commands |
| `main.rb` | `/prefs` and `/shopping-llm` Telegram command handlers |
