# Feature 23 — Telegram Command Audit & NLP Generalization

> **Status:** Placeholder — spec interview incomplete.
> **Priority:** Medium — should be done before Features 18–22 add more commands.
>
> **Spec completeness:** The audit criteria are clear from Bailey's description. An interview pass
> is needed to apply the criteria to the actual command list and agree on changes before implementing.

---

## Goal

Review all Telegram commands for clarity, naming, discoverability, and necessity. Generalize
natural language processing in code where possible. Ensure every command that could benefit from
NLP has it, with a Telegram "form" fallback if NLP fails.

---

## Bailey's description (verbatim)

> Review and consolidate telegram commands. Make sure all are clear and well documented. Make sure
> names are obvious — what you would guess they would be reading the description. Make sure all are
> still needed. Make sure overall flow is obvious to a new user just reading the list. Make sure
> any that could be improved with natural language processing have it. Generalize language
> processing in code where possible, this is becoming common. Always have a fallback telegram
> "form" for inputs needed if language processing fails. Audit existing commands with these criteria
> and plan improvements, consolidations, renamings, etc.

---

## Context and background

**Current Telegram commands (as of twentieth session):**

| Command | Handler | Has NLP? |
|---|---|---|
| `/plan` | `cmd_plan` | No (triggers pipeline) |
| `/shop` | `cmd_shop` | No (triggers pipeline) |
| `/add <item>` | `cmd_add` → `cmd_add_llm` | ✅ LlmItemParser |
| `/automap` | `cmd_automap` | No (triggers pipeline) |
| `/newrecipes [note]` | `cmd_newrecipes` (Feature 10, not built) | Yes (note is freeform) |
| `/recipelist` | `cmd_recipelist` (Feature 11, not built) | No |
| `/recipe <day or title>` | `cmd_recipe` (Feature 11, not built) | Fuzzy match |
| `/cart-correction <text>` | `cmd_cart_correction` (Feature 7, not built) | ✅ LlmItemParser-style |
| `/set-meal <text>` | `cmd_set_meal` (Feature 22, not built) | ✅ planned |
| `/prefs add/list/delete` | (Feature 8, not built) | Structured subcommand |
| `/shopping-llm on/off` | (Feature 8, not built) | No |
| `/sleeping` | `cmd_sleeping` (Feature 9, not built) | No |
| `/help` | inline | N/A |

**What NLP generalization means in code:**

Currently `LlmItemParser` handles `/add` and (planned) `/cart-correction`. A shared
`NlpParser` base class or module could handle: structured extraction from free text, button
fallback form, pending state management — reused across all NLP-enabled commands. Feature 22
(`/set-meal`) is already designed to use this pattern.

---

## Known decisions (from description)

- All commands must have obvious names (what you'd guess from the description)
- All must still be needed (prune dead/redundant commands)
- New-user discoverability: `/help` must accurately reflect the full command set
- NLP where applicable, form fallback if NLP fails
- Generalize NLP code — don't duplicate `LlmItemParser` patterns per command

---

## Open questions (interview needed)

This feature is fundamentally an audit, so the key interview step is:

1. Walk through the current command list together and apply each criterion:
   - Is this name obvious?
   - Is this command still needed?
   - Should this have NLP?
   - Should any of these be merged?

**Specific questions to prompt that conversation:**

2. `/automap` — is this name obvious? Would `/map-ingredients` or `/update-map` be clearer?
3. `/prefs` — is this obviously about dietary/product preferences? Could it conflict with
   other types of preferences (week layout prefs, etc.)?
4. `/shopping-llm on/off` — is this the right name? `/ai-shopping` or `/smart-cart`?
5. Should there be a single `/settings` command that routes to sub-settings rather than
   per-feature toggle commands?
6. Are there commands Bailey no longer wants or that should be removed?
7. Should `/plan`, `/shop`, `/add` suggest next steps inline (covered more in Feature 24)?

**NLP generalization design:**
8. Should a shared `NlpCommand` base class be extracted, or keep it as a module/mixin?
9. What's the button fallback form standard? A "fill in the blank" style with one button
   per missing field, or a step-by-step prompt?

---

## Technical notes (preliminary)

- Central file: `lib/autochef/notify.rb` — all command handlers live here
- NLP generalization: extract a `lib/autochef/nlp_command.rb` or similar shared base
  (pattern already exists in `LlmItemParser` and `LlmItemParser`-style `/cart-correction`)
- `/help` text update is always part of any command addition or rename
- Renaming commands: Telegram bot commands are registered in the bot's BotFather config;
  they also need updating in `handle_message` dispatch in `notify.rb`
- This audit should happen *before* Features 18–22 add more commands, so new commands
  follow the agreed naming/NLP conventions from day one
