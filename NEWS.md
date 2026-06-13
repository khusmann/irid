# irid (development version)

## Breaking changes

* Event and binding dispatch config now rides the slot it configures via a
  single carrier, `wire(subject, timing, coalesce, dom_opts)`. The
  element-level `.event` and `.prevent_default` props are removed, along
  with `event_immediate()` / `event_throttle()` / `event_debounce()` —
  replaced by the pure timing shapes `wire_immediate()` /
  `wire_throttle(ms, leading)` / `wire_debounce(ms)` (with `coalesce`
  hoisted onto `wire`) and `wire_dom_opts(prevent_default,
  stop_propagation, capture, passive)`. A bare handler/reactive in a slot
  still works as sugar for `wire(callable)`.
* A DOM event is now bound *or* handled, never both. Combining a
  `value`/`checked` binding with an explicit `on*` handler for the same
  event (e.g. `value = rv, onInput = ...`) is an error; use
  `value = reactiveProxy(get, set)` for a synchronous write side-effect, or
  observe the bound reactive for an async reaction. Two explicit handlers on
  the same event also error (no composition).

## New features

* `IridWidget()` — wrap arbitrary JavaScript libraries (CodeMirror,
  Plotly, Leaflet, ...) as reactive irid components. Props are
  two-way-capable by default (symmetric with DOM `value`/`checked`): a
  callable prop reads inbound and accepts write-back when the widget JS
  calls `setProp(key, value)`. Genuine notifications flow back via `events`
  (`sendEvent`). Composes inside `When`, `Each`, and `Match` like any other
  irid construct. See `examples/codemirror.R`.

## Bug fixes

* Reactive bindings no longer flicker when user activity outpaces the
  server's echo. The optimistic-update protocol's stale-echo skip
  used to apply only to focused text inputs; it now covers all
  reactive bindings.

# irid 0.2.0

## Breaking changes

* Auto-bind: `value` and `checked` accept any callable (`reactiveVal`,
  store leaf, `reactiveProxy`, plain function) and two-way bind
  automatically. Reads populate the IDL property; DOM events write back
  through the same callable. When auto-bind coexists with an explicit
  `on*` handler on the same event, the auto-bind write always lands
  first regardless of attribute order. Works on `<input>`, `<textarea>`,
  `<select>` for `value`; checkboxes and radios for `checked`.
* `event_immediate()` / `event_throttle()` / `event_debounce()` no longer
  wrap a handler. They return a config used with the element-level
  `.event` prop. Per-handler timing is gone:

  ```r
  # OLD
  tags$input(value = field, onInput = event_debounce(\(e) field(e$value), ms = 500))

  # NEW
  tags$input(value = field, .event = event_debounce(500))
  ```

  `.event` takes a single config or a named list keyed by lowercase DOM
  event for per-event overrides.
* `prevent_default` moved off the event constructors onto the element as
  `.prevent_default`. Logical scalar broadcasts; named list overrides per
  event; unmapped events default to `FALSE`.
* `Each()` redesigned. The callback receives a per-item callable (mini-
  store for records, scalar accessor for atomics) and an optional `pos`.
  Reconciliation moves to `by`: `NULL` (default) for positional, `\(x)
  x$id` for keyed. In-place value changes update accessors without DOM
  recreation; keyed reorders move DOM nodes.
* `Match()` projects the bound value as a mini-store for the active
  case's body (records) or the bare callable (scalars). Active-case
  change fully tears down the previous case and mounts the new one fresh.
* `When()` is a fixed-shape binary specialization of `Match()`. `yes` /
  `otherwise` must be 0-arg functions returning tag trees; each
  activation builds a fresh tree.
* `Index()` removed. Covered by `Each(items, fn)` with default `by = NULL`.

## New features

* `reactiveProxy()` — callable built from a `get` reader and optional
  `set` writer for validation, transforms, and read-only views at
  component boundaries.
* `reactiveStore()` — hierarchical reactive state container. Bare named
  lists become navigable sub-nodes; everything else (including
  `I()`-wrapped lists) is a `reactiveVal` leaf. Branch writes replace
  and must list every locked key; `node$key(value)` is the single-slot
  path.
* `innerHTML` is now a DOM property, so reactive writes hit the IDL
  property directly.

## Bug fixes

* Reactive text children use a comment-anchor pair instead of a `<span>`
  wrapper, so reactive text no longer adds spurious wrappers to the DOM.

# irid 0.1.0

Initial release.

## Features

* Reactive attributes and children — pass functions to any tag attribute or
  text child for fine-grained DOM updates without re-rendering
* Controlled inputs — bind `value` directly to a `reactiveVal` for two-way
  binding without `update*Input()` callbacks
* Composable components — plain functions that accept `reactiveVal`s for
  natural state sharing
* Control flow primitives: `When()`, `Each()`, `Index()`, `Match()`
* Output bindings: `Output()`, `PlotOutput()`, `TableOutput()`, `DTOutput()`
* Event handling with `event_immediate()`, `event_throttle()`, `event_debounce()`
* Embed in existing Shiny apps via `iridOutput()` / `renderIrid()`, or build
  standalone apps with `iridApp()`
* Optimistic updates with sequence-number tracking
