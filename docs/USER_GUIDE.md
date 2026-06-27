# Mealie AutoChef — User Guide

AutoChef automates your weekly meal-planning, shopping-list generation, and Food Lion cart-building, while keeping you in control at every meaningful step. You approve the plan, you tap the final checkout. The system handles everything in between.

---

## How it works (the weekly loop)

```
Thursday evening
  AutoChef picks dinners for the week → asks Claude Haiku to arrange them
  → sends a Telegram message with the plan + estimated cart total

You (anytime before the weekend)
  Review the plan on your phone
  → Approve / swap a meal / regenerate / add a note

AutoChef (on approve)
  Scales servings → injects recurring staples → applies product map
  → pushes the "Next Order" list to Mealie
  → opens Food Lion To Go in a headless browser
  → adds every item, selects a pickup slot, STOPS before checkout
  → sends "Cart ready: $XX.XX — [open in Food Lion]"

You
  Tap the link → review the cart → place the order
```

Everything between your Thursday approval and your Sunday checkout is automated. The cart builder never places an order; that's always you.

---

## One-time setup

### 1. Mealie prerequisites

AutoChef reads from and writes to your existing Mealie instance via its REST API. Before the first run you need:

- **An API token:** Mealie UI → your username → API Tokens → create one. Copy it.
- **The "Next Order" shopping list:** create a Mealie shopping list named exactly `Next Order` (or change `mealie.next_order_list` in `config.yaml`).
- **Recipes:** AutoChef only plans from recipes tagged `auto-plan` (configurable in `mealie.eligible_tag`). You add that tag; AutoChef never removes it.

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
| `UPTIME_KUMA_PUSH_URL` | Uptime Kuma → Monitors → a Push-type monitor |
| `MEALIE_URL` | Only needed for local dev outside Docker (e.g. `http://localhost:9000`) |

`FOODLION_USERNAME` / `FOODLION_PASSWORD` are only used once to log in interactively and save a browser session — they're never sent anywhere else. See the Phase 5 cart-builder section below.

### 3. Fill in `config.yaml`

Open `config.yaml` and set the values marked `FILL IN`:

```yaml
store:
  name: "Food Lion - City, State"     # which location for pickup
schedule:
  pickup_window_pref: "Sun 10:00-12:00"
meals:
  week_layout:                         # your actual schedule
    Sun: cook
    Mon: leftover
    ...
```

Anything else you want to tune has a sensible default — see [Configuration reference](#configuration-reference) below.

### 4. Install dependencies and verify

```bash
bundle install
bundle exec ruby main.rb check
```

Expect `PARTIAL` if Mealie isn't on `mealie_net` yet. Config + DB OK is enough to proceed with recipe setup.

---

## Recipe setup (one-time, before first real run)

### Tag your recipes

Run the interactive tagger. It walks through every recipe in Mealie and prompts for the tags AutoChef uses:

```bash
bundle exec ruby scripts/tag_recipes.rb
```

Flags:
- `--untagged` — only recipes not yet in the pool (fastest after the first pass)
- `--eligible` — only already-eligible recipes (to add cuisine/protein/effort)
- `--foods-only` — skip recipe tagging, go straight to ingredient shelf-life setup

The script prompts for:

| Tag | Purpose |
|---|---|
| `auto-plan` | Admits the recipe to the planning pool |
| `cuisine:*` | Variety cap (max 2 same cuisine/week) |
| `protein:*` | Protein diversity + nutrition scoring |
| `effort:quick` / `effort:project` | Avoids back-to-back project meals |
| `makes-leftovers` | Planner covers the next `leftover` day automatically |

After recipe tags, the script walks all ingredients in eligible recipes and sets `shelf_life_days` on each food. This is what drives perishability-aware scheduling — the most perishable meals land earliest after your pickup day.

### Sync to the local database

```bash
bundle exec ruby main.rb sync
```

Pulls `avg_rating` and `lastMade` from Mealie into the local `recipe_stats` table. The scorer uses these in Phase 2. Re-run this any time ratings or cook history change.

### Pantry staples

In Mealie: mark any food you always keep on hand as **"On Hand"** (the toggle on the food detail page). Those foods are automatically excluded from the shopping list — salt, oil, common spices, etc. never appear in your cart.

---

## Weekly operation

> **Note:** The Telegram approval bot (Phase 3) and the full weekly automation (Phase 6) are not yet implemented. This section describes the target flow.

Once fully operational:

**Every Thursday at ~6pm** — AutoChef generates a meal plan and sends you a Telegram message like:

```
📅 Week of Jun 29

Sun  🍗 Lemon Herb Chicken (2 servings, ~48g protein)
Tue  🥩 Beef Stir Fry (2 servings, ~52g protein)
Wed  🍝 Pasta Carbonara (2 servings, ~38g protein)
Sat  🐟 Salmon + Roasted Veg (2 servings, ~44g protein)
  (Mon, Thu: leftovers from Sun/Wed)

⚠️ Salmon on Saturday — 5 days after Sunday pickup. Fish is good for 2 days.
   Consider swapping to an earlier cook day.

Estimated cart: ~$87.40

[Approve] [Swap Sun] [Swap Tue] [Swap Wed] [Swap Sat] [Regenerate]
```

**Your options:**
- **Approve** — AutoChef builds the list and the cart. You get a "cart ready" link.
- **Swap [day]** — re-picks that meal. Swaps are logged and feed into future scoring (the system learns which meals you actually want).
- **Regenerate** — full re-draft. You can add a note first: "light week, no fish, want something quick."
- **Add note** — supply guidance and regenerate.

**Bot commands you can use any time:**
- `/add 2 lbs chicken thighs` — adds to the Next Order list
- `/list` — shows the current next order
- `/remove <id>` — removes an item
- `/staples` — view/edit recurring staples
- `/servings <day> <n>` — change servings for one meal before approving

> These commands are not yet available — they land in Phase 3.

---

## Recurring staples

AutoChef can automatically add items to every (or every-N) order on a cadence. Examples:

| Item | Cadence |
|---|---|
| Milk | Every order |
| Coffee | Every 2 orders |
| Paper towels | Every 3 orders |

Staples are managed via the `/staples` bot command (Phase 3) or directly in the `recurring_items` table.

---

## Safety features

All of these are on by default.

| Feature | What it does |
|---|---|
| **Dry-run mode** (`safety.dry_run: true`) | Cart is built but never auto-placed. This is the default and should stay on until you've verified the cart builder works reliably. |
| **Spending cap** (`safety.spending_cap_usd: 150`) | If the estimated cart total exceeds this, AutoChef aborts and alerts you instead of proceeding. |
| **Kill switch** | `touch data/PAUSE` — if this file exists, no ordering actions run. `rm data/PAUSE` to resume. |
| **Out-of-stock policy** | AutoChef never silently accepts a substitute for an out-of-stock item. It flags it for your review. |
| **Cart deviation alert** | If the built cart total deviates more than 20% from the estimate, AutoChef re-prompts before proceeding. |
| **Idempotency** | Each weekly run has a unique key; re-running the same week reconciles rather than double-adding. |

**Recommended:** set up a dedicated card with a reasonable limit on your Food Lion/Instacart account — not your primary card. The system never touches card data (you enter it once in the Food Lion UI), but defense in depth is worth it.

---

## Configuration reference

Everything in `config.yaml` is tunable without touching code.

### `meals.week_layout`
Which days you cook, eat leftovers, eat out, or skip. AutoChef only plans meals for `cook` days. `leftover` days are automatically covered by the preceding `makes-leftovers` recipe.

```yaml
week_layout:
  Sun: cook
  Mon: leftover   # covered by Sun's makes-leftovers recipe
  Tue: cook
  Wed: cook
  Thu: leftover
  Fri: out        # no grocery planning
  Sat: cook
```

### `selection.scoring_weights`
All scoring weights are tunable; set any to `0` to disable that signal.

| Weight | What it does |
|---|---|
| `rating` | Bias toward higher-rated recipes |
| `tag_affinity` | Bias toward tags you've historically kept (not swapped out) |
| `recency_penalty` | Avoid replanning a recipe cooked recently |
| `swap_penalty` | Downrank recipes you've swapped out in the past |
| `nutrition_fit` | Bias toward hitting `target_protein_per_serving_g` |

### `nutrition.enabled`
When `true`, the scorer biases toward dinners with higher protein content and the approval message shows estimated protein/serving. Set to `false` or set `scoring_weights.nutrition_fit: 0` to ignore.

### `llm.enabled`
When `false`, the system skips the Claude step and uses the deterministic scorer's ranking directly. Useful for testing or if you want to avoid LLM costs.

### `selection.repeat_avoidance_weeks`
Number of weeks a recipe is blocked from being re-planned after it was last made. Default: `3`.

---

## Troubleshooting

**`main.rb check` shows `PARTIAL` (Mealie unreachable)**
Expected when running outside Docker. Set `MEALIE_URL=http://localhost:<port>` in `.env` if Mealie is port-forwarded, or run inside the Docker network.

**`tag_recipes.rb` shows 0 recipes**
Mealie is reachable but has no recipes. Import or create some in the Mealie UI first.

**`sync` shows 0 eligible recipes**
No recipes are tagged `auto-plan`. Run `tag_recipes.rb` first.

**Telegram bot not responding**
Check that `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are set correctly in `.env`. The chat ID must be your personal chat with the bot (message `@userinfobot` to get it). Phase 3 not yet implemented.

**Food Lion cart not matching expected items**
Check `product_map` — items without a map entry are flagged rather than guessed. Run `scripts/seed_product_map.rb` (Phase 4) to set up mappings interactively.

**`data/PAUSE` file exists**
Someone (or you) created the kill switch. `rm data/PAUSE` to resume.
