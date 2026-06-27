# Mealie AutoChef — First-Run Setup Walkthrough

This is a concrete, sequential guide to getting AutoChef running end-to-end for the first time. Follow the steps in order — each step's output is what the next step expects. All commands are run from the repo root unless otherwise noted.

**Estimated time:** 45–90 minutes, depending on how many recipes you're tagging.

---

## Prerequisites

Before step 1:

- Ruby 3.2+ installed (`ruby --version`)
- Bundler installed (`gem install bundler`)
- Python 3.11+ installed (`python3 --version`)
- A running self-hosted Mealie instance with recipes in it
- A Telegram account
- A Food Lion To Go (Instacart) account with pickup enabled
- Docker + Docker Compose (for production; steps 1–7 work without Docker)

---

## Step 1 — Install Ruby gems

```bash
bundle install
```

**Expected output:** Gems resolve from `Gemfile.lock`, no conflicts. If you see version conflicts, check that you're on Ruby 3.2+.

---

## Step 2 — Configure secrets

```bash
cp .env.example .env
```

Open `.env` and fill in:

```bash
MEALIE_API_TOKEN=<your token>       # Mealie UI → your username → API Tokens → create one
ANTHROPIC_API_KEY=sk-ant-...        # console.anthropic.com
TELEGRAM_BOT_TOKEN=123456:ABC...    # @BotFather → /newbot → copy the token
TELEGRAM_CHAT_ID=987654321          # @userinfobot → it replies with your user ID
FOODLION_USERNAME=you@email.com     # your Food Lion / Instacart login
FOODLION_PASSWORD=...               # your Food Lion / Instacart password
UPTIME_KUMA_PUSH_URL=...            # optional; leave blank if you don't have Uptime Kuma
```

For **Telegram**:
1. Message `@BotFather` in Telegram, send `/newbot`
2. Follow the prompts. Copy the token it gives you → `TELEGRAM_BOT_TOKEN`
3. Start a chat with your new bot (send `/start`)
4. Message `@userinfobot` → it replies with `Your ID: 987654321` → `TELEGRAM_CHAT_ID`

**Security note:** Never commit `.env`. It's in `.gitignore`.

---

## Step 3 — Fill in config.yaml

Open `config.yaml`. Three values are marked `FILL IN`:

```yaml
store:
  name: "Food Lion - Raleigh, NC"   # your preferred pickup location name

schedule:
  pickup_window_pref: "Sun 10:00-12:00"  # your preferred day+window

safety:
  spending_cap_usd: 150   # abort if cart exceeds this; adjust to your budget
```

The rest of the defaults are reasonable starting points:

- `meals.week_layout` — edit to match your actual cooking schedule (`cook` / `leftover` / `out` / `skip`)
- `selection.repeat_avoidance_weeks: 3` — recipes won't repeat within 3 weeks
- `llm.enabled: true` — Claude Haiku arranges the plan; set `false` to save ~$0.03/week and use deterministic ordering

---

## Step 4 — Verify setup (config + DB + Mealie ping)

```bash
bundle exec ruby main.rb check
```

**Expected output (outside Docker — Mealie unreachable):**
```
=== Mealie AutoChef — Phase 0/1 sanity check ===
Config loaded OK (mealie: http://mealie:9000, store: Food Lion - ...)
Database initialized and migrated OK.
Mealie connection FAILED: ...

Result: PARTIAL — config/db OK, Mealie unreachable (expected if Mealie
isn't on mealie_net yet, or this isn't running inside Docker).
Tip: set MEALIE_URL=http://localhost:9000 in .env to point at your local Mealie.
```

`PARTIAL` is expected at this stage if you're not yet inside Docker. Config + DB OK is all you need to continue.

**If Mealie is reachable locally** (e.g., via `localhost:9000`), add to `.env`:
```
MEALIE_URL=http://localhost:9000
```
Then re-run `main.rb check` — you should see `Eligible pool: N recipe(s)` and `Result: OK`.

---

## Step 5 — Tag recipes in Mealie

AutoChef only plans from recipes tagged `auto-plan`. This interactive script walks your entire Mealie library:

```bash
bundle exec ruby scripts/tag_recipes.rb
```

**What it does:**

For each recipe, it prompts you to:
1. Add `auto-plan` (admit to planning pool)
2. Add `cuisine:*` tag (e.g., `cuisine:italian`)
3. Add `protein:*` tag (e.g., `protein:chicken`)
4. Add `effort:*` tag (`effort:quick` or `effort:project`)
5. Add `makes-leftovers` if the recipe yields enough for the next day

After recipes, it walks every ingredient in eligible recipes and prompts for `shelf_life_days`. This is the number that drives perishability-aware scheduling — more perishable meals land earlier in the week. Suggest values are provided (e.g., "fish: suggest 2 days").

**Expected output:**
```
[1/47] Lemon Herb Chicken (slug: lemon-herb-chicken)
  Add auto-plan? [y/N] y
  Cuisine tag (e.g. american, italian, asian, mexican) or blank: american
  Protein tag (e.g. chicken, beef, fish, vegetarian) or blank: chicken
  Effort (quick/project) or blank: quick
  Makes leftovers? [y/N] y
  ✓ Tagged.
...
```

**Tips:**
- `--untagged` flag to only see recipes not yet in the pool (fastest for subsequent runs)
- `--eligible` flag to only see already-eligible recipes (to fill in missing tags)
- `--foods-only` flag to skip recipe tagging and go straight to shelf-life setup

---

## Step 6 — Sync recipe data to local DB

```bash
bundle exec ruby main.rb sync
```

This pulls `avg_rating` and `lastMade` from Mealie into `recipe_stats`. The scorer uses these to rank recipes.

**Expected output:**
```
=== Mealie AutoChef — sync (pull Mealie → recipe_stats) ===
Connected to Mealie 1.x.x at http://mealie:9000
Found 23 eligible recipe(s) tagged 'auto-plan'
Synced 23 recipe stat(s).
```

Re-run `sync` any time you update ratings or cook history in Mealie.

---

## Step 7 — Set up the Python side (cart_builder)

```bash
# Create a Python virtual environment scoped to this project
python3 -m venv .venv
source .venv/bin/activate

# Install Playwright and dependencies
pip install -r cart_builder/requirements.txt
playwright install --with-deps chromium
```

**Verify:**
```bash
python3 -c "from playwright.sync_api import sync_playwright; print('OK')"
```

**Expected:** `OK`

### Seed the Food Lion browser session (interactive, one-time)

```bash
python3 cart_builder/cart.py --login
```

This opens a **visible** Chromium browser window and waits for you to:
1. Navigate to Food Lion To Go
2. Log in with your `FOODLION_USERNAME` / `FOODLION_PASSWORD`
3. Make sure you're on the pickup flow (not delivery)

When you're logged in and see the store homepage, press Enter in the terminal. The script saves `data/playwright_state.json` with your session.

```bash
deactivate

# Tell cart_client.rb where the venv Python is
export CART_BUILDER_PYTHON="$(pwd)/.venv/bin/python3"
```

Add that `export` line to your `.env` or shell profile so it persists across sessions. Inside Docker, `CART_BUILDER_PYTHON` is set automatically by the Dockerfile.

---

## Step 8 — Seed the product map

```bash
bundle exec ruby scripts/seed_product_map.rb
```

This interactive script maps Mealie ingredient names → Food Lion search terms + pack sizes. For each unmapped ingredient, it prompts:

- Search term (what to type into Food Lion search)
- Pack unit (`oz`, `lb`, `ct`, etc.)
- Default quantity
- Preferred product ID (optional — if you already know the Instacart product ID)

**Expected output:**
```
37 unmapped ingredient(s) from your eligible recipes.

[1/37] chicken thighs, boneless skinless
  Search term [chicken thighs]: boneless skinless chicken thighs
  Pack unit (oz/lb/ct or blank): lb
  Default qty [1]: 2
  Preferred product ID (optional): 
  ✓ Saved.
```

Items not in the product map are flagged (not silently substituted) in the cart-ready notification. You can re-run this script any time new ingredients appear.

---

## Step 9 — Generate the first plan

```bash
bundle exec ruby main.rb plan
```

This scores all eligible recipes, builds a week plan, and sends a Telegram message with inline buttons.

**Expected output:**
```
=== Mealie AutoChef — plan (Phase 2) ===
Eligible pool: 23 recipe(s) tagged 'auto-plan'

--- Week of Sunday, June 28, 2026 ---
(via Claude)

  Sun Jun 28: Lemon Herb Chicken (2 servings)
  Tue Jun 30: Beef Stir Fry (2 servings)
  Wed Jul 1: Pasta Carbonara (2 servings)  [perishable: 3d]
  Sat Jul 4: Salmon + Roasted Veg (2 servings)  [perishable: 2d]

Warnings:
  ⚠  Salmon assigned to Sat (6 days after pickup). Perishability: 2d.

Plan saved to plan_history (id=1).
Plan draft sent to Telegram (plan_history id=1).
Start `bundle exec ruby main.rb serve` to handle approval buttons.
```

Check your Telegram — you should have received the plan message with Approve/Swap/Regenerate buttons.

---

## Step 10 — Start the bot and approve the plan

Start the long-running bot process (in a separate terminal or as a background process):

```bash
bundle exec ruby main.rb serve
```

**Expected output:**
```
=== Mealie AutoChef — serve (Phase 3 Telegram bot) ===
Telegram bot starting (polling)...
Reminder scheduler started.
```

Now go to Telegram and tap **Approve** on the plan message.

**Expected sequence after Approve:**
1. Bot acknowledges: "Approved! Building shopping list..."
2. `main.rb shop` runs internally → pushes the "Next Order" list to Mealie
3. `main.rb build-cart` runs internally → Playwright builds the Food Lion cart
4. Telegram message: "Cart ready: $87.40 — tap here to review" (with a link)

Go to Food Lion To Go → review the cart → place the order when you're ready.

**If `safety.dry_run: true` (the default):** The cart is built but checkout is not clicked. You'll see a dry-run note in the cart-ready message. This is correct behavior — the dry-run default is intentional.

---

## Full end-to-end command sequence (weekly, after first-run setup)

```bash
# Thursday ~6 pm (or automatically via `main.rb serve`'s scheduler):
bundle exec ruby main.rb plan

# Approve via Telegram (bot handles the rest automatically)

# After your Sunday pickup — close the feedback loop:
bundle exec ruby main.rb feedback

# Saturday night — backup:
bundle exec ruby main.rb backup
```

Once `main.rb serve` is running continuously (e.g., inside Docker), `plan` can be scheduled via rufus-scheduler instead of a manual cron call. See `lib/autochef/reminders.rb` and `MEALIE_AUTOMATION_PLAN.md` section 12 for the Docker/Unraid scheduling setup.

---

## Docker production deployment

```bash
docker network create mealie_net
docker network connect mealie_net <mealie_container_name>

cd docker
docker compose up -d --build
docker compose logs -f
```

The container runs `main.rb serve` as its entrypoint. The weekly `plan` command is fired by rufus-scheduler inside the `serve` process at the time configured in `schedule.weekly_run`.

**Required volume mounts** (in `docker-compose.yml`):
- `./data:/app/data` — persistent SQLite DB, backups, screenshots, playwright session
- `./.env:/app/.env:ro` — secrets (or use Docker secrets / Unraid secret management)

**Verify the container is healthy:**
```bash
docker compose exec autochef bundle exec ruby main.rb check
```

Expected: `Result: OK` (Mealie reachable over `mealie_net`).
