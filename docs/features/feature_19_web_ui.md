# Feature 19 — Web UI

> **Status:** Placeholder — spec interview incomplete.
> **Priority:** Low.
>
> **Spec completeness:** Many open questions. A Sinatra week configurator already exists at
> `localhost:3456/week` — the key question is how far beyond that Bailey wants to go and whether
> this depends on Feature 20 (Multi-user Support) being built first.

---

## Goal

A web UI that ties preferences to an account, exposes settings management, and wraps recipe
management powered by Mealie.

---

## Context and background

**What already exists:**

A minimal Sinatra week configurator runs at `localhost:3456/week` (started with `main.rb serve`):
- DB-backed form for the week layout (`WeekPref` model, `sinatra_prefs_source.rb`, `web/app.rb`)
- Per-day controls: meal type, servings, vibe
- Global controls: protein-exclude chips, freeform note
- Not exposed externally — only accessible locally or via Tailscale
- A "⚙ Configure week" Telegram button links to it (URL uses `web.host` from config)

The Telegram bot handles most user-facing actions today. The web UI would be additive, not
a replacement.

---

## Known decisions

None yet — scope is fully open pending interview.

---

## Open questions (interview needed)

**Scope:**
1. What does "account" mean before multi-user exists? A single admin account with a login page?
   Or is "account" contingent on Feature 20 being built first?
2. What does "settings management" mean specifically?
   - `config.yaml` fields exposed as a web form?
   - Nutrition targets (Feature 16 dials)?
   - Scoring weight dials?
   - LLM model selection?
3. What does "recipe management" mean?
   - Browsing the Mealie recipe pool?
   - Editing tags/ratings?
   - Adding recipes to Mealie via the UI?
   - Or just viewing recipe data that Mealie already manages?

**Access:**
4. Is this localhost-only (like the existing week configurator) or externally accessible
   (e.g. exposed via Tailscale or a reverse proxy)?
5. If externally accessible, is authentication required?

**Framework:**
6. Extend the existing Sinatra app (`web/app.rb`) vs. a new framework (Rails, Roda, separate
   frontend)? The existing Sinatra app is minimal by design — a bigger scope may outgrow it.

**Dependency on Feature 20:**
7. If multi-user support is built first (Feature 20), accounts and per-user preferences are
   already in scope there. Should this web UI be specced after that conversation to avoid
   re-speccing?

**The "why":**
8. What does the current Telegram-only UX make frustrating or impossible that a web UI would fix?
   What's the primary pain point?

---

## Technical notes (preliminary)

- Existing Sinatra app: `lib/autochef/web/app.rb`, `lib/autochef/sinatra_prefs_source.rb`
- Existing `WeekPref` model already has DB-backed week configurator
- If authentication is needed: Sinatra has middleware for basic auth; anything more complex
  would be easier in Rails or Roda
- If this depends on Feature 20 (Multi-user): user model and session management from that
  feature would be the foundation
- Mealie already has a full web UI — "recipe management" here likely means a read/tag/rate
  view that integrates with the autochef scoring context, not a duplicate of Mealie's UI
