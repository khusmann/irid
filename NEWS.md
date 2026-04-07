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
