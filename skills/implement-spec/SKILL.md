---
name: implement-spec
description: Workflow step 4 of 7. Implement specs/$ARGUMENTS/SPEC.md, keeping implementation-notes.md current for the whole task.
disable-model-invocation: true
---

Implement `specs/$ARGUMENTS/SPEC.md`.

Resolutions under `Open Questions / Risks` are decided — build on them, don't
re-open them. If the approach fails mid-build, re-plan against `Requirements`;
the goal holds even when the design changes.

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
