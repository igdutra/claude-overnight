---
name: overnight-report
description: Publish the morning artifact for an overnight run — one page covering every spec, what shipped, what blocked, and what needs the user's attention. Reads overnight/<date>/<run-id>/. Trigger on /overnight-report [date] [run-id].
disable-model-invocation: true
---

# Overnight report

Publish one artifact covering the whole night. This is the deliverable the user
actually wakes up to — the code is on branches they have not read, in pull
requests they have not opened. The page is how they find out what happened.

## Which run to report on

`$ARGUMENTS` is `[date] [run-id]`; both are optional. Resolve the run directory
in this order:

1. **Both given** — read `overnight/<date>/<run-id>/`.
2. **Date only** — look under `overnight/<date>/`. If exactly one `run-*`
   directory is there, use it. If several are, **do not merge them**: they are
   separate runs with separate verdicts, and a page that blends two runs'
   results describes a night that never happened. List them with their start
   times and ask which one, or report the most recent and say plainly at the
   top of the page that others exist and are not covered.
3. **Neither** — today's date, then rule 2.

A run directory holds `RUN.md`, `loop.log`, `logs/`, `shipped.md` and
`suggestions.md`. `QUEUE.md` sits one level up, at the date, because the
operator writes it before any run exists.

If the resolved directory does not exist, list what is under `overnight/` and
stop.

## Read first

- **`RUN.md`** — the spine. Every spec, its verdict, duration, branch, pull
  request, attempt count, and for blocked specs the reason.
- **`logs/<slug>.log`** — the full session per spec. This is where the prose
  written for the morning lives, above each `SPEC-RESULT:` block. Pull the real
  account from here; `RUN.md` only carries the summary lines.
- **`suggestions.md`** — non-blocking findings, filed but not acted on. Two
  kinds live here: code-review suggestions, and **QA concerns** (`## <slug> —
  QA concerns`) where QA looked at a rendered snapshot, saw a difference, and
  judged it cosmetic. Surface the QA concerns distinctly — they are a machine's
  judgment call about what a screen looks like, and the user is the one who
  gets to overrule it.
- **`specs/<slug>/SPEC.md`** — what was asked for.
- **`specs/<slug>/implementation-notes.md`** — deviations, and the per-attempt
  log for anything that took more than one try.

For shipped specs, also read the diff: `git diff main...spec/<slug>`. Do not
describe code you have not looked at.

## Write for someone who was asleep

They have no idea what happened. They did not watch a single decision. Write for
that reader, not for someone reconstructing a session they half-remember.

What this means concretely:

- **Lead with what they need to decide**, not with chronology. The first thing
  on the page should be: how many shipped, what needs attention, what to open
  first.
- **Explain the reasoning, not the syntax.** They can read the diff. They cannot
  recover *why* it went this way and not the other — that is the part that is
  gone unless the report carries it.
- **A blocked spec is not a footnote.** It is often the most valuable section on
  the page, because it is the one that needs them. Give it the same care as a
  shipped one: what was tried across the attempts, what the verdicts actually
  said, and the best read on why it did not work.
- **Do not editorialise the outcome.** Three shipped and two blocked is a fine
  night; write it plainly. Inflating a partial result costs the user more than
  it saves them, because next time they cannot trust the page.

## Structure

**Header** — the date, and one line of shape: how many shipped, blocked,
skipped, and how long the run took.

**What to do first** — the actions waiting for them, ordered. Pull requests to
review, blocked specs to look at, anything that needs a decision. If nothing
needs them, say that plainly.

**One section per spec**, shipped first, then blocked, then skipped:

- What it was meant to do, in plain language from the spec
- What was built and how it works — enough to navigate the code unaided
- **Why it is like this** — decisions and their alternatives, pulled from the
  spec and any logged deviations. The part not recoverable from the diff.
- QA result: criteria passed and failed, and how many attempts it took
- The pull request link, prominent
- Anything to watch: deviations, concerns, assumptions

For a blocked spec, replace the last three with: what was tried in each attempt,
what never cleared, the best read on why, and what to try next. Link the branch
even though there is no pull request — a branch someone can look at is worth far
more than a discarded one.

**QA concerns** — anything QA passed but flagged about a rendered snapshot.
Give these their own short section rather than burying them among code
suggestions: say which spec, what QA saw, and that it shipped anyway. A missing
control or a dropped label is exactly the kind of thing that is obvious to a
person in two seconds and invisible to every automated check downstream.

**Suggestions** — grouped by spec, from `suggestions.md`. These were deliberately
not acted on. Present them as a list to skim and decide on, not as work owed.

**Run detail** — timings, attempt counts, token usage if `RUN.md` recorded it,
and where the worktrees are. Small, at the bottom; useful when something looks
wrong.

## Publishing

Load the `artifact-design` skill first, then write the HTML and publish it.

- **Title**: `Overnight <date>` — short, and stable across republishes.
- **Favicon**: pick one and keep it the same for every night's report.
- **Description**: one line naming the shape of the night.

Republishing the same file path updates the same URL. **If the run stopped
partway and you are adding the remaining specs, pass the existing artifact's
`url`** so it updates in place rather than creating a second page. Find it in
`RUN.md` if the loop recorded it, or with `action: "list"`.

Write the file to the run directory as `report.html` — the same directory
`RUN.md` was read from, not the date level — so it is re-publishable later
without rebuilding it, and so two runs on one date keep two reports.

Then **append the artifact URL to `RUN.md`** under a `## Report` heading. That
file is the durable record; the URL belongs in it.

## Design

The page is read once, over coffee, on a phone as often as a laptop. Favour
scanning over completeness:

- Verdicts should be visible without reading — a shipped spec and a blocked one
  should be distinguishable at a glance, and not by colour alone.
- Pull request links are the most-clicked thing on the page. Make them obvious.
- Long logs and diffs belong in a collapsed `<details>`, not inline. The user
  wants the account, and the raw material only when something looks wrong.
- Code samples only where they carry the explanation. This is a report, not a
  diff viewer.

## Say when there is nothing to report

If the run produced nothing — the queue was empty, or every spec was skipped —
say so in two sentences and do not publish. An artifact with no content is worse
than a line of text, because it costs a click to discover it was empty.
