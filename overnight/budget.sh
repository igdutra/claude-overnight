#!/bin/bash
# budget.sh — how much of the 5-hour usage window is left.
#
# Claude Code exposes usage interactively through /usage, but there is no
# `claude usage` subcommand to call from a script. The data is on disk though:
# every assistant turn appends a record to ~/.claude/projects/*/*.jsonl carrying
# a timestamp and per-model token counts. Summing the trailing five hours across
# every project gives a usable picture of the current window.
#
# What this is and is not: a burn estimate from local session history, not an
# authoritative balance. It cannot see usage from other machines or from
# claude.ai, and Anthropic does not publish the token ceiling for a plan. So it
# reports consumption and lets the caller apply a threshold, rather than
# pretending to know a percentage remaining.
#
# Usage:
#   ./budget.sh              human-readable summary
#   ./budget.sh --json       machine-readable, for loop.sh
#   ./budget.sh --check <n>  exit 1 if the window has burned more than n tokens
#
# Exit codes: 0 under budget, 1 over (with --check), 2 could not read usage.

set -uo pipefail

readonly WINDOW_HOURS=5
readonly PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

outputFormat="human"
checkThreshold=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  outputFormat="json"; shift ;;
    --check) checkThreshold="${2:-}"; outputFormat="check"; shift 2 ;;
    *)       echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$PROJECTS_DIR" ]]; then
  echo "no transcripts at $PROJECTS_DIR" >&2
  exit 2
fi

# Walk every transcript, keep records inside the window, and total them.
#
# Only input_tokens and output_tokens are counted. Cache reads are deliberately
# excluded: they are billed differently and counting them would wildly overstate
# a long session, where the same cached prefix is re-read on every single turn.
# Cache *creation* is counted, since that is genuinely new input.
usageSummary=$(python3 - "$PROJECTS_DIR" "$WINDOW_HOURS" <<'PYEOF'
import json, os, sys, glob
from datetime import datetime, timedelta, timezone

projectsDirectory, windowHours = sys.argv[1], float(sys.argv[2])
windowStart = datetime.now(timezone.utc) - timedelta(hours=windowHours)

inputTokens = outputTokens = cacheCreationTokens = 0
turnCount = 0
earliestTimestamp = None
perModel = {}

for transcriptPath in glob.glob(os.path.join(projectsDirectory, "*", "*.jsonl")):
    # Skip files untouched since before the window; nothing in them can count.
    try:
        if datetime.fromtimestamp(os.path.getmtime(transcriptPath), timezone.utc) < windowStart:
            continue
    except OSError:
        continue

    try:
        handle = open(transcriptPath, "r", errors="replace")
    except OSError:
        continue

    with handle:
        for line in handle:
            try:
                record = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue

            message = record.get("message")
            if not isinstance(message, dict):
                continue
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue

            rawTimestamp = record.get("timestamp")
            if not rawTimestamp:
                continue
            try:
                turnTime = datetime.fromisoformat(rawTimestamp.replace("Z", "+00:00"))
            except ValueError:
                continue
            if turnTime < windowStart:
                continue

            turnInput = usage.get("input_tokens", 0) or 0
            turnOutput = usage.get("output_tokens", 0) or 0
            turnCacheCreation = usage.get("cache_creation_input_tokens", 0) or 0

            inputTokens += turnInput
            outputTokens += turnOutput
            cacheCreationTokens += turnCacheCreation
            turnCount += 1

            model = message.get("model", "unknown")
            perModel[model] = perModel.get(model, 0) + turnInput + turnOutput + turnCacheCreation

            if earliestTimestamp is None or turnTime < earliestTimestamp:
                earliestTimestamp = turnTime

billableTokens = inputTokens + outputTokens + cacheCreationTokens

# Burn rate over the observed span, not the nominal window: five minutes of
# heavy use should not read as a low hourly rate just because the window is long.
if earliestTimestamp:
    observedHours = max(
        (datetime.now(timezone.utc) - earliestTimestamp).total_seconds() / 3600.0,
        1 / 60.0,
    )
else:
    observedHours = 0.0

print(json.dumps({
    "window_hours": windowHours,
    "turns": turnCount,
    "input_tokens": inputTokens,
    "output_tokens": outputTokens,
    "cache_creation_tokens": cacheCreationTokens,
    "billable_tokens": billableTokens,
    "tokens_per_hour": round(billableTokens / observedHours) if observedHours else 0,
    "observed_hours": round(observedHours, 2),
    "oldest_turn": earliestTimestamp.isoformat() if earliestTimestamp else None,
    "by_model": perModel,
}))
PYEOF
) || { echo "failed to read usage" >&2; exit 2; }

case "$outputFormat" in
  json)
    printf '%s\n' "$usageSummary"
    ;;

  check)
    if [[ -z "$checkThreshold" ]]; then
      echo "--check needs a token threshold" >&2
      exit 2
    fi
    billable=$(printf '%s' "$usageSummary" | jq -r '.billable_tokens')
    if (( billable > checkThreshold )); then
      printf 'over budget: %s tokens used in the last %sh (threshold %s)\n' \
        "$billable" "$WINDOW_HOURS" "$checkThreshold" >&2
      exit 1
    fi
    printf 'under budget: %s / %s tokens\n' "$billable" "$checkThreshold"
    ;;

  human)
    printf '%s' "$usageSummary" | jq -r '
      "Usage in the last \(.window_hours) hours",
      "",
      "  turns          \(.turns)",
      "  input          \(.input_tokens)",
      "  output         \(.output_tokens)",
      "  cache creation \(.cache_creation_tokens)",
      "  billable       \(.billable_tokens)",
      "",
      "  burn rate      \(.tokens_per_hour) tokens/hour over \(.observed_hours)h observed",
      "  oldest turn    \(.oldest_turn // "none in window")",
      "",
      "by model:",
      (.by_model | to_entries[] | "  \(.key)  \(.value)")
    '
    echo
    echo "Counts local session history only — not usage from other machines or claude.ai."
    ;;
esac
