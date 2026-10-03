# Install light

follow ~/Desktop/Projetos/claude-overnight/docs/INSTALL-LIGHT.md

The daytime skills in a new repo, without the overnight runner. This file is a
handoff: a Claude session starting a repo reads it and does the steps.

The skills end up as plain folders inside the repo, committed with it. Nothing
is installed, and no prefix is involved. They are called `/discovery`, `/spec`
and so on.

## The target may be public. The source is not.

The repo you are working in can be public. Where the skills come from is
private. So nothing in the target repo may mention the source: not its name,
its path, its URL, or the fact that the skills came from a plugin. That covers
files, `CLAUDE.md`, commit messages and pull requests.

Use a neutral commit message, for example `Add discovery-to-pitch skills under
.claude/skills`.

## What gets copied

Eight skills, all self-contained:

`discovery`, `prototype`, `spec`, `implement-spec`, `qa`, `local-code-review`,
`finish`, `pitch`

Nothing else: no scripts, no hooks, no design docs. The skills do not refer to
anything outside their own folders, and they have been written so their text
names no project and no tool they came from. Step 5 checks this.

## Steps

You are in the new repo. The user gives you `sourceRepoPath`, the folder that
holds `skills/` and `docs/`. If they have not, ask.

1. Set the two paths, and stop if you are standing in the source:

   ```bash
   sourceRepoPath=<path the user gave you>
   targetRepoPath=$(git rev-parse --show-toplevel)
   test "$targetRepoPath" != "$sourceRepoPath" || echo "wrong repo: this is the source"
   git -C "$sourceRepoPath" branch --show-current   # expect: main
   git -C "$sourceRepoPath" status --short          # expect: nothing
   ```

2. Copy the skills. If any destination folder already exists, stop and ask — a
   second `cp -R` would nest inside it.

   ```bash
   mkdir -p "$targetRepoPath/.claude/skills"
   for skillName in discovery prototype spec implement-spec qa local-code-review finish pitch; do
     cp -R "$sourceRepoPath/skills/$skillName" "$targetRepoPath/.claude/skills/$skillName"
   done
   ```

3. Write `CLAUDE.md` from `$sourceRepoPath/docs/CLAUDE.starter.md`:
   - No `CLAUDE.md` yet: copy the starter to the repo root and replace
     `<project name>`.
   - One exists: keep everything in it and append the two sections. Do not add a
     second `## Build & Validation` block if it has one.

4. Fill `## Build & Validation` only with commands you have run and seen work.
   If the project has no test command yet, leave the placeholders. Do not invent
   a check: `/implement-spec` runs only what `CLAUDE.md` states, and says so when
   nothing is stated.

5. Verify. Both commands must print nothing past the folder listing:

   ```bash
   ls "$targetRepoPath/.claude/skills"
   rg -n -i "overnight|plugin|workflow:|claude-overnight|igdutra|ProgramListView|morning|2am|3am|loop\.sh" \
     "$targetRepoPath/.claude/skills" "$targetRepoPath/CLAUDE.md"
   ```

   Expect the eight folder names, then no matches. A match means the source
   still carries something private: stop and tell the user, do not edit around
   it.

6. Leave everything uncommitted and show `git status`. The user commits.

7. Tell the user to start a new session in the repo and type `/` to confirm the
   eight skills appear.

## Know before you go

- **Copies, not links.** Changing a skill in the source does not change the copy
  here. To update one, copy its folder over again, and run `git diff` first so
  local edits are not lost.
- **Two listings are normal.** If the same skills are also installed globally on
  this machine, each may show up twice, once prefixed and once as `/spec`. Leave
  the global install alone, and do not mention it in the repo.
- **Do not edit the skills while copying.** Fix them in the source.
- **The verdict lines are not a bug.** `/qa` and `/local-code-review` end with
  machine-readable lines (`QA-VERDICT:`, `REVIEW-BUGS:`) that automation can read.
  They are harmless when run by hand.
- **`While implementing` is scoped on purpose.** The stop rule is for building.
  `/discovery` works by asking questions, and a bare keep-going rule could make
  it skip the interview.

## Using them

```
/discovery → /prototype → /spec → /implement-spec → /qa + /local-code-review → /finish
```

Each takes the task slug (`NNN-short-kebab-slug`), which `/discovery` fixes. Work
lands in `specs/<slug>/`.
