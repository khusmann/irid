# irid (development version)

## Breaking changes

* Auto-bind: `value` and `checked` now accept any callable (`reactiveVal`,
  store leaf, `reactiveProxy`, plain function) and automatically two-way
  bind. Reads populate the prop; DOM events on the element write back
  through the same callable. Explicit `onInput` / `onChange` write handlers
  can be removed when auto-bind covers them. When auto-bind coexists with
  an explicit `on*` handler on the same DOM event, the auto-bind write
  always lands first — your handler observes the post-write state
  regardless of attribute source order. Auto-bind targets the DOM IDL
  property of the same name, so `value = rv` works on `<input>`,
  `<textarea>`, and `<select>`; `checked = rv` works on checkboxes and
  individual radios.
* `event_immediate()`, `event_throttle()`, `event_debounce()` no longer
  wrap a handler. They return a config struct used with the new
  element-level `.event` prop. Per-handler timing is gone — set timing on
  the element instead:

  ```r
  # OLD
  tags$input(value = field, onInput = event_debounce(\(e) field(e$value), ms = 500))

  # NEW
  tags$input(value = field, .event = event_debounce(500))
  ```

  `.event` accepts either a single config or a named list keyed by
  lowercase DOM event name for per-event overrides.
* `prevent_default` moved off the event constructors and onto the element
  as `.prevent_default`. Like `.event`, accepts either a logical scalar
  (broadcasts to every event) or a named list keyed by DOM event for
  per-event overrides; unmapped events default to `FALSE`.

## New features

* `reactiveProxy()` — build a callable from a `get` reader and optional
  `set` writer for validation, transforms, and read-only views at
  component boundaries.
* `reactiveStore()` — hierarchical reactive state container.

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
