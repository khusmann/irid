# Design: unify the render protocol into one ordered op message

Status: design / handoff. **Continue on branch `render-batching`** (PR #68 — open,
**not merged**). This work builds on the batch commits already on that branch and
replaces them in place; do it as further commits on the same branch. Greenfield —
no back-compat constraint, so delete freely.

## Context

The branch already landed flush-coalescing (the `irid-batch` section of
`ARCHITECTURE.md` explains the why): the render-phase messages of one Shiny flush
ride a single WebSocket frame, so a nested control-flow render lands in one paint
instead of one-per-message. But it did that by **adding** an `irid-batch` envelope
*alongside* the existing standalone messages, leaving the protocol with two ways
to say the same thing. In practice the standalone render messages are already
dead: the server now sends standalone only `irid-config`, `irid-ready`, and
`irid-attr` (for the per-widget drain) — never standalone `irid-mutate` /
`irid-wire` / `irid-widget-init`.

This collapses that redundancy into one coherent protocol: a single `irid-render`
message carrying an ordered op list, with `irid-batch` and the standalone render
messages gone.

## Starting point (current code on the branch)

What exists now, and the role each piece plays — the implementing agent edits/deletes these:

- **`srcts/src/protocol/messages.ts`** — wire types: `IridConfig`, `IridAttr`
  (union: dom/text/widget), `IridMutate`, `IridWire`, `IridWidgetInit`,
  `IridReady`, `IridBatch`/`IridBatchOp`, `IridClientEvent`. Value types live in
  `values.ts` (`EchoGate`, `DomOpts`, `Timing`, id aliases) — unchanged.
- **`srcts/src/core/handlers.ts`** — `apply*` fns (`applyConfig`, `applyAttr`
  [switches on `target` dom/text/widget], `applyMutate` [does its own
  `setTimeout(bindAll, 0)`], `applyWire`, `applyWidgetInit`, `applyReady`,
  `applyBatch`) + `registerHandlers`. Module state: `wireRegistered` set,
  `PROP_ATTRS`.
- **`srcts/src/core/widgets.ts`** — `widgets` registry, `handleWidgetInit` →
  `mountWidget` (`getElementById`; buffers updates in `w.pending` during async
  construction); a widget handle's `update(values)` hook.
- **`R/mount.R`** — `irid_send(session, type, message)` (buffers an op),
  `irid_arm_render_batch(session)` (creates the buffer + a one-shot
  `session$onFlushed` drain that sends `irid-batch`), `irid_queue_widget_attr`
  (the **separate** per-widget accumulate + drain — to delete),
  `irid_echo_gate(seq, channel)`. `irid_mount_processed(result, session, depth)`
  arms the batch at `depth == 0` (before `irid_send_ready`), sends `irid-wire` /
  `irid-widget-init` / binding `irid-attr` / event force-send via `irid_send`;
  widget bindings go via `irid_queue_widget_attr`. `run_reconcile_plan` /
  `cf_render_child` send `irid-mutate` via `irid_send`.
- **`R/encode.R`** — `msg_irid_*` constructors (`mutate`, `attr_dom`,
  `attr_text`, `attr_widget`, `wire`, `widget_init`, `config`, `ready`, `batch`),
  the `json_*` shape combinators, and `as_protocol.*` (timing / dom_opts / gate).
- **`R/app.R`** — `irid_send_config` (standalone), `irid_send_ready` (standalone,
  via its own `onFlushed`), `iridApp` / `renderIrid` mount entry points.
- **Tests** — `tests/testthat/helper-mock-session.R` (`new_fake_session` with
  `flatten_irid_batch` + `raw_msgs`; the bare `flushReact()` routes through the
  latest fake session so `onFlushed` fires). `test-mount-batching.R` asserts
  batch structure via `raw_msgs()`. `test-widget-batching.R` (own
  `new_batch_session`, also flattens). `test-widget-deps.R` (`recording_session`,
  a plain-list stub whose `onFlushed` fires **immediately** — used only by tests
  that call `deliver_widget_deps` directly, not `irid_mount_processed`).

## The change

1. **One render message.** Replace the standalone `irid-mutate` / `irid-attr` /
   `irid-wire` / `irid-widget-init` *and* the `irid-batch` envelope with a single
   `irid-render`: `{ ops: Op[] }`, applied in one synchronous pass. Emission order
   is apply order — a child's `mutate` precedes the `wire` / `widget-init` / `attr`
   that need its element to exist.

2. **One `kind` per operation; a `source`/`target` field only for dom/widget
   variants.** Op set: `mutate | wire | widget-init | attr | text`. Two ops have
   dom/widget variants, and the field name encodes data-flow direction:
   - `wire` registers a client→server channel — the event *originates* from a DOM
     listener or a widget → `source: "dom" | "widget"`.
   - `attr` pushes a server→client value — the value is *destined* for a DOM
     property or a widget's `update()` → `target: "dom" | "widget"`.

   Parallel structure, opposite field names; the opposition is information. `attr`'s
   two targets share an identical shape (`{ id, attr, value, gate }`). `text` is
   *not* an `attr` variant — different shape (`{ id, value }`, no `attr`/`gate`)
   and operation (range-content replace), so it is its own kind.

3. **Widget props become single-key ops; the per-widget merge moves to the
   client.** Today the server coalesces a flush's prop writes per widget into one
   `irid-attr target="widget"` with a `{attr -> value}` map, so an atomic-render
   widget (Plotly) redraws once. That machinery exists only because, before the
   render frame, coalescing *required* one message. Now:
   - A widget prop write is a single-key `attr` op with `target: "widget"`,
     emitted one per write exactly like a DOM attr — no special server path.
   - The client, applying `irid-render`, **accumulates** `target: "widget"` ops
     per id (gate-checked per op), then after the last op calls each widget's
     `update()` **once** with the merged map. Deferring to the end also fixes
     ordering: the widget's `widget-init` op (earlier in the list) has run.

   The widget `update()` contract is unchanged — it still gets a `{attr -> value}`
   map; the client builds it instead of the server.

## What this deletes

- **Server**: `irid_queue_widget_attr`, `session$userData$irid_widget_pending`
  (+ `.order`), its `onFlushed` drain, `msg_irid_attr_widget`. Widget prop writes
  take the same `irid_send` path as DOM attrs — one coalescing point.
- **Wire types**: the `IridAttrWidget`-with-maps variant (→ single-key `attr`).
- **Client**: the standalone `irid-mutate` / `irid-attr` / `irid-wire` /
  `irid-widget-init` handlers. The `apply*` fns survive as op-dispatch targets.

After this, server→client is exactly three messages — `irid-config`,
`irid-render`, `irid-ready` — and every DOM/widget update flows through
`irid-render`.

## Final protocol schema

TypeScript shapes (source of truth: `srcts/src/protocol/`). All server→client
messages are built by the producer codec (`R/encode.R`); the `json_*` combinators
pin each field's wire shape from its declared type.

```ts
// ---- shared value types (values.ts, unchanged) --------------------------
type ElementId  = string;  // document.getElementById
type AnchorId   = string;  // a comment-anchor-pair id (range protocol)
type OutputName = string;  // a Shiny output id (renderIrid / iridOutput)
type Channel    = string;  // a Shiny input id; also the per-channel seq key

interface EchoGate { seq: number; channel: Channel; }  // null gate = programmatic write

interface DomOpts {        // mirrors R's wire_dom_opts(); DOM channels only
  preventDefault: boolean; stopPropagation: boolean;
  capture: boolean; passive: boolean;
  filter: string | null;   // JS predicate over `e`, or null
}

type Timing =
  | { mode: "immediate" }
  | { mode: "throttle"; ms: number; leading: boolean }
  | { mode: "debounce"; ms: number };

// ---- server -> client: three custom messages ----------------------------

// irid-config — runtime options pushed at session start (before the mount).
interface IridConfig { staleTimeout: number | null; }  // null disables the indicator

// irid-render — one flush's render: an ordered op list applied in one pass.
interface IridRender { ops: Op[]; }
type Op = OpMutate | OpWire | OpWidgetInit | OpAttr | OpText;

// Structural comment-anchor range mutation (Each / When / Match). Each part
// always present; an unused part is [] (a no-op). The three arrays are the
// ordered phases of ONE reconciliation (see Op-modeling principles).
interface OpMutate {
  kind: "mutate";
  id: AnchorId;
  removes: AnchorId[];
  inserts: string[];        // outerHTML fragments, parsed in the container's context
  order: AnchorId[];
}

// Attach one client->server channel's listener (one op per channel).
// Discriminated on `source` (where the event comes FROM — mirror of OpAttr.target).
type OpWire = OpWireDom | OpWireWidget;
interface OpWireCore {
  kind: "wire";
  id: ElementId;
  event: string;
  channel: Channel;         // namespaced Shiny input id; per-channel seq key
  timing: Timing;
  coalesce: boolean;        // gate on server-idle (backpressure)
}
interface OpWireDom extends OpWireCore {
  source: "dom";
  domOpts: DomOpts;
  clientOnly: boolean;      // config-only wire: apply flags, never round-trips
}
interface OpWireWidget extends OpWireCore { source: "widget"; }

// Mount a widget instance into its container.
interface OpWidgetInit {
  kind: "widget-init";
  id: ElementId;
  name: string;             // registry name (defineWidget)
  props: Record<string, unknown>;   // merged initial props ({} when none)
}

// A bound value pushed to its sink, discriminated on `target` (where it GOES).
//   "dom"    — property/attribute write on getElementById(id), applied inline.
//   "widget" — a prop write; the client collects all target="widget" ops per id
//              and calls update() once at the end with the merged map (one redraw).
interface OpAttr {
  kind: "attr";
  target: "dom" | "widget";
  id: ElementId;
  attr: string;
  value: unknown;
  gate: EchoGate | null;    // null = programmatic; else gated on the channel's seq
}

// Text replace inside a comment-anchor range — its own kind (no attr, no gate).
interface OpText { kind: "text"; id: AnchorId; value: string; }  // "" = clear range

// irid-ready — mount fully wired (post-render barrier). Sent after irid-render
// drains, so a client that has seen it has the whole render applied.
interface IridReady { output: OutputName | null; }  // output name, or null (iridApp)

// ---- client -> server (unchanged) ---------------------------------------
// Sent via Shiny.setInputValue(channel, _, {priority:"event"}); event data
// (DOM fields, or a widget sendEvent payload) under `data`.
interface IridClientEvent {
  id: ElementId;            // source element id (module namespacing)
  seq: number;              // per-channel monotonic sequence (the echo gate)
  data: Record<string, unknown>;
}
```

## Client apply algorithm (`irid-render` handler)

```
applyRender(msg):
  widgetAcc = {}                       # id -> { attr -> value }
  for op in msg.ops:
    switch op.kind:
      "mutate":      applyMutate(op)
      "wire":        applyWire(op)
      "widget-init": applyWidgetInit(op)
      "text":        applyText(op)                       # inline
      "attr":
        if op.target == "dom": applyDomAttr(op)          # gate-checked, inline
        else if not isStaleEcho(op.gate):                # target == "widget"
          widgetAcc[op.id][op.attr] = op.value           # accumulate, gate per op
  for id, values in widgetAcc:                           # after all ops
    applyWidgetValues(id, values)      # update() if handle live, else merge into w.pending
  scheduleBindAll()                    # ONE bindAll, replacing the per-mutate setTimeout
```

`applyDomAttr` / `applyText` are the dom / text branches of today's `applyAttr`;
`applyWidgetValues` is its widget branch minus the per-key gate loop (gates are
checked during accumulation). Drop `applyMutate`'s own `setTimeout(bindAll)` — one
`bindAll` runs after the pass instead.

## Invariants to preserve (the e2e suite is the gate)

- **One paint** — every op in one frame, applied synchronously.
- **Ordering** — emission order = apply order; `mutate` precedes the
  `wire`/`widget-init`/`attr` that depend on its element. The `<select value=rv>`
  options-before-value case holds because control-flow ops precede the binding's
  `attr` (`target="dom"`) in the list.
- **Single widget redraw** — now via the client's per-widget accumulation.
- **`irid-ready` barrier** — `irid-render` drains before ready's `onFlushed`
  (the buffer is armed at the depth-0 mount, ahead of `irid_send_ready`).
- **Stale-echo gate** — per-op `gate` on every `attr`; widget gates are now per op,
  not a `valueGates` map.

## Op-modeling principles (why the shapes are what they are)

- **A list field belongs to one op only when its elements are the *internal
  structure* of one operation — not when each is a complete op on its own.**
  `mutate`'s `removes`/`inserts`/`order` stay one op: three ordered phases of one
  reconciliation (`plan_reconcile`'s output), with inter-phase dependencies, and
  `order` is an indivisible whole-sequence value. `wire`'s old `rows[]` was an
  array only to save frames (each row a complete, independent registration) → it
  flattened to one op per channel. Test: *could each element stand alone as its
  own op?* Yes → flatten; no → keep.
- **When the producer knows a discriminant, put it on the wire; don't make the
  client infer it.** `attr.target` / `wire.source` are explicit though the client
  could often guess (probe the widget registry / anchor map). The server knows for
  free, and inference couples the client to mutable state and op order — an `attr`
  arriving before its `widget-init` would mis-route. Explicit beats inferred.
- **Naming**: `irid-render`, not `irid-batch` — "batch" reads oddly once it is
  *the* render message (a batch even with one op).

## Implementation plan (commits on `render-batching`)

1. **Protocol types** (`messages.ts`): `IridRender` + the `Op` union (one `OpAttr`
   with `target`; `OpText` separate; `OpWire` keeps its `source` union). Delete
   `IridBatch`/`IridBatchOp` and the `IridAttrWidget`-with-maps variant.
2. **Client** (`handlers.ts`): one `irid-render` handler running the algorithm
   above. Split `applyAttr` → `applyDomAttr` / `applyText` / `applyWidgetValues`;
   accumulate `target="widget"` ops; single post-pass `bindAll`. Delete the four
   standalone render handler registrations; keep `irid-config` / `irid-ready`.
   Then `cd srcts && corepack pnpm run typecheck && corepack pnpm test &&
   corepack pnpm run build` (rebuild the committed `inst/` bundles).
3. **Codec** (`R/encode.R`): `msg_irid_render(ops)` (replacing `msg_irid_batch`);
   give each `msg_irid_*` op constructor its `kind`; collapse the three
   `msg_irid_attr_*` into one `attr` constructor (`target` ∈ {dom, widget}, single
   key) + a `text` constructor. Remove `msg_irid_attr_widget`.
4. **Server send path** (`R/mount.R` + `R/app.R`): widget bindings emit a single
   `attr` (`target="widget"`) op via `irid_send` — delete `irid_queue_widget_attr`,
   the pending map, and its drain. Rename the buffer's drain message `irid-batch`
   → `irid-render`. The depth-0 arming and `irid_send_ready` ordering stay as-is.
5. **Tests**: rename `flatten_irid_batch` → flatten `irid-render`; update
   `test-mount-batching.R` (op shapes carry `kind`; `widget-attr` is now an `attr`
   op with `target="widget"`); rework `test-widget-batching.R` to assert the
   client-side merge contract (one `attr` op per write, in order, in the op list)
   rather than a server `values` map. `Rscript -e 'devtools::test()'` then
   `IRID_E2E=1 Rscript -e 'devtools::test(filter="e2e")'` (plotly exercises the
   single-redraw path; controlled-input the select ordering).
6. **Docs**: replace the `irid-batch` section of `ARCHITECTURE.md` with the
   `irid-render` protocol; delete this doc and update PR #68's description.
