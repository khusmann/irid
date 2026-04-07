# PlotlyOutput — Design Document

**Status:** Proposed  
**Date:** April 2026

---

## 1. Motivation

Interactive plots are one of the most common use cases in Shiny apps, and plotly is the dominant library. The existing `{plotly}` R package wraps plotly.js as a Shiny output binding via `{htmlwidgets}` — but this means every reactive update destroys and recreates the entire widget. Users lose zoom, pan, and selection state on every data change.

irid can do better. `PlotlyOutput` should be a first-class output primitive — on par with `PlotOutput` and `TableOutput` — that uses `Plotly.react()` for incremental updates and provides one-way-in state attributes with explicit event callbacks to close the loop.

---

## 2. Goals

- Same authoring pattern as every other irid component: pass a function, it's reactive
- Data updates preserve user zoom/pan/selection by default (via `uirevision`)
- UI state is observable via explicit event callbacks (consistent with `onInput` on `tags$input`)
- UI state is serializable for bookmarking via stores
- User-set state is distinguished from plotly auto-computed state (auto-fit)
- Works with both `plot_ly()` and `ggplotly()`
- No JS build step — vanilla JS, consistent with irid core
- Lives in irid core as a suggested dependency on `{plotly}`

---

## 3. Design Principles

### One-way data flow

irid follows Solid's philosophy: data flows one way. Attributes are one-way in (R → client), callbacks are one-way out (client → R). The user explicitly wires them together. This applies uniformly to raw HTML tags and managed output components:

```r
# Raw tag — user wires value ↔ onInput
tags$input(value = myVal, onInput = \(event) myVal(event$value))

# PlotlyOutput — user wires state ↔ callbacks
PlotlyOutput(
  \() plot_ly(...),
  xaxis_range = xrange,
  onRelayout = \(event) xrange(event$xaxis_range)
)
```

No implicit bidirectional binding. The user always closes the loop.

### Stores splice attributes, not callbacks

Stores (`create_store`) are bags of reactive values. Splicing a store with `!!!` injects reactive attributes — never callbacks. Callbacks are wired separately, either explicitly or via a sync helper.

---

## 4. API

### Basic usage

```r
library(irid)
library(bslib)
library(plotly)

FilteredScatter <- function() {
  n <- reactiveVal(100L)

  page_fluid(
    card(
      card_body(
        tags$label(\() paste("Points:", n())),
        tags$input(
          type = "range", min = "10", max = "500",
          value = n,
          onInput = \(event) n(as.integer(event$value))
        ),
        PlotlyOutput(\() {
          plot_ly(faithful[seq_len(n()), ],
                  x = ~eruptions, y = ~waiting,
                  type = "scatter", mode = "markers")
        })
      )
    )
  )
}

iridApp(FilteredScatter)
```

Drag the slider — data updates, zoom stays. Under the hood, `PlotlyOutput` serializes the plotly object to JSON, injects a stable `uirevision`, and sends it to the client where `Plotly.react()` diffs and updates in place.

### Works with ggplotly

```r
PlotlyOutput(\() {
  p <- ggplot(faithful[seq_len(n()), ], aes(eruptions, waiting)) +
    geom_point()
  ggplotly(p)
})
```

`ggplotly()` returns the same plotly JSON spec. No special handling needed.

### Observing UI state with individual reactives

Pass reactive attributes one-way in, wire callbacks to close the loop:

```r
xrange <- reactiveVal(NULL)
selected <- reactiveVal(NULL)

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  xaxis_range = xrange,
  onRelayout = \(event) xrange(event$xaxis_range),
  onSelected = \(event) selected(event$points)
)

tags$p(\() {
  sel <- selected()
  if (is.null(sel)) "No selection" else paste(length(sel), "points")
})
```

Only bind what you care about. Don't need zoom state? Don't pass it.

### Bundling with a store and sync helper

For full bookmark fidelity, use a typed store constructor and a sync helper:

```r
ps <- plotly_state()

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp),
  !!!ps,
  !!!plotly_sync(ps)
)
```

`!!!ps` splices the state attributes (`xaxis_range`, `yaxis_range`, `selected`, ...) as one-way-in reactive bindings. `!!!plotly_sync(ps)` splices the matching callbacks (`onRelayout`, `onSelected`, ...) that wire events back into the store. They are independent and can be used separately:

```r
# State in, no sync (set from R, ignore user interaction)
PlotlyOutput(\() ..., !!!ps)

# Full sync (state in + callbacks that write back)
PlotlyOutput(\() ..., !!!ps, !!!plotly_sync(ps))

# Just callbacks, no state store
PlotlyOutput(\() ..., onRelayout = \(event) log(event))
```

`plotly_sync(ps)` is a convenience — it returns a named list of callback functions that write each event's fields into the corresponding store nodes. It is equivalent to writing the callbacks by hand:

```r
# plotly_sync(ps) produces something like:
list(
  onRelayout = \(event) {
    ps$xaxis_range(event$xaxis_range)
    ps$yaxis_range(event$yaxis_range)
    ps$dragmode(event$dragmode)
    # ... etc
  },
  onSelected = \(event) ps$selected(event$points),
  onRestyle = \(event) ps$visible(event$visible)
)
```

### Overriding individual callbacks

`plotly_sync` accepts override callbacks that **replace** the default sync for that event. No composition — your callback runs instead of the generated one:

```r
PlotlyOutput(
  \() plot_ly(...),
  !!!ps,
  !!!plotly_sync(ps,
    onRelayout = \(event) {
      # Only sync x-axis zoom if range is wide enough
      if (event$xaxis_range[2] - event$xaxis_range[1] > 1) {
        ps$xaxis_range(event$xaxis_range)
      }
      # intentionally not syncing yaxis_range
    }
  )
)
```

Pass `NULL` to suppress a callback entirely:

```r
!!!plotly_sync(ps, onRelayout = NULL)  # don't sync layout changes
```

If you want the default sync behavior plus custom logic, write the sync yourself in your override — the default is just store writes, so reproducing it is a one-liner per field.

### plotly_state constructor

```r
plotly_state <- function(
  xaxis_range = NULL,
  yaxis_range = NULL,
  selected = NULL,
  visible = NULL,
  dragmode = NULL,
  # ... all user-controllable state fields
) {
  create_store(list(
    xaxis_range = xaxis_range,
    yaxis_range = yaxis_range,
    selected = selected,
    visible = visible,
    dragmode = dragmode
  ))
}
```

The goal is complete bookmark fidelity — every piece of user-controllable UI state should be capturable. See Section 8 for the full inventory.

### Resetting zoom

Changing `uirevision` resets all plotly UI state. `PlotlyOutput` injects a stable `uirevision` by default. To reset programmatically:

```r
revision <- reactiveVal(1L)

PlotlyOutput(\() {
  plot_ly(df(), x = ~mpg, y = ~hp) |>
    layout(uirevision = revision())
})

tags$button("Reset zoom", onClick = \() revision(revision() + 1L))
```

If the user provides `uirevision` in their layout, `PlotlyOutput` respects it and does not override.

To reset individual state fields without resetting everything:

```r
ps$xaxis_range(NULL)  # this axis back to auto-fit
ps$yaxis_range(NULL)
```

### Rehydrating UI state from a bookmark

```r
ps <- plotly_state(!!!readRDS("bookmark.rds"))

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp),
  !!!ps,
  !!!plotly_sync(ps)
)
```

On first render, non-`NULL` state attributes are merged into the plotly spec before sending to the client. The round-trip is safe: after the user zooms, `onRelayout` writes the range into the store, the spec re-evaluates, `Plotly.react()` receives the same range and no-ops.

---

## 5. User State vs Auto-Fit

### The problem

On first render with no saved state, Plotly auto-fits axes. If callbacks naively capture the resulting layout via `plotly_relayout`, they write auto-computed ranges into state reactives. Now those ranges are "locked in" — the next data change preserves them instead of re-fitting.

### The solution

The client-side handler distinguishes user-initiated layout changes from Plotly's auto-fit:

1. **On mount**, record that no user interaction has occurred.
2. **On `plotly_relayout`**, check whether the event was triggered by user interaction (zoom/pan/drag) or by `Plotly.react()` auto-fitting.
3. Only send state back to R for user-initiated changes.

Plotly's `plotly_relayout` fires for both cases, but the event payloads differ. Auto-fit produces `autorange: true` or axis range updates immediately after a `Plotly.react()` call. User zoom produces range updates in response to mouse events. The client tracks whether a `Plotly.react()` call is in flight and suppresses relayout events that fire synchronously after it.

If this heuristic proves unreliable, a fallback approach: only capture state after user interaction events (`plotly_selecting`, `plotly_relayouting`) and ignore `plotly_relayout` entirely as a state source.

### NULL means auto-fit

A `NULL` value in any state attribute means "let Plotly decide." This is both the initial default and the way to programmatically reset:

```r
ps$xaxis_range(NULL)  # back to auto-fit
```

When merging state into the spec, `NULL` attributes are simply omitted — Plotly auto-fits any axis that has no explicit range.

---

## 6. Implementation

### R side

`PlotlyOutput` is a function that returns a tag-like structure recognized by `process_tags`. It accepts:

- A function returning a plotly object (the spec)
- Optional reactive attributes for UI state (via `...`)
- Optional event callbacks (via `...`)

`process_tags` handles `PlotlyOutput` nodes by:

1. Creating a placeholder `<div>` with a unique ID
2. Extracting the spec function as a binding (like other outputs)
3. Extracting reactive state attributes as one-way-in bindings
4. Extracting event callbacks (`on*` arguments)

The mount phase creates:

1. An `observe()` that serializes the plotly object to JSON and sends an `irid-plotly-render` message, merging any non-`NULL` state attributes into the spec
2. For each state attribute, an `observe()` that sends updates to the client when R changes the value
3. For each callback, an `observeEvent()` on the corresponding namespaced input

### JS side (~100 lines)

New message handlers:

**`irid-plotly-render`**

```js
{id: "irid-7", spec: {data: [...], layout: {...}}}
```

- If no root exists for `id`, create via `Plotly.react()` and attach event listeners
- Inject stable `uirevision` if not already present
- Call `Plotly.react(el, spec.data, spec.layout)`
- Suppress `plotly_relayout` events until the render settles (auto-fit filtering)

**Event listeners**

After mount, attach listeners for:

- `plotly_relayout` → send axis ranges, dragmode (filtered for user-initiated only)
- `plotly_selected` / `plotly_deselect` → send selected points
- `plotly_restyle` → send trace visibility

Each listener sends its payload via `Shiny.setInputValue(inputId, value, {priority: "event"})`.

**Cleanup**

When the containing control-flow node tears down, `Plotly.purge(el)` is called to free plotly resources.

### Dependencies

- `{plotly}` is a suggested dependency of irid (not imported)
- `PlotlyOutput()` checks for `{plotly}` availability and errors with a helpful message if missing
- Plotly.js is loaded via `{plotly}`'s existing `htmlDependency` — no separate CDN or bundling

---

## 7. Relationship to irid.react

React component wrapping is a separate concern with a different API shape. React components are defined by their props — the tag pattern is natural:

```r
# Registration — turns a React component into an irid tag constructor
DataGrid <- react_component("DataGrid")

# Usage — same authoring model as tags$input
DataGrid(
  data = \() filtered_df(),
  columns = col_config(),
  onSelect = \(event) selected(event$row)
)
```

`PlotlyOutput` uses the output pattern (function returning a plotly object) because plotly has a rich R-side DSL (`plot_ly()`, `ggplotly()`, pipe chains). React components use the tag pattern because props are the interface. The rule: if the library has a rich R API that produces a single object, use the output pattern. If the interface is named arguments in / callbacks out, use the tag pattern.

`irid.react` is a separate package because it brings a runtime dependency (React/ReactDOM) and a JS build step — both contrary to irid's zero-build core.

---

## 8. State Attribute Inventory

`plotly_state()` should expose every piece of user-controllable UI state. The goal is complete bookmark fidelity — serialize the state, restore it, see exactly the same view.

Full inventory:

- Axis ranges (all axes, including subplots: `xaxis_range`, `yaxis_range`, `xaxis2_range`, ...)
- Per-trace visibility (legend toggle state)
- Selected points
- Drag mode (zoom, pan, select, lasso)
- Active hover mode
- 3D camera position (for `scatter3d`, `surface`)
- Mapbox/geo viewport (center, zoom, bearing, pitch)
- Slider/animation position
- Range slider extent

All fields default to `NULL` (auto / Plotly default). The `plotly_state()` constructor accepts all of them. The JS side captures all of them from the relevant Plotly events.

Subplot axis naming uses Plotly's own convention (`xaxis`, `xaxis2`, `xaxis3`, ...). The store holds them as a flat namespace.

---

## 9. Scope

### What this covers

- `PlotlyOutput` as a core irid primitive
- Incremental rendering via `Plotly.react()`
- One-way-in state attributes with explicit event callbacks
- `plotly_state()` store constructor for bundled state
- `plotly_sync()` helper for wiring callbacks to a store
- Bookmark serialization and rehydration
- Auto-fit vs user-state distinction

### What this does not cover

- Surgical `Plotly.restyle()` / `Plotly.relayout()` — not needed; `Plotly.react()` diffs internally
- A separate `irid.plotly` package — not justified unless `Plotly.react()` proves insufficient for large datasets
- React component wrapping — separate design (`irid.react`, Section 7)
- Generic `htmlwidgets` bridge — separate concern; most htmlwidgets don't support incremental updates

---

## 10. Open Questions

### Detecting user-initiated relayout

The heuristic for distinguishing user zoom from auto-fit (Section 5) needs validation against real Plotly behavior. If unreliable, the fallback of only capturing state after explicit interaction events may be necessary.

### Integration with irid's stale UI indicator

`Plotly.react()` runs client-side and is fast. But the R-side serialization and message round-trip still takes time. Should the stale indicator fire during plotly updates, or is the perceived latency low enough to skip it?

### Dynamic subplot axes

A plot may have a variable number of subplot axes depending on the data. The `plotly_state()` store has a fixed shape at construction time. If the number of axes changes across renders, the store cannot grow to accommodate new axes. This may require a convention — e.g. pre-declaring the maximum expected axes, or treating all axis state as a single atomic list field.
