# Mealie AutoChef — Build Plan & Handoff Document

> **Amendment (post Phase-0):** this document was written with a Python
> tech stack (section 4) and a Python project layout (section 5). After
> Phase 0's first pass, the project switched to Ruby + ActiveRecord/
> ActiveModel (no Rails app), with Playwright/`cart.py` kept as the one
> isolated Python file — see `MEMORY.md`'s locked decisions and
> `cart_builder/cart.py`'s docstring for the full reasoning. Sections 4 and
> 5 below are left as originally written for historical context; treat the
> actual repo layout (see top-level `README.md`) as current truth where
> they disagree.

**Purpose:** Automate weekly meal planning, shopping list generation, and grocery cart-building for a self-hosted Mealie instance, with a human approval gate and a final manual checkout. Target store: **Food Lion** (via Food Lion To Go, **pickup**). Runs on an **Unraid** server alongside an existing media/self-hosting stack.

**Audience:** A fresh engineering agent picking this up cold. This document is the spec. Read `MEMORY.md` alongside it for running project context and gotchas.

---

## 1. Confirmed decisions

| Decision | Choice | Notes |
|---|---|---|
| Fulfillment | **Pickup** (drive to store) | Cart automation targets the Food Lion To Go pickup flow + pickup time-slot selection. |
| Meal scope | **Dinner first**, lunch-expandable, no breakfast | `meal_types` is a config list; ship with `[dinner]`, design every component to accept `[dinner, lunch]`. |
| LLM for weekly planning | **Claude API, `claude-haiku-4-5`** | One call/week against the recipe pool is ~$0.03/week (~$1.50/yr). No model to self-host (the server has 16GB RAM already running the media stack). Config flag to bump to `claude-sonnet-4-6` if plan quality needs it. |
| Final checkout | **Manual** (dry-run default) | System builds the cart and stops; human taps the final "place order". Auto-checkout is an opt-in later phase. |
| Browser automation | **Playwright (Python)** | Chosen over an AI browser agent for the unattended, money-adjacent step: predictable, fast, free. Re-evaluate if the Instacart/Food Lion UI changes often. |
| Default servings | **2** | Per-meal override supported. |

---

## 2. What already exists vs. what we build

**Mealie gives us for free (configuration, not code):**
- Meal-plan "Plan Rules" that restrict the random-pick pool by tag/category/meal-type/day, and a "not made in last N days" filter.
- Shopping lists that auto-generate from a meal plan, consolidate duplicate ingredients, support an **"On Hand"** flag (pantry staples never get added), and **labels** for store sections.
- A full REST API, webhooks, and Apprise notifiers. Unofficial Python SDK: `mealie-client` (PyPI) covers recipes, meal plans, shopping lists, foods, units.
- Per-food and per-list **`extras`** JSON fields (arbitrary key/values) — we use these to store perishability metadata on foods.

**We build (supplemental code):**
- Preference learning + scored recipe selection.
- LLM weekly draft (arrangement + nuance).
- Cooking-day scheduling and perishability-aware ordering.
- Recurring/staple injection on cadences.
- Product/size mapping (recipe ingredient → purchasable Food Lion product).
- Servings scaling.
- Telegram approval bot + manual-add interface.
- Playwright cart builder (pickup).
- Safety layer, feedback logging, reminders.

---

## 3. Architecture

```
Mealie (recipes, ratings, cook history, "Next Order" list)
   │  REST API
   ▼
[scoring.py]  deterministic preference scorer  ──► recipe_stats / tag_weights (SQLite)
   │
   ▼
[planner.py]  cook-day scheduling + perishability ordering + repeat avoidance
   │
   ▼
[llm_planner.py]  Claude Haiku arranges/finalizes the week (JSON, validated)
   │
   ▼
[notify.py]  Telegram approval gate  ◄──►  Bailey (approve / swap / regenerate / add)
   │  (on approve)
   ▼
[shopping.py]  generate list → scale by servings → inject due staples → apply product map → push to Mealie "Next Order"
   │
   ▼
[cart.py]  Playwright → Food Lion To Go (pickup): add items, pick slot, STOP before checkout
   │
   ▼
[notify.py]  "Cart ready: $X, [open in Food Lion]"  ──► Bailey taps final checkout
   │
   ▼
[feedback]  log kept/swapped/ordered → order_history / plan_history → back into scorer
```

**Design principle:** deterministic code owns all data plumbing, scoring, scaling, and safety. The LLM is used *only* for the weekly "arrange the plan" reasoning step, where nuance ("had chicken twice already", "pair a project recipe with quick weeknights") is hard to encode as rules. Everything is a cron-triggered batch job, not a long-lived agent — simpler to run unattended and to reason about.

---

## 4. Tech stack

- **Language:** Python 3.11+
- **Mealie access:** `mealie-client` SDK (or direct `httpx` calls; SDK is async)
- **State:** SQLite (single file, lives on the array)
- **LLM:** Anthropic API, `claude-haiku-4-5` (model string `claude-haiku-4-5-20251001`); swap to `claude-sonnet-4-6` via config
- **Browser automation:** Playwright for Python (Chromium)
- **Notifications/approval:** Telegram bot (`python-telegram-bot`). Alternative: self-hosted `ntfy` (works well with the existing Tailscale setup) if a full bot is overkill.
- **Scheduling:** APScheduler inside a long-running container, or Unraid User Scripts / host cron firing `main.py <command>`
- **Deployment:** Docker container on Unraid, on the same Docker network as Mealie
- **Observability:** push healthcheck to the existing Uptime Kuma on each run

---

## 5. Project layout

```
mealie-autochef/
├── README.md
├── MEMORY.md                  # project context for fresh agents (see separate file)
├── config.yaml                # human-editable settings
├── .env.example                # secret names only (real .env is gitignored)
├── .gitignore
├── docker/
│   ├── Dockerfile
│   └── docker-compose.yml
├── src/
│   ├── main.py                # CLI + scheduler entrypoint
│   ├── config.py               # load + validate config.yaml/.env
│   ├── db.py                   # sqlite schema + helpers
│   ├── mealie_client.py        # Mealie API wrapper
│   ├── scoring.py               # deterministic preference scorer
│   ├── planner.py               # cook-day scheduling + perishability ordering
│   ├── llm_planner.py           # Claude weekly draft (strict JSON out)
│   ├── shopping.py              # list gen, servings scaling, staples, product map
│   ├── recurring.py             # cadence injection
│   ├── cart.py                  # Playwright Food Lion To Go pickup automation
│   ├── notify.py                # Telegram bot + approval flow + manual add
│   ├── reminders.py             # thaw / night-before reminders
│   └── safety.py                # spending cap, kill switch, idempotency
├── data/                       # gitignored
│   ├── autochef.db
│   └── playwright_state.json  # saved Food Lion / Instacart auth
├── scripts/
│   ├── seed_product_map.py    # one-time interactive product-map seeding
│   ├── tag_recipes.py         # bulk-tag perishability / cuisine / effort
│   └── backup.py
└── tests/
```

---

## 6. Configuration reference (`config.yaml`)

```yaml
mealie:
  url: "http://mealie:9000"        # internal Docker network address
  # token comes from .env: MEALIE_API_TOKEN
  eligible_tag: "auto-plan"        # only recipes with this tag enter the pool
  next_order_list: "Next Order"    # canonical Mealie shopping list = the cart

store:
  name: "Food Lion - <FILL IN>"    # OPEN DECISION: preferred pickup store
  fulfillment: "pickup"

schedule:
  weekly_run: "Thu 18:00"          # when to generate + send draft for approval
  pickup_window_pref: "Sun 10:00-12:00"  # OPEN DECISION
  # the shop/pickup day anchors perishability scheduling
  pickup_day: "Sun"

meals:
  meal_types: ["dinner"]           # expandable to ["dinner", "lunch"]
  default_servings: 2
  # per-day plan: cook | leftover | out | skip   (OPEN DECISION: fill in real layout)
  week_layout:
    Sun: cook
    Mon: leftover
    Tue: cook
    Wed: cook
    Thu: leftover
    Fri: out
    Sat: cook

selection:
  repeat_avoidance_weeks: 3        # don't replan a dinner within N weeks
  variety:
    max_same_cuisine_per_week: 2
    max_same_protein_per_week: 2
  scoring_weights:                 # all tunable
    rating: 1.0
    tag_affinity: 0.5
    recency_penalty: 1.0
    swap_penalty: 0.75
    nutrition_fit: 0.5             # set 0 to disable protein weighting

nutrition:
  enabled: true                    # protein-forward weighting; toggle off anytime
  target_protein_per_serving_g: 45 # supports a high daily-protein goal across meals

llm:
  provider: "anthropic"
  model: "claude-haiku-4-5-20251001"
  enabled: true                    # false => deterministic-only planning
  freeform_note_default: ""        # Bailey can pass a note at run time via the bot

notify:
  channel: "telegram"              # or "ntfy"
  # token + chat id from .env

safety:
  dry_run: true                    # true => build cart, never auto-checkout
  spending_cap_usd: 150            # hard cap; abort/flag above this
  cart_deviation_alert_pct: 20     # re-confirm if total deviates from estimate
  kill_switch_file: "data/PAUSE"   # if present, no ordering actions run
```

`.env` (names only; never commit real values):

```
MEALIE_API_TOKEN=
ANTHROPIC_API_KEY=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
FOODLION_USERNAME=
FOODLION_PASSWORD=
```

---

## 7. Data model

### 7.1 Mealie-side conventions (no schema change, just usage)

- **Eligible pool:** only recipes tagged `auto-plan` enter selection. Keeps half-baked/imported recipes out.
- **Perishability:** store `{"shelf_life_days": N}` in each **food's `extras`**. Fallback default-by-category map in code (e.g. seafood 2, fresh fish 2, ground meat 2, fresh herbs 3, dairy 7, hardy produce 10, pantry 365).
- **Pantry staples:** set the food **"On Hand"** flag in Mealie → auto-excluded from lists (salt, pepper, oil, common spices).
- **Recipe tags (conventions):** `cuisine:*`, `protein:*`, `effort:quick` / `effort:project`, `makes-leftovers`.
- **Ratings:** use Mealie's native 1–5 rating → feeds `avg_rating`.
- **Canonical cart:** one Mealie shopping list named **"Next Order"** is the single source of truth for what gets carted. Meal-plan items, recurring staples, and manual adds all funnel here.

### 7.2 SQLite schema (`autochef.db`)

```sql
CREATE TABLE recipe_stats (
  recipe_id          TEXT PRIMARY KEY,
  times_planned      INTEGER DEFAULT 0,
  times_cooked       INTEGER DEFAULT 0,
  times_swapped_out  INTEGER DEFAULT 0,
  last_planned       DATE,
  last_cooked        DATE,
  avg_rating         REAL,
  score              REAL DEFAULT 0,
  updated_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE tag_weights (
  tag         TEXT PRIMARY KEY,
  weight      REAL DEFAULT 0,
  updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE recurring_items (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  name          TEXT NOT NULL,
  product_ref   TEXT,                 -- -> product_map.key
  quantity      REAL DEFAULT 1,
  unit          TEXT,
  cadence_type  TEXT NOT NULL,        -- 'every_order' | 'every_n_orders' | 'every_n_days'
  cadence_value INTEGER DEFAULT 1,
  last_added    DATE,
  active        INTEGER DEFAULT 1
);

CREATE TABLE product_map (
  key                  TEXT PRIMARY KEY,   -- normalized mealie food name/id
  display_name         TEXT,
  search_term          TEXT,               -- what to search in Food Lion
  preferred_product_id TEXT,               -- Food Lion/Instacart product id if known
  pack_size            REAL,               -- e.g. 16
  pack_unit            TEXT,               -- 'oz' | 'lb' | 'ct'
  default_qty          INTEGER DEFAULT 1,  -- packs to buy by default
  rounding             TEXT DEFAULT 'up',  -- recipe qty -> packs
  substitution_notes   TEXT,
  updated_at           TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE manual_additions (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  name      TEXT NOT NULL,
  quantity  REAL DEFAULT 1,
  unit      TEXT,
  added_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  consumed  INTEGER DEFAULT 0
);

CREATE TABLE plan_history (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  week_start  DATE,
  plan_json   TEXT,        -- {date: {recipe_id, servings, meal_type, rationale}}
  approved    INTEGER DEFAULT 0,
  swaps_json  TEXT,
  created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE order_history (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  week_start   DATE,
  items_json   TEXT,
  est_total    REAL,
  actual_total REAL,
  status       TEXT,        -- 'cart_built' | 'approved' | 'placed' | 'aborted'
  pickup_slot  TEXT,
  run_key      TEXT,        -- idempotency key
  notes        TEXT,
  created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

---

## 8. Feature specifications

### 8.1 Preference learning & scoring (`scoring.py`)
Pull ratings, favorites, and cook history from Mealie; maintain a per-recipe `score` and per-`tag` weight. Starting formula (all weights from config):

```
score = w_rating        * normalized_rating(avg_rating)
      + w_tag_affinity   * mean(tag_weights for recipe's tags)
      - w_recency_penalty* recency_factor(last_cooked)
      - w_swap_penalty   * times_swapped_out
      + w_nutrition_fit  * protein_fit(recipe)        # if nutrition.enabled
```
Tag weights nudge up when a recipe is kept/cooked/highly rated, down when swapped out. Keep it simple and tunable — this is deterministic and cheap, and it's the long-term backbone.

### 8.2 Cooking-day scheduling (`planner.py`)
Read `week_layout`. Only `cook` days receive a planned meal. `leftover` days are covered by surplus from a prior `makes-leftovers` recipe (plan one when a leftover day follows a cook day). `out`/`skip` days get nothing. Number of meals to pick = count of `cook` days × number of `meal_types`.

### 8.3 Perishability-aware ordering (`planner.py`)
Because pickup is a single weekly trip, schedule perishable-ingredient meals **earliest after pickup day**.
1. For each candidate, `perishability = min(shelf_life_days of its non-On-Hand ingredients)`.
2. Sort assigned meals so the most-perishable land on the earliest cook days after `pickup_day`.
3. Constraint: `shelf_life_days >= (cook_day_index − pickup_day_index)`. If violated and unfixable, flag it in the approval message (e.g. "fish on Saturday from a Sunday pickup — won't keep").

### 8.4 Servings scaling (`shopping.py`)
Each planned meal carries a `servings` value (default `2`). When generating the list, scale ingredient quantities by `servings / recipe.base_servings`. Bot command `/servings <day> <n>` overrides per meal before approval.

### 8.5 Recurring / staple items (`recurring.py`)
`recurring_items` rows with a cadence (`every_order`, `every_n_orders`, `every_n_days`). On each list-build, inject any item that's **due** (based on `last_added` vs cadence), then update `last_added`. Manage via bot (`/staples`). Examples: milk every order, coffee every 2 orders, paper towels every 3 orders.

### 8.6 Manual add to next order (`notify.py` + `shopping.py`)
No need to touch the Food Lion UI. Anything added to the **"Next Order"** Mealie list flows into the next cart. Two entry points:
- Mealie's own app/UI (nicer than Food Lion's).
- Telegram: `/add 2 lbs chicken thighs` → writes to `manual_additions` **and** the Mealie list. `/list` shows the current next order; `/remove <id>` removes.

### 8.7 Product / size mapping (`product_map`, `scripts/seed_product_map.py`)
Bridges recipe units ("2 cloves garlic", "200g chicken") to purchasable Food Lion pack sizes ("1 bulb garlic", "1 lb pack"). Each map row: `search_term` (or known `preferred_product_id`), `pack_size`/`pack_unit`, `default_qty`, `rounding`. The cart builder uses it; **unmapped items are flagged** for a one-time setup pass rather than guessed. `seed_product_map.py` is an interactive helper to build the map incrementally as new ingredients appear.

### 8.8 Pantry / on-hand awareness
Driven entirely by Mealie's **"On Hand"** food flag — no separate config. Staples you keep stocked never hit the list.

### 8.9 Repeat avoidance & variety
- No recipe replanned within `repeat_avoidance_weeks` (cross-check `plan_history` + Mealie `lastMade`).
- Cap same-cuisine and same-protein counts per week (config). The LLM step enforces these as soft constraints; the scorer pre-filters hard ones.

### 8.10 Optional protein-forward weighting (`nutrition`)
When `nutrition.enabled`, the scorer biases toward dinners that hit `target_protein_per_serving_g`, and the approval message surfaces estimated protein/serving. Fully optional — set `nutrition.enabled: false` or `nutrition_fit: 0` to ignore. (Default on, since macros are tracked; trivially disabled.)

### 8.11 LLM weekly draft (`llm_planner.py`)
- **Input:** eligible pool (id, name, tags, est protein/serving, last_cooked, rating, perishability), `week_layout`, `default_servings`, recent weeks' plans (avoid repeats), due recurring items, and any freeform note Bailey passes via the bot ("light week, no fish, want a freezer meal").
- **Task:** arrange meals across cook days respecting perishability order, variety caps, and repeat avoidance; the deterministic scorer has already ranked candidates.
- **Output:** strict JSON `{date: {recipe_id, servings, meal_type, rationale}}`. **Validate the JSON**; on any parse/validation failure, fall back to the deterministic plan and note it.
- **Model:** `claude-haiku-4-5`. Prompt-cache the recipe pool if you iterate (regenerate) within a session.

### 8.12 Approval gate (`notify.py`)
Telegram message: the week's plan (day, recipe, servings, est protein), estimated cart total, and any perishability/variety warnings. Inline actions:
- **Approve** → generate list → build cart → second "cart ready" message.
- **Swap [day]** → re-pick that day (next-best candidate or LLM re-roll) and re-send.
- **Regenerate** → full re-draft, optionally with a freeform note.
- **Add note** → supply guidance and regenerate.
Swaps are logged (`times_swapped_out`++) — the strongest preference signal we get.

### 8.13 Cart builder (`cart.py`, Playwright, pickup)
- Headless Chromium with a **persistent saved auth state** (`playwright_state.json`); human-like pacing; weekly cadence only (no aggressive parallelism).
- Flow: open Food Lion To Go (Instacart-powered) → confirm store = configured → set fulfillment = **Pickup** → select pickup slot per `pickup_window_pref` → for each "Next Order" item: search via `product_map` and add `default_qty` packs → verify each add → on out-of-stock, **flag, don't auto-substitute** (unless explicitly allowed).
- **Stop before placing the order.** Capture cart total + a screenshot + a deep link; send to Bailey.
- Idempotency: tag the run with `run_key`; re-runs reconcile rather than double-add.

### 8.14 Reminders (`reminders.py`)
Night-before "thaw the protein for tomorrow's [recipe]" nudge (the kind of thing the Mealie/Home-Assistant community already does via webhooks). Optional cook-day morning ping.

### 8.15 Feedback loop
After approval/cooking, log kept-vs-swapped and (if entered) the actual paid total into `order_history`/`plan_history`, then update `recipe_stats` and `tag_weights`. The swap-at-approval signal is weighted heavily.

---

## 9. Safety features (consolidated — all required)

1. **Dry-run default** — build the cart, human taps the final checkout. Auto-checkout is opt-in (Phase 7) only after the cart builder is trusted.
2. **Hard spending cap in code** — abort or flag any cart whose estimated total exceeds `spending_cap_usd`.
3. **Dedicated payment card** — Bailey sets up a card with a sane limit on the Food Lion/Instacart account, not the primary card. (Account setup task, not code.)
4. **Kill switch** — if `data/PAUSE` exists, no ordering actions run. First thing every ordering path checks.
5. **Idempotency keys** — per weekly `run_key`; safe to re-run without double-ordering.
6. **Secrets hygiene** — all secrets in `.env` / Unraid Docker secrets; `.gitignore` covers `.env`, `data/`, `playwright_state.json`. Never commit credentials or card data; card data never touches code at all (entered once in the Food Lion account).
7. **Account-risk mitigation** — automated checkout against a consumer site invites bot detection. Mitigate with a persistent real browser profile, human pacing, weekly (not frequent) runs, and keeping a human in the loop at checkout. **Accept this is the most fragile part of the stack** and the part most likely to need babysitting; the manual-checkout default is the main protection.
8. **Out-of-stock / substitution policy** — never silently accept a pricier or different substitute; flag for approval.
9. **Cart-deviation re-confirm** — if the built cart total deviates from the estimate by more than `cart_deviation_alert_pct`, re-prompt before proceeding.
10. **Validation everywhere** — LLM output is JSON-validated with a deterministic fallback; config is validated on load.
11. **Observability** — push a healthcheck to the existing Uptime Kuma on each run; alert on failure.
12. **Backups** — nightly SQLite dump + trigger Mealie's own backup; store on the array (Mealie does not auto-backup, so this is on us).

---

## 10. Build phases & definition of done

**Phase 0 — Scaffolding.** Repo, `config.py` + validation, `.env` handling, SQLite schema (`db.py`), Dockerfile + compose on the Mealie network, Uptime Kuma ping.
*DoD:* container runs, reads config, connects to Mealie API, creates the DB.

**Phase 1 — Data layer.** `mealie_client.py`; `scripts/tag_recipes.py` to bulk-tag perishability/cuisine/effort and seed food `shelf_life_days` extras + On-Hand flags; sync ratings/cook history into `recipe_stats`.
*DoD:* eligible pool queryable; perishability resolvable for every eligible recipe.

**Phase 2 — Selection.** `scoring.py` + `planner.py` (cook-day scheduling, perishability ordering, repeat avoidance, variety caps). Then `llm_planner.py` with strict JSON + deterministic fallback.
*DoD:* running `main.py plan` produces a valid, perishability-correct week for the configured layout.

**Phase 3 — Approval.** `notify.py` Telegram bot: draft message with Approve/Swap/Regenerate/Add-note; manual-add commands (`/add`, `/list`, `/remove`, `/staples`, `/servings`).
*DoD:* a draft can be approved/swapped/regenerated from the phone; swaps are logged.

**Phase 4 — Shopping list.** `shopping.py` (servings scaling, On-Hand exclusion, store-section labels) + `recurring.py` (cadence injection) + product map application; push consolidated list to Mealie "Next Order".
*DoD:* approved plan yields a correct, scaled, deduped "Next Order" list with staples and manual adds folded in; unmapped items flagged.

**Phase 5 — Cart builder.** `cart.py` Playwright pickup flow + `safety.py` (cap, kill switch, idempotency, deviation check). Builds the cart, selects a pickup slot, **stops before checkout**, sends "cart ready" with total + link.
*DoD:* from an approved list, the Food Lion cart is populated and a pickup slot selected, with no order placed; spending cap and kill switch verified.

**Phase 6 — Feedback & polish.** Order/plan logging, `reminders.py` thaw nudges, budget tracking, backup script.
*DoD:* a full week runs end-to-end on schedule with the human only approving and tapping final checkout.

**Phase 7 — (Optional/future) Auto-checkout.** Only after the cart builder is reliably trusted. Behind `dry_run: false` with extra confirmation. **Recommended to leave off indefinitely** unless there's a strong reason.

**Future/optional (flagged fragile):** weekly-ad / sale awareness would require scraping the Food Lion circular — high maintenance, low reliability. Skip unless it earns its keep.

---

## 11. Open decisions needed from Bailey

These are config values, not architecture — the build can proceed with placeholders, but these are needed before the first real run:

1. **Preferred Food Lion store** (which location).
2. **Pickup day + time window**, and **when the weekly job should fire** (suggested: generate Thursday evening → approve over the weekend → Sunday pickup).
3. **Week layout** — which days are cook / leftover / out / skip.
4. **Notification channel** — Telegram (recommended) vs self-hosted ntfy.
5. **Dedicated card setup** on the Food Lion account + the **spending-cap** amount (default $150).
6. **Standing dislikes / allergies / never-buy** ingredients, if any.
7. **Initial recurring staples** + their cadences.
8. **Keep protein-forward weighting on?** (default yes; one toggle to disable).

---

## 12. Operational runbook

- **Run modes (CLI):** `main.py plan` (draft + send for approval), `main.py build-cart` (post-approval), `main.py sync` (pull Mealie stats), `main.py backup`.
- **Schedule:** APScheduler in-container, or Unraid User Scripts / host cron hitting the CLI at `schedule.weekly_run`.
- **Pause:** `touch data/PAUSE` halts all ordering; delete to resume.
- **Re-auth:** if the Food Lion session expires, re-run the interactive login once to refresh `playwright_state.json`.
- **Monitor:** Uptime Kuma push on each run; failures alert.
- **Back up:** nightly SQLite dump + Mealie backup to the array.

---

## 13. Known-fragile areas (be honest with yourself here)

- **The cart builder** is the least durable component — it automates a site not built to be automated. Expect selector maintenance when Instacart/Food Lion ships UI changes. Keep checkout manual.
- **Product mapping** needs a one-time human seeding pass and ongoing additions as new ingredients appear; don't let the system guess pack sizes silently.
- **LLM drift** — always validate JSON and keep the deterministic fallback so a bad model response can never break a run.

---

## 14. Reference links

- Mealie API usage & filters: https://docs.mealie.io/documentation/getting-started/api-usage/
- Mealie features (plan rules, shopping lists, On-Hand, labels): https://docs.mealie.io/documentation/getting-started/features/
- `mealie-client` Python SDK: https://pypi.org/project/mealie-client/
- Claude API pricing & models: https://docs.claude.com/en/docs/about-claude/pricing
- Playwright for Python: https://playwright.dev/python/
- python-telegram-bot: https://docs.python-telegram-bot.org/
- Food Lion To Go (Instacart-powered; pickup uses Food Lion's own in-store pickers): the consumer storefront is the automation target — there is no first-party Food Lion ordering API, and Instacart's developer APIs are partner-facing, not for placing orders on a personal account.
