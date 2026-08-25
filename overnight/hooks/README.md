# The guardrail hook

`block-dangerous-git.sh` denies destructive git commands during an overnight
run: pushes to protected branches, force pushes, `reset --hard`, history
rewriting, and anything that leaves the worktree.

## It only fires during a run

The first thing the script checks is `OVERNIGHT_WORKTREE`. `loop.sh` exports
that variable for the duration of one spec and nothing else sets it, so its
presence is what distinguishes "a run is happening" from "the user is working
normally". Outside a run the hook exits immediately and allows everything.

That is deliberate. These rules exist because nobody is watching. Applied to
ordinary daytime work they would block legitimate things — rebasing, amending a
commit, resetting a botched experiment — that the user is perfectly capable of
supervising. A guardrail that fires when it is not needed teaches people to work
around it, which is how it comes to be ignored when it does matter.

## Installation: none

The plugin ships `hooks/hooks.json` at its root, which registers this script for
every session the plugin is loaded in. There is nothing to copy into a
repository and no settings file to edit.

`${CLAUDE_PLUGIN_ROOT}` resolves to the plugin directory regardless of the
session's working directory, so the hook is equally active in a worktree as in
the main checkout — and equally inert in both when no run is in progress.

## Verifying it

```bash
./test-hook.sh
```

61 cases across three tables. **BLOCK** proves destructive commands are caught,
including evasion attempts. **ALLOW** proves a legitimate run is not strangled —
that table matters as much as the first, since a hook that blocks everything
fails differently, not better. **GATE** proves the hook is inert with no run
active.

Run it after any edit to the patterns.

To confirm Claude Code has registered it, run `/hooks` in a session and look for
the entry. To watch it work, set the variable by hand and feed it a payload:

```bash
OVERNIGHT_WORKTREE=/tmp/example ./block-dangerous-git.sh <<< \
  '{"tool_name":"Bash","cwd":"/tmp/example","tool_input":{"command":"git reset --hard"}}'
```

That prints a JSON deny decision. Without the variable it prints nothing and
exits 0.

## The honest limit

Pattern-matching shell is defeatable in principle — `git p"u"sh`, a variable, a
wrapper script. Not because Claude is adversarial, but because shell has many
spellings for the same thing.

So the design does not lean on the hook alone. The `cwd` confinement check, the
worktree being a separate directory, `ANTHROPIC_API_KEY` unset in the runner's
environment, and the branch never being `main` in the first place are each
independent. The hook is the loudest layer, not the only one.
