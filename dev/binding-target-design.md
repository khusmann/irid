# Binding target dispatch — design

**Status:** Proposed
**Date:** May 2026

---

## 1. Motivation

irid today routes reactive text children — `\() doc()` as a child of
a tag — via two awkward mechanisms:

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
   (`attr`) is stringly-typed and only one extra routing case exists
   today.

The widget framework (`irid-widget-design-v2.md`,
`dev/plans/irid-widgets-plan.md`) is about to add a third routing
case: callable widget props produce bindings that need to call the
widget instance's `update` hook rather than touch the DOM directly.
Rather than pile a *second* magic string on top of `attr = "irid:text"`
(e.g. `attr = "widget:content"`), this doc introduces an explicit
**`target`** field on binding rows and on `irid-attr` messages,
retires the existing magic string, and folds `irid-text` into
`irid-attr` with `target: "text"`. The widget commit then extends
the field with a third value `"widget"` rather than introducing the
field itself.

After both commits, all binding-update routing is data-driven
dispatch on one field, with one message type (`irid-attr`) carrying
three target values: `"dom"`, `"text"`, `"widget"`. *This* commit
ships the field with the first two; the widget commit adds the
third.

---

## 2. Design

This doc covers the introduction of `target` and the two values that
land in *this* commit (`"dom"` and `"text"`). The widget framework
adds `"widget"` as a third value in a subsequent commit; that
extension is forward-referenced where relevant but not implemented
here. See § 6 "Relation to other work" and § 7 "Order of work."

### Binding row shape

`process_tags` emits one row per reactive binding into the
top-level `bindings` list. The row gains a `target` field:

| target  | other fields    | meaning |
|---------|-----------------|---------|
| `"dom"` | `attr`, `id`, `fn` | set a DOM attribute or property on `getElementById(id)` |
| `"text"` | `id`, `fn` (no `attr`) | replace the content between the comment-anchor pair `id` with a text node |

(Future, in the widget commit: `"widget"` with fields `attr` (prop
key), `id`, `fn` → calls the widget instance at `id`'s
`update(attr, value, sequence)` hook. The framework presented here
is designed to accept that extension additively.)

Every binding row carries a `target`, always set explicitly — no
defaulting or absence. Existing extraction sites that previously
produced rows without thinking about the field now set it
explicitly: DOM attrs at the auto-bind / `on*` / reactive-attr paths
in `process_tags` get `target = "dom"`; the reactive-text-child
branch gets `target = "text"`.

### `mount.R` dispatch

The binding observer reads `b$target` and constructs the message
shape per case:

```r
lapply(result$bindings, function(b) {
  obs <- observe({
    val <- b$fn()
    msg <- switch(b$target,
      dom  = list(id = b$id, target = "dom",  attr = b$attr, value = val),
      text = list(id = b$id, target = "text",                value = val)
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

Two branches, one message type. The sequence-attaching logic is
shared across both (currently it sits inside the `else` branch
that handles `irid-attr`). The switch is structured so the widget
commit can add a `widget = list(...)` branch without restructuring.

### Wire — `irid-attr`

```js
// target = "dom"
{ id: "irid-3", target: "dom",  attr: "value", value: "hello", sequence: 12 }

// target = "text"
{ id: "irid-5", target: "text",                value: "Count: 42" }
```

The `attr` field is present when `target = "dom"` and absent when
`target = "text"` (text replaces the entire range; no attribute name
applies). Sequence numbers attach to whichever target applies, with
the same source-match rule as today.

### Wire — `irid-text` is removed

The `irid-text` custom message handler in `inst/js/irid.js` is
deleted. Its body — anchor-pair lookup, detach old children with
`Shiny.unbindAll`, insert text node before the end anchor — moves
into the `target === "text"` branch of the unified `irid-attr`
handler.

### Client handler structure

```js
Shiny.addCustomMessageHandler('irid-attr', function (msg) {
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

Two branches dispatched on `msg.target`, no string-prefix parsing.
The widget commit adds a `msg.target === "widget"` branch above the
text branch.

### Aside — `source` on `irid-events` (widget commit, not this one)

The widget commit (per `dev/plans/irid-widgets-plan.md`) adds an
analogous discrete-field dispatch on `irid-events`: a new
**`source`** field with values `"widget"` or `"dom"`. The semantic
analog of `target` for events. **Different field name on purpose:**
events have a *source* — they originate somewhere (a DOM listener,
a widget's `send()` call). Attrs have a *target* — they land
somewhere (a DOM property, an anchored range, a widget update hook).
Semantics diverge, names diverge.

The `source` field is not introduced by this commit; it ships with
the widget commit and is specced there. It's mentioned here only
because the field-naming decision (`target` vs `source`) is part
of the same broader cleanup, and a reader of either doc should
understand why the two fields aren't unified under one name.

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
- The `irid-swap` / `irid-mutate` / `irid-events` / `irid-config`
  message types — unchanged in shape. (`irid-events` gains a
  `source` field, but that lands in the widget commit, not this
  one. `irid-widget-init` is new in the widget commit.)

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
- **Client**: `irid-attr` handler tests assert the two branches
  (`"dom"` and `"text"`) dispatch correctly on `msg.target`. The
  deleted `irid-text` handler tests are removed. (The widget commit
  adds tests for the third branch.)

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
  intentionally different — see Design § 2 "Aside — `source` on
  `irid-events`."
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
