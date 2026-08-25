---
name: spec
description: Workflow step 3 of 7. Write an implementation plan from the current conversation and save it to specs/$ARGUMENTS/SPEC.md. Run after /discovery and /prototype, before /implement-spec.
disable-model-invocation: true
---

# Spec

Write the plan to `specs/$ARGUMENTS/SPEC.md`, pulling in any `discovery.md`
findings and prototype decisions.

If `$ARGUMENTS` is empty, `/discovery` didn't run — create the slug yourself as
`NNN-short-kebab-slug`, where `NNN` is the highest number in `specs/` plus one,
zero-padded to three digits. State it in chat; later skills take it as an
argument.

**Markdown, not HTML.** `/qa` reads this file back in a fresh context on every
run — markup would double that cost for no gain, and the headers below are what
`/qa` parses.

## Before writing anything

Draft the plan first and see what it exposes. Writing a plan is what reveals
what discovery missed.

**If nothing is unresolved, write the file. Say nothing first.** A good
discovery should produce a spec with no interruption — prompting is the
exception, not a ritual.

**If something genuinely is unresolved, write no file yet.** Surface each gap
in chat, and with each one already state the conservative path you'd take, so
the user can answer "yes to all" in one line:

```
- **Question?** → What I'd do, and why it's the safe default.
```

Wait for the answer. Then write the file with those answers folded in — the
file is written only once the questions are closed.

Only raise what actually blocks the plan. Not preferences, not things the
codebase already answers, not detail you can decide conservatively and note.

Lead with what the user is most likely to change. Decisions before mechanics —
the plan is a decision surface, not a deliverable.

## Structure

Open the file with two lines, then the headers below exactly:

```
Created: YYYY-MM-DD
Updated: YYYY-MM-DD
```

Set both to today on creation. On any later edit, bump `Updated` only.

### Context / Why
Why this exists — the problem, not the solution. 2-3 sentences.

### Requirements / What
What the user can observe when this works. No tech: no types, files, or APIs.
Short bullets. This is the one section that cannot be recovered from the
codebase, and later skills run forked with no memory of this conversation —
so if the approach turns out wrong mid-build, this is what they re-plan
against. Omit the header entirely when the change has no behavioral surface
(a pure refactor).

### Decisions / Architecture
The choices the user would most likely want to tweak: data model changes, new
interfaces, anything user-facing. One line each, with the alternative rejected
where a prototype settled it. Highest-impact first.

### Approach / How
The rest of the design — files touched, how pieces fit. State what's being
assumed and what's fixed (existing patterns, APIs, constraints to respect).
Skip mechanical detail.

### Out of Scope
What this explicitly does not cover. Prevents mid-build scope creep.

### Steps
Ordered list, in build order.

### Open Questions / Risks
A record of what got settled above, not a list of what's still open — by the
time this file exists, nothing is open. Each entry is the question and the
answer it was closed with:

```
- **Question?** → How it was settled, and why.
```

Downstream skills treat these as decided. Risks that were never questions —
things that could still go wrong at build time — are plain bullets.

### Acceptance Criteria
Concrete statements of what "done" means — what must be true, not how to check.
Each answerable yes/no. Derive these from Requirements where it exists, not
from Approach.

### Verification
How to check each criterion: tests, commands, manual steps.

## Then

Show the Decisions section in chat so the user can see what the plan committed
to. Point out anything they should change before `/implement-spec` runs.
