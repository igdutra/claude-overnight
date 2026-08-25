#!/bin/bash
# block-dangerous-git.sh — PreToolUse guardrail for unattended overnight runs.
#
# Reads a PreToolUse payload on stdin and denies destructive or scope-escaping
# commands. Always exits 0; the block is carried by the permissionDecision
# field of the JSON printed to stdout, so Claude receives a reason it can act
# on rather than a bare failure.
#
# Layers, backstop first:
#   1. the working directory must stay inside the run's worktree
#   2. no pushes to a protected branch, no force-pushes anywhere
#   3. no commands that destroy uncommitted work
#   4. no history rewriting
#   5. no leaving or dismantling the worktree
#
# Configuration is environmental so one copy serves every repository:
#   OVERNIGHT_WORKTREE   absolute path the session is confined to; when unset,
#                        the working-directory check is skipped
#   OVERNIGHT_BRANCHES   additional protected branch names, space-separated
#
# Verify without starting a session: ./test-hook.sh

set -uo pipefail

payload=$(cat)

# Emit a deny decision and stop. The reason surfaces to Claude as a tool error,
# so each one says what to do instead, not merely what was refused.
deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# No decision — hand back to the normal permission flow.
allow() {
  exit 0
}

# ---------------------------------------------------------------------------
# The gate — only guard an actual overnight run
# ---------------------------------------------------------------------------
# OVERNIGHT_WORKTREE is exported by loop.sh for the duration of one spec and by
# nothing else, so its presence is what distinguishes "a run is happening" from
# "the user is working normally".
#
# Outside a run the hook allows everything and gets out of the way. That is
# deliberate: these rules exist because nobody is watching, and the same rules
# applied to ordinary daytime work would block legitimate things — rebasing,
# amending a commit, resetting a botched experiment — that the user is perfectly
# capable of supervising themselves. A guardrail that fires when it is not
# needed teaches people to work around it, which is how it comes to be ignored
# when it does matter.

[[ -n "${OVERNIGHT_WORKTREE:-}" ]] || exit 0

toolName=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
[[ "$toolName" == "Bash" ]] || allow

command=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
[[ -n "$command" ]] || allow

workingDirectory=$(printf '%s' "$payload" | jq -r '.cwd // empty')

# Collapse whitespace so spacing cannot hide a keyword, and drop quotes that
# would otherwise break a word-boundary match (git p"u"sh stays visible).
normalized=$(printf '%s' "$command" | tr '\n\t' '  ' | tr -s ' ' | tr -d "\"'")

matches() {
  printf '%s' "$normalized" | grep -Eq "$1"
}

# ---------------------------------------------------------------------------
# Layer 1 — stay inside the worktree
# ---------------------------------------------------------------------------
# The backstop beneath every rule below: a destructive command that slips past
# a pattern still cannot reach the main checkout from here.

confinementRoot="$OVERNIGHT_WORKTREE"
if [[ -n "$workingDirectory" ]]; then
  canonicalRoot=$(cd "$confinementRoot" 2>/dev/null && pwd -P) || canonicalRoot="$confinementRoot"
  canonicalCwd=$(cd "$workingDirectory" 2>/dev/null && pwd -P) || canonicalCwd="$workingDirectory"

  if [[ "$canonicalCwd" != "$canonicalRoot" && "$canonicalCwd" != "$canonicalRoot"/* ]]; then
    deny "Working directory $canonicalCwd is outside this run's worktree ($canonicalRoot). Overnight runs stay inside the worktree — cd back before retrying."
  fi
fi

# Redirecting git elsewhere would defeat the check above.
if matches '(^|[;&|] )git +(.* )?(-C +|--git-dir|--work-tree)'; then
  deny "Redirecting git outside the worktree (-C / --git-dir / --work-tree) is blocked. Run git from inside the worktree."
fi
if matches '(^|[;&|] )(GIT_DIR|GIT_WORK_TREE)='; then
  deny "Setting GIT_DIR or GIT_WORK_TREE is blocked — it would point git at another checkout."
fi

# ---------------------------------------------------------------------------
# Layer 2 — protected branches and force-pushes
# ---------------------------------------------------------------------------

protectedBranches="main master develop release ${OVERNIGHT_BRANCHES:-}"

if matches '(^|[;&|] )git +push'; then
  if matches 'git +push.*(--force|--force-with-lease|--force-if-includes| -f( |$))'; then
    deny "Force-pushing is blocked during overnight runs. If the remote branch diverged, stop and leave it for review."
  fi

  # A leading + on a refspec is a force push wearing a disguise.
  if matches 'git +push.*[: ]\+[A-Za-z0-9_/.-]+'; then
    deny "That refspec force-pushes (leading +). Push the feature branch normally instead."
  fi

  for branch in $protectedBranches; do
    if matches "git +push([^;&|]*[ :])$branch( |\$)"; then
      deny "Pushing to '$branch' is blocked. Overnight runs push only their own spec/* branch and open a pull request for review."
    fi
  done

  # Deleting a remote branch, in either spelling.
  if matches 'git +push +[A-Za-z0-9_.-]+ +--delete' || matches 'git +push.*[: ]:[A-Za-z0-9_/.-]+'; then
    deny "Deleting a remote branch is blocked."
  fi

  # A bare `git push` follows push.default and can land somewhere unintended,
  # so require the target branch to be named.
  if matches 'git +push *$' || matches 'git +push +(-u +|--set-upstream +)?[A-Za-z0-9_.-]+ *$'; then
    deny "Name the branch explicitly (git push -u origin spec/<slug>) so the target is unambiguous."
  fi
fi

# ---------------------------------------------------------------------------
# Layer 3 — destroying uncommitted work
# ---------------------------------------------------------------------------
# Path-scoped forms stay allowed: backing out one file is how a legitimate fix
# cycle recovers. It is the unscoped, whole-tree forms that are unrecoverable.

if matches 'git +reset +(--hard|--merge|--keep)'; then
  deny "git reset --hard destroys uncommitted work. To undo one file use 'git checkout -- <file>'; if the tree is genuinely broken, mark the spec BLOCKED and stop."
fi

# Bare `git reset` or `git reset <commit>` moves HEAD. Anything after `--` is a
# pathspec, which is the safe form.
if matches 'git +reset( +[A-Za-z0-9_^~@{}/.-]+)? *$' && ! matches 'git +reset.* -- '; then
  deny "Unscoped 'git reset' moves HEAD and unstages everything. Use a path-scoped reset (git reset -- <file>) or leave the state for review."
fi

if matches 'git +clean +-[a-zA-Z]*f'; then
  deny "git clean -f deletes untracked files, including ones this run has not committed yet. Leave them in place."
fi

if matches 'git +(checkout|restore) +\.( |$)'; then
  deny "'git checkout .' discards every uncommitted change. Scope it to the file you mean: git checkout -- <file>."
fi
if matches 'git +restore +(--staged +)?(--worktree +)?\.( |$)'; then
  deny "'git restore .' discards every uncommitted change. Scope it to a single file instead."
fi

if matches 'git +stash +(drop|clear)'; then
  deny "Dropping stashes is irreversible. Leave the stash for review."
fi

# ---------------------------------------------------------------------------
# Layer 4 — rewriting history
# ---------------------------------------------------------------------------
# Review reads the branch history. Rewriting it mid-run invalidates that and can
# strand commits the run already reported as done.

if matches 'git +rebase'; then
  deny "Rebasing is blocked during overnight runs. Commit forward instead — the branch is reviewed as a pull request."
fi
if matches 'git +commit.*--amend'; then
  deny "Amending rewrites the previous commit. Make a new commit describing the fix."
fi
if matches 'git +(filter-branch|filter-repo)'; then
  deny "History rewriting is blocked during overnight runs."
fi
if matches 'git +reflog +(expire|delete)'; then
  deny "Expiring the reflog removes this run's recovery path. Blocked."
fi
if matches 'git +update-ref +-d'; then
  deny "Deleting refs directly is blocked."
fi
if matches 'git +branch +-[a-zA-Z]*D'; then
  deny "Force-deleting a branch can strand unmerged commits. Leave the branch for review."
fi
if matches 'git +tag +-d'; then
  deny "Deleting tags is blocked."
fi

# ---------------------------------------------------------------------------
# Layer 5 — leaving or dismantling the worktree
# ---------------------------------------------------------------------------

for branch in $protectedBranches; do
  if matches "git +(checkout|switch) +$branch( |\$)"; then
    deny "Switching to '$branch' abandons this run's branch. Stay on spec/<slug> for the whole run."
  fi
done

if matches 'git +worktree +(remove|prune)'; then
  deny "Removing worktrees is blocked — this run is executing inside one. Cleanup happens after review."
fi

if matches 'git +merge' && ! matches 'git +merge +--abort'; then
  deny "Merging is blocked. Overnight runs open a pull request and stop; you merge after reviewing."
fi

# ---------------------------------------------------------------------------
# Nothing matched — normal permission flow applies.
# ---------------------------------------------------------------------------
allow
