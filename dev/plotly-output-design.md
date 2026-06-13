# PlotlyOutput — Design Document

**Status:** Proposed  
**Date:** April 2026 (revised June 2026 against the two-way-prop widget substrate)

---

## 1. Motivation

Interactive plots are one of the most common use cases in Shiny apps, and plotly is the dominant library. The existing `{plotly}` R package wraps plotly.js as a Shiny output binding via `{htmlwidgets}` — but this means every reactive update destroys and recreates the entire widget. Users lose zoom, pan, and selection state on every data change.

irid can do better. `PlotlyOutput` should be a first-class output primitive — on par with `PlotOutput` and `TableOutput` — that uses `Plotly.react()` for incremental updates and binds user-controllable state as named reactive arguments, consistent with how every other irid component works.

It is implemented as a thin wrapper on top of `IridWidget` (see [ARCHITECTURE.md](../ARCHITECTURE.md#widgets) — the framework's generic JS-library wrapper mechanism. The widget substrate carries the transport (init message, per-key reactive props, event timing, deps hoisting, lifecycle), and `PlotlyOutput` adds only the plotly-specific logic: serializing the spec, the translation table that maps named args to plotly paths and event sources, and the JS-side `Plotly.react` / `Plotly.relayout` / `Plotly.purge` glue.

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
- Implemented as a wrapper on top of `IridWidget` — no new wire-protocol messages, no PlotlyOutput-specific `process_tags` extraction, no custom mount path

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

gated <- reactiveProxy(
  get = xrange,
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
  pts <- selected()   # data.frame(curve, point), or NULL
  if (is.null(pts)) "No selection" else paste(nrow(pts), "points")
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
  onDeselect          = \(event) log("cleared"),   # side effect only — see note
  onSelecting         = \(event) preview(event$points),
  onBrushing          = \(event) preview(event$points)
)
```

Pass only the callbacks you need. Listeners are only attached on the client for events with a corresponding callback.

`onDeselect` is a *notification*, not the way you clear the selection: when `selected_points` is bound, `plotly_deselect` already sets it to `NULL` through its own prop channel. Use `onDeselect` only for an additional side effect (logging, resetting a sibling), never to mirror the clear by hand.

### Constrained writes with `reactiveProxy`

Wrap any named arg in a proxy to intercept writes:

```r
xrange <- reactiveVal(NULL)

# Reject zooms narrower than 1 unit
gated <- reactiveProxy(
  get = xrange,
  set = \(v) if (is.null(v) || v[2] - v[1] > 1) xrange(v)
)

PlotlyOutput(\() plot_ly(...), xaxis_range = gated)
```

When a zoom is rejected, the plot **snaps back** to the last accepted range — analogous to how an `<input>` with a rejecting proxy reverts the displayed text. This requires specific client-side handling because of `uirevision`; see Section 6.

To suppress write-back entirely (the plot displays the range but user interaction doesn't update it):

```r
PlotlyOutput(
  \() plot_ly(...),
  xaxis_range = reactiveProxy(get = xrange)
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

> **Empirically grounded.** The behavior in this section and the snap-back path
> in §6 were verified against **Plotly 2.35.2** *and* re-confirmed against
> **Plotly 2.25.2 — the version `{plotly}` 4.12.0 actually bundles** — with the
> throwaway harness in
> [`dev/spikes/plotly-uirevision-spike.html`](spikes/plotly-uirevision-spike.html)
> (questions Q1–Q4; the
> [`-2.25.html`](spikes/plotly-uirevision-spike-2.25.html) copy loads the bundled
> file). Q1–Q4 returned **identical verdicts on both versions**, so these
> internals are stable across the 2.25–2.35 range. They are nonetheless exactly
> the internals that drift between plotly major versions, so re-run the spike when
> bumping the pinned `{plotly}`.

### `Plotly.react()` is silent — there is no auto-fit echo to suppress

The original worry was that re-rendering would emit `plotly_relayout` with
spec-computed (auto-fit) ranges that we'd capture as if the user had set them,
locking them in. The spike shows that does **not** happen: `Plotly.react()`
fires *no* `plotly_relayout` at all — not on an auto-range recompute from new
data (Q1), not on an explicit range change, not on an `autorange: true` reset
(Q2). Every `plotly_relayout` observed came from a genuine user gesture (a
drag-zoom, which emits split `xaxis.range[0]` / `[1]` keys, or the zoom-tool
select, which emits a lone `dragmode`). So the spec/data path needs no
echo-suppression heuristic.

### The real echo source: our own programmatic mutations

What *does* re-fire `plotly_relayout` is **our own** `Plotly.relayout()` /
`Plotly.restyle()` — the targeted calls the `update` hook makes for snap-back,
apply, and reset (Q4). The echo fires **synchronously, inside the call, before
the returned promise resolves**, and carries the whole-array key
(`xaxis.range: [lo, hi]`), not the split form. Unguarded it would loop:
relayout → echo → `setProp` → write → …

The guard is a single `applying` flag the factory raises around every
programmatic graph mutation and clears in that call's `.then()`; the
`plotly_relayout` listener early-returns while it is set:

```js
function mutate(fn) { applying = true; return fn().then(function () { applying = false; }); }
// el.on("plotly_relayout", function (p) { if (applying) return; /* fan out */ });
```

Because the echo *precedes* the promise, clearing in `.then()` is always in time
— the spike confirmed the flag is still set at echo time under every clear-timing
tried (immediate, rAF, 50 ms). The `matchesCurrent` idempotence check (§6)
remains as a secondary backstop for cross-flush races, but the flag alone
suppresses the self-echo. (This replaces the earlier "tell a user zoom from a
react-settling echo by timing" heuristic — there is nothing to distinguish on
the react side, and the flag is an exact guard, not a timing guess.)

### NULL: "stay out of the merge" and "reset to the spec" are different acts

`NULL` in a named arg means **"PlotlyOutput is not controlling this field"** —
but the spike shows that *releasing* control and *resetting* the view diverge,
because `uirevision` makes them behave differently:

- **A binding that is already `NULL` across a data-change `react()`** — the merge
  omits the field; `uirevision` then *preserves whatever is on screen* (a user
  zoom stays; an untouched auto-range keeps tracking the data). `NULL` here is
  **not** a reset — it leaves the current view alone. (Q2b: react with no range
  preserved the hand-zoom.)
- **A binding *transitioning* to `NULL`** (`xrange(NULL)` as a deliberate reset)
  — the `update` hook's `applyDeferred` issues a **targeted**
  `Plotly.relayout(el, {"xaxis.autorange": true})` (or the spec's explicit range
  if it has one), which bypasses `uirevision` and genuinely reverts to the spec's
  view. (Q2e: explicit `autorange: true` reset works; Q2d: a merge alone cannot.)

So `xrange(NULL)` *does* reset — via the targeted path — while a binding that is
simply already `NULL` during a data update stays out of the way. Both readings of
"defer to the spec" hold; they just run through different code paths.

---

## 6. Implementation

`PlotlyOutput` carries no custom `process_tags` extraction, no custom wire-message, and no custom client mount path. All of that comes from the `IridWidget` substrate. The wrapper's job is to:

- map the user's spec function and named state args into the two-way `props` shape that `IridWidget` understands — each state arg is a two-way prop, so its write-back and snap-back come from the substrate, not the wrapper
- pass the discrete callbacks (and the `onRelayout` escape hatch) as `events`
- ship plotly's `htmlDependency` via `IridWidget(deps = ...)`
- apply sensible per-binding timing by wrapping the high-frequency state props (relayout/hover-sourced) in `wire(..., wire_throttle())`

The JS side is an `irid.defineWidget("plotly", factory)` registration that owns the `Plotly.react()` / `Plotly.relayout()` / `Plotly.purge()` calls, routes plotly's source events to the bound props via `setProp` and to discrete callbacks via `sendEvent`.

### R side — wrapper sketch

```r
PlotlyOutput <- function(
  spec,
  ...,                          # named state args: xaxis_range, dragmode, etc.
  onClick             = NULL,
  onHover             = NULL,
  onUnhover           = NULL,
  onDoubleclick       = NULL,
  onDeselect          = NULL,
  onSelecting         = NULL,
  onBrushing          = NULL,
  onLegendClick       = NULL,
  onLegendDoubleclick = NULL,
  onClickAnnotation   = NULL,
  onSunburstClick     = NULL,
  onRelayout          = NULL
) {
  state <- list(...)
  validate_named_args(state)               # error on names not in the translation table

  # The spec is always a function; wrap it as a callable prop that serializes
  # to plotly's JSON spec each time its deps change. Like every callable prop
  # it is two-way-capable, but the client never writes the spec back.
  spec_prop <- function() to_plotly_spec(spec())   # returns a JSON *string* (see below)

  IridWidget(
    name  = "plotly",
    # Each named state arg rides as a *two-way prop*. A reactiveVal / store
    # leaf / reactiveProxy becomes a server->client binding PLUS a client->
    # server setProp write-back (with automatic snap-back); a constant
    # (including NULL) rides init-only with no observer. The relayout/hover-
    # sourced props get throttled, coalesced write-back timing via wire(); a
    # caller overrides per-arg by passing its own wire(subject, timing).
    props = c(
      list(spec = spec_prop),
      throttle_stream_props(state)
    ),
    # events carry ONLY the discrete notifications plus the raw relayout escape
    # hatch — never the per-field state fan-out (the JS side does that via
    # setProp). Keys are lowercase kebab-case; NULL entries drop out.
    events = compact(list(
      relayout             = onRelayout,
      click                = onClick,
      hover                = onHover,
      unhover              = onUnhover,
      doubleclick          = onDoubleclick,
      deselect             = onDeselect,
      selecting            = onSelecting,
      brushing             = onBrushing,
      `legend-click`       = onLegendClick,
      `legend-doubleclick` = onLegendDoubleclick,
      `click-annotation`   = onClickAnnotation,
      `sunburst-click`     = onSunburstClick
    )),
    deps  = plotly_dependency()
  )
}
```

What's relying on what in `IridWidget`:

- **Named state args are two-way props.** Each arg in `...` flows straight into `IridWidget`'s `props`, where per-key `is.function()` dispatch makes a `reactiveVal` (or any callable) a two-way binding and a constant (including `NULL`) an init-only value. Because props are two-way by construction, the wrapper writes *nothing* to get write-back and snap-back — the JS side's `setProp(name, value)` drives the bound callable, and a rejecting `reactiveProxy` snaps the plot back through the per-binding force-send (see below).
- **`spec` is always a callable prop.** Because the user always passes a function, the spec rides as a binding: `isolate(spec_prop())` seeds the init message, and re-evaluations arrive on the JS side inside the coalesced `update(values)` batch as `values.spec` — folded into the same `Plotly.react()` as any state props that changed in the same flush.
- **The translation table (§7) lives on the R side** only as the wrapper's reference for validating unknown names at construction time. The JS side keeps its own mirror for two jobs: looking up the spec path when merging, and routing each source-event field to the right `setProp(name, …)`. The wire never carries the table itself.

### Spec serialization — pre-encode with plotly's own `to_JSON`, ship a string

> **Empirically grounded.** Verified against `{plotly}` 4.12.0 with the throwaway
> harness in [`dev/spikes/plotly-serialize-spike.R`](spikes/plotly-serialize-spike.R).

`to_plotly_spec()` does **not** hand the substrate a raw R list of the spec; it
returns a **JSON string** that the JS side `JSON.parse`s. The recipe:

```r
to_plotly_spec <- function(p) {
  b <- plotly::plotly_build(p)              # works for plot_ly() AND ggplotly() — identical structure
  plotly:::to_JSON(list(data = b$x$data, layout = b$x$layout, config = b$x$config))
}
```

Why a string, not a list: a prop value is serialized by the **substrate's**
encoder (`shiny:::toJSON`, via `sendCustomMessage`), not plotly's. The two are
*nearly* identical in practice — Shiny defaults to `digits = 16, use_signif,
auto_unbox, na = "null"`, so coordinate precision survives (the spike's first
"4-digit truncation" scare was an artifact of raw `jsonlite` defaults, which
Shiny overrides). But pre-encoding with plotly's own `to_JSON` **decouples plot
fidelity from Shiny's JSON option defaults** (a user's `options(shiny.json.*)`,
Shiny-version drift) and reproduces *exactly* what the `{plotly}` htmlwidget
itself ships. The string round-trips through the substrate byte-for-byte (spike
Q2). The **state props** (ranges, dragmode, `selected_points`) stay ordinary
values — they are simple scalars/vectors the substrate encoder handles cleanly,
so only `spec` is pre-stringified. JS side: `var m = JSON.parse(props.spec)` then
`Plotly.react(el, m.data, m.layout, m.config)`.

`plotly_dependency()` is the five html dependencies `plotly_build()` attaches
(`typedarray`, `jquery`, `crosstalk`, `plotly-htmlwidgets-css`, `plotly-main`),
grabbed once from a built throwaway plot. All five carry `package` + `src$file`,
which is exactly what the substrate's `register_widget_dep` resolves. Note the
bundled **plotly.js is 2.25.2** (not the 2.35.2 a casual CDN pull gives); the §5
behavioral spike was re-confirmed on 2.25.2 for this reason.

### Source events route to props, not R-side handlers

In the two-way-prop model the relayout fan-out lives entirely on the JS side. A `plotly_relayout` payload is dot-notation that maps to several named props; the widget walks its mirror of the translation table and calls `setProp(name, value)` once per matching field. Each `setProp` lands on that prop's own `irid_prop_{id}_{name}` input and writes the bound callable independently — so a `reactiveProxy` on `xaxis_range` can reject while `yaxis_range` accepts, and each field snaps back or sticks on its own. There is no R-side multi-write handler to build.

The raw payload is *also* forwarded — the JS calls `sendEvent("relayout", payload)`, which routes to the user's `onRelayout` callback (a silent no-op if unbound). So named props and the escape hatch compose: props capture the table-known fields, `onRelayout` sees the whole raw payload.

Single-source props are even simpler: `plotly_selected` → `setProp("selected_points", …)`, `plotly_restyle` → `setProp("trace_visibility", …)`. The discrete-only events (`click`, `hover`, `unhover`, `doubleclick`, …) are pure `sendEvent` calls with no prop side. The wrapper drops any `events` entry whose callback is `NULL`; `setProp` / `sendEvent` are silent no-ops with no R subscriber anyway, but omitting the registration keeps the managed-state table clean.

### Parsing the relayout payload

`plotly_relayout` does not hand back clean `{ "xaxis.range": [lo, hi] }`
objects. The payload is a flat bag of dot/bracket-notation keys whose exact
spelling depends on the gesture, and the keys are relative to `layout` (the
`layout.` prefix of the spec path is dropped). So each relayout-sourced entry
carries a `relayoutKey` (its spec path minus `layout.`) and a
`fromRelayout(payload)` reader that returns one of three things:

- a **value** — the field changed; write it to the prop;
- `null` — the user *reset* the field (e.g. double-click autoscale); clear the
  prop to `NULL` so it defers to the spec;
- `undefined` — this gesture didn't touch the field; leave the prop alone.

The `null`-vs-`undefined` split is exactly what the JS sketch's
`if (v !== undefined) setProp(entry.name, v)` leans on — `null` clears, absent
abstains.

The gestures a **range** reader must fold together:

| gesture                | payload keys                                | reader result |
|------------------------|---------------------------------------------|---------------|
| drag-zoom / pan        | `xaxis.range[0]`, `xaxis.range[1]` (split!) | `[lo, hi]`    |
| programmatic / API set | `xaxis.range` (whole array)                 | `[lo, hi]`    |
| double-click reset     | `xaxis.autorange: true` (no range keys)     | `null`        |
| unrelated gesture      | (key absent)                                | `undefined`   |

A range `fromRelayout` therefore checks, in order: whole-array key → split
`[0]`/`[1]` keys → `<axis>.autorange === true` → otherwise `undefined`. The
split form is the one a drag actually produces; the whole-array form never
appears from direct interaction. A **scalar** entry (`dragmode`, `hovermode`) is
the simple case: present key → value, absent → `undefined`. Subplot entries use
the same shapes with the axis number baked into `relayoutKey`
(`xaxis2.range[0]`, …).

Two robustness notes:

- The split keys arrive together for any drag. If only one half ever shows up,
  the reader treats the gesture as `undefined` (skip) rather than fabricating a
  half-range; a follow-up can read the missing half off the graph if real plots
  turn out to emit partial payloads.
- `<axis>.autorange: false` — which plotly often includes *alongside* a concrete
  range — is ignored, because the explicit range is checked first. The reader
  returns the range, not `null`.

This parsing only runs for genuine user gestures. `Plotly.react()` itself emits
no `plotly_relayout` (§5, spike Q1/Q2), so there is no auto-fit echo to filter;
the only non-user relayout is the synchronous echo from our *own* targeted
`Plotly.relayout()` / `Plotly.restyle()`, which the `applying` guard (§5)
`return`s on before the fan-out — so a snap-back/apply/reset we issued never
re-enters `fromRelayout`.

### Snap-back is automatic

The original design specced an explicit JS-side "diff server-authoritative vs last-sent" snap-back path. With the two-way-prop substrate that's gone — the per-binding force-send-on-no-op echo and the widget's idempotent `update` hook combine to deliver it:

1. User zooms → plotly fires `plotly_relayout` → JS calls `setProp("xaxis_range", newRange)`.
2. The write pushes through `irid_prop_{id}_xaxis_range` (same managed-state / sequence transport as an event). R's synthesized prop handler attempts the write; the `reactiveProxy` (or read-only callable) rejects it — the bound callable's canonical value is *unchanged*.
3. The force-send-on-no-op loop, **scoped to that one binding** (`write_targets = "xaxis_range"`), re-reads it with `isolate()` and queues an `irid-attr target="widget"` carrying the **old** canonical value in the coalesced `values` map, tagged with the source sequence. (This is what makes read-only snap-back automatic for every two-way prop — the wrapper writes nothing extra to get it.)
4. The widget's `update({xaxis_range: oldValue})` hook compares against plotly's current state, sees a mismatch, and calls `Plotly.relayout(el, {"xaxis.range": oldValue})` — the snap. (The stale-echo gate upstream guarantees ordered batches, so the hook needs no sequence argument.)

The per-binding scoping matters for plotly specifically: a relayout that only moved the x-axis must not force-send `yaxis_range` while a debounced y-axis write is still in flight.

**Step 4 must be a *targeted* `Plotly.relayout()`, not a re-`react()` — the spike proves it.** Re-rendering the spec with the unchanged old range merged in does *not* snap the plot back: under `uirevision`, a layout value equal to the previous render's value loses to the user's intervening zoom (Q2d — the re-asserted `[0,6]` was ignored in favor of the hand-zoom). Only a direct `Plotly.relayout()` overrides the live view, because it's a state update, not a reconciliation. The echo that targeted call then fires is swallowed by the `applying` guard (Q4), and `matchesCurrent` backstops any cross-flush race. **The wrapper writes nothing extra to get snap-back; declaring the prop is sufficient** — a framework guarantee for every two-way prop.

One consequence worth surfacing to users: a **constant** (init-only) range prop is therefore *uncontrolled* — it seeds the initial view but has no write-back and no snap-back, so a user zoom sticks. To *lock* a range against interaction, bind a read-only `reactiveProxy` (its rejected write triggers the snap-back above); a bare constant is an initial value, not a constraint.

### JS side — `irid.defineWidget("plotly", ...)`

```js
irid.defineWidget("plotly", function (el, props, sendEvent, setProp) {
  var TABLE = PLOTLY_TRANSLATION_TABLE;     // mirror of the R-side table
  var applying = false;                     // raised around our own graph mutations
  var spec = props.spec;
  var state = {};
  TABLE.forEach(function (e) { state[e.name] = props[e.name]; });

  // every programmatic mutation runs through this guard. react() is silent (Q1/
  // Q2) so wrapping it is only defensive; relayout()/restyle() echo a synchronous
  // plotly_relayout (Q4) that the guard makes the listener ignore.
  function mutate(fn) { applying = true; return fn().then(function () { applying = false; }); }

  function merge(spec, state) {
    var s = deepCopy(spec);
    if (s.layout.uirevision == null) s.layout.uirevision = "irid";
    TABLE.forEach(function (entry) {
      var v = state[entry.name];
      if (v != null) entry.writeSpec(s, v);   // identity for ranges; per-trace
    });                                        // converter for the data[*] entries
    return s;
  }

  function render() {
    return mutate(function () { var m = merge(spec, state); return Plotly.react(el, m.data, m.layout); });
  }

  render();

  // user-driven layout changes fan out across the named state props
  el.on("plotly_relayout", function (payload) {
    if (applying) return;                   // our own relayout/restyle echo, not user
    TABLE.forEach(function (entry) {
      if (entry.source !== "relayout") return;
      var v = entry.fromRelayout(payload);    // value | null | undefined
      if (v !== undefined) setProp(entry.name, v);     // two-way prop write-back
    });
    sendEvent("relayout", payload);          // raw escape hatch (no-op if unbound)
  });
  el.on("plotly_selected", function (e) { setProp("selected_points", pointsToFrame(e.points)); });
  el.on("plotly_deselect", function ()  { setProp("selected_points", null); });
  el.on("plotly_restyle",  function ()  { setProp("trace_visibility", readVisibility(el)); });
  el.on("plotly_click",    function (e) { sendEvent("click", e); });
  el.on("plotly_hover",    function (e) { sendEvent("hover", e); });
  // ... one listener per discrete event in the wrapper's events list ...

  return {
    // server -> client: a coalesced { key -> value } batch (spec and/or state)
    update: function (values) {
      var reactNeeded = "spec" in values;
      if (reactNeeded) spec = values.spec;
      TABLE.forEach(function (entry) {
        if (!(entry.name in values)) return;
        var v = values[entry.name];
        state[entry.name] = v;
        if (reactNeeded) return;             // folded into the upcoming render()
        // entry.apply / applyDeferred pick the primitive — Plotly.relayout for
        // layout paths, Plotly.restyle for the data[*] entries — run the
        // value->spec conversion, and wrap the call in mutate() so its echo is
        // guarded. applyDeferred resets to the spec's value (autorange:true when
        // the spec has no explicit range — a real reset, not a merge-omit; §5).
        if (v == null) entry.applyDeferred(el, spec);          // "defer to spec" = reset
        else if (!entry.matchesCurrent(el, v)) entry.apply(el, v);   // snap / apply
      });
      if (reactNeeded) render();             // one redraw for the whole batch
    },
    destroy: function () {
      Plotly.purge(el);
    }
  };
});
```

Notes on what's load-bearing on the substrate:

- `props` arrives as a single merged object containing both the spec and the named state args — the `irid-widget-init.props` contract. The factory doesn't need to know which fields were callable on the R side; that shows up only in which keys later appear in `update(values)`.
- `update(values)` receives a `{ key -> value }` map, never a single `(key, value)` pair. Multiple props that changed in the same server flush — e.g. a new `spec` and a fresh `xaxis_range` — arrive coalesced in one call, so the factory folds them into a single `Plotly.react()` and the atomic-render library redraws once, no flash. Pure state changes (no `spec`) take the targeted per-key apply path (`Plotly.relayout` for layout entries, `Plotly.restyle` for the `data[*]` entries).
- `setProp` and `sendEvent` are silent no-ops for keys/events with no R subscriber. The widget can register listeners for every plotly event unconditionally and let the framework gate which round-trip — the per-field `setProp` writes and the discrete `sendEvent` notifications alike.
- The widget's `destroy()` runs from the client's detach walker on `irid-swap` / `irid-mutate` removals — no custom client teardown code in `PlotlyOutput`.

### Wire protocol

No new messages. The traffic is exactly the widget-substrate messages:

- **`irid-widget-init`** — `{ id, name: "plotly", props: { spec, xaxis_range, ... }, deps: [plotlyDep] }`. Sent after the swap that introduces the placeholder div.
- **`irid-attr target="widget"`** — fired by the per-key prop observers on the R side, coalesced per flush into one message carrying a `values: { key -> value }` map (spec and/or state). The widget routes it to its `update(values)` hook.
- **`irid-events`** with `source: "widget"` — set up at mount for each registered discrete event (and the `relayout` escape hatch) in the wrapper's `events` list, with each event's `wire` timing applied.
- **`irid_prop_{id}_{key}`** — the client → server half of each two-way state prop. `setProp(key, value)` pushes the user's new value here through the managed-state / sequence transport; mount's synthesized prop handler writes the bound callable.

### Dependencies

`plotly_dependency()` returns the `htmltools::htmlDependency` for plotly.js, sourced from the suggested `{plotly}` package. The wrapper passes it to `IridWidget(deps = ...)`, which lifts it through `widget_inits` and ships it on `irid-widget-init` — the `htmltools::as.character()` strip issue is handled by the substrate, not PlotlyOutput.

The wrapper errors at construction time if `{plotly}` isn't installed, with a message pointing the user at `install.packages("plotly")`.

### Per-binding event timing

Timing rides each prop and event via `wire`, not a separate `.event` argument. The wrapper wraps the high-frequency, relayout/hover-sourced state props (and the `relayout` escape-hatch event) in `wire(subject, wire_throttle(100), coalesce = TRUE)` so streaming zooms and hovers gate on server-idle; `selected_points` and `click` stay `wire_immediate()`. A caller tunes any single arg by passing its own `wire()` in place of the bare callable — e.g. `xaxis_range = wire(xrange, wire_immediate())` — exactly as anywhere else in irid. There is no PlotlyOutput-specific timing API.

---

## 7. Feature Translation Table

The translation table is the list of plotly features `PlotlyOutput` knows how to bind as named args. Each entry specifies:

- **Name** — the named arg as seen by the user
- **Spec path** — where the value is merged into the plotly spec
- **Source event** — the plotly.js event that writes back to it
- **Converters / apply primitive** — `fromEvent` (event payload → canonical
  value; relayout-sourced entries use `fromRelayout`, which reads `relayoutKey`
  out of the shared payload and may return `null`/`undefined` — see *Parsing the
  relayout payload* in §6), `writeSpec` (value → spec merge), and `apply` (value
  → live graph via `Plotly.relayout` or `Plotly.restyle`). Symmetric entries get
  identity defaults; the asymmetric `data[*]` entries supply their own (see
  *Value shapes*).

Launch-scope table (everything else lives in the `onRelayout` escape hatch):

| Named arg              | Spec path                  | Source event                          |
|------------------------|----------------------------|---------------------------------------|
| `xaxis_range`          | `layout.xaxis.range`       | `plotly_relayout`                     |
| `yaxis_range`          | `layout.yaxis.range`       | `plotly_relayout`                     |
| `xaxis<n>_range`       | `layout.xaxis<n>.range`    | `plotly_relayout` (pattern-matched)   |
| `yaxis<n>_range`       | `layout.yaxis<n>.range`    | `plotly_relayout` (pattern-matched)   |
| `dragmode`             | `layout.dragmode`          | `plotly_relayout`                     |
| `hovermode`            | `layout.hovermode`         | `plotly_relayout`                     |
| `selected_points` †    | `data[*].selectedpoints`   | `plotly_selected` / `plotly_brushed` / `plotly_deselect` |
| `trace_visibility` †   | `data[*].visible`          | `plotly_restyle`                      |

† Not symmetric — the event payload and the spec path differ in shape, and the
field lives on a `data[*]` array (applied via `Plotly.restyle`, not
`Plotly.relayout`). See *Value shapes* below.

### Value shapes for selection and visibility

Most table entries are *symmetric*: the event reports the same shape the spec
path consumes (a range in, a range out), so the entry's `writeSpec` / `apply` /
`fromEvent` are identity wrappers over `setSpecPath` and `Plotly.relayout`. Two
entries are not symmetric — the event payload and the spec path speak different
languages — so each defines a canonical R value and converts in both directions.
The asymmetry is sealed inside the translation-table entry; user code only ever
sees the canonical value.

**`selected_points` — `data.frame(curve, point)` (1-based), or `NULL`.**

`plotly_selected` returns a flat list of point *objects*
(`{curveNumber, pointNumber, x, y, …}`) spanning every trace, while the spec
path `data[*].selectedpoints` wants per-trace *integer index* arrays. The
canonical value bridges them as a two-column data frame — one row per selected
point — echoing `{plotly}`'s own `event_data("plotly_selected")` shape:

| column  | meaning                               |
|---------|---------------------------------------|
| `curve` | 1-based trace index                   |
| `point` | 1-based point index within that trace |

irid reports **1-based** indices, not plotly.js's 0-based `curveNumber` /
`pointNumber`, so `df()[selected()$point, ]` indexes the bound data directly.
The JS↔value boundary does the ±1. (This is the one deliberate divergence from
`{plotly}`'s 0-based `event_data` — reversible if matching plotly verbatim turns
out to matter more than R-native indexing.)

- **event → value** (`pointsToFrame`, on `plotly_selected`): map each
  `payload.points[i]` to a row `(curveNumber + 1, pointNumber + 1)`.
  `plotly_deselect` → `NULL`.
- **value → spec** (`writeSpec` / `apply`): group rows by `curve` and set
  `data[curve − 1].selectedpoints = point − 1` per trace via `Plotly.restyle`.
  A trace that is part of an active selection but holds no selected points gets
  `[]` (plotly dims it); a `NULL` value omits `selectedpoints` entirely (no
  dimming).

The value carries only what *persists and restores* a selection. The rich,
transient geometry — coordinates, box/lasso extent — is not state; it rides the
`onSelecting` raw payload during the drag (and an `onSelected` callback for the
final payload, if one is added — additive, parallel to how `onRelayout` sits
beside the range props). Bookmark
fidelity: the `(curve, point)` pairs restore the highlighted/dimmed state across
a reload as long as the underlying data order is stable; the selection rectangle
itself is not redrawn.

**`trace_visibility` — character vector over `{"true","false","legendonly"}`,
trace-aligned, or `NULL`.**

`plotly_restyle` reports only *which* traces changed and to what
(`[{visible:"legendonly"}, [2]]`); the spec path `data[*].visible` is a
per-trace tri-state. The canonical value is the full trace-aligned vector:

- **event → value** (`readVisibility`, on `plotly_restyle`): read every trace's
  current `visible` off the graph and stringify (`true → "true"`,
  `false → "false"`, `"legendonly"` unchanged).
- **value → spec** (`writeSpec` / `apply`): set each `data[i].visible` to the
  typed value (`"true" → true`, `"false" → false`, else `"legendonly"`) via
  `Plotly.restyle`.
- `NULL` defers to the spec — visibility is left untouched during the merge.

A plain logical vector can't hold the `"legendonly"` third state, so the value
is character; a caller toggling visibility compares against the three string
literals.

Fields to add post-launch as usage patterns become clear:

- `scene_camera` — 3D camera position (`layout.scene.camera`, `plotly_relayout`)
- `mapbox_center`, `mapbox_zoom`, `mapbox_bearing`, `mapbox_pitch` — mapbox viewport
- `geo_projection_rotation` — geo projection rotation
- Range slider extent
- Slider/animation position

The table grows additively. Adding a new entry doesn't break any existing code — unknown-in-old-version / known-in-new-version named args were previously handled via `onRelayout` escape hatch, and users can opt into the named-arg version when convenient.

---

## 8. Scope

### What this covers

- `PlotlyOutput` as a thin `IridWidget` wrapper, shipped from irid core
- Incremental rendering via `Plotly.react()`
- Named reactive args for stateful fields, backed by the translation table — each a two-way `IridWidget` prop (server→client binding + `setProp` write-back)
- Discrete event callbacks (`onClick`, `onHover`, `onUnhover`, `onDoubleclick`, `onDeselect`, `onSelecting`, `onBrushing`, `onLegendClick`, `onLegendDoubleclick`, `onClickAnnotation`, `onSunburstClick`) — flowing through `IridWidget`'s `events`
- `onRelayout` escape hatch for fields outside the table
- `reactiveProxy` for constrained writes — snap-back falls out of `IridWidget`'s per-binding force-send-on-no-op echo + the widget's `update(values)` hook calling `Plotly.relayout`
- Bookmark serialization via user-constructed `reactiveStore`s
- Self-echo suppression for our own programmatic mutations (client-side `applying` flag inside the widget factory; `Plotly.react()` itself is silent, so there is no auto-fit echo to distinguish — §5)
- `uirevision`-aware client-side state handling

### What this does not cover

- A canonical "plotly state store" constructor — plotly has no canonical state shape, so there is nothing for such a constructor to contain (Section 3)
- Surgical `Plotly.restyle()` / `Plotly.relayout()` as the primary render path — `Plotly.react()` diffs internally and is fast enough; targeted `relayout` is used only for snap-back corrections and per-key state updates
- A separate `irid.plotly` package — not justified unless `Plotly.react()` proves insufficient for large datasets
- React component wrapping — out of scope; React support is a separate package with its own runtime dependency and build step
- Generic `htmlwidgets` bridge — most htmlwidgets don't support incremental updates
- Any extension to the `IridWidget` framework — `PlotlyOutput` is a pure consumer of the substrate (see [ARCHITECTURE.md](../ARCHITECTURE.md#widgets)). Section 10 catalogs the load-bearing assumptions.

---

## 9. Open Questions

### Resolved by the spike (Plotly 2.35.2, re-confirmed on the bundled 2.25.2)

These were open; [`dev/spikes/plotly-uirevision-spike.html`](spikes/plotly-uirevision-spike.html)
settled them, and the
[`-2.25.html`](spikes/plotly-uirevision-spike-2.25.html) copy returned identical
verdicts on the version `{plotly}` 4.12.0 actually bundles. Re-confirm on a
`{plotly}` bump.

- **Distinguishing user zoom from spec-computed state — moot.** `Plotly.react()` emits *no* `plotly_relayout` (Q1/Q2), so there is no auto-fit echo to filter. The only non-user relayout is the synchronous echo from our *own* targeted `Plotly.relayout()`/`restyle()` (Q4), guarded by the `applying` flag (§5). The earlier user-vs-react timing heuristic is gone.
- **Snap-back must be targeted, and it works.** A re-`react()` with the unchanged old value does *not* revert a user zoom under `uirevision` (Q2d); a direct `Plotly.relayout()` does. Its echo is swallowed by `applying`, and the same-flush coalescing means a real apply redraws once.
- **`matchesCurrent` reads public API.** After a zoom, `gd.layout.xaxis.range` equals `gd._fullLayout.xaxis.range` (Q3) — no `_fullLayout` introspection needed for layout ranges.
- **`NULL` reset is real, via the targeted path.** Merge-omit preserves the current view (Q2b); a genuine reset needs `autorange: true` (Q2e), which `applyDeferred` issues. Both behaviors are intended (§5).

### `plotly_brushed` vs `plotly_selected` internal state

`plotly_brushed` and `plotly_selected` are separate events in plotly.js, but it's unclear whether they write to the same internal `selectedpoints` attribute or maintain genuinely distinct state. The named-args model supports either resolution additively:

- **Shared state** → a single `selected_points` named arg that both events write to. Users who care about the interaction type use `onSelected` / `onBrushed` discrete callbacks alongside.
- **Distinct state** → a separate `brushed_points` (or similarly named) arg in the translation table.

Launch plan: ship with one `selected_points` arg fed from both events, since that's the likelier shared-state scenario. If plotly.js behavior shows they're distinct, add a second named arg — additive change, no breaking.

### Snap-back residuals beyond the launch table

The snap-back path (Section 6) is settled for the launch-scope layout ranges and scalars (spike Q2d/Q3/Q4). What the spike did *not* cover, to confirm when those fields are promoted from the `onRelayout` escape hatch into the table:

- **Nested / post-launch paths** — `scene.camera.eye.x` (3D), mapbox viewport, geo rotation. Targeted `relayout` was only verified for `xaxis.range` and `dragmode`; whether it bypasses `uirevision` identically for nested camera paths, and whether `matchesCurrent` can read them off public state, needs its own check before each is added.
- **Animated transitions** — if a plot uses plotly's transition/animation layer, a correction issued mid-transition may interleave with plotly's own tween. The `applying` guard + `matchesCurrent` should still converge, but ordering under an active transition is unverified.

### Integration with irid's stale UI indicator

`Plotly.react()` runs client-side and is fast. But the R-side serialization and message round-trip still takes time. Should the stale indicator fire during plotly updates, or is the perceived latency low enough to skip it?

### Dynamic subplot axes

A plot may have a variable number of subplot axes depending on the data. The named-args model handles fixed and programmatic N via splicing, but a user whose axis count changes at runtime must remount the component (same as any other dynamic UI). Whether a cleaner "all axes at once" binding is needed depends on how often this comes up.

### Growing the table

New fields are added to the translation table as usage patterns clarify which plotly features are common enough to warrant first-class support. The `onRelayout` escape hatch covers everything else in the meantime. Criteria for promotion: (1) multiple users bind the field via the escape hatch, (2) the field has a stable payload shape across plot types, (3) snap-back semantics are well-defined for it.

---

## 10. Substrate dependence — what PlotlyOutput leans on `IridWidget` for

`PlotlyOutput` is fully expressible on top of the `IridWidget` substrate (see [ARCHITECTURE.md](../ARCHITECTURE.md#widgets)); no new framework features are required. The notes below catalog the substrate guarantees PlotlyOutput's correctness depends on, so that future changes to `IridWidget` know PlotlyOutput is a downstream consumer of these contracts.

- **Per-binding force-send echoes the rejected prop's canonical value.** PlotlyOutput's snap-back path *requires* that when a `reactiveProxy` rejects a `setProp` write, the framework still emits `irid-attr target="widget"` carrying that prop's unchanged canonical value, so the widget's `update` hook can snap plotly back. The substrate scopes this echo per-binding (`write_targets`), which is exactly right for plotly: a relayout that only moved the x-axis must not force-send `yaxis_range` while a debounced y-axis write is still in flight. (The original design assumed an echo of *every* binding; the per-binding scoping the substrate actually ships is stricter and is what PlotlyOutput now leans on.)

- **`update(values)` delivers a coalesced `{ key -> value }` batch.** PlotlyOutput's idempotence path compares each value against plotly's current state at the corresponding path; the substrate handles sequence / stale-echo gating upstream, so no sequence reaches the hook. The per-flush coalescing is load-bearing: folding a same-flush `spec` change plus state changes into one `update` call is what lets PlotlyOutput redraw once via a single `Plotly.react()` instead of flashing on each message.

- **The init message ships a single merged `props` object** containing both the spec and the named state args. The factory destructures `props.spec` and the named keys from one object. If the substrate ever split init into "constant" and "binding-driven" channels, the factory would need to adapt.

- **`setProp` and `sendEvent` are silent no-ops when no R subscriber exists.** PlotlyOutput's JS registers a listener for every plotly event it knows about and lets the framework gate which ones round-trip — the per-field `setProp` writes for table-known fields and the discrete `sendEvent` notifications alike. If the substrate ever required pre-declaring every event/prop a widget can emit, PlotlyOutput would switch to conditionally registering plotly listeners based on which `events` and state args the wrapper received — feasible but tighter.

- **State args are two-way props with per-field write-back.** PlotlyOutput leans on each named arg being an *independent* two-way prop so that per-field proxy rejection works (x snaps back while y sticks) and a multi-field `plotly_relayout` payload routes to N independent `setProp` calls — no R-side multi-write handler. This is what makes the fan-out the substrate now renders unnecessary; collapsing the state args back into a single event channel would reintroduce it.

- **`is.function()` dispatch on `props` is per-key.** A `reactiveVal` becomes a two-way binding; a constant (including `NULL`) becomes an init-only static prop. PlotlyOutput's named state args rely on both halves: `xaxis_range = NULL` should not produce an observer; `xaxis_range = rv` should. Removing the per-key dispatch (e.g., requiring all `props` to be either all-callable or all-static) would require the wrapper to do that classification itself.

- **`wire` tunes a prop's or event's timing without disabling two-way.** PlotlyOutput's "relayout / hover throttled, selected / click immediate" defaults come from wrapping those props and events in `wire(subject, wire_throttle(...))`; a caller overrides per-arg with their own `wire`. This relies on `wire` tuning only the write-back / emit rate of the slot it wraps, never its two-way-ness.

- **Targeted `Plotly.relayout()` bypasses `uirevision` preservation.** Strictly a plotly-internal property, not a substrate one — but the snap-back design is wholly load-bearing on it. If plotly ever changes this, no widget-level workaround exists; PlotlyOutput would need to retain the original design's "track last-sent per field" intent somewhere (likely client-side in the widget factory).

None of the items above are gaps in `IridWidget` — they are contracts the substrate already meets that PlotlyOutput depends on continuing to meet.
