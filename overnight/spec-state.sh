#!/bin/bash
# spec-state.sh — what is actually true about a spec, derived from git and gh.
#
# The run of 2026-08-25 marked two specs [x] SHIPPED that had no commits, no
# pushes and no pull requests. The queue mark was written from the loop's own
# belief about what it had just done, and nothing ever checked that belief
# against the repository. So a false SHIPPED did not merely produce a wrong
# report — it poisoned recovery, because the next invocation read the mark,
# found nothing pending, and exited having done nothing.
#
# The fix is to stop treating QUEUE.md as the source of truth. It is a cache of
# a fact that is independently verifiable, and this script does the verifying.
# Every question it answers is mechanical and has a deterministic answer:
#
#   does the branch exist, locally or on the remote?
#   does it carry commits the base branch does not?
#   is there uncommitted work sitting in its worktree?
#   is there a pull request, and is it open or merged?
#
# What it deliberately does NOT do is decide what to do about the answer. That
# is a judgment call — half-applied work from an interrupted fix looks exactly
# like deliberate work in progress — and it belongs to the orchestrator.
#
# Usage:
#   ./spec-state.sh <repo> <slug>            human-readable
#   ./spec-state.sh --json <repo> <slug>     machine-readable, for loop.sh
#
# The verdict field is one of:
#   SHIPPED      a pull request exists for the branch (open or merged)
#   COMMITTED    commits ahead of base and pushed, but no pull request
#   LOCAL-ONLY   commits ahead of base, not pushed
#   DIRTY        no commits, but uncommitted work in the worktree
#   EMPTY        branch and/or worktree exist, but nothing was accomplished
#   ABSENT       no branch, no worktree — never started

set -uo pipefail

outputFormat="human"
if [[ "${1:-}" == "--json" ]]; then
  outputFormat="json"; shift
fi

repoPath="${1:-}"
slug="${2:-}"

if [[ -z "$repoPath" || -z "$slug" ]]; then
  echo "usage: ./spec-state.sh [--json] <repo> <slug>" >&2
  exit 2
fi

repoPath="$(cd "$repoPath" 2>/dev/null && pwd -P)" || {
  echo "no such directory: $repoPath" >&2; exit 2; }

cd "$repoPath" || exit 2

branchName="spec/$slug"
worktreePath="$(dirname "$repoPath")/wt-$slug"

# The base branch is whatever HEAD points at on the remote, falling back to
# main. Hardcoding main would silently misreport every repo that uses master or
# trunk, and misreporting is the exact failure being fixed here.
baseBranch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
[[ -n "$baseBranch" ]] || baseBranch="main"

branchExists=false
git show-ref --verify --quiet "refs/heads/$branchName" && branchExists=true

remoteBranchExists=false
git show-ref --verify --quiet "refs/remotes/origin/$branchName" && remoteBranchExists=true

worktreeExists=false
[[ -d "$worktreePath" ]] && worktreeExists=true

# Is this path actually a registered worktree, or just a leftover directory?
# They need different handling: git refuses to reuse a stale directory, and
# `git worktree add` on an existing branch fails differently than on a new one.
worktreeRegistered=false
if $worktreeExists; then
  git worktree list --porcelain 2>/dev/null \
    | grep -qx "worktree $worktreePath" && worktreeRegistered=true
fi

# Commits the branch carries that the base does not.
commitsAhead=0
if $branchExists; then
  commitsAhead=$(git rev-list --count "$baseBranch..$branchName" 2>/dev/null || echo 0)
fi

# Commits not yet on the remote. A branch with commits that were never pushed
# is recoverable but invisible to anyone else, which is its own failure state.
unpushedCommits=0
if $branchExists && $remoteBranchExists; then
  unpushedCommits=$(git rev-list --count "origin/$branchName..$branchName" 2>/dev/null || echo 0)
elif $branchExists && [[ "$commitsAhead" -gt 0 ]]; then
  unpushedCommits="$commitsAhead"
fi

# Uncommitted work in the worktree. This is what spec 002 was left holding: a
# fix interrupted partway through, real work, but invisible to git log and to
# every check that only looks at commits.
dirtyFileCount=0
if $worktreeRegistered; then
  # grep -c exits 1 on zero matches, so the count is read from its stdout and
  # the exit status ignored rather than chained with `||`, which would append a
  # second number to a legitimate "0".
  dirtyFileCount=$( (cd "$worktreePath" 2>/dev/null && git status --porcelain 2>/dev/null | grep -c .) 2>/dev/null )
  dirtyFileCount="${dirtyFileCount//[^0-9]/}"
  dirtyFileCount="${dirtyFileCount:-0}"
fi

# The pull request, asked of GitHub rather than of our own bookkeeping. This is
# the check whose absence let "SHIPPED" be written over a branch that had never
# been pushed.
pullRequestUrl=""
pullRequestState=""
if command -v gh >/dev/null 2>&1; then
  pullRequestJson=$(gh pr list --head "$branchName" --state all \
    --json url,state,number --limit 1 2>/dev/null || echo "")
  if [[ -n "$pullRequestJson" && "$pullRequestJson" != "[]" ]]; then
    pullRequestUrl=$(printf '%s' "$pullRequestJson" | jq -r '.[0].url // ""' 2>/dev/null)
    pullRequestState=$(printf '%s' "$pullRequestJson" | jq -r '.[0].state // ""' 2>/dev/null)
  fi
fi

# ---------------------------------------------------------------------------
# The verdict
# ---------------------------------------------------------------------------
# Ordered most-accomplished first. Each rung requires everything below it to be
# true, so the first match is the whole story.

if [[ -n "$pullRequestUrl" ]]; then
  verdict="SHIPPED"
elif [[ "$commitsAhead" -gt 0 && "$unpushedCommits" -eq 0 ]]; then
  verdict="COMMITTED"
elif [[ "$commitsAhead" -gt 0 ]]; then
  verdict="LOCAL-ONLY"
elif [[ "$dirtyFileCount" -gt 0 ]]; then
  verdict="DIRTY"
elif $branchExists || $worktreeExists; then
  verdict="EMPTY"
else
  verdict="ABSENT"
fi

# Can loop.sh proceed with this spec without a human deciding first? Only when
# there is nothing to lose: nothing started, or something started that
# accomplished literally nothing. Anything holding real work — commits, a dirty
# tree, a pull request — needs a decision, because the wrong guess either
# duplicates work or destroys it.
case "$verdict" in
  ABSENT) safeToStart=true ;;
  EMPTY)  safeToStart=true ;;
  *)      safeToStart=false ;;
esac

if [[ "$outputFormat" == "json" ]]; then
  jq -n \
    --arg slug "$slug" \
    --arg verdict "$verdict" \
    --arg branch "$branchName" \
    --arg baseBranch "$baseBranch" \
    --arg worktree "$worktreePath" \
    --arg pullRequestUrl "$pullRequestUrl" \
    --arg pullRequestState "$pullRequestState" \
    --argjson branchExists "$branchExists" \
    --argjson remoteBranchExists "$remoteBranchExists" \
    --argjson worktreeExists "$worktreeExists" \
    --argjson worktreeRegistered "$worktreeRegistered" \
    --argjson commitsAhead "${commitsAhead:-0}" \
    --argjson unpushedCommits "${unpushedCommits:-0}" \
    --argjson dirtyFileCount "${dirtyFileCount:-0}" \
    --argjson safeToStart "$safeToStart" \
    '{
      slug: $slug, verdict: $verdict, branch: $branch, base_branch: $baseBranch,
      worktree: $worktree, branch_exists: $branchExists,
      remote_branch_exists: $remoteBranchExists, worktree_exists: $worktreeExists,
      worktree_registered: $worktreeRegistered, commits_ahead: $commitsAhead,
      unpushed_commits: $unpushedCommits, dirty_files: $dirtyFileCount,
      pull_request_url: $pullRequestUrl, pull_request_state: $pullRequestState,
      safe_to_start: $safeToStart
    }'
else
  printf '%s — %s\n' "$slug" "$verdict"
  printf '  branch          %s (exists: %s, on origin: %s)\n' "$branchName" "$branchExists" "$remoteBranchExists"
  printf '  base            %s\n' "$baseBranch"
  printf '  commits ahead   %s (unpushed: %s)\n' "$commitsAhead" "$unpushedCommits"
  printf '  worktree        %s (exists: %s, registered: %s)\n' "$worktreePath" "$worktreeExists" "$worktreeRegistered"
  printf '  uncommitted     %s files\n' "$dirtyFileCount"
  if [[ -n "$pullRequestUrl" ]]; then
    printf '  pull request    %s (%s)\n' "$pullRequestUrl" "$pullRequestState"
  else
    printf '  pull request    none\n'
  fi
  printf '  safe to start   %s\n' "$safeToStart"
fi
