# helper-e2e-plt.R — the PlotlyOutput layer for the e2e driver (helper-e2e.R).
# Reads gd.layout / gd.data state and drives plotly's own API (relayout / restyle
# / emit + a real drag-select). `gd` selects which graph div to drive — defaults
# to the sole PlotlyOutput on the page; pass a container selector (e.g. "#plot-b")
# to target one of several.
#
# (testthat auto-sources every helper-*.R before the tests; the generic e2e_*
# helpers it builds on resolve at call time regardless of source order.)

# A CSS selector for the plotly graph div (gd). PlotlyOutput renders the chart
# straight into its widget container, so the container element *is* gd.
PLOTLY_GD <- "[data-irid-widget=plotly]"

# Evaluate a JS body that has `gd` (the graph div) in scope.
e2e_plt_eval <- function(app, body, gd = PLOTLY_GD, await = FALSE) {
  e2e_eval(app, sprintf(
    "(function(){var gd=document.querySelector('%s');%s})()", gd, body
  ), await = await)
}

# Wait for the plot to render N traces (the readiness gate).
e2e_plt_await <- function(app, n_traces, gd = PLOTLY_GD, timeout = 40) {
  # Two readiness gates, because the plot becoming visible does NOT mean the app
  # is ready to drive — and the deps-on-the-page change (#35) made the widget
  # render fast enough to expose both windows on a cold boot:
  #
  #  1. marker `data-irid-plotly-ready`: the factory finished rendering AND
  #     attached its own gd.on('plotly_*') handlers. `Plotly.react` sets
  #     `el.data` before that `.then` runs, so waiting on data alone loses a
  #     gesture fired right after (the onRelayout/onClick flake).
  #  2. irid idle: irid finished wiring the PAGE's DOM listeners (buttons,
  #     inputs). The marker can fire before that, so a click dispatched right
  #     after it can hit an unbound button and be lost (the server->client
  #     push flake). `e2e_wait_idle` keys off irid's own settle tracker.
  e2e_wait_until(app, sprintf(
    "window.Plotly && document.querySelector('%s') && document.querySelector('%s').data && document.querySelector('%s').data.length === %d && document.querySelector('%s').getAttribute('data-irid-plotly-ready') === '1'",
    gd, gd, gd, n_traces, gd
  ), timeout = timeout)
  e2e_wait_idle(app)
  invisible(app)
}

# ---- client -> server gestures (drive plotly's own API / emitter) ----
e2e_plt_relayout <- function(app, obj, gd = PLOTLY_GD) {
  e2e_eval(app, sprintf(
    "(function(){var gd=document.querySelector('%s');return Plotly.relayout(gd,%s).then(function(){return true;});})()",
    gd, jsonlite::toJSON(obj, auto_unbox = TRUE)
  ), await = TRUE)
}
e2e_plt_restyle <- function(app, obj, trace_index, gd = PLOTLY_GD) {
  e2e_eval(app, sprintf(
    "(function(){var gd=document.querySelector('%s');return Plotly.restyle(gd,%s,[%d]).then(function(){return true;});})()",
    gd, jsonlite::toJSON(obj, auto_unbox = TRUE), trace_index
  ), await = TRUE)
}
e2e_plt_emit <- function(app, event, payload = NULL, gd = PLOTLY_GD) {
  pl <- if (is.null(payload)) "{}" else jsonlite::toJSON(payload, auto_unbox = TRUE)
  e2e_eval(app, sprintf(
    "(function(){var gd=document.querySelector('%s');gd.emit(%s,%s);return true;})()",
    gd, to_js_str(event), pl
  ))
}
# A real drag-select over a fraction of the plot interior. Aims at `.nsewdrag`
# (offset in from the edges) so the drag lands on the plot area, not an axis;
# `dragmode` must be a select tool.
e2e_plt_drag_select <- function(app, gd = PLOTLY_GD,
                                fx1 = 0.15, fy1 = 0.15, fx2 = 0.85, fy2 = 0.85) {
  r <- e2e_eval(app, sprintf(
    "(function(){var d=document.querySelector('%s .nsewdrag');var r=d.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height};})()",
    gd
  ))
  e2e_drag(app, r$x + r$w * fx1, r$y + r$h * fy1,
           r$x + r$w * fx2, r$y + r$h * fy2)
}

# ---- gd state readers (what the plot shows) ----
e2e_plt_range <- function(app, axis = "xaxis", gd = PLOTLY_GD) {
  e2e_plt_eval(app, sprintf("var a=gd.layout&&gd.layout['%s'];return a?a.range:null;", axis), gd = gd)
}
e2e_plt_autorange <- function(app, axis = "xaxis", gd = PLOTLY_GD) {
  e2e_plt_eval(app, sprintf("var a=gd.layout&&gd.layout['%s'];return a?!!a.autorange:null;", axis), gd = gd)
}
e2e_plt_dragmode <- function(app, gd = PLOTLY_GD) {
  e2e_plt_eval(app, "return gd.layout?gd.layout.dragmode:null;", gd = gd)
}
e2e_plt_hovermode <- function(app, gd = PLOTLY_GD) {
  e2e_plt_eval(app, "return gd.layout?gd.layout.hovermode:null;", gd = gd)
}
e2e_plt_n_traces <- function(app, gd = PLOTLY_GD) {
  e2e_plt_eval(app, "return gd.data?gd.data.length:0;", gd = gd)
}
# tri-state visibility of the trace with the given name (identity lookup).
e2e_plt_visible <- function(app, name, gd = PLOTLY_GD) {
  e2e_plt_eval(app, sprintf(
    "var t=(gd.data||[]).filter(function(x){return String(x.name)===%s;})[0];return t?(t.visible===undefined?true:t.visible):null;",
    to_js_str(as.character(name))
  ), gd = gd)
}
# total selected points across all traces (the dimming layer).
e2e_plt_n_selected <- function(app, gd = PLOTLY_GD) {
  e2e_plt_eval(app, "return (gd.data||[]).reduce(function(n,t){return n+((t.selectedpoints&&t.selectedpoints.length)||0);},0);", gd = gd)
}
# number of selectedpoints arrays that are actually set (not null/undefined).
e2e_plt_n_selected_traces <- function(app, gd = PLOTLY_GD) {
  e2e_plt_eval(app, "return (gd.data||[]).filter(function(t){return t.selectedpoints!=null;}).length;", gd = gd)
}
# count of outline rectangles (layout.selections + rendered .selectionlayer).
e2e_plt_n_selections <- function(app, gd = PLOTLY_GD) {
  e2e_plt_eval(app, "return (gd.layout&&gd.layout.selections)?gd.layout.selections.length:0;", gd = gd)
}
e2e_plt_outline_paths <- function(app, gd = PLOTLY_GD) {
  e2e_plt_eval(app, sprintf(
    "return document.querySelectorAll('%s .select-outline, %s .selectionlayer path').length;",
    gd, gd
  ), gd = gd)
}
