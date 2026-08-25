---
name: local-code-review
description: Workflow step 5 of 7 (with /qa). Review the current diff locally for obvious bugs, plus a principal-engineer pass. Read-only and in-session — no subagents, no cloud review, no GitHub posting. Correctness and quality only; /qa checks whether it meets the spec.
disable-model-invocation: true
context: fork
background: false
---

Run `git diff main...HEAD` for the diff — or, if $ARGUMENTS is given, use that as
the base instead of `main` (e.g. `/code-review develop`). Note this skill's
argument is a **git base**, not a task slug like the other workflow skills take.

If the diff is empty — you're on `main`, or nothing is committed — fall back to
`git diff HEAD`. Say so rather than reporting no issues found.

## Step 1: Bugs

Read only the changed lines and their immediate context. Look for obvious bugs —
the kind that would actually bite, not nitpicks.

Ignore false positives:
- Pre-existing issues not introduced by this diff
- Anything a linter, typechecker, or compiler would catch
- Pedantic style nitpicks
- General code quality opinions (test coverage, docs)
- Issues on lines this diff didn't touch

Do not check build signal or attempt to build/typecheck.

## Step 2: Suggestions (principal-engineer pass)

Look at the same diff as a principal engineer would: code that's correct as
written but could be clearer, simpler, more robust, better named. Only what a
principal engineer would actually bring up.

These are not bugs — keep them out of the bug list. Each is take-it-or-leave-it.

## Output

Output in chat. Do not post to GitHub, open a PR, or modify any file — this pass
reads and reports, nothing else.

### Code review

Found N issues:

1. <description> — <why it's a bug>
   <file>:<line>

(or: No issues found.)

### Suggestions

1. <description> — <why it'd be better>
   <file>:<line>

(omit this section entirely if there are none)

## Verdict

After the sections above, as the very last thing you output, a machine-readable
block. An unattended overnight run parses this to decide what to act on, so the
format is fixed:

```
REVIEW-BUGS: 0
REVIEW-SUGGESTIONS: 3
```

or

```
REVIEW-BUGS: 2
REVIEW-BUG: <file>:<line> — <what's wrong>
REVIEW-BUG: <file>:<line> — <what's wrong>
REVIEW-SUGGESTIONS: 1
```

The split between the two counts is the whole point of the block. Overnight,
**bugs block and suggestions don't**: a bug sends the work back for another fix
attempt, while suggestions are filed for the user to read later and the code is
left alone. So the line a finding lands on decides whether code changes at 3am
with nobody watching.

That makes the bar for the bug list the same as it is in Step 1 — something that
would actually bite. A finding you're unsure about belongs in Suggestions, where
it gets read rather than acted on. Padding the bug list burns fix attempts on
nitpicks and can push a sound implementation into BLOCKED.

One `REVIEW-BUG:` line per bug, naming the file, the line, and what's wrong.
That line is what the next fix attempt works from, so it needs to be specific
enough to act on without re-deriving the review.

Do not list suggestions individually — the count is enough. Their text is
already above, and the run files that prose for the user to read in the morning.
