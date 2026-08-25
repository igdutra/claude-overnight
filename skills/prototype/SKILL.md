---
name: prototype
description: Workflow step 2 of 7. Generate several deliberately different directions for a task so the user can react to something concrete instead of describing it. Surfaces the "obviously not that" they'd never write down. Use after /discovery and before /spec, or standalone whenever a direction is unclear. Trigger on /prototype, or proactively when the user is describing something visual or structural they haven't seen yet.
---

# Prototype

Cheapest way to find what the user can recognize but not articulate. Runs before
any decision is locked in.

## Rule: diverge, don't vary

Three or four directions that differ in **approach**, not in styling. Different
layout models, different interaction patterns, different structural bets. Four
shades of one idea teach nothing.

Say what each direction commits to and what it gives up. The user is picking a
bet, not a color.

## UI tasks — use /design

Invoke the `design` skill. It produces editable artboards on one canvas, which
beats disposable HTML: the user can tweak the winner in place instead of
describing changes back.

Give it the divergence explicitly — tell it the directions differ in approach,
and name each one's bet.

`/design` is a research preview; if it fails or isn't available, fall back below.

## Non-UI tasks — compare in an artifact

For API contracts, data models, architecture: no artboards. Publish one HTML
artifact comparing the approaches side by side — schema sketches or signatures,
plus the tradeoff each makes. Concrete enough to react to.

## After

Prototypes are disposable. The output is the **decision**, not the file.

If a task slug exists (`specs/NNN-slug/`), append a `## Prototype` section to
`discovery.md`: the direction chosen, why, what the others gave up, and the
artifact URL. `/spec` and `/pitch` read that file and cannot open artifacts.

Otherwise just carry the decision into `/spec` and say why the others lost.

## Skip when

The approach is already settled, or the task has one obvious shape.
