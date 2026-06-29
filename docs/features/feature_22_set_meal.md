# Feature 22 — `/set-meal` Manual Recipe Selection

> **Status:** Placeholder — spec interview incomplete.
> **Priority:** Medium.
>
> **Spec completeness:** Bailey's description is clear on the UX intent. Key open questions are
> around how this interacts with the existing plan approval flow and what happens when a plan
> is already approved.

---

## Goal

Allow Bailey to pin a specific recipe to a specific day in the week plan via a natural language
Telegram command, with button-based gap-filling for any missing inputs.

---

## Context and background

**What already exists:**

- **Week configurator (Sinatra form):** Sets per-day *preferences* (meal type, vibe, servings,
  protein excludes) but does not pin a specific recipe
- **Plan approval flow:** After `main.rb plan` generates a week, Bailey can approve/swap/regenerate
  via Telegram inline buttons. Swap offers the next best candidates.
- **No existing way to say "I want Greek Salmon on Tuesday specifically"** before or after planning

**Relationship to existing features:**
- Feature 9 (Recipe Sleep) removes recipes from eligibility — this pins one in
- Feature 19 (Web UI) might eventually offer a visual week grid for drag-and-drop scheduling,
  but `/set-meal` is the Telegram-native path

---

## Bailey's description (verbatim)

> `/set-meal "Greek salmon for 2 on Tuesday for dinner"` natural language processing. Asks
> questions with buttons to fill in all gaps: recipe, servings, day, meal. If only 1 meal
> configured in settings, meal defaults to "dinner" for example. If servings not specified,
> use default. Other inputs required. Use recipe disambiguation if needed. Graceful failure
> if issue arises.

---

## Known decisions (from description)

- Natural language input via free text after `/set-meal`
- Button-based gap-filling if any required field is missing
- Defaults: meal type → "dinner" if only 1 meal type in config; servings → recipe default
- Recipe disambiguation via inline buttons (consistent with `/recipe` in Feature 11)
- Graceful failure with clear error message

---

## Open questions (interview needed)

**Timing / plan state:**
1. When can `/set-meal` be used?
   - (a) Before a plan is generated — pre-sets a constraint the planner respects
   - (b) After a plan is drafted but before approval — overrides one slot
   - (c) After a plan is approved — modifies an already-approved plan
   - (d) All of the above at different points in the week
2. If a plan is already approved when `/set-meal` runs, does it trigger a plan rebuild or just
   update the stored plan directly?

**Recipe lookup:**
3. Does the recipe have to be in the Mealie pool (tagged `auto-plan`)? Or can Bailey set any
   recipe in Mealie regardless of eligibility?
4. What happens if the specified recipe is currently sleeping (Feature 9)?

**Day/slot handling:**
5. What if the specified day is already assigned in the current plan — does it replace the
   existing assignment?
6. What if the day is a leftover day in the week layout config? Override it to cook, or error?

**Downstream effects:**
7. After `/set-meal` changes a plan slot, does the shopping list need to be regenerated?
   Should the bot suggest running `/shop` next?
8. If the set meal uses different ingredients than what was previously in the shopping list,
   is there a notification about that?

**Scope:**
9. Can Bailey set multiple meals in a single `/set-meal` command, or one at a time?

---

## Technical notes (preliminary)

- LLM parsing (same pattern as `/add` via `LlmItemParser`) to extract:
  `{ recipe_name, servings, day, meal_type }` from free text
- Recipe disambiguation: same inline button pattern as Feature 11 (`/recipe`)
- If pre-planning: a new `PlanConstraint` model or `WeekPref` extension to store the pinned
  assignment before `main.rb plan` runs
- If post-approval: direct update to `PlanHistory` + `plan_entries` (or equivalent structure)
- The planner (`planner.rb`) would need to respect pinned assignments when building the rest
  of the week
- Pending state in `@pending_states[user_id]` during button-based gap-filling
