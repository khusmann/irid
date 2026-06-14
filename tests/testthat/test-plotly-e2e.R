# End-to-end tests for PlotlyOutput — the round-trip behavior that pure-R unit
# tests cannot see. See dev/plotly-e2e-testing-design.md for the coverage matrix
# (each test names its numbered rows) and helper-e2e.R for the driver.
#
# Heavyweight + browser-dependent: gated behind the driver's skip_unless_e2e()
# (CRAN, missing chromote/callr/Chrome, or IRID_E2E != "1"). Run locally with:
#   IRID_E2E=1 Rscript -e 'devtools::test(filter = "plotly-e2e")'

# Kitchen-sink fixture: mtcars by cylinder -> 3 traces (4/6/8). hp >= 120 drops
# the whole 4-cyl group (max 4-cyl hp is 113), recomposing 3 -> 2 traces.
KS_TRACES <- 3L
KS_FILTER <- 120

expect_approx_range <- function(actual, expected, tol = 1) {
  testthat::expect_false(is.null(actual))
  testthat::expect_length(actual, 2L)
  testthat::expect_lt(abs(as.numeric(actual[[1]]) - expected[1]), tol)
  testthat::expect_lt(abs(as.numeric(actual[[2]]) - expected[2]), tol)
}

# --- Row 1, 22: render + layout ---------------------------------------------

test_that("spec renders, deps load, factory never touches undefined Plotly (1, 22)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)

  expect_true(app_eval(app, "!!window.Plotly"))
  expect_equal(plt_gd_eval(app, "return gd.data.length"), KS_TRACES)
  expect_equal(app_exceptions(app), character())

  # Row 22 (#27 regression): the control panel renders at non-zero width.
  w <- app_eval(app, "document.querySelector('#control-panel').getBoundingClientRect().width")
  expect_gt(w, 0)
  app_expect_no_error(app)
})

# --- Rows 3, 4, 6: server -> client state props -----------------------------

test_that("range / visibility / reset push server -> client (3, 4, 6)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)

  # Row 3: "Zoom to economy cars" writes both ranges. Poll the lower bound (20)
  # — the autorange upper already sits near 35, so only the lower is unambiguous.
  app_click(app, "#btn-economy")
  xr <- poll_until(\() plt_range(app, "xaxis"), \(v) abs(as.numeric(v[[1]]) - 20) < 2)
  expect_approx_range(xr, c(20, 35), tol = 2)
  expect_approx_range(plt_range(app, "yaxis"), c(50, 130), tol = 2)
  expect_match(app_readout(app, "#ro-viewport"), "mpg: \\[20")

  # Row 4: "Hide 8-cyl" sets c("8" = "legendonly") — found by name, not index.
  app_click(app, "#btn-hide8")
  v <- poll_until(\() plt_visible(app, "8"), \(v) identical(v, "legendonly"))
  expect_equal(v, "legendonly")
  expect_match(app_readout(app, "#ro-visibility"), "8=legendonly")

  # Row 6: "Reset view" -> autorange + visibility back to default.
  app_click(app, "#btn-reset")
  ar <- poll_until(\() plt_autorange(app, "xaxis"), isTRUE)
  expect_true(isTRUE(ar))
  expect_false(identical(plt_visible(app, "8"), "legendonly"))
  app_expect_no_error(app)
})

# --- Row 5: dragmode two-way ------------------------------------------------

test_that("dragmode is two-way: <select> drives gd, modebar pick writes back (5)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)

  # server <- client: change the <select>.
  app_set_input(app, "#dragmode", "pan", event = "change")
  dm <- poll_until(\() plt_dragmode(app), \(v) identical(v, "pan"))
  expect_equal(dm, "pan")

  # client <- server: a modebar-style relayout writes the select back.
  plt_relayout(app, list(dragmode = "lasso"))
  poll_until(\() app_readout(app, "#ro-dragmode"), \(t) grepl("lasso", t))
  expect_match(app_readout(app, "#ro-dragmode"), "lasso")
  expect_equal(
    poll_until(\() app_eval(app, "document.querySelector('#dragmode').value"),
               \(v) identical(v, "lasso")),
    "lasso"
  )
  app_expect_no_error(app)
})

# --- hovermode two-way + onHover / onLegendClick sendEvent channels ---------
# Not a numbered §3 row, but the remaining two-way prop and notification channels
# (hover, legend) share enough distinct plumbing to be worth one smoke case.

test_that("hovermode two-way; onHover and onLegendClick notifications fire", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)

  # server -> client: a button sets hovermode; the plot follows.
  app_click(app, "#btn-hover-x")
  expect_equal(poll_until(\() plt_hovermode(app), \(v) identical(v, "x")), "x")
  # client -> server: a relayout writes hovermode back.
  plt_relayout(app, list(hovermode = "closest"))
  poll_until(\() app_readout(app, "#ro-hovermode"), \(t) grepl("closest", t))
  expect_match(app_readout(app, "#ro-hovermode"), "closest")

  # onHover -> slimPoints -> readout.
  plt_emit(app, "plotly_hover", list(points = list(list(
    curveNumber = 0, pointNumber = 0, x = 21, y = 110, customdata = "Mazda RX4"
  ))))
  poll_until(\() app_readout(app, "#ro-hover"), \(t) grepl("Mazda RX4", t))
  expect_match(app_readout(app, "#ro-hover"), "Mazda RX4")

  # onLegendClick -> readout shows the curve number.
  plt_emit(app, "plotly_legendclick", list(curveNumber = 1))
  poll_until(\() app_readout(app, "#ro-legend"), \(t) grepl("legend: 1", t))
  expect_match(app_readout(app, "#ro-legend"), "legend: 1")
  app_expect_no_error(app)
})

# --- Row 2: uirevision preserves the view across a data update --------------

test_that("uirevision preserves the zoomed view across a data update (2)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)

  plt_relayout(app, list(`xaxis.range[0]` = 18, `xaxis.range[1]` = 26))
  poll_until(\() plt_range(app, "xaxis"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 26) < 2)

  # Move the data slider — the spec re-renders; the range must survive.
  app_set_input(app, "#hp-slider", 60)
  app_wait_idle(app)
  expect_approx_range(plt_range(app, "xaxis"), c(18, 26), tol = 2)
  app_expect_no_error(app)
})

# --- Rows 7, 8, 9, 10, 11: onRelayout + accepted zoom + snap-back -----------

test_that("onRelayout escape hatch, accepted zoom, snap-back, gate (7-11)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)

  # Row 7: onRelayout lists the gesture's raw keys.
  plt_relayout(app, list(`xaxis.range[0]` = 15, `xaxis.range[1]` = 30))
  poll_until(\() app_readout(app, "#ro-relayout"), \(t) grepl("xaxis\\.range", t))
  expect_match(app_readout(app, "#ro-relayout"), "xaxis\\.range")

  # Row 8: an accepted (wide) hp zoom reaches the server and the plot keeps it.
  plt_relayout(app, list(`yaxis.range[0]` = 50, `yaxis.range[1]` = 160))
  poll_until(\() app_readout(app, "#ro-viewport"), \(t) grepl("hp: \\[50", t))
  expect_match(app_readout(app, "#ro-viewport"), "hp: \\[50")
  expect_approx_range(plt_range(app, "yaxis"), c(50, 160), tol = 2)

  # Rows 9 + 11: a too-narrow zoom is rejected — server unchanged, plot snaps
  # back to the prior accepted [50, 160].
  plt_relayout(app, list(`yaxis.range[0]` = 100, `yaxis.range[1]` = 118))
  yr <- poll_until(\() plt_range(app, "yaxis"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 160) < 2)
  expect_approx_range(yr, c(50, 160), tol = 2)
  expect_match(app_readout(app, "#ro-viewport"), "hp: \\[50")  # server held the prior value

  # Row 10: after a reset (null canonical), a rejected narrow zoom snaps back to
  # autorange, not the rejected range.
  app_click(app, "#btn-reset")
  poll_until(\() plt_autorange(app, "yaxis"), isTRUE)
  plt_relayout(app, list(`yaxis.range[0]` = 100, `yaxis.range[1]` = 118))
  ar <- poll_until(\() plt_autorange(app, "yaxis"), isTRUE)
  expect_true(isTRUE(ar))
  app_expect_no_error(app)
})

# --- Rows 12, 13, 14, 15: discrete + selection via emit ---------------------

test_that("onClick, selected_ids, deselect, autorange-reset null via emit (12-15)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)

  # Row 12: onClick -> slimPoints -> readout shows the point's fields.
  plt_emit(app, "plotly_click", list(points = list(list(
    curveNumber = 0, pointNumber = 0, x = 21, y = 110,
    customdata = "Mazda RX4", text = "Mazda RX4"
  ))))
  poll_until(\() app_readout(app, "#ro-click"), \(t) grepl("clicked:", t))
  expect_match(app_readout(app, "#ro-click"), "Mazda RX4")

  # Row 13: selected_ids — emit a selection at known indices; the readout shows
  # the *ids* (names) and per-trace selectedpoints resolve from them.
  ids <- plt_gd_eval(app, "return [gd.data[0].ids[0], gd.data[0].ids[1]];")
  plt_emit(app, "plotly_selected", list(points = list(
    list(curveNumber = 0, pointNumber = 0),
    list(curveNumber = 0, pointNumber = 1)
  )))
  sel <- poll_until(\() app_readout(app, "#ro-selection"), \(t) grepl("^2:", t))
  expect_match(sel, "^2:")
  expect_match(sel, ids[[1]], fixed = TRUE)
  expect_equal(poll_until(\() plt_n_selected(app), \(n) n == 2), 2)

  # Row 14: deselect clears (full opacity, selectedpoints unset — not []).
  plt_emit(app, "plotly_deselect")
  poll_until(\() app_readout(app, "#ro-selection"), \(t) identical(t, "none"))
  expect_equal(app_readout(app, "#ro-selection"), "none")
  expect_equal(poll_until(\() plt_n_selected_traces(app), \(n) n == 0), 0)

  # Row 15: an autorange-reset relayout sends null through the prop with no error.
  plt_emit(app, "plotly_relayout", list(`yaxis.autorange` = TRUE))
  poll_until(\() app_readout(app, "#ro-viewport"), \(t) grepl("hp: auto", t))
  expect_match(app_readout(app, "#ro-viewport"), "hp: auto")
  app_expect_no_error(app)
})

# --- Rows 16, 17: a REAL drag populates both layers; clear tears both down ---

test_that("real drag-select populates both layers; clear tears both down (16, 17)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)
  settle(1)

  # Row 16: a real drag populates layout.selections (outline) AND selectedpoints.
  plt_drag_select(app)
  n <- poll_until(\() plt_n_selections(app), \(n) n >= 1)
  expect_gte(n, 1)
  expect_no_match(app_readout(app, "#ro-selection"), "none")
  expect_gt(plt_n_selected(app), 0)
  expect_gt(plt_outline_paths(app), 0)

  # Row 17: "Clear selection" tears down BOTH layers (readout none, no outline,
  # every selectedpoints unset).
  app_click(app, "#btn-clear")
  poll_until(\() app_readout(app, "#ro-selection"), \(t) identical(t, "none"))
  expect_equal(app_readout(app, "#ro-selection"), "none")
  expect_equal(poll_until(\() plt_n_selections(app), \(n) n == 0), 0)
  expect_equal(poll_until(\() plt_n_selected_traces(app), \(n) n == 0), 0)
  app_expect_no_error(app)
})

# --- Rows 23, 24: identity selection survives filtering + echo guard ---------

test_that("identity selection survives a trace-recomposing filter (23, 24)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)
  settle(1)

  plt_drag_select(app)
  sel0 <- poll_until(\() app_readout(app, "#ro-selection"), \(t) !identical(t, "none"))
  expect_no_match(sel0, "none")
  n_sel0 <- plt_n_selected(app)

  # Filter so the 4-cyl group drops entirely: 3 -> 2 traces (the renumber).
  app_set_input(app, "#hp-slider", KS_FILTER)
  expect_equal(poll_until(\() plt_n_traces(app), \(n) n == 2), 2)
  # Row 24: the data-change deselect echo is swallowed — selection NOT wiped.
  expect_equal(app_readout(app, "#ro-selection"), sel0)
  expect_no_match(app_readout(app, "#ro-selection"), "none")

  # Unfilter: 2 -> 3 traces; names unchanged, selectedpoints re-resolve in full.
  app_set_input(app, "#hp-slider", 0)
  expect_equal(poll_until(\() plt_n_traces(app), \(n) n == KS_TRACES), KS_TRACES)
  expect_equal(app_readout(app, "#ro-selection"), sel0)
  expect_equal(poll_until(\() plt_n_selected(app), \(n) n == n_sel0), n_sel0)
  app_expect_no_error(app)
})

# --- Row 25: programmatic set over an active drag ---------------------------

test_that("programmatic set clears the stale outline; a re-drag keeps its own (25)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)
  settle(1)

  plt_drag_select(app)
  poll_until(\() plt_n_selections(app), \(n) n >= 1)

  # A different (programmatic) selection applies and clears the stale outline.
  app_click(app, "#btn-sports")
  sel <- poll_until(\() app_readout(app, "#ro-selection"), \(t) grepl("Maserati Bora", t))
  expect_match(sel, "Maserati Bora")
  expect_equal(poll_until(\() plt_n_selections(app), \(n) n == 0), 0)
  expect_equal(poll_until(\() plt_n_selected(app), \(n) n == 2), 2)

  # A re-drag's OWN echo must NOT wipe its fresh marquee (matchesCurrent skip).
  plt_drag_select(app)
  poll_until(\() plt_n_selections(app), \(n) n >= 1)
  app_wait_idle(app)  # let the echo round-trip; the marquee must survive it
  expect_gte(plt_n_selections(app), 1)
  app_expect_no_error(app)
})

# --- Row 26: name-keyed visibility survives recomposition + round-trips ------

test_that("name-keyed visibility survives recomposition; legend toggle writes back (26)", {
  app <- irid_app("kitchen-sink.R")
  plt_await(app, KS_TRACES)

  app_click(app, "#btn-hide8")
  poll_until(\() plt_visible(app, "8"), \(v) identical(v, "legendonly"))

  # Filter drops the 4-cyl group (3 -> 2); "8" stays legendonly, keyed by name.
  app_set_input(app, "#hp-slider", KS_FILTER)
  expect_equal(poll_until(\() plt_n_traces(app), \(n) n == 2), 2)
  expect_equal(plt_visible(app, "8"), "legendonly")

  # Unfilter (2 -> 3); still legendonly.
  app_set_input(app, "#hp-slider", 0)
  expect_equal(poll_until(\() plt_n_traces(app), \(n) n == KS_TRACES), KS_TRACES)
  expect_equal(plt_visible(app, "8"), "legendonly")

  # A legend toggle (restyle) writes the full {name -> state} map back.
  idx6 <- plt_gd_eval(app, "for(var i=0;i<gd.data.length;i++){if(String(gd.data[i].name)==='6')return i;}return -1;")
  plt_restyle(app, list(visible = "legendonly"), idx6)
  vis <- poll_until(\() app_readout(app, "#ro-visibility"), \(t) grepl("6=legendonly", t))
  expect_match(vis, "6=legendonly")
  expect_match(vis, "8=legendonly")
  app_expect_no_error(app)
})

# --- Row 18: subplot axes route independently -------------------------------

test_that("subplot axes route independently (18)", {
  app <- irid_app("subplot.R")
  plt_await(app, 2L)

  app_click(app, "#btn-x1")
  poll_until(\() plt_range(app, "xaxis"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 20) < 2)
  expect_approx_range(plt_range(app, "xaxis"), c(10, 20), tol = 2)
  # xaxis2 untouched (autorange still on).
  expect_true(isTRUE(plt_autorange(app, "xaxis2")) || is.null(plt_range(app, "xaxis2")))

  app_click(app, "#btn-x2")
  poll_until(\() plt_range(app, "xaxis2"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 40) < 2)
  expect_approx_range(plt_range(app, "xaxis2"), c(30, 40), tol = 2)
  expect_approx_range(plt_range(app, "xaxis"), c(10, 20), tol = 2)  # x1 still set
  app_expect_no_error(app)
})

# --- Row 19: ggplotly parity ------------------------------------------------

test_that("ggplotly renders and the same range bindings work (19)", {
  app <- irid_app("ggplotly.R")
  plt_await(app, 1L)

  app_click(app, "#btn-zoom")
  xr <- poll_until(\() plt_range(app, "xaxis"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 25) < 3)
  expect_approx_range(xr, c(15, 25), tol = 3)
  expect_approx_range(plt_range(app, "yaxis"), c(80, 200), tol = 5)
  app_expect_no_error(app)
})

# --- Row 20: per-flush coalescing — one redraw ------------------------------

test_that("a same-flush spec + range write redraws once (20)", {
  app <- irid_app("gated.R")
  plt_await(app, 1L)
  settle(1)

  # Count redraws via plotly_afterplot from this point forward.
  plt_gd_eval(app, "window.__redraws=0;gd.on('plotly_afterplot',function(){window.__redraws++;});return true;")
  app_click(app, "#btn-bump")
  # spec change -> 30 points; wait for the react to land, then assert one redraw.
  poll_until(\() plt_gd_eval(app, "return gd.data[0].x.length;"), \(n) n == 30)
  app_wait_idle(app)
  expect_equal(app_eval(app, "window.__redraws"), 1)
  app_expect_no_error(app)
})

# --- Row 21: destroy on When flip -------------------------------------------

test_that("flipping the gate destroys the widget (Plotly.purge + removal) (21)", {
  app <- irid_app("gated.R")
  plt_await(app, 1L)

  # Spy on Plotly.purge so we can confirm destroy() ran.
  app_eval(app, "window.__purged=false;var _p=Plotly.purge;Plotly.purge=function(){window.__purged=true;return _p.apply(this,arguments);};true")
  app_click(app, "#btn-toggle")
  app_wait_until(app, sprintf("document.querySelector('%s')===null", PLOTLY_GD), timeout = 15)
  expect_null(plt_gd_eval(app, "return gd;"))
  expect_true(app_eval(app, "window.__purged===true"))
  app_expect_no_error(app)
})
