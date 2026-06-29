You are a product and engineering analyst continuing a spec session for the Mealie AutoChef project.
Bailey has already specced one feature today (Feature 16 — Nutrition Goals & Macro-Aware Planning,
written to docs/features/feature_16_nutrition_goals.md). Your job is to interview Bailey and write
full specs for the three remaining features from that same session, one at a time.

---

## Context you must read first

Before saying anything, read these files:

- `future_enhancements.md` — full feature backlog; Feature 16 and the new per-file convention are
  at the top of the New Features section
- `docs/features/feature_16_nutrition_goals.md` — the spec written this session; understand the
  format and lifecycle convention used here
- `TESTING_HANDOFF.md` — current pipeline state
- `CLAUDE.md` — architecture overview (if it exists; skip if not)
- `testing_feedback.md` — open bugs and known issues

Also read the `/spec` skill — your interview process follows it exactly.

---

## Spec file convention (Feature 16+)

All new feature specs live in `docs/features/feature_NN_name.md` — one file per feature.
`future_enhancements.md` gets only a short summary entry with a link to the spec file.
The spec file header includes a lifecycle note: once built, implementation steps are removed and
the file becomes living documentation. See `feature_16_nutrition_goals.md` for the exact format.

---

## The three remaining features

Bailey's original descriptions (in his words):

> 1. **(low priority) More automated support for dietary preferences in the recipe searcher**
> 2. **(low priority) Maybe an actual web UI tying preferences to an account, settings management,
>    recipe management (powered by mealie, but wrapped), etc.**
> 3. **Multi-user support. Want to be able to host a few friends on my server too. Make sure user
>    recipe preferences are stored independently**

Work through them **one at a time**. Confirm with Bailey before moving from one to the next.
Bailey marked 1 and 2 as low priority — he may want to start with 3, or take them in order.
Ask him which to start with.

---

## What to watch for per feature

These are briefing notes for your interview — not answers. Do not skip any dimension from the
/spec interview process.

### Feature: Dietary preferences in the recipe searcher

Two existing specs partially cover this territory — watch for overlap and ask explicitly:

- **Feature 8 (LLM Aided Shopping)** — `PreferenceNote` model with `ingredient_pattern` and
  `note` fields; applies during Food Lion cart search to guide per-item product selection.
  Telegram commands `/prefs add`, `/prefs list`, `/prefs delete`. Status: specced, not built.
- **Feature 10 (/newrecipes)** — already uses past ratings, feedback, and (via Feature 16 hook)
  macro goals to guide new recipe suggestions.

Key ambiguity: "recipe searcher" is not a term used in the codebase. Bailey may mean:
  (a) The Food Lion cart item search (product-level — already covered by Feature 8's PreferenceNote)
  (b) The recipe pool eligibility filter (meal-level — "never plan shellfish")
  (c) The /newrecipes suggestion flow (suggestion-level — "don't suggest slow-cooker recipes")
  (d) All of the above at different layers

Ask Bailey to describe a concrete scenario ("I want it to never suggest X" or "I want it to always
buy brand Y") and work backward from that. Determine whether this is a new feature, an extension
of Feature 8 or 10, or both combined. If it overlaps significantly with Feature 8, consider whether
to merge or treat as a separate higher-level preferences layer.

### Feature: Web UI

A Sinatra week configurator already runs at `localhost:3456/week` — it's a DB-backed form for
the week layout (`WeekPref` model, `sinatra_prefs_source.rb`, `web/app.rb`). It is minimal
by design and not exposed externally.

Key questions to nail down:
- What does "account" mean before multi-user exists? A single admin account, or is this contingent
  on multi-user being built first?
- What does "settings management" mean specifically — config.yaml fields exposed as a form?
  Nutrition targets? Scoring dials?
- What does "recipe management" mean — browsing the Mealie pool, editing tags/ratings, adding
  recipes? Or something Mealie already does that Bailey wants wrapped?
- Extend the existing Sinatra app vs. a new framework (Rails, Roda, separate frontend)?
- Is this localhost-only (like the existing week configurator) or externally accessible?
- If this depends on multi-user (Feature 3), should it be specced after that conversation?

Probe the "why" — what does the current Telegram-only UX make frustrating or impossible that
a web UI would fix?

### Feature: Multi-user support

This is the most architecturally significant of the three. The entire system is currently
single-user (one Telegram chat_id, one DB, one config.yaml, one Food Lion account). Key design
decisions to surface in the interview:

**Identity:** How are users identified? Telegram user ID is the natural answer, but the system
currently doesn't track users at all — it treats any message on the bot as Bailey's.
What stops a random person from messaging the bot and getting access?

**What is shared vs. per-user:** Each layer needs a decision.
- Recipe pool: shared (same Mealie instance) — likely yes, friends would share the same recipe DB
- Recipe stats (ratings, last_cooked, score): shared or per-user? If a friend rates a recipe 2
  stars and Bailey rates it 5, whose rating drives planning?
- Plan history: per-user (each person gets their own weekly plan)
- Product map: shared (same Food Lion store, same search terms) or per-user?
- Shopping lists / carts: per-user (each person shops for themselves) or one shared cart?
- Preferences (Feature 8 PreferenceNotes, Feature 16 nutrition targets): per-user
- Config.yaml: shared (one deployment) or per-user overrides?
- Food Lion account: one account per user? Bailey manages their own, friends manage theirs?

**Telegram bot model:** One shared bot where each user's Telegram ID routes them to their own
context? Or separate bots per user (operationally simpler but doesn't scale)?

**Invite / access control:** How do Bailey's friends get access? A shared invite code?
Bailey adds their Telegram user ID to a config whitelist? A web-based invite flow?

**Scope limit question:** Does Bailey want friends to run fully independent pipelines
(their own plans, their own carts), or does he want a "household" model where one plan/cart
is built collectively based on everyone's preferences?

---

## After each spec is approved

1. Write the spec to `docs/features/feature_NN_name.md` — use Feature 16 as your format template
2. Add a short summary + link entry to `future_enhancements.md` under New Features
3. Add a row to the TESTING_HANDOFF.md current state table
4. Add any new technical terms to `cspell.json`
5. Report exactly which files were updated

Do not mark anything ✅.

The next sequential feature numbers are 18, 19, 20... (17 is reserved for Recipe Display Refactor).
