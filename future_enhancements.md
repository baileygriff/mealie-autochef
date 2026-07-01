# Future Enhancements — Mealie AutoChef

**Rule: address feedback and improvements first, then new features.**
When asked "what's next," pick the next unchecked item from the Feedback section before moving to New Features.

**Spec convention (Feature 16+):** Each item has its own file under `docs/features/`. This file
is the index — short summary + status + link. The spec file is the source of truth for
implementation details. Items marked 🗂️ have a complete spec. Items marked ❓ have a placeholder
spec with open questions — interview Bailey before implementing. Completed items remain here as
a brief historical record.

---

## Feature Priority

**Last updated:** 2026-06-29 — re-sort this table whenever a feature is added or completed.

**Adding a new feature:** place it in the appropriate tier immediately. Default to Tier 3 unless
there is a clear argument for Tier 2 (high impact, no dependencies) or Tier 1 (small scope +
operational blocker). Never add without assigning a tier.

Per the feedback-first rule, all Feedback / Improvements items rank above New Features.
Within Feedback, order follows the Pending table below. Within each tier, order is roughly
impact × (1 / effort).

### Tier 1 — Do Next

All remaining Feedback / Improvements items. Complete these before any new features.

| Item | Category | Why first |
|---|---|---|
| Seamless Login Integration | Feedback | Replaces CapSolver path; always-login-first + automated slider + Telegram 2FA |
| Cart Builder Package Refactor (Steps 3–6) | Feedback | Enables browser-free Python tests; pre-req for FoodLionProvider isolation |
| Orchestrator Refactor (Sections 2–8) | Feedback | Per-function LLM model config; injectable notifier; `main.rb` → thin router |
| ~~Debug Screenshots~~ | ~~Feedback~~ | ~~Low effort; completes the feedback backlog~~ ✅ done |

### Tier 2 — New Features, Highest Impact

Work through these after all Tier 1 items are done. Ordered by impact / effort.

| Item | Category | Notes |
|---|---|---|
| Feature 9 — Recipe Sleep | Feature | Small DB migration; no dependencies; high day-to-day planner value |
| Feature 11 — Recipe Telegram Commands | Feature | No dependencies; useful UX; moderate effort |
| Feature 7 — Cart Review, Auto-Fix + `/cart-correction` | Feature | Highest-marked feature; requires `cart.py` `items_added` schema + LLM reviewer |
| Feature 16 — Nutrition Goals & Macro-Aware Planning | Feature | Redesigns scorer; includes Haiku macro backfill script |
| Feature 10 — LLM Recipe Suggestions (`/newrecipes`) | Feature | Grows the recipe pool; moderate effort |

### Tier 3 — Later / Interview Needed / Infrastructure

Lower priority, blocked on an interview, or deferred until a dependency is ready.

| Item | Category | Notes |
|---|---|---|
| Feature 8 — LLM Aided Shopping | Feature | Improves product selection; no hard dependency |
| Feature 17 — Recipe Display Refactor | Feature | Depends on Feature 16 |
| Feature 22 — `/set-meal` Manual Recipe Selection | Feature | ❓ interview needed |
| Feature 21 — AI Spend Kill Switch | Feature | ❓ interview needed |
| Feature 24 — Streamline Telegram UX Flow | Feature | ❓ interview needed |
| Feature 23 — Telegram Command Audit & NLP Generalization | Feature | ❓ interview needed |
| Feature 20 — Multi-user Support | Feature | ❓ interview needed |
| Feature 18 — Dietary Preferences in Recipe Searcher | Feature | ❓ interview needed |
| Feature 19 — Web UI | Feature | ❓ interview needed |
| Infra 12 — Unraid Xvfb | Infra | Required before Infra 13 |
| Infra 13 — Docker Deploy on Unraid | Infra | Depends on Infra 12 |
| Infra 14 — Uptime Kuma Push Monitor | Infra | Waiting on Bailey to create the monitor |
| Infra 15 — MCP Setup | Infra | Deferred until Docker stable |
| Doc 01 — Pipeline Documentation & Architecture Diagrams | Doc | ❓ interview needed |

---

## Feedback / Improvements

### Completed

- ✅ Enhancement 2 — LLM Quantity Consolidation (`lib/autochef/llm_qty_consolidator.rb`)
- ✅ Telegram UX: Food Lion Markdown link, `/shop` command, screenshot as photo
- ✅ `est_total` populated in `cart.py` output
- ✅ Crash alert on plan failure (`Notifier.send_crash_alert`, method-level rescue in `cmd_plan`)
- ✅ `/add` multi-item LLM flow — `LlmItemParser`, preview/confirm/edit/cancel, cart rebuild
- ✅ Automap Telegram report reformatted — two sections: Grocery additions + Pantry skips
- ✅ Previous Purchases cart optimization — PP-first add pass; 66 cards, 3/24 matched; verified end-to-end
- ✅ Session Expiry Detection (Option 1) — `detect_session_state()` in `cart.py`; Telegram alert + inline rebuild button
- ✅ Debug Screenshots — per-step shots in `data/cart_screenshots/<run_key>/`; rolling 2-run cleanup; `01_store_loaded.png` is the key Kasada timing diagnostic

### Pending

| Item | Status | Spec |
|---|---|---|
| Seamless Login Integration | 🔧 Path A implemented (twenty-eighth session), live-tested (twenty-ninth). Slider found ✅ IPC ✅ drag executes ✅ — drag falls ~13px short, DataDome rejects. Fix: `- random.uniform(5, 12)` → `+ random.uniform(3, 8)` in `_try_kasada_slider()`. Path B (noVNC) is fallback if slider automation can't be made reliable. | [improvement_login_integration.md](docs/features/improvement_login_integration.md) |
| ~~CapSolver Kasada Auto-solving~~ | ❌ Abandoned — `AntiKasadaTask` not supported in CapSolver live API; 2captcha doesn't support Kasada on standard plans | [improvement_capsolver.md](docs/features/improvement_capsolver.md) |
| Cart Builder Package Refactor | 🗂️ Complete spec (Step 2 done) | [improvement_cart_builder_refactor.md](docs/features/improvement_cart_builder_refactor.md) |
| Application Orchestrator Refactor | 🗂️ Complete spec (Section 1 done) | [improvement_orchestrator_refactor.md](docs/features/improvement_orchestrator_refactor.md) |

---

## New Features

| # | Feature | Priority | Status | Spec |
|---|---|---|---|---|
| 5 | Debug Screenshots | low | ✅ implemented (twenty-fourth session) | [improvement_debug_screenshots.md](docs/features/improvement_debug_screenshots.md) |
| 7 | Cart Review, Auto-Fix + `/cart-correction` | high | 🗂️ spec complete | [feature_07_cart_review.md](docs/features/feature_07_cart_review.md) |
| 8 | LLM Aided Shopping (per-item LLM product selection, `PreferenceNote` model) | medium | 🗂️ spec complete | [feature_08_llm_aided_shopping.md](docs/features/feature_08_llm_aided_shopping.md) |
| 9 | Recipe Sleep | medium | 🗂️ spec complete | [feature_09_recipe_sleep.md](docs/features/feature_09_recipe_sleep.md) |
| 10 | LLM Recipe Suggestions (`/newrecipes`) | medium | 🗂️ spec complete | [feature_10_newrecipes.md](docs/features/feature_10_newrecipes.md) |
| 11 | Recipe Telegram Commands (`/recipelist`, `/recipe`) | medium | 🗂️ spec complete | [feature_11_recipe_commands.md](docs/features/feature_11_recipe_commands.md) |
| 16 | Nutrition Goals & Macro-Aware Planning | medium | 🗂️ spec complete | [feature_16_nutrition_goals.md](docs/features/feature_16_nutrition_goals.md) |
| 17 | Recipe Display Refactor (macro line across all recipe contexts) | low | 🗂️ spec complete — depends on F16 | [feature_17_recipe_display_refactor.md](docs/features/feature_17_recipe_display_refactor.md) |
| 18 | Dietary Preferences in Recipe Searcher | low | ❓ interview needed | [feature_18_dietary_preferences.md](docs/features/feature_18_dietary_preferences.md) |
| 19 | Web UI (settings, recipe management, account) | low | ❓ interview needed | [feature_19_web_ui.md](docs/features/feature_19_web_ui.md) |
| 20 | Multi-user Support | medium | ❓ interview needed | [feature_20_multi_user.md](docs/features/feature_20_multi_user.md) |
| 21 | AI Spend Kill Switch (token/time thresholds, Telegram alert, debug log) | medium | ❓ interview needed | [feature_21_ai_spend_killswitch.md](docs/features/feature_21_ai_spend_killswitch.md) |
| 22 | `/set-meal` Manual Recipe Selection | medium | ❓ interview needed | [feature_22_set_meal.md](docs/features/feature_22_set_meal.md) |
| 23 | Telegram Command Audit & NLP Generalization | medium | ❓ interview needed | [feature_23_telegram_command_audit.md](docs/features/feature_23_telegram_command_audit.md) |
| 24 | Streamline Telegram User Flow (next-step guidance) | medium | ❓ interview needed | [feature_24_telegram_ux_flow.md](docs/features/feature_24_telegram_ux_flow.md) |

> **Note:** Feature 6 (LLM Assisted Recipe Mapping) is ✅ built and verified. Feature 5 (Debug
> Screenshots) spec appears in the improvements section since it's a cart.py enhancement.
> Numbers 1–4 were Feedback items completed in the ninth session.

---

## Infrastructure

| # | Item | Status | Spec |
|---|---|---|---|
| 12 | Unraid Docker Display (Xvfb) — **must be done before #13** | 🗂️ spec complete | [infra_12_xvfb.md](docs/features/infra_12_xvfb.md) |
| 13 | Docker Deployment on Unraid — blocked on #12 | 🗂️ spec complete | [infra_13_docker_deploy.md](docs/features/infra_13_docker_deploy.md) |
| 14 | Uptime Kuma Push Monitor — waiting on Bailey to create the monitor | 🗂️ spec complete | [infra_14_uptime_kuma.md](docs/features/infra_14_uptime_kuma.md) |
| 15 | MCP Setup — deferred until Docker is stable | 🗂️ spec complete | [infra_15_mcp.md](docs/features/infra_15_mcp.md) |

---

## Documentation

| # | Item | Status | Spec |
|---|---|---|---|
| Doc 01 | Pipeline Documentation & Architecture Diagrams | ❓ interview needed | [doc_01_pipeline_documentation.md](docs/features/doc_01_pipeline_documentation.md) |
