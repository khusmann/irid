# `.listener` Element Prop — Design Document

**Status:** Proposed
**Date:** May 2026

---

## 1. Motivation

The element-level `.prevent_default` prop is the first member of an emerging
family. As irid grows, three more DOM-listener behaviors are likely to land:

- `stopPropagation()` — prevent bubbling; common pair with `preventDefault`
  for nested clickable regions
- `addEventListener({capture: true})` — fire during capture phase so a parent
  can intercept before children
- `addEventListener({passive: true})` — promise not to call `preventDefault`
  so the browser can optimize `touchstart`/`touchmove`/`wheel`

All four have the same shape: a per-event boolean. Today's `.prevent_default`
accepts a logical scalar (broadcasts to every event on the element) or a
named list keyed by DOM event for per-event overrides. The other three would
naturally inherit that same shape.

Two designs scale this family poorly:

- **Flat siblings** (`.prevent_default`, `.stop_propagation`, `.capture`,
  `.passive`) clutter the element signature and, more painfully, force
  parallel keyed lists for the per-event case. Renaming an event handler
  means chasing the rename through four lists. Documentation either
  spreads across four Rd pages or collapses into a synthetic
  `listener-props.Rd` that documents four props with identical shape rules.
- **Folding into `event_*()`** (`event_immediate(prevent_default = TRUE,
  stop_propagation = TRUE, capture = TRUE, passive = TRUE)`) couples two
  orthogonal concerns. `.event` answers *when/how* the event is delivered
  (timing, transport); these flags answer *how the browser should treat the
  listener*. The canonical case suffers most: today `tags$form(onSubmit =
  handle, .prevent_default = TRUE)` becomes `tags$form(onSubmit = handle,
  .event = event_immediate(prevent_default = TRUE))`, which forces a
  timing choice the author didn't want to make and overrides the per-event
  default rule in [process_tags.R:479](../R/process_tags.R#L479).

---

## 2. Design

Introduce a single element-level prop `.listener`, with a constructor
`listener_opts()` that holds the listener flags. Deprecate `.prevent_default`.

```r
listener_opts(
  prevent_default = FALSE,
  stop_propagation = FALSE,
  capture = FALSE,
  passive = FALSE
)
```

Returns an `irid_listener_opts` struct.

`.listener` mirrors `.event`'s shape:

- A single `listener_opts()` struct broadcasts to every event on the element.
- A named list keyed by lowercase DOM event (or `on`-prop name) overrides
  per-event. Unmapped events get default flags (all `FALSE`).

```r
# Scalar — all events on the element
tags$form(
  onSubmit = handle,
  .listener = listener_opts(prevent_default = TRUE)
)

tags$a(
  onClick = handle,
  .listener = listener_opts(prevent_default = TRUE, stop_propagation = TRUE)
)

# Per-event — flags for each event colocated
tags$div(
  onClick = handleClick,
  onWheel = handleWheel,
  .listener = list(
    click = listener_opts(prevent_default = TRUE, stop_propagation = TRUE),
    wheel = listener_opts(passive = TRUE)
  )
)
```

Validation, normalization, and per-event resolution reuse the existing
machinery (`normalize_event_keyed_list()`, the lookup-closure pattern used
for `.event` and `.prevent_default` today).

---

## 3. Why this beats the alternatives

1. **Per-event colocation.** All flags for an event live together. Renaming
   `onClick` to a different event touches one list key, not four.
2. **Mirrors `.event`.** Two structured element-config props, same mental
   model (scalar struct or named list of structs). Authors learn the shape
   once.
3. **One Rd page.** All listener flags surface as arguments to
   `listener_opts()` with a single help entry. No four-way duplication.
4. **Element signature stays flat.** `.event = ..., .listener = ...` is two
   slots regardless of how many flags are set.
5. **Orthogonal to timing.** `.event` and `.listener` can vary independently
   without one forcing a choice on the other.

Cost: the scalar case becomes `listener_opts(prevent_default = TRUE)`
instead of `.prevent_default = TRUE` — one constructor to learn, slightly
wordier. Acceptable given the family resemblance and per-event win.

No shortcut alias for the common case (no surviving `.prevent_default`
backed by `.listener`). One way to express the behavior; readers don't
have to learn two.

---

## 4. Interaction with iridwidgets

A planned htmlwidgets-style mechanism for binding JS libraries surfaces an
asymmetry that *strengthens* the `.event` / `.listener` split:

- **`.event` is universal.** Timing/transport applies to any event, whether
  it's a DOM event on a real element or a library callback (e.g.,
  `plotly_relayout`). Debouncing, throttling, and coalescing all make sense
  for widget callbacks. No special API needed beyond what tags already have.
- **`.listener` is DOM-only.** `passive`, `capture`, `preventDefault`,
  `stopPropagation` are `addEventListener` semantics. A library callback
  isn't registered through `addEventListener` on a real element, so the
  flags have nothing to attach to.

Had `prevent_default` been folded into `event_*()`, this asymmetry would
have been silent: `event_debounce(100, prevent_default = TRUE)` on a widget
event would ignore half its arguments with no clean way to surface the
error. With separate props, the boundary is inspectable per-prop.

Implication for widget authors: each widget event needs metadata declaring
whether it's DOM-backed. `.listener` set on a non-DOM-backed event raises
an error at tag-processing time. Widgets that *are* DOM-backed (custom
elements emitting real CustomEvents) honor `.listener` naturally:
`capture` and `stopPropagation` always work; `preventDefault` works if
the widget dispatches cancelable events.

---

## 5. Related planned work

Three planned designs all touch the same client-side dispatch layer and
should be reconciled before any of them land:

- **Client-side event queue** — [dev/client-event-queue-design.md](client-event-queue-design.md).
  Per-element FIFO slot queue with preemptive flush, fixing the cross-stream
  ordering race where an immediate event overtakes a pending debounced one.
- **Client-side event filtering** — sketched in
  [ARCHITECTURE.md:444-463](../ARCHITECTURE.md#L444-L463). Adds a `filter`
  argument that accepts a JS expression evaluated against the event object
  client-side; falsy result drops the event before it reaches the server.
  A `key_filter()` helper covers the common Enter/Esc case.

The filter sketch currently places `filter` *inside* `event_*()`
constructors:

```r
.event = list(keydown = event_immediate(filter = key_filter("Enter")))
```

This is the same placement choice §1 and §5.2 rejected for `prevent_default`,
but the argument doesn't translate cleanly. `filter` decides *whether* the
event fires at all — arguably closer to timing/transport (both gate
dispatch) than to listener flags (which configure how the browser treats
the listener). Three reasonable placements exist:

1. **Inside `event_*()`** as currently sketched. Gating sits with timing,
   which is also gating in a sense.
2. **Inside `listener_opts()`**. Treats `filter` as another listener-side
   browser concern. Awkward — the other listener flags are static booleans;
   `filter` is a JS expression.
3. **A third structured prop `.filter`** mirroring `.event` and `.listener`
   shape (scalar JS-expr struct or named list per event). Maximally
   orthogonal, but a third prop to learn.

Decide before filtering lands. The iridwidgets asymmetry from §4 may help:
`filter` requires a real DOM event to evaluate against, so it shares
`.listener`'s DOM-only nature, weakly arguing against placement (1).

The todo-example race in [ARCHITECTURE.md:463](../ARCHITECTURE.md#L463)
motivates both the event queue and the filter design — restoring
`onKeyDown = \(e) if (e$key == "Enter") add_todo()` needs both fixes.

---

## 6. Rejected alternatives

### 6.1 Flat sibling props

```r
tags$div(
  onClick = handleClick,
  onWheel = handleWheel,
  .prevent_default = list(click = TRUE),
  .stop_propagation = list(click = TRUE),
  .passive = list(wheel = TRUE)
)
```

Rejected for the per-event fragility (parallel keyed lists), signature
clutter, and Rd-page duplication described in §1.

### 6.2 Fold into `event_*()`

```r
tags$form(
  onSubmit = handle,
  .event = event_immediate(prevent_default = TRUE)
)
```

Rejected because (a) listener flags are orthogonal to timing/transport,
(b) the common case is forced to invent a timing choice it didn't want,
(c) the per-event default rule for timing in [process_tags.R:479](../R/process_tags.R#L479)
becomes inexpressible alongside a listener flag, and (d) the iridwidgets
asymmetry in §4 has no clean error surface.

This does *not* automatically rule out folding `filter` into `event_*()`
— see §5 for that placement discussion, which is genuinely open.

### 6.3 Keep `.prevent_default` as a shortcut alongside `.listener`

Two ways to express the same behavior. Readers learn both, doc has to
explain precedence, errors when both are set. Reject in favor of one
idiom.

---

## 7. Migration

`.prevent_default` is deprecated with a warning that points to
`.listener = listener_opts(prevent_default = ...)`. Both shapes (scalar
and named list) translate mechanically. Remove `.prevent_default` after
one release cycle.

Files affected:

- [R/event.R](../R/event.R) — add `listener_opts()` constructor and Rd
- [R/process_tags.R:145-200](../R/process_tags.R#L145-L200) — replace
  `normalize_element_prevent_default()` with a `normalize_element_listener()`
  that returns a per-event lookup closure yielding a struct; deprecation
  shim for `.prevent_default`
- [R/process_tags.R:479-489](../R/process_tags.R#L479-L489) — write the
  resolved flags onto each pending event entry
- [R/mount.R:106](../R/mount.R#L106) — extend the per-event message payload
  to carry the new flags alongside `preventDefault`
- JS client — apply `stopPropagation`, `capture`, `passive` in addition to
  the existing `preventDefault`
- [TESTING.md](../TESTING.md) — extend the `.prevent_default` checklist to
  cover the full `listener_opts()` surface
- [NEWS.md](../NEWS.md) — breaking-change entry
