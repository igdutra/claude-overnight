#!/bin/bash
# test-hook.sh — verify block-dangerous-git.sh without starting a session.
#
# Three tables. BLOCK proves the guardrail catches destructive commands. ALLOW
# proves it does not strangle the run at 2am on a legitimate push — that matters
# as much as the first, since a hook that blocks everything fails differently,
# not better. GATE proves the hook is inert outside an overnight run: it only
# guards when loop.sh has exported OVERNIGHT_WORKTREE.
#
# Usage: ./test-hook.sh

set -uo pipefail

hookScript="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-dangerous-git.sh"

# The worktree the fake session is confined to, and a path outside it.
export OVERNIGHT_WORKTREE="/tmp/wt-example"
readonly INSIDE_WORKTREE="/tmp/wt-example"
readonly MAIN_CHECKOUT="/tmp/example-repo"

passedCount=0
failedCount=0

# Run one command through the hook and report whether the verdict matched.
check() {
  local expectedVerdict="$1" description="$2" command="$3"
  local workingDirectory="${4:-$INSIDE_WORKTREE}"

  local payload
  payload=$(jq -n \
    --arg command "$command" \
    --arg cwd "$workingDirectory" \
    '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$command}}')

  local output
  output=$(printf '%s' "$payload" | "$hookScript")

  local actualVerdict="allow"
  if printf '%s' "$output" | grep -q '"permissionDecision": *"deny"'; then
    actualVerdict="deny"
  fi

  if [[ "$actualVerdict" == "$expectedVerdict" ]]; then
    passedCount=$((passedCount + 1))
    printf '  \033[32m✓\033[0m %-46s %s\n' "$description" "$command"
  else
    failedCount=$((failedCount + 1))
    printf '  \033[31m✗\033[0m %-46s %s\n' "$description" "$command"
    printf '      expected %s, got %s\n' "$expectedVerdict" "$actualVerdict"
    [[ "$actualVerdict" == "deny" ]] && \
      printf '      reason: %s\n' "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  fi
}

echo
echo "MUST BLOCK"
echo

check deny "push to main"                  "git push origin main"
check deny "push to master"                "git push origin master"
check deny "force push, long flag"         "git push --force origin spec/foo"
check deny "force push, short flag"        "git push -f origin spec/foo"
check deny "force-with-lease"              "git push --force-with-lease origin spec/foo"
check deny "refspec force (leading +)"     "git push origin +HEAD:spec/foo"
check deny "bare push"                     "git push"
check deny "push with no branch named"     "git push origin"
check deny "delete remote branch"          "git push origin --delete spec/foo"

check deny "reset --hard"                  "git reset --hard"
check deny "reset --hard to a ref"         "git reset --hard HEAD~1"
check deny "bare reset"                    "git reset"
check deny "reset to a ref"                "git reset HEAD~2"
check deny "clean -fd"                     "git clean -fd"
check deny "clean -fdx"                    "git clean -fdx"
check deny "checkout ."                    "git checkout ."
check deny "restore ."                     "git restore ."
check deny "stash drop"                    "git stash drop"

check deny "rebase"                        "git rebase main"
check deny "interactive rebase"            "git rebase -i HEAD~3"
check deny "commit --amend"                "git commit --amend -m 'fix'"
check deny "branch -D"                     "git branch -D spec/foo"
check deny "tag -d"                        "git tag -d v1.0.0"
check deny "filter-branch"                 "git filter-branch --tree-filter true HEAD"

check deny "checkout main"                 "git checkout main"
check deny "switch main"                   "git switch main"
check deny "worktree remove"               "git worktree remove ../wt-foo"
check deny "merge"                         "git merge main"

check deny "git -C redirect"               "git -C /tmp/example-repo status"
check deny "GIT_DIR redirect"              "GIT_DIR=/elsewhere/.git git status"
check deny "cwd outside worktree"          "git status"                    "$MAIN_CHECKOUT"
check deny "cwd in a sibling worktree"     "ls"                            "/tmp/wt-other"

check deny "quote evasion"                 "git push origin \"main\""
check deny "extra whitespace"              "git   reset   --hard"
check deny "chained after &&"              "swift test && git reset --hard"

echo
echo "MUST ALLOW"
echo

check allow "push to the spec branch"      "git push -u origin spec/foo"
check allow "push, upstream already set"   "git push origin spec/add-login"
check allow "ordinary commit"              "git commit -m 'implement login form'"
check allow "stage files"                  "git add ."
check allow "status"                       "git status"
check allow "diff against main"            "git diff main...HEAD"
check allow "log"                          "git log --oneline -20"
check allow "create a branch"              "git checkout -b spec/foo"
check allow "switch to the spec branch"    "git switch spec/foo"
check allow "path-scoped reset"            "git reset -- src/App.swift"
check allow "path-scoped checkout"         "git checkout -- src/App.swift"
check allow "stash push"                   "git stash push -m 'wip'"
check allow "merge --abort"                "git merge --abort"
check allow "worktree list"                "git worktree list"
check allow "run tests"                    "swift test"
check allow "build"                        "xcodebuild test -scheme App"
check allow "open a pull request"          "gh pr create --fill"
check allow "read a file"                  "cat README.md"
check allow "subdirectory of worktree"     "swift test"                    "$INSIDE_WORKTREE/Sources"

echo
echo "GATE — inert outside an overnight run"
echo

# Everything above ran with OVERNIGHT_WORKTREE set. Unset it and the same
# destructive commands must sail through: outside a run the user is awake and
# supervising, and these rules would only get in their way.
unset OVERNIGHT_WORKTREE

check allow "reset --hard, no run active"   "git reset --hard"
check allow "push to main, no run active"   "git push origin main"
check allow "force push, no run active"     "git push --force origin main"
check allow "rebase, no run active"         "git rebase -i HEAD~3"
check allow "clean -fd, no run active"      "git clean -fd"
check allow "checkout main, no run active"  "git checkout main"
check allow "cwd anywhere, no run active"   "git status"   "$MAIN_CHECKOUT"

export OVERNIGHT_WORKTREE="$INSIDE_WORKTREE"

echo
if [[ $failedCount -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m, 0 failed\n\n' "$passedCount"
  exit 0
else
  printf '\033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n\n' "$passedCount" "$failedCount"
  exit 1
fi
