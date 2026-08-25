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
