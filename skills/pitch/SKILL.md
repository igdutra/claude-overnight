---
name: pitch
description: Workflow step 7 of 7. Bundle specs/$ARGUMENTS — prototype, spec, and implementation notes — into one shareable doc to get buy-in from other people. Run when work needs approval or a decision recorded for others.
disable-model-invocation: true
---

# Pitch

Packages finished or proposed work into one link to drop in Slack. Distribution
is the whole point — the audience is other people, not the user.

Gather whatever exists in `specs/$ARGUMENTS/` — `discovery.md` (including its
`## Prototype` section), `SPEC.md`, `implementation-notes.md` — plus the diff if
it's built. Any of these may be missing; work with what's there.

## Output

Publish an HTML artifact. Justified here: nothing reads a pitch back, and a
markdown file pasted into Slack is a wall of `##`. This is read once, by people
who need to skim it.

Structure:
- **The ask** — what you want from the reader, up top. Approval, a decision, or
  just awareness. One line.
- **Problem** — why this came up, in their terms, not the codebase's
- **What we're doing** — the approach and the tradeoff it makes
- **Alternatives** — what was considered and why it lost. Link the prototype if
  one exists.
- **Status** — built, in progress, or proposed. If built, what QA verified.
- **Open questions** — what's still undecided, where input would help

## Write for someone who wasn't there

No internal shorthand, no assumed context from the build. Spell out acronyms and
system names on first use. Lead with impact, not implementation.

Keep it skimmable — someone should get the ask and the shape in thirty seconds.
