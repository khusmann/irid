# helper-e2e.R — a small e2e driver for irid apps (and a plotly layer on top).
#
# See dev/plotly-e2e-testing-design.md. The harness boots a test-owned fixture
# app in a background `callr` process (a real, separate Shiny session) and drives
# a headless Chrome via `chromote` (a CDP client).
#
# The driver is a PLAIN STATE OBJECT plus FREE FUNCTIONS, not R6 and not a
# `$`-method closure object. `irid_app()` returns a list ($session, $proc, $url,
# $caps); every operation is a free `app_*` (generic irid) / `plt_*` (plotly)
# function taking it first. This is the most statically-checkable shape in R: a
# free-function call site is a real symbol, so `codetools`/`lintr` flags a
# misspelled or removed helper. A `$`-method call (`app$rang()`) is dynamic and
# invisible to static analysis whether the object is R6 or a closure — so the
# fluent style buys ergonomics at the cost of the very call-site linting we want.
#
#   app <- irid_app("kitchen-sink.R")
#   plt_await(app, 3)
#   app_click(app, "#btn-economy")
#   app_wait_idle(app)
#   plt_range(app, "xaxis")          # c(20, 35)
#   app_readout(app, "#ro-selection")
#   plt_drag_select(app)
#
# Three drive primitives mirror the round-trip directions: click the real DOM
# controls (server <- client), synthesize a plotly gesture (client -> server via
# relayout/emit), and a *real* mouse drag (selection). Assertions read back
# gd.layout / gd.data state and the app's own readout <div>s (the server-side
# reactiveVals), separating a client-apply bug from a server-write bug.

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

to_js_str <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE)

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

# Block until the app reports it is listening (or the process dies), by watching
# the child's stderr for Shiny's "Listening on ..." banner. This deliberately
# does NOT poll the port with socketConnection(): each refused probe while the
# app boots leaks an R connection slot, and across the suite's ~17 boots that
# exhausts R's ~128-connection table. read_error_lines() reads processx pipes,
# which are not R connections. Returns the boot-phase stderr it consumed so the
# caller can seed its own error tracking. The timeout is generous because the
# child runs pkgload::load_all(), slow when the machine is already loaded.
e2e_wait_listening <- function(proc, timeout = 90) {
  deadline <- Sys.time() + timeout
  seen <- character()
  repeat {
    new <- tryCatch(proc$read_error_lines(), error = function(e) character())
    seen <- c(seen, new)
    if (any(grepl("Listening on", seen, fixed = TRUE))) return(invisible(seen))
    if (!proc$is_alive()) {
      stop("App process died while booting:\n", paste(seen, collapse = "\n"))
    }
    if (Sys.time() > deadline) {
      stop("App did not report listening within ", timeout, "s\n",
           paste(utils::tail(seen, 20), collapse = "\n"))
    }
    Sys.sleep(0.2)
  }
}

# --- low-level browser impl (take a ChromoteSession `b`) --------------------
# The driver methods are thin closures over these; they stay free functions so
# they are independently testable and reusable.

# Evaluate JS in the page and return the value to R. awaitPromise resolves a
# returned promise first, so a `Plotly.relayout(...).then(...)` can be awaited.
e2e_eval <- function(b, js, await = TRUE) {
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

# Poll a JS boolean expression until truthy (round-trips are async).
e2e_wait_until <- function(b, js_bool, timeout = 30, interval = 0.2) {
  deadline <- Sys.time() + timeout
  guarded <- paste0(
    "(function(){try{return !!(", js_bool, ");}catch(e){return false;}})()"
  )
  repeat {
    if (isTRUE(e2e_eval(b, guarded))) return(invisible(TRUE))
    if (Sys.time() > deadline) stop("Timeout waiting for: ", js_bool, call. = FALSE)
    Sys.sleep(interval)
  }
}

# Install a busy/idle tracker that mirrors Shiny's shiny:busy / shiny:idle (the
# same events irid's stale indicator listens to). Shiny dispatches these as
# *jQuery* events, not native ones, so the tracker attaches via jQuery — which
# is not yet loaded right after navigate, so the install self-bootstraps once
# window.jQuery appears. wait_for_idle then waits for a quiet idle window — a
# real settle signal, not a fixed sleep. Idempotent.
e2e_install_idle <- function(b) {
  e2e_eval(b, "(function () {
    if (window.__iridIdleInstalled) return true;
    function attach() {
      if (!window.jQuery) return false;
      window.__iridIdle = { busy: false, lastChange: Date.now() };
      window.jQuery(document).on('shiny:busy', function () {
        window.__iridIdle.busy = true; window.__iridIdle.lastChange = Date.now();
      });
      window.jQuery(document).on('shiny:idle', function () {
        window.__iridIdle.busy = false; window.__iridIdle.lastChange = Date.now();
      });
      window.__iridIdleInstalled = true;
      return true;
    }
    if (!attach()) {
      var t = setInterval(function () { if (attach()) clearInterval(t); }, 50);
    }
    return true;
  })()")
}

# Wait until the server has been idle continuously for `quiet` ms. A reactive
# chain that flushes more than once briefly toggles busy between flushes; the
# quiet window bridges that gap.
e2e_wait_for_idle <- function(b, quiet = 0.25, timeout = 15, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    st <- e2e_eval(b, "({busy: window.__iridIdle ? window.__iridIdle.busy : false, since: window.__iridIdle ? (Date.now() - window.__iridIdle.lastChange) : 1e9})")
    if (isFALSE(st$busy) && st$since >= quiet * 1000) return(invisible(TRUE))
    if (Sys.time() > deadline) return(invisible(FALSE))
    Sys.sleep(interval)
  }
}

# A real left-button drag with intermediate moves (plotly's select tool builds
# the outline from the move stream — a single jump produces no selection).
e2e_drag <- function(b, x1, y1, x2, y2, steps = 6) {
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

# Boot the fixture app in a background process, retrying on a fresh port if it
# fails to come up — across a suite of ~17 sequential boots a just-released port
# can still be in TIME_WAIT and fail to rebind. Registers teardown on success.
e2e_boot_app <- function(fixture, env, attempts = 3) {
  last_err <- NULL
  for (i in seq_len(attempts)) {
    port <- httpuv::randomPort()
    # supervise = FALSE is deliberate: the callr supervisor opens (and never
    # releases) pipe connections per process, so across the suite's ~17 sequential
    # boots it exhausts R's ~128-connection table ("all connections are in use").
    # Teardown kills the process explicitly via withr::defer, so the supervisor's
    # crash-cleanup is redundant here.
    proc <- callr::r_bg(
      e2e_boot_fn,
      args = list(
        fixture_path = testthat::test_path("fixtures", fixture),
        pkg_root = e2e_pkg_root(),
        port = port
      ),
      supervise = FALSE
    )
    ok <- tryCatch({ e2e_wait_listening(proc); TRUE },
                   error = function(e) { last_err <<- e; FALSE })
    if (ok) {
      withr::defer(tryCatch(proc$kill(), error = function(e) NULL), envir = env)
      return(list(proc = proc, port = port))
    }
    tryCatch(proc$kill(), error = function(e) NULL)
    Sys.sleep(0.5)
  }
  stop("Failed to boot ", fixture, " after ", attempts, " attempts: ",
       conditionMessage(last_err))
}

# --- the app handle + the generic `app_*` API -------------------------------
#
# The driver is a PLAIN state object (a list: $session, $proc, $url, $caps) and
# every operation is a free `app_*` (generic irid) / `plt_*` (plotly) function
# taking it as the first argument. This is the most lintable shape in R: unlike
# a `$`-method object (R6 *or* closure), a free-function call site is a real
# symbol, so `codetools`/`lintr` flags a misspelled or removed helper
# (`plt_rang(app, ...)` -> "no visible global function definition"). A `$`-method
# call (`app$rang()`) is dynamic and invisible to static analysis either way.

# Boot a fixture app + headless browser and return the handle. Teardown is
# registered on `env` (the calling test frame) so both processes die when the
# test exits.
irid_app <- function(fixture, env = parent.frame(), viewport = c(1280, 900)) {
  skip_unless_e2e()

  boot <- e2e_boot_app(fixture, env)

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

  url <- sprintf("http://127.0.0.1:%d", boot$port)
  b$Page$navigate(url, wait_ = TRUE)
  e2e_install_idle(b)

  structure(
    list(session = b, proc = boot$proc, url = url, caps = caps),
    class = "irid_app"
  )
}

# Evaluate JS in the page and return the value to R.
app_eval <- function(app, js, await = TRUE) e2e_eval(app$session, js, await)

# Poll a JS boolean expression until truthy.
app_wait_until <- function(app, js_bool, timeout = 30) {
  e2e_wait_until(app$session, js_bool, timeout)
}

# Wait until the server has been idle continuously for `quiet` s (shiny:idle).
app_wait_idle <- function(app, quiet = 0.25, timeout = 15) {
  e2e_wait_for_idle(app$session, quiet = quiet, timeout = timeout)
}

# Click a DOM control by selector (server <- client via the genuine event path).
app_click <- function(app, sel) {
  e2e_eval(app$session,
           sprintf("document.querySelector(%s).click(), true", to_js_str(sel)))
}

# Set a control's value and fire the binding's event.
app_set_input <- function(app, sel, value, event = "input") {
  e2e_eval(app$session, sprintf(
    "(function(){var e=document.querySelector(%s);e.value=%s;e.dispatchEvent(new Event(%s,{bubbles:true}));return e.value;})()",
    to_js_str(sel), to_js_str(as.character(value)), to_js_str(event)
  ))
}

# Read an element's trimmed textContent (a readout reflects the server-side
# reactiveVal — the source of truth to compare gd state against).
app_readout <- function(app, sel) {
  e2e_eval(app$session, sprintf(
    "(function(){var e=document.querySelector(%s);return e?e.textContent.trim():null;})()",
    to_js_str(sel)
  ))
}

# A settle window (rarely needed — prefer poll_until / app_wait_idle).
settle <- function(sec = 2) Sys.sleep(sec)

app_exceptions <- function(app) app$caps$exceptions
app_console <- function(app) app$caps$console

# Fail if the app's stderr emitted an R error since the last drain — the
# count-around-a-gesture pattern that localizes a bug to an exact action.
app_expect_no_error <- function(app) {
  lines <- tryCatch(app$proc$read_error_lines(), error = function(e) character())
  errs <- grep("Error", lines, value = TRUE)
  testthat::expect_equal(errs, character(),
    info = paste("app stderr errors:", paste(errs, collapse = " | ")))
}

app_stop <- function(app) {
  tryCatch(app$session$close(), error = function(e) NULL)
  tryCatch(app$proc$kill(), error = function(e) NULL)
}

# --- the plotly `plt_*` layer -----------------------------------------------

# Evaluate a JS body that has `gd` (the graph div) in scope.
plt_gd_eval <- function(app, body, await = FALSE) {
  e2e_eval(app$session, sprintf(
    "(function(){var gd=document.querySelector('%s');%s})()", PLOTLY_GD, body
  ), await = await)
}

# Wait for the plot to render N traces (the row-1 readiness gate).
plt_await <- function(app, n_traces, timeout = 40) {
  e2e_wait_until(app$session, sprintf(
    "window.Plotly && document.querySelector('%s') && document.querySelector('%s').data && document.querySelector('%s').data.length === %d",
    PLOTLY_GD, PLOTLY_GD, PLOTLY_GD, n_traces
  ), timeout = timeout)
  invisible(app)
}

# ---- client -> server gestures (drive plotly's own API / emitter) ----
plt_relayout <- function(app, obj) {
  e2e_eval(app$session, sprintf(
    "(function(){var gd=document.querySelector('%s');return Plotly.relayout(gd,%s).then(function(){return true;});})()",
    PLOTLY_GD, jsonlite::toJSON(obj, auto_unbox = TRUE)
  ), await = TRUE)
}
plt_restyle <- function(app, obj, trace_index) {
  e2e_eval(app$session, sprintf(
    "(function(){var gd=document.querySelector('%s');return Plotly.restyle(gd,%s,[%d]).then(function(){return true;});})()",
    PLOTLY_GD, jsonlite::toJSON(obj, auto_unbox = TRUE), trace_index
  ), await = TRUE)
}
plt_emit <- function(app, event, payload = NULL) {
  pl <- if (is.null(payload)) "{}" else jsonlite::toJSON(payload, auto_unbox = TRUE)
  e2e_eval(app$session, sprintf(
    "(function(){var gd=document.querySelector('%s');gd.emit(%s,%s);return true;})()",
    PLOTLY_GD, to_js_str(event), pl
  ))
}
# A real drag-select over a fraction of the plot interior. Aims at `.nsewdrag`
# (offset in from the edges) so the drag lands on the plot area, not an axis;
# `dragmode` must be a select tool.
plt_drag_select <- function(app, fx1 = 0.15, fy1 = 0.15, fx2 = 0.85, fy2 = 0.85) {
  r <- e2e_eval(app$session, sprintf(
    "(function(){var d=document.querySelector('%s .nsewdrag');var r=d.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height};})()",
    PLOTLY_GD
  ))
  e2e_drag(app$session, r$x + r$w * fx1, r$y + r$h * fy1,
           r$x + r$w * fx2, r$y + r$h * fy2)
}

# ---- gd state readers (what the plot shows) ----
plt_range <- function(app, axis = "xaxis") {
  plt_gd_eval(app, sprintf("var a=gd.layout&&gd.layout['%s'];return a?a.range:null;", axis))
}
plt_autorange <- function(app, axis = "xaxis") {
  plt_gd_eval(app, sprintf("var a=gd.layout&&gd.layout['%s'];return a?!!a.autorange:null;", axis))
}
plt_dragmode <- function(app) plt_gd_eval(app, "return gd.layout?gd.layout.dragmode:null;")
plt_hovermode <- function(app) plt_gd_eval(app, "return gd.layout?gd.layout.hovermode:null;")
plt_n_traces <- function(app) plt_gd_eval(app, "return gd.data?gd.data.length:0;")
# tri-state visibility of the trace with the given name (identity lookup).
plt_visible <- function(app, name) {
  plt_gd_eval(app, sprintf(
    "var t=(gd.data||[]).filter(function(x){return String(x.name)===%s;})[0];return t?(t.visible===undefined?true:t.visible):null;",
    to_js_str(as.character(name))
  ))
}
# total selected points across all traces (the dimming layer).
plt_n_selected <- function(app) {
  plt_gd_eval(app, "return (gd.data||[]).reduce(function(n,t){return n+((t.selectedpoints&&t.selectedpoints.length)||0);},0);")
}
# number of selectedpoints arrays that are actually set (not null/undefined).
plt_n_selected_traces <- function(app) {
  plt_gd_eval(app, "return (gd.data||[]).filter(function(t){return t.selectedpoints!=null;}).length;")
}
# count of outline rectangles (layout.selections + rendered .selectionlayer).
plt_n_selections <- function(app) {
  plt_gd_eval(app, "return (gd.layout&&gd.layout.selections)?gd.layout.selections.length:0;")
}
plt_outline_paths <- function(app) {
  plt_gd_eval(app, sprintf(
    "return document.querySelectorAll('%s .select-outline, %s .selectionlayer path').length;",
    PLOTLY_GD, PLOTLY_GD
  ))
}

# --- shared assertion helpers ------------------------------------------------

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
