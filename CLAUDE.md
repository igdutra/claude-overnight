# claude-overnight

**Scope: this file describes the plugin repo itself.** It is read only by a
session working *on* the plugin. It never travels into a target repo, is never
read by a run, and nothing in it applies to the projects the runner operates on.

Do not add build/test/lint commands for other projects here. Those belong in the
`## Build & Validation` block that `/overnight-init` writes into each target
repo's own `CLAUDE.md`. Keeping the two apart is the two-place rule —
`docs/DESIGN.md` §3.

## What

A Claude Code plugin for spec-driven development that runs unattended. Two
halves: the daytime workflow skills (`/discovery` → `/prototype` → `/spec`), and
the overnight runner that takes a queue of specs to pull requests while nobody
is watching.

Bash, Python 3, and markdown. No build step, no dependency manifest, no compile.

## Structure

- `skills/` — 11 skills, one directory each. `/overnight` is the entry point.
- `overnight/loop.sh` — the outer loop; one `claude -p` process per phase.
- `overnight/budget.sh` — trailing-5h usage, the stop gate.
- `overnight/spec-state.sh` — a spec's real state, from `git` and `gh`.
- `overnight/extract-result.py` — final text and phase health out of a stream.
- `overnight/render-stream.py` — stream-json to a readable live feed.
- `overnight/hooks/block-dangerous-git.sh` — the `PreToolUse` guardrail.
- `docs/DESIGN.md` — the full design and its rationale. Long; read sections.

## How

Verify the guardrail after any change to it:

```bash
overnight/hooks/test-hook.sh     # expect: 61 passed, 0 failed
```

Exercise the loop without spending budget or touching a repo:

```bash
overnight/loop.sh --dry-run
```

There is nothing else to run. No test suite covers the skills — they are
markdown, verified by running them.

## Important

`docs/DESIGN.md` is the reference, not background reading. Before you start,
read the section that covers what you are touching:

- **Editing `loop.sh`** — read §5 (the loop) and §9 (decisions already settled,
  which is a list of things not to reopen).
- **Editing verdict parsing, or any skill that emits a verdict** — read §4's
  verdict contract and §10 (silence is not consent). A missing verdict must
  block; it must never fall through to green.
- **Editing the guardrail or `hooks.json`** — read §8 and
  `overnight/hooks/README.md`. The hook is armed only during a run, gated on
  `OVERNIGHT_WORKTREE`.
- **Adding or moving a file** — read §3 (the two-place rule) first and be sure
  which of the two places it belongs in.

Skills carry `disable-model-invocation` on purpose: the runner invokes each
phase as its own process so QA and review get genuinely fresh context. Do not
remove it to make a skill callable in-session.
