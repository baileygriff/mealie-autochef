# Feature 17 — Recipe Display Refactor

> **Status:** Placeholder — spec to be written when implementing.
> **Priority:** Low — depends on Feature 16 (Nutrition Goals & Macro-Aware Planning).
>
> **Spec completeness:** No interview needed. Scope is clear; spec should be written immediately
> before implementation.

---

## Goal

Roll out the compact recipe display format (`Cal X; P Xg; F Xg; C Xg` on a second line)
consistently across all Telegram recipe-display contexts. Feature 16 must be built first — macro
data needs to exist before this is useful.

---

## Contexts to update

- Plan approval and swap flow (currently the only place macros appear after Feature 16)
- `/recipe` (Feature 11) — inline under recipe name
- `/recipelist` (Feature 11) — one line per recipe, compact
- Any future message context that shows a recipe

---

## Known decisions

- Format established by Feature 16: `Cal X; P Xg; F Xg; C Xg`
- ⚠️ flag placement per macro follows Feature 16's flag threshold logic
- This is a display-only change — no new data, no new DB columns

---

## Technical notes

- All macro data comes from `recipe_stats` columns added in Feature 16
- The flag logic lives in `notify.rb` or a helper; should be extracted to a shared method
  so all contexts use the same threshold logic
- Telegram message length: the macro line adds ~25 chars per recipe; watch for split threshold
  changes in `/recipe` (Feature 11)

---

## Key files

| File | Change |
|---|---|
| `lib/autochef/notify.rb` | Extend macro stat line + flag logic to all recipe-display contexts |
| Wherever Feature 11 sends `/recipe` / `/recipelist` responses | Add macro line |
