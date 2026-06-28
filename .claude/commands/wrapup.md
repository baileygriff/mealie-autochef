You are wrapping up a working session on the Mealie AutoChef project. Your job is to update all documentation and memory to reflect what happened this session, then commit and push.

## Step 1 — Gather session context

Run these in parallel:
- `git diff HEAD` — see exactly what changed (staged + unstaged)
- `git status` — list untracked files
- `git log --oneline -10` — recent commit history and message style

Read these files in full:
- `TESTING_HANDOFF.md`
- `testing_feedback.md`
- `future_enhancements.md`
- `README.md`
- `~/.claude/projects/-Users-baileygriffin-Projects-mealie-autochef-ruby/memory/project_status.md`

Use the git diff as the authoritative record of what changed. Conversation context gives you the *why*.

## Step 2 — Update TESTING_HANDOFF.md

In the **"Current state as of…"** table:
- Change the date in the header to today
- Increment the session number
- Mark newly completed steps ✓
- Add any new "NOT YET" rows for things discovered this session

In **"What's coming next"**:
- Mark completed items ✅
- Keep the numbered list accurate — features stay numbered in order, infrastructure stays at 11–13
- Update the session reference ("cleared in Nth session")

In **"Key gotchas"**: add any new gotchas discovered this session.

## Step 3 — Update testing_feedback.md

Add a new section at the top of the bug history (below "Known Issues") for this session:

```markdown
## Implemented / Fixed — YYYY-MM-DD (Nth session)

**Feature or bug title**
Short description of what was done and why.
File: `path/to/file`
```

Update **"Known Issues"** at the top: remove anything fixed, add anything newly discovered.

Update the **Test Suite State** table if the example count changed.

Update **cart.py State** if anything changed in cart automation.

## Step 4 — Update future_enhancements.md

In the **Feedback / Improvements** section:
- Mark completed items ✅
- Add any new feedback items that came up this session (unnumbered, under a "New feedback" sub-heading if needed)

In **New Features**:
- Mark any newly completed specs ✅
- Add any new feature specs discovered this session (give them the next number, full spec format)

## Step 5 — Update README.md

Only update README if:
- A new CLI command was added or removed
- Setup steps changed
- A new dependency was added

Don't touch README for internal refactors or bug fixes.

## Step 6 — Update memory

Read the existing memory files and update only what changed. Do not rewrite files that are still accurate.

**Always update** `project_status.md`:
- Add the new session to "Steps completed"
- Move newly done items out of "Steps NOT yet done"
- Add any new bugs to the summary section
- Update the test suite count if it changed

If new user preferences or working-style patterns emerged, update `user_bailey.md`.

If a new architectural constraint or gotcha was discovered, create a new `feedback_*.md` memory file and add it to `MEMORY.md`.

## Step 7 — Commit and push

Stage all modified tracked files and any new files that belong in the repo (skip `.env`, `data/autochef.db`, `data/backups/`, `data/playwright_state.json`, `data/cart_screenshots/`).

Write the commit message in the project's style (short imperative subject, no trailing period). Include what changed and why — not just "update docs". Example:

```
Add debug screenshots (feature 5); update session docs
```

Use a HEREDOC for the commit message. After committing, push to the remote.

Report what was committed and pushed.
