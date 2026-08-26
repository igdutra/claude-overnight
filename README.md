# claude-overnight

A Claude Code plugin for spec-driven development that runs while you sleep.

You do the thinking — scope the work, prototype directions, write the spec. Then
you hand the machine a queue of specs and go to bed. By morning: working
branches, open pull requests, and one page explaining what was built and what
needs your attention.

```
/discovery → /prototype → /spec  │  /implement-spec → /qa + /local-code-review → /finish
       you, awake, engaged       │        the runner, unattended, overnight
```

> **Status: work in progress, unreleased.** Everything is built and
> unit-verified, and the first real runs have produced feedback still being
> acted on. There is no tagged release yet, and `main` moves. If you install it,
> pin a commit and expect churn. See
> [Verified vs. unverified](#verified-vs-unverified).

---

## Why this exists

Running a coding agent unattended usually fails for one reason: **nothing tells
it "no."**

Left alone, a model wants to move forward — write code, say "done", move on. So
an unattended run flows forward all night saying *done, done, done*, and you
wake to eight specs marked complete, four of them broken.

The fix is **backpressure** — anything that can say *"no, you're not done"* and
force the work back. Failing tests. A typecheck error. A QA criterion marked
Fail. A code review that found a real bug.

This plugin's whole design is backpressure plus the guardrails that make it safe
to leave running:

- **QA and review run in separate processes with fresh context.** A session that
  just wrote the code is the least reliable judge of it. Here "fresh eyes" is
  literal, not aspirational.
- **Their verdicts are machine-readable**, so the runner can branch on them
  instead of printing text nobody reads at 2am.
- **Bugs block; suggestions don't.** A bug sends the work back for another fix
  attempt. A suggestion is filed for later and the code is left alone.
- **Silence is not consent.** A phase is green only if it *affirmatively said*
  so. Output that is missing, empty, or off-contract — a phase that died, was
  truncated, or hit a session limit — blocks. It never passes by default.
- **A claim is not evidence.** "I opened a pull request" is verified against
  `gh` before a spec is marked shipped, because a phase can report doing
  something without having done it.
- **Three fix attempts, then BLOCKED.** Better a clean blocked report in the
  morning than a burned window grinding on something genuinely stuck.
- **One unfinished spec stops the run.** The queue is ordered and later specs
  build on earlier ones; verifying 003 against a base that never got 002 tells
  you nothing.
- **A `PreToolUse` hook makes the dangerous things impossible**, not merely
  discouraged — enforcement that cannot drift at hour six.

## Credit where it's due

The seven-step workflow is a direct implementation of **[A field guide to Claude
Fable: finding your unknowns](https://claude.com/blog/a-field-guide-to-claude-fable-finding-your-unknowns)**
by Thariq Shihipar, which argues that *"the quality of the work is bottlenecked
by my ability to clarify its unknowns"* and that *"reducing and planning for your
unknowns is the skill of agentic coding."* Each skill here is one of its
practices made into a command:

| Field guide practice | Skill |
|---|---|
| Blind spot pass, interviews | `/discovery` |
| Prototyping multiple directions | `/prototype` |
| Implementation plans | `/spec` |
| Implementation notes | `/implement-spec` |
| Explainers and quizzes | `/finish` |
| Pitches | `/pitch` |

The overnight runner is what happens when you take those practices —
spec-driven development, essentially — and ask what it would take to run the
back half unattended.

The loop itself comes from **[Geoffrey Huntley's Ralph
technique](https://ghuntley.com/ralph/)** — a fresh agent process every
iteration, with state living in files that get re-read each loop rather than in
a conversation that slowly rots. His rules are quoted throughout
[`docs/DESIGN.md`](docs/DESIGN.md).

---

## Install

```
/plugin marketplace add igdutra/claude-overnight
/plugin install workflow@claude-overnight
```

Or clone and run it directly, without installing:

```bash
git clone https://github.com/igdutra/claude-overnight.git
claude --plugin-dir ./claude-overnight
```

### Working on the plugin itself

Symlink the clone into your skills directory. Claude Code loads it as a
skills-directory plugin, and every edit is live in the next session — no
reinstall, no version bump:

```bash
git clone https://github.com/igdutra/claude-overnight.git
ln -s "$PWD/claude-overnight" ~/.claude/skills/workflow
```

Do not also install it from the marketplace: the marketplace copy is a frozen
snapshot of a published version, and it takes precedence over the
skills-directory one, so your edits would stop taking effect.

### Requirements

- **Claude Code**, authenticated on a subscription plan
- **`git`** with worktree support
- **`gh`**, authenticated (`gh auth login`) — the runner opens pull requests
- **`jq`** — verdict parsing
- **`python3`** — stream rendering

The runner never uses API credits: it unsets `ANTHROPIC_API_KEY` before starting,
so the pay-per-token fallback is structurally unreachable rather than merely
discouraged.

### Verify the guardrail

```bash
"$CLAUDE_PLUGIN_ROOT"/overnight/hooks/test-hook.sh
# expect: 61 passed, 0 failed
```

61 cases: destructive commands blocked, legitimate ones allowed, and the whole
thing inert when no run is active. Then run `/hooks` in a session and confirm
the guardrail is listed — if it is not, the plugin is not loading.

---

## Use

### Once per repository

```
/overnight-init
```

Detects the project, **runs its build/test/lint commands to verify they work**,
writes them into `CLAUDE.md`, lists the gitignored files a worktree will need,
seeds the queue, and commits.

Verifying the commands is the step that matters: the runner trusts them
completely, so a subtly wrong command is worse than no command at all. Init also
flags a test suite that passes with zero tests — that exits 0 happily and would
never block anything.

**No test command means no backpressure, which means no safe overnight run.**

### Each night

```
/overnight 002 003
```

Slugs are optional (empty runs whatever is queued) and may be abbreviated —
`002` resolves to `002-swiftui-snapshot-engine` when only one spec starts that
way. Ambiguous prefixes stop rather than guess.

### Each morning

```
/overnight-report
```

One page covering the night: what shipped, what blocked, what needs a decision,
with pull request links. Written for someone who was asleep — it leads with what
you need to decide, not with chronology.

**Those are the only two commands you type.** Everything else is machinery they
drive. Nobody runs `loop.sh` by hand or creates a worktree by hand — a worktree
made manually would run with the guardrails disarmed.

---

## What it does to your repo

**Your checkout is never touched.** The runner works in a separate git worktree
at `../wt-<slug>`, on branch `spec/<slug>`, outside the repo. Your working
directory, your branch, and your uncommitted changes are untouched.

**It never touches `main`.** No pushes to it, no merges, no history rewriting.
The runner opens a pull request and stops. You merge.

Per spec, the inner loop is:

```
/implement-spec <slug>
  ×3 attempts:
      tests              → TESTS: PASS|FAIL
      /qa                → QA-VERDICT, QA-CRITERIA, QA-FAILED
      /local-code-review → REVIEW-BUGS, REVIEW-BUG, REVIEW-SUGGESTIONS
      triage: tests/QA/bugs must-fix; suggestions filed, code untouched
      fix, given all three outputs verbatim
  ship     → push branch, open PR, never merge
  or blocked → push the branch, no PR, write up why
```

A **missing verdict is treated as BLOCKED**. A crashed process leaves no result
line, and the one thing worse than a blocked spec is a spec quietly recorded as
done when nobody knows what happened.

It stops before the 5-hour window is spent rather than after, checking between
specs — the only point where stopping is free — and reserving enough budget to
still write the morning report.

## The guardrail

A `PreToolUse` hook ships with the plugin. It is **armed only during a run**,
gated on the `OVERNIGHT_WORKTREE` variable that `loop.sh` exports. Outside a run
it exits immediately and allows everything.

That is deliberate. These rules exist because nobody is watching. Applied to
ordinary daytime work they would block legitimate things — rebasing, amending,
resetting a botched experiment — that you are perfectly capable of supervising
yourself. **A guardrail that fires when it is not needed teaches people to work
around it, which is how it comes to be ignored when it does matter.**

When armed, five layers: worktree confinement, push safety, protecting
uncommitted work, blocking history rewriting, and blocking exits from the
worktree. Path-scoped operations stay allowed — `git checkout -- file.swift` is
how a legitimate fix cycle backs out one file at 3am. Every denial explains what
to do instead, because Claude reads that reason as a tool error and decides its
next move from it.

It intercepts **Claude's tool calls only**. You typing `git push origin main` in
your own terminal is unaffected — this is not a git hook, not a git config, not
a server rule.

## Verified vs. unverified

Stated plainly, because "built" and "verified" are different claims:

| Component | Status |
|---|---|
| `test-hook.sh` | **Run — 61/61 passing** |
| `budget.sh` | **Run against real transcript data** |
| `loop.sh --dry-run` | **Run** |
| `loop.sh` real | **Run** on a scratch repo — worktree created, verdict parsed, queue marked, `RUN.md` written |
| `/overnight-init` | Never run |
| `/overnight` on a real spec | Never run |
| `/overnight-report` | Never run |
| Hook listed in `/hooks` | Never verified |

The plumbing is verified: scripts run, verdicts parse, worktrees create, queues
mark. What is unverified is a real spec going implement → QA → review → fix →
pull request on actual code.

**Treat the first run as a supervised one.** Watch it.

## Layout

```
.claude-plugin/plugin.json       plugin manifest
.claude-plugin/marketplace.json  self-hosting, so this repo installs itself
hooks/hooks.json                 registers the guardrail
skills/                          the 11 skills
overnight/
  loop.sh                        the outer loop — one process per spec
  budget.sh                      trailing-5h usage, the stop gate
  spec-state.sh                  a spec's real state, from git and gh
  render-stream.py               stream-json → readable live feed
  extract-result.py              final text + phase health out of a stream
  hooks/block-dangerous-git.sh   the guardrail
  hooks/test-hook.sh             61 assertions
docs/DESIGN.md                   why it is shaped this way
```

## Documentation

- **[`docs/DESIGN.md`](docs/DESIGN.md)** — the full design: research provenance,
  why plain `git worktree` instead of `claude --worktree`, why a loop given a 1M
  context window, the verdict contracts, and an honest account of the limits.
- **[`overnight/hooks/README.md`](overnight/hooks/README.md)** — how the gate works.

## License

MIT — see [LICENSE](LICENSE).
