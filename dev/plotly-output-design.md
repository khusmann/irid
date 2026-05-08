# PlotlyOutput — Design Document

**Status:** Proposed  
**Date:** April 2026

---

## 1. Motivation

Interactive plots are one of the most common use cases in Shiny apps, and plotly is the dominant library. The existing `{plotly}` R package wraps plotly.js as a Shiny output binding via `{htmlwidgets}` — but this means every reactive update destroys and recreates the entire widget. Users lose zoom, pan, and selection state on every data change.

irid can do better. `PlotlyOutput` should be a first-class output primitive — on par with `PlotOutput` and `TableOutput` — that uses `Plotly.react()` for incremental updates and binds user-controllable state as named reactive arguments, consistent with how every other irid component works.

---

## 2. Goals

- Same authoring pattern as every other irid component: pass a function, it's reactive
- Data updates preserve user zoom/pan/selection by default (via `uirevision`)
- User-controllable UI state is bound as named reactive arguments — consistent with auto-bind on raw tags
- Any field the user binds is serializable for bookmarking
- User-set state is distinguished from plotly auto-computed state (auto-fit)
- Works with both `plot_ly()` and `ggplotly()`
- No JS build step — vanilla JS, consistent with irid core
- Lives in irid core as a suggested dependency on `{plotly}`

---

## 3. Design Principles

### Named reactive args, unified callable

Every stateful field of a plotly chart — axis ranges, drag mode, selected points, trace visibility, 3D camera, mapbox viewport — is exposed as a **named reactive argument** to `PlotlyOutput`. Each named arg accepts any irid callable: a `reactiveVal`, a store leaf, a `reactiveProxy`, or a plain zero-arg reader.

```r
PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp),
  xaxis_range     = xrange,
  yaxis_range     = yrange,
  selected_points = selected,
  dragmode        = drag
)
```

`PlotlyOutput` maintains an internal **translation table** — a mapping from named arg → (plotly spec path, source event). On render, non-`NULL` values are merged into the spec at their path. On the corresponding event, the dot-notation event payload is parsed and fanned out to the matching callables. No stores-per-event, no splicing, no sync helpers.

This matches irid's core idiom: everything is a callable, and binding is per-field. The same mental model as `tags$input(value = x)`.

### No universal "plotly state"

Plotly does not have a single notion of UI state. A 2D scatter has axes and selection; a 3D plot adds a camera; a mapbox plot has a viewport; a geo plot has projection rotation; a sunburst has drill-down state; a ternary plot has a distinct axis system. **"What counts as UI state" is determined by which plotly features the specific plot uses.**

Consequently, there is no one-size-fits-all state constructor. The user picks the named args corresponding to the features their plot actually uses, and bookmark fidelity is scoped to those bindings. `PlotlyOutput`'s translation table is the list of features it knows how to bind; anything not in the table can be handled via the `onRelayout` escape hatch.

### Discrete callbacks for non-state events

Events that aren't persistent state — `plotly_click`, `plotly_hover`, `plotly_doubleclick`, etc. — are plain callbacks, following the same `on*` naming convention as the rest of irid:

```r
PlotlyOutput(
  \() plot_ly(...),
  selected_points = selected,
  onClick         = \(event) inspect(event$points[[1]]),
  onHover         = \(event) tooltip(event$points[[1]])
)
```

State fields and action callbacks live side-by-side as sibling arguments, cleanly separated by purpose.

### `reactiveProxy` for constrained writes

Any named arg can be wrapped in a `reactiveProxy` to validate, transform, or reject writes before they hit the underlying callable. This is the same mechanism used everywhere in irid — no PlotlyOutput-specific API:

```r
xrange <- reactiveVal(NULL)

gated <- reactiveProxy(xrange,
  set = \(v) if (is.null(v) || v[2] - v[1] > 1) xrange(v)
)

PlotlyOutput(\() plot_ly(...), xaxis_range = gated)
```

Snap-back semantics (rejected writes cause the plot to revert) require specific JS-side handling because of `uirevision` — see Section 6.

### `onRelayout` as universal escape hatch

For fields the translation table doesn't cover — exotic plot types, dynamic dot-notation keys, experimental plotly features — `onRelayout` receives the raw relayout event payload. The user handles the dot-notation parsing manually. Fields can be promoted from the escape hatch into the named-args table as they prove common.

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
          plot_ly(
            faithful[seq_len(n()), ],
            x = ~eruptions, y = ~waiting,
            type = "scatter", mode = "markers"
          )
        })
      )
    )
  )
}

iridApp(FilteredScatter)
```

Drag the slider — data updates, zoom stays. `PlotlyOutput` serializes the plotly object to JSON, injects a stable `uirevision`, and sends it to the client where `Plotly.react()` diffs and updates in place.

### Works with ggplotly

```r
PlotlyOutput(\() {
  p <- ggplot(faithful[seq_len(n()), ], aes(eruptions, waiting)) +
    geom_point()
  ggplotly(p)
})
```

`ggplotly()` returns the same plotly JSON spec. No special handling needed.

### Binding state with named args

```r
xrange   <- reactiveVal(NULL)
yrange   <- reactiveVal(NULL)
selected <- reactiveVal(NULL)

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  xaxis_range     = xrange,
  yaxis_range     = yrange,
  selected_points = selected
)

tags$p(\() {
  pts <- selected()
  if (is.null(pts)) "No selection" else paste(length(pts), "points")
})
```

Only bind the fields you care about. Unbound fields are left to the spec — whatever the plot function produced is what plotly uses, with no interception.

### Bundling fields into your own store for bookmarking

If you want a single bookmarkable unit, bundle the fields in your own `reactiveStore` and pass leaves to `PlotlyOutput`:

```r
state <- reactiveStore(list(
  xaxis_range     = NULL,
  yaxis_range     = NULL,
  selected_points = NULL,
  dragmode        = NULL
))

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp),
  xaxis_range     = state$xaxis_range,
  yaxis_range     = state$yaxis_range,
  selected_points = state$selected_points,
  dragmode        = state$dragmode
)

# Serialize for bookmark
saveRDS(state(), "bookmark.rds")

# Rehydrate
state <- reactiveStore(readRDS("bookmark.rds"))
```

The store shape is the user's choice — they include exactly the fields they care about. There is no canonical "plotly state store" because there is no canonical plotly state (Section 3).

### Subplot axes

Subplot axes follow plotly's `xaxis2`, `xaxis3`, `yaxis2`, ... naming. The translation table recognizes the pattern `xaxis<n>_range` / `yaxis<n>_range` and maps each to `layout.xaxis<n>.range`.

**Fixed small N (common case):**

```r
PlotlyOutput(
  \() subplot(p1, p2, p3),
  xaxis_range  = xr1,
  xaxis2_range = xr2,
  xaxis3_range = xr3,
  yaxis_range  = yr1,
  yaxis2_range = yr2,
  yaxis3_range = yr3
)
```

**Programmatic N known at mount time:**

```r
axes <- setNames(
  lapply(seq_len(n), \(i) reactiveVal(NULL)),
  paste0("xaxis", ifelse(seq_len(n) == 1, "", seq_len(n)), "_range")
)
PlotlyOutput(\() ..., !!!axes)
```

Same model, programmatic construction via splicing. No new API.

**Truly dynamic N (changes at runtime):** the component remounts when N changes, like any other dynamic UI. See open questions.

### Discrete event callbacks

For events that carry no persistent state — clicks, hovers, legend interactions — pass plain callbacks:

```r
PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp),
  onClick             = \(event) inspect(event$points[[1]]),
  onHover             = \(event) tooltip(event$points[[1]]),
  onUnhover           = \(event) tooltip(NULL),
  onDoubleclick       = \(event) reset_view(),
  onLegendClick       = \(event) log(event$curveNumber),
  onLegendDoubleclick = \(event) isolate_trace(event$curveNumber),
  onClickAnnotation   = \(event) handle(event),
  onSunburstClick     = \(event) drill_down(event),
  onDeselect          = \(event) selected(NULL),
  onSelecting         = \(event) preview(event$points),
  onBrushing          = \(event) preview(event$points)
)
```

Pass only the callbacks you need. Listeners are only attached on the client for events with a corresponding callback.

### Constrained writes with `reactiveProxy`

Wrap any named arg in a proxy to intercept writes:

```r
xrange <- reactiveVal(NULL)

# Reject zooms narrower than 1 unit
gated <- reactiveProxy(xrange,
  set = \(v) if (is.null(v) || v[2] - v[1] > 1) xrange(v)
)

PlotlyOutput(\() plot_ly(...), xaxis_range = gated)
```

When a zoom is rejected, the plot **snaps back** to the last accepted range — analogous to how an `<input>` with a rejecting proxy reverts the displayed text. This requires specific client-side handling because of `uirevision`; see Section 6.

To suppress write-back entirely (the plot displays the range but user interaction doesn't update it):

```r
PlotlyOutput(
  \() plot_ly(...),
  xaxis_range = reactiveProxy(xrange, set = NULL)
)
```

### `onRelayout` escape hatch

For relayout fields not in the translation table:

```r
PlotlyOutput(
  \() plot_ly(...),
  xaxis_range = xrange,             # named arg — in the table
  onRelayout  = \(event) {          # raw callback — everything else
    # event is the raw plotly_relayout payload, e.g.:
    # list(`scene.camera.eye.x` = 1.2, `scene.camera.eye.y` = 0.8, ...)
    handle_camera(event)
  }
)
```

Named args and `onRelayout` compose: named args handle the fields in the table, `onRelayout` receives the full raw payload. Fields that snap-back or participate in bookmarking should use named args; truly ad-hoc handling uses the raw callback.

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

To reset individual fields without resetting everything:

```r
xrange(NULL)   # defer to whatever the spec function specifies
yrange(NULL)
```

`NULL` in any named arg means **"don't override the spec."** `PlotlyOutput` leaves the field untouched during the merge, so whatever the plot's spec function produced at that path takes effect. That might be an explicit range set via `layout(xaxis = list(range = c(0, 10)))`, or it might be plotly's auto-fit if the spec left the field unset. Either way, `NULL` reverts to the spec's own value — it is not equivalent to forcing auto-fit.

### Rehydrating from a bookmark

```r
bookmark <- readRDS("bookmark.rds")

xrange   <- reactiveVal(bookmark$xaxis_range)
yrange   <- reactiveVal(bookmark$yaxis_range)
selected <- reactiveVal(bookmark$selected_points)

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp),
  xaxis_range     = xrange,
  yaxis_range     = yrange,
  selected_points = selected
)
```

On first render, non-`NULL` named args are merged into the plotly spec before sending to the client. After the user zooms, `xrange` receives the new range, the spec re-evaluates, `Plotly.react()` receives the same range and no-ops.

---

## 5. User State vs Spec-Computed State

### The problem

On first render, Plotly produces a concrete layout from the spec — either explicit ranges the user set in the plot call, or auto-fit ranges computed from the data when the spec left axes unspecified. Either way, `plotly_relayout` fires with the resulting values shortly after `Plotly.react()` settles. If we naively capture these, we write spec-computed ranges back into the bound callable. Now those ranges are "locked in" — the next data change preserves them instead of letting the spec re-compute.

This matters most for auto-fit cases (where the computed range depends on data that may change), but the same issue applies to any spec-driven state that should follow the spec rather than override it.

### The solution

The client-side handler distinguishes user-initiated layout changes from spec-computed ones:

1. **On mount**, record that no user interaction has occurred.
2. **On `plotly_relayout`**, check whether the event was triggered by user interaction (zoom/pan/drag) or by `Plotly.react()` settling the spec.
3. Only write state back for user-initiated changes.

`plotly_relayout` fires for both cases, but the timing and payload differ. Spec-computed updates fire synchronously after a `Plotly.react()` call; user zooms fire in response to mouse events. The client tracks whether a `Plotly.react()` call is in flight and suppresses relayout events that fire synchronously after it.

If this heuristic proves unreliable, a fallback approach: only capture state after user interaction events (`plotly_selecting`, `plotly_relayouting`) and ignore `plotly_relayout` entirely as a state source.

### NULL means "defer to the spec"

`NULL` in any named arg means **"don't override the spec"** — both as the initial default and as a programmatic reset:

```r
xrange(NULL)   # defer to the spec
```

When merging state into the spec, `NULL`-valued named args are simply omitted. Whatever the plot's spec function produced at that path — an explicit range, an `autorange: true`, or no setting at all — is what takes effect. `NULL` is *not* a command to force auto-fit; it's a signal that `PlotlyOutput` should not touch that field during the merge.

---

## 6. Implementation

### R side

`PlotlyOutput` is a function that returns a tag-like structure recognized by `process_tags`. It accepts:

- A function returning a plotly object (the spec)
- Named reactive args corresponding to entries in the translation table (Section 8)
- Optional discrete event callbacks (`onClick`, `onHover`, ...)
- Optional `onRelayout` escape hatch for unrecognized fields

`process_tags` handles `PlotlyOutput` nodes by:

1. Creating a placeholder `<div>` with a unique ID
2. Extracting the spec function as a binding
3. Classifying remaining arguments against the translation table: known named args become state bindings, unknown `on*` args become discrete callbacks, `onRelayout` is the escape hatch
4. Unknown arguments that don't match anything error at construction time with a helpful message

The mount phase creates:

1. An `observe()` that serializes the plotly object to JSON, merges non-`NULL` named args into the spec at their table-defined paths, and sends an `irid-plotly-render` message
2. An `observeEvent()` on each event-source namespaced input that parses the payload and fans writes out to the matching named-arg callables
3. An `observeEvent()` for each discrete callback that invokes it with the raw payload

### JS side

**`irid-plotly-render`**

```js
{id: "irid-7", spec: {data: [...], layout: {...}}, bound: ["xaxis_range", "yaxis_range", "selected_points"]}
```

- If no root exists for `id`, create via `Plotly.react()` and attach event listeners
- Inject stable `uirevision` if not already present
- Call `Plotly.react(el, spec.data, spec.layout)`
- Suppress `plotly_relayout` events until the render settles (auto-fit filtering)
- Track `bound` fields — the list of named args the R side is binding — so the client knows which fields are authoritative from the server

**Snap-back via targeted corrections**

The default `Plotly.react()` + `uirevision` flow *preserves* user-interactive state across renders. This is exactly what we want for data updates, but it **blocks** the snap-back semantics needed for rejecting proxies. If the user zooms, the server rejects the write, and the server re-renders with the old range, `uirevision` preservation will keep plotly showing the user's zoom — the rejection is silently ignored.

To restore snap-back, the JS side tracks the last event payload it sent for each bound field. When a new spec arrives, it compares the server's value for each bound field against what the client last sent:

- **Match** → normal render, `Plotly.react()` reconciles, `uirevision` preserves everything else
- **Mismatch** → targeted `Plotly.relayout(el, {path: value})` call for the field after the `react()`, forcing the correction

This handles both the rejection case ("server didn't accept it") and the transform case ("server accepted a modified version"). Targeted `Plotly.relayout()` bypasses `uirevision` preservation because it's a direct state update, not a reconciliation.

Snap-back only works for fields in the translation table. The `onRelayout` escape hatch has no binding to snap back to.

**Event listeners**

After mount, attach listeners for:

- `plotly_relayout` → parse dot-notation payload, fan out to matching named args, also forward to `onRelayout` callback if provided (filtered for user-initiated only)
- `plotly_selected` / `plotly_deselect` → write to `selected_points` named arg if bound
- `plotly_brushed` → write to the selection field (see open questions for brush/select resolution)
- `plotly_restyle` → write to `trace_visibility` and other restyle-sourced named args
- `plotly_click`, `plotly_hover`, `plotly_unhover`, `plotly_doubleclick`, `plotly_selecting`, `plotly_brushing`, `plotly_legendclick`, `plotly_legenddoubleclick`, `plotly_clickannotation`, `plotly_sunburstclick` → forward to corresponding discrete callbacks only if bound

Each listener sends its payload via `Shiny.setInputValue(inputId, value, {priority: "event"})`. Discrete event listeners are only attached if the corresponding callback argument was supplied.

**Cleanup**

When the containing control-flow node tears down, `Plotly.purge(el)` is called to free plotly resources.

### Dependencies

- `{plotly}` is a suggested dependency of irid (not imported)
- `PlotlyOutput()` checks for `{plotly}` availability and errors with a helpful message if missing
- Plotly.js is loaded via `{plotly}`'s existing `htmlDependency` — no separate CDN or bundling

---

## 7. Relationship to irid.react

React component wrapping is a separate concern with a different API shape. React components are defined by their props — the tag pattern is natural, and auto-bind applies the same way it does on raw tags:

```r
# Registration — turns a React component into an irid tag constructor,
# declaring which props are state-binding (auto-bind) and which are events
DataGrid <- react_component("DataGrid",
  state  = c("selected", "sort", "filter"),
  events = c("onRowClick")
)

selected <- reactiveVal(NULL)
sort     <- reactiveVal(list(col = "name", dir = "asc"))

DataGrid(
  data       = \() filtered_df(),
  columns    = col_config(),
  selected   = selected,                           # auto-bind — read + write
  sort       = sort,                               # auto-bind — read + write
  onRowClick = \(event) inspect(event$row)         # discrete event callback
)
```

State props accept any irid callable — `reactiveVal`, store leaf, or `reactiveProxy` — and the component reads them for rendering and writes back when the corresponding React event fires. This is the same model as `tags$input(value = x)`, extended across a component boundary. `reactiveProxy` works the same way, including snap-back for rejected writes.

**Why two components share the same mental model but have different implementations:**

- `PlotlyOutput` uses the *output* pattern (function returning a plotly object) because plotly has a rich R-side DSL (`plot_ly()`, `ggplotly()`, pipe chains). Its translation table maps named args to paths inside the generated spec.
- `irid.react` components use the *tag* pattern because props *are* the interface — there's no intermediate object to compute paths into.

Both expose named reactive args with auto-bind. The rule: if the library has a rich R API that produces a single object, use the output pattern. If the interface is already named-arguments-in / events-out, use the tag pattern.

`irid.react` is a separate package because it brings a runtime dependency (React/ReactDOM) and a JS build step — both contrary to irid's zero-build core.

---

## 8. Feature Translation Table

The translation table is the list of plotly features `PlotlyOutput` knows how to bind as named args. Each entry specifies:

- **Name** — the named arg as seen by the user
- **Spec path** — where the value is merged into the plotly spec
- **Source event** — the plotly.js event that writes back to it

Launch-scope table (everything else lives in the `onRelayout` escape hatch):

| Named arg              | Spec path                  | Source event                          |
|------------------------|----------------------------|---------------------------------------|
| `xaxis_range`          | `layout.xaxis.range`       | `plotly_relayout`                     |
| `yaxis_range`          | `layout.yaxis.range`       | `plotly_relayout`                     |
| `xaxis<n>_range`       | `layout.xaxis<n>.range`    | `plotly_relayout` (pattern-matched)   |
| `yaxis<n>_range`       | `layout.yaxis<n>.range`    | `plotly_relayout` (pattern-matched)   |
| `dragmode`             | `layout.dragmode`          | `plotly_relayout`                     |
| `hovermode`            | `layout.hovermode`         | `plotly_relayout`                     |
| `selected_points`      | `data[*].selectedpoints`   | `plotly_selected` / `plotly_brushed` / `plotly_deselect` |
| `trace_visibility`     | `data[*].visible`          | `plotly_restyle`                      |

Fields to add post-launch as usage patterns become clear:

- `scene_camera` — 3D camera position (`layout.scene.camera`, `plotly_relayout`)
- `mapbox_center`, `mapbox_zoom`, `mapbox_bearing`, `mapbox_pitch` — mapbox viewport
- `geo_projection_rotation` — geo projection rotation
- Range slider extent
- Slider/animation position

The table grows additively. Adding a new entry doesn't break any existing code — unknown-in-old-version / known-in-new-version named args were previously handled via `onRelayout` escape hatch, and users can opt into the named-arg version when convenient.

---

## 9. Scope

### What this covers

- `PlotlyOutput` as a core irid primitive
- Incremental rendering via `Plotly.react()`
- Named reactive args for stateful fields, backed by the translation table
- Discrete event callbacks (`onClick`, `onHover`, `onUnhover`, `onDoubleclick`, `onDeselect`, `onSelecting`, `onBrushing`, `onLegendClick`, `onLegendDoubleclick`, `onClickAnnotation`, `onSunburstClick`)
- `onRelayout` escape hatch for fields outside the table
- `reactiveProxy` for constrained writes, including snap-back via targeted `Plotly.relayout()`
- Bookmark serialization via user-constructed `reactiveStore`s
- Auto-fit vs user-state distinction
- `uirevision`-aware client-side state handling

### What this does not cover

- A canonical "plotly state store" constructor — plotly has no canonical state shape, so there is nothing for such a constructor to contain (Section 3)
- Surgical `Plotly.restyle()` / `Plotly.relayout()` as the primary render path — `Plotly.react()` diffs internally and is fast enough; targeted `relayout` is used only for snap-back corrections
- A separate `irid.plotly` package — not justified unless `Plotly.react()` proves insufficient for large datasets
- React component wrapping — separate design (`irid.react`, Section 7)
- Generic `htmlwidgets` bridge — most htmlwidgets don't support incremental updates

---

## 10. Open Questions

### Detecting user-initiated relayout

The heuristic for distinguishing user zoom from auto-fit (Section 5) needs validation against real Plotly behavior. If unreliable, the fallback of only capturing state after explicit interaction events may be necessary.

### `plotly_brushed` vs `plotly_selected` internal state

`plotly_brushed` and `plotly_selected` are separate events in plotly.js, but it's unclear whether they write to the same internal `selectedpoints` attribute or maintain genuinely distinct state. The named-args model supports either resolution additively:

- **Shared state** → a single `selected_points` named arg that both events write to. Users who care about the interaction type use `onSelected` / `onBrushed` discrete callbacks alongside.
- **Distinct state** → a separate `brushed_points` (or similarly named) arg in the translation table.

Launch plan: ship with one `selected_points` arg fed from both events, since that's the likelier shared-state scenario. If plotly.js behavior shows they're distinct, add a second named arg — additive change, no breaking.

### Snap-back reliability with `uirevision`

The targeted `Plotly.relayout()` correction approach (Section 6) assumes the client can reliably diff the server's authoritative value against what it last sent, and that targeted `relayout` calls bypass `uirevision` preservation. Both assumptions need prototype validation. Edge cases:

- Rapid user interactions while a correction is in flight
- Corrections on arrays vs scalars (e.g. `xaxis.range` vs `dragmode`)
- Correction interactions with plotly's own animation/transition layer

### Integration with irid's stale UI indicator

`Plotly.react()` runs client-side and is fast. But the R-side serialization and message round-trip still takes time. Should the stale indicator fire during plotly updates, or is the perceived latency low enough to skip it?

### Dynamic subplot axes

A plot may have a variable number of subplot axes depending on the data. The named-args model handles fixed and programmatic N via splicing, but a user whose axis count changes at runtime must remount the component (same as any other dynamic UI). Whether a cleaner "all axes at once" binding is needed depends on how often this comes up.

### Growing the table

New fields are added to the translation table as usage patterns clarify which plotly features are common enough to warrant first-class support. The `onRelayout` escape hatch covers everything else in the meantime. Criteria for promotion: (1) multiple users bind the field via the escape hatch, (2) the field has a stable payload shape across plot types, (3) snap-back semantics are well-defined for it.
