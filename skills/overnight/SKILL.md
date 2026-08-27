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

## Step 0: Get your bearings before anything else

**Do this first, every time, before resolving specs or touching the queue.**

A previous run may have stopped partway — a session limit, a crash, a machine
that slept. When it did, it left worktrees, branches, and possibly uncommitted
work on disk, and the queue file may claim things that are not true. Starting
fresh on top of that either duplicates work or destroys it.

This step exists because of a real failure: a run marked two specs `[x] SHIPPED`
that had no commits, no pushes, and no pull requests. The next invocation read
those marks, found nothing pending, and exited having done nothing — while one
spec's real implementation sat uncommitted in its worktree. **The queue file is
a claim, not evidence.** Verify against git and GitHub instead.

### Ask the repository what is true

For every spec you are about to run — and every spec the queue mentions, checked
or not — get its actual state:

```bash
${CLAUDE_PLUGIN_ROOT}/overnight/spec-state.sh <repo-root> <slug>
```

It reports one verdict per spec, derived from git and `gh` rather than from any
file the runner wrote:

| Verdict | Means | What it needs |
|---|---|---|
| `SHIPPED` | a pull request exists | nothing — genuinely done |
| `COMMITTED` | commits pushed, no pull request | the ship step never completed |
| `LOCAL-ONLY` | commits exist, never pushed | push and open the pull request |
| `DIRTY` | uncommitted work in the worktree | **your judgment — see below** |
| `EMPTY` | branch/worktree exist, nothing in them | safe to restart from scratch |
| `ABSENT` | nothing exists | the normal path |

Also read `overnight/<date>/<run-id>/logs/<slug>.checkpoint.json` if it exists
(newest run first, if there are several). It records
each phase, whether it was healthy, and why the run stopped — written precisely
so this question is a `cat` and not an archaeology expedition through `.jsonl`
streams.

### Then decide, per spec

`loop.sh` handles the two unambiguous cases by itself: it skips a genuinely
`SHIPPED` spec, and it reclaims an `EMPTY` one. You do not need to do anything
for those.

**The cases that need you are `DIRTY`, `LOCAL-ONLY`, and `COMMITTED`** — real
work exists that no pull request covers. `loop.sh` deliberately refuses to guess
here and stops with the queue item marked `?`, because the wrong guess either
duplicates work or throws away hours of it. That judgment is yours:

1. **Read what is actually there.** `git -C ../wt-<slug> status` and
   `git -C ../wt-<slug> diff`. Read the checkpoint to see which phase it died
   in.
2. **Work out how far it got.** Implementation complete but never committed?
   A fix half-applied when the limit hit, with its verification never re-run?
   Those are different situations.
3. **Choose, and say why:**
   - **Resume** — the work looks coherent and the spec's verification simply
     never ran. Keep the worktree, re-run the spec through `loop.sh`; the
     verify/fix cycle re-checks the work as it stands.
   - **Salvage** — the work is worth keeping but not finishing here. Commit and
     push the branch for the user to look at, and leave the spec unqueued.
   - **Restart** — the work is incoherent or trivial. Remove the worktree and
     branch, and queue the spec fresh.

   A fix interrupted partway through is the tricky one: it is real work, but it
   was never verified and may be half-applied. Prefer resuming it through the
   full verify cycle over trusting it, and never assume "the files are there" is
   the same as "the spec is done".

4. **Tell the user what you found and what you chose**, before the run starts —
   not afterwards. This is exactly the moment where a wrong assumption costs a
   night.

**Never mark a queue item `[x]` yourself on the strength of the queue's own
claim.** If a spec is genuinely shipped, `spec-state.sh` says `SHIPPED` and
`loop.sh` will mark it. If it is not, it needs work.

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

**`CLAUDE.md` needs a `## Build & Validation` block — and it must cover the specs
you are about to run.** This is the backpressure; without a real test command
nothing can tell the run when it is wrong, and an unattended night flows forward
saying *done, done, done*. If it is missing, run `/overnight-init` yourself to
establish and verify the commands, then continue.

Its presence is not enough. **Read the block and check it actually exercises the
code the queued specs touch.** Commands rot: a block written when the work was
in one package keeps naming that package after the work moves, and the suite
goes on passing while testing nothing anybody is changing. A green light from a
suite that never ran the new code is worse than no suite, because the run trusts
it.

Concretely: if the block's `Covers:` line (or, absent one, the commands
themselves) names a target the queued specs do not touch, stop and say so, and
run `/overnight-init` to re-verify and re-record the commands before launching.
This is a judgment only you can make — `loop.sh` can see that the block exists,
not whether it is still the right one.

**`jq` and an authenticated `gh`.** The loop parses JSON and opens pull
requests. If either is missing, stop and say exactly what to install or run —
this one genuinely needs the user.

**A clean working tree.** `loop.sh` refuses to start on a dirty one, because
unrelated local state makes the run's diffs unreadable. If there are uncommitted
changes, stop and show them. Do not commit the user's work for them.

## Step 3: Write the queue

The queue lives at `overnight/<today>/QUEUE.md` and is a markdown checklist. The
loop reads unchecked items and marks each as it goes:

| Mark | Meaning |
|---|---|
| `[ ]` | pending — the loop will pick this up |
| `[x]` | shipped, **verified** against GitHub — a pull request exists |
| `[!]` | blocked or skipped — see `RUN.md` for why |
| `[?]` | holds unshipped work and needs your judgment (Step 0) |

`[x]` is now only ever written after `spec-state.sh` confirms a real pull
request. A spec whose ship phase claimed success without producing one is marked
`[!]`, not `[x]`.

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
open adds nothing.

**Do not redirect its stdout to a log file of your own choosing.** `loop.sh`
writes its own console log inside the run directory and prints the exact
`tail -f` command at launch. Read that path out of its output and give the user
*that*; inventing a redirect is how a previous run left the user tailing a file
nothing was writing to. Redirecting to `/dev/null` is fine — the log on disk is
complete either way.

Each run writes everything it produces under
`overnight/<date>/run-<HHMMSS>-<pid>/` — `RUN.md`, `loop.log`, `logs/`,
`shipped.md`, `suggestions.md`. Runs on the same day therefore never share
state. `QUEUE.md` stays one level up at `overnight/<date>/`, because it is an
input the operator writes before any run exists.

**One run per repo at a time.** `loop.sh` takes a lock and refuses to start if
another run is already working in that repo — every run shares the same
`../wt-<slug>` and `spec/<slug>` namespace, so two would race each other over
the same worktrees. If it refuses, it names the run holding the lock and when
it started. A lock left behind by a killed run is detected as stale and
reclaimed automatically; it never needs deleting by hand.

Useful options, when the user asked for something specific:

- `--dry-run` — print what would happen without creating worktrees or calling
  Claude. Worth doing unprompted the first time a repo is used, then continuing.
- `--run-id <id>` — name this run's directory instead of taking the default.
  Worth it when the user wants a run they can refer to later by name.
- `--queue <file>` — run a queue other than today's. Two runs meant to work
  different spec sets need this; without it they share one queue file.
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

## Step 5: The report

**`loop.sh` writes the report itself when it can.** If the queue drained, the
session limit was never hit, and there is budget left, it runs
`/overnight-report` as its last act and the artifact is waiting in the morning.

It defers when it should not spend the budget — and records why in `RUN.md`
under `## Report — deferred`:

- the session limit was reached (no budget to write it)
- specs are still pending (the report covers a finished run)
- nothing ran
- the usage budget is spent

The reasoning: the report is the deliverable — the code sits on branches nobody
has read — but generating it costs a real session, and the worst possible ending
is a partial night whose report never got written because the window went dry.
So it is written when there is room and owed when there is not.

**When it was deferred, writing it is your job.** On any `/overnight`
invocation, check `RUN.md` for a `## Report — deferred` (or `— not written`)
section from a previous run. If one is there and that run is over, publish it
before starting new work:

```
/overnight-report <date>
```

Use the date of the *deferred* run, not today's. A night's work with no report
is a night the user cannot see.

If the loop is still going, say how to check on it and that the report comes
after. Do not publish a partial report unless they ask.

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
