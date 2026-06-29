# Feature 24 — Streamline Telegram User Flow

> **Status:** Placeholder — spec interview incomplete.
> **Priority:** Medium — best done after or alongside Feature 23 (Command Audit).
>
> **Spec completeness:** The intent and examples are clear. Interview needed to walk through
> each step of the pipeline and agree on what "next step" suggestions look like and when they
> appear.

---

## Goal

Make the Telegram bot feel like a continuous app rather than a disconnected set of commands.
Sequential steps suggest the next action. Prompts guide the user naturally through the weekly
meal-planning pipeline.

---

## Bailey's description (verbatim)

> Streamline user flow in telegram. Make this feel like a continuous "app" more than a chat.
> Make sure steps are clear and well documented. Make sure steps that are usually sequential
> give suggestions to users about likely next steps. E.g. in /add, after adding item is
> confirmed, suggest they might want to use /shop to lock in their cart. /shop would give an
> updated cart summary and suggest you go to checkout or make corrections with command
> instructions. Make the prompts guide the user naturally through the process.

---

## Context and background

**The weekly pipeline (current):**

```
Monday: /plan  →  Approve/Swap/Regenerate
          ↓
      /shop  (generates Mealie shopping list + triggers cart build)
          ↓
      Cart ready → review → go to Food Lion To Go → place order
          ↓ (after pickup, Sunday)
      main.rb feedback  (run manually, not from Telegram)
```

**What's currently missing:** After each step completes, the bot says what happened but doesn't
tell you what to do next. A user new to the system would need to remember the sequence.

**Existing partial implementations:**
- After `/add` confirms: `notify.rb` already has a pantry hint mentioning `/shop`. Could be
  extended to also suggest `/shop` explicitly.
- Cart-ready message: links to Food Lion To Go. Could suggest `/cart-correction` if something
  looks off.

---

## Known decisions (from description)

- After `/add` confirmation → suggest `/shop`
- After cart is ready → suggest going to checkout or using `/cart-correction`
- Each step should make the next step obvious
- Bailey's word: "guide the user naturally through the process"

---

## Open questions (interview needed)

**Pipeline steps to walk through:**

For each step below, agree on what "next step suggestion" looks like:

1. **After plan draft sent** (Telegram approval message with buttons):
   - Already has [✅ Keep] [🔁 Swap] [🔄 Regen] — good. What else?
   - After all days are approved: explicitly suggest "Run `/shop` next"?

2. **After plan approved:**
   - Current behavior: "✅ Week approved. Shopping list will be built."
   - Should it automatically suggest running `/shop` or kick it off automatically?

3. **After `/shop` completes:**
   - Cart is queued/built. What does the bot say next?
   - Suggest reviewing the cart-ready message? Suggest `/cart-correction` proactively?

4. **After cart is ready:**
   - Current: Food Lion To Go link + pantry items + (future) review table
   - Should it say "Go to Food Lion To Go to place your order. Come back with `/feedback`
     after pickup."?

5. **After `/add` with LLM:**
   - After confirm: already hints at `/shop`. Make this more explicit?

6. **After `/feedback`:**
   - What does the bot say? "Feedback recorded. See you next Monday for planning."?

7. **After `/cart-correction` rebuild:**
   - Fresh review table. "Cart updated. Review above and place your order."?

**Scope questions:**
8. Should next-step suggestions be dismissable (a button to hide them)?
9. Should there be a `/status` command that tells the user where they are in the weekly
   cycle? ("Plan approved. Ready to shop. Try `/shop` to build your cart.")
10. Should `/help` show the pipeline steps in order, not just an alphabetical command list?

---

## Technical notes (preliminary)

- All changes in `lib/autochef/notify.rb` — the send methods that fire after each action
- No new DB schema needed — this is purely message content changes
- A `/status` command (if in scope) would need to check: `PlanHistory` (approved?), shopping
  list (built?), last `cart.py` run, last `feedback` run
- Next-step text should be consistent in style — "Next: use `/shop` to build your cart." is
  cleaner than freeform paragraph text
- This feature pairs naturally with Feature 23 (Command Audit) — both touch the same
  `notify.rb` send methods and `/help` text. Consider implementing together.
