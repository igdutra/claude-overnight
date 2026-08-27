# Roadmap

Work that is understood but deliberately not built yet. Each item states what it
is, what it would cost, and what has to be settled before anyone starts.

Nothing here is scheduled. This file exists so the reasoning survives the
session it came from.

---

## Watch a spec being built, in VS Code

**Status:** not started. Exploratory — the value is unproven, and the current
headless run works.

Today `loop.sh` runs each phase as a headless `claude -p ... | tee
logs/*.jsonl | render-stream.py` process. The operator watches by tailing a log.
The idea is to let them *see it happen* instead: open VS Code on the worktree
the moment it is created, with a terminal in that window showing the phase feed
live, so a spec's implementation is watchable in a real editor.

### The three pieces

**1. Open VS Code on the worktree.** Trivial — `code "$worktreePath"` right
after the worktree is confirmed. VS Code's file watcher shows files changing
live in the Explorer as any process edits them, background `claude -p`
included. No extra wiring.

**2. Auto-open a terminal in that window.** A `.vscode/tasks.json` with
`"runOptions": {"runOn": "folderOpen"}` runs automatically when VS Code opens
the folder, landing output in an integrated terminal.
([task docs](https://code.visualstudio.com/docs/debugtest/tasks))

**3. Have that terminal show the phase feed.** The task's `command` tails the
run's phase log through `render-stream.py`, so the terminal shows the same
readable feed the operator would otherwise `tail -f`. Not the raw `.jsonl`.

### The blocker to resolve first

VS Code gates `runOn: folderOpen` behind **workspace trust**: the first time a
folder with such a task opens, it prompts "allow automatic tasks in this
folder?" — and a worktree is a freshly created directory *every single spec*.
Without pre-trust that prompt fires once per spec, destroying the unattended
property that is the whole point of `loop.sh`. The docs are explicit:
"automatic tasks never run in an untrusted workspace."

Before building anything that depends on this being silent, check whether
`security.workspace.trust.*` can pre-trust a path *pattern* (e.g. everything
under `../wt-*`) rather than folder-by-folder, and whether the `code` CLI can
open with trust already granted. **Unverified.** If trust cannot be pre-granted,
the feature ships default-off and documented as "expect a one-time trust prompt
per spec" — not sold as silent.

### Two designs — pick one before building

**Design A — viewer only.** `loop.sh` keeps driving every phase headlessly
exactly as today; VS Code is purely an extra window for the human, showing a
read-only feed of the same logs. All existing guarantees — checkpoint accuracy,
exhaustion detection, no false SHIPPED — are untouched, because nothing about
how a verdict is reached changes.

**Design B — the visible terminal *is* the implement phase.** The folderOpen
task runs `claude` interactively, replacing the headless call. Closer to "start
Claude there," but it breaks a real contract: everything downstream
(`runPhase`'s health check, `readVerdict`, the checkpoint) parses a
`stream-json` stream from a fixed prompt with no human interjection. An
interactive session has no defined "done" signal to wait on, and if the user
types into it, the fresh-eyes-per-phase design stops holding — a human is now
part of that phase's context.

**Recommendation: build A first.** It gets ~90% of the value (watch files
change, watch a real terminal) with none of the risk to the verification
guarantees. Build B only if the user explicitly wants to intervene
mid-implementation — and if so, that phase should stop counting as one of the
three scripted fix attempts, since a human-steered attempt is not comparable to
an automated one.

### Constraints on whoever builds it

- Opt-in flag (e.g. `--open-vscode`), best-effort: never fail a run because
  `code` is not on PATH or VS Code is not installed.
- Ship the `tasks.json` template through `.worktreeinclude`, the mechanism
  `loop.sh` already uses to copy files into fresh worktrees.
- **Entirely additive.** With the flag absent — the default — `loop.sh`'s
  behavior must be byte-for-byte what it is today.
