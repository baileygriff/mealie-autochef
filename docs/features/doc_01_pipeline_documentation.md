# Doc Task 01 — Pipeline Documentation & Architecture Diagrams

> **Status:** Placeholder — not yet written.
> **Priority:** Medium — useful reference for both Bailey and AI agents.
>
> **Spec completeness:** Intent is clear. Interview needed to agree on which diagrams are most
> valuable and what format to use (Markdown text diagrams vs. Mermaid vs. something else).

---

## Goal

Document the full AutoChef pipeline with diagrams from two perspectives: (1) user-facing chat
flow (what Bailey sees and does in Telegram each week) and (2) technical back-end data flow
(what components, LLMs, and APIs are involved). Reference these docs from other relevant files.
Update them as part of the `/wrapup` skill.

---

## Bailey's description (verbatim)

> Document the general user pipeline for the readme and/or make a new doc for this app flow.
> This will be a helpful reference to users and ai. Diagram the steps and components for both
> the flow of the chat app, and the back end data processing happening between code and llms.
> Organize these documents as new files and reference them in other related docs. Make sure
> they get updated as a part of the wrapup skill. These should act as an overall app diagram
> from multiple different perspectives, user and technical.

---

## Known decisions

- Multiple perspectives: user-facing flow + technical/data flow
- Organized as new files (not stuffed into README)
- Referenced from: README, TESTING_HANDOFF.md, CLAUDE.md (if it exists)
- Must be updated as part of the `/wrapup` skill (currently updates TESTING_HANDOFF.md,
  testing_feedback.md, future_enhancements.md, README, memory — would add these docs to
  the list)

---

## Proposed documents (to be confirmed in interview)

**`docs/USER_PIPELINE.md`** — User-facing flow:
```
Every Monday
└── Bailey gets a Telegram message with the week plan
    └── Taps [Approve], [Swap], or [Regen]
        └── Taps /shop to build the shopping list
            └── Cart ready message arrives
                └── Reviews cart, goes to Food Lion To Go
                    └── Places order manually (dry_run: true always)
                        └── Sunday: picks up groceries
                            └── Bailey runs feedback (or it's automatic)
                                └── Scores update for next week
```

**`docs/TECHNICAL_PIPELINE.md`** — Technical/data flow:
- Components diagram: Ruby main.rb → LLM tools → Mealie API → cart.py → Food Lion
- Data flow per command: what reads from DB, what writes, what calls the LLM, what calls Mealie
- LLM call map: which model is used at each step, what goes in, what comes out
- Component dependency graph

---

## Open questions (interview needed)

1. **Format:** Plain Markdown text diagrams (ASCII art arrows), Mermaid flowcharts (rendered on
   GitHub), or both?

2. **Audience level:** Should `USER_PIPELINE.md` be written for a brand-new user who has never
   heard of AutoChef? Or for Bailey + AI agents who know the domain?

3. **What to include in the technical diagram:**
   - Just the Ruby/Python component map?
   - Also include: DB schema overview? LLM prompt context summary? Mealie API endpoints used?

4. **Living document standard:** What counts as "needs updating" for wrapup? Only when the
   pipeline steps change, or also when new LLM tools are added?

5. **`CLAUDE.md`:** Does a `CLAUDE.md` exist in this project? (It's referenced in
   `TESTING_HANDOFF.md` as "architecture overview (if it exists; skip if not)"). If not,
   should this task create it?

---

## Technical notes (preliminary)

- New files: `docs/USER_PIPELINE.md`, `docs/TECHNICAL_PIPELINE.md` (names TBD based on interview)
- `/wrapup` skill (`.claude/commands/wrapup.md`) will need a new step: "Update pipeline docs
  if any component, command, or LLM step changed this session"
- Mermaid diagrams render natively in GitHub — good choice if the repo is on GitHub
- The existing `docs/` directory already has `SETUP_WALKTHROUGH.md`, `USER_GUIDE.md`,
  `DEVELOPER_GUIDE.md` — the new files slot in alongside these
