#!/bin/bash
# loop.sh — run a queue of specs overnight, one fresh Claude process each.
#
# The outer loop. For every spec in the queue it creates a git worktree, starts
# a new claude process with that worktree as its working directory, and lets
# runs each phase — implement, test, QA, review, fix, ship — as its own claude
# process, then moves to the next spec with a cold context.
#
# The fresh process per spec is the whole point, and it is not about context
# capacity. It is about re-anchoring: iteration N+1 reads state from disk rather
# than from a window full of iteration N's failed attempts. Progress persists in
# files; failures evaporate with the process.
#
# Why a plain `git worktree add` rather than `claude --worktree`: a session that
# Claude Code considers "isolated" enforces a command-shape check that refuses
# any Bash it cannot trace without running, heredocs and brace expansion
# included, and that check cannot be turned off. A worktree made with git, then
# entered by cd, is just a normal directory to a normal session — real isolation
# from the filesystem, without the tool-call interception.
#
# Usage:
#   ./loop.sh <repo> [--queue <file>] [--run-id <id>] [--max-specs <n>]
#            [--budget <tokens>] [--dry-run]
#
# Each run writes everything it produces — RUN.md, loop.log, per-phase logs,
# checkpoints, shipped.md, suggestions.md — under overnight/<date>/<run-id>/,
# so runs on the same day never share state. --run-id names that directory;
# without it the run picks run-<HHMMSS>-<pid>. The path to tail is printed at
# launch; no stdout redirect is needed or expected.
#
# The queue is a markdown checklist; unchecked items are the work:
#   - [ ] add-login
#   - [x] fix-header      (already done, skipped)

set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUN_DATE="$(date +%Y-%m-%d)"

# Ralph's recommended ceiling, and a sane one: a queue longer than this is a
# planning problem, not something to grind through unattended.
readonly DEFAULT_MAX_SPECS=25

# Three rounds of fresh-eyes verification failing means it is stuck in a way a
# fourth identical round will not solve.
readonly MAX_FIX_ATTEMPTS=3

# Stop taking new specs past this much usage in the trailing five hours. The
# reserve below it is what writes the morning artifact — running the window dry
# and losing the report is the worst possible ending.
readonly DEFAULT_BUDGET_TOKENS=8000000

repoPath=""
queueFile=""
runId=""
maxSpecs="$DEFAULT_MAX_SPECS"
budgetTokens="$DEFAULT_BUDGET_TOKENS"
dryRun=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue)     queueFile="$2"; shift 2 ;;
    --run-id)    runId="$2"; shift 2 ;;
    --max-specs) maxSpecs="$2"; shift 2 ;;
    --budget)    budgetTokens="$2"; shift 2 ;;
    --dry-run)   dryRun=true; shift ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           repoPath="$1"; shift ;;
  esac
done

[[ -n "$repoPath" ]] || { echo "usage: ./loop.sh <repo> [options]" >&2; exit 2; }

repoPath="$(cd "$repoPath" 2>/dev/null && pwd -P)" || {
  echo "no such directory: $repoPath" >&2; exit 2; }

cd "$repoPath" || exit 2

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
# Every check here is something that would otherwise fail hours later, in the
# dark, after burning budget. They are cheap now and expensive at 3am.

git rev-parse --show-toplevel >/dev/null 2>&1 || fail "$repoPath is not a git repository"

grep -q "## Build & Validation" CLAUDE.md 2>/dev/null || fail \
  "CLAUDE.md has no '## Build & Validation' block — run /overnight-init in this repo first.
   Without a test command nothing can tell the run when it is wrong, and the whole
   verification loop is meaningless."

# The block existing is not the same as the block being right. Commands rot:
# they keep naming a scheme or a package after the work has moved elsewhere,
# and go on exiting 0 while exercising nothing anybody is changing. The run
# would treat that as backpressure when it is not.
#
# This cannot be settled mechanically — deciding whether a command still covers
# the queued specs takes reading them. What can be done here is surface the
# block so the decision is at least possible, and insist it says what it covers.
if ! grep -qE '^[[:space:]]*-[[:space:]]*Covers:' CLAUDE.md 2>/dev/null; then
  log "note: the '## Build & Validation' block has no 'Covers:' line, so nothing"
  log "      states what these commands actually exercise. If the queued specs"
  log "      touch code the suite does not cover, this run's green lights mean"
  log "      nothing. Re-run /overnight-init to re-verify and record the scope."
fi

guardrailHook="$SCRIPT_DIR/hooks/block-dangerous-git.sh"
[[ -x "$guardrailHook" ]] || fail \
  "the guardrail hook is missing or not executable at $guardrailHook.
   The plugin ships it; a broken install means the run would proceed unguarded."

# Prove the hook actually denies before trusting a night to it. A hook that
# silently allows everything — a missing jq, a bad copy — is worse than none,
# because the run proceeds believing it is protected.
hookProbe=$(OVERNIGHT_WORKTREE=/tmp/overnight-probe "$guardrailHook" <<< \
  '{"tool_name":"Bash","cwd":"/tmp/overnight-probe","tool_input":{"command":"git push origin main"}}' 2>/dev/null)
printf '%s' "$hookProbe" | grep -q '"deny"' || fail \
  "the guardrail hook did not deny a push to main when probed.
   Run ${SCRIPT_DIR}/hooks/test-hook.sh to see what is wrong; do not run unattended until it passes."

git diff --quiet && git diff --cached --quiet || fail \
  "the working tree has uncommitted changes. Commit or stash them; worktrees branch
   from the default branch and unrelated local state makes the run's diffs unreadable."

command -v gh >/dev/null 2>&1 || fail "gh is not installed; the run opens pull requests"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated — run: gh auth login"
command -v jq >/dev/null 2>&1 || fail "jq is not installed"

# Every run gets its own directory, not just its own date. Keying state by
# calendar date alone meant a second run the same day appended into the first
# run's RUN.md, shared its QUEUE.md, and overwrote its checkpoints — and the
# operator had no way to tell which run any given line came from. A run id
# makes collision impossible rather than merely unlikely: two runs cannot
# clobber each other's state when they never share a path.
[[ -n "$runId" ]] || runId="run-$(date +%H%M%S)-$$"
runDirectory="overnight/$RUN_DATE/$runId"
mkdir -p "$runDirectory/logs"

# The log this script writes about itself. Until now loop.sh never wrote one:
# `overnight/<date>/loop.log` existed only because some launching session
# redirected stdout there by hand, and the "tail -f the log" instruction was
# folklore no code guaranteed. A launch that redirected to /dev/null — or a
# second run that aimed at the first run's file — left the operator watching
# a file nothing was writing to. Owning the path here makes "where do I watch
# this run" a fact the script can state rather than a convention to reinvent.
runConsoleLog="$runDirectory/loop.log"
: > "$runConsoleLog"

# tee from inside rather than asking the caller to redirect. exec rewires this
# script's own stdout/stderr, so every log line from here on lands in both the
# terminal and the file, and a caller who redirects to /dev/null still gets a
# complete log on disk.
exec > >(tee -a "$runConsoleLog") 2>&1

# ---------------------------------------------------------------------------
# The repo lock
# ---------------------------------------------------------------------------
# Specs run strictly one at a time by design, and every run of this script
# shares one worktree/branch namespace (../wt-<slug>, spec/<slug>). Two runs
# against the same repo therefore race `git worktree add` for any spec both
# queues name. Git refuses the duplicate, so today that fails loudly rather
# than corrupting anything — but it fails hours in, in the dark, as an
# unhandled error rather than a designed one.
#
# Refusing up front is the honest behaviour. Multiple runs against *different*
# repos stay fine; so does a second run once the first has finished.
lockDirectory="$repoPath/.git/overnight.lock"
writeLockOwner() {
  printf '%s\n' "$$" > "$lockDirectory/pid"
  printf '%s\n' "$runId" > "$lockDirectory/run-id"
  printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$lockDirectory/started-at"
  # The command name of the process holding the lock. PIDs recycle — this box
  # tops out at a few thousand — so a dead run's pid is quickly reused by
  # something unrelated, and `kill -0` alone would then report a stale lock as
  # live and refuse a legitimate run forever. Checking the name too means the
  # pid must still belong to a bash process before we believe it.
  ps -o comm= -p "$$" 2>/dev/null | tr -d ' \n' > "$lockDirectory/comm" || true
}

if mkdir "$lockDirectory" 2>/dev/null; then
  writeLockOwner
else
  lockPid="$(cat "$lockDirectory/pid" 2>/dev/null || true)"
  lockRunId="$(cat "$lockDirectory/run-id" 2>/dev/null || echo unknown)"
  lockStarted="$(cat "$lockDirectory/started-at" 2>/dev/null || echo unknown)"

  # A lock whose process is gone is stale — a previous run was killed before it
  # could clean up. Reclaim it rather than making the operator delete a
  # directory by hand to get their repo back.
  lockComm="$(cat "$lockDirectory/comm" 2>/dev/null || true)"
  livePid=false
  if [[ -n "$lockPid" ]] && kill -0 "$lockPid" 2>/dev/null; then
    # The pid exists. Is it still the same program, or has it been recycled?
    currentComm="$(ps -o comm= -p "$lockPid" 2>/dev/null | tr -d ' \n')"
    if [[ -z "$lockComm" || "$currentComm" == "$lockComm" ]]; then
      livePid=true
    else
      log "lock pid $lockPid is now '$currentComm', not '$lockComm' — the pid was recycled"
    fi
  fi

  if $livePid; then
    fail "another overnight run is already working in this repo.

   run:     $lockRunId (pid $lockPid)
   started: $lockStarted

   Specs share one worktree and branch namespace, so two runs would race each
   other over the same ../wt-<slug> directories. Wait for that run to finish,
   or stop it, then start this one."
  fi

  log "found a stale lock from $lockRunId (pid ${lockPid:-unknown}, started $lockStarted)"
  log "no such run is holding it — reclaiming it"
  writeLockOwner
fi

# Release on every exit path, including failures and Ctrl-C. A lock that
# outlives its run turns the next launch into a puzzle.
#
# INT/TERM need their own handlers rather than relying on the EXIT trap alone.
# A run spends nearly all its wall time blocked in a foreground `claude -p`
# child, and bash defers a trap until that child returns — so a killed run
# would leave the lock behind until something else cleaned it up. Handling the
# signal explicitly and re-raising it releases promptly and still reports the
# right exit status to whatever killed us.
releaseLock() { rm -rf "$lockDirectory" 2>/dev/null || true; }
onSignal() {
  local signalName="$1"
  releaseLock
  trap - "$signalName" EXIT
  kill -s "$signalName" "$$"
}
trap releaseLock EXIT
trap 'onSignal INT' INT
trap 'onSignal TERM' TERM

# The queue is an input, not an output: the operator writes it before any run
# exists, so it stays at the date level rather than moving under the run
# directory with everything this script produces. Two runs meant to work
# different queues pass --queue; two runs sharing one queue are the case the
# repo lock refuses outright.
[[ -n "$queueFile" ]] || queueFile="overnight/$RUN_DATE/QUEUE.md"

if [[ ! -f "$queueFile" ]]; then
  fail "no queue at $queueFile

Create it with one unchecked item per spec:

  - [ ] add-login
  - [ ] fix-header

Each slug must match a directory under specs/."
fi

# API credits are forbidden: the run uses subscription budget only. Unsetting
# the key makes the fallback unreachable rather than merely discouraged.
unset ANTHROPIC_API_KEY

# ---------------------------------------------------------------------------
# The queue
# ---------------------------------------------------------------------------

readQueue() {
  grep -E '^[[:space:]]*-[[:space:]]*\[ \][[:space:]]*[^[:space:]]' "$queueFile" 2>/dev/null \
    | sed -E 's/^[[:space:]]*-[[:space:]]*\[ \][[:space:]]*//; s/[[:space:]]+$//'
}

markQueueItem() {
  local slug="$1" mark="$2"
  python3 - "$queueFile" "$slug" "$mark" <<'PYEOF'
import re, sys
queuePath, slug, mark = sys.argv[1], sys.argv[2], sys.argv[3]
with open(queuePath) as handle:
    lines = handle.readlines()
pattern = re.compile(r'^(\s*-\s*)\[ \](\s*)' + re.escape(slug) + r'\s*$')
for index, line in enumerate(lines):
    match = pattern.match(line)
    if match:
        lines[index] = f"{match.group(1)}[{mark}]{match.group(2)}{slug}\n"
        break
with open(queuePath, "w") as handle:
    handle.writelines(lines)
PYEOF
}

# Read with a while loop rather than mapfile: macOS ships bash 3.2, which has
# neither mapfile nor readarray.
pendingSpecs=()
while IFS= read -r queueLine; do
  [[ -n "$queueLine" ]] && pendingSpecs+=("$queueLine")
done < <(readQueue)

if [[ ${#pendingSpecs[@]:-0} -eq 0 ]]; then
  log "nothing pending in $queueFile — every item is checked off"
  exit 0
fi

specCount=${#pendingSpecs[@]}
if [[ $specCount -gt $maxSpecs ]]; then
  log "queue has $specCount specs; capping this run at $maxSpecs"
  pendingSpecs=("${pendingSpecs[@]:0:$maxSpecs}")
  specCount=$maxSpecs
fi

log "repo:   $repoPath"
log "run:    $runId"
log "queue:  $queueFile ($specCount specs)"
log "log:    $runDirectory/loop.log"
log "watch:  tail -f $repoPath/$runDirectory/loop.log"
log "budget: stop taking new specs past $budgetTokens tokens in the trailing 5h"
$dryRun && log "DRY RUN — no worktrees, no claude, no pushes"

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

runLog="$runDirectory/RUN.md"
if [[ ! -f "$runLog" ]]; then
  {
    printf '# Overnight run — %s (%s)\n\n' "$RUN_DATE" "$runId"
    printf 'Started %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Console log: `%s/loop.log`\n\n' "$runDirectory"
  } > "$runLog"
fi

shippedCount=0
blockedCount=0
skippedCount=0

# Set true the moment any phase comes back holding a session-limit banner.
# Once set, the run stops taking work: every further phase would return
# instantly having done nothing, and marking that as a result is the bug this
# whole file was rewritten to prevent.
runExhausted=false
exhaustionResetsAt=""
exhaustedAtSpec=""
exhaustedAtPhase=""

# Set when the run stops deliberately at a spec that needs a human decision,
# as opposed to running out of queue.
halted=false
haltReason=""

# ---------------------------------------------------------------------------
# Verdicts
# ---------------------------------------------------------------------------
# The old triage asked "did it say FAIL?" and treated everything else as a
# pass. That is backwards for an unattended run: silence is the most common
# failure and it scored as success. A phase is green only if it affirmatively
# said so, in the format its own skill contract fixes.
#
# readVerdict <output> <marker> <passWord> <failWord>
#   → PASS | FAIL | INDETERMINATE
#
# INDETERMINATE is not a soft pass. It means the phase did not answer the
# question, and it routes to BLOCKED exactly like a FAIL — the difference is
# only what the morning report says about why.
readVerdict() {
  local output="$1" marker="$2" passWord="${3:-PASS}" failWord="${4:-FAIL}"
  local verdictLine

  verdictLine=$(printf '%s' "$output" \
    | grep -E "^[[:space:]]*${marker}:[[:space:]]*(${passWord}|${failWord})[[:space:]]*$" \
    | tail -1)

  if [[ -z "$verdictLine" ]]; then
    printf 'INDETERMINATE'
  elif printf '%s' "$verdictLine" | grep -qE "${failWord}[[:space:]]*$"; then
    printf 'FAIL'
  else
    printf 'PASS'
  fi
}

# The review contract emits a count line (REVIEW-BUGS: n) plus one detail line
# per bug (REVIEW-BUG: file:line — what). loop.sh used to count only the detail
# lines, which happen to agree with the count whenever bugs exist and silently
# report zero when the block is malformed or missing. The count line is the
# contract, so it is what gets read — and its absence is INDETERMINATE, not
# zero bugs.
#
# readBugCount <output> → a number, or the word INDETERMINATE
readBugCount() {
  local output="$1" countLine

  countLine=$(printf '%s' "$output" \
    | grep -E '^[[:space:]]*REVIEW-BUGS:[[:space:]]*[0-9]+' | tail -1 \
    | sed -E 's/^[[:space:]]*REVIEW-BUGS:[[:space:]]*([0-9]+).*$/\1/')

  if [[ -z "$countLine" ]]; then
    printf 'INDETERMINATE'
  else
    printf '%s' "$countLine"
  fi
}

# ---------------------------------------------------------------------------
# The checkpoint
# ---------------------------------------------------------------------------
# One JSON file per spec, rewritten after every phase. Its whole purpose is the
# morning question: which spec stopped, at which phase, and why — answerable
# with `cat`, rather than by grepping .jsonl streams, which is what writing the
# bug report for the 2026-08-25 run actually required.
#
# It is also what a cold session reads to resume: the orchestrator loads it
# before deciding whether to re-run a spec or leave it alone.
checkpointPath=""

checkpointPhase() {
  local phaseName="$1" healthJson="${2:-}"
  [[ -n "$checkpointPath" ]] || return 0
  [[ -n "$healthJson" ]] || healthJson='{}'

  python3 - "$checkpointPath" "$phaseName" "$healthJson" <<'PYEOF_CHECKPOINT'
import json, os, sys
from datetime import datetime

checkpointPath, phaseName, healthJson = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    health = json.loads(healthJson)
except (json.JSONDecodeError, ValueError):
    health = {}

try:
    with open(checkpointPath) as handle:
        checkpoint = json.load(handle)
except (OSError, json.JSONDecodeError, ValueError):
    checkpoint = {}

checkpoint.setdefault("phases", [])
checkpoint["phases"].append({
    "phase": phaseName,
    "at": datetime.now().astimezone().isoformat(timespec="seconds"),
    "healthy": not (
        health.get("exhausted")
        or health.get("is_error")
        or health.get("silent")
        or health.get("saw_result") is False
    ),
    "exhausted": bool(health.get("exhausted")),
    "is_error": bool(health.get("is_error")),
    "tool_calls": health.get("tool_calls", 0),
})
checkpoint["last_phase"] = phaseName
checkpoint["updated_at"] = checkpoint["phases"][-1]["at"]

with open(checkpointPath, "w") as handle:
    json.dump(checkpoint, handle, indent=2)
    handle.write("\n")
PYEOF_CHECKPOINT
}

# checkpointField <key> <value> — record a top-level fact about the spec.
checkpointField() {
  [[ -n "$checkpointPath" ]] || return 0
  python3 - "$checkpointPath" "$1" "$2" <<'PYEOF_FIELD'
import json, sys
from datetime import datetime

checkpointPath, key, value = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(checkpointPath) as handle:
        checkpoint = json.load(handle)
except (OSError, json.JSONDecodeError, ValueError):
    checkpoint = {}

checkpoint[key] = value
checkpoint["updated_at"] = datetime.now().astimezone().isoformat(timespec="seconds")

with open(checkpointPath, "w") as handle:
    json.dump(checkpoint, handle, indent=2)
    handle.write("\n")
PYEOF_FIELD
}

specIndex=0
# ---------------------------------------------------------------------------
# runPhase
# ---------------------------------------------------------------------------
# Defined here, above the spec loop, rather than inside it. Bash defines a
# function when execution reaches it, so a definition inside the loop body is
# not callable from the state-reconciliation block that runs earlier in the
# same iteration — which is exactly what the COMMITTED/LOCAL-ONLY arm needs to
# do. It reads $slug, $worktreePath, $specLog and $runDirectory from the
# enclosing loop's scope either way.

# runPhase <name> <prompt> [extra claude args...]
# Leaves the phase's final text in $phaseOutput and its raw stream on disk.
# Sets $phaseHealthy false and $runExhausted true when the phase did not
# actually run — see the health check below.
runPhase() {
  local phaseName="$1" phasePrompt="$2"
  shift 2

  local streamPath="$runDirectory/logs/$slug.$phaseName.jsonl"
  streamPath="$repoPath/$streamPath"

  echo
  log "── $slug · $phaseName ──"

  (
    cd "$worktreePath" || exit 2
    claude -p "$phasePrompt" \
      --permission-mode auto \
      --add-dir "$repoPath" \
      --output-format stream-json \
      --verbose \
      "$@" \
      2>>"$specLog"
  ) | tee "$streamPath" | "$SCRIPT_DIR/render-stream.py" "$slug/$phaseName"

  phaseOutput=$(python3 "$SCRIPT_DIR/extract-result.py" "$streamPath")
  printf '\n===== %s =====\n%s\n' "$phaseName" "$phaseOutput" >> "$specLog"

  # Did this phase actually run, or did it come back holding a banner?
  #
  # A rate-limited turn returns instantly, with well-formed output, having
  # done nothing. On 2026-08-25 twelve consecutive phases did exactly that
  # and every one of them was scored green, because the triage below only
  # ever looked for the word FAIL. The health check is what makes "returned
  # without running" distinguishable from "ran and found nothing wrong".
  local healthJson
  healthJson=$(python3 "$SCRIPT_DIR/extract-result.py" --health "$streamPath" 2>/dev/null)

  phaseHealthy=true
  phaseUnhealthyReason=""

  if [[ -n "$healthJson" ]]; then
    local phaseExhausted phaseIsError phaseSilent phaseResetsAt phaseSawResult
    phaseExhausted=$(printf '%s' "$healthJson" | jq -r '.exhausted // false')
    phaseIsError=$(printf '%s' "$healthJson" | jq -r '.is_error // false')
    phaseSilent=$(printf '%s' "$healthJson" | jq -r '.silent // false')
    phaseSawResult=$(printf '%s' "$healthJson" | jq -r '.saw_result // false')
    phaseResetsAt=$(printf '%s' "$healthJson" | jq -r '.resets_at // ""')

    if [[ "$phaseExhausted" == "true" ]]; then
      phaseHealthy=false
      runExhausted=true
      exhaustionResetsAt="$phaseResetsAt"
      phaseUnhealthyReason="session limit reached"
      [[ -n "$phaseResetsAt" ]] && phaseUnhealthyReason="session limit reached (resets $phaseResetsAt)"
    elif [[ "$phaseIsError" == "true" ]]; then
      phaseHealthy=false
      phaseUnhealthyReason="the phase returned an error"
    elif [[ "$phaseSilent" == "true" ]]; then
      phaseHealthy=false
      phaseUnhealthyReason="the phase produced no output and called no tools"
    elif [[ "$phaseSawResult" != "true" ]]; then
      phaseHealthy=false
      phaseUnhealthyReason="the stream ended without a result (killed or crashed)"
    fi
  else
    phaseHealthy=false
    phaseUnhealthyReason="could not read the phase's stream"
  fi

  if ! $phaseHealthy; then
    log "!! $phaseName did not run: $phaseUnhealthyReason"
  fi

  checkpointPhase "$phaseName" "$healthJson"
}

for slug in "${pendingSpecs[@]}"; do
  specIndex=$((specIndex + 1))
  echo
  printf '════════════════════════════════════════════════════════════\n'
  log "spec $specIndex of $specCount: $slug"
  printf '════════════════════════════════════════════════════════════\n'

  # Specs run strictly one at a time. The next worktree is not created until
  # this process exits — the queue is a queue, not a fan-out.

  # A queue entry may be an abbreviation of the directory name — "002" for
  # "002-swiftui-snapshot-engine". Resolve it, but only when it is unambiguous;
  # guessing between two specs at 3am is worse than skipping one.
  queueEntry="$slug"
  if [[ ! -f "specs/$slug/SPEC.md" ]]; then
    matchCount=0
    for candidate in specs/"$slug"*/; do
      [[ -f "$candidate/SPEC.md" ]] || continue
      matchCount=$((matchCount + 1))
      resolvedSlug="$(basename "$candidate")"
    done

    if [[ $matchCount -eq 1 ]]; then
      log "resolved '$slug' to '$resolvedSlug'"
      slug="$resolvedSlug"
    elif [[ $matchCount -gt 1 ]]; then
      log "'$slug' matches $matchCount specs — too ambiguous to pick one, skipping"
      printf '\n## %s — SKIPPED\n\n`%s` matches %d spec directories; name it in full.\n' \
        "$queueEntry" "$queueEntry" "$matchCount" >> "$runLog"
      markQueueItem "$queueEntry" "!"
      skippedCount=$((skippedCount + 1))
      continue
    else
      log "no specs/$slug/SPEC.md — skipping"
      printf '\n## %s — SKIPPED\n\nNo `specs/%s/SPEC.md`.\n' "$queueEntry" "$queueEntry" >> "$runLog"
      markQueueItem "$queueEntry" "!"
      skippedCount=$((skippedCount + 1))
      continue
    fi
  fi

  # The budget gate sits here, between specs, because this is the only point
  # where stopping costs nothing: the previous spec is shipped and the next has
  # not started. Checking mid-spec would mean abandoning work in progress.
  budgetUsed=$("$SCRIPT_DIR/budget.sh" --json 2>/dev/null | jq -r '.billable_tokens // 0')
  log "budget: $budgetUsed / $budgetTokens tokens used in the trailing 5h"

  if ! "$SCRIPT_DIR/budget.sh" --check "$budgetTokens" >/dev/null 2>&1; then
    log "budget reached — stopping before $slug"
    printf '\n## Stopped before %s\n\nUsage budget for the 5-hour window was reached.\nThe remaining reserve is left for writing the artifact.\n' \
      "$slug" >> "$runLog"
    break
  fi

  worktreePath="$(dirname "$repoPath")/wt-$slug"
  branchName="spec/$slug"

  if $dryRun; then
    log "would create $worktreePath on $branchName"
    log "would run: claude -p '/overnight-spec-runner $slug'"
    continue
  fi

  # -- State reconciliation ------------------------------------------------
  # What is actually true about this spec, asked of git and GitHub rather than
  # of QUEUE.md. The old code skipped on `[[ -e $worktreePath ]]` alone, which
  # cannot tell finished work from an abandoned directory, and the queue mark
  # it trusted instead was the very thing that had been written wrongly.
  specState=$("$SCRIPT_DIR/spec-state.sh" --json "$repoPath" "$slug" 2>/dev/null)
  if [[ -z "$specState" ]]; then
    log "could not determine the state of $slug — skipping rather than guessing"
    markQueueItem "$queueEntry" "!"
    skippedCount=$((skippedCount + 1))
    continue
  fi

  stateVerdict=$(printf '%s' "$specState" | jq -r '.verdict')
  stateSafeToStart=$(printf '%s' "$specState" | jq -r '.safe_to_start')
  stateCommitsAhead=$(printf '%s' "$specState" | jq -r '.commits_ahead')
  stateDirtyFiles=$(printf '%s' "$specState" | jq -r '.dirty_files')
  statePullRequest=$(printf '%s' "$specState" | jq -r '.pull_request_url')
  stateWorktreeRegistered=$(printf '%s' "$specState" | jq -r '.worktree_registered')
  stateBranchExists=$(printf '%s' "$specState" | jq -r '.branch_exists')

  log "state: $stateVerdict (commits ahead $stateCommitsAhead, uncommitted $stateDirtyFiles)"

  case "$stateVerdict" in
    SHIPPED)
      # A pull request already exists. This is the only verdict that means
      # genuinely done, and it is now established by asking GitHub rather than
      # by reading a checkbox this script wrote itself.
      log "already shipped: $statePullRequest — marking done and moving on"
      printf '\n## %s — ALREADY SHIPPED\n\nA pull request already exists: %s\nNothing to do; the queue mark was stale.\n' \
        "$slug" "$statePullRequest" >> "$runLog"
      markQueueItem "$queueEntry" "x"
      shippedCount=$((shippedCount + 1))
      continue
      ;;

    COMMITTED|LOCAL-ONLY)
      # Committed work with no pull request. This used to halt alongside DIRTY,
      # asking the orchestrator to read the diff and decide — but by the time
      # work is committed that decision has already been made and acted on by
      # whoever committed it. What is missing is purely mechanical: push the
      # branch if it is unpushed, then open the pull request. Halting here cost
      # a whole second /overnight invocation to re-make a settled decision.
      #
      # If the work turns out not to be green, that is what the verify/fix
      # cycle below is for. Nothing is being trusted that is not checked: the
      # ship phase's claim is still verified against GitHub afterwards, exactly
      # as it is on the normal path.
      log "$slug holds committed work with no pull request ($stateVerdict) — finishing it"

      if [[ "$stateWorktreeRegistered" != "true" || ! -d "$worktreePath" ]]; then
        # The commits exist on the branch but the worktree they were made in is
        # gone. Recreate it on that same branch — checking the branch out
        # rather than creating one, so the existing commits come with it.
        log "worktree is missing — checking out the existing branch $branchName"
        git worktree prune >/dev/null 2>&1
        if ! git worktree add "$worktreePath" "$branchName" 2>&1 | tail -3; then
          log "could not check out $branchName — skipping"
          markQueueItem "$queueEntry" "!"
          skippedCount=$((skippedCount + 1))
          continue
        fi
      fi

      if [[ ! -d "$worktreePath" ]]; then
        log "worktree was not created at $worktreePath — skipping"
        markQueueItem "$queueEntry" "!"
        skippedCount=$((skippedCount + 1))
        continue
      fi

      checkpointPath="$repoPath/$runDirectory/logs/$slug.checkpoint.json"
      printf '{"slug":"%s","branch":"%s","worktree":"%s","started_at":"%s","resumed_from":"%s","phases":[]}\n' \
        "$slug" "$branchName" "$worktreePath" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$stateVerdict" > "$checkpointPath"

      export OVERNIGHT_WORKTREE="$worktreePath"
      specLog="$repoPath/$runDirectory/logs/$slug.log"

      if [[ "$stateVerdict" == "LOCAL-ONLY" ]]; then
        pushInstruction="Push this branch with 'git push -u origin $branchName', then open"
      else
        pushInstruction="The branch is already pushed. Open"
      fi

      runPhase ship \
        "The work for this spec is already committed on $branchName ($stateCommitsAhead commits) but no pull request covers it. $pushInstruction a pull request with 'gh pr create'. Read the diff against the base branch first so the description matches what is actually there. Title from the spec; body should cover what was built and anything a reviewer should know. Do NOT merge — the user reviews and merges. End your reply with a single line: SPEC-PR: <url>"

      # Same rule as the normal ship path: a phase's claim about what it did is
      # not evidence. Ask GitHub.
      resumeState=$("$SCRIPT_DIR/spec-state.sh" --json "$repoPath" "$slug" 2>/dev/null)
      resumeVerdict=$(printf '%s' "$resumeState" | jq -r '.verdict // "UNKNOWN"')
      resumePullRequest=$(printf '%s' "$resumeState" | jq -r '.pull_request_url // ""')

      unset OVERNIGHT_WORKTREE

      if [[ "$resumeVerdict" == "SHIPPED" && -n "$resumePullRequest" ]]; then
        log "SHIPPED — $resumePullRequest"
        printf -- '- %s  %s  %s\n' "$(date '+%H:%M:%S')" "$slug" "$resumePullRequest" \
          >> "$runDirectory/shipped.md"
        {
          printf '\n## %s — SHIPPED (resumed)\n\n' "$slug"
          printf 'Committed work was already on `%s` (state: **%s**) with no pull\n' \
            "$branchName" "$stateVerdict"
          printf 'request. This run opened one rather than stopping to ask.\n\n'
          printf 'Pull request: %s\n' "$resumePullRequest"
        } >> "$runLog"
        checkpointField result "SHIPPED"
        checkpointField pull_request "$resumePullRequest"
        markQueueItem "$queueEntry" "x"
        shippedCount=$((shippedCount + 1))
      else
        # The mechanical step did not work. That is genuinely worth a human's
        # attention, so this halts the way the old shared arm always did.
        log "could not open a pull request for $slug (state: $resumeVerdict) — stopping the run"
        {
          printf '\n## %s — NEEDS A DECISION\n\n' "$slug"
          printf 'Committed work sits on `%s` (state was **%s**) with no pull\n' \
            "$branchName" "$stateVerdict"
          printf 'request. This run tried to open one, and afterwards the state was\n'
          printf '**%s** — so it did not work.\n\n' "$resumeVerdict"
          printf 'Worktree: `%s`\n\n' "$worktreePath"
          printf 'Resolve it with `/overnight %s`. The phase log is at\n' "$slug"
          printf '`%s/logs/%s.ship.jsonl`.\n' "$runDirectory" "$slug"
        } >> "$runLog"
        checkpointField result "BLOCKED"
        checkpointField block_reason "ship phase left the spec at $resumeVerdict"
        markQueueItem "$queueEntry" "?"
        skippedCount=$((skippedCount + 1))
        halted=true
        haltReason="$slug could not be shipped from its committed state"
        break
      fi
      continue
      ;;

    DIRTY)
      # Uncommitted work. Unlike the committed verdicts above, this one is
      # genuinely ambiguous: the changes could be half-applied, abandoned, or
      # complete, and only reading the diff can tell. That is a judgment call,
      # which is the orchestrator's job, not this script's. Guessing wrong
      # either duplicates work or destroys it, so it stops.
      log "$slug holds uncommitted work ($stateVerdict) — stopping the run"
      {
        printf '\n## %s — NEEDS A DECISION\n\n' "$slug"
        printf 'State: **%s** — %s commits ahead of base, %s uncommitted files.\n\n' \
          "$stateVerdict" "$stateCommitsAhead" "$stateDirtyFiles"
        printf 'There is real work here that no pull request covers, so this run\n'
        printf 'left it alone rather than starting over on top of it or discarding it.\n\n'
        printf 'Worktree: `%s`\nBranch: `%s`\n\n' "$worktreePath" "$branchName"
        printf 'Resolve it with `/overnight %s`, which reads the work and decides\n' "$slug"
        printf 'whether to resume, salvage or restart it.\n\n'
        printf 'The run stopped here rather than continuing to later specs. The queue\n'
        printf 'is ordered, and a spec that is not finished is not a spec to build on.\n'
      } >> "$runLog"
      markQueueItem "$queueEntry" "?"
      skippedCount=$((skippedCount + 1))
      # Stop the whole run, not just this spec.
      #
      # The queue is ordered and later specs routinely build on earlier ones —
      # 003's tests exercise what 002 built. Carrying on past a spec whose work
      # is unfinished and unverified means the next spec branches from a base
      # that does not contain what it expects, and its verdicts are then
      # meaningless whichever way they go. An unresolved spec is a wall, not a
      # gap to step around.
      halted=true
      haltReason="$slug holds unshipped work ($stateVerdict) and needs a decision"
      break
      ;;

    EMPTY)
      # Branch and/or worktree exist but nothing was ever accomplished in them
      # — a spec that died before its first commit. There is nothing to lose,
      # so reclaim the leftovers and run it properly.
      log "$slug has an empty branch/worktree from a previous run — reclaiming it"
      if [[ "$stateWorktreeRegistered" == "true" ]]; then
        git worktree remove --force "$worktreePath" >/dev/null 2>&1 \
          || log "could not remove the stale worktree; continuing anyway"
      elif [[ -d "$worktreePath" ]]; then
        rm -rf "$worktreePath"
      fi
      git worktree prune >/dev/null 2>&1
      if [[ "$stateBranchExists" == "true" ]]; then
        git branch -D "$branchName" >/dev/null 2>&1 \
          || log "could not delete the empty branch $branchName; continuing anyway"
      fi
      ;;

    ABSENT)
      : # Nothing exists yet. The normal path.
      ;;
  esac

  log "creating worktree $worktreePath on $branchName"
  if ! git worktree add "$worktreePath" -b "$branchName" 2>&1 | tail -3; then
    log "could not create the worktree — skipping"
    markQueueItem "$queueEntry" "!"
    skippedCount=$((skippedCount + 1))
    continue
  fi

  # The pipe above means $? is tail's status, so confirm the worktree really is
  # there. A silent failure here would run the whole spec in the wrong
  # directory — against the user's main checkout.
  if [[ ! -d "$worktreePath" ]]; then
    log "worktree was not created at $worktreePath — skipping"
    markQueueItem "$queueEntry" "!"
    skippedCount=$((skippedCount + 1))
    continue
  fi

  # Open the checkpoint now that the spec is genuinely starting.
  checkpointPath="$repoPath/$runDirectory/logs/$slug.checkpoint.json"
  printf '{"slug":"%s","branch":"%s","worktree":"%s","started_at":"%s","phases":[]}\n' \
    "$slug" "$branchName" "$worktreePath" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$checkpointPath"

  # A worktree is a fresh checkout, so gitignored files the build needs are not
  # in it. .worktreeinclude only applies to worktrees Claude Code creates, so
  # honour it here by hand.
  if [[ -f .worktreeinclude ]]; then
    while IFS= read -r pattern; do
      [[ -n "$pattern" && "$pattern" != \#* ]] || continue
      for sourceFile in $pattern; do
        [[ -e "$sourceFile" ]] || continue
        mkdir -p "$worktreePath/$(dirname "$sourceFile")"
        cp -R "$sourceFile" "$worktreePath/$sourceFile" 2>/dev/null
      done
    done < .worktreeinclude
    log "copied .worktreeinclude files into the worktree"
  fi

  specLog="$repoPath/$runDirectory/logs/$slug.log"
  log "starting claude in $worktreePath"
  log "raw stream: $specLog.jsonl"
  echo

  # Confine the guardrail hook to this worktree. The hook denies any command
  # whose working directory resolves outside it, which is the backstop beneath
  # every git pattern it matches.
  export OVERNIGHT_WORKTREE="$worktreePath"

  specStart=$(date +%s)

  # Each phase is its own `claude -p` process. That is not ceremony: the skills
  # carry `disable-model-invocation`, so one session cannot call them as tools —
  # and more importantly, QA and review are only worth anything with genuinely
  # fresh context. A session that just wrote the code is the least reliable
  # judge of it. Separate processes make "fresh eyes" literal rather than
  # aspirational.
  #
  # stream-json emits one JSON event per tool call, per message, per result. The
  # raw stream goes to a .jsonl for forensics; render-stream.py turns it into a
  # readable feed so the run can be watched while it happens.


  # -- Implement -----------------------------------------------------------
  runPhase implement "/implement-spec $slug"

  # A dead implement phase makes everything downstream meaningless: there is
  # nothing to test, QA or review. Stop here rather than burning five more
  # invocations to discover the same thing five more times.
  if ! $phaseHealthy; then
    log "implement did not run ($phaseUnhealthyReason) — abandoning this spec"
    specResult="BLOCKED"
    blockReason="the implement phase did not run: $phaseUnhealthyReason"
    implementFailed=true
  else
    implementFailed=false
  fi

  # -- Verify, fix, repeat -------------------------------------------------
  # Three attempts, then stop. Three rounds of fresh-eyes verification failing
  # means it is stuck in a way another identical round will not solve, and the
  # remaining budget is better spent on the next spec.
  attempt=0
  if ! $implementFailed; then
    specResult="BLOCKED"
    blockReason="did not reach a green state"
  fi
  qaSummary=""
  suggestionCount=0

  while (( attempt < MAX_FIX_ATTEMPTS )) && ! $implementFailed && ! $runExhausted; do
    attempt=$((attempt + 1))
    log "attempt $attempt of $MAX_FIX_ATTEMPTS"

    # Tests first: cheapest and most objective, so a failure here makes the
    # other two moot for this attempt.
    runPhase "tests-$attempt" \
      "Run this project's test, lint and typecheck commands from CLAUDE.md's '## Build & Validation' block. Report exactly what you ran and what you observed. End your reply with a single line: TESTS: PASS or TESTS: FAIL"
    testsOutput="$phaseOutput"

    if ! $runExhausted; then
      runPhase "qa-$attempt" "/qa $slug"
      qaOutput="$phaseOutput"
    else
      qaOutput=""
    fi

    if ! $runExhausted; then
      runPhase "review-$attempt" "/local-code-review"
      reviewOutput="$phaseOutput"
    else
      reviewOutput=""
    fi

    # Triage. Must-fix: failing tests, a QA FAIL, or any review bug.
    # Never-fix: suggestions — those are the user's to judge in the morning.
    #
    # Every verdict must be affirmative. A phase that did not say PASS did not
    # pass, whether it said FAIL, said nothing, or never ran — the old code
    # collapsed all three onto "not FAIL" and therefore onto green.
    testsVerdict=$(readVerdict "$testsOutput" "TESTS")
    qaVerdict=$(readVerdict "$qaOutput" "QA-VERDICT")
    bugCount=$(readBugCount "$reviewOutput")

    qaSummary=$(printf '%s' "$qaOutput" | grep -E '^QA-CRITERIA:' | tail -1 \
      | sed -E 's/^QA-CRITERIA:[[:space:]]*//' || true)
    suggestionCount=$(printf '%s' "$reviewOutput" | grep -E '^REVIEW-SUGGESTIONS:' | tail -1 \
      | sed -E 's/^REVIEW-SUGGESTIONS:[[:space:]]*//; s/[^0-9].*$//' || true)
    suggestionCount="${suggestionCount:-0}"

    # QA concerns: things QA saw, judged non-blocking, and passed anyway —
    # most often a visual difference in a snapshot it decided was cosmetic.
    # They must not change the verdict, and they must not evaporate either.
    # The skill has always told QA to emit these; nothing read them, so a
    # concern raised on a passing spec died in the phase log and never
    # reached the morning. File them where the report already looks.
    qaConcerns=$(printf '%s' "$qaOutput" | grep -E '^QA-CONCERN:' || true)
    if [[ -n "$qaConcerns" ]]; then
      concernCount=$(printf '%s\n' "$qaConcerns" | grep -c . || true)
      log "qa raised $concernCount concern(s) — filing them for the report"
      {
        printf '\n## %s — QA concerns (attempt %s)\n\n' "$slug" "$attempt"
        printf 'QA passed these but flagged them for a human to look at.\n\n'
        printf '%s\n' "$qaConcerns" | sed -E 's/^QA-CONCERN:[[:space:]]*/- /'
      } >> "$repoPath/$runDirectory/suggestions.md"
    fi

    log "triage: tests=$testsVerdict, qa=$qaVerdict, bugs=$bugCount, suggestions=$suggestionCount"

    # A session limit anywhere in the attempt ends the run. Continuing would
    # score phases that never executed.
    if $runExhausted; then
      specResult="BLOCKED"
      blockReason="the session limit was reached during attempt $attempt"
      exhaustedAtSpec="$slug"
      exhaustedAtPhase="attempt $attempt"
      log "session limit reached mid-attempt — stopping"
      break
    fi

    if [[ "$testsVerdict" == "PASS" && "$qaVerdict" == "PASS" && "$bugCount" == "0" ]]; then
      specResult="GREEN"
      break
    fi

    # Distinguish "verified and found wanting" from "never answered". Both
    # block, but only the first is worth spending a fix attempt on — a fix
    # phase cannot act on a verdict that was never given.
    unansweredVerdicts=""
    [[ "$testsVerdict" == "INDETERMINATE" ]] && unansweredVerdicts="$unansweredVerdicts tests"
    [[ "$qaVerdict" == "INDETERMINATE" ]] && unansweredVerdicts="$unansweredVerdicts qa"
    [[ "$bugCount" == "INDETERMINATE" ]] && unansweredVerdicts="$unansweredVerdicts review"

    if [[ -n "$unansweredVerdicts" ]]; then
      log "no verdict from:$unansweredVerdicts — treating as a failure, not a pass"
    fi

    if (( attempt >= MAX_FIX_ATTEMPTS )); then
      blockReason="still failing after $MAX_FIX_ATTEMPTS attempts (tests=$testsVerdict, qa=$qaVerdict, bugs=$bugCount)"
      [[ -n "$unansweredVerdicts" ]] && blockReason="$blockReason; no verdict from:$unansweredVerdicts"
      log "out of attempts — marking BLOCKED"
      break
    fi

    # From the second attempt on, tell the fix phase to look outward before
    # trying again.
    #
    # The first failure is usually a plain mistake and the fix is obvious from
    # the verdict alone. A failure that survives a fix attempt is different: it
    # often means the approach is fighting the framework rather than that the
    # code is careless — a snapshot API that needs a host application, a test
    # runner that will not see async assertions, a simulator that has to be
    # warmed. Those have known community answers, and a session with no memory
    # of the first attempt will otherwise reach for the same idea again.
    #
    # Deliberately not on attempt 1: searching every failure would spend budget
    # on problems the verdict already explains.
    searchGuidance=""
    if (( attempt >= 2 )); then
      searchGuidance="

This is attempt $attempt — the previous fix did not clear it. Before changing
any more code, search the web for how this is normally solved: the exact error
text, the framework or tool involved, and what the community does about it.
Check the project's own issue tracker and discussions too.

A failure that survives a fix attempt is more often an approach fighting the
framework than careless code, so look for the established pattern before
inventing another workaround. If what you find contradicts the current
approach, say so plainly and follow the evidence rather than patching around
it. If the search turns up nothing useful, say that too and proceed on your own
reasoning — do not stall on it.

Record what you searched, what you found, and how it changed your fix in
specs/$slug/implementation-notes.md, so the morning report can explain why the
approach changed and the next attempt does not repeat the search."
    fi

    runPhase "fix-$attempt" \
      "Verification failed. Fix every blocking issue below, then commit. Do NOT act on anything labelled a suggestion — append those to $repoPath/$runDirectory/suggestions.md under a '## $slug' heading instead, and leave that code alone.$searchGuidance

TEST OUTPUT:
$testsOutput

QA:
$qaOutput

CODE REVIEW:
$reviewOutput"
  done

  # -- Ship or block -------------------------------------------------------
  if [[ "$specResult" == "GREEN" ]]; then
    runPhase ship \
      "All verification passed. Push this branch with 'git push -u origin $branchName' and open a pull request with 'gh pr create'. Title from the spec; body should cover what was built, the QA result, and any concerns. Do NOT merge — the user reviews and merges. End your reply with a single line: SPEC-PR: <url>"

    claimedPullRequestUrl=$(printf '%s' "$phaseOutput" | grep -E '^SPEC-PR:' | tail -1 \
      | sed -E 's/^SPEC-PR:[[:space:]]*//; s/[[:space:]]+$//')

    # SHIPPED used to be set unconditionally, purely because the ship phase had
    # been invoked. On 2026-08-25 that phase returned a rate-limit banner
    # having called no tools, and the spec was recorded as shipped with an
    # empty URL — the blank after the dash in the log was the system saying so,
    # and nothing was listening.
    #
    # A phase's claim about what it did is not evidence. Ask git and GitHub.
    shipState=$("$SCRIPT_DIR/spec-state.sh" --json "$repoPath" "$slug" 2>/dev/null)
    shipVerdict=$(printf '%s' "$shipState" | jq -r '.verdict // "UNKNOWN"')
    pullRequestUrl=$(printf '%s' "$shipState" | jq -r '.pull_request_url // ""')

    if [[ "$shipVerdict" == "SHIPPED" && -n "$pullRequestUrl" ]]; then
      specResult="SHIPPED"
      log "ship verified: $pullRequestUrl"
      # Real-time visibility: a confirmed pull request is appended the moment
      # it is confirmed, so a check-in never depends on a summary written hours
      # later that this run has shown can be wrong.
      printf -- '- %s  %s  %s\n' "$(date '+%H:%M:%S')" "$slug" "$pullRequestUrl" \
        >> "$runDirectory/shipped.md"
    else
      specResult="BLOCKED"
      pullRequestUrl=""
      if [[ -n "$claimedPullRequestUrl" ]]; then
        blockReason="the ship phase reported $claimedPullRequestUrl but no pull request exists for $branchName (state: $shipVerdict)"
      else
        blockReason="the ship phase did not open a pull request (state: $shipVerdict)"
      fi
      log "ship NOT verified — $blockReason"
    fi
  else
    # A branch someone can look at is worth far more than a discarded one, even
    # broken — so commit and push, but open no pull request. A PR signals
    # "ready for review", and this is not.
    # Salvage needs a working session. When the run died because the account
    # is out of budget, invoking claude again returns another banner and the
    # work stays uncommitted — which is exactly how spec 002's implementation
    # was left stranded. Say so in the log instead of pretending to salvage.
    if $runExhausted; then
      log "skipping salvage — the session limit is what stopped this spec"
      blockReason="$blockReason (salvage skipped: no session budget left)"
    else
      runPhase salvage \
        "This spec could not reach a green state: $blockReason. Commit any work in progress and push the branch with 'git push -u origin $branchName'. Do NOT open a pull request. Then append a section to $repoPath/$runDirectory/RUN.md under a '## $slug' heading covering: which criteria or bugs never cleared, what was tried in each attempt, your best read on why it did not work, and what you would try next."
    fi
    pullRequestUrl=""
  fi

  specDuration=$(( $(date +%s) - specStart ))
  unset OVERNIGHT_WORKTREE

  checkpointField result "$specResult"
  [[ -n "$pullRequestUrl" ]] && checkpointField pull_request "$pullRequestUrl"
  [[ "$specResult" != "SHIPPED" ]] && checkpointField block_reason "$blockReason"

  case "$specResult" in
    SHIPPED)
      log "SHIPPED in ${specDuration}s — $pullRequestUrl"
      markQueueItem "$queueEntry" "x"
      shippedCount=$((shippedCount + 1))
      ;;
    BLOCKED)
      log "BLOCKED after ${specDuration}s"
      markQueueItem "$queueEntry" "!"
      blockedCount=$((blockedCount + 1))
      ;;
    *)
      # No verdict at all: the process died, ran out of window, or was killed.
      # Treated as blocked, because the one thing worse than a blocked spec is
      # a spec quietly recorded as done when nobody knows what happened.
      log "no verdict — treating as BLOCKED (see $specLog)"
      specResult="BLOCKED"
      markQueueItem "$queueEntry" "!"
      blockedCount=$((blockedCount + 1))
      ;;
  esac

  {
    printf '\n## %s — %s\n\n' "$slug" "$specResult"
    printf -- '- Duration: %dm %ds\n' $((specDuration / 60)) $((specDuration % 60))
    printf -- '- Worktree: `%s`\n' "$worktreePath"
    printf -- '- Branch: `%s`\n' "$branchName"
    [[ -n "$pullRequestUrl" ]] && printf -- '- Pull request: %s\n' "$pullRequestUrl"
    printf -- '- Log: `%s`\n' "$specLog"
    [[ "$specResult" != "SHIPPED" && -n "$blockReason" ]] \
      && printf -- '- Reason: %s\n' "$blockReason"
    grep -E '^SPEC-(ATTEMPTS|QA|SUGGESTIONS|REASON):' "$specLog" \
      | sed 's/^SPEC-/- /' || true
  } >> "$runLog"

  checkpointPath=""

  # A spec that did not ship stops the run, for the same reason an unresolved
  # one does: the queue is ordered, later specs build on earlier ones, and
  # verifying 003 against a base that never got 002 tells you nothing. The old
  # behaviour — carry on and tally the failures at the end — optimised for
  # getting through the list, which is the wrong goal when the list has
  # dependencies in it.
  if [[ "$specResult" != "SHIPPED" ]] && ! $runExhausted; then
    log "$slug did not ship — stopping the run rather than building on it"
    {
      printf '\nThe run stopped here. `%s` did not ship, and the specs after it\n' "$slug"
      printf 'in the queue are left pending rather than built on top of an\n'
      printf 'unverified base.\n'
    } >> "$runLog"
    halted=true
    haltReason="$slug did not ship ($blockReason)"
    break
  fi

  # The session limit ends the run, not just the spec. Every remaining phase
  # would return instantly having done nothing, and the old code drove the
  # whole queue that way — twelve dead invocations recorded as two shipped
  # specs. Stop, and say precisely where it stopped.
  if $runExhausted; then
    log "session limit reached — stopping the run"
    {
      printf '\n## Run cut short — session limit\n\n'
      printf 'The account hit its session limit'
      [[ -n "$exhaustionResetsAt" ]] && printf ', which resets at **%s**' "$exhaustionResetsAt"
      printf '.\n\n'
      printf 'Stopped during `%s`' "$slug"
      [[ -n "$exhaustedAtPhase" ]] && printf ' at %s' "$exhaustedAtPhase"
      printf '. Nothing after this point ran, and nothing\n'
      printf 'has been marked shipped on the strength of a phase that did not execute.\n\n'
      printf 'Specs still pending in the queue are left unchecked. Re-run with\n'
      printf '`/overnight` once the limit resets; it reads the checkpoints in\n'
      printf '`%s/logs/` and resumes where this stopped.\n' "$runDirectory"
    } >> "$runLog"
    break
  fi
done

# ---------------------------------------------------------------------------
# The morning report
# ---------------------------------------------------------------------------

echo
log "── done ──"
log "shipped $shippedCount, blocked $blockedCount, skipped $skippedCount"

# Anything still unchecked in the queue. After an exhausted run this is the
# honest answer to "what is left", and it is what a resuming session picks up.
remainingSpecs=()
while IFS= read -r queueLine; do
  [[ -n "$queueLine" ]] && remainingSpecs+=("$queueLine")
done < <(readQueue)

{
  printf '\n---\n\nFinished %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'Shipped %d, blocked %d, skipped %d.\n' \
    "$shippedCount" "$blockedCount" "$skippedCount"
  if $halted; then
    printf '\nRun stopped early: %s.\n' "$haltReason"
  fi
  if [[ ${#remainingSpecs[@]:-0} -gt 0 ]]; then
    printf '\nStill pending: %d spec(s) — ' "${#remainingSpecs[@]}"
    printf '%s ' "${remainingSpecs[@]}"
    printf '\n'
  fi
} >> "$runLog"

"$SCRIPT_DIR/budget.sh" || true

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------
# Write the report tonight if there is budget for it, and defer it to the
# morning if there is not.
#
# The report is the deliverable — the code sits on branches nobody has read.
# But generating it costs a real Claude session, and the one ending worse than
# a partial night is a partial night whose report never got written because the
# window was already dry. So it is attempted only when three things hold: the
# queue actually drained, the session limit was never hit, and there is budget
# left over. Otherwise the run says plainly that the report is owed, and the
# morning `/overnight` picks it up.
reportCommand="/overnight-report $RUN_DATE $runId"
reportDeferredReason=""

if $runExhausted; then
  reportDeferredReason="the session limit was reached — no budget to write it"
elif $halted; then
  reportDeferredReason="the run stopped early ($haltReason)"
elif [[ ${#remainingSpecs[@]:-0} -gt 0 ]]; then
  reportDeferredReason="${#remainingSpecs[@]} spec(s) are still pending; the report covers a finished run"
elif [[ $shippedCount -eq 0 && $blockedCount -eq 0 ]]; then
  reportDeferredReason="nothing ran, so there is nothing to report"
elif ! "$SCRIPT_DIR/budget.sh" --check "$budgetTokens" >/dev/null 2>&1; then
  reportDeferredReason="the usage budget is spent"
fi

if [[ -z "$reportDeferredReason" ]]; then
  echo
  log "queue drained with budget to spare — writing the report now"

  reportStream="$repoPath/$runDirectory/logs/report.jsonl"
  (
    cd "$repoPath" || exit 2
    claude -p "$reportCommand" \
      --permission-mode auto \
      --output-format stream-json \
      --verbose \
      2>>"$runDirectory/logs/report.log"
  ) | tee "$reportStream" | "$SCRIPT_DIR/render-stream.py" "report"

  reportHealth=$(python3 "$SCRIPT_DIR/extract-result.py" --health "$reportStream" 2>/dev/null)
  reportExhausted=$(printf '%s' "$reportHealth" | jq -r '.exhausted // false' 2>/dev/null)
  reportIsError=$(printf '%s' "$reportHealth" | jq -r '.is_error // false' 2>/dev/null)

  if [[ "$reportExhausted" == "true" || "$reportIsError" == "true" ]]; then
    log "the report phase did not complete — it is still owed"
    printf '\n## Report — not written\n\nThe report phase did not complete. Run `%s` to write it.\n' \
      "$reportCommand" >> "$runLog"
  else
    log "report written"
  fi
else
  log "report deferred: $reportDeferredReason"
  {
    printf '\n## Report — deferred\n\n'
    printf 'Not written tonight: %s.\n\n' "$reportDeferredReason"
    printf 'Write it with `%s`.\n' "$reportCommand"
  } >> "$runLog"
fi

echo
echo "Run:         $runId"
echo "Run record:  $runLog"
echo "Console log: $runDirectory/loop.log"
[[ -f "$runDirectory/suggestions.md" ]] && echo "Suggestions: $runDirectory/suggestions.md"
[[ -f "$runDirectory/shipped.md" ]] && echo "Shipped log: $runDirectory/shipped.md"
echo
echo "Worktrees are left in place on purpose — they hold the branches under review."
echo "After merging, clean one up with:  git worktree remove ../wt-<slug>"
echo

if [[ -n "$reportDeferredReason" ]]; then
  echo "The report was not written ($reportDeferredReason)."
  echo "Open Claude in this repo and run:"
  echo "  $reportCommand"
fi

if [[ ${#remainingSpecs[@]:-0} -gt 0 ]]; then
  echo
  echo "${#remainingSpecs[@]} spec(s) still pending. Resume with:  /overnight"
fi

# A run cut short — by the limit or by a spec needing a decision — is not a
# success, and a wrapper or cron job needs to be able to tell.
if $runExhausted || $halted; then
  exit 1
fi
exit 0
