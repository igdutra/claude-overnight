---
name: discovery
description: Workflow step 1 of 7. Surface unknown unknowns about a new non-trivial task, then interview the user one question at a time, prioritized by architectural impact. Use before writing code, before plan mode, before touching files on a task that hasn't been scoped. Trigger on /discovery, or proactively when a task is non-trivial and unscoped. Skip for trivial fixes or already-scoped tasks.
---

# Discovery

First step of the workflow. Finds what the user hasn't thought of yet, cheaply.

## 1. Orient

Read enough of the codebase (structure, key files, README, entry points) to
summarize in plain language what it is and does. Post that summary as its own
message. Do not combine it with a question — an interview built on a guessed
mental model asks the wrong things.

## 2. Blind spot pass

Look for unknown unknowns in this task: assumptions the request rests on,
decisions it implies but doesn't state, parts of the codebase it will touch that
the user may not know exist.

## 3. Checkpoint

Count the real questions — ones whose answer would change the architecture.
State the count, then:

- **Zero:** say the task is already scoped, give your read of it in a few
  sentences, and stop. No interview.
- **One or two:** just ask them. No ceremony.
- **Three or more:** say how many you have and what they cover, then ask if the
  user wants the full interview or just the top ones.

## 4. Interview

One question at a time, highest architectural impact first. Wait for each answer
before the next. Stop when what's left wouldn't change the plan, or the user says
to proceed.

## 5. Name the task

Establish the task slug — every later skill takes it as an argument, so this is
where it gets fixed.

Format `NNN-short-kebab-slug`. Take `NNN` as the highest existing number in
`specs/` plus one, zero-padded to three digits (`ls specs/`). Padding matters:
unpadded, `10-` sorts before `2-`.

State the slug in chat so the user can pass it onward.

## 6. Write findings

Ask which format:

- **Markdown** — `specs/NNN-slug/discovery.md`. `/spec` reads it back; cheaper.
  Default for most tasks.
- **HTML artifact** — rendered to react to. Worth it when findings are
  substantial or visual, or when sharing them. Still write
  `specs/NNN-slug/discovery.md` with the artifact URL and the decisions in
  plain text — later skills run forked and cannot open an artifact.

Record decisions made and open questions — not a transcript.
