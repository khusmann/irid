# Design: unify the render protocol into one ordered op message

Status: design / handoff. Builds on the flush-coalescing batch (PR #68). Not yet
implemented. Greenfield — no back-compat constraint.

## Context

PR #68 made every render-phase message of one Shiny flush ride a single
`irid-batch` frame (so a nested control-flow render lands in one paint instead of
one-per-message; see the `irid-batch` section of `ARCHITECTURE.md` for the
why). It did that by *adding* a batch envelope **alongside** the existing
standalone messages, and routing the server through it.

That leaves the protocol with two ways to say the same thing — and, in practice,
the standalone render handlers are now dead: after #68 the server never sends a
standalone `irid-mutate` / `irid-wire` / `irid-widget-init`, and `irid-attr` only
standalone for the per-widget drain. This doc collapses that redundancy into a
single coherent protocol.

## The change

1. **One render message.** Replace the standalone `irid-mutate` / `irid-attr` /
   `irid-wire` / `irid-widget-init` *and* the `irid-batch` envelope with a single
   `irid-render` message: `{ ops: Op[] }`, an ordered list the client applies in
   one synchronous pass. Emission order is apply order (a child's `mutate`
   precedes the `wire` / `widget-init` / attr that need its element to exist).

2. **One `kind` per operation; a `source`/`target` field only for dom/widget
   variants.** The op set is:

   ```
   mutate | wire | widget-init | attr | text
   ```

   Two ops have dom/widget variants and carry a discriminant for it — and the
   field name encodes data-flow direction:
   - `wire` registers a client→server channel, so the event *originates* from a
     DOM listener or a widget → `source: "dom" | "widget"`.
   - `attr` pushes a server→client value, so the value is *destined* for a DOM
     property or a widget's `update()` hook → `target: "dom" | "widget"`.

   Parallel structure, opposite field names — and that opposition is information
   (which way the data flows). `attr`'s two targets share an identical shape
   (`{ id, attr, value, gate }`); `target` selects how the client applies it.
   `mutate`, `widget-init`, and `text` are single-shape operations, so they are
   plain kinds. `text` is *not* an `attr` variant: it is a range-content replace
   with a different shape (`{ id, value }`, no `attr`, no `gate`), not a
   named-attribute write.

3. **Widget props become single-key ops; the per-widget merge moves to the
   client.** Today the server coalesces a flush's prop writes per widget into one
   `irid-attr target="widget"` carrying a `{attr -> value}` map, so an
   atomic-render widget (Plotly) calls `update()` once, not once per prop. That
   server machinery exists only because, pre-#68, coalescing *required* packing
   into one message. With a single render frame, the merge moves to the client:

   - A widget prop write is a single-key `attr` op with `target: "widget"`
     (`{ id, attr, value, gate }`) — structurally identical to a `target: "dom"`
     attr. The server emits one per write, exactly like a DOM attr.
   - The client, applying `irid-render`, **accumulates** `target: "widget"` attr
     ops into a per-widget map (gate-checked per op as they arrive), then after
     the last op flushes each widget's map with **one** `update()`. Deferring the
     flush to the end also fixes ordering for free: the widget's `widget-init` op
     (earlier in the message) has already run, and `target: "dom"` attrs have
     already applied.

   The widget author's `update()` contract is unchanged — it still receives a
   `{attr -> value}` map; the client builds it instead of the server.

## What this deletes

- **Server**: `irid_queue_widget_attr`, `session$userData$irid_widget_pending`
  (+ its `.order`), the second `onFlushed` drain, and `msg_irid_attr_widget`. A
  widget prop write goes through the same `irid_send` path as a DOM attr — no
  special widget path, one coalescing point (the `irid-render` drain).
- **Wire types**: the `IridAttrWidget`-with-maps variant collapses into the
  single-key `attr` op (`target: "widget"`).
- **Client**: the standalone `irid-mutate` / `irid-attr` / `irid-wire` /
  `irid-widget-init` custom-message handlers. The `apply*` fns survive as the
  op-dispatch targets of the one `irid-render` handler.

After this, server→client is exactly three messages: `irid-config`,
`irid-render`, `irid-ready`. Every DOM/widget update flows through `irid-render`.

## Final protocol schema

TypeScript shapes (the source of truth lives in `srcts/src/protocol/`). All
server→client messages are built by the producer-side codec (`R/encode.R`); the
`json_*` combinators pin each field's wire shape from its declared type.

### Shared value types

```ts
// Id aliases — all string, named for what they resolve against.
type ElementId  = string;  // document.getElementById
type AnchorId   = string;  // a comment-anchor-pair id (range protocol)
type OutputName = string;  // a Shiny output id (renderIrid / iridOutput)
type Channel    = string;  // a Shiny input id; also the per-channel seq key

// Optimistic-update echo gate. A missing gate (null) = a programmatic write,
// applied unconditionally; present = drop if the channel's seq has advanced.
interface EchoGate { seq: number; channel: Channel; }

// DOM listener options (mirrors R's wire_dom_opts()). DOM channels only.
interface DomOpts {
  preventDefault: boolean;
  stopPropagation: boolean;
  capture: boolean;
  passive: boolean;
  filter: string | null;   // JS predicate over `e`, or null for none
}

// Rate-limit timing, discriminated on mode.
type Timing =
  | { mode: "immediate" }
  | { mode: "throttle"; ms: number; leading: boolean }
  | { mode: "debounce"; ms: number };
```

### Server → client (three custom messages)

```ts
// irid-config — runtime options pushed at session start (before the mount).
interface IridConfig {
  staleTimeout: number | null;   // ms before the stale indicator shows; null disables
}

// irid-render — one Shiny flush's render, an ordered op list applied in one pass.
interface IridRender { ops: Op[]; }

type Op = OpMutate | OpWire | OpWidgetInit | OpAttr | OpText;

// Structural comment-anchor range mutation (Each / When / Match). Each part
// always present; an unused part is [] (a no-op).
interface OpMutate {
  kind: "mutate";
  id: AnchorId;
  removes: AnchorId[];
  inserts: string[];          // outerHTML fragments, parsed in the container's context
  order: AnchorId[];
}

// Attach one client->server channel's listener (one op per channel).
// Discriminated on `source` (where the event comes FROM — the mirror of OpAttr's
// outbound `target`): a DOM event carries listener options; widget adds none.
type OpWire = OpWireDom | OpWireWidget;
interface OpWireCore {
  kind: "wire";
  id: ElementId;
  event: string;
  channel: Channel;           // namespaced Shiny input id; per-channel seq key
  timing: Timing;
  coalesce: boolean;          // gate on server-idle (backpressure)
}
interface OpWireDom extends OpWireCore {
  source: "dom";
  domOpts: DomOpts;
  clientOnly: boolean;        // config-only wire: apply flags, never round-trips
}
interface OpWireWidget extends OpWireCore { source: "widget"; }

// Mount a widget instance into its container.
interface OpWidgetInit {
  kind: "widget-init";
  id: ElementId;
  name: string;               // registry name (defineWidget)
  props: Record<string, unknown>;   // merged initial props ({} when none)
}

// A bound value pushed to its sink, discriminated on `target` (where the value
// GOES — the mirror of OpWire's inbound `source`). Identical shape for both
// sinks; `target` selects how the client applies it:
//   "dom"    — property/attribute write on getElementById(id), applied inline.
//   "widget" — a prop write; the client collects all target="widget" ops in the
//              message per id and calls the widget's update() once at the end
//              with the merged { attr -> value } (one redraw).
interface OpAttr {
  kind: "attr";
  target: "dom" | "widget";
  id: ElementId;
  attr: string;
  value: unknown;
  gate: EchoGate | null;      // null = programmatic; else gated on the channel's seq
}

// Text replace inside a comment-anchor range — its own kind, not an attr variant
// (a range-content replace with a different shape: no `attr`, no gate).
interface OpText {
  kind: "text";
  id: AnchorId;
  value: string;              // "" is the clear-the-range signal
}

// irid-ready — the mount is fully wired (post-render barrier). Sent after the
// flush's irid-render drains, so a client that has seen it has the whole render
// applied and every server observer registered.
interface IridReady {
  output: OutputName | null;  // output name (renderIrid), or null (top-level iridApp)
}
```

### Client → server (unchanged)

```ts
// Every client->server payload: irid's transport envelope, sent via
// Shiny.setInputValue(channel, _, {priority: "event"}). Event data (DOM event
// fields, or a widget sendEvent payload) rides under `data`.
interface IridClientEvent {
  id: ElementId;              // source element id (for module namespacing)
  seq: number;                // per-channel monotonic sequence (the echo gate)
  data: Record<string, unknown>;
}
```

## Client apply algorithm (irid-render)

```
function applyRender(msg):
  widgetAcc = {}                         # id -> { attr -> value }
  for op in msg.ops:
    switch op.kind:
      "mutate":      applyMutate(op)
      "wire":        applyWire(op)
      "widget-init": applyWidgetInit(op)
      "text":        applyText(op)               # applied now
      "attr":
        if op.target == "dom":
          applyDomAttr(op)                       # gate-checked, applied now
        else:                                    # target == "widget" — deferred + merged
          if not isStaleEcho(op.gate): widgetAcc[op.id][op.attr] = op.value
  for id, values in widgetAcc:           # one update() per widget, after all ops
    applyWidgetValues(id, values)        # update() if handle live, else buffer in w.pending
  scheduleBindAll()                      # once, after the synchronous pass
```

Single `Shiny.bindAll` after the pass (replacing the per-mutate deferral).

## Invariants preserved

- **One paint** — every render op in one frame, applied synchronously.
- **Ordering** — emission order = apply order; `mutate` precedes the
  `wire`/`widget-init`/`attr` depending on its element. The `<select value=rv>`
  options-before-value case holds (control-flow ops precede the binding's
  `attr` (target="dom") in the list).
- **Single widget redraw** — preserved, now via client-side per-widget collection
  within the atomic apply (instead of a server-side merge).
- **`irid-ready` barrier** — `irid-render` drains before ready's `onFlushed`
  (armed at the depth-0 mount); unchanged.
- **Stale-echo gate** — per-op `gate` on every `attr` op (both targets), checked
  the same way; widget gates are now per op rather than a `valueGates` map.

## Op-modeling principles

Two tests settled these shapes; keep them in mind when adding ops.

- **A list field belongs to one op only when its elements are the *internal
  structure* of a single operation — not when each is a complete op on its own.**
  `mutate`'s `removes`/`inserts`/`order` stay one op: they are the three ordered
  phases of one container reconciliation (the output of `plan_reconcile`), with
  inter-phase dependencies, and `order` is an indivisible whole-sequence value.
  `wire`, by contrast, carried a `rows[]` array only to save frames — each row is
  a complete, independent registration — so it flattened to one op per channel.
  Test: *could each element stand alone as its own op?* Yes → flatten; no → keep.

- **When the producer knows a discriminant, put it on the wire; don't make the
  client infer it.** `attr`'s `target` and `wire`'s `source` are explicit even
  though the client could often guess (probe the widget registry, the anchor
  map). The server knows for free (the binding's target, the event's source), and
  inference couples the client to mutable state and op-processing order — an
  `attr` that arrived before its `widget-init` would mis-route. Explicit beats
  inferred.

## Implementation plan (incremental, folds into PR #68)

1. **Protocol types** (`srcts/src/protocol/messages.ts`): replace the standalone
   message interfaces + `IridBatch` with `IridRender` + the `Op` union (one
   `OpAttr` with `target`; `OpText` separate); drop the `IridAttrWidget`-with-maps
   shape.
2. **Client** (`handlers.ts`): one `irid-render` handler + the apply algorithm
   above (target="widget" accumulation; single bindAll). Delete the four
   standalone render handlers. Keep `irid-config` / `irid-ready`. Rebuild `inst/`
   bundles.
3. **Server codec** (`R/encode.R`): `msg_irid_render(ops)`; per-op constructors
   carrying `kind`; collapse `msg_irid_attr_*` to one `attr` form (`target` ∈
   {dom, widget}, single key) plus `text`. Remove `msg_irid_attr_widget`'s map form.
4. **Server send path** (`R/mount.R`): `irid_send` appends ops to the one buffer;
   widget prop writes emit single `attr` (target="widget") ops (no
   `irid_queue_widget_attr`). Delete the widget-pending map + its drain. Rename
   the drain message to `irid-render`.
5. **Tests**: update the mock-session flatten + message-shape assertions; the
   widget-batching unit tests now assert client-side collection semantics via the
   op list (one `widget-attr` op per write, in order) rather than a server `values`
   map. Re-run unit + e2e (plotly exercises the single-redraw path).
6. **Docs**: fold into `ARCHITECTURE.md` (replace the `irid-batch` section with
   the unified `irid-render` protocol); delete this doc.

## Settled choices

- **Message name**: `irid-render`. "batch" reads oddly once it is *the* render
  message (it is a batch even with one op); "render" names what it is.
- **`wire` granularity**: one op per channel (the schema above). The old `rows[]`
  grouping was itself a frame-saving micro-batch — the same problem `irid-render`
  now solves globally — so it is vestigial. The client registers each channel
  independently and idempotently and never uses the grouping, so flattening keeps
  every op a single atomic unit with no information lost.
