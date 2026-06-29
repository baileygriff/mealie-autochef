# Feature 7 — Cart Review, Auto-Fix + /cart-correction

> **Status:** Spec — not yet implemented.
>
> **Lifecycle:** Once implemented, remove the Migration Order and Key Files sections, fill in
> actual LLM prompt details, observed auto-fix success rates, and any selector/DOM notes.

---

## Goal

After a cart build, send Bailey a structured review table showing what was added vs. what recipes
called for. Auto-fix obvious wrong products before notification (one attempt each). Allow
post-notification human corrections via `/cart-correction` that permanently update the product
map and trigger a rebuild.

---

## What this does NOT do

- Does not auto-checkout or modify the order
- Auto-fix is one attempt only — no retry loops
- Does not replace the product map; corrections improve it permanently

---

## Full flow overview

1. `cart.py` builds the cart and returns per-item results (new `items_added` field)
2. `main.rb` calls `LlmCartReviewer` with the per-item results + screenshot
3. LLM auto-fixes "happy cases" (clear wrong product, wrong variant, obvious bad substitute) — one attempt each via targeted cart.py correction session
4. LLM categorizes all items into the review table
5. Cart-ready Telegram message includes the full review table
6. Bailey reviews and sends `/cart-correction` for anything missed
7. Corrections batch in `@pending_states`, user confirms with a button
8. Confirmed corrections update product_map (permanent) → `build-cart --force` → fresh review table

---

## cart.py output schema additions

New `items_added` array in the JSON output. Each entry covers one attempted item:

```python
{
  "status": "cart_built",
  # ... existing fields unchanged ...
  "items_added": [
    {
      "search_term": "chicken thighs",
      "product_name": "Food Lion Chicken Thighs Bone-In, 4 lbs",
      "product_qty_description": "4 lbs",
      "recipe_qty_requested": "2 lbs",
      "match_source": "previous_purchases",   # "previous_purchases" | "search"
      "pp_score": 0.85,                       # only when match_source == "previous_purchases"
      "added": true                           # false if item could not be added
    }
  ]
}
```

To populate `recipe_qty_requested`, the Ruby-side payload to cart.py is extended:
```python
{
  "search_term": "chicken thighs",
  "default_qty": 1,
  "pack_unit": "pkg",
  "recipe_qty_description": "2 lbs"   # new field
}
```

---

## `lib/autochef/llm_cart_reviewer.rb` — new class

```ruby
module Autochef
  CartReviewResult = Struct.new(
    :auto_corrected,      # Array<Hash> — items the LLM fixed before notification
    :auto_fix_failed,     # Array<Hash> — LLM tried to fix but couldn't
    :low_confidence,      # Array<Hash> — flagged for human review
    :qty_discrepancies,   # Array<Hash> — pack qty significantly off from recipe qty
    :high_confidence,     # Array<Hash> — items LLM considers correct
    :correction_attempts, # Integer
    keyword_init: true
  )

  class LlmCartReviewer
    def initialize(cfg, llm: nil)
      @llm = llm || Llm::AnthropicProvider.new(
        model: cfg.llm.models&.cart_reviewer || cfg.llm.default_model
      )
    end

    # items_added: the items_added array from cart.py output
    # screenshot_path: path to the final cart screenshot
    # Returns CartReviewResult
    def review(items_added:, screenshot_path:); end
  end
end
```

**LLM model:** Claude Sonnet (vision capability required for screenshot analysis).

**Auto-fix — "happy cases" only (one attempt each):**

The LLM tags each problem item with an `auto_fix_strategy`:
- `"re_search"` — search term was fine but wrong result selected
- `"variant_change"` — right category, wrong variant (skin-on vs. skinless)
- `"substitute_rejected"` — clearly wrong product (imitation vs. real)

For each:
1. Pass targeted correction to `cart.py`: `{remove_product: "...", replace_search_term: "..."}`
2. `cart.py` removes item, searches for replacement, adds first result
3. Success → `auto_corrected`; failure → `auto_fix_failed` → surfaces in `low_confidence`

Items with `auto_fix_strategy: nil` are never auto-fixed.

---

## Review table format (Telegram Markdown)

```
*Cart ready ✅*

Total: *$119.45*
Pickup slot: Thu 5:00–6:00 PM

[Open cart in Food Lion To Go](https://www.foodlion.com/shop)

---

*Ingredient Review*

⚠️ *Needs your attention (2 items)*
| Called For | Got |
|---|---|
| chicken thighs | Food Lion Bone-In Skin-On Chicken *Breast* |
| 1 lemon | ReaLemon Lemon Juice (8 fl oz bottle) |

📦 *Quantity notes (3 items)*
| Called For | Got |
|---|---|
| 1/4 cup sugar | Domino Granulated Sugar, 5 lb bag |
| 1 egg | Food Lion Large Eggs, 12-count |
| 1 tbsp olive oil | Pompeian Smooth EVOO, 16 fl oz |

✓ *Auto-corrected (1 item)*
| Originally added | Replaced with |
|---|---|
| Dannon Greek Yogurt Vanilla | Dannon Plain Whole Milk Yogurt (32oz) |

✓ *High confidence (18 items)*
```

Notes:
- High confidence items collapsed by default; available via `/cart-detail`
- Pantry items remain in their own section (existing behavior)
- `auto_fix_failed` items appear in "Needs your attention" with note: _(auto-fix attempted)_

---

## `/cart-correction` command

```
/cart-correction you picked chicken breasts but I want chicken thighs only or nothing
/cart-correction get real lemons instead of the ReaLemon bottle
```

**Flow:**
1. User sends `/cart-correction <free text>`
2. LLM parses into structured corrections:
   ```json
   [{ "current_product": "...", "action": "replace", "replacement_search_term": "chicken thighs", "or_nothing": true }]
   ```
3. Bot shows preview with [✅ Apply] [✏️ Edit] [➕ Add another] [🔄 Rebuild now]
4. User can batch multiple corrections before rebuilding
5. **Rebuild:** each correction updates `ProductMap` (permanent) → `build-cart --force` →
   fresh cart-ready message with new review table

**Why update product_map permanently:** Corrections improve future builds. If the correction is
one-off, the user notes that in free text and the LLM leaves product_map unchanged.

**Pending state:**
```ruby
{
  action:      :waiting_cart_correction,
  corrections: [{ current_product:, action:, replacement_search_term:, or_nothing:, update_product_map: }],
  run_key:     "2026-06-30-1"
}
```

---

## Migration order

**Step 1 — cart.py output extension:**
- Add `items_added` array to `run_build_cart()` return
- Track `product_name`, `product_qty_description` per `add_item_to_cart()` call
- Extend input payload to accept `recipe_qty_description` per item
- Update `cart_client.rb` to pass `recipe_qty_description`
- Verify: `build-cart --force` still works; `items_added` appears in output

**Step 2 — LlmCartReviewer (no auto-fix yet):**
- Implement `review()` — LLM categorizes items into four buckets
- Add `send_cart_review_table` to `notify.rb`
- Update `cmd_build_cart` to call reviewer + send table
- Verify: cart-ready message includes review table

**Step 3 — Auto-fix:**
- Add auto-fix pass to `LlmCartReviewer.review()`
- Add targeted correction mode to `cart.py` (remove + re-add without clearing full cart)
- Verify: at least one happy case gets auto-corrected end-to-end

**Step 4 — `/cart-correction`:**
- Add `cmd_cart_correction` handler to `notify.rb`
- LLM parsing → structured correction → preview + confirm → product_map update → rebuild
- Verify: send test correction, rebuild fires, new review table arrives

---

## Key files

| File | Change |
|---|---|
| `cart_builder/cart.py` | Extend `items_added` output; add targeted correction mode |
| `lib/autochef/cart_client.rb` | Pass `recipe_qty_description`; accept targeted correction payload |
| `lib/autochef/llm_cart_reviewer.rb` | New: vision LLM call, categorization, auto-fix |
| `lib/autochef/notify.rb` | `send_cart_review_table`, `cmd_cart_correction`, correction pending state |
| `main.rb` | Call `LlmCartReviewer.review` after `cmd_build_cart`; handle `/cart-correction` |
| `config.yaml` | Add `llm.models.cart_reviewer` (Claude Sonnet for vision) |
