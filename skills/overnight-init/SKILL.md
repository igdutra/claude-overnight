---
name: overnight-init
description: Set up a repository for unattended overnight runs — detect and verify its build/test/lint commands, write them into CLAUDE.md, and seed the run queue. Run once per repository, before its first overnight run. Trigger on /overnight-init.
disable-model-invocation: true
---

# Overnight init

One-time setup for a repository that will host overnight runs. Everything here
is idempotent — running it twice is safe and is the right way to re-verify a
repo whose build commands have changed.

Two things must be true before a repo can run unattended:

1. **Its validation commands are known and actually work.** They are the
   backpressure — the wall that tells the loop "no, you're not done." Without a
   working test command an unattended run flows forward all night saying *done,
   done, done*, and the morning brings specs marked complete that are broken.
2. **The guardrails are active.** They make "never touch main" physically
   impossible rather than merely instructed, so it cannot drift at hour six.
   The plugin ships these, so there is nothing to install — but they are worth
   confirming before the first unattended night.

Work in the current repository. If `git rev-parse --show-toplevel` fails, stop
and say this must run inside a git repository.

The runner's own files live at `${CLAUDE_PLUGIN_ROOT}/overnight/`. This
skill does not copy any of them into the repository — the plugin ships the hook
and the scripts, and they are referenced in place.

---

## Step 1: Detect the project

Look for the markers below, in order. A repo may match several — a JS frontend
beside a Swift package — in which case set up the one at the repository root,
and note the other in your report.

| Marker | Project type |
|---|---|
| `Package.swift` | Swift package |
| `*.xcodeproj` / `*.xcworkspace` | Xcode project |
| `package.json` | Node |
| `Cargo.toml` | Rust |
| `pyproject.toml` / `setup.py` | Python |
| `go.mod` | Go |
| `Gemfile` | Ruby |
| `pom.xml` / `build.gradle` | JVM |
| `Makefile` | Make-driven |

Read the file you found — do not assume the conventional command. `package.json`
names its own scripts; an Xcode project has specific schemes; a `Makefile` has
specific targets. Prefer what the repo actually declares over what is typical
for its ecosystem.

Also read any existing `CLAUDE.md`, `README.md`, or CI config
(`.github/workflows/*.yml`) — CI is often the most reliable statement of how the
project is really built and tested.

## Step 2: Pick the commands

Derive a candidate for each of build, test, typecheck, and lint.

**Pick and report — never ask.** When several candidates are plausible (two test
runners, several Xcode schemes), choose the most likely and say clearly in your
report what you chose and what you passed over. A wrong pick is visible in the
report and trivially corrected; an interactive prompt makes this skill unusable
across many repos.

Choosing between candidates:

- Prefer what CI runs over what is conventional.
- Prefer the whole-suite command over a subset.
- For Xcode, prefer a scheme matching the product name; if several, prefer the
  one CI uses, else the first alphabetically, and report the others.
- Not every category applies. A Swift package has no separate typecheck — the
  build covers it. Record `covered by build` rather than inventing a command.
- If nothing sensible exists for a category, record `none` and say so.

## Step 3: Verify each command

**This is the step that matters.** The runner will trust these commands
completely, so a subtly wrong one is worse than none — it grants a green light
the code has not earned.

Run each candidate and record its exit code and how long it took. Use a generous
timeout; a cold build is slow. If a command fails, do not silently substitute
another — report the failure with its output.

Then look at what you actually observed, not just the exit code:

- **A suite that passes with zero tests is not backpressure.** If the output
  reports no tests, or finishes suspiciously fast, say so plainly. It exits 0
  happily and will never block anything.
- Note if tests appear to need a running service, network, or credentials —
  those will fail at 3am in a fresh worktree where they are not present.
- Note if the build needs files a fresh checkout will not have (`.env`, secrets,
  local config). Those go in the copy list in your report, because the runner
  works in a worktree where they are absent.

Report exactly what you ran and what you saw. Do not describe a command as
verified unless you ran it and it passed.

## Step 4: Write the CLAUDE.md block

Write to `CLAUDE.md` at the repository root:

```markdown
## Build & Validation

- Build:     <command>
- Tests:     <command>
- Typecheck: <command, or "covered by build">
- Lint:      <command, or "none">
```

If `CLAUDE.md` exists, **merge** — replace an existing `## Build & Validation`
section in place, and otherwise append. Never clobber the file; it may hold
instructions that matter more than this block.

Below the block, add a line for anything the fix cycle needs to know: a service
that must be running, a slow suite worth a longer timeout, a test that is known
flaky.

## Step 5: Check the guardrail and the tooling

**There is nothing to install here.** The plugin ships the hook at its root
(`hooks/hooks.json`), so it is registered in every session the plugin is loaded
in — no file to copy into the repository, no settings to edit.

The hook only fires when `OVERNIGHT_WORKTREE` is set, which `loop.sh` exports
for the duration of one spec and nothing else does. Outside a run it exits
immediately and allows everything, so it will not interfere with the user's
ordinary work in this repo.

Confirm it is registered and behaving:

```bash
# Should print a JSON deny decision:
OVERNIGHT_WORKTREE=/tmp/example \
  ${CLAUDE_PLUGIN_ROOT}/overnight/hooks/block-dangerous-git.sh <<< \
  '{"tool_name":"Bash","cwd":"/tmp/example","tool_input":{"command":"git reset --hard"}}'

# Should print nothing (no run active):
${CLAUDE_PLUGIN_ROOT}/overnight/hooks/block-dangerous-git.sh <<< \
  '{"tool_name":"Bash","cwd":"/tmp/example","tool_input":{"command":"git reset --hard"}}'
```

If the first prints nothing, `jq` is likely missing — check below and say so
rather than continuing.

The runner also needs `jq` and an authenticated `gh`, since it parses JSON and
opens pull requests. Check both now rather than letting the first night fail on
them:

```bash
command -v jq >/dev/null && echo "jq ok" || echo "jq MISSING — brew install jq"
gh auth status >/dev/null 2>&1 && echo "gh ok" || echo "gh NOT AUTHENTICATED — gh auth login"
```

## Step 6: List the files a worktree will need

The runner builds in a **git worktree**, which is a fresh checkout — gitignored
files are not in it. If the build or tests need `.env`, local config, or
credentials, they will be absent and the run will fail at 3am for a reason that
has nothing to do with the code.

If Step 3 turned up any such files, write a `.worktreeinclude` at the repo root
listing them. It uses `.gitignore` syntax, and only files that match *and* are
gitignored are copied:

```text
.env
.env.local
config/secrets.json
```

`loop.sh` reads this file and copies those paths into each worktree it creates.

Do not create the file if nothing needs it — an empty one is noise. Say in your
report either what you listed, or that nothing gitignored is needed.

## Step 7: Seed the first queue

The runner reads its work from `overnight/<date>/QUEUE.md` and refuses to start
without one. Create a template so the first night does not fail on a missing
file:

```bash
mkdir -p "overnight/$(date +%Y-%m-%d)"
```

Write `overnight/<today>/QUEUE.md`:

```markdown
# Queue

One unchecked item per spec. Each slug must match a directory under `specs/`.
The runner marks each `[x]` when it ships and `[!]` when it blocks or is skipped.

- [ ] example-slug
```

List any existing `specs/*/` directories you find as unchecked items, so the
queue starts populated rather than empty. If there are none yet, leave the
example line and say in your report that specs come first — `/discovery`,
`/prototype`, `/spec`.

## Step 8: Gitignore

Add if absent:

```
overnight/*/logs/
```

Run state under `overnight/<date>/` is otherwise **kept deliberately** —
`RUN.md` is the durable record of what ran, what passed, what blocked, and which
pull requests opened. Only the verbose logs are ignored.

## Step 9: Commit

```bash
git add CLAUDE.md .gitignore overnight/
# plus .worktreeinclude if you created one
git commit -m "Set up overnight runs"
```

**Committing is required, not tidiness.** `loop.sh` refuses to start on a dirty
working tree, so uncommitted setup blocks the first run. A worktree is also a
checkout — only committed files travel into it, so `CLAUDE.md` must be committed
for the runner to find the build commands once it is working in a worktree.

Do not push. Do not create a branch. If the repo is on `main` with a clean tree,
committing there is correct — this is setup, not spec work.

## Step 10: Report

End with a short report covering:

**Project** — type detected, and any secondary project noted but not set up.

**Commands** — the four, each with what you observed: passed, how long, test
count. State plainly which were verified by running them and which were not.

**Choices made** — where several candidates existed, what you picked and what
you passed over. This is what lets the user correct a wrong pick at a glance.

**Concerns** — an empty-looking suite, tests needing a service or network, files
a fresh worktree will lack, a build too slow for a three-attempt fix cycle.
Say these plainly; they are what breaks a run at 3am.

**Files a worktree will need** — `.env` and similar, for the runner's copy list.

**Then the two manual steps**, which need the user's own eyes and cannot be done
from here:

1. **Run `/hooks`** and confirm the guardrail is listed. It comes from the
   plugin, so it should be there in any session — if it is not, the plugin is
   not loading.
2. **Run the hook's own test suite**, once per machine:

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/overnight/hooks/test-hook.sh
   ```

   61 cases: destructive commands blocked, legitimate ones allowed, and the
   whole thing inert with no run active. Expect `61 passed, 0 failed`.

   Note the hook will *not* refuse anything you ask Claude to do right now —
   that is by design. It only guards while `loop.sh` has a run in progress.

Also mention, if `gh auth status` shows unauthenticated, that the runner opens
pull requests and needs `gh` logged in.

## What this skill deliberately does not do

- **Does not push, branch, or merge.** Setup only.
- **Does not modify the plugin.** The canonical hook lives in the plugin; this
  copies it in.
- **Does not judge whether the test suite is meaningful.** It can see exit codes
  and output, not coverage. It reports what it observed and flags what looks
  thin; the user decides.
