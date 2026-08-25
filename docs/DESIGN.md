# Overnight Workflow — Design Notes

**Status:** all components built; end-to-end run on a real spec still pending.
**Last updated:** 2026-08-25

This document is the reasoning behind the design — why it is shaped the way it
is, what was tried, and what has actually been verified. A fresh session should
be able to read it top to bottom and continue the work without re-deriving
anything.

For installation and day-to-day use, see the [README](../README.md).

---

## 1. What we are building and why

You drive discovery, prototyping, and spec-writing yourself — those need human
judgement, and they are the parts worth being present for. Once the specs are
good, you hand the machine a queue of them and go to sleep. By morning you want
working branches, open pull requests, and **one artifact** you can read over
coffee that explains what was built.

The full workflow is seven steps. You own the first three; the overnight runner
owns the rest:

```
/discovery → /prototype → /spec  │  /implement-spec → /qa + /local-code-review → /finish
       you, awake, engaged      │        the runner, unattended, overnight
```

The problem with running this unattended today is that `/qa` and
`/local-code-review` **report but nobody acts**. A failure at 2am is just text
nobody reads until morning. The runner has to consume those verdicts and act on
them.

### Non-negotiables

- **Never touch `main`.** No pushes, no merges, no history rewriting. The runner
  opens a pull request and stops; you merge.
- **Never use API credits.** Subscription budget only. `ANTHROPIC_API_KEY` is
  unset in the runner's environment so the fallback is structurally unreachable.
- **Stop before the 5-hour window is spent**, not after.
- **Auto mode, not `--dangerously-skip-permissions`.** Running unsandboxed with
  permissions off is not the trade being made here. Guardrails come from hooks
  instead.
- **Your own checkout is never disturbed.** The runner works in a separate git
  worktree on a separate branch.

---

## 2. Where the research came from

Worth keeping because it explains *why* the design is shaped this way, and a
fresh session should not have to re-search it.

### The Ralph loop (the real source)

Geoffrey Huntley, <https://ghuntley.com/ralph/> and
<https://github.com/ghuntley/how-to-ralph-wiggum>. The entire technique is:

```bash
while :; do cat PROMPT.md | claude ; done
```

A **fresh `claude` process every iteration**. State lives in files that get
re-read each loop, not in the conversation.

His rules, quoted:

- *"Only one thing per loop"* — and trust the agent to pick which.
- *"Before making changes search codebase (don't assume not implemented) using
  subagents."*
- *"You may use up to 500 parallel subagents for all operations but only 1
  subagent for build/tests."*
- *"The more you use the context window, the worse the outcomes you'll get."*
- Context math: 200K advertised ≈ 176K usable; target **40–60% utilization**
  ("smart zone"). One tight task per loop keeps you there.
- Philosophy: *"sit on the loop, not in it"*, and *"the plan is disposable"*.

Named failure modes: false negatives from ripgrep, placeholder implementations
(*"DO NOT IMPLEMENT PLACEHOLDER OR SIMPLE IMPLEMENTATIONS"*), context
exhaustion, and occasionally a broken tree needing `git reset --hard` — which is
**your escape hatch, not the runner's**, hence the hook blocking it.

### Why a loop at all, given a 1M context window

A fair question. The answer: the loop is not for context *capacity*, it
is for **re-anchoring**. The community consensus is that fresh context is the
feature, not a workaround — *"throwing the session away and rebuilding state
from disk kills context rot on long runs."* Iteration N+1 reads the plan from
disk rather than from a window polluted by N's failed attempts. Anthropic's own
long-context guidance says agents must re-anchor to sources of truth to prevent
drift.

Notably the community criticises Anthropic's own Ralph Loop *plugin* for
re-feeding the prompt inside one growing session — it never re-anchors.

### Backpressure — the core concept

A plumbing term: pressure pushing *back* against the flow.

Left alone, a model wants to move forward — write code, say "done", move on.
**Backpressure is anything that can say "no, you're not done" and force it
back.** Tests failing. Typecheck failing. Lint failing. QA marking a criterion
Fail.

Without it, an unattended run flows forward all night saying *done, done, done*
and you wake to eight specs marked complete, four of them broken.

This is why documenting the project's test command is build step 1: **no test
command means no wall, which means no safe overnight run.**

Ralph also uses "non-deterministic backpressure" — an LLM judging pass/fail for
things tests cannot measure. `/qa` and `/local-code-review` are exactly that.

### Worktrees — why plain `git worktree`, not `claude --worktree`

Running Claude *inside* a worktree hits walls. Confirmed cause, from
<https://code.claude.com/docs/en/worktrees>: when Claude Code is *isolated* in a
worktree it enforces four checks on every tool call — blocking edits to the main
checkout, blocking commands whose cwd it cannot verify, blocking git redirects,
and a **"command shape"** check that refuses any Bash it cannot trace without
running, *explicitly including "brace expansion and heredocs with unquoted
delimiters."* The docs say: *"You can't turn this check off."*

That last one is the wall. Ordinary shell gets refused on shape alone.

**The escape:** create the worktree with plain `git worktree add`, then `cd`
there and launch a fresh `claude` whose cwd simply *is* the worktree. That
session is not "isolated" — it is a normal session in a normal directory. No
shape refusals. Isolation is still real, but it is *git's* (separate directory,
separate branch), enforced by the filesystem rather than by tool interception.

Two further reasons: `git worktree add` can place the worktree **outside** the
repo (Claude's always uses `.claude/worktrees/<name>/`), and non-interactive
`-p` runs **never clean up their worktrees** and leave a lock behind — leaked
state every iteration.

Caveat: a worktree is a fresh checkout, so `.env` and dependencies are absent.
`.worktreeinclude` only works for Claude-created worktrees, so `loop.sh` copies
those files in itself.

### Hooks — why they are the enforcement layer

From <https://code.claude.com/docs/en/hooks>:

- A `PreToolUse` hook **works even in bypassPermissions mode**. It is real
  enforcement, not instruction — it cannot drift at hour six.
- Hooks **merge across settings scopes** (user + project + local all run);
  they do not override each other.
- **All matching hooks run in parallel, and any deny wins.** Layering is
  therefore safe: more hooks can only ever be more restrictive.
- Exit 2 blocks. Alternatively exit 0 with
  `{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"..."}}`
  — preferred, because the reason reaches Claude as a tool error it can act on.
- Input JSON includes `cwd`, `tool_name`, `tool_input`.
- **Project hooks require workspace trust.** An untrusted repo registers nothing,
  silently.

### Budget — usage is machine-readable

No `claude usage` subcommand exists; the docs only mention interactive `/usage`.
**But** every assistant turn in `~/.claude/projects/*/*.jsonl` carries a
timestamped, per-model usage record (`input_tokens`, `output_tokens`,
`cache_read_input_tokens`, `cache_creation_input_tokens`). Verified directly on
this machine. Summing the trailing 5 hours across all projects gives a real
burn-rate number.

### AGENTS.md vs CLAUDE.md

An early draft of this design said `AGENTS.md`, copying Ralph. **That was wrong**
— `AGENTS.md` is the cross-tool standard Ralph uses because his loop is
agent-agnostic. **Claude Code reads `CLAUDE.md`.** Use `CLAUDE.md`; it is loaded
automatically, which is better anyway.

---

## 3. The two-place rule

The single most important thing to keep straight:

> **The plugin is the tooling. The target repo gets only what must travel into
> worktrees.**

### The plugin — the installed plugin directory

Built once. Never copied into projects wholesale. `${CLAUDE_PLUGIN_ROOT}`
resolves to it from any session, whatever the install location.

```
README.md                       ← install and usage
docs/DESIGN.md                  ← this document
.claude-plugin/plugin.json
.claude-plugin/marketplace.json
skills/
  discovery/SKILL.md            ← pre-existing, unchanged
  prototype/SKILL.md            ← pre-existing, unchanged
  spec/SKILL.md                 ← pre-existing, unchanged
  pitch/SKILL.md                ← unchanged
  implement-spec/SKILL.md       ← unchanged
  qa/SKILL.md                   ← DONE: emits QA-VERDICT block
  local-code-review/SKILL.md    ← DONE: emits REVIEW-BUGS block
  finish/SKILL.md               ← unchanged
  overnight-init/SKILL.md       ← DONE: per-repo setup, run once per project
  overnight/SKILL.md            ← DONE: THE ENTRY POINT — the only one to type
  overnight-report/SKILL.md     ← DONE: publishes the morning artifact
hooks/
  hooks.json                    ← registers the guardrail plugin-wide
overnight/
  hooks/
    block-dangerous-git.sh      ← the guardrail itself
    test-hook.sh                ← 61 cases
    README.md                   ← how the gate works
  loop.sh                       ← invoked by /overnight; one process per PHASE
  render-stream.py              ← stream-json → readable live feed
  extract-result.py             ← final text out of a stream, for parsing
  budget.sh                     ← invoked by loop.sh; trailing-5h usage
```

### The target repo — per project

**Nothing is copied in.** The plugin ships the hook and registers it via
`hooks/hooks.json`, so it is active in every session the plugin loads in —
no file in the repo, no settings to edit.

What the repo needs is only what describes *itself*:

```
<repo>/CLAUDE.md                              ← the ## Build & Validation block
<repo>/.worktreeinclude                       ← gitignored files a worktree needs
<repo>/specs/<slug>/SPEC.md                   ← you write these
```

Everything else the runner needs, it generates at runtime:

```
<repo>/specs/<slug>/SPEC.md                   ← you write these
<repo>/specs/<slug>/implementation-notes.md   ← the runner maintains
<repo>/overnight/<date>/
    QUEUE.md          ← specs to run, with status
    RUN.md            ← what happened; the durable record
    suggestions.md    ← non-blocking review notes, for later
    logs/<slug>.log
```

Worktrees live at `../wt-<slug>` — **outside** the repo, created with plain
`git worktree add`.

---

## 4. Every file, and what it is for

### Done

**`overnight/hooks/block-dangerous-git.sh`** (199 lines, executable)

*Goal: make the non-negotiables physically impossible rather than merely
instructed, so they cannot drift over a long unattended run.*

Reads a `PreToolUse` payload on stdin, decides, and always exits 0 — the block
is carried by `permissionDecision: "deny"` in the JSON it prints. Configured by
environment so one copy serves every repo:

- `OVERNIGHT_WORKTREE` — absolute path the session is confined to; when unset
  the working-directory check is skipped
- `OVERNIGHT_BRANCHES` — extra protected branch names, space-separated

Five layers, backstop first:

1. **Worktree confinement** — `cwd` must be under `$OVERNIGHT_WORKTREE`,
   canonicalized so symlinks and `..` cannot slip past. Also blocks `git -C`,
   `--git-dir`, `--work-tree`, `GIT_DIR`, `GIT_WORK_TREE`. *This is the backstop:
   a destructive command that evades every regex below still cannot reach the
   main checkout from here.*
2. **Push safety** — protected branches, every force spelling (`--force`, `-f`,
   `--force-with-lease`, `--force-if-includes`, and the `+HEAD:branch` refspec),
   remote-branch deletion, and bare `git push` (which follows `push.default` and
   can land somewhere unintended).
3. **Destroying uncommitted work** — `reset --hard`, bare `reset`, `clean -f*`,
   `checkout .`, `restore .`, `stash drop`.
4. **History rewriting** — rebase, `--amend`, `filter-branch`, `branch -D`,
   `tag -d`, reflog expiry.
5. **Leaving the worktree** — switching to a protected branch,
   `git worktree remove`, and `git merge`.

Two deliberate design calls:

- **Path-scoped operations stay allowed.** `git reset -- file.swift` and
  `git checkout -- file.swift` pass, because that is how a legitimate fix cycle
  backs out one file at 3am. Only the unscoped, whole-tree forms are blocked. A
  hook that blocks everything fails differently, not better.
- **Every deny says what to do instead.** Claude reads
  `permissionDecisionReason` as a tool error and decides its next move from it,
  so `reset --hard` returns *"To undo one file use `git checkout -- <file>`; if
  the tree is genuinely broken, mark the spec BLOCKED and stop."* That steers it
  back on track instead of leaving it guessing — which matters enormously when
  nobody is watching.

**`overnight/hooks/test-hook.sh`** (executable, 61 assertions)

*Goal: prove the hook's logic in one second without starting a session, so the
patterns can be edited fearlessly.*

Two tables. **MUST BLOCK** (35 cases) proves destructive commands are caught,
including evasion attempts — quote evasion, extra whitespace, chaining after
`&&`. **MUST ALLOW** (19 cases) proves the runner is not strangled at 2am by a
legitimate `git push -u origin spec/foo`, a path-scoped reset, or `swift test`.
*The allow table matters as much as the block table.*

Run it after every edit to the patterns:

```bash
"$CLAUDE_PLUGIN_ROOT"/overnight/hooks/test-hook.sh
```

Currently **61 passed, 0 failed**. It has already earned its keep: it caught
`git -C /path status` slipping through a pattern that required `.*` between
`git` and `-C`.

**`hooks/hooks.json`** (plugin root)

*Goal: ship the guardrail with the plugin, so no repository has to install it.*

Registers `block-dangerous-git.sh` as a `PreToolUse` hook for every session the
plugin loads in, referencing it through `${CLAUDE_PLUGIN_ROOT}` — which resolves
to the plugin directory regardless of the session's working directory, so the
hook is equally reachable from a worktree as from the main checkout.

**`overnight/hooks/README.md`**

*Goal: explain the gate, since "a guardrail that does nothing right now" is
surprising until you know why.*

### To build

### Done — the verdict contract

**`skills/qa/SKILL.md`** and **`skills/local-code-review/SKILL.md`**

*Goal: make the verdicts machine-readable so the loop can branch on them.*

Both already had `context: fork` in frontmatter — **that is the fresh-context
boundary, and it was already present.** Both keep their prose output for the
artifact; each now ends with a fixed block the runner parses.

`/qa` emits:

```
QA-VERDICT: PASS|FAIL
QA-CRITERIA: <n> passed, <n> failed
QA-FAILED: <criterion> — <what was observed>     (one per failure)
QA-CONCERN: <deviation that could bite>          (optional, doesn't change verdict)
```

`PASS` only when every criterion passed — anything unverifiable is a Fail, so
there is no "PASS with a caveat in prose".

`/local-code-review` emits:

```
REVIEW-BUGS: <n>
REVIEW-BUG: <file>:<line> — <what's wrong>       (one per bug)
REVIEW-SUGGESTIONS: <n>
```

**The bugs/suggestions split is the triage boundary**, and it already existed in
the skill — the block just makes it parseable. Overnight, bugs block and
suggestions don't: a bug sends the work back for another fix attempt, while
suggestions are filed to `suggestions.md` and the code is left alone. So which
line a finding lands on decides whether code changes at 3am with nobody
watching. Both skills say this explicitly, so an uncertain finding goes to
Suggestions rather than burning a fix attempt on a nitpick.

`QA-FAILED:` and `REVIEW-BUG:` lines are what the next fix attempt works from,
so both skills require them to be specific enough to act on without re-deriving
the review.

**`skills/overnight/SKILL.md`** — *the entry point* — **DONE**

*Goal: the only overnight command anyone types. Everything else is machinery it
drives.*

Resolves slugs against `specs/` (accepting unambiguous prefixes), checks the
repo is set up and runs `/overnight-init` itself if `CLAUDE.md` lacks its
validation block, writes and commits the queue, launches `loop.sh` in the
background, and points at `/overnight-report` for the morning.

It explicitly never runs the build phases itself and never creates a worktree by
hand — `loop.sh` owns both, and it is `loop.sh` that exports
`OVERNIGHT_WORKTREE`, which is what arms the guardrails. A worktree made by hand
would run unguarded.

**`overnight/loop.sh`** — *the outer loop* — **DONE**

*Goal: one fresh `claude` process per spec, so context never rots across specs.*

**Invoked by `/overnight`, never by hand.** Its signature, for reference when
debugging:

```bash
loop.sh <repo> [--queue <file>] [--max-specs <n>] [--budget <tokens>] [--dry-run]
```

The queue is a markdown checklist at `overnight/<date>/QUEUE.md`; unchecked
items are the work, and the loop marks each `[x]` shipped or `[!]` blocked as it
goes:

```markdown
- [ ] add-login
- [x] fix-header
```

**Preflight** — refuses to start on anything that would otherwise fail hours
later in the dark: not a git repo, no `## Build & Validation` block, missing or
non-executable hook, a dirty working tree, `gh` missing or unauthenticated, no
`jq`. Then `unset ANTHROPIC_API_KEY`, making the credits fallback unreachable
rather than merely discouraged.

**Per spec** — budget gate → `git worktree add ../wt-<slug> -b spec/<slug>` →
copy `.worktreeinclude` files by hand (that file only applies to worktrees
*Claude* creates) → export `OVERNIGHT_WORKTREE` so the hook confines to it →
run the phases → mark the queue → append to `RUN.md` → next spec starts cold.

**Specs run strictly one at a time.** The next worktree is not created until the
current spec finishes. The queue is a queue, not a fan-out.

**Each phase is its own `claude -p` process:**

```
/implement-spec <slug>
  ×3 attempts:
      tests    — run CLAUDE.md's commands, emit TESTS: PASS|FAIL
      /qa      — emits QA-VERDICT, QA-CRITERIA, QA-FAILED
      /local-code-review — emits REVIEW-BUGS, REVIEW-BUG, REVIEW-SUGGESTIONS
      triage   — tests/QA/bugs must-fix; suggestions filed, code untouched
      fix      — given the three outputs verbatim
  ship     — push branch, gh pr create, never merge
  or salvage — push the branch, no PR, write up why in RUN.md
```

Separate processes are the point, not an implementation detail. **QA and review
are only worth anything with genuinely fresh context** — a session that just
wrote the code is the least reliable judge of it. Separate processes make "fresh
eyes" literal rather than aspirational. (It is also forced: the skills carry
`disable-model-invocation`, so one session cannot call them as tools at all.)

**A missing verdict is treated as BLOCKED.** A killed or crashed process leaves
no `SPEC-RESULT:` line, and the one thing worse than a blocked spec is a spec
quietly recorded as done when nobody knows what happened.

Worktrees are deliberately left in place — they hold the branches under review.

**`overnight/budget.sh`** — *the budget gate* — **DONE**

*Goal: stop before the window is spent, not after.*

Called by `loop.sh` between specs. Also runnable by hand when you want to see
where the window stands:

```bash
"$CLAUDE_PLUGIN_ROOT"/overnight/budget.sh
```

Sums `input_tokens + output_tokens + cache_creation_input_tokens` from every
`~/.claude/projects/*/*.jsonl` record inside the trailing five hours. **Cache
*reads* are deliberately excluded** — they are billed differently, and counting
them would wildly overstate a long session where the same cached prefix is
re-read every turn. Burn rate is computed over the *observed* span, not the
nominal window, so five minutes of heavy use doesn't read as a low hourly rate.

Honest about what it is: a burn estimate from local session history, not an
authoritative balance. It cannot see other machines or claude.ai, and Anthropic
publishes no token ceiling per plan — so it reports consumption and lets the
caller apply a threshold rather than inventing a "percentage remaining".

**`overnight/budget.sh`** — *the budget gate*

*Goal: stop before the window is spent, not after.*

Sums trailing-5h token usage from `~/.claude/projects/*/*.jsonl` across all
projects. Called **between specs only** — the only point where stopping is free.
Reserves a floor so the artifact can still be written. Also handles the
short-spec case: if the window is nearly spent, park rather than start something
that will die halfway.

**`skills/overnight-report/SKILL.md`** — *the morning artifact* — **DONE**

*Goal: the thing the user actually wakes up to. The code is on branches they
have not read, in pull requests they have not opened; the page is how they find
out what happened.*

Reads `overnight/<date>/` — `RUN.md` for the spine, `logs/<slug>.log` for the
prose each spec wrote for the morning, `suggestions.md`, the specs, and the diff
for anything shipped.

Structure: header with the shape of the night → **what to do first** (the
actions waiting, ordered) → one section per spec, shipped then blocked then
skipped → suggestions → run detail at the bottom.

Written *for someone who was asleep*: lead with what they need to decide, not
chronology; explain the reasoning rather than the syntax, since the diff already
carries the syntax; and give a blocked spec the same care as a shipped one —
it is often the most valuable section, because it is the one that needs them.

Publishes to a stable title (`Overnight <date>`) and saves the HTML to
`overnight/<date>/report.html` so it can be republished without rebuilding, then
appends the artifact URL to `RUN.md`. If the run produced nothing, it says so in
two sentences and **does not publish** — an empty artifact costs a click to
discover it was empty.

---

## 5. The loop

**Outer — `loop.sh`, one fresh process per spec:**

```
for each unfinished spec in QUEUE.md:
    budget check ──────── stop cleanly if the 5h window is nearly spent
    git worktree add ../wt-<slug> -b spec/<slug>     # plain git, outside repo
    copy .env and friends into it
    cd ../wt-<slug> && claude -p <inner loop>        # cwd IS the worktree
    push branch, open PR
    append this spec's section to the artifact, republish
    mark done / BLOCKED in QUEUE.md
    exit ──────────────── context evaporates; next spec starts cold
```

**Inner — inside that one session, per spec:**

```
/implement-spec <slug>

attempt 1..3:
    /qa <slug>                  ← context: fork, fresh eyes
    /local-code-review          ← context: fork
    triage:
        QA Fail      → must fix
        Bugs         → must fix
        tests failing→ must fix
        Suggestions  → suggestions.md, code untouched
    nothing must-fix? → break
    otherwise: fix, re-run tests, next attempt

3 strikes → mark BLOCKED, record why, move on. Do not grind.
/finish <slug> → artifact section
```

Ralph's *"one task per loop"* maps to **one spec per outer iteration** — that is
what keeps each session in the 40–60% smart zone.

**Why 3 attempts:** three failures means it is genuinely stuck, and a fresh
context is unlikely to rescue it. Better a clean BLOCKED report in the morning
than a burned window grinding.

### The artifact

One per night, sections per spec, PR links inside — read with coffee.

**Written incrementally**, appending each spec's section as it finishes and
republishing to the same URL. That way a hard stop mid-night still leaves a
complete artifact for everything that did finish. `budget.sh` also reserves a
floor so there is always enough window left to write it.

Artifacts are **not** disposable — publishing gives a durable URL, reopenable
from `/artifacts`, and republishing the same file updates the same link. So the
HTML does not need saving to the repo. What *is* worth committing is `RUN.md`:
what ran, what passed, what blocked, which PRs opened, and the artifact URL.
That is real project history.

---

## 6. Installation guide

### One-time, per machine

Install the plugin (see the [README](../README.md)), then verify the hook logic:

```bash
"$CLAUDE_PLUGIN_ROOT"/overnight/hooks/test-hook.sh
# expect: 61 passed, 0 failed
```

### Per target repo

Run **`/overnight-init`** inside the repository. One pass, ten steps, idempotent
— running it again is the right way to re-verify a repo whose build commands
have changed.

What it does, so you know what to check in its report:

1. **Detects the project** and reads what the repo actually declares — scripts
   in `package.json`, Xcode schemes, `Makefile` targets, CI workflows. CI is
   often the most reliable statement of how a project is really built.
2. **Picks commands and reports the choice.** Where several candidates exist it
   takes the most likely and names what it passed over, rather than asking — so
   setup stays a single non-interactive step. A wrong pick is visible in the
   report and trivially corrected.
3. **Verifies each by running it.** The step that matters: the runner trusts
   these commands completely, so a subtly wrong one is worse than none. It also
   flags a suite that passes with **zero tests** — that exits 0 happily and would
   never block anything.
4. **Writes the `## Build & Validation` block** into `CLAUDE.md`, merging rather
   than clobbering.
5. **Checks the guardrail and the tooling** — the plugin already ships the
   hook, so there is nothing to install; it probes that the hook denies, and
   confirms `jq` and `gh auth`.
6. **Lists what a worktree will need** — `.env` and friends, into
   `.worktreeinclude`. A worktree is a fresh checkout, so gitignored files are
   absent; `loop.sh` reads this file and copies them in.
7. **Seeds `overnight/<today>/QUEUE.md`**, populated from any existing `specs/*/`
   directories. `loop.sh` refuses to start without a queue.
8. **Adds `overnight/*/logs/` to `.gitignore`.** The rest of `overnight/<date>/`
   is kept deliberately — `RUN.md` is the durable record.
9. **Commits everything.** Required, not tidiness: `loop.sh` refuses to start
   on a dirty tree, and a worktree is a checkout — `CLAUDE.md` must be committed
   for the runner to find the build commands once it is working in one.
10. **Reports** — commands verified, choices made, concerns, and the two manual
    steps below.

**Then two manual steps it cannot do for you:**

- **Run `/hooks`** and confirm the guardrail is listed. It comes from the
  plugin, so it should appear in any session — if it does not, the plugin is not
  loading.
- **Run the hook's test suite**, once per machine:

  ```bash
  "$CLAUDE_PLUGIN_ROOT"/overnight/hooks/test-hook.sh   # expect 61 passed
  ```

  Note the hook will not refuse anything you ask Claude to do right now. That is
  by design — see the gate below.

### Manual fallback

If detection fails or you would rather do it by hand:

**1. Document the commands in `CLAUDE.md`** at the repo root:

```markdown
## Build & Validation

- Build:     xcodebuild -scheme App build
- Tests:     xcodebuild test -scheme App
- Typecheck: covered by build
- Lint:      swiftlint
```

Run each by hand first and confirm it passes on a clean checkout.

**2. List anything gitignored the build needs** in `.worktreeinclude` at the
repo root (`.env`, local config). A worktree is a fresh checkout, so these are
absent unless `loop.sh` copies them in. Skip the file if nothing is needed.

**3. Seed the queue** at `overnight/<today>/QUEUE.md` — `loop.sh` refuses to
start without one:

```markdown
- [ ] your-first-spec
```

**4. Add `overnight/*/logs/` to `.gitignore`, then commit** `CLAUDE.md`, the
queue, and `.worktreeinclude` if you made one. Preflight refuses a dirty tree,
so uncommitted setup blocks the first run.

**5. Check `jq` is installed and `gh auth status` is authenticated.**

**6.** The same two checks as above: `/hooks`, then `test-hook.sh`.

### Per night

**One command, in the repo:**

```
/overnight 002 003
```

Slugs are optional (empty runs whatever the queue holds) and may be
abbreviations — `002` resolves to `002-swiftui-snapshot-engine` when only one
spec starts that way. Ambiguous prefixes stop rather than guess.

`/overnight` does everything else: resolves the slugs against `specs/`, checks
`CLAUDE.md` has its `## Build & Validation` block (running `/overnight-init` if
not), verifies `jq` and `gh`, writes and commits `overnight/<today>/QUEUE.md`,
then launches `loop.sh` in the background.

**In the morning:**

```
/overnight-report <date>
```

One artifact covering the night — what shipped, what blocked, what needs a
decision, with the pull request links. Then review the pull requests, skim
`suggestions.md`, and clean up merged worktrees with
`git worktree remove ../wt-<slug>`.

That is the whole interface. `/overnight` and `/overnight-report` are the only
two commands to type — everything below the line is machinery they drive.

**Nobody runs `loop.sh` by hand**, creates a worktree by hand, or exports
`OVERNIGHT_WORKTREE` by hand. `/overnight` invokes the script; the script
creates the worktrees and exports the variable. A worktree made by hand would
run with the guardrails disarmed, because it is `loop.sh` that sets the variable
they gate on. The script's flags (`--dry-run`, `--max-specs`, `--budget`) are
things `/overnight` passes when you ask for them in words — "just show me what
it would do", "only the first two", "keep it short tonight".

---

## 7. Build order

Each step is verifiable before the next depends on it. Stopping after any step
still leaves things better than before.

- [x] **1. Guardrail hook** — `block-dangerous-git.sh`, `test-hook.sh`,
      **61/61 passing**, gated on an active run.
      *(Done first because it is verifiable standalone, before anything depends
      on it.)*
- [x] **2. `/overnight-init` skill** — per-repo setup: detect the project,
      verify its commands, write `CLAUDE.md`, install and wire the hook, commit.
      Plug-and-play into any folder.
      *(Everything downstream needs this — no test command, no backpressure.)*
- [x] **3. `/qa` + `/local-code-review` verdict lines.** Both now emit a fixed
      machine-readable block after their prose. Contract in section 4.
- [x] **4. `/overnight`.** The entry point — resolves slugs, checks setup,
      writes the queue, launches the loop. The per-spec work is orchestrated by
      `loop.sh` as separate phases, not by a single inner skill.
- [x] **5. `loop.sh` + `budget.sh`.** Outer loop and the budget gate. Verified
      end to end against a scratch repo — worktree created, verdict parsed,
      queue marked, `RUN.md` written.
- [x] **6b. `/overnight-report`** — publishes the morning artifact from
      `overnight/<date>/`. Built after step 5, since `loop.sh` ends by pointing
      at it.
- [ ] **6. Dry run** on one small spec, awake, watching. *Everything else is
      built; this is the remaining step.*

---

## 8. Testing strategy

Three levels, cheapest first. Level 1 is the daily driver; 2 and 3 are one-time
wiring checks.

**Level 1 — the script alone, no Claude involved.**
`test-hook.sh`. One second, 61 cases, catches essentially everything. Run after
every pattern edit. **Currently 61/61.**

**Level 2 — confirm Claude loaded it.**
`/hooks` in a session. Must list the entry and its source. Catches the classic
failure: correct script, wrong path or untrusted workspace, failing silently.

**Level 3 — live refusal.**
Scratch repo, ask Claude to do the forbidden thing, watch it refuse. Tests the
*wiring* rather than the logic. With no remote configured, push tests fail for
the wrong reason — use `reset --hard`, `clean -fd`, `checkout .`, or
`branch -D`, which all test cleanly without one.

### What has actually been executed

Stated plainly, because "built" and "verified" are different claims:

| Component | Status |
|---|---|
| `test-hook.sh` | **Run, 61/61 passing** |
| `budget.sh` | **Run against real transcript data** |
| `loop.sh --dry-run` | **Run** |
| `loop.sh` real | **Run** on a scratch repo — worktree created, verdict parsed, queue marked, `RUN.md` written. The spec was deliberately unbuildable, so it stopped at the first gate. |
| `/overnight-init` | **Never run** |
| `/overnight` on a real spec | **Never run** |
| `/overnight-report` | **Never run** |
| Hook listed in `/hooks` | **Never verified** |
| Hook refusing live | **Never verified** |

So: the plumbing is verified — scripts run, verdicts parse, worktrees create,
queue marks. What is unverified is a real spec going implement → qa → review →
fix → pull request on actual code. That is build step 6, and it needs a real
repository.

### The gate: the hook only fires during a run

The first thing `block-dangerous-git.sh` checks is `OVERNIGHT_WORKTREE`.
`loop.sh` exports it for the duration of one spec and nothing else sets it, so
its presence is what distinguishes "a run is happening" from "someone is
working normally". Outside a run the hook exits immediately and allows
everything.

This is deliberate. The rules exist because nobody is watching. Applied to
ordinary daytime work they would block legitimate things — rebasing, amending a
commit, resetting a botched experiment — that you are perfectly capable of
supervising yourself. **A guardrail that fires when it is not needed teaches
people to work around it, which is how it comes to be ignored when it does
matter.**

The practical consequence: asking Claude to `git reset --hard` right now will
work. That is not the hook being broken. To see it deny, set the variable by
hand, or read the GATE table in `test-hook.sh`.

### The honest limit

Pattern-matching shell is defeatable in principle — `git p"u"sh`, a variable, a
wrapper script. Not because Claude is adversarial, but because shell has many
spellings for the same thing.

This is why the design does not lean on the hook alone. The `cwd` check, the
worktree being a separate directory, `ANTHROPIC_API_KEY` unset, and the branch
never being `main` in the first place are each independent. **The hook is the
loudest layer, not the only one.**

### What the hook does and does not affect

- It intercepts **Claude's tool calls only**. You typing `git push origin main`
  in your own terminal is unaffected — it is not a git hook, not a git config,
  not a server rule.
- It is committed, so it is active in ordinary daytime sessions too. Intentional:
  Claude cannot `reset --hard` your work during the day either. To disable for
  one session, use `.claude/settings.local.json`.
- Overnight, Claude is **not in your checkout** — it is in `../wt-<slug>` on its
  own branch. Your working directory, branch, and uncommitted changes are
  untouched.

---

## 9. Decisions already settled — do not reopen

- One artifact **per night**, sections per spec, PR links inside. Written
  incrementally so a mid-night stop still leaves something complete.
- Must-fix = QA Fail, review Bugs, and any failing test. Suggestions go to
  `suggestions.md` and never touch code.
- Run state lives in `overnight/<date>/` inside the target repo.
- Worktrees via **plain `git worktree add`**, outside the repo — never
  `claude --worktree`.
- **Auto mode plus hooks.** Not `--dangerously-skip-permissions`, not sandboxing.
- **The guardrail ships with the plugin and is gated on `OVERNIGHT_WORKTREE`** —
  active during a run, inert otherwise. Nothing is installed per repository.
- Fresh process per spec; up to 3 fix attempts within a spec, then BLOCKED.
- It is **`CLAUDE.md`**, not `AGENTS.md`.

## Open questions

None. The design is settled; what remains is building steps 2–6.
