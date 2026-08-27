---
name: qa
description: Workflow step 5 of 7 (with /local-code-review). QA a finished implementation against specs/$ARGUMENTS/SPEC.md Acceptance Criteria, in a fresh context. Functionality only — /local-code-review covers correctness and style.
disable-model-invocation: true
context: fork
background: false
---

Act as QA on a finished implementation. You have no memory of building this —
read `specs/$ARGUMENTS/SPEC.md` and the code fresh, as an outside reviewer.

Check functionality only. Do not comment on code style, architecture, or
anything `/local-code-review` would catch — that's a separate step.

Read `## Requirements` first if present — it says what the user should observe.
Judge against that, not against what the code appears designed to do.

For each item under `## Acceptance Criteria`:

1. Determine how to check it — run it, read the code path, or inspect output.
   State what you did. `## Verification` in the spec tells you how.
2. Mark Pass or Fail. No partial credit — if you can't verify it, it's a Fail.
3. Give evidence: what you ran or read, and what you observed. Not an assertion.

Also read `specs/$ARGUMENTS/implementation-notes.md` if it exists — flag any
logged deviation that could break an acceptance criterion, even if the criterion
technically passes.

## Snapshot criteria: open the image and inspect it

A passing snapshot test is **not** evidence the snapshot is correct. A snapshot
test can only ever detect *change*; on its first recording it asserts nothing.
A blank reference image matches itself byte-for-byte forever and the suite
stays green while checking nothing.

This is not hypothetical, and it fails at two different depths:

- Spec 005 shipped a `ProgramListView` reference PNG that was an empty dark
  rectangle — the renderer did not rasterize `ScrollView` contents at all — and
  it passed QA, passed review, and was nearly merged.
- A row shipped missing its right-hand chevron. The image was not blank, so a
  "does it look empty?" check waves it through. The affordance that tells the
  user the row is tappable was simply gone, and QA should have caught it.

### First: does this apply at all?

This section is about **images this spec's work produced or affected**. Plenty
of specs have no rendered output whatsoever — a parser, a migration, a network
client — and for those there is nothing here to do. Do not go hunting for
snapshots that were never part of the work, and do not audit a repo's existing
reference images just because they exist.

It applies when either is true:

- **This spec's acceptance criteria involve a snapshot, screenshot or other
  rendered reference image** — the normal case, including a spec that records
  new references.
- **This spec touched something that renders into existing snapshots** — a
  shared row or cell, a design token, a theme, a layout container, a component
  other screens embed. Then the relevant existing references are in scope as a
  **regression** check, even though no criterion names them. If the suite
  re-recorded or updated any reference image, look at what changed and why.

If neither holds, skip this section entirely and say nothing about snapshots.
An absent snapshot test is not a finding on its own — "this spec has no
rendered output" is a complete answer.

### When it does apply

1. Locate the actual image the test recorded or asserts against — typically
   `**/snapshots/*.png`, though each repo names them differently. If a
   criterion asserts against an image and you cannot find that image, *that*
   is a Fail: an assertion you cannot point at is not one you have verified.
   This is about a reference a criterion names, not about a repo that has no
   snapshots at all.
2. **View it.** Read the image file itself, so you see the pixels.
3. **Inspect it against what the spec describes**, element by element. Walk the
   screen's parts — rows, labels, section headers, icons, chevrons, badges,
   counts, empty states — and confirm each one the spec calls for is actually
   present and reads correctly. "Not blank" is not the bar.

### What to compare against

`SPEC.md` is the authority. If `specs/$ARGUMENTS/discovery.md` has a
`## Prototype` section, read it too — it records which direction was chosen and
what that direction committed to, which is often the only written description
of what the screen is meant to look like. Prefer it over guessing.

Two cautions. The prototype is a *direction*, not a specification: it was
deliberately disposable, and the spec supersedes it wherever they disagree. And
you cannot open the linked artifact — the prose in `discovery.md` is what you
have, which is exactly why that skill requires the bets and costs to be written
out there. If no prototype was run, the spec's own description is the target
and that is fine.

### The bar is functional, not pixel-perfect

The snapshot does not have to match a mockup exactly, and it often will not —
spacing, exact shades, font rendering and platform chrome all drift, and that
drift is fine. Do not fail a criterion over nitpicks.

Make a judgment call on one question: **is something functional missing or
wrong?** An absent chevron, a row that lost its subtitle, a section header that
did not render, a control with no label, a truncated value, a count showing the
wrong number — those change what the user can understand or do, and they are a
**Fail regardless of whether the test passed.** Say in the `QA-FAILED:` line
what the image actually showed.

### If you pass it but something is different, log it

When you notice a visual difference that you judge *not* functional — you are
passing the criterion — do not let it evaporate. Record it as a `QA-CONCERN:`
line in the verdict block (see below). It leaves the verdict a Pass, and it
carries into the morning report so a human sees what you saw and can overrule
you.

This is the whole point of looking: a difference you noticed and said nothing
about is worth no more than never having opened the file. Passing silently is
how the blank rectangle and the missing chevron both got through.

An unattended run has no other checkpoint that ever looks at rendered output.
If you skip this, nothing downstream catches it.

## When you cannot tell whether it works

A criterion you cannot verify is a Fail — that rule does not bend. But before
recording one, be sure the doubt is about *the code* and not about *the
framework*.

Those are different failures. "The snapshot does not match" is a finding. "I
cannot tell whether this snapshot API is supposed to need a host application"
is not a finding yet, and a Fail written from that doubt sends the next fix
attempt chasing the wrong thing — or worse, rewriting working code to satisfy a
misreading.

So when the uncertainty is about how a framework, tool or API is meant to
behave, **search the web before writing the verdict**: the exact error text,
the API name, and what the community does about it. The official documentation
and the project's issue tracker are worth more than a forum post, but a
recurring complaint in issues is itself evidence about how the tool really
behaves.

What that changes:

- **It confirms the failure.** You now know what correct use looks like and can
  say precisely how the code departs from it. Put that in the `QA-FAILED:` line
  — a specific, sourced description is what makes the next fix attempt land.
- **It dissolves the failure.** What looked wrong is the documented behaviour.
  Record the criterion honestly against what you actually observed, and say in
  your prose what you found and where.

Keep it proportionate: a couple of focused searches, not an investigation. If
nothing useful turns up, say so and fall back to the rule — unverifiable is a
Fail. Never let a search become a reason to pass something you could not
verify.

## Verdict

End with a one-line summary in prose: all criteria pass, or what failed.

Then, as the very last thing you output, a machine-readable block. An unattended
overnight run parses this to decide whether to ship the work or send it back for
another fix attempt, so the format is fixed:

```
QA-VERDICT: PASS
QA-CRITERIA: 7 passed, 0 failed
QA-CONCERN: <what you observed that a human should still look at>
```

`QA-CONCERN:` lines are optional and may appear with either verdict; zero or
more of them.

or

```
QA-VERDICT: FAIL
QA-CRITERIA: 5 passed, 2 failed
QA-FAILED: <criterion> — <what was observed instead>
QA-FAILED: <criterion> — <what was observed instead>
```

Rules for the block:

- `PASS` only when every criterion passed. Anything you could not verify is a
  Fail, so it makes the verdict `FAIL` — never `PASS` with a caveat in prose.
- One `QA-FAILED:` line per failed criterion, each naming what you actually
  observed. That line is what the next fix attempt works from, so "returns nil
  when the list is empty" is useful and "doesn't work" is not.
- A logged deviation that could break a criterion which technically passes is
  worth a `QA-CONCERN:` line. So is any visual difference you saw in a snapshot
  and judged non-functional. It does not change the verdict; it carries forward
  to the morning report, where a human can overrule your judgment. Write what
  you observed, not a reassurance: "row chevron sits ~4px left of the mockup"
  is useful, "minor visual difference" is not.
