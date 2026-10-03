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

---

## Skill enhancements from the Opus 5.5 / Sonnet 5.5 guidance

**Status:** items 1 to 9 done (item 2 dropped). Ordered by value when skills
are run on demand, with QA and review fired only occasionally, so
`/implement-spec` is often the only gate a spec passes.

Sources: [Opus 5.5](https://claude.dev/blog/getting-the-most-out-of-opus-5-5/),
[Sonnet 5.5](https://claude.dev/blog/building-with-claude-sonnet-5-5/),
[Spending Your Effort](https://claude.dev/blog/spending-your-effort/),
[the Fable field guide](https://claude.com/blog/a-field-guide-to-claude-fable-finding-your-unknowns).

| # | Skill | Change | Source | Status |
|---|---|---|---|---|
| 1 | `/implement-spec` | Run the project's stated check before reporting done; install nothing, and hand back to the user if none is stated or it cannot run | Sonnet | Done. Tightened from the article's paragraph: only stated commands, no installs |
| 2 | `/spec` | Close with a Sonnet cold-read: implement from `SPEC.md` alone, list every ambiguity, fold the answers in | Sonnet, Effort | Dropped from `/spec`: no article basis. Kept as an optional habit in `INDEX.md` |
| 3 | `/spec` | A Haiku subagent checks `SPEC.md` and `discovery.md` for contradictions; one line if clean, otherwise stop and show them | Opus | Done. The subagent and Haiku are our adaptation of the article's document check |
| 4 | `/prototype` | Ask once what to avoid, naming specifics | Opus | Done. Reference images dropped: the article says no extra steps are needed |
| 5 | `/local-code-review` | Add how to show the bug fails to each `REVIEW-BUG:` finding | Opus 5.5 | Done. The "would block the merge" bar was already in the skill. `docs/DESIGN.md` §4 synced; `loop.sh` reads only the count line |
| 6 | `/spec`, `/implement-spec` | Keep a checklist in `TASKS.md` for a run that will take a while | Opus 5.5 | Done. `/spec` flags `Task list: yes` or `no` in Steps and `/implement-spec` obeys it, so an unattended run asks nothing. The flag is our design; the article gives only the condition |
| 7 | `/implement-spec` | End the final message with three headings: Blocked on me, Changed, Found | Opus 5.5 | Done. The article puts this in `CLAUDE.md`; it lives in the skill so it travels with it |
| 8 | `/discovery` | Ask for a reference when the user cannot describe what they want; the best one is source code, even in another language | Fable | Done. The finish-line half is dropped: `/spec` Acceptance Criteria already define "done" |
| 9 | `/implement-spec` | "Done means every item under `## Acceptance Criteria` is met" | Opus 5.5 | Done. Maps the article's "name the finish line" onto the spec's own definition of done |

### Left from the articles

- **Stop rules** (Opus 5.5, "Tell it which stops you want"): a short rule in
  `CLAUDE.md` about when to stop and ask and when to keep going. A project
  setting, not a skill change, and an unattended run cannot ask. Add it to a
  repo's own `CLAUDE.md` if wanted.
- **Splitting work across subagents** (Opus 5.5): for audits and migrations over
  a large codebase. Does not apply; the runner is serial by design (DESIGN §9).
  Only `/spec` uses a subagent, for the contradiction check.

Everything else in the four articles is done above, already in the skills (the
Fable guide's blind spot pass, interview, prototypes, plans, notes, explainer and
pitch; `/qa` already fails what it cannot verify), user behavior (mid-run
follow-ups, fast mode), Claude apps only (screenshots, projects), or checked with
nothing to change: no "think hard" or "show your reasoning" lines in any skill,
and no Sonnet 5 workarounds.

### Parked

- **Pinning a model and effort per skill or per phase in `loop.sh`.** Decided
  against for now; sessions choose their own model.
- **Escalating fix attempt 3 to Opus.** Only matters for overnight runs.
- **`budget.sh` weighting Opus and Sonnet differently.** Unchecked whether the
  gate sums tokens equally across models. Only matters for overnight runs.
