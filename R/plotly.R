# PlotlyOutput — a thin IridWidget wrapper around plotly.js
#
# The wrapper carries no custom wire-protocol message, no PlotlyOutput-specific
# process_tags extraction, and no custom client mount path — all of that comes
# from the IridWidget substrate (see ARCHITECTURE.md#widgets). The wrapper's
# job is to:
#
#   - serialize the user's plotly spec to a JSON string prop (`to_plotly_spec`),
#   - route the named state args into two-way props (with sensible per-binding
#     timing) validated against the translation table,
#   - pass the discrete callbacks + the `onRelayout` escape hatch as events,
#   - ship plotly's html dependencies (+ the irid-plotly factory JS).
#
# The JS side (`inst/widgets/plotly/plotly-irid.js`) owns the
# `Plotly.react()` / `Plotly.relayout()` / `Plotly.restyle()` / `Plotly.purge()`
# glue and its own mirror of the translation table.

# --- Translation table (R side: name validation only) -----------------------

# The launch-scope set of named state args PlotlyOutput knows how to bind.
# Subplot axes are pattern-matched (`xaxis2_range`, `yaxis3_range`, ...). The JS
# side keeps the authoritative mirror that maps each name to a spec path and a
# source event; the R side only needs to reject unknown names at construction.
plotly_state_arg_ok <- function(name) {
  name %in% c("dragmode", "hovermode", "selected_points", "trace_visibility") ||
    grepl("^[xy]axis[0-9]*_range$", name)
}

validate_plotly_state_args <- function(state) {
  if (length(state) == 0L) return(invisible())
  nms <- names(state)
  if (is.null(nms) || any(!nzchar(nms))) {
    cli::cli_abort(c(
      "Every named state argument to {.fn PlotlyOutput} must be named.",
      "i" = "Pass e.g. {.code xaxis_range = xr}, not a bare positional value."
    ))
  }
  bad <- nms[!vapply(nms, plotly_state_arg_ok, logical(1L))]
  if (length(bad) > 0L) {
    cli::cli_abort(c(
      "Unknown named state argument{?s}: {.field {bad}}.",
      "i" = "Known fields: {.field xaxis_range}, {.field yaxis_range}, \\
             {.field xaxis<n>_range}, {.field yaxis<n>_range}, \\
             {.field dragmode}, {.field hovermode}, \\
             {.field selected_points}, {.field trace_visibility}.",
      "i" = "Anything outside the table can be handled via {.arg onRelayout}."
    ))
  }
  invisible()
}

# Shiny decodes client messages with `simplifyVector = FALSE`, so a value the
# JS factory pushes via `setProp` arrives in R as a nested list — a range
# `[40, 200]` becomes `list(40, 200)`, on which `v[2] - v[1]` (a natural thing
# for a user proxy to write) errors. The wrapper coerces each field back to its
# documented R shape at the boundary so user code sees a clean value: ranges as
# numeric vectors, `trace_visibility` as a character vector, `selected_points`
# as integer columns. Scalars (`dragmode`, `hovermode`) need no coercion.
coerce_plotly_value <- function(name, v) {
  # A `setProp(key, null)` (deselect, autorange-reset) arrives here as a scalar
  # `NA`, because mount's event payload maps a JS `null` field to `NA`. Every
  # real value is a length>=2 vector or a structured list, so a scalar `NA`
  # unambiguously means "clear" — normalize it back to `NULL`.
  if (is.null(v) || (length(v) == 1L && is.atomic(v) && is.na(v))) return(NULL)
  if (grepl("_range$", name)) return(as.numeric(unlist(v)))
  if (identical(name, "trace_visibility")) return(as.character(unlist(v)))
  if (identical(name, "selected_points")) {
    if (is.list(v) && !is.null(v$curve)) {
      return(list(
        curve = as.integer(unlist(v$curve)),
        point = as.integer(unlist(v$point))
      ))
    }
    return(v)
  }
  v
}

# Wrap a user-supplied callable so client write-backs are coerced before they
# reach it. Reads pass straight through (so the readout / binding / snap-back
# all see the user's own canonical value); only the write path coerces. A
# rejecting `reactiveProxy` still rejects — coercion happens *before* the
# user's `set` runs. Constants (incl. NULL) are returned untouched.
coerce_state_prop <- function(name, callable) {
  # force() is load-bearing: the get/set closures don't touch `name`/`callable`
  # until a write arrives, long after the caller's construction loop has moved
  # on. Without forcing, every proxy would capture the loop's final values.
  force(name)
  force(callable)
  if (!is_function(callable)) return(callable)
  reactiveProxy(
    get = callable,
    set = function(v) callable(coerce_plotly_value(name, v))
  )
}

# Wrap each callable state arg in its boundary coercion, then apply default
# timing: high-frequency relayout-sourced props (ranges, dragmode, hovermode)
# gate on server-idle via a throttle; selection / visibility stay immediate. A
# caller overrides any single arg by passing its own `wire()` — the caller's
# timing wins. Constants (incl. NULL) ride init-only and pass through.
prepare_state_props <- function(state) {
  stream <- function(nm) grepl("_range$", nm) || nm %in% c("dragmode", "hovermode")
  out <- list()
  for (nm in names(state)) {
    v <- state[[nm]]
    if (!is_function(v) && !inherits(v, "irid_wire")) {
      out[[nm]] <- v          # constant
      next
    }
    base <- if (inherits(v, "irid_wire")) v else wire(subject = v)
    w <- wire(
      subject  = coerce_state_prop(nm, base$subject),
      timing   = base$timing,
      coalesce = base$coalesce,
      dom_opts = base$dom_opts
    )
    if (is.null(w$timing) && stream(nm)) {
      w <- merge(wire(timing = wire_throttle(100)), w)
    }
    out[[nm]] <- w
  }
  out
}

# --- Spec serialization -----------------------------------------------------

#' Serialize a plotly object to the JSON string PlotlyOutput ships
#'
#' Pre-encodes with plotly's own `to_JSON` (digits/encoding identical to what
#' the `{plotly}` htmlwidget itself ships) and returns a plain JSON *string*.
#' The substrate's encoder then ships the string verbatim; the JS side
#' `JSON.parse`s it. Works for both `plot_ly()` and `ggplotly()` — both build
#' to the same structure.
#'
#' @param p A plotly or ggplotly object.
#' @return A length-1 character vector of JSON.
#' @keywords internal
to_plotly_spec <- function(p) {
  b <- plotly::plotly_build(p)
  # plotly:::to_JSON is unexported; getFromNamespace avoids the R CMD check
  # `:::` note while still reproducing plotly's exact encoding.
  to_JSON <- utils::getFromNamespace("to_JSON", "plotly")
  unclass(to_JSON(list(
    data   = b$x$data,
    layout = b$x$layout,
    config = b$x$config
  )))
}

# --- Dependencies -----------------------------------------------------------

# Memoize the plotly.js html dependencies (typedarray, jquery, crosstalk,
# plotly-htmlwidgets-css, plotly-main). They're grabbed once from a throwaway
# build — all five carry `package` + `src$file`, exactly what
# register_widget_dep resolves.
.plotly_cache <- new.env(parent = emptyenv())

plotly_js_dependencies <- function() {
  if (is.null(.plotly_cache$deps)) {
    b <- suppressMessages(suppressWarnings(
      plotly::plotly_build(plotly::plot_ly(x = 1, y = 1, type = "scatter"))
    ))
    .plotly_cache$deps <- b$dependencies
  }
  .plotly_cache$deps
}

# The irid-plotly factory registration (`irid.defineWidget("plotly", ...)`).
plotly_widget_dependency <- function() {
  htmltools::htmlDependency(
    name    = "irid-plotly",
    version = utils::packageVersion("irid"),
    src     = system.file("widgets", "plotly", package = "irid"),
    script  = "plotly-irid.js"
  )
}

#' Plotly html dependencies for PlotlyOutput
#'
#' The plotly.js bundle (sourced from the suggested `{plotly}` package) plus the
#' irid-plotly factory script. Passed to `IridWidget(deps = ...)`.
#'
#' @return A list of `html_dependency` objects.
#' @keywords internal
plotly_dependency <- function() {
  c(plotly_js_dependencies(), list(plotly_widget_dependency()))
}

# --- Constructor ------------------------------------------------------------

#' Reactive plotly output
#'
#' A first-class output primitive for interactive plotly charts, on par with
#' [PlotOutput] and [TableOutput]. Unlike the `{plotly}` htmlwidget — which
#' destroys and recreates the chart on every reactive update — `PlotlyOutput`
#' uses `Plotly.react()` for incremental updates, so a data change preserves
#' the user's zoom, pan, and selection (via plotly's `uirevision`).
#'
#' `PlotlyOutput` is a thin wrapper over [IridWidget]. User-controllable UI
#' state (axis ranges, drag mode, selection, trace visibility) is exposed as
#' **named reactive arguments**, each a two-way prop: bind a `reactiveVal`,
#' store leaf, or [reactiveProxy] and the user's interaction writes back to it.
#' A `reactiveProxy` that rejects a write snaps the plot back. Discrete events
#' (clicks, hovers, legend interactions) are plain `on*` callbacks.
#'
#' @param spec A zero-argument function returning a plotly object (from
#'   `plotly::plot_ly()` or `plotly::ggplotly()`). Re-evaluated reactively;
#'   `Plotly.react()` diffs the result client-side.
#' @param ... Named state arguments, each a callable (`reactiveVal`, store
#'   leaf, `reactiveProxy`) or constant. Recognized: `xaxis_range`,
#'   `yaxis_range`, `xaxis<n>_range`, `yaxis<n>_range`, `dragmode`,
#'   `hovermode`, `selected_points`, `trace_visibility`. `NULL` means "don't
#'   override the spec". Unknown names error — use `onRelayout` for fields
#'   outside the table.
#' @param onClick,onHover,onUnhover,onDoubleclick Discrete pointer callbacks.
#'   Each receives the (slimmed) plotly event payload.
#' @param onDeselect,onSelecting,onBrushing Selection-lifecycle notifications.
#'   `onDeselect` is a side-effect notification only — when `selected_points`
#'   is bound, the clear already flows through its prop channel.
#' @param onLegendClick,onLegendDoubleclick,onClickAnnotation,onSunburstClick
#'   Discrete interaction callbacks.
#' @param onRelayout Escape hatch — receives the raw `plotly_relayout` payload
#'   (flat dot-notation keys) for fields outside the translation table.
#' @param container Optional `shiny.tag` for the wrapper element.
#'
#' @return An `irid_widget` construct.
#' @export
PlotlyOutput <- function(
  spec,
  ...,
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
  container           = NULL
) {
  if (!requireNamespace("plotly", quietly = TRUE)) {
    cli::cli_abort(c(
      "{.fn PlotlyOutput} requires the {.pkg plotly} package.",
      "i" = 'Install it with {.run install.packages("plotly")}.'
    ))
  }
  check_function(spec)

  state <- list(...)
  validate_plotly_state_args(state)
  # The JS factory builds its translation-table entries from this list, not
  # from which props happen to be non-NULL at init: a NULL-initialized state
  # arg (`xaxis_range = reactiveVal(NULL)`) is dropped from the init `props`
  # object (R list semantics), so the bound keys must be shipped explicitly.
  state_keys <- as.list(names(state))

  # The spec is always a function; wrap it as a callable prop that serializes
  # to the plotly JSON string each time its deps change. Two-way-capable like
  # any callable prop, but the client never writes the spec back.
  spec_prop <- function() to_plotly_spec(spec())

  # Throttled relayout/hover events; immediate clicks/selection. NULL handlers
  # resolve to subject-less wires and drop out in normalize_widget_events.
  throttled <- function(h) merge(wire(timing = wire_throttle(100)), h)

  IridWidget(
    name  = "plotly",
    props = c(
      list(spec = spec_prop, `__irid_state_keys` = state_keys),
      prepare_state_props(state)
    ),
    events = list(
      relayout             = throttled(onRelayout),
      click                = onClick,
      hover                = throttled(onHover),
      unhover              = onUnhover,
      doubleclick          = onDoubleclick,
      deselect             = onDeselect,
      selecting            = throttled(onSelecting),
      brushing             = throttled(onBrushing),
      `legend-click`       = onLegendClick,
      `legend-doubleclick` = onLegendDoubleclick,
      `click-annotation`   = onClickAnnotation,
      `sunburst-click`     = onSunburstClick
    ),
    deps      = plotly_dependency(),
    container = container
  )
}
