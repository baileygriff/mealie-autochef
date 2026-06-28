# Testing Verifications — Mealie AutoChef

Track what has been tested end-to-end, what is known to work, and what still needs verification before the project is considered production-ready.

Updated at the end of each session alongside `testing_feedback.md`.

---

## Legend

| Symbol | Meaning |
|---|---|
| ✅ | Verified end-to-end on live system |
| ⏳ | Partially tested or tested indirectly |
| 🔧 | Implemented, not yet tested on live system |
| ❌ | Known broken or untested with a known risk |
| 🚫 | Blocked — depends on another step first |

---

## Core CLI Commands

| Command | Status | Notes | Session |
|---|---|---|---|
| `main.rb check` | ✅ | Result: OK, Mealie v3.19.2, 11 recipe pool | 2026-06-28 (10th) |
| `main.rb sync` | ✅ | 11 recipe stats populated in local DB | 2026-06-28 (9th) |
| `main.rb plan` | ✅ | LLM plan generated (plan id=5), Telegram draft sent | 2026-06-28 (10th) |
| `main.rb plan [note]` | ⏳ | Freeform note arg accepted; not tested with a note | — |
| `main.rb serve` | ✅ | Telegram bot + Sinatra start clean; Puma on port 3456 | 2026-06-28 (10th) |
| `main.rb shop` | ✅ | 35 items pushed to Mealie "Next Order" from plan id=5 | 2026-06-28 (10th) |
| `main.rb build-cart` | ✅ | 24/24 items added, $119.45 total, 0 flagged | 2026-06-28 (9th) |
| `main.rb build-cart --force` | ✅ | Cart cleared + rebuilt; clear_cart + OK dialog confirmed | 2026-06-28 (9th) |
| `main.rb feedback` | ❌ | Never tested — requires a completed week with an order_history row |
| `main.rb budget` | ❌ | Never tested |
| `main.rb backup` | ❌ | Never tested |

---

## Telegram Bot Flows

| Flow | Status | Notes | Session |
|---|---|---|---|
| Receive plan draft message | ✅ | Week layout, meal list, rationale, inline buttons | 2026-06-28 (10th) |
| Approve button | ✅ | plan_history `approved=true`, `last_planned` stamped on approval (not draft) | 2026-06-28 (10th) |
| Swap button | ✅ | Swap candidate sent; 1 swap completed before approval in 10th session | 2026-06-28 (10th) |
| Regenerate button (no note) | ⏳ | Implemented; tested in earlier sessions but not in 10th session |
| Regenerate with typed note | ❌ | Bot prompts for a freeform note before regenerating; never explicitly tested end-to-end |
| "⚙ Configure week" button | ❌ | Link URL uses `web.host` (192.168.1.64) — only works once deployed on Unraid. TODO after Docker deploy |
| `/help` command | 🔧 | Implemented, not explicitly tested |
| `/shop` command | 🔧 | Sends "Cart rebuild started", spawns `build-cart --force` in background thread; implemented in 9th session, not yet tested end-to-end |
| `/sleeping` command | 🚫 | Depends on Recipe Sleep feature (Feature 9) — not built yet |
| Cart-ready message | ✅ | Message sent, Food Lion Markdown link, pantry-skipped section | 2026-06-28 (9th) |
| Cart screenshot as Telegram photo | ✅ | `send_photo` verified; screenshot uploaded in 9th session | 2026-06-28 (9th) |
| Spending-cap abort alert | ⏳ | Code path exists; triggered once by accident (duplicate items pushed total to $312.66) | 2026-06-28 (9th) |
| Deviation alert (>20% off estimate) | ⏳ | Code path exists; `est_total` now populated so comparison runs, but 0% deviation on all tested runs | 2026-06-28 (9th) |
| Crash alert (`send_crash_alert`) | 🔧 | Implemented in 9th session; never triggered by an actual crash |
| Thaw reminder (18:00 push) | 🔧 | rufus-scheduler job registered on serve startup; never observed firing |
| Morning ping | 🔧 | rufus-scheduler job registered; never observed firing |

---

## Cart Builder (`cart.py`)

| Step | Status | Notes | Session |
|---|---|---|---|
| `--login` (interactive session setup) | ✅ | Full auth + 2FA, `playwright_state.json` saved | 2026-06-28 (9th) |
| `navigate_to_store` | ✅ | Confirmed on live Food Lion site | 2026-06-28 (9th) |
| `dismiss_modals` | ✅ | Backdrop click at (10,10) clears "Pick a Shopping Method" modal | 2026-06-28 (9th) |
| `clear_cart` | ✅ | Cleared 27–60 items correctly; OK confirmation dialog handled | 2026-06-28 (9th) |
| `set_pickup_mode` | ⏳ | Runs in flow; no explicit screenshot verification |
| `add_item_to_cart` | ✅ | 24/24 items matched using `text='Add to cart'` selector | 2026-06-28 (9th) |
| `capture_cart_summary` | ✅ | `cart_total`, `item_count` returned correctly; screenshot saved | 2026-06-28 (9th) |
| Out-of-stock / no-results handling | ⏳ | Code path exists (`flagged` list); never triggered on live runs |
| Session expiry re-login | ❌ | `playwright_state.json` will eventually expire; re-login flow documented but not re-tested since 2026-06-28 |

---

## Product Map & Shopping

| Step | Status | Notes | Session |
|---|---|---|---|
| `seed_product_map.rb` (interactive map) | ✅ | All 59 items from plan id=4 mapped or pantry-skipped | 2026-06-28 (9th) |
| `seed_product_map.rb --list` | ❌ | Flag exists; not tested |
| `seed_product_map.rb --update` | ❌ | Flag exists; not tested |
| Enhancement 1 — qty consolidation by search_term | ✅ | 30 items → 24 unique search terms, quantities summed | 2026-06-28 (9th) |
| Enhancement 2 — LLM qty consolidation | ✅ | `LlmQtyConsolidator` ran, adjustments printed to stdout | 2026-06-28 (9th) |
| Pantry skip (`__skip__` sentinel) | ✅ | 29 items silently dropped; listed in stdout + Telegram | 2026-06-28 (9th) |
| `main.rb automap` (LLM Assisted Recipe Mapping) | ✅ | Feature 6 — verified 2026-06-28 (12th): 35/35 plan id=5 items mapped (26 real, 9 pantry-skip), Telegram report sent. Bug fixed: key now uses original note text (indexed LLM response) so resolve_cart_item matches correctly |
| `/automap` Telegram command | 🔧 | Implemented; spawns `main.rb automap` in background thread; not yet tested end-to-end |
| `scripts/auto_map.rb` | 🔧 | CLI equivalent of `main.rb automap`; not yet tested on live system |

---

## Week Configurator (Sinatra form)

| Step | Status | Notes | Session |
|---|---|---|---|
| Server starts on port 3456 | ✅ | Puma binds to 0.0.0.0:3456 | 2026-06-28 (10th) |
| Form loads at `/week` | ⏳ | Accessible via `localhost:3456/week` on dev machine; Telegram link URL uses Unraid IP — TODO after Docker deploy |
| Per-day preferences saved to DB | ⏳ | Logic tested in spec; not verified end-to-end via browser |
| Prefs applied on Regenerate | ⏳ | Code path wired up; not tested with real prefs saved |

---

## Scripts

| Script | Status | Notes |
|---|---|---|
| `scripts/tag_recipes.rb` | ✅ | Used successfully to tag 11 recipes with auto-plan + metadata |
| `scripts/seed_product_map.rb` | ✅ | See Product Map section above |
| `scripts/import_recipes.rb` | ✅ | Used in earlier sessions to bulk-import recipes |

---

## Safety & Infrastructure

| Feature | Status | Notes |
|---|---|---|
| `dry_run: true` enforcement | ✅ | Cart always stops before checkout; never auto-placed |
| Spending cap (`$300`) | ⏳ | Triggered once accidentally at $312.66 — aborted correctly |
| Kill switch (`data/PAUSE`) | ❌ | Implemented; never tested |
| Idempotency / run key | ⏳ | Runs don't duplicate; not stress-tested |
| Budget tracking (`order_history`) | ⏳ | `est_total` now populated; `main.rb budget` command never tested |
| Uptime Kuma push | ❌ | Stub in `main.rb plan`; `UPTIME_KUMA_PUSH_URL` not configured yet |
| `main.rb backup` | ❌ | Never tested |

---

## Flows Not Yet Triggered in Any Session

These are implemented code paths that have never executed on the live system:

1. **`main.rb feedback`** — requires a completed pickup week with a matching `order_history` row
2. **`main.rb budget`** — requires at least one completed `order_history` row
3. **Thaw reminders and morning pings** — rufus-scheduler fires at specific times; never observed
4. **Crash alert** — `Notifier.send_crash_alert` never triggered by a real exception
5. **Kill switch** — `data/PAUSE` file never created
6. **Regenerate with freeform note** — the multi-step bot prompt for typing a note before regenerating
7. **`/shop` Telegram command** — cart rebuild from Telegram without touching the CLI
8. **Session expiry re-login** — `playwright_state.json` will expire eventually; re-login tested once on 2026-06-28

---

## Upcoming — Needs Verification Once Built

These will need end-to-end testing after each feature lands:

| Feature | When to test |
|---|---|
| Auto-map (`main.rb automap`, Feature 6) | ✅ Verified 2026-06-28 (12th session) |
| LLM Cart Review (Feature 7) | After implementation — verify correction flow on a live cart |
| LLM Aided Shopping (Feature 8) | After implementation — verify per-item screenshot + LLM selection |
| Recipe Sleep (Feature 9) | After implementation — verify sleep/wake/reset bot buttons |
| `/newrecipes` (Feature 10) | After implementation — verify import → Mealie → auto-map chain |
| "⚙ Configure week" link | After Docker deployment on Unraid |
| Uptime Kuma push | After Bailey creates Push monitor and sets `UPTIME_KUMA_PUSH_URL` |
| `main.rb feedback` | After first real pickup week completes post-Unraid deploy |
