---
name: finish
description: Workflow step 6 of 7. Close the loop on specs/$ARGUMENTS — explain what was built and why, so the user understands code they didn't write line by line. Optionally quiz them on it. Run after /qa passes.
disable-model-invocation: true
context: fork
background: false
---

# Finish

Last step. After a long agentic build the user has working code they don't fully
understand — that debt compounds into the next task. This pays it down.

Read `specs/$ARGUMENTS/SPEC.md`, `discovery.md` and `implementation-notes.md` if
present, and the diff.

For the diff use `git diff main...HEAD`. If that comes back empty — you're on
`main`, or the work isn't committed — fall back to `git diff HEAD` and
`git status`, or ask which base to compare against. Never explain an empty diff.

## Explain

Publish an HTML artifact. Read once, never parsed back — markup is worth it here.

Cover:
- **What was built** — in plain language, not a changelog
- **How it works** — the mechanism and the shape of the flow, enough to navigate
  the code unaided
- **Why it's like this** — decisions and their alternatives, pulled from the
  spec's Decisions and any logged deviations. This is the part that isn't
  recoverable from reading the diff.
- **Where things live** — the map: which file owns what
- **What to watch** — sharp edges, assumptions, anything deferred

Explain the reasoning, not the syntax. The user can read the code; they can't
read why it went this way and not the other.

## Then ask about the quiz

Ask whether they want a quiz appended.

Say what it's for: a quiz is worth it on code they'll maintain or extend, and
wasted on a throwaway spike. Their call.

If yes, append 5-8 questions to the artifact and republish. Ask about decisions
and consequences ("what breaks if this cache is never invalidated?"), not
trivia. Put answers in a collapsed `<details>` block after each question.

## Skip when

The change was small enough to read in one sitting.
