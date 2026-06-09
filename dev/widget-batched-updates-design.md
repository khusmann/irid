# Widget batched updates — design

**Status:** Implemented — `irid_queue_widget_attr` in `R/mount.R`, the
`update(values)` client dispatch in `inst/js/irid.js`, and the CodeMirror
example migration. Tests in `tests/testthat/test-widget-batching.R`.
**Date:** May 2026

---

## 1. Motivation

irid's IridWidget framework routes each reactive prop binding through
its own `irid-attr` message. One reactiveVal change → one observer fire
→ one `sendCustomMessage("irid-attr", …)` → one `update(key, value)`
call on the JS side. This works for widgets with a single bound prop
(`content` on CodeMirror, alone) but breaks down once a widget exposes
**multiple bound pieces of state that need to stay coherent**.

### The cursor-binding bug that prompted this doc

Attempting to add a bound `cursor` reactiveVal alongside `content` on
the CodeMirror demo surfaced a multi-binding race:

1. User types "a" — JS sends `change` (seq=1) and `cursor-changed`
   (seq=2) on separate timer paths.
2. Server processes both, writes both reactiveVals, each binding
   observer fires independently and sends its own `irid-attr` message.
3. **Content echo** arrives at the client → JS dispatches
   `view.dispatch({changes: …})` to replace the doc. The dispatch
   itself triggers `updateListener` with `selectionSet=true`
   (CodeMirror repositions the cursor after a doc replace), which
   sends *another* cursor-changed event.
4. That spurious cursor-changed bumps the sequence past the pending
   cursor echo. The pending cursor echo arrives, fails the stale-echo
   gate, gets dropped.
5. Cursor reactiveVal now holds whatever position CodeMirror landed
   on after the replace (often 0). Next echo of that stale cursor
   moves the editor cursor to 0. The user's next keystroke inserts at
   position 0 — visibly, characters "disappear" from the right.

The bug has **three distinct causes**, two of which are already fixed
in the current PR — this doc covers the remaining one (wire batching):

| Cause | Fix | Status |
|---|---|---|
| Server-initiated dispatches fire the library's change listener, generating spurious echo events | Library-specific transaction marker (CM6 `Annotation`, Plotly's `Plotly.react()` tracking, …) — wrapper-author responsibility | Wrapper / JS |
| `force-send-on-no-op` sent *every* binding on the source element after *every* event, even bindings the handler didn't touch — debounced bindings' stale server reactiveVals were echoed back, overwriting in-flight client state | **Per-binding force-send** — `write_back` and `make_autobind_handler` attach an `irid_write_targets` attribute to their returned handler; `compose_handlers` unions; `mount.R` filters source bindings to only those whose `attr` is in the firing event's declared targets; hand-rolled handlers declare nothing → no force-send | **Landed in this PR** |
| Multiple bound props ride independent `irid-attr` messages — they race on the wire, exposing partial state mid-transition | **Per-widget batching** — coalesce all `irid-attr` messages targeting the same widget id in the same Shiny flush into one wire message with a `values: {…}` map | **Landed (this doc)** |

### Why batching is still worth doing (after the force-send fix)

The per-binding force-send fix eliminates the correctness bug — the
CodeMirror demo can fire `cursor-changed` during typing without
wiping content, because the cursor-changed handler doesn't declare
`content` as a write target, so force-send no longer fans the stale
content value back to the client.

What remains is the **wire-level race when multiple bindings on one
widget update in the same flush**. Each binding observer still sends
its own `irid-attr`; on the client, the messages arrive sequentially.
For libraries with incremental update primitives (CodeMirror handles
separate `view.dispatch()` calls fine, especially with the
server-update annotation pattern), the gap between messages is
invisible. For libraries with atomic-render primitives (Plotly,
Mapbox), each `irid-attr` triggers a full re-render — two messages =
two redraws = flash.

So batching is a **visual-atomicity** improvement, not a correctness
one. It's the cleaner long-term shape and enables atomic-render
libraries to wrap cleanly, but it doesn't unblock the editor-class
demos that work today via the per-binding force-send fix.

This doc covers the framework piece. The wrapper-side marker pattern
is documented in [ARCHITECTURE.md](../ARCHITECTURE.md#widgets) and
illustrated per-wrapper.

### Why "lump the state into one prop" is not the universal answer

The natural workaround — "model conjoined state as one bound prop with
a structured value" (e.g. `editor = reactiveStore(list(content,
cursor))`) — works for libraries with small, well-defined atomic
state (Plotly's `{data, layout, frames}`, Mapbox's `{center, zoom,
bearing}`). It does **not** scale for editor-class libraries whose
internal state is sprawling and open-ended (CodeMirror has content,
selection, scroll position, fold state, undo history, decorations,
language, theme, …). Asking wrapper authors to predict and bundle every
field a consumer might ever want to bind is a non-starter.

So the framework needs to support **multiple independent bound props
with atomic-on-the-wire delivery**. Each piece is its own reactiveVal
(fine-grained reads, independent observability), but when multiple
fire in the same server flush, they arrive at the client as one
coherent update.

---

## 2. Design

### Wire shape — always `values: {…}` for widget target

The widget branch of `irid-attr` switches to a single canonical shape:

```js
{
  target:   "widget",
  id:       "el-3",
  values:   { content: "...", cursor: {line: 1, ch: 1} },
  sequence: 42        // optional, single value for the whole batch
}
```

`values` is **always** a `{attr → value}` object, even for a
single-attribute update. No dual single/batch shape — one canonical
form, applied uniformly. A single-prop change is just a one-entry
`values` map.

The existing single-attribute shapes for `target: "dom"` and
`target: "text"` are unchanged.

### Widget contract — `update(values)`

The widget factory's `update` hook receives the batch directly:

```js
irid.defineWidget("codemirror", function (el, props, send) {
  // ...
  return {
    update: function (values) {
      // values = {content: "...", cursor: {line, ch}}  (one or more keys)
      view.dispatch({
        changes:   "content" in values
                     ? { from: 0, to: view.state.doc.length, insert: values.content }
                     : undefined,
        selection: "cursor"  in values
                     ? { anchor: cursorToPos(view.state, values.cursor),
                         head:   cursorToPos(view.state, values.cursor) }
                     : undefined,
        annotations: SERVER_UPDATE.of(true)
      });
    },
    destroy: function () { view.destroy(); }
  };
});
```

This is a **breaking contract change** for widget authors. Greenfield
project, no deployed consumers — the change is mechanical, well-scoped,
and clarifies the contract (every update is potentially multi-key, the
hook just treats `Object.keys(values)` uniformly).

### Server flow — accumulate, drain on flush

Per-widget binding observers stop sending `irid-attr` immediately when
they fire. Instead they append `(attr, value)` to a per-widget pending
map on `session$userData`. A one-shot `session$onFlushed` handler
drains every pending map at flush end, sending one `irid-attr` per
widget id with the full `values` object.

```r
# Sketch — actual code lives in mount.R
pending <- session$userData$irid_widget_pending
if (is.null(pending)) {
  pending <- new.env(parent = emptyenv())
  session$userData$irid_widget_pending <- pending
  session$onFlushed(function() {
    for (id in ls(pending)) {
      msg <- pending[[id]]
      session$sendCustomMessage("irid-attr",
        list(id = id, target = "widget", values = msg$values,
             sequence = msg$sequence))
    }
    session$userData$irid_widget_pending <- NULL
  }, once = TRUE)
}
entry <- pending[[b$id]] %||% list(values = list(), sequence = NULL)
entry$values[[b$attr]] <- val
if (!is.null(seq_for_this_observer)) entry$sequence <- seq_for_this_observer
pending[[b$id]] <- entry
```

Notes:

- **Sequence handling.** Each batched message carries one sequence,
  which is the highest sequence number contributed by any binding in
  the batch (or `NULL` for purely programmatic updates with no event
  driver). The stale-echo gate continues to work — it compares the
  batch's sequence against `sequences[id]` exactly as today.
- **Ordering across widgets.** Different widgets get separate batches
  (one message per widget id). Inter-widget ordering is preserved by
  the order observers fire within the flush.
- **Cross-flush updates** still send separate messages — batching is
  intra-flush only. A reactiveVal that updates in one flush and
  another in a later flush produces two messages, as today.

### Client dispatch — single `update(values)` call per message

```js
// inst/js/irid.js — irid-attr widget branch
if (msg.target === 'widget') {
  var w = widgets[msg.id];
  if (!w) return;
  if (typeof w.handle.update === 'function') {
    w.handle.update(msg.values);
  }
  return;
}
```

The stale-echo gate runs upstream of this branch and is unchanged.

### (Per-binding force-send already landed)

Already implemented in this PR — see the in-tree code: `write_back`
and `make_autobind_handler` attach `irid_write_targets` to their
returned handlers; `compose_handlers` unions; `process_tags` stores
the targets on each event row; `mount.R`'s force-send loop filters
`source_bindings` by `ev$write_targets`. Hand-rolled handlers (no
attribute) skip force-send entirely. This doc keeps it on the list
for narrative continuity but no further work is required.

---

## 3. What this enables

### Multi-state widgets without manual coordination

Wrapper authors expose as many bound props as makes sense for their
library, without worrying about wire-level race conditions:

```r
CodeMirror <- function(
  content,        # reactiveVal: editor body
  cursor   = NULL,    # reactiveVal: {line, ch}
  scroll   = NULL,    # reactiveVal: scrollTop in px
  language = "javascript",
  ...
) {
  IridWidget(
    name  = "codemirror",
    props = list(content = content, cursor = cursor, scroll = scroll,
                 language = language),
    events = list(
      # Single change event carries everything that moved; the wrapper
      # writes through each writable callable.
      change = function(e) {
        if (can_accept_write(content)) content(e$content)
        if (can_accept_write(cursor) && !is.null(e$cursor)) cursor(e$cursor)
        if (can_accept_write(scroll) && !is.null(e$scroll)) scroll(e$scroll)
      }
    ),
    ...
  )
}
```

Server multi-writes (e.g. a "go to line N" button that updates both
content and cursor) arrive at the JS widget as one atomic update.

### Programmatic state restoration

```r
restore_session <- function(snapshot) {
  content(snapshot$content)
  cursor(snapshot$cursor)
  scroll(snapshot$scroll)
}
```

All three writes fire in the same Shiny flush → one batched
`irid-attr` → one `view.dispatch` with all three pieces → no
intermediate render flash.

### Cleaner widget contract

The `update(values)` shape is simpler than `update(key, value)`:
widget authors handle "what's in this batch" uniformly via
`Object.keys(values)` / `if ("foo" in values)`. The pre-batch shape
required them to mentally track "for each separate update call, which
single key am I handling" — easy to mishandle when multiple keys
interact.

---

## 4. Non-goals

- **Cross-flush batching.** Only intra-flush bindings coalesce. A
  reactiveVal updating now and another in 500ms produces two messages.
  Cross-flush batching would require delaying delivery, which fights
  Shiny's reactive model.
- **DOM / text target batching.** This design only changes the widget
  branch. `target: "dom"` and `target: "text"` keep their existing
  single-value shape — there's no analogous race because each DOM
  attribute write is its own concern (no JS factory mediating).
- **Generic feedback-loop prevention.** The framework can't generically
  know whether a JS state change came from the server-applied update or
  from genuine user action. Wrapper authors handle this with their
  library's idioms (CM6 `Annotation`, Plotly `react()` tracking,
  Mapbox event source flags, …). The framework's stale-echo gate
  handles transient sequencing races; it's not a substitute for
  library-level loop-breaking.
- **A higher-level "transaction" R-side API.** `withProgress`-style
  batching wrappers are out of scope. Shiny's natural flush boundary
  is the batching unit.

---

## 5. Migration

Greenfield — no deployed widgets to migrate. The CodeMirror demo is
the only consumer in-tree; its `update(key, value)` hook becomes
`update(values)` mechanically:

```js
// Before
update: function (key, value) {
  if (key === "content") { /* ... */ }
  else if (key === "language") { /* ... */ }
}

// After
update: function (values) {
  if ("content"  in values) { /* ... uses values.content ... */ }
  if ("language" in values) { /* ... uses values.language ... */ }
}
```

No `else if` chain — every key that's present in the batch is applied
in one transaction.

---

## 6. Test plan

- **Single-prop write** → one `irid-attr` with one-entry `values`
  map. Existing single-binding tests adapt to assert the new shape.
- **Multi-prop write in one flush** (event handler writing two
  reactiveVals) → one `irid-attr` with multi-entry `values` map.
- **Multi-prop write across two flushes** → two separate `irid-attr`
  messages, one per flush.
- **Stale-echo gate** still drops batches whose sequence is behind
  `sequences[id]`.
- **Sequence selection**: a batch driven by an event with seq=N
  carries `sequence = N`. A batch driven by purely programmatic
  reactive cascades carries no sequence.
- **Multi-widget flush** → multiple `irid-attr` messages (one per
  widget id), each batched within its own widget.

---

## 7. Open questions

- **Pending-state location.** `session$userData$irid_widget_pending`
  is a session-scoped env; an alternative is a closure variable
  inside `irid_mount_processed`. Closure scoping is cleaner but
  doesn't compose across nested mounts cleanly. Session-scoped is
  simpler and matches how `irid_current_sequence` is already stored.
- **`values` field ordering.** Within a batch, key insertion order
  follows binding observer fire order. JSON object key order is
  preserved on the wire in practice (jsonlite + every modern JS
  engine), so widgets that depend on a specific apply order can
  rely on it. Document this or treat it as undefined?
- **Empty batches.** If all bindings for a widget fire but each
  evaluates to a value identical to its last sent value, do we send
  an empty-`values` batch (semantically "the flush completed with no
  changes") or skip? Suggest: skip, no message for an empty batch.
  The force-send-on-no-op path for event echos is the explicit
  exception — those don't go through the binding observer path.
