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
Ordered list, in build order. Finish with `Task list: yes` or `Task list: no` —
yes when the run will take a while: a long run fills the context window, older
turns get summarized, and a list in a file survives that.

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
from Approach. Number them `AC1`, `AC2`, … as a bold prefix on each bullet, not
checkboxes: the ID is a stable name that Verification, `/qa` and
`implementation-notes.md` can cite, while progress is tracked elsewhere (`/qa`
marks Pass or Fail, `TASKS.md` ticks Steps), so a box in the spec would only
mix state into the plan.

### Verification
How to check each criterion: tests, commands, manual steps. Name the criterion
IDs each line covers (`**AC3, AC4** …`).

## Then

Once the file is written, spawn one subagent on the Haiku model to check it for
contradictions. Give it the paths to `SPEC.md` and, if it exists, `discovery.md`
— not this conversation. A reader that has only the documents is the point.
Tell it:

> You are a focused checker. Your whole world is these files: <paths>. Read them
> and nothing else — do not open other files, search the code, browse the web,
> or edit anything. Look only for contradictions: numbers, names, and scope that
> disagree within a file or between the two, such as something under Out of
> Scope that Steps still builds. An alternative that `discovery.md` records as
> rejected or open is not a contradiction with a spec that settled it. For each
> one, quote both passages and say which file and section each is in. Do not
> suggest improvements or point out anything missing. If you find none, reply
> with exactly: NONE. Keep your reply under 200 words.

Check every flag against the file first — a small model raises false alarms —
and drop any that do not hold up. If it replies NONE, or none hold up, report
exactly one line, `✅ Contradiction check done.`, and nothing more. If any hold
up, do not edit the file. Stop and show each one: both passages and where they
are. The user decides how to proceed; show the Decisions below only after they
have.

Show the Decisions section in chat so the user can see what the plan committed
to. Say whether Steps flags a task list. Point out anything they should change
before `/implement-spec` runs.
