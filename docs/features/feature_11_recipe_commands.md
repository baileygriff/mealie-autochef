# Feature 11 — Recipe Telegram Commands (`/recipelist`, `/recipe`)

> **Status:** Spec — not yet implemented.
>
> **Lifecycle:** Once implemented, remove the Key Files section, fill in actual Telegram message
> length observations, and note any Mealie API behavior for ingredient scaling.

---

## Goal

Let Bailey look up the week's meal plan and fetch full recipe details (ingredients + instructions)
without leaving Telegram.

---

## `/recipelist`

Shows all cook days from the current approved week plan with recipe name and planned servings.

**Usage:**
```
/recipelist
```

**Response format:**
```
*Week of Monday, June 30*

Sun Jun 29: Greek Salmon with Rice Pilaf — 2 srv
Mon Jun 30: Chicken Thigh Tacos — 4 srv
Wed Jul 2: Sheet Pan Lemon Chicken — 4 srv
Fri Jul 4: Baked Ziti — 4 srv
```

- Shows only cook days (days with assigned recipes); leftover days are omitted
- Reads from the most recently approved `PlanHistory` record
- No Mealie API call needed — all data is in the local DB

---

## `/recipe`

Fetch full recipe details for a specific planned meal.

**By day (matches cook day in current week plan):**
```
/recipe Sunday
/recipe Sun
/recipe Sunday Dinner
```

**By fuzzy title (matched against current week's recipe names):**
```
/recipe salmon
/recipe greek salad
/recipe chicken tacos
```

**Disambiguation (when fuzzy match finds multiple candidates):**
```
Bot: Did you mean one of these?
[Greek Salmon with Rice Pilaf]  [Miso Salmon Bowl]
```
Inline button tap → sends the recipe.

---

## Recipe response format

Telegram has a 4096 character limit per message. Long recipes are split across two messages:

**Message 1 — ingredients:**
```
*Greek Salmon with Rice Pilaf*
_2 servings — Sunday, June 29_

*Ingredients:*
• 2 salmon fillets (6 oz each)
• 1 cup long-grain white rice
• 2 tbsp olive oil
• 1 lemon, juiced
• 2 cloves garlic, minced
• 1 tsp dried oregano
• Salt and pepper to taste
• 2 cups chicken broth
```

**Message 2 — instructions:**
```
*Instructions:*

1. Preheat oven to 400°F.
2. Cook rice in chicken broth per package directions.
3. Mix olive oil, lemon juice, garlic, and oregano.
...
```

Split threshold: ~3500 chars to leave room for Telegram overhead.

**Ingredient scaling:** Plan servings ÷ Mealie recipe default servings × each ingredient quantity.
Uses the same scaling logic as `ShoppingListBuilder`.

---

## Scope decisions

- `/recipe` searches **current week's plan only** (not the full Mealie pool)
- Future: `/recipepool <title>` — fuzzy search against all auto-plan tagged recipes in Mealie
  (separate backlog item)
- Disambiguation uses inline buttons (consistent with existing approve/swap UX)
- Phase 2 enhancement (future): LLM-formatted version where ingredient quantities are woven into
  step-by-step instructions. Spec separately when implementing.

---

## Data flow

1. Load latest approved `PlanHistory` from local DB
2. Filter to cook days only
3. For `/recipe` by day: match day abbreviation/name to plan entry
4. For `/recipe` by title: fuzzy-match recipe names in the plan (substring/word overlap)
5. Fetch full recipe from Mealie: `mealie_client.recipe(recipe_id)` (already exists)
6. Scale ingredients to plan servings
7. Format and send (split if > ~3500 chars)

---

## Key files

| File | Change |
|---|---|
| `lib/autochef/notify.rb` | `cmd_recipelist`, `cmd_recipe`, disambiguation button callbacks |
| `lib/autochef/mealie_client.rb` | `recipe(id)` already exists — no changes needed |
| `main.rb` | Register `/recipelist` and `/recipe` in `handle_message` |
| `main.rb` | `cmd_help` — add both new commands to help text |
