# Mealie AutoChef — User Guide

AutoChef automates your weekly meal-planning, shopping-list generation, and Food Lion cart-building, while keeping you in control at every meaningful step. You approve the plan, you tap the final checkout. The system handles everything in between.

---

## How it works (the weekly loop)

```
Thursday ~6 pm
  AutoChef scores your recipe pool → Claude Haiku arranges the week
  → sends a Telegram message with the plan + inline buttons

You (anytime before the weekend)
  Review the plan on your phone
  → tap Approve / Swap a meal / Regenerate / Add a note

AutoChef (on Approve)
  → scales servings → injects recurring staples → resolves product map
  → consolidates duplicate search terms (quantities summed)
  → pushes the "Next Order" list to Mealie
  → opens Food Lion To Go in a headed Chrome browser
  → clears any items from a previous run
  → adds every item, selects a pickup slot, STOPS before checkout
  → sends "Cart ready: $XX.XX — [tap to review]"

You (Sunday morning)
  Tap the link → review the cart → place the order

After the week
  bundle exec ruby main.rb feedback
  → times_cooked incremented, tag_weights nudged, ready for next week
```

Everything between your Thursday approval and your Sunday checkout is automated. The cart builder never places an order; that's always you.

---

## One-time setup

See [docs/SETUP_WALKTHROUGH.md](SETUP_WALKTHROUGH.md) for the full
step-by-step guide with exact commands and expected output. The short
version is below.

### 1. Mealie prerequisites

AutoChef reads from and writes to your existing Mealie instance via its REST API. Before the first run you need:

- **An API token:** Mealie UI → your username → API Tokens → create one. Copy it.
- **The "Next Order" shopping list:** create a Mealie shopping list named exactly `Next Order` (or change `mealie.next_order_list` in `config.yaml`).
- **Recipes tagged `auto-plan`:** AutoChef only plans from recipes with this tag. Run `bundle exec ruby scripts/tag_recipes.rb` to add it interactively.

### 2. Copy and fill in `.env`

```bash
cp .env.example .env
```

| Variable | Where to get it |
|---|---|
| `MEALIE_API_TOKEN` | Mealie UI → API Tokens |
| `ANTHROPIC_API_KEY` | console.anthropic.com |
| `TELEGRAM_BOT_TOKEN` | Telegram → `@BotFather` → `/newbot` |
| `TELEGRAM_CHAT_ID` | Telegram → `@userinfobot` |
| `FOODLION_USERNAME` | Your Food Lion / Instacart account email |
| `FOODLION_PASSWORD` | Your Food Lion / Instacart account password |
| `UPTIME_KUMA_PUSH_URL` | Uptime Kuma → Monitors → Push-type monitor |
| `MEALIE_URL` | Only needed for local dev outside Docker (e.g. `http://localhost:9000`) |

`FOODLION_USERNAME` / `FOODLION_PASSWORD` are used once to log in interactively and save a browser session to `data/playwright_state.json`. After that, only the saved session file is used — the credentials are not sent anywhere on weekly runs.

### 3. Fill in `config.yaml`

Open `config.yaml` and set the three values marked `FILL IN`:

```yaml
store:
  name: "Food Lion - City, State"     # which location for pickup
schedule:
  pickup_window_pref: "Sun 10:00-12:00"
safety:
  spending_cap_usd: 150
```

Everything else has a sensible default. See [Configuration reference](#configuration-reference) below to tune further.

### 4. Install dependencies and verify

```bash
bundle install
bundle exec ruby main.rb check
```

Expect `PARTIAL` if Mealie is not on `mealie_net` yet. Config + DB OK is enough to continue with recipe setup.

### 5. Tag your recipes

```bash
bundle exec ruby scripts/tag_recipes.rb
```

Interactive — walks every recipe in Mealie and prompts for the tags AutoChef uses. Flags:

- `--untagged` — only recipes not yet in the planning pool (fastest after the first pass)
- `--eligible` — only already-eligible recipes (to fill in cuisine/protein/effort tags)
- `--foods-only` — skip recipe tags, go straight to ingredient shelf-life setup

| Tag | Purpose |
|---|---|
| `auto-plan` | Admits the recipe to the planning pool |
| `cuisine:*` | Variety cap (max 2 same cuisine per week) |
| `protein:*` | Protein diversity + nutrition scoring |
| `effort:quick` / `effort:project` | Avoids back-to-back project meals |
| `makes-leftovers` | Planner covers the next `leftover` day automatically |

After recipe tags, the script walks all ingredients in eligible recipes and sets `shelf_life_days` on each food. This drives perishability-aware scheduling — the most perishable meals land earliest after your pickup day.

### 6. Sync to the local database

```bash
bundle exec ruby main.rb sync
```

Pulls `avg_rating` and `lastMade` from Mealie into the local `recipe_stats` table. The scorer uses these every week. Re-run any time ratings or cook history change.

### 7. Pantry staples

In Mealie: mark any food you always keep on hand as **"On Hand"** (the toggle on the food detail page). Those foods are automatically excluded from the shopping list — salt, oil, common spices never appear in your cart.

### 8. Seed the product map

```bash
bundle exec ruby scripts/seed_product_map.rb
```

Interactive — walks every item in the current Mealie "Next Order" shopping list and prompts you to map each one to a Food Lion search term, pack size, and default quantity. Run this after your first `main.rb shop`.

**First run:** expect ~50 items spanning all your initial recipes. Most are one-and-done — once "salmon fillet" is mapped, it stays mapped forever.

**Pantry staples** (water, salt, black pepper, olive oil): type `s` at the search term prompt to mark an item as a pantry staple. It will be excluded from the cart payload entirely — cart.py never sees it. Note: Mealie's "On Hand" food toggle only works when ingredients are linked to Mealie food objects; imported free-text recipes bypass it, so `s` in the seed script is the reliable path.

**Steady state:** most weeks need no seeding at all. New seeding is only needed when a brand-new recipe with previously-unseen ingredients enters your planning pool. `main.rb shop` will flag the unmapped items by name at the end of its output.

**Flags:**
- `--list` — show all existing mappings
- `--update` — re-map already-mapped items (use after changing pack sizes or search terms)

### 9. Food Lion browser session

```bash
source .venv/bin/activate
python3 cart_builder/cart.py --login
deactivate
```

Opens a visible Chromium browser, waits for you to log in to Food Lion To Go, then saves the session to `data/playwright_state.json`. All future cart builds reuse this session. Re-run if the session expires.

---

## Weekly operation

### Thursday: plan generation

AutoChef generates a plan automatically (via `main.rb serve`'s rufus-scheduler, or via a cron/Unraid User Script calling `main.rb plan`). You receive a Telegram message like:

```
📅 Week of Jun 29

Sun  Lemon Herb Chicken (2 servings)
Tue  Beef Stir Fry (2 servings)
Wed  Pasta Carbonara (2 servings)
Sat  Salmon + Roasted Veg (2 servings)
  Mon, Thu: leftovers from Sun/Wed

⚠ Salmon on Saturday — 5 days after pickup. Fish keeps 2 days.
   Consider swapping to an earlier slot.

[Approve] [Swap Sun] [Swap Tue] [Swap Wed] [Swap Sat] [Regenerate]
```

### Your options

- **Approve** — AutoChef builds the shopping list and the cart. You get a "cart ready" Telegram with the total and a link.
- **Swap [day]** — AutoChef re-picks that meal. Swaps are logged and feed into future scoring (the system learns which meals you actually want vs. keep accepting).
- **Regenerate** — full re-draft. You can add a note first (see `/note` command below).
- **Add note** — supply freeform guidance ("light week, no fish, something quick") and regenerate.
- **⚙ Configure week** — opens the week configurator form (see below). Set your preferences, save, then tap Regenerate to apply them.

### Bot commands (available any time `main.rb serve` is running)

| Command | What it does |
|---|---|
| `/add 2 lbs chicken thighs` | Adds to the current Next Order list as a manual addition |
| `/list` | Shows the current Next Order items |
| `/remove <id>` | Removes an item from the list by its ID |
| `/staples` | View and toggle recurring staples |
| `/servings <day> <n>` | Change servings for one meal before you approve |
| `/note <text>` | Set a freeform guidance note for the next Regenerate |

### After the week (feedback)

```bash
bundle exec ruby main.rb feedback
```

Increments `times_cooked` for every recipe in the approved plan, updates `last_cooked`, and nudges `tag_weights` up for cuisine/protein tags you kept (didn't swap out). This feeds into next week's scoring. Run once after each grocery pickup.

---

## Week configurator

When `main.rb serve` is running, a web form is available at:

```
http://192.168.1.64:3456/week       # from your local network / Tailscale
```

Use it before tapping Approve when you want to influence this week's plan. The Telegram plan message includes an **⚙ Configure week** button that links directly to this URL.

### What you can configure

**Per-day controls** (one row per cook day):

| Control | What it does |
|---|---|
| Meal type | Override a day to cook / leftover / skip for this week only |
| Dinner servings | How many portions to plan (overrides `default_servings`) |
| Vibe | "Feed Me" (hearty/filling) or "Treat" (something special) |
| Notes | Freeform guidance for that day ("no onions", "something quick") |

**Global controls** (apply to the whole week):

| Control | What it does |
|---|---|
| Protein exclude chips | Checkboxes: No Seafood / No Beef / No Pork / Vegetarian only |
| Week note | Freeform guidance passed to Claude ("light week", "no fish") |

### How it fits the workflow

1. Receive the Telegram plan draft
2. Tap **⚙ Configure week** → set your preferences → Save
3. Tap **Regenerate** in Telegram — the new draft applies your preferences
4. Tap **Approve**

Preferences are saved per-week-start date. They persist in the local DB so a Regenerate always picks them up, even if you set them hours before the plan is generated. They have no effect after the plan is approved.

---

## Reminders

When `main.rb serve` is running, AutoChef sends two automatic push notifications per cook day:

- **Thaw reminder** — sent the day before a recipe that needs thawing (anything with frozen protein), at the time configured in `schedule.thaw_reminder_time` (default `18:00`)
- **Morning ping** — sent the morning of each cook day at `schedule.morning_ping_time` (default `08:00`), if `schedule.morning_ping_enabled` is `true`

To disable morning pings: set `morning_ping_enabled: false` in `config.yaml`.

---

## Recurring staples

AutoChef can automatically add items to every (or every-N) order. Examples:

| Item | Cadence |
|---|---|
| Milk | Every order |
| Coffee | Every 2 orders |
| Paper towels | Every 3 orders |

Manage staples with the `/staples` bot command or directly in the `recurring_items` table via `sqlite3 data/autochef.db`.

---

## Budget tracking

```bash
bundle exec ruby main.rb budget
```

Prints monthly and year-to-date grocery spend from `order_history`, with a per-week breakdown. Flags any week that exceeded the spending cap.

---

## Backup

```bash
bundle exec ruby main.rb backup
```

Copies `data/autochef.db` to `data/backups/autochef_YYYYMMDD.db` and triggers a Mealie backup via the API. Schedule this weekly (e.g., Saturday night via Unraid User Scripts or cron).

---

## Safety features

All of these are on by default.

| Feature | What it does |
|---|---|
| **Dry-run mode** (`safety.dry_run: true`) | Cart is built but never auto-placed. Keep this on until you've verified the cart builder works reliably for your account. |
| **Spending cap** (`safety.spending_cap_usd`) | If the cart total exceeds this, AutoChef aborts and sends you a Telegram alert. |
| **Kill switch** | `touch data/PAUSE` — if this file exists, no ordering actions run. `rm data/PAUSE` to resume. |
| **Idempotency** | Each weekly run has a unique key; re-running the same week skips the cart build unless you pass `--force`. |
| **Out-of-stock policy** | AutoChef never silently accepts a substitute. Flagged items appear in the cart-ready Telegram for your review. |
| **Cart deviation alert** | If the built cart total deviates more than 20% from the estimate, you get a warning in the cart-ready message. |

**Recommended:** set up a dedicated card with a reasonable limit on your Food Lion / Instacart account — not your primary card. The system never touches card data (you enter it once in the Food Lion UI), but defense in depth is worth it.

---

## Configuration reference

Everything in `config.yaml` is tunable without touching code.

### `meals.week_layout`

Which days you cook, eat leftovers, eat out, or skip. AutoChef only plans meals for `cook` days. `leftover` days are automatically covered by a preceding `makes-leftovers` recipe.

```yaml
week_layout:
  Sun: cook
  Mon: leftover   # covered by Sunday's makes-leftovers recipe
  Tue: cook
  Wed: cook
  Thu: leftover
  Fri: out        # no grocery planning
  Sat: cook
```

Valid values: `cook`, `leftover`, `out`, `skip`.

### `selection.scoring_weights`

All weights are tunable; set any to `0` to disable that signal.

| Weight | What it does |
|---|---|
| `rating` | Bias toward higher-rated recipes (from Mealie `avg_rating`) |
| `tag_affinity` | Bias toward cuisine/protein tags you've historically kept (not swapped out) |
| `recency_penalty` | Avoid re-planning a recipe cooked recently |
| `swap_penalty` | Downrank recipes you've swapped out repeatedly |
| `nutrition_fit` | Bias toward hitting `target_protein_per_serving_g` |

### `nutrition.enabled`

When `true`, the scorer biases toward higher-protein dinners and the approval message shows estimated protein per serving. Set to `false` or set `scoring_weights.nutrition_fit: 0` to ignore entirely.

### `llm.enabled`

When `false`, the system skips the Claude step and uses the deterministic scorer's ranking directly. Useful for testing or if you want to avoid LLM costs.

### `selection.repeat_avoidance_weeks`

Number of weeks a recipe is blocked from being re-planned after it was last cooked. Default: `3`.

---

## Troubleshooting

**`main.rb check` shows `PARTIAL` (Mealie unreachable)**

Expected when running outside Docker. Set `MEALIE_URL=http://localhost:<port>` in `.env` if Mealie is port-forwarded, or run inside the Docker network.

**`tag_recipes.rb` shows 0 recipes**

Mealie is reachable but has no recipes. Import or create some in the Mealie UI first.

**`main.rb sync` shows 0 eligible recipes**

No recipes are tagged `auto-plan`. Run `scripts/tag_recipes.rb` first.

**Telegram bot not responding**

Check that `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are set correctly in `.env`. The chat ID must be your personal chat with the bot (not a group). `main.rb serve` must be running to handle button presses.

**Cart not matching expected items**

Check the product map — items without a mapping are flagged rather than guessed. Run `scripts/seed_product_map.rb` to add or fix mappings.

**Cart has duplicate items after a `--force` re-run**

This was a bug in earlier sessions. `build-cart` now clears the entire Food Lion cart at the start of every run before adding items. If you still see duplicates, the `SEL_CART_ITEM_REMOVE` selectors in `cart_builder/cart.py` may need updating — watch the browser during the run and note which button text/attribute removes an item, then file an issue.

**`/add` items disappeared from the cart**

Items added via `/add` are in the Mealie "Next Order" list and are always re-added by the cart build. They are not lost when the cart is cleared — they come back in the normal add flow. If an `/add` item is missing, check that it's still in the Next Order list (`/list` in the bot) and that it has a product map entry (`seed_product_map.rb --list`).

**`data/PAUSE` file exists**

Someone created the kill switch. `rm data/PAUSE` to resume.

**Cart session expired (Food Lion login required)**

Run `python3 cart_builder/cart.py --login` again to refresh `data/playwright_state.json`.

**Food Lion cart builder breaks after a UI update**

The cart builder automates a consumer website. When Food Lion / Instacart ships UI changes, CSS selectors may need updating. See the `SELECTOR MAINTENANCE` section in `cart_builder/cart.py` for the recovery procedure (Playwright Codegen).
