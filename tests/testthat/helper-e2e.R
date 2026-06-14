# helper-e2e.R — reusable harness for the PlotlyOutput end-to-end suite.
#
# See dev/plotly-e2e-testing-design.md. The suite boots a test-owned fixture app
# in a background `callr` process (a real, separate Shiny session) and drives a
# headless Chrome via `chromote` (a CDP client). Three drive primitives mirror
# the round-trip directions:
#
#   - server -> client : click the real DOM controls          (eval_js + .click())
#   - client -> server : synthesize the plotly gesture        (eval_js: emit / relayout)
#   - client -> server : a *real* mouse drag (selection)      (drag_select via Input)
#
# Assertions read back gd.layout / gd.data state and the app's own readout <div>s
# (the server-side reactiveVals), which cleanly separates a client-apply bug from
# a server-write bug.

# --- prerequisites / skip gate ----------------------------------------------

# Every e2e case opens with this. skip_on_cran() is the load-bearing CRAN guard;
# the rest cover machines without the browser stack, and IRID_E2E is a *local*
# opt-out so a routine devtools::test() does not boot Chrome (~30s/case).
skip_unless_e2e <- function() {
  testthat::skip_on_cran()
  testthat::skip_if_not_installed("chromote")
  testthat::skip_if_not_installed("callr")
  testthat::skip_if(is.null(chromote::find_chrome()), "no Chrome found")
  testthat::skip_if(Sys.getenv("IRID_E2E") != "1", "set IRID_E2E=1 to run e2e")
}

# A CSS selector for the plotly graph div (gd). PlotlyOutput renders the chart
# straight into its widget container, so the container element *is* gd.
PLOTLY_GD <- "[data-irid-widget=plotly]"

`%e2e||%` <- function(a, b) if (is.null(a)) b else a

# --- booting the app under test (callr) -------------------------------------

# tests/testthat -> package root, so the background process can load_all() the
# dev tree rather than a stale installed copy.
e2e_pkg_root <- function() {
  normalizePath(testthat::test_path("..", ".."), mustWork = FALSE)
}

# Self-contained boot function shipped to the callr process (must reference only
# its args + base/loaded-pkg functions — callr strips its environment). Loads the
# dev package, sources the fixture (whose last expression is the bare `App`
# function), and runs it.
e2e_boot_fn <- function(fixture_path, pkg_root, port) {
  loaded <- FALSE
  if (requireNamespace("pkgload", quietly = TRUE) &&
      file.exists(file.path(pkg_root, "DESCRIPTION"))) {
    loaded <- tryCatch({
      pkgload::load_all(pkg_root, quiet = TRUE, helpers = FALSE,
                        attach_testthat = FALSE)
      TRUE
    }, error = function(e) FALSE)
  }
  if (!loaded) library(irid)
  app_fn <- source(fixture_path)$value
  shiny::runApp(
    irid::iridApp(app_fn),
    port = port, host = "127.0.0.1", launch.browser = FALSE
  )
}

# Block until the app's port accepts a connection (or the process dies).
e2e_wait_port <- function(proc, port, timeout = 30) {
  deadline <- Sys.time() + timeout
  repeat {
    if (!proc$is_alive()) {
      stop("App process died while booting:\n",
           paste(proc$read_all_error_lines(), collapse = "\n"))
    }
    con <- tryCatch(
      socketConnection("127.0.0.1", port, open = "r+",
                       blocking = TRUE, timeout = 1),
      error = function(e) NULL, warning = function(w) NULL
    )
    if (!is.null(con)) { close(con); return(invisible()) }
    if (Sys.time() > deadline) stop("App did not bind port ", port)
    Sys.sleep(0.3)
  }
}

# --- the drive primitives (chromote) ----------------------------------------

# Evaluate JS in the page and return the value to R. awaitPromise resolves a
# returned promise first, so a `Plotly.relayout(...).then(...)` can be awaited.
eval_js <- function(b, js, await = TRUE) {
  res <- b$Runtime$evaluate(
    js, returnByValue = TRUE, awaitPromise = await, wait_ = TRUE
  )
  if (!is.null(res$exceptionDetails)) {
    det <- res$exceptionDetails
    msg <- det$exception$description %e2e||% det$text %e2e||% "unknown JS error"
    stop("JS exception: ", msg, call. = FALSE)
  }
  res$result$value
}

# Poll a JS boolean expression until truthy (round-trips are async). Used for the
# initial render and after every gesture in place of a blind fixed sleep.
wait_until <- function(b, js_bool, timeout = 30, interval = 0.2) {
  deadline <- Sys.time() + timeout
  guarded <- paste0(
    "(function(){try{return !!(", js_bool, ");}catch(e){return false;}})()"
  )
  repeat {
    if (isTRUE(eval_js(b, guarded))) return(invisible(TRUE))
    if (Sys.time() > deadline) stop("Timeout waiting for: ", js_bool, call. = FALSE)
    Sys.sleep(interval)
  }
}

# Poll an R-side reader until a predicate holds (or timeout), returning the last
# value so the caller can assert on it. Robust alternative to a blind sleep when
# the settled value is known.
poll_until <- function(reader, pred, timeout = 15, interval = 0.3) {
  deadline <- Sys.time() + timeout
  repeat {
    v <- tryCatch(reader(), error = function(e) NULL)
    if (!is.null(v) && isTRUE(tryCatch(pred(v), error = function(e) FALSE))) return(v)
    if (Sys.time() > deadline) return(v)
    Sys.sleep(interval)
  }
}

# A settle window between a gesture and its assertion. Throttled props
# (wire_throttle(100)) plus the server flush want ~1.5-2.5s; one gesture per
# window (batching lets a later sequence bump mask an earlier echo).
settle <- function(sec = 2) Sys.sleep(sec)

# Click a DOM element by selector (server <- client via the genuine event path).
click_sel <- function(b, sel) {
  eval_js(b, sprintf("document.querySelector(%s).click(), true", to_js_str(sel)))
}

# Read an element's trimmed textContent (a readout reflects the server-side
# reactiveVal — the source of truth to compare gd state against).
read_text <- function(b, sel) {
  eval_js(b, sprintf(
    "(function(){var e=document.querySelector(%s);return e?e.textContent.trim():null;})()",
    to_js_str(sel)
  ))
}

# Read gd state via a JS body that has `gd` in scope.
gd_eval <- function(b, body, await = FALSE) {
  eval_js(b, sprintf(
    "(function(){var gd=document.querySelector('%s');%s})()", PLOTLY_GD, body
  ), await = await)
}

to_js_str <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE)

# Set a DOM control's value and fire the binding's event (server <- client).
set_input <- function(b, sel, value, event = "input") {
  eval_js(b, sprintf(
    "(function(){var e=document.querySelector(%s);e.value=%s;e.dispatchEvent(new Event(%s,{bubbles:true}));return e.value;})()",
    to_js_str(sel), to_js_str(as.character(value)), to_js_str(event)
  ))
}

# Synthesize a plotly gesture by driving plotly's own API / emitter (client ->
# server). `obj` is an R list serialized to a JS object.
gd_relayout <- function(b, obj) {
  eval_js(b, sprintf(
    "(function(){var gd=document.querySelector('%s');return Plotly.relayout(gd,%s).then(function(){return true;});})()",
    PLOTLY_GD, jsonlite::toJSON(obj, auto_unbox = TRUE)
  ), await = TRUE)
}

gd_restyle <- function(b, obj, trace_index) {
  eval_js(b, sprintf(
    "(function(){var gd=document.querySelector('%s');return Plotly.restyle(gd,%s,[%d]).then(function(){return true;});})()",
    PLOTLY_GD, jsonlite::toJSON(obj, auto_unbox = TRUE), trace_index
  ), await = TRUE)
}

# Emit a plotly event through plotly's own emitter — runs the factory's real
# listener (slimPoints, the applying guard, the sequence plumbing) with only the
# physical mouse event faked.
gd_emit <- function(b, event, payload = NULL) {
  pl <- if (is.null(payload)) "{}" else jsonlite::toJSON(payload, auto_unbox = TRUE)
  eval_js(b, sprintf(
    "(function(){var gd=document.querySelector('%s');gd.emit(%s,%s);return true;})()",
    PLOTLY_GD, to_js_str(event), pl
  ))
}

# --- gd state readers (compare 'what the plot shows' vs the readouts) --------

gd_range <- function(b, axis = "xaxis") {
  gd_eval(b, sprintf("var a=gd.layout&&gd.layout['%s'];return a?a.range:null;", axis))
}
gd_autorange <- function(b, axis = "xaxis") {
  gd_eval(b, sprintf("var a=gd.layout&&gd.layout['%s'];return a?!!a.autorange:null;", axis))
}
gd_dragmode <- function(b) gd_eval(b, "return gd.layout?gd.layout.dragmode:null;")
gd_ntraces  <- function(b) gd_eval(b, "return gd.data?gd.data.length:0;")
# tri-state visibility of the trace with the given name (identity lookup).
gd_visible_by_name <- function(b, name) {
  gd_eval(b, sprintf(
    "var t=(gd.data||[]).filter(function(x){return String(x.name)===%s;})[0];return t?(t.visible===undefined?true:t.visible):null;",
    to_js_str(as.character(name))
  ))
}
# total selected points across all traces (the dimming layer).
gd_nselected <- function(b) {
  gd_eval(b, "return (gd.data||[]).reduce(function(n,t){return n+((t.selectedpoints&&t.selectedpoints.length)||0);},0);")
}
# number of selectedpoints arrays that are actually set (not null/undefined).
gd_nselected_traces <- function(b) {
  gd_eval(b, "return (gd.data||[]).filter(function(t){return t.selectedpoints!=null;}).length;")
}
# count of outline rectangles (layout.selections + rendered .selectionlayer).
gd_nselections <- function(b) {
  gd_eval(b, "return (gd.layout&&gd.layout.selections)?gd.layout.selections.length:0;")
}
gd_outline_paths <- function(b) {
  gd_eval(b, sprintf(
    "return document.querySelectorAll('%s .select-outline, %s .selectionlayer path').length;",
    PLOTLY_GD, PLOTLY_GD
  ))
}

# A real left-button drag with intermediate moves (plotly's select tool builds
# the outline from the move stream — a single jump produces no selection).
drag <- function(b, x1, y1, x2, y2, steps = 6) {
  b$Input$dispatchMouseEvent(type = "mousePressed", x = x1, y = y1,
                             button = "left", buttons = 1, clickCount = 1,
                             wait_ = TRUE)
  for (i in seq_len(steps)) {
    b$Input$dispatchMouseEvent(
      type = "mouseMoved",
      x = x1 + (x2 - x1) * i / steps, y = y1 + (y2 - y1) * i / steps,
      button = "left", buttons = 1, wait_ = TRUE
    )
  }
  b$Input$dispatchMouseEvent(type = "mouseReleased", x = x2, y = y2,
                             button = "left", buttons = 1, clickCount = 1,
                             wait_ = TRUE)
}

# Drag-select a fraction of the plot's interior. Aims at the `.nsewdrag` rect
# (offset in from the edges) so the drag lands on the plot area, not an axis.
# `dragmode` must be a select tool.
drag_select <- function(b, fx1 = 0.15, fy1 = 0.15, fx2 = 0.85, fy2 = 0.85) {
  r <- eval_js(b, sprintf(
    "(function(){var d=document.querySelector('%s .nsewdrag');var r=d.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height};})()",
    PLOTLY_GD
  ))
  drag(b,
       r$x + r$w * fx1, r$y + r$h * fy1,
       r$x + r$w * fx2, r$y + r$h * fy2)
}

# --- lifecycle: boot app + browser, register teardown -----------------------

# Returns a handle: $b (ChromoteSession), $proc (callr), $url, and a private
# capture env. Tears down both processes via withr::defer on `env`.
local_e2e <- function(fixture, env = parent.frame(),
                      viewport = c(1280, 900)) {
  skip_unless_e2e()
  port <- httpuv::randomPort()
  proc <- callr::r_bg(
    e2e_boot_fn,
    args = list(
      fixture_path = testthat::test_path("fixtures", fixture),
      pkg_root = e2e_pkg_root(),
      port = port
    ),
    supervise = TRUE
  )
  withr::defer(tryCatch(proc$kill(), error = function(e) NULL), envir = env)
  e2e_wait_port(proc, port)

  b <- chromote::ChromoteSession$new()
  withr::defer(tryCatch(b$close(), error = function(e) NULL), envir = env)
  b$set_viewport_size(viewport[1], viewport[2])

  caps <- new.env(parent = emptyenv())
  caps$console <- character()
  caps$exceptions <- character()
  b$Runtime$enable(wait_ = TRUE)
  b$Runtime$consoleAPICalled(function(msg) {
    txt <- vapply(msg$args, function(a) {
      a$value %e2e||% a$description %e2e||% ""
    }, character(1))
    caps$console <- c(caps$console, paste(msg$type, paste(txt, collapse = " ")))
  })
  b$Runtime$exceptionThrown(function(msg) {
    d <- msg$exceptionDetails
    caps$exceptions <- c(caps$exceptions,
      d$exception$description %e2e||% d$text %e2e||% "exception")
  })

  url <- sprintf("http://127.0.0.1:%d", port)
  b$Page$navigate(url, wait_ = TRUE)

  list(b = b, proc = proc, url = url, caps = caps, port = port)
}

# Wait for the plot to render N traces (the row-1 readiness gate). Returns the
# handle invisibly so callers can chain.
e2e_await_plot <- function(h, n_traces, timeout = 40) {
  wait_until(h$b, sprintf(
    "window.Plotly && document.querySelector('%s') && document.querySelector('%s').data && document.querySelector('%s').data.length === %d",
    PLOTLY_GD, PLOTLY_GD, PLOTLY_GD, n_traces
  ), timeout = timeout)
  invisible(h)
}

# Fail if the app's stderr emitted an R error since the last drain. The
# count-before/count-after pattern that localized the null->NA + lazy-capture
# bugs to an exact gesture.
expect_no_app_error <- function(h) {
  lines <- tryCatch(h$proc$read_error_lines(), error = function(e) character())
  errs <- grep("Error", lines, value = TRUE)
  testthat::expect_equal(
    errs, character(),
    info = paste("app stderr errors:", paste(errs, collapse = " | "))
  )
}
