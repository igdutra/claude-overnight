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
#   ./loop.sh <repo> [--queue <file>] [--max-specs <n>] [--budget <tokens>] [--dry-run]
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
maxSpecs="$DEFAULT_MAX_SPECS"
budgetTokens="$DEFAULT_BUDGET_TOKENS"
dryRun=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue)     queueFile="$2"; shift 2 ;;
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

runDirectory="overnight/$RUN_DATE"
mkdir -p "$runDirectory/logs"

[[ -n "$queueFile" ]] || queueFile="$runDirectory/QUEUE.md"

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
log "queue:  $queueFile ($specCount specs)"
log "budget: stop taking new specs past $budgetTokens tokens in the trailing 5h"
$dryRun && log "DRY RUN — no worktrees, no claude, no pushes"

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

runLog="$runDirectory/RUN.md"
if [[ ! -f "$runLog" ]]; then
  {
    printf '# Overnight run — %s\n\n' "$RUN_DATE"
    printf 'Started %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  } > "$runLog"
fi

shippedCount=0
blockedCount=0
skippedCount=0

specIndex=0
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

  if [[ -e "$worktreePath" ]]; then
    log "$worktreePath already exists — skipping (remove it by hand to retry)"
    markQueueItem "$queueEntry" "!"
    skippedCount=$((skippedCount + 1))
    continue
  fi

  log "creating worktree $worktreePath on $branchName"
  if ! git worktree add "$worktreePath" -b "$branchName" >/dev/null 2>&1; then
    log "could not create the worktree — skipping"
    markQueueItem "$queueEntry" "!"
    skippedCount=$((skippedCount + 1))
    continue
  fi

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

  # runPhase <name> <prompt> [extra claude args...]
  # Leaves the phase's final text in $phaseOutput and its raw stream on disk.
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
  }

  # -- Implement -----------------------------------------------------------
  runPhase implement "/implement-spec $slug"

  # -- Verify, fix, repeat -------------------------------------------------
  # Three attempts, then stop. Three rounds of fresh-eyes verification failing
  # means it is stuck in a way another identical round will not solve, and the
  # remaining budget is better spent on the next spec.
  attempt=0
  specResult="BLOCKED"
  blockReason="did not reach a green state"
  qaSummary=""
  suggestionCount=0

  while (( attempt < MAX_FIX_ATTEMPTS )); do
    attempt=$((attempt + 1))
    log "attempt $attempt of $MAX_FIX_ATTEMPTS"

    # Tests first: cheapest and most objective, so a failure here makes the
    # other two moot for this attempt.
    runPhase "tests-$attempt" \
      "Run this project's test, lint and typecheck commands from CLAUDE.md's '## Build & Validation' block. Report exactly what you ran and what you observed. End your reply with a single line: TESTS: PASS or TESTS: FAIL"
    testsOutput="$phaseOutput"

    runPhase "qa-$attempt" "/qa $slug"
    qaOutput="$phaseOutput"

    runPhase "review-$attempt" "/local-code-review"
    reviewOutput="$phaseOutput"

    # Triage. Must-fix: failing tests, a QA FAIL, or any review bug.
    # Never-fix: suggestions — those are the user's to judge in the morning.
    testsFailed=false
    printf '%s' "$testsOutput" | grep -qE '^TESTS:[[:space:]]*FAIL' && testsFailed=true

    qaFailed=false
    printf '%s' "$qaOutput" | grep -qE '^QA-VERDICT:[[:space:]]*FAIL' && qaFailed=true

    bugCount=$(printf '%s' "$reviewOutput" | grep -cE '^REVIEW-BUG:' || true)
    qaSummary=$(printf '%s' "$qaOutput" | grep -E '^QA-CRITERIA:' | tail -1 \
      | sed -E 's/^QA-CRITERIA:[[:space:]]*//' || true)
    suggestionCount=$(printf '%s' "$reviewOutput" | grep -E '^REVIEW-SUGGESTIONS:' | tail -1 \
      | sed -E 's/^REVIEW-SUGGESTIONS:[[:space:]]*//; s/[^0-9].*$//' || true)
    suggestionCount="${suggestionCount:-0}"

    log "triage: tests=$($testsFailed && echo FAIL || echo pass), qa=$($qaFailed && echo FAIL || echo pass), bugs=$bugCount, suggestions=$suggestionCount"

    if ! $testsFailed && ! $qaFailed && [[ "$bugCount" -eq 0 ]]; then
      specResult="GREEN"
      break
    fi

    if (( attempt >= MAX_FIX_ATTEMPTS )); then
      blockReason="still failing after $MAX_FIX_ATTEMPTS attempts (tests=$($testsFailed && echo FAIL || echo pass), qa=$($qaFailed && echo FAIL || echo pass), bugs=$bugCount)"
      log "out of attempts — marking BLOCKED"
      break
    fi

    runPhase "fix-$attempt" \
      "Verification failed. Fix every blocking issue below, then commit. Do NOT act on anything labelled a suggestion — append those to overnight/$RUN_DATE/suggestions.md under a '## $slug' heading instead, and leave that code alone.

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

    pullRequestUrl=$(printf '%s' "$phaseOutput" | grep -E '^SPEC-PR:' | tail -1 \
      | sed -E 's/^SPEC-PR:[[:space:]]*//; s/[[:space:]]+$//')
    specResult="SHIPPED"
  else
    # A branch someone can look at is worth far more than a discarded one, even
    # broken — so commit and push, but open no pull request. A PR signals
    # "ready for review", and this is not.
    runPhase salvage \
      "This spec could not reach a green state: $blockReason. Commit any work in progress and push the branch with 'git push -u origin $branchName'. Do NOT open a pull request. Then append a section to $repoPath/$runDirectory/RUN.md under a '## $slug' heading covering: which criteria or bugs never cleared, what was tried in each attempt, your best read on why it did not work, and what you would try next."
    pullRequestUrl=""
  fi

  specDuration=$(( $(date +%s) - specStart ))
  unset OVERNIGHT_WORKTREE

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
    grep -E '^SPEC-(ATTEMPTS|QA|SUGGESTIONS|REASON):' "$specLog" \
      | sed 's/^SPEC-/- /' || true
  } >> "$runLog"
done

# ---------------------------------------------------------------------------
# The morning report
# ---------------------------------------------------------------------------

echo
log "── done ──"
log "shipped $shippedCount, blocked $blockedCount, skipped $skippedCount"

{
  printf '\n---\n\nFinished %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'Shipped %d, blocked %d, skipped %d.\n' \
    "$shippedCount" "$blockedCount" "$skippedCount"
} >> "$runLog"

"$SCRIPT_DIR/budget.sh" || true

echo
echo "Run record:  $runLog"
echo "Suggestions: $runDirectory/suggestions.md"
echo
echo "Worktrees are left in place on purpose — they hold the branches under review."
echo "After merging, clean one up with:  git worktree remove ../wt-<slug>"
echo
echo "To publish the morning artifact, open Claude in this repo and run:"
echo "  /overnight-report $RUN_DATE"
