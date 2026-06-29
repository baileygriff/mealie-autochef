# Feature 18 — Dietary Preferences in Recipe Searcher

> **Status:** Placeholder — spec interview incomplete.
> **Priority:** Low.
>
> **Spec completeness:** The core ambiguity is what "recipe searcher" means. Interview needed to
> determine which layer(s) this applies to before any implementation details can be written.

---

## Goal

More automated support for dietary preferences — avoiding certain ingredients, cuisines, or
proteins when recipes are selected, planned, or suggested.

---

## Context and background

Two existing features already partially cover this space — watch for overlap:

**Feature 8 (LLM Aided Shopping) — `PreferenceNote` model:**
- `ingredient_pattern` (STRING) matched against cart item search term
- `note` (TEXT) freeform: "always get Organic Valley 2% milk", "never imitation"
- Applies at the **product selection layer** — which specific Food Lion product to add to cart
- Telegram commands: `/prefs add`, `/prefs list`, `/prefs delete`
- Status: specced, not yet built

**Feature 10 (`/newrecipes`):**
- Already uses past ratings and feedback to guide suggestions
- Feature 16 hook adds macro context
- Could be extended to also filter by dietary exclusions
- Status: specced, not yet built

The existing tag system (`cuisine`, `protein`, `effort`, etc.) already allows soft preference
expression through week configurator vibe settings and tag affinity scoring.

---

## Known decisions

None yet — the entire scope is open pending interview.

---

## Open questions (interview needed)

**The central question:**

> What is a concrete scenario where dietary preferences would help? Walk through it:
> "I want it to never suggest X" or "I want it to always buy brand Y" — which one?

This determines which layer(s) this feature touches:

| Layer | What it means | Overlap? |
|---|---|---|
| (a) Food Lion product selection | "always buy Kerrygold butter, never store brand" | Covered by Feature 8 `PreferenceNote` |
| (b) Recipe pool filter | "never plan shellfish", "exclude pork entirely" | New — meal-level exclusion |
| (c) `/newrecipes` suggestion filter | "don't suggest slow-cooker recipes" | Could extend Feature 10 |
| (d) All of the above | Unified dietary preference layer | Probably too broad for one spec |

**Follow-up questions once layer is determined:**
- Should preferences be stored in the DB or in `config.yaml`?
- Should recipe pool exclusions hard-filter (recipe never appears) or soft-penalize (recipe
  gets a low score but can still be selected if pool is exhausted)?
- How should preferences interact with the tag system? Are they additive or separate?
- How are preferences managed? Telegram commands? Sinatra web form? Both?
- Should preferences be per-user (relevant to Feature 20 — Multi-user Support)?

**If this is largely covered by Feature 8's `PreferenceNote` model:**
- Does Bailey want a single unified "preferences" layer that covers both product selection
  and recipe planning? If so, should Feature 8 and Feature 18 be merged or refactored together?

---

## Technical notes (preliminary)

- If meal-level exclusions are in scope: `scorer.rb` / `planner.rb` are the right places
- A new `DietaryPreference` model (separate from `PreferenceNote`) may be needed if scope goes
  beyond product selection
- Tag affinity scoring already supports soft preferences via dial weights — hard exclusions
  would require an eligibility filter similar to `sleep_until` in Feature 9
- Multi-user implications: preferences would need to be per-user if Feature 20 is built
