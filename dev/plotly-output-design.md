# PlotlyOutput — Design Document

**Status:** Proposed  
**Date:** April 2026

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

`PlotlyOutput` carries no custom `process_tags` extraction, no custom wire-message, and no custom client mount path. All of that comes from the `IridWidget` substrate. The wrapper's job is to:

- map the user's spec function and named state args into the `props` shape that `IridWidget` understands
- build the `events` handlers that fan plotly's source events out to the bound state callables, and call user-supplied discrete callbacks
- ship plotly's `htmlDependency` via `IridWidget(deps = ...)`
- supply sensible per-event timing defaults via `event_defaults()`

The JS side is an `irid.defineWidget("plotly", factory)` registration that owns the `Plotly.react()` / `Plotly.relayout()` / `Plotly.purge()` calls and emits raw event payloads via `send()`.

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
  onRelayout          = NULL,
  .event              = NULL
) {
  state <- list(...)
  validate_named_args(state)               # error on names not in the translation table

  # The spec is always a function; wrap it as a callable prop that serializes
  # to plotly's JSON spec each time its deps change.
  spec_prop <- function() to_plotly_spec(spec())

  IridWidget(
    name   = "plotly",
    props  = c(list(spec = spec_prop), state),
    events = build_event_handlers(
      state               = state,
      onClick             = onClick,
      onHover             = onHover,
      onUnhover           = onUnhover,
      onDoubleclick       = onDoubleclick,
      onDeselect          = onDeselect,
      onSelecting         = onSelecting,
      onBrushing          = onBrushing,
      onLegendClick       = onLegendClick,
      onLegendDoubleclick = onLegendDoubleclick,
      onClickAnnotation   = onClickAnnotation,
      onSunburstClick     = onSunburstClick,
      onRelayout          = onRelayout
    ),
    deps   = plotly_dependency(),
    .event = event_defaults(
      .event,
      relayout = event_throttle(100, coalesce = TRUE),
      hover    = event_throttle(100, coalesce = TRUE),
      selected = event_immediate(),
      click    = event_immediate()
    )
  )
}
```

What's relying on what in `IridWidget`:

- **Per-key dispatch on `is.function()`.** The named state args in `...` flow straight into `IridWidget`'s `props`. A `reactiveVal` (or any other callable) becomes a per-key binding; a constant (including `NULL`) becomes an init-only value. The wrapper does no special casing — `IridWidget`'s per-key dispatch handles this.
- **`spec` is always a callable prop.** Because the user always passes a function, the spec rides as a binding: `isolate(spec_prop())` is read into the init message, and re-evaluations fire `irid-attr widget:spec` updates with the new serialized JSON.
- **The translation table (§8) lives only on the R side** — it's the wrapper's reference for (a) validating unknown names at construction time and (b) fanning source-event payloads to named-arg callables. The JS side has its own mirror of the table for path lookups; the wire never carries the table itself.

### Event handlers — the relayout fan-out

The plotly_relayout event delivers a dot-notation payload that maps to multiple named-arg callables. The wrapper builds a single `relayout` handler that fans writes across all writable bound callables, then forwards the raw payload to `onRelayout` if the user supplied one. The widget framework explicitly allows multi-write handlers in `events =` — the canonical `write_back(callable, field)` helper covers the single-target case, and hand-rolled `\(e) ...` handlers cover the multi-write case:

```r
build_relayout_handler <- function(state, onRelayout) {
  function(e) {
    for (entry in TRANSLATION_TABLE_RELAYOUT) {
      callable <- state[[entry$name]]
      if (!can_accept_write(callable)) next
      value <- extract_from_payload(e, entry$path)
      if (!is.null(value)) callable(value)
    }
    if (!is.null(onRelayout)) onRelayout(e)
  }
}
```

The handlers for `plotly_selected`, `plotly_restyle`, and similar single-target sources are simpler `write_back`-style one-liners. The discrete-only events (`click`, `hover`, `unhover`, `doubleclick`, …) get a 1-line handler that just calls the user's callback if it's non-`NULL`.

The wrapper omits any `events` entry whose user callback is `NULL` *and* whose translation-table fan-out has no writable target. The JS-side `send` would be a silent no-op in that case anyway (no-R-subscriber `send` calls drop silently), but skipping the registration keeps the managed-state table clean.

### Snap-back is automatic

The original design specced an explicit JS-side "diff server-authoritative vs last-sent" snap-back path. With the widget substrate that's no longer needed — the framework's force-send-on-no-op loop and the widget's idempotent `update` hook combine to deliver the same behavior:

1. User zooms → plotly fires `plotly_relayout` → JS calls `send("relayout", payload)`.
2. R relayout handler fires. The `reactiveProxy` (or read-only callable) rejects the write — the bound callable's canonical value is *unchanged*.
3. The framework's force-send-on-no-op loop reads every binding on the widget's id, `isolate`-evaluates each, and emits `irid-attr target="widget"` with the **old** canonical value, tagged with the source event's sequence. (This is what makes read-only snap-back automatic for every widget — the wrapper writes nothing extra to get it.)
4. The widget's `update("xaxis_range", oldValue)` hook compares against plotly's current state, sees a mismatch, and calls `Plotly.relayout(el, {"xaxis.range": oldValue})` — the snap. (The stale-echo gate upstream guarantees the hook never sees out-of-order values, so it needs no sequence argument.)

Targeted `Plotly.relayout()` bypasses `uirevision` preservation because it's a direct state update, not a reconciliation — same observation as the original design, now flowing through the generic substrate. **The wrapper writes nothing extra to get snap-back; registering the listener is sufficient** — a framework guarantee for every widget.

### JS side — `irid.defineWidget("plotly", ...)`

```js
irid.defineWidget("plotly", function (el, props, send) {
  var TABLE = PLOTLY_TRANSLATION_TABLE;     // mirror of the R-side table
  var settling = false;                     // suppress auto-fit relayout echoes
  var lastSpec = props.spec;
  var stateCache = {};
  TABLE.forEach(function (e) { stateCache[e.name] = props[e.name]; });

  function merge(spec, state) {
    var s = deepCopy(spec);
    if (s.layout.uirevision == null) s.layout.uirevision = "irid";
    TABLE.forEach(function (entry) {
      var v = state[entry.name];
      if (v != null) setSpecPath(s, entry.path, v);
    });
    return s;
  }

  function render(spec, state) {
    settling = true;
    var m = merge(spec, state);
    return Plotly.react(el, m.data, m.layout).then(function () { settling = false; });
  }

  render(lastSpec, stateCache);

  el.on("plotly_relayout", function (payload) {
    if (settling) return;                   // spec-computed (auto-fit), not user
    send("relayout", payload);
  });
  el.on("plotly_selected", function (e) { send("selected", e); });
  el.on("plotly_deselect", function ()  { send("selected", { points: null }); });
  el.on("plotly_restyle",  function (e) { send("restyle", e); });
  el.on("plotly_click",    function (e) { send("click", e); });
  el.on("plotly_hover",    function (e) { send("hover", e); });
  // ... one listener per event in the wrapper's events list ...

  return {
    update: function (key, value) {
      if (key === "spec") {
        lastSpec = value;
        render(lastSpec, stateCache);
        return;
      }
      var entry = TABLE.find(function (e) { return e.name === key; });
      if (!entry) return;                   // unknown key — silently dropped
      stateCache[key] = value;

      if (value == null) {
        // "defer to spec" — relayout to the spec's value at that path
        var specValue = getSpecPath(lastSpec, entry.path);
        Plotly.relayout(el, relayoutPatch(entry.path, specValue));
      } else {
        if (sameAsCurrent(el, entry.path, value)) return;     // idempotence
        Plotly.relayout(el, relayoutPatch(entry.path, value));
      }
    },
    destroy: function () {
      Plotly.purge(el);
    }
  };
});
```

Notes on what's load-bearing on the substrate:

- `props` arrives as a single merged object containing both the spec and the named state args — this is the `irid-widget-init.props` contract. The widget doesn't need to know which fields were reactive on the R side.
- `update` fires only for keys that were callable on the R side. Constant state args don't generate update messages; the widget never has to ignore "spurious" same-value updates that the substrate already filtered out.
- `send` is a silent no-op for events with no R subscriber. The widget can register listeners for every plotly event unconditionally and let the framework gate which round-trip.
- The widget's `destroy()` runs from the client's detach walker on `irid-swap` / `irid-mutate` removals — no custom client teardown code in `PlotlyOutput`.

### Wire protocol

No new messages. The traffic is exactly the widget-substrate messages:

- **`irid-widget-init`** — `{ id, name: "plotly", props: { spec, xaxis_range, ... }, deps: [plotlyDep] }`. Sent after the swap that introduces the placeholder div.
- **`irid-attr widget:<key>`** — fired by the per-key prop observers on the R side. The widget routes these to its `update(key, value)` hook.
- **`irid-events`** with `source: "widget"` — set up at mount for each registered event in the wrapper's `events` list, with the wrapper's `.event` timing applied.

### Dependencies

`plotly_dependency()` returns the `htmltools::htmlDependency` for plotly.js, sourced from the suggested `{plotly}` package. The wrapper passes it to `IridWidget(deps = ...)`, which lifts it through `widget_inits` and ships it on `irid-widget-init` — the `htmltools::as.character()` strip issue is handled by the substrate, not PlotlyOutput.

The wrapper errors at construction time if `{plotly}` isn't installed, with a message pointing the user at `install.packages("plotly")`.

### Element-level event timing

`event_defaults(.event, ...)` layers PlotlyOutput's preferred per-event timing (relayout / hover throttled, click immediate) underneath whatever the caller passes via `.event`. A caller scalar wins everywhere; a caller named list fills in per event. Callers who want every event immediate write `.event = event_immediate()`.

---

## 7. Feature Translation Table

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

## 8. Scope

### What this covers

- `PlotlyOutput` as a thin `IridWidget` wrapper, shipped from irid core
- Incremental rendering via `Plotly.react()`
- Named reactive args for stateful fields, backed by the translation table — flowing through `IridWidget`'s per-key `props`
- Discrete event callbacks (`onClick`, `onHover`, `onUnhover`, `onDoubleclick`, `onDeselect`, `onSelecting`, `onBrushing`, `onLegendClick`, `onLegendDoubleclick`, `onClickAnnotation`, `onSunburstClick`) — flowing through `IridWidget`'s `events`
- `onRelayout` escape hatch for fields outside the table
- `reactiveProxy` for constrained writes — snap-back falls out of `IridWidget`'s force-send-on-no-op + the widget's `update` hook calling `Plotly.relayout`
- Bookmark serialization via user-constructed `reactiveStore`s
- Auto-fit vs user-state distinction (client-side `settling` flag inside the widget factory)
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

### Detecting user-initiated relayout

The heuristic for distinguishing user zoom from auto-fit (Section 5) needs validation against real Plotly behavior. If unreliable, the fallback of only capturing state after explicit interaction events may be necessary.

### `plotly_brushed` vs `plotly_selected` internal state

`plotly_brushed` and `plotly_selected` are separate events in plotly.js, but it's unclear whether they write to the same internal `selectedpoints` attribute or maintain genuinely distinct state. The named-args model supports either resolution additively:

- **Shared state** → a single `selected_points` named arg that both events write to. Users who care about the interaction type use `onSelected` / `onBrushed` discrete callbacks alongside.
- **Distinct state** → a separate `brushed_points` (or similarly named) arg in the translation table.

Launch plan: ship with one `selected_points` arg fed from both events, since that's the likelier shared-state scenario. If plotly.js behavior shows they're distinct, add a second named arg — additive change, no breaking.

### Snap-back reliability with `uirevision`

The snap-back path (Section 6) is now: framework force-send-on-no-op → `irid-attr widget:<key>` echo → widget `update` hook → targeted `Plotly.relayout()`. The widget-substrate half is well-defined; the unknowns are plotly-internal:

- Whether targeted `relayout` reliably bypasses `uirevision` preservation for every bound field (arrays like `xaxis.range`, scalars like `dragmode`, nested paths like `scene.camera.eye.x`)
- Behavior under rapid user interactions while a correction is in flight (the widget's idempotence check — "incoming value equals plotly's current value" — gates redundant relayouts, but ordering with plotly's own transition layer needs prototype validation)
- Whether the widget can usefully read plotly's "current state at path" for the comparison (likely via `el._fullLayout` introspection or a per-event cache of last-sent payloads)

### Integration with irid's stale UI indicator

`Plotly.react()` runs client-side and is fast. But the R-side serialization and message round-trip still takes time. Should the stale indicator fire during plotly updates, or is the perceived latency low enough to skip it?

### Dynamic subplot axes

A plot may have a variable number of subplot axes depending on the data. The named-args model handles fixed and programmatic N via splicing, but a user whose axis count changes at runtime must remount the component (same as any other dynamic UI). Whether a cleaner "all axes at once" binding is needed depends on how often this comes up.

### Growing the table

New fields are added to the translation table as usage patterns clarify which plotly features are common enough to warrant first-class support. The `onRelayout` escape hatch covers everything else in the meantime. Criteria for promotion: (1) multiple users bind the field via the escape hatch, (2) the field has a stable payload shape across plot types, (3) snap-back semantics are well-defined for it.

---

## 10. Substrate dependence — what PlotlyOutput leans on `IridWidget` for

`PlotlyOutput` is fully expressible on top of the `IridWidget` substrate (see [ARCHITECTURE.md](../ARCHITECTURE.md#widgets)); no new framework features are required. The notes below catalog the substrate guarantees PlotlyOutput's correctness depends on, so that future changes to `IridWidget` know PlotlyOutput is a downstream consumer of these contracts.

- **Force-send-on-no-op echoes every binding on the widget's id after every event.** PlotlyOutput's snap-back path *requires* this — when a `reactiveProxy` rejects a write, the framework must still emit `irid-attr widget:<key>` carrying the unchanged canonical value, so the widget's `update` hook can snap plotly back. Narrowing the echo (e.g., "only echo bindings the event handler conceptually writes to") would silently break PlotlyOutput's rejection semantics.

- **`update(key, value)` arity is stable.** PlotlyOutput's idempotence path compares `value` against plotly's current state at the corresponding path. The widget framework leaves idempotence to the widget author and handles sequence/stale-echo gating upstream of the hook (so no sequence argument reaches it). Stable as long as the hook's signature doesn't change.

- **The init message ships a single merged `props` object** containing both the spec and the named state args. The factory destructures `props.spec` and the named keys from one object. If the substrate ever split init into "constant" and "binding-driven" channels, the factory would need to adapt.

- **`send()` is a silent no-op when no R subscriber exists for an event name.** PlotlyOutput's JS registers listeners for every plotly event it knows about and lets the framework gate which ones round-trip. If the substrate ever required pre-declaring every event a widget can emit (e.g. surfacing a hard error for unknown event names), PlotlyOutput would need to switch to conditionally registering plotly listeners based on which `events` the wrapper passed — feasible but tighter.

- **Multi-write handlers are an accepted pattern.** The relayout fan-out writes through several callables in one function — the framework allows arbitrary hand-rolled handlers in `events =` for exactly this case. Calling it out here so the pattern doesn't get lint-driven away.

- **`is.function()` dispatch on `props` is per-key.** A `reactiveVal` becomes a binding; a constant (including `NULL`) becomes an init-only static prop. PlotlyOutput's named state args rely on both halves: `xaxis_range = NULL` should not produce an observer; `xaxis_range = rv` should. Removing the per-key dispatch (e.g., requiring all `props` to be either all-callable or all-static) would require the wrapper to do that classification itself.

- **`event_defaults()` resolves caller `.event` > wrapper defaults > framework default.** PlotlyOutput's "relayout throttled, click immediate" defaults rely on the wrapper-default tier being preserved when the caller passes a per-event named-list `.event`. The helper implements the three-tier resolution that PlotlyOutput depends on.

- **Targeted `Plotly.relayout()` bypasses `uirevision` preservation.** Strictly a plotly-internal property, not a substrate one — but the snap-back design is wholly load-bearing on it. If plotly ever changes this, no widget-level workaround exists; PlotlyOutput would need to retain the original design's "track last-sent per field" intent somewhere (likely client-side in the widget factory).

None of the items above are gaps in `IridWidget` — they are contracts the substrate already meets that PlotlyOutput depends on continuing to meet.
