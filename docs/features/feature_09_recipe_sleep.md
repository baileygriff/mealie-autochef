# Feature 9 — Recipe Sleep

> **Status:** Spec — not yet implemented.
>
> **Lifecycle:** Once implemented, remove the Key Files section, fill in actual migration number,
> and document the sleep count progression as observed in practice.

---

## Goal

Allow Bailey to put a recipe to sleep from the plan approval or swap flow. Sleeping recipes are
excluded from the eligible pool until the sleep expires.

---

## Sleep duration progression

| `sleep_count` before this sleep | Duration |
|---|---|
| 0 | 2 weeks |
| 1 | 4 weeks |
| 2 | 16 weeks |
| 3 | 32 weeks |
| 4+ | 52 weeks (cap — recipe always returns within a year) |

**Reset:** clears `sleep_count` to 0 and `sleep_until` to nil. Available via `/sleeping` command.

---

## DB changes (migration 010)

New columns on `recipe_stats`:

```ruby
add_column :recipe_stats, :sleep_until, :date     # nullable — nil = not sleeping
add_column :recipe_stats, :sleep_count, :integer, null: false, default: 0
```

**Eligibility check:** In `scorer.rb` / `planner.rb`: exclude any `RecipeStat` where
`sleep_until IS NOT NULL AND sleep_until > Date.today`.

---

## Bot flow — plan approval message

```
[✅ Keep] [🔁 Swap] [😴 Sleep]
```

**Swap flow** — Sleep is presented first, before swap candidates:
```
[😴 Sleep this recipe instead] [Swap candidate 1] [Swap candidate 2] ...
```

**After tapping Sleep:**
1. Compute duration from current `sleep_count`
2. Set `sleep_until = Date.today + duration_days`, increment `sleep_count`
3. Auto-swap the slept recipe with the next best candidate
4. Bot replies: "😴 [Recipe] sleeping for N weeks (returns [date]). Swapped with [replacement]."

---

## `/sleeping` command

```
*Sleeping recipes:*
  • Greek Salmon — wakes up Thu Jul 30 (2 wks, sleep #1)
  [Reset]
```

Reset button clears `sleep_until` and `sleep_count` for that recipe.

---

## Key files

| File | Change |
|---|---|
| `lib/autochef/database.rb` | Migration 010 |
| `lib/autochef/models/recipe_stat.rb` | `sleep_duration_weeks` helper + eligibility scope |
| `lib/autochef/scorer.rb` | Filter sleeping recipes before scoring |
| `lib/autochef/notify.rb` | Sleep buttons in plan + swap flow; `/sleeping` handler |
| `main.rb` | `cmd_sleeping`; `sleep_recipe`, `reset_sleep` callback handlers |
