# Design: flush-coalesced render batching

Status: design / handoff. Implementation not started.

## Problem

When a control-flow subtree renders (notably an `Each` whose item body is itself
a `When`/`Match`/`Each`), the client paints it **incrementally** — the user sees
item structure appear chunk-by-chunk, then reactive text "snap in" together a
beat later. The motivating report: a todo list (`Each` of per-item `When` of an
`<li>` with a reactive text child) where the cards appear a few at a time and the
text fills in afterward.

It is not a regression — it is inherent to how irid delivers DOM updates, and
becomes visible with a large list.

## Reproduction & evidence (spikes in `dev/spikes/`)

Headless-Chrome spikes, 6–8 item todo-shaped `Each`. A `requestAnimationFrame`
counter tags each DOM insertion / WebSocket frame with the animation frame it
landed in.

- `each_paint_timing.R` — 8 `<li>` cards land across **3–4 animation frames**;
  all 8 text nodes land together in **one** (later) frame.
- `each_paint_timing.R` (A/B/C comparison) isolates the cause:
  - **A** plain `Each`, static `<li>` → all cards in **1 frame**.
  - **B** `Each` + reactive text child (no nested control flow) → all cards in
    **1 frame** (text trails in a later frame).
  - **C** `Each` + per-item `When` + text → cards across **4 frames**.
  So the *structural* cascade is caused by the **nested control-flow level**, not
  the text binding. A single `Each` mutate carrying N items paints once (A/B).
- `flush_attribution.R` (via `options(shiny.trace=TRUE)`) — the authoritative
  server-side picture. For the 6-item case the render emits, **consecutively with
  no client `RECV` interleaved**: 1 `irid-config`, 7 `irid-mutate` (1 `Each`
  shell-insert + 6 per-item `When` bodies), 6 `irid-attr` (text), then
  `irid-ready`. **All in a single reactive flush, no round-trips.**

### Root cause

The whole render happens in **one server flush**, but Shiny sends **each
`sendCustomMessage` as its own WebSocket frame**. The client processes one frame
per task and the compositor paints between batches of frames, so N structural
messages → N (coalesced) paints. The render is **one-flush-but-N-frames**, not
multi-flush.

A *plain* `Each` avoids this only because it emits its whole child set as **one**
`irid-mutate` (one frame). The moment an item body contains its own control-flow
node, that node ships an empty shell in the `Each` mutate and fills itself via a
*separate* `irid-mutate` — one extra frame per item.

(An earlier spike tried making nested control-flow render eagerly so its body
ships in the mount's flush rather than the next one. It had no visible effect:
the render was *already* one flush; eager rendering left the per-message framing
— and thus the frame count — unchanged. Reverted. The lever is **frame count**,
not flush timing.)

## Approaches considered

### A. Render nested control-flow initial content into the parent mutate (rejected)

Make `Each`/`When`/`Match`, when built inside a parent item body, render their
initial branch into the parent's insert HTML (server-side render of initial
state) so the `Each` emits one mutate with complete items, then have the child
observer adopt the pre-rendered DOM and skip its first render.

Rejected: narrow (only fixes structure built through item bodies; does not help
the trailing text frame, nor sibling control-flow at the top level), and it
requires invasive surgery to `process_tags` / `build_entry` plus a new
"observer adopts existing DOM" contract — the most delicate code in the system.

### B. Flush-coalesced render batch — "super-message" (recommended)

Buffer the DOM-mutating messages emitted within a flush and deliver them as a
**single** `irid-batch` custom message (one frame) that the client applies in one
synchronous pass → one paint. This is the user-proposed approach and it
generalizes: it coalesces structure *and* text, so the whole render lands in one
paint (better than A, which still trails text).

Crucially, the trace proves the initial render is a single flush with no
round-trips, so a per-flush batch captures the entire render in one message.

irid **already uses this exact pattern** for widget attrs: `irid_queue_widget_attr`
([R/mount.R](../R/mount.R)) buffers `(attr, value)` per widget on
`session$userData` and drains them via a one-shot `session$onFlushed` into a
single `irid-attr target="widget"`. Approach B extends that precedent to
`irid-mutate` and `irid-attr` (dom/text).

## Design of B

### Server

- Add a per-session outbound buffer (e.g. `session$userData$irid_render_batch`),
  an **ordered** list of `{kind, msg}` ops.
- Route the DOM-mutating sends through it instead of sending inline:
  - `irid-mutate` (the sole structural message: `Each` reconcile, `When`/`Match`
    flips) → buffer `{kind: "mutate", ...}`.
  - `irid-attr` `target` ∈ {`dom`, `text`} (the per-binding observer echoes and
    event force-sends) → buffer `{kind: "attr", ...}`.
- On first buffered op, register a one-shot `session$onFlushed` that drains the
  buffer (in insertion order) into one `session$sendCustomMessage("irid-batch",
  { ops: [...] })` and clears it. Same shape/lifecycle as the widget-attr drain.
- **Emission order is the apply order.** The existing observer-priority design
  already orders emission correctly within a flush (control flow at priority 0
  before bindings at `-100+depth`; deeper bindings before shallower), so buffering
  in emission order preserves the `<select value=rv>` "options before value"
  invariant — now carried by array order inside one message instead of by frame
  order across messages.

### Client

- New `irid-batch` handler: iterate `msg.ops` and dispatch each to the existing
  per-kind apply logic. Refactor `handlers.ts` so the current `irid-mutate` /
  `irid-attr` handlers and the batch handler share `applyMutate(msg)` /
  `applyAttr(msg)` helpers. All ops apply synchronously → one paint.
- Call `Shiny.bindAll(parent)` **once** after the batch (the per-mutate
  `setTimeout(bindAll, 0)` becomes a single post-batch bind), removing redundant
  rebinds.
- Keep the standalone `irid-mutate` / `irid-attr` handlers: not every send is
  batched (see below), and they're the apply primitives the batch reuses.

### What batches vs. what does not

Batch only DOM-mutating messages whose interleaving with each other is what
causes the multi-paint: `irid-mutate`, `irid-attr` (dom/text).

Leave alone (own ordering / lifecycle, sent once, not the cascade):
`irid-config`, `irid-wire` (must register before its events fire),
`irid-widget-init`, `irid-ready`, and `irid-attr target="widget"` (already
coalesced by its own per-widget drain — fold into the batch later if desired, but
not required).

## Open questions to settle during implementation

1. **`onFlushed` ordering vs. the `irid-ready` barrier.** `irid-ready` is itself
   deferred via `onFlushed` ([R/app.R](../R/app.R)) and must arrive *after* the
   render. The batch drain registers its `onFlushed` when the first op is buffered
   (during mount, early); ready registers its `onFlushed` at the end of
   `irid_mount_processed`. Confirm `onFlushed` callbacks fire in registration
   order so the batch drains before ready. If not, sequence them explicitly.
2. **Prototype → confirm one paint.** Build a throwaway server buffer + client
   `irid-batch` handler and re-run `each_paint_timing.R`; expect all `<li>` **and**
   text in a single animation frame. (List B already shows one frame → one paint
   for a single message; this confirms it end-to-end for the coalesced batch.)
3. **Stale-echo gate** rides per-`attr` op unchanged (the gate is in the op
   payload); verify the gate still applies per op after batching.
4. **Multi-flush updates** (rare): a sequence spanning several flushes yields one
   batch per flush — correct, and still far fewer paints than today.
5. **Widget-attr unification**: decide whether to fold the existing widget-attr
   drain into the single batch or keep it separate (separate is fine initially).

## Implementation plan (incremental commits on this branch)

1. Spike the prototype (server buffer + client `irid-batch`) and confirm one
   paint (open question 2). Throwaway.
2. Client: refactor `handlers.ts` into `applyMutate`/`applyAttr` + add the
   `irid-batch` handler (single post-batch `bindAll`). Rebuild `inst/` bundles.
3. Server: add the buffer + `onFlushed` drain; route `irid-mutate` and dom/text
   `irid-attr` through it. Resolve the ready-ordering question (1).
4. Tests: unit (message shape + drain order, mirroring `test-widget-batching.R`);
   e2e assertion that a nested `Each` render lands in one batch / one frame.
5. Fold the durable rationale into `ARCHITECTURE.md`; delete this doc and the
   spikes (handoff complete).

## Spikes (evidence, build-ignored under `dev/`)

- `dev/spikes/each_paint_timing.R` — per-frame DOM-insertion timing + A/B/C
  isolation of the nested-control-flow cause.
- `dev/spikes/flush_attribution.R` — `shiny.trace` proof the render is one flush
  with no round-trips (so per-flush batching collapses it).
- `dev/spikes/each_flush_timing.R` — `MockShinySession` message dump (note: the
  mock flattens live timing; trust the browser spikes for delivery behavior).
