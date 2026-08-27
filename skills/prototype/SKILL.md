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

### Where the working files live

`/design` authors each direction as a separate `.dc.html` artboard plus a
`canvas.json`, then seeds them into one self-contained published HTML. That
split is mechanically required by the skill, not a choice — and those
intermediate sources have no reason to enter the repo.

- **While iterating**, keep the `.dc.html` sources and `canvas.json` in the
  session scratchpad. Editing and re-seeding there avoids deleting and
  re-extracting from the published canvas on every round, which costs a round
  trip and buys nothing. Rounds are normal: adding a Direction D after
  feedback on A/B/C is the common shape.
- **Only once a direction is locked** do the final seed and publish happen,
  and only the resulting single published HTML is copied into the repo.
- **Never commit `.dc.html` or `canvas.json`.** If the canvas ever needs
  rebuilding outside the browser editor, `/design --extract` pulls fresh
  sources straight from the live artifact URL.

The repo therefore holds exactly one generated file per prototype round, not a
trail of working files. Note in `discovery.md` that the live canvas is the source
of truth — the committed copy is an offline fallback and does **not** resync if
someone edits the canvas in the browser afterwards.

### One canvas bug worth knowing

An absolutely-positioned element placed outside its artboard's bounds has no
background of its own, so it paints onto the canvas's white page rather than
the artboard's surface. On a dark artboard that renders caption text
white-on-white — invisible, and easy to mistake for a screenshot artifact
rather than the real CSS bug it is. Keep positioned elements inside their
artboard, or give them their own background.

## Non-UI tasks — compare in an artifact

For API contracts, data models, architecture: no artboards. Publish one HTML
artifact comparing the approaches side by side — schema sketches or signatures,
plus the tradeoff each makes. Concrete enough to react to.

## After

Prototypes are disposable. The output is the **decision**, not the file.

If a task slug exists (`specs/NNN-slug/`), append a `## Prototype` section to
`discovery.md`: the direction chosen, why, what the others gave up, and the
artifact URL. `/spec` and `/pitch` read that file and cannot open artifacts —
so `discovery.md` is the canonical record, and anything that only exists on the
canvas is invisible to every phase downstream. Write the bets and costs out in
prose there; do not point at the artifact and call it recorded.

Otherwise just carry the decision into `/spec` and say why the others lost.

## Export a read-only design snapshot once the direction is locked

**Do this for UI tasks the moment a `/design` direction is chosen**, before
moving on to `/spec`. Skip it only for non-UI prototypes (no artboards).

### Why this step exists

The committed `/design` file is a *design-canvas editor*: it inlines the
editor's entire JavaScript runtime alongside the design, and stores the
artboards as JSON-escaped strings inside `<script id="appifact-doc">`. On spec
006 that was **2.5 MB across 11,009 lines**, with single lines up to 264 KB.
Every downstream session that needed the visual reference — `/implement-spec`,
`/qa`, `/local-code-review` — had to parse that JSON and pull artboards out by
hand: about a minute of wall time, several tool calls, and a large slice of
context, *re-derived from scratch every single time*. This snapshot removes
that cost permanently.

### What to produce

One file: `specs/NNN-slug/design.html`. A **read-only, static** rendering of
the locked design — the file every downstream phase reads instead of the
canvas. The canvas stays the editable source of truth; `design.html` is a
derived, disposable view you can always delete and rewrite from the canvas.

Build it by opening the canvas, reading each artboard, and re-writing the
design as plain semantic HTML with one inline `<style>` block. It is a
hand-made snapshot, not an export tool — there is no script.

### Hard constraints — all of them, no exceptions

- **Zero JavaScript.** No `<script>` tags of any kind. No `on*=` handlers. No
  `<noscript>`.
- **No editor runtime, no canvas chrome.** No `appifact-doc`, no pan/zoom, no
  toolbars, no selection UI. The design only.
- **Self-contained and static.** One file. Inline `<style>` only — no `<link>`,
  no external stylesheet. Images as `data:` URIs or dropped for an alt-text
  placeholder; no remote `src`.
- **Plain semantic markup.** Each artboard is a `<section>` preceded by an
  `<h2>` naming it and, in one line, what it represents (entry path, state).
  Artboards in canvas order.
- **Size ceiling 250 KB.** A few artboards of real design land well under this.
  Over it means pasted runtime or un-optimized base64 images — strip them.
- **Renders standalone with JS disabled** — every artboard present and
  correctly styled.
- **First line is** `<!-- generated from <canvas-file> on YYYY-MM-DD — read-only snapshot, regenerate if the canvas changes -->`.

### Redo the file if any of these is true

- it contains a `<script>` tag or any `on*=` attribute
- it is over 250 KB
- it references any `http` URL
- an artboard from the canvas is missing, or renders blank/broken with JS off
- it is not named exactly `specs/NNN-slug/design.html`

### Before you commit

1. Open `design.html` yourself and confirm every artboard is present and
   matches the canvas.
2. `rg -c '<script|on[a-z]+=' specs/NNN-slug/design.html` must print `0` (or no
   match).
3. Commit both the canvas file and `design.html`.

### Record it

In the `## Prototype` section of `discovery.md`, add a line: `Read-only design
snapshot: specs/NNN-slug/design.html` — and note that it is regenerated by hand
from the canvas and goes stale if the canvas is edited afterward.

## Skip when

The approach is already settled, or the task has one obvious shape.
