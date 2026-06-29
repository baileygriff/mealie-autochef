# Feature 16 — Nutrition Goals & Macro-Aware Planning

> **Status:** Spec — not yet implemented.
>
> **Lifecycle:** Once implemented, update this file: remove the Implementation Plan section, fill in
> actual file paths and key decisions made, document usage, known edge cases, and config tuning tips.
> This file then becomes the feature's living documentation for the lifetime of the project.

---

## Goal

Store all 4 macros (calories, protein, carbs, fat) per recipe in the local DB — sourced from Mealie
where available, LLM-estimated otherwise — and use them as a soft scoring tier in the planner. The
Telegram plan draft shows per-recipe macro stats with per-macro ⚠️ flags when a recipe could
significantly throw off daily goals.

---

## What this does NOT do

- Not a macro-tracker app. Does not log meals eaten or count daily intake.
- Does not touch the cart or shopping list.
- Does not refactor compact recipe display across all Telegram contexts — that is Feature 17.
- Lunch macro planning is config-only placeholder for now; scoring/flagging for lunch comes when
  that feature is built.
- Flags are advisory only — Bailey adjusts serving size and appetite himself.

---

## Trigger and happy path

1. **One-time backfill:** Run `scripts/backfill_macros.rb` — for each recipe in the pool, check if
   Mealie has `nutritionData`; if yes, copy values; if no, call LLM to estimate all 4 macros from
   recipe name + ingredients. Store in `recipe_stats` with `macro_source` and `macro_estimated_at`.
2. **New recipe import:** When a recipe is imported via `/newrecipes` (Feature 10), run the same
   check immediately after import — Mealie data if available, LLM estimate if not.
3. **Safety net at plan time:** If any eligible recipe is missing macro data when `main.rb plan`
   runs, estimate it before scoring proceeds.
4. **Planning:** Scorer uses stored macros as Tier 3 bonus in the tiered formula (see Scoring below).
5. **Plan draft:** Each recipe in the Telegram plan message includes a macro stat line, with ⚠️
   next to any macro that's significantly off target for a single dinner.

**Plan draft example:**
```
*Thursday — Dinner*
Greek Salmon with Rice Pilaf
Cal 820; P 42g; F 28g ⚠️; C 55g
```

---

## Config changes

### `config.yaml` — nutrition block (replaces old `target_protein_per_serving_g`)

```yaml
nutrition:
  enabled: true                    # global feature flag — false disables all macro scoring and flags
  daily_targets:
    calories: 2200                 # kcal/day
    protein_g: 150
    carbs_g: 200
    fat_g: 70
  meal_shares:
    dinner_pct: 35                 # % of daily target a single dinner is expected to cover
    lunch_pct: 30                  # reserved — unused until lunch planning feature is built
  flag_threshold_pct: 150          # flag when macro exceeds (or undercuts) this % of expected share
                                   # upper bound = flag_threshold_pct (150%)
                                   # lower bound = 100 - (flag_threshold_pct - 100) = 50%
```

### `config.yaml` — scoring_weights (converted from legacy floats to 0–10 dials)

```yaml
selection:
  scoring_weights:
    rating:       10   # dial: 0=off, 1=tiebreaker, 5=proportional, 10=heavily prioritized
    tag_affinity:  6
    recency:       8
    swap_penalty:  6
    macros:        3   # small bonus only — macros should never dominate recipe selection
```

### `config.yaml` — LLM model for estimation

```yaml
llm:
  models:
    nutrition_estimator: "claude-haiku-4-5-20251001"   # configurable for smarter estimation later
```

### Removed config fields

- `nutrition.target_protein_per_serving_g` — replaced by `nutrition.daily_targets.protein_g`
- `selection.scoring_weights.nutrition_fit` — replaced by `scoring_weights.macros`

---

## DB schema changes

New columns on `recipe_stats` — new migration (next sequential number after whichever of the
reserved 010–012 migrations from Recipe Sleep / suggestion_feedback / preference_notes are built
first):

```ruby
add_column :recipe_stats, :calories,           :float
add_column :recipe_stats, :protein_g,          :float
add_column :recipe_stats, :carbs_g,            :float
add_column :recipe_stats, :fat_g,              :float
add_column :recipe_stats, :macro_source,       :string    # "mealie" | "llm_estimate"
add_column :recipe_stats, :macro_estimated_at, :datetime
```

---

## Macro flag logic

Expected dinner amount per macro:
```
expected_dinner_g = daily_target_macro × (dinner_share_pct / 100.0)
```

| Macro | Flag triggers |
|---|---|
| Protein | ⚠️ if `actual_g < expected_dinner_g × 0.50` — low protein for a protein-goal dinner |
| Fat | ⚠️ if `actual_g > expected_dinner_g × 1.50` — dinner alone will blow daily fat budget |
| Carbs | ⚠️ if `actual_g > expected_dinner_g × 1.50` OR `actual_g < expected_dinner_g × 0.50` |
| Calories | ⚠️ if `actual_kcal > expected_dinner_kcal × 1.50` OR `actual_kcal < expected_dinner_kcal × 0.50` |

The 50% lower bound is derived from `flag_threshold_pct`: `100 - (150 - 100) = 50`. Both numbers
are always computed from that single config value so they stay in sync.

---

## Scoring system redesign (tiered)

Replaces the current flat weighted sum with a 3-tier structure. Each tier is scaled by an order
of magnitude so a maxed-out lower tier is unlikely to casually overtake the tier above it. This is
a practical soft guarantee — continuous float components make a mathematical proof impossible
without strict lexicographic sorting, which would remove the probabilistic "softness" the dial
system is designed for.

### Tiers and tier multipliers

| Tier | Signals | Multiplier |
|---|---|---|
| 1 — Preference | rating, tag_affinity | ×100 |
| 2 — Freshness | recency, swap_penalty | ×10 |
| 3 — Macros | macros | ×1 |

### Formula

```
score = 100 × (rating_term + tag_affinity_term)
      +  10 × (recency_term + swap_term)
      +   1 × (macros_term)

where each term = (dial/10) × normalized_component(0–1)
```

### Normalized components (all clamped to 0–1)

**Rating** — already 0–1, unchanged:
```ruby
rating_norm = [(avg_rating.to_f - 1.0) / 4.0, 0.0].max.clamp(0.0, 1.0)
```

**Tag affinity** — tag_weights drift unboundedly; use tanh to compress naturally:
```ruby
tag_affinity_norm = (Math.tanh(raw_mean_weight) + 1.0) / 2.0
```

**Recency** — invert to "freshness penalty" then bound:
```ruby
weeks_ago = (Date.today - last_cooked.to_date).to_f / 7.0
recency_norm = weeks_ago.positive? ? [1.0 / weeks_ago, 1.0].min : 0.0
```
_(Recipes inside `repeat_avoidance_weeks` are hard-filtered before scoring, so this soft penalty
covers the "recently cooked but technically eligible" zone.)_

**Swap penalty** — diminishing returns so repeated rejections don't grow without bound:
```ruby
swap_norm = 1.0 - (1.0 / (1.0 + times_swapped_out.to_f))
# 0 swaps → 0.0, 1 swap → 0.50, 3 swaps → 0.75, ∞ → 1.0 asymptote
```

**Macros** — 4-component average; semantics differ per macro:

```ruby
protein_fit  = [actual_protein_g / expected_dinner_protein_g,  1.0].min  # higher is good, capped
fat_fit      = actual_fat_g <= expected_dinner_fat_g ? 1.0 :
               expected_dinner_fat_g / actual_fat_g              # lower is good, penalize overage
carbs_fit    = [1.0 - (actual_carbs_g - expected_dinner_carbs_g).abs /
               expected_dinner_carbs_g, 0.0].max                 # closeness rewards, both directions
calories_fit = [1.0 - (actual_kcal - expected_dinner_kcal).abs /
               expected_dinner_kcal, 0.0].max                    # closeness rewards, both directions

macros_score = (protein_fit + fat_fit + carbs_fit + calories_fit) / 4.0
```

---

## LLM macro estimation

**Class:** `lib/autochef/llm_nutrition_estimator.rb`

**Input:** recipe name, ingredients list (from Mealie recipe fetch)
**Output:** `{ calories: Float, protein_g: Float, carbs_g: Float, fat_g: Float }` per serving
**Model:** `cfg.llm.models.nutrition_estimator` (default `claude-haiku-4-5-20251001`)
**Prompt style:** consistent with `LlmRecipeMapper` — structured JSON response, same
`StubProvider`-injectable pattern via `llm:` kwarg.

**Source priority:**
1. Mealie `nutritionData` present and non-zero → copy values, `macro_source: "mealie"`
2. Otherwise → LLM estimate → `macro_source: "llm_estimate"`, set `macro_estimated_at`

**Trigger points:**
- `scripts/backfill_macros.rb` — one-time; skips rows already populated; reports N estimated / N skipped
- New recipe import via `/newrecipes` (Feature 10) — runs immediately after import
- `main.rb plan` safety net — estimates any missing recipe before scoring (logs a warning)

---

## /newrecipes macro integration (Feature 10 hook)

When `nutrition.enabled: true`, `/newrecipes` passes macro goals as context to weight suggestions
toward macro-appropriate dinners by default.

Override flags (added to Feature 10 command handler):
- `--no-macros` — suppress macro context for this invocation (e.g. `/newrecipes --no-macros birthday cake`)
- `--macros` — force-enable even when `nutrition.enabled: false` globally

---

## Implementation plan

> This section is removed once the feature is built and replaced with implementation notes.

### Step 1 — DB migration + config update
- Write new migration (next sequential number) adding 6 columns to `recipe_stats`
- Update `NutritionConfig` in `config.rb`: replace `target_protein_per_serving_g` with
  `daily_targets`, `meal_shares`, `flag_threshold_pct` structs
- Update `ScoringWeights` in `config.rb`: rename `nutrition_fit` → `macros`; add integer
  validation 0–10 for all five dial fields
- Update `config.yaml` with new blocks as shown above
- Run `bundle exec rspec` — green

### Step 2 — LlmNutritionEstimator
- Create `lib/autochef/llm_nutrition_estimator.rb`
- Accepts `llm:` kwarg (same pattern as `LlmRecipeMapper`)
- Fetches Mealie nutritionData if available; calls LLM otherwise
- Writes results to `recipe_stats` row
- Create `spec/llm_nutrition_estimator_spec.rb` with `StubProvider`
- Run `bundle exec rspec` — green

### Step 3 — Backfill script + safety net
- Create `scripts/backfill_macros.rb` — iterate all `RecipeStat` rows, call estimator for missing
- Add safety-net call to `main.rb` plan path (before scoring, logs warning if triggered)
- Manual verify: `bundle exec ruby scripts/backfill_macros.rb` against all 11 recipes
- Confirm all rows populated, `macro_source` set correctly

### Step 4 — Scorer tiered redesign
- Rewrite `lib/autochef/scoring.rb`:
  - Remove `PROTEIN_TAG_ESTIMATES`, `protein_per_serving`, `protein_component`
  - Normalize all 5 components to 0–1 (tanh for tag_affinity, diminishing returns for swap)
  - Implement 3-tier formula with ×100/×10/×1 multipliers
  - New `macros_component(stat)` reads from `recipe_stats` columns
  - Update `score()` signature — remove `nutrition_data:` and `base_servings:` params (no longer needed)
- Update `spec/scoring_spec.rb`:
  - Tier ordering: dial=10 macros cannot beat dial=10 rating difference in typical range
  - dial=0 → 0 contribution; dial=10 → max contribution within tier
  - Each macro fit semantic: protein at-target=1.0; protein below → proportional;
    fat at-target=1.0; fat above → diminished; carbs/calories closeness both directions
- Run `bundle exec rspec` — green

### Step 5 — Plan draft macro display
- Update Telegram plan draft message in `notify.rb` to include macro stat line per recipe
- Apply flag logic: ⚠️ per macro using thresholds from config
- Hook `LlmNutritionEstimator` into Feature 10 `/newrecipes` import callback

### Step 6 — Cleanup
- Confirm no references to `PROTEIN_TAG_ESTIMATES`, `protein_per_serving`,
  `target_protein_per_serving_g`, or `nutrition_fit` remain anywhere in codebase
- Run `bundle exec ruby main.rb plan` — verify Telegram draft shows macro lines with correct flags
- Run `bundle exec rspec` — green, count ≥ previous

---

## Key files

| File | Change |
|---|---|
| `lib/autochef/llm_nutrition_estimator.rb` | New |
| `scripts/backfill_macros.rb` | New |
| `db/migrate/0XX_add_macros_to_recipe_stats.rb` | New |
| `spec/llm_nutrition_estimator_spec.rb` | New |
| `lib/autochef/scoring.rb` | Complete rewrite — tiered formula, remove protein heuristic |
| `lib/autochef/config.rb` | NutritionConfig + ScoringWeights struct changes |
| `config.yaml` | nutrition + scoring_weights blocks updated |
| `lib/autochef/notify.rb` | Macro stat line + ⚠️ flag logic in plan draft |
| `main.rb` | Safety net estimation call; Feature 10 import hook |

---

## Testing plan

- `spec/scoring_spec.rb` (extend) — tier ordering, dial=0/10 boundary conditions, all 4 macro fit
  semantics, flag threshold math
- `spec/llm_nutrition_estimator_spec.rb` (new) — StubProvider; Mealie data takes priority;
  correct 4-macro parse; handles LLM parse failure gracefully
- Manual: `scripts/backfill_macros.rb` populates all 11 recipes; `main.rb plan` produces Telegram
  draft with macro line + correct ⚠️ placement

---

## Definition of done

1. `scripts/backfill_macros.rb` runs successfully; all 11 recipes have macro data in `recipe_stats`.
2. `main.rb plan` produces a Telegram draft with `Cal X; P Xg; F Xg; C Xg` per recipe; ⚠️ placed
   correctly per macro flag logic.
3. `bundle exec rspec` green; scoring spec covers tier ordering and all macro fit semantics.
4. `config.yaml` has `flag_threshold_pct`, `meal_shares.dinner_pct`, `meal_shares.lunch_pct`,
   and 0–10 scoring dials — all obviously named.
5. `PROTEIN_TAG_ESTIMATES`, `protein_per_serving`, `target_protein_per_serving_g`,
   and `nutrition_fit` are gone from the codebase with no dead references.
6. `/newrecipes --no-macros birthday cake` suppresses macro context; `nutrition.enabled: false`
   disables the feature globally.
