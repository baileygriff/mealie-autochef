# Feature 20 — Multi-user Support

> **Status:** Placeholder — spec interview incomplete.
> **Priority:** Medium (higher than Features 18 and 19).
>
> **Spec completeness:** This is the most architecturally significant of the three unspecced
> features. Every layer of the system needs a shared-vs-per-user decision. Interview required
> before any implementation details can be written.

---

## Goal

Host a few friends on Bailey's server. Each user gets their own weekly plans, shopping carts,
and preferences. Recipe preferences are stored independently per user.

---

## Context and background

The entire system is currently single-user:
- One Telegram `chat_id` (any message on the bot is treated as Bailey's)
- One SQLite database with no user concept
- One `config.yaml` with no per-user overrides
- One Food Lion account
- One `playwright_state.json`

Multi-user is architecturally significant because it requires decisions at every layer.

---

## Known decisions

None yet — all architecture decisions are open pending interview.

---

## Open questions (interview needed)

### Identity and access

1. **How are users identified?** Telegram user ID is the natural answer since the bot is the
   primary interface. What prevents a random person from messaging the bot and getting access?
   - Option A: whitelist of Telegram user IDs in `config.yaml`
   - Option B: an invite code flow (bot DMs invite link, user clicks, gets access)
   - Option C: Bailey manually adds users via a bot command

2. **Is there a concept of roles?** Is Bailey always the admin (can see all users' plans, manage
   invites) while friends are regular users?

### What is shared vs. per-user

Each layer needs a decision:

| Layer | Likely decision | Questions |
|---|---|---|
| Recipe pool (Mealie) | **Shared** — same Mealie instance | Do friends see all recipes or a curated subset? |
| Recipe ratings/stats | **Open** — shared or per-user? | If a friend rates something 2★ and Bailey rates it 5★, whose score drives planning? |
| Plan history | **Per-user** — each person gets their own week | |
| Shopping lists / carts | **Per-user** or **per-household**? | Does each friend shop independently, or is there one shared cart? |
| Product map (search terms) | **Shared** — same Food Lion store | Or per-user if friends have different stores? |
| Food Lion account | **Open** — one account per user? | Friends would need their own Food Lion accounts if per-user. |
| `playwright_state.json` | **Per-user** if per-user cart | Multiple browser sessions to manage |
| Preferences (PreferenceNotes, nutrition targets) | **Per-user** | |
| `config.yaml` | **Shared** (one deployment) | Per-user overrides? |
| Week layout (WeekPref) | **Open** — per-user or shared default with per-user overrides? | |

3. **Is this a "household" model or "independent users" model?**
   - Household: one shared plan and cart built collectively based on everyone's preferences
   - Independent: each user runs their own pipeline completely separately

4. **Do friends each need their own Food Lion account?** If each user gets their own cart,
   they'd need their own credentials and `playwright_state.json`.

### Telegram bot model

5. **Single shared bot or separate bots per user?**
   - Single bot: one bot token, each user's Telegram ID routes them to their own context
   - Separate bots: each user gets their own bot (operationally simpler but doesn't scale,
     and requires managing multiple bot tokens)
   - Single bot is the architecturally correct answer for a multi-tenant system

6. **How does the bot distinguish users?** `message.from.id` (Telegram user ID) is the natural
   key. Currently `chat_id` is used for send targets — this distinction matters.

### Recipe stats sharing

7. **If recipe ratings are per-user:** `recipe_stats` needs a `user_id` foreign key.
   The scoring system would need to query per-user stats. The backfill and plan commands
   would need user context.

8. **If recipe ratings are shared:** How are conflicts resolved when users disagree?

---

## Technical notes (preliminary)

- A new `User` AR model will be needed with at least `telegram_user_id` and a whitelist/active flag
- If `recipe_stats` becomes per-user: significant schema migration + scorer/planner refactor
- `main.rb serve` (BotServer) currently assumes one global `@pending_states` — needs to be
  keyed by `user_id` not just `chat_id` (currently the same thing for a single user)
- The Application Orchestrator Refactor (improvement spec) would make it much easier to inject
  user context through orchestrators — worth implementing that first
- `playwright_state.json` per-user would mean multiple Playwright sessions to manage; could
  run them serially or in parallel
- Feature 19 (Web UI) likely depends on this feature for the account/login concept

---

## Suggested interview order

Start with questions 1, 3, and 5 — those three answers will clarify most of the architecture.
The shared-vs-per-user table can be filled in after understanding the household vs. independent
model.
