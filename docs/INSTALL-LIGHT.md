# Install light

The daytime skills in a new repo, without the overnight runner. This file is a
handoff: a Claude session starting a repo reads it and does the steps.

The skills end up as plain folders inside the repo, committed with it. No plugin
is installed, and no `workflow:` prefix is involved. They are called `/discovery`,
`/spec` and so on.

## What gets copied

Eight skills, all self-contained:

`discovery`, `prototype`, `spec`, `implement-spec`, `qa`, `local-code-review`,
`finish`, `pitch`

Not copied: `overnight`, `overnight-init`, `overnight-report`, and the
`overnight/`, `hooks/` and `docs/DESIGN.md` they depend on. Those need the
installed plugin, and this repo is not running overnight.

`docs/DESIGN.md` §3 says the plugin is never copied into projects wholesale.
This is not wholesale: it is eight skills, chosen because none of them refers to
anything outside its own folder.

## Steps

You are in the new repo. The plugin repo is the source.

1. Set the two paths, and stop if you are standing in the plugin repo:

   ```bash
   pluginRepoPath=~/Desktop/Projetos/claude-overnight
   targetRepoPath=$(git rev-parse --show-toplevel)
   test "$targetRepoPath" != "$pluginRepoPath" || echo "wrong repo: this is the plugin"
   git -C "$pluginRepoPath" branch --show-current   # expect: main
   ```

2. Copy the skills. If any destination folder already exists, stop and ask — a
   second `cp -R` would nest inside it.

   ```bash
   mkdir -p "$targetRepoPath/.claude/skills"
   for skillName in discovery prototype spec implement-spec qa local-code-review finish pitch; do
     cp -R "$pluginRepoPath/skills/$skillName" "$targetRepoPath/.claude/skills/$skillName"
   done
   ```

3. Write `CLAUDE.md` from `$pluginRepoPath/docs/CLAUDE.starter.md`:
   - No `CLAUDE.md` yet: copy the starter to the repo root and replace
     `<project name>`.
   - One exists: keep everything in it and append the two sections. Do not add a
     second `## Build & Validation` block if it has one.

4. Fill `## Build & Validation` only with commands you have run and seen work.
   If the project has no test command yet, leave the placeholders. Do not invent
   a check: `/implement-spec` runs only what `CLAUDE.md` states, and says so when
   nothing is stated.

5. Verify:

   ```bash
   ls "$targetRepoPath/.claude/skills"
   rg -n "CLAUDE_PLUGIN_ROOT|overnight/|loop\.sh|spec-state|budget\.sh" "$targetRepoPath/.claude/skills"
   ```

   Expect the eight folder names, then no output from the second command.

6. Leave everything uncommitted and show `git status`. The user commits.

7. Tell the user to start a new session in the repo and type `/` to confirm the
   eight skills appear.

## Know before you go

- **Copies, not links.** Changing a skill in the plugin repo does not change the
  copy here. To update one, copy its folder over again, and run `git diff`
  first so local edits are not lost.
- **Two listings are normal.** If the plugin is also installed globally, each
  skill may show up twice: `workflow:spec` from the plugin and `/spec` from this
  repo. Leave the global install alone; it is a link to the plugin repo.
- **Do not edit the skills while copying.** Fix them in the plugin repo.
- **The verdict lines are not a bug.** `/qa` and `/local-code-review` end with
  machine-readable lines (`QA-VERDICT:`, `REVIEW-BUGS:`) that the overnight
  runner reads. They are harmless when run by hand.
- **`While implementing` is scoped on purpose.** The stop rule is for building.
  `/discovery` works by asking questions, and a bare keep-going rule could make
  it skip the interview.

## Using them

```
/discovery → /prototype → /spec → /implement-spec → /qa + /local-code-review → /finish
```

Each takes the task slug (`NNN-short-kebab-slug`), which `/discovery` fixes. Work
lands in `specs/<slug>/`. Which model and effort to use for each step is in
`skills/INDEX.md` in the plugin repo.
