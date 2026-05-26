# Binding target dispatch — design

**Status:** Proposed
**Date:** May 2026

---

## 1. Motivation

The widget framework (`irid-widget-design-v2.md`,
`dev/plans/irid-widgets-plan.md`) introduces an explicit **`target`**
field on `irid-attr` messages with values `"dom"` and `"widget"` to
route binding updates between DOM property mutations and widget
`update`-hook calls. That field is the wedge for a broader cleanup
in the existing binding routing.

irid today routes reactive text children — `\() doc()` as a child of
a tag — via two awkward mechanisms inherited from before `target`
existed:

1. **Magic string in the `attr` field.** Reactive text children
   produce a binding with `attr = "irid:text"`, and `mount.R` checks
   for this string to decide whether to send `irid-text` instead of
   `irid-attr`. The `attr` field is named for "DOM attribute being
   set," but the text path doesn't set an attribute at all — it
   replaces the content between a pair of comment anchors. The name
   is already a misnomer.

2. **A separate `irid-text` message type** on the wire with its own
   handler in `irid.js`. Most of its plumbing (anchor lookup,
   detaching old children, inserting new content) overlaps with the
   comment-anchor protocol shared with `irid-swap` / `irid-mutate`,
   but it ships as its own message type because the dispatch field
   (`attr`) is stringly-typed and predates `target`.

Once `target` exists as a discrete dispatch field, the cleanup is
obvious: add a third value `"text"` to the field, retire the
`attr = "irid:text"` magic string, and fold the `irid-text`
message type into `irid-attr` with `target: "text"`. After the
refactor, all binding-update routing is data-driven dispatch on one
field, with one message type (`irid-attr`) carrying three target
values: `"dom"`, `"widget"`, `"text"`.

---

## 2. Design

### Binding row shape

`process_tags` emits one row per reactive binding into the
top-level `bindings` list. The row gains a `target` field:

| target  | other fields    | meaning |
|---------|-----------------|---------|
| `"dom"` | `attr`, `id`, `fn` | set a DOM attribute or property on `getElementById(id)` |
| `"text"` | `id`, `fn` (no `attr`) | replace the content between the comment-anchor pair `id` with a text node |
| `"widget"` | `attr` (the prop key), `id`, `fn` | call the widget instance at `id`'s `update(attr, value, sequence)` hook |

Every binding row carries a `target`, always set explicitly — no
defaulting or absence. Existing extraction sites that previously
produced rows without thinking about the field now set it
explicitly: DOM attrs at the auto-bind / `on*` / reactive-attr paths
in `process_tags` get `target = "dom"`; the reactive-text-child
branch gets `target = "text"`; the widget extraction branch (when
widgets land) gets `target = "widget"`.

### `mount.R` dispatch

The binding observer reads `b$target` and constructs the message
shape per case:

```r
lapply(result$bindings, function(b) {
  obs <- observe({
    val <- b$fn()
    msg <- switch(b$target,
      dom    = list(id = b$id, target = "dom",    attr = b$attr, value = val),
      text   = list(id = b$id, target = "text",                   value = val),
      widget = list(id = b$id, target = "widget", attr = b$attr, value = val)
    )
    seq_info <- session$userData$irid_current_sequence
    if (!is.null(seq_info) && seq_info$source == b$id) {
      msg$sequence <- seq_info$seq
    }
    session$sendCustomMessage("irid-attr", msg)
  }, priority = binding_priority)
  observers[[length(observers) + 1L]] <<- obs
})
```

Three branches, one message type. The sequence-attaching logic is
shared across all three (currently it sits inside the `else` branch
that handles `irid-attr`).

### Wire — `irid-attr`

```js
// target = "dom"
{ id: "irid-3", target: "dom",    attr: "value", value: "hello", sequence: 12 }

// target = "text"
{ id: "irid-5", target: "text",                   value: "Count: 42" }

// target = "widget"
{ id: "irid-7", target: "widget", attr: "content", value: "...", sequence: 12 }
```

The `attr` field is present when `target ∈ {"dom", "widget"}` and
absent when `target = "text"`. (Text replaces the entire range; no
attribute name applies.) Sequence numbers attach to whichever target
applies, with the same source-match rule as today.

### Wire — `irid-text` is removed

The `irid-text` custom message handler in `inst/js/irid.js` is
deleted. Its body — anchor-pair lookup, detach old children with
`Shiny.unbindAll`, insert text node before the end anchor — moves
into the `target === "text"` branch of the unified `irid-attr`
handler.

### Client handler structure

```js
Shiny.addCustomMessageHandler('irid-attr', function (msg) {
  if (msg.target === "widget") {
    var w = widgets[msg.id];
    if (!w) return;
    w.handle.update(msg.attr, msg.value, msg.sequence);
    return;
  }

  if (msg.target === "text") {
    var a = lookupAnchors(msg.id);
    if (!a) return;
    var parent = a.start.parentNode;
    var n = a.start.nextSibling;
    while (n && n !== a.end) {
      var next = n.nextSibling;
      if (n.nodeType === 1) Shiny.unbindAll(n);
      parent.removeChild(n);
      n = next;
    }
    if (msg.value != null && msg.value !== '') {
      parent.insertBefore(
        document.createTextNode(String(msg.value)),
        a.end
      );
    }
    return;
  }

  // target === "dom" — existing path
  var el = document.getElementById(msg.id);
  if (!el) return;
  if (msg.attr === 'value' && document.activeElement === el) {
    // sequence-based focused-input gating (unchanged)
    // ...
  }
  if (PROP_ATTRS[msg.attr]) {
    el[msg.attr] = msg.value;
  } else if (msg.value === false || msg.value === null) {
    el.removeAttribute(msg.attr);
  } else if (msg.attr === 'textContent') {
    el.textContent = msg.value;
  } else {
    el.setAttribute(msg.attr, msg.value);
  }
});
```

Three branches dispatched on `msg.target`, no string-prefix parsing.

### `irid-events` — `source` field

A companion field-rename on `irid-events`. The current message
shape has no field that names "what kind of event source produces
input here"; the existence of a managed-state entry and the call to
`el.addEventListener` are implicit. To support widgets (which need
managed state but no `addEventListener`), the message gains an
explicit `source` field:

```js
// source = "dom" (existing)
{ id: "irid-2", event: "input", inputId: "...", mode: "debounce", ms: 200, ..., source: "dom" }

// source = "widget" (new)
{ id: "irid-7", event: "change", inputId: "...", mode: "debounce", ms: 200, ..., source: "widget" }
```

The client checks `msg.source === "widget"` and skips
`el.addEventListener`; managed-state setup is identical in both
branches. Always set explicitly server-side, no `%||%` default.

**Why a different field name from `irid-attr`'s `target`.** Events
have a source — they originate somewhere (a DOM listener, a widget's
`send()` call). Attrs have a target — they land somewhere (a DOM
property, an anchored range, a widget update hook). The semantics
diverge, so the field names diverge.

---

## 3. Migration

### What changes

- **`R/process_tags.R`**: every existing binding-emission site sets
  `target = "dom"` or `target = "text"` explicitly. The
  reactive-text-child branch (currently emits `attr = "irid:text"`)
  switches to emitting `target = "text"` with no `attr` field.
- **`R/mount.R`**: the binding observer's switch-on-attr-magic-string
  becomes switch-on-`target`. The two-message paths (`irid-text` and
  `irid-attr`) collapse to one (`irid-attr`).
- **`inst/js/irid.js`**: the `irid-text` handler is deleted; its
  body moves into the `target === "text"` branch of the unified
  `irid-attr` handler. The `irid-attr` handler dispatches on
  `msg.target` first, then runs the per-target logic.

### What does not change

- The comment-anchor registry (`anchors` map, `indexAnchors`,
  `lookupAnchors`) — text replacement still uses it.
- The focused-element optimistic-update gating for `target = "dom"` /
  `attr = "value"` — unchanged.
- The sequence-number threading from event observers to binding
  echoes — unchanged.
- The `irid-swap` / `irid-mutate` / `irid-widget-init` /
  `irid-events` / `irid-config` message types — unchanged in shape
  apart from `irid-events`'s new `source` field.

### Backwards compatibility

irid is greenfield / pre-1.0 (per `CLAUDE.md`'s "no backwards
compatibility constraints"). Both clients and servers update in
lockstep; no transitional period needed.

---

## 4. Test plan implications

- **`process_tags`**: every binding emitted has `target` set
  explicitly. Tests that previously matched on `attr = "irid:text"`
  match on `target = "text"` instead. Tests of DOM-attr and `on*`
  paths assert `target = "dom"` on every binding row.
- **`mount.R` dispatch**: a binding with `target = "text"` produces
  one `irid-attr` message with `target: "text"` and no `attr` field.
  A binding with `target = "dom"` produces an `irid-attr` message
  carrying the `attr` field. (The `irid-text` message-type
  expectation in existing tests goes away.)
- **Client**: `irid-attr` handler tests assert the three branches
  dispatch correctly on `msg.target`. The deleted `irid-text`
  handler tests are removed.

---

## 5. Non-goals

- **Folding `irid-swap`/`irid-mutate` into `irid-attr`** with their
  own `target` values. They have substantively different payload
  shapes (HTML fragments, ordered child lists) and substantively
  different client-side machinery (Shiny.bindAll deferral, range
  detach + reinsertion). Unifying them buys a wire-name change at
  the cost of confusing payload polymorphism.
- **Generalizing `target` to other primitives** (`Output`,
  `iridOutput`) — those go through Shiny's own output binding path,
  not irid-attr.
- **Renaming `target` and `source` to share a name.** They are
  intentionally different — see Design § 2 "Why a different field
  name from irid-attr's target."
- **Touching the irid-attr / target = "dom" path** beyond adding the
  field. Existing focused-element gating, PROP_ATTRS table, and
  removeAttribute behavior carry forward verbatim.

---

## 6. Relation to other work

- **`irid-widget-design-v2.md`**: the widget framework introduces
  the `"widget"` value on this taxonomy. After this refactor lands,
  the widget commit adds `target = "widget"` to an already-existing
  field rather than introducing the field itself. The widget plan
  (`dev/plans/irid-widgets-plan.md`) treats this refactor as a
  prerequisite — see that plan's commit ordering.
- **`custom-dom-events-design.md`**: independent. Custom DOM events
  ride the existing `addEventListener` path with a different event
  type name; they don't interact with the binding-target dispatch.

---

## 7. Order of work

The refactor lands as one commit, before the widget framework:

1. R-side: add `target` to the binding row shape in
   `process_tags.R`; every emission site sets it explicitly. Drop
   the `attr = "irid:text"` magic string (the
   reactive-text-child branch emits `target = "text"` with no
   `attr`).
2. R-side: `mount.R` binding observer dispatches on `target` and
   sends one message type (`irid-attr`) with target-dependent shape.
3. JS-side: `irid.js` unifies the `irid-text` handler into the
   `irid-attr` handler. Delete the `irid-text` registration.
4. Update existing tests: replace `attr = "irid:text"` expectations
   with `target = "text"`; replace `irid-text` message-type
   assertions with `irid-attr` + `target: "text"`.
5. Smoke-test: run the existing examples that use reactive text
   (every one — text is everywhere). Verify no visual or behavioral
   regression.

Commit message: `Binding routing: introduce 'target' field, fold irid-text into irid-attr`
