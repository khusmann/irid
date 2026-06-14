# End-to-end tests for PlotlyOutput — the round-trip behavior that pure-R unit
# tests cannot see. See dev/plotly-e2e-testing-design.md for the coverage matrix
# (each test names its numbered rows) and helper-e2e.R for the harness.
#
# Heavyweight + browser-dependent: gated behind skip_unless_e2e() (CRAN, missing
# chromote/callr/Chrome, or IRID_E2E != "1"). Run locally with:
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
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)

  expect_true(eval_js(h$b, "!!window.Plotly"))
  expect_equal(gd_eval(h$b, "return gd.data.length"), KS_TRACES)
  expect_equal(h$caps$exceptions, character())

  # Row 22 (#27 regression): the control panel renders at non-zero width.
  w <- eval_js(h$b,
    "document.querySelector('#control-panel').getBoundingClientRect().width")
  expect_gt(w, 0)
  expect_no_app_error(h)
})

# --- Rows 3, 4, 6: server -> client state props -----------------------------

test_that("range / visibility / reset push server -> client (3, 4, 6)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)

  # Row 3: "Zoom to economy cars" writes both ranges. Poll the lower bound (20)
  # — the autorange upper already sits near 35, so only the lower is unambiguous.
  click_sel(h$b, "#btn-economy")
  xr <- poll_until(\() gd_range(h$b, "xaxis"), \(v) abs(as.numeric(v[[1]]) - 20) < 2)
  expect_approx_range(xr, c(20, 35), tol = 2)
  expect_approx_range(gd_range(h$b, "yaxis"), c(50, 130), tol = 2)
  expect_match(read_text(h$b, "#ro-viewport"), "mpg: \\[20")

  # Row 4: "Hide 8-cyl" sets c("8" = "legendonly") — found by name, not index.
  click_sel(h$b, "#btn-hide8")
  v <- poll_until(\() gd_visible_by_name(h$b, "8"), \(v) identical(v, "legendonly"))
  expect_equal(v, "legendonly")
  expect_match(read_text(h$b, "#ro-visibility"), "8=legendonly")

  # Row 6: "Reset view" -> autorange + visibility back to default.
  click_sel(h$b, "#btn-reset")
  ar <- poll_until(\() gd_autorange(h$b, "xaxis"), isTRUE)
  expect_true(isTRUE(ar))
  expect_false(identical(gd_visible_by_name(h$b, "8"), "legendonly"))
  expect_no_app_error(h)
})

# --- Row 5: dragmode two-way ------------------------------------------------

test_that("dragmode is two-way: <select> drives gd, modebar pick writes back (5)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)

  # server <- client: change the <select>.
  set_input(h$b, "#dragmode", "pan", event = "change")
  dm <- poll_until(\() gd_dragmode(h$b), \(v) identical(v, "pan"))
  expect_equal(dm, "pan")

  # client <- server: a modebar-style relayout writes the select back.
  gd_relayout(h$b, list(dragmode = "lasso"))
  settle(2)
  expect_match(read_text(h$b, "#ro-dragmode"), "lasso")
  expect_equal(eval_js(h$b, "document.querySelector('#dragmode').value"), "lasso")
  expect_no_app_error(h)
})

# --- Row 2: uirevision preserves the view across a data update --------------

test_that("uirevision preserves the zoomed view across a data update (2)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)

  gd_relayout(h$b, list(`xaxis.range[0]` = 18, `xaxis.range[1]` = 26))
  poll_until(\() gd_range(h$b, "xaxis"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 26) < 2)

  # Move the data slider — the spec re-renders; the range must survive.
  set_input(h$b, "#hp-slider", 60)
  settle(2)
  expect_approx_range(gd_range(h$b, "xaxis"), c(18, 26), tol = 2)
  expect_no_app_error(h)
})

# --- Rows 7, 8, 9, 10, 11: onRelayout + accepted zoom + snap-back -----------

test_that("onRelayout escape hatch, accepted zoom, snap-back, gate (7-11)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)

  # Row 7: onRelayout lists the gesture's raw keys.
  gd_relayout(h$b, list(`xaxis.range[0]` = 15, `xaxis.range[1]` = 30))
  settle(2)
  expect_match(read_text(h$b, "#ro-relayout"), "xaxis\\.range")

  # Row 8: an accepted (wide) hp zoom reaches the server and the plot keeps it.
  gd_relayout(h$b, list(`yaxis.range[0]` = 50, `yaxis.range[1]` = 160))
  poll_until(\() read_text(h$b, "#ro-viewport"), \(t) grepl("hp: \\[50", t))
  expect_match(read_text(h$b, "#ro-viewport"), "hp: \\[50")
  expect_approx_range(gd_range(h$b, "yaxis"), c(50, 160), tol = 2)

  # Rows 9 + 11: a too-narrow zoom is rejected — server unchanged, plot snaps
  # back to the prior accepted [50, 160].
  gd_relayout(h$b, list(`yaxis.range[0]` = 100, `yaxis.range[1]` = 118))
  yr <- poll_until(\() gd_range(h$b, "yaxis"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 160) < 2)
  expect_approx_range(yr, c(50, 160), tol = 2)
  expect_match(read_text(h$b, "#ro-viewport"), "hp: \\[50")  # server held the prior value

  # Row 10: after a reset (null canonical), a rejected narrow zoom snaps back to
  # autorange, not the rejected range.
  click_sel(h$b, "#btn-reset")
  poll_until(\() gd_autorange(h$b, "yaxis"), isTRUE)
  gd_relayout(h$b, list(`yaxis.range[0]` = 100, `yaxis.range[1]` = 118))
  ar <- poll_until(\() gd_autorange(h$b, "yaxis"), isTRUE)
  expect_true(isTRUE(ar))
  expect_no_app_error(h)
})

# --- Rows 12, 13, 14, 15: discrete + selection via emit ---------------------

test_that("onClick, selected_ids, deselect, autorange-reset null via emit (12-15)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)

  # Row 12: onClick -> slimPoints -> readout shows the point's fields.
  gd_emit(h$b, "plotly_click", list(points = list(list(
    curveNumber = 0, pointNumber = 0, x = 21, y = 110,
    customdata = "Mazda RX4", text = "Mazda RX4"
  ))))
  poll_until(\() read_text(h$b, "#ro-click"), \(t) grepl("clicked:", t))
  expect_match(read_text(h$b, "#ro-click"), "Mazda RX4")

  # Row 13: selected_ids — emit a selection at known indices; the readout shows
  # the *ids* (names) and per-trace selectedpoints resolve from them.
  ids <- gd_eval(h$b, "return [gd.data[0].ids[0], gd.data[0].ids[1]];")
  gd_emit(h$b, "plotly_selected", list(points = list(
    list(curveNumber = 0, pointNumber = 0),
    list(curveNumber = 0, pointNumber = 1)
  )))
  sel <- poll_until(\() read_text(h$b, "#ro-selection"), \(t) grepl("^2:", t))
  expect_match(sel, "^2:")
  expect_match(sel, ids[[1]], fixed = TRUE)
  expect_equal(poll_until(\() gd_nselected(h$b), \(n) n == 2), 2)

  # Row 14: deselect clears (full opacity, selectedpoints unset — not []).
  gd_emit(h$b, "plotly_deselect")
  poll_until(\() read_text(h$b, "#ro-selection"), \(t) identical(t, "none"))
  expect_equal(read_text(h$b, "#ro-selection"), "none")
  expect_equal(poll_until(\() gd_nselected_traces(h$b), \(n) n == 0), 0)

  # Row 15: an autorange-reset relayout sends null through the prop with no error.
  gd_emit(h$b, "plotly_relayout", list(`yaxis.autorange` = TRUE))
  poll_until(\() read_text(h$b, "#ro-viewport"), \(t) grepl("hp: auto", t))
  expect_match(read_text(h$b, "#ro-viewport"), "hp: auto")
  expect_no_app_error(h)
})

# --- Rows 16, 17: a REAL drag populates both layers; clear tears both down ---

test_that("real drag-select populates both layers; clear tears both down (16, 17)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)
  settle(1)

  # Row 16: a real drag populates layout.selections (outline) AND selectedpoints.
  drag_select(h$b)
  n <- poll_until(\() gd_nselections(h$b), \(n) n >= 1)
  expect_gte(n, 1)
  expect_no_match(read_text(h$b, "#ro-selection"), "none")
  expect_gt(gd_nselected(h$b), 0)
  expect_gt(gd_outline_paths(h$b), 0)

  # Row 17: "Clear selection" tears down BOTH layers (readout none, no outline,
  # every selectedpoints unset).
  click_sel(h$b, "#btn-clear")
  poll_until(\() read_text(h$b, "#ro-selection"), \(t) identical(t, "none"))
  expect_equal(read_text(h$b, "#ro-selection"), "none")
  expect_equal(poll_until(\() gd_nselections(h$b), \(n) n == 0), 0)
  expect_equal(poll_until(\() gd_nselected_traces(h$b), \(n) n == 0), 0)
  expect_no_app_error(h)
})

# --- Rows 23, 24: identity selection survives filtering + echo guard ---------

test_that("identity selection survives a trace-recomposing filter (23, 24)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)
  settle(1)

  drag_select(h$b)
  sel0 <- poll_until(\() read_text(h$b, "#ro-selection"), \(t) !identical(t, "none"))
  expect_no_match(sel0, "none")
  n_sel0 <- gd_nselected(h$b)

  # Filter so the 4-cyl group drops entirely: 3 -> 2 traces (the renumber).
  set_input(h$b, "#hp-slider", KS_FILTER)
  expect_equal(poll_until(\() gd_ntraces(h$b), \(n) n == 2), 2)
  # Row 24: the data-change deselect echo is swallowed — selection NOT wiped.
  expect_equal(read_text(h$b, "#ro-selection"), sel0)
  expect_no_match(read_text(h$b, "#ro-selection"), "none")

  # Unfilter: 2 -> 3 traces; names unchanged, selectedpoints re-resolve in full.
  set_input(h$b, "#hp-slider", 0)
  expect_equal(poll_until(\() gd_ntraces(h$b), \(n) n == KS_TRACES), KS_TRACES)
  expect_equal(read_text(h$b, "#ro-selection"), sel0)
  expect_equal(poll_until(\() gd_nselected(h$b), \(n) n == n_sel0), n_sel0)
  expect_no_app_error(h)
})

# --- Row 25: programmatic set over an active drag ---------------------------

test_that("programmatic set clears the stale outline; a re-drag keeps its own (25)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)
  settle(1)

  drag_select(h$b)
  poll_until(\() gd_nselections(h$b), \(n) n >= 1)

  # A different (programmatic) selection applies and clears the stale outline.
  click_sel(h$b, "#btn-sports")
  sel <- poll_until(\() read_text(h$b, "#ro-selection"), \(t) grepl("Maserati Bora", t))
  expect_match(sel, "Maserati Bora")
  expect_equal(poll_until(\() gd_nselections(h$b), \(n) n == 0), 0)
  expect_equal(poll_until(\() gd_nselected(h$b), \(n) n == 2), 2)

  # A re-drag's OWN echo must NOT wipe its fresh marquee (matchesCurrent skip).
  drag_select(h$b)
  poll_until(\() gd_nselections(h$b), \(n) n >= 1)
  settle(2)  # let the echo round-trip; the marquee must survive it
  expect_gte(gd_nselections(h$b), 1)
  expect_no_app_error(h)
})

# --- Row 26: name-keyed visibility survives recomposition + round-trips ------

test_that("name-keyed visibility survives recomposition; legend toggle writes back (26)", {
  h <- local_e2e("kitchen-sink.R")
  e2e_await_plot(h, KS_TRACES)

  click_sel(h$b, "#btn-hide8")
  poll_until(\() gd_visible_by_name(h$b, "8"), \(v) identical(v, "legendonly"))

  # Filter drops the 4-cyl group (3 -> 2); "8" stays legendonly, keyed by name.
  set_input(h$b, "#hp-slider", KS_FILTER)
  expect_equal(poll_until(\() gd_ntraces(h$b), \(n) n == 2), 2)
  expect_equal(gd_visible_by_name(h$b, "8"), "legendonly")

  # Unfilter (2 -> 3); still legendonly.
  set_input(h$b, "#hp-slider", 0)
  expect_equal(poll_until(\() gd_ntraces(h$b), \(n) n == KS_TRACES), KS_TRACES)
  expect_equal(gd_visible_by_name(h$b, "8"), "legendonly")

  # A legend toggle (restyle) writes the full {name -> state} map back.
  idx6 <- gd_eval(h$b, "for(var i=0;i<gd.data.length;i++){if(String(gd.data[i].name)==='6')return i;}return -1;")
  gd_restyle(h$b, list(visible = "legendonly"), idx6)
  vis <- poll_until(\() read_text(h$b, "#ro-visibility"), \(t) grepl("6=legendonly", t))
  expect_match(vis, "6=legendonly")
  expect_match(vis, "8=legendonly")
  expect_no_app_error(h)
})

# --- Row 18: subplot axes route independently -------------------------------

test_that("subplot axes route independently (18)", {
  h <- local_e2e("subplot.R")
  e2e_await_plot(h, 2L)

  click_sel(h$b, "#btn-x1")
  poll_until(\() gd_range(h$b, "xaxis"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 20) < 2)
  expect_approx_range(gd_range(h$b, "xaxis"), c(10, 20), tol = 2)
  # xaxis2 untouched (autorange still on).
  expect_true(isTRUE(gd_autorange(h$b, "xaxis2")) || is.null(gd_range(h$b, "xaxis2")))

  click_sel(h$b, "#btn-x2")
  poll_until(\() gd_range(h$b, "xaxis2"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 40) < 2)
  expect_approx_range(gd_range(h$b, "xaxis2"), c(30, 40), tol = 2)
  expect_approx_range(gd_range(h$b, "xaxis"), c(10, 20), tol = 2)  # x1 still set
  expect_no_app_error(h)
})

# --- Row 19: ggplotly parity ------------------------------------------------

test_that("ggplotly renders and the same range bindings work (19)", {
  h <- local_e2e("ggplotly.R")
  e2e_await_plot(h, 1L)

  click_sel(h$b, "#btn-zoom")
  xr <- poll_until(\() gd_range(h$b, "xaxis"), \(v) !is.null(v) && abs(as.numeric(v[[2]]) - 25) < 3)
  expect_approx_range(xr, c(15, 25), tol = 3)
  expect_approx_range(gd_range(h$b, "yaxis"), c(80, 200), tol = 5)
  expect_no_app_error(h)
})

# --- Row 20: per-flush coalescing — one redraw ------------------------------

test_that("a same-flush spec + range write redraws once (20)", {
  h <- local_e2e("gated.R")
  e2e_await_plot(h, 1L)
  settle(1)

  # Count redraws via plotly_afterplot from this point forward.
  eval_js(h$b, sprintf(
    "(function(){var gd=document.querySelector('%s');window.__redraws=0;gd.on('plotly_afterplot',function(){window.__redraws++;});return true;})()",
    PLOTLY_GD
  ))
  click_sel(h$b, "#btn-bump")
  # spec change -> 25 points; wait for the react to land, then assert one redraw.
  poll_until(\() gd_eval(h$b, "return gd.data[0].x.length;"), \(n) n == 30)
  settle(2)
  expect_equal(eval_js(h$b, "window.__redraws"), 1)
  expect_no_app_error(h)
})

# --- Row 21: destroy on When flip -------------------------------------------

test_that("flipping the gate destroys the widget (Plotly.purge + removal) (21)", {
  h <- local_e2e("gated.R")
  e2e_await_plot(h, 1L)

  # Spy on Plotly.purge so we can confirm destroy() ran.
  eval_js(h$b, "window.__purged=false;var _p=Plotly.purge;Plotly.purge=function(){window.__purged=true;return _p.apply(this,arguments);};true")
  click_sel(h$b, "#btn-toggle")
  wait_until(h$b, sprintf("document.querySelector('%s')===null", PLOTLY_GD), timeout = 15)
  expect_null(gd_eval(h$b, "return gd;"))
  expect_true(eval_js(h$b, "window.__purged===true"))
  expect_no_app_error(h)
})
