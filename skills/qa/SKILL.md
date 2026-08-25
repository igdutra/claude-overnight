---
name: qa
description: Workflow step 5 of 7 (with /local-code-review). QA a finished implementation against specs/$ARGUMENTS/SPEC.md Acceptance Criteria, in a fresh context. Functionality only — /local-code-review covers correctness and style.
disable-model-invocation: true
context: fork
background: false
---

Act as QA on a finished implementation. You have no memory of building this —
read `specs/$ARGUMENTS/SPEC.md` and the code fresh, as an outside reviewer.

Check functionality only. Do not comment on code style, architecture, or
anything `/local-code-review` would catch — that's a separate step.

Read `## Requirements` first if present — it says what the user should observe.
Judge against that, not against what the code appears designed to do.

For each item under `## Acceptance Criteria`:

1. Determine how to check it — run it, read the code path, or inspect output.
   State what you did. `## Verification` in the spec tells you how.
2. Mark Pass or Fail. No partial credit — if you can't verify it, it's a Fail.
3. Give evidence: what you ran or read, and what you observed. Not an assertion.

Also read `specs/$ARGUMENTS/implementation-notes.md` if it exists — flag any
logged deviation that could break an acceptance criterion, even if the criterion
technically passes.

## Verdict

End with a one-line summary in prose: all criteria pass, or what failed.

Then, as the very last thing you output, a machine-readable block. An unattended
overnight run parses this to decide whether to ship the work or send it back for
another fix attempt, so the format is fixed:

```
QA-VERDICT: PASS
QA-CRITERIA: 7 passed, 0 failed
```

or

```
QA-VERDICT: FAIL
QA-CRITERIA: 5 passed, 2 failed
QA-FAILED: <criterion> — <what was observed instead>
QA-FAILED: <criterion> — <what was observed instead>
```

Rules for the block:

- `PASS` only when every criterion passed. Anything you could not verify is a
  Fail, so it makes the verdict `FAIL` — never `PASS` with a caveat in prose.
- One `QA-FAILED:` line per failed criterion, each naming what you actually
  observed. That line is what the next fix attempt works from, so "returns nil
  when the list is empty" is useful and "doesn't work" is not.
- A logged deviation that could break a criterion which technically passes is
  worth a `QA-CONCERN:` line. It does not change the verdict; it carries
  forward to the morning report.
