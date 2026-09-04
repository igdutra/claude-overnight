# Skills

Eleven skills. Seven are the workflow, in order; four run the overnight loop.

Claude routes on each skill's frontmatter `description`, not on this table —
this is the map for a human deciding which file to open.

## The workflow

| # | Skill | What it does | You run it |
|---|---|---|---|
| 1 | [`discovery`](discovery/SKILL.md) | Surfaces unknown unknowns, then interviews you one question at a time | Before anything is scoped |
| 2 | [`prototype`](prototype/SKILL.md) | Builds several deliberately different directions to react to | When a direction is unclear |
| 3 | [`spec`](spec/SKILL.md) | Writes the plan to `specs/<slug>/SPEC.md` | Once the direction is locked |
| 4 | [`implement-spec`](implement-spec/SKILL.md) | Builds the spec, keeping `implementation-notes.md` current | The runner calls this |
| 5 | [`qa`](qa/SKILL.md) | Checks the build against the spec's Acceptance Criteria, fresh context. Emits `QA-VERDICT` | The runner calls this |
| 5 | [`local-code-review`](local-code-review/SKILL.md) | Reviews the diff for bugs, fresh context. Emits `REVIEW-BUGS` | The runner calls this |
| 6 | [`finish`](finish/SKILL.md) | Explains what was built, so you understand code you didn't write | After QA passes |
| 7 | [`pitch`](pitch/SKILL.md) | Bundles the work into one shareable doc for other people | When it needs buy-in |

Steps 5 are two skills that run together: `/qa` covers functionality,
`/local-code-review` covers correctness and quality.

## The overnight runner

| Skill | What it does | You run it |
|---|---|---|
| [`overnight-init`](overnight-init/SKILL.md) | Detects and **verifies** a repo's build commands, writes them into its `CLAUDE.md`, seeds the queue | Once per repository |
| [`overnight`](overnight/SKILL.md) | Runs the queue unattended — worktrees, implement, QA, review, fix, pull requests | Each night |
| [`overnight-report`](overnight-report/SKILL.md) | Publishes the morning page: what shipped, what blocked, what needs you | Each morning |

`/overnight` and `/overnight-report` are the only two commands anyone should
need to type. Everything else is machinery they drive.

## Conventions

Every skill except `discovery` and `prototype` carries
`disable-model-invocation: true`, so a session cannot call it as a tool. The
runner invokes each phase as its own `claude -p` process — that is what makes
QA's and review's fresh context real rather than aspirational.

`qa`, `local-code-review`, and `finish` also carry `context: fork`.

Skills that the runner branches on emit machine-readable verdict lines. Their
contract is in `docs/DESIGN.md` §4 — change a skill's output format and you
must change `loop.sh` with it.
