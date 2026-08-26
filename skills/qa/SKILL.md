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

## When you cannot tell whether it works

A criterion you cannot verify is a Fail — that rule does not bend. But before
recording one, be sure the doubt is about *the code* and not about *the
framework*.

Those are different failures. "The snapshot does not match" is a finding. "I
cannot tell whether this snapshot API is supposed to need a host application"
is not a finding yet, and a Fail written from that doubt sends the next fix
attempt chasing the wrong thing — or worse, rewriting working code to satisfy a
misreading.

So when the uncertainty is about how a framework, tool or API is meant to
behave, **search the web before writing the verdict**: the exact error text,
the API name, and what the community does about it. The official documentation
and the project's issue tracker are worth more than a forum post, but a
recurring complaint in issues is itself evidence about how the tool really
behaves.

What that changes:

- **It confirms the failure.** You now know what correct use looks like and can
  say precisely how the code departs from it. Put that in the `QA-FAILED:` line
  — a specific, sourced description is what makes the next fix attempt land.
- **It dissolves the failure.** What looked wrong is the documented behaviour.
  Record the criterion honestly against what you actually observed, and say in
  your prose what you found and where.

Keep it proportionate: a couple of focused searches, not an investigation. If
nothing useful turns up, say so and fall back to the rule — unverifiable is a
Fail. Never let a search become a reason to pass something you could not
verify.

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
