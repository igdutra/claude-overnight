---
name: implement-spec
description: Workflow step 4 of 7. Implement specs/$ARGUMENTS/SPEC.md, keeping implementation-notes.md current for the whole task.
disable-model-invocation: true
---

Implement `specs/$ARGUMENTS/SPEC.md`.

Resolutions under `Open Questions / Risks` are decided — build on them, don't
re-open them. If the approach fails mid-build, re-plan against `Requirements`;
the goal holds even when the design changes.

For the visual reference, read `specs/$ARGUMENTS/design.html` if it exists — a
read-only, static snapshot of the locked design, a few KB of plain HTML. **Do
not `cat` or read `prototype.html` or any `.dc.html` canvas file**; those bundle
the design-canvas editor runtime (2.5 MB on spec 006) and reading one floods
this session's context. If `design.html` is missing, work from the `SPEC.md`
prose and the `## Prototype` section of `discovery.md`; do not open the canvas.

## First: check whether this is already partly built

You may be running on a worktree that already holds work — a previous attempt
that was interrupted, or one the overnight loop is resuming. Before writing
anything, look: if `specs/$ARGUMENTS/implementation-notes.md` exists, or source
files the spec calls for are already there, **treat the spec as partially or
fully built.**

In that case the job is to *close the gap*, not to start over. Read the notes
and the existing code, check them against `SPEC.md`, and implement only what is
missing or wrong. Re-implementing from scratch on top of working code throws
away a previous session's reasoning and routinely reintroduces exactly the
deviations that notes file was written to record.

If the existing work looks complete, say so plainly and verify it against the
spec rather than manufacturing changes to look busy — the verification phases
that follow are what decide whether it is actually done.

Keep `specs/$ARGUMENTS/implementation-notes.md` current for the whole task.
If an edge case forces you off the plan: take the conservative option, append
one line under `## Deviations` (what changed and why), continue.
Do not log changes that match the plan.

If you edit `SPEC.md` itself, bump its `Updated:` line to today.

When a framework or API does not behave the way you expected — an error whose
cause is not obvious, a call that needs setup the docs in your head do not
mention — search the web before working around it. Here, unattended and at
2am, an invented workaround becomes a QA failure later at several times the
cost, and a session with no memory of this moment gets to debug it blind.
Prefer the official documentation and the project's issue tracker, note what
you found under `## Deviations`, and move on. Keep it to a search or two: this
is for genuine unknowns, not a substitute for reading the code in front of you.
