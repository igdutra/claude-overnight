---
name: overnight
description: Run a queue of specs unattended — set up worktrees, implement each spec, QA it, review it, fix what blocks, open pull requests, and publish a morning report. This is the entry point for overnight runs. Trigger on /overnight, optionally with spec slugs.
disable-model-invocation: true
---

# Overnight

Start an unattended run. This is the only overnight command anyone should need
to type: it works out what to run, checks the repository is ready, launches the
loop, and publishes the morning report when the loop is done.

`$ARGUMENTS` may name specs to run (slugs, or unambiguous prefixes). Empty means
run whatever the queue already holds.

Everything below is your job, not the user's. They typed one command; they
should not have to know about worktrees, branches, queue files, or which script
drives which. If something is missing, create it or fix it and say what you did.

## Step 1: Find the repository and the specs

Confirm you are in a git repository (`git rev-parse --show-toplevel`). If not,
stop and say so.

List `specs/*/` and read what is there. Then resolve `$ARGUMENTS` against it:

- **An exact directory name** — use it.
- **A prefix matching exactly one directory** — use that one, and say which.
  `002` resolving to `002-swiftui-snapshot-engine` is normal and expected;
  numbered specs with descriptive suffixes are a common convention and the user
  should not have to type the whole thing.
- **A prefix matching several** — stop and list the candidates. Never guess
  between them.
- **No match** — stop and list what does exist. Do not invent a spec.

Every spec you run must have a readable `SPEC.md`. Skip any that does not, and
say which you skipped.

## Step 2: Check the repository is set up

The run needs three things. Check them and fix what you can rather than
reporting a wall.

**`CLAUDE.md` needs a `## Build & Validation` block.** This is the backpressure —
without a real test command nothing can tell the run when it is wrong, and an
unattended night flows forward saying *done, done, done*. If it is missing, run
`/overnight-init` yourself to establish and verify the commands, then continue.

**`jq` and an authenticated `gh`.** The loop parses JSON and opens pull
requests. If either is missing, stop and say exactly what to install or run —
this one genuinely needs the user.

**A clean working tree.** `loop.sh` refuses to start on a dirty one, because
unrelated local state makes the run's diffs unreadable. If there are uncommitted
changes, stop and show them. Do not commit the user's work for them.

## Step 3: Write the queue

The queue lives at `overnight/<today>/QUEUE.md` and is a markdown checklist. The
loop reads unchecked items, and marks each `[x]` shipped or `[!]` blocked as it
goes.

Write it from the specs you resolved in Step 1, using **full directory names**,
not the abbreviations the user typed:

```markdown
# Queue — 2026-08-25

- [ ] 002-swiftui-snapshot-engine
- [ ] 003-diff-renderer
```

Order matters: the loop runs top to bottom and stops when the budget runs low,
so put the specs that matter most first. If the user named them in a particular
order, keep it.

If a queue for today already exists with unchecked items, ask nothing — add the
new specs to it and keep what is there.

Commit the queue. The tree must be clean for the loop to start, so this is part
of setting up, not tidying afterwards.

## Step 4: Launch the loop

```bash
${CLAUDE_PLUGIN_ROOT}/overnight/loop.sh <repo-root>
```

Run it in the **background** — a full run takes hours, and holding the session
open adds nothing. Tell the user it has started, where the log is, and roughly
what to expect.

Useful options, when the user asked for something specific:

- `--dry-run` — print what would happen without creating worktrees or calling
  Claude. Worth doing unprompted the first time a repo is used, then continuing.
- `--max-specs <n>` — cap the number of specs this run.
- `--budget <tokens>` — override the usage ceiling.

What the loop does per spec, so you can explain it if asked: creates
`../wt-<slug>` on branch `spec/<slug>` with plain `git worktree add`, copies
anything listed in `.worktreeinclude` into it, then runs each phase as its own
Claude process in that directory — `/implement-spec`, then up to three rounds of
[tests, `/qa`, `/local-code-review`, fix], then a push-and-open-a-pull-request
phase or, if it never went green, a salvage phase that pushes the branch and
writes up why. Specs run **strictly one at a time**; the next worktree is not
created until the current spec is finished.

Separate processes per phase are the point, not an implementation detail: QA and
review are only worth anything with genuinely fresh context, and a session that
just wrote the code is the least reliable judge of it.

## Step 5: Report in the morning

When the loop finishes, publish the report:

```
/overnight-report <date>
```

That reads `overnight/<date>/` and publishes one artifact covering the night —
what shipped, what blocked, what needs a decision, with the pull request links.

If the user is running this interactively and the loop is still going, say how
to check on it and that the report comes after. Do not publish a partial report
unless they ask.

## What to tell the user

When the run starts, in a few lines: which specs are queued and in what order,
where the log is, and that pull requests will be waiting with a report to
publish in the morning.

When something stopped you, say what and how to fix it — not just that it
failed. "No `## Build & Validation` block in `CLAUDE.md`, so nothing can verify
the work; I ran `/overnight-init` and it found `swift test`" is useful.
"Setup incomplete" is not.

## Never

- **Never run the build phases yourself in this session.** `/implement-spec`,
  `/qa` and `/local-code-review` belong inside the worktree the loop creates;
  running them here would build in the user's main checkout on whatever branch
  they are standing on.
- **Never create the worktree by hand.** That is `loop.sh`'s job, and it also
  sets `OVERNIGHT_WORKTREE`, which is what arms the git guardrails. A worktree
  you made yourself would run unguarded.
- **Never commit the user's unrelated changes** to get a clean tree.
