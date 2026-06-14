# helper-e2e.R — e2e driver for irid apps, with a plotly layer (e2e_plt_*).
# Design + rationale: dev/plotly-e2e-testing-design.md. Boots a fixture app in a
# background callr process and drives headless Chrome via chromote.
#
#   app <- e2e_app("plotly/kitchen-sink.R")
#   e2e_plt_await(app, 3)
#   e2e_click(app, "#btn-economy")
#   e2e_plt_range(app, "xaxis")

# --- prerequisites / skip gate ----------------------------------------------

# Skip unless this is an opted-in e2e run with the browser stack present.
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

# Runs in the callr child (must be self-contained — callr strips its env). Loads
# the dev package, sources the fixture (last expr is the bare App fn), runs it.
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

# Wait for Shiny's "Listening on ..." banner on the child's stderr. Not a
# socketConnection port poll: refused probes leak R connection slots, and ~17
# boots/suite exhaust R's ~128-connection table. Timeout is generous — the child
# runs load_all().
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

# Boot in a background process, retrying on a fresh port (a just-released port can
# still be in TIME_WAIT). supervise = FALSE: the supervisor leaks a pipe
# connection per process; teardown kills explicitly via withr::defer.
e2e_boot_app <- function(fixture, env, attempts = 3) {
  last_err <- NULL
  for (i in seq_len(attempts)) {
    port <- httpuv::randomPort()
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

# --- the app handle + the generic `e2e_*` API -------------------------------

# Boot a fixture app + headless browser and return the handle. Teardown is
# registered on `env` (the calling test frame) so both processes die when the
# test exits.
e2e_app <- function(fixture, env = parent.frame(), viewport = c(1280, 900)) {
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

  app <- structure(
    list(session = b, proc = boot$proc,
         url = sprintf("http://127.0.0.1:%d", boot$port), caps = caps),
    class = "e2e_app"
  )
  b$Page$navigate(app$url, wait_ = TRUE)
  e2e_install_idle(app)
  app
}

# Evaluate JS in the page and return the value to R. awaitPromise resolves a
# returned promise first, so a `Plotly.relayout(...).then(...)` can be awaited.
e2e_eval <- function(app, js, await = TRUE) {
  res <- app$session$Runtime$evaluate(
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
e2e_wait_until <- function(app, js_bool, timeout = 30, interval = 0.2) {
  deadline <- Sys.time() + timeout
  guarded <- paste0(
    "(function(){try{return !!(", js_bool, ");}catch(e){return false;}})()"
  )
  repeat {
    if (isTRUE(e2e_eval(app, guarded))) return(invisible(TRUE))
    if (Sys.time() > deadline) stop("Timeout waiting for: ", js_bool, call. = FALSE)
    Sys.sleep(interval)
  }
}

# Track Shiny's shiny:busy/shiny:idle (jQuery events) so e2e_wait_idle has a real
# settle signal. Self-bootstraps once jQuery loads. Idempotent. Internal.
e2e_install_idle <- function(app) {
  e2e_eval(app, "(function () {
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

# Wait until the server has been idle for `quiet` s (the window bridges the brief
# busy toggle between flushes of a multi-flush reactive chain).
e2e_wait_idle <- function(app, quiet = 0.25, timeout = 15, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    st <- e2e_eval(app, "({busy: window.__iridIdle ? window.__iridIdle.busy : false, since: window.__iridIdle ? (Date.now() - window.__iridIdle.lastChange) : 1e9})")
    if (isFALSE(st$busy) && st$since >= quiet * 1000) return(invisible(TRUE))
    if (Sys.time() > deadline) return(invisible(FALSE))
    Sys.sleep(interval)
  }
}

# Click a DOM control by selector (server <- client via the genuine event path).
e2e_click <- function(app, sel) {
  e2e_eval(app, sprintf("document.querySelector(%s).click(), true", to_js_str(sel)))
}

# Set a control's value and fire the binding's event.
e2e_set_input <- function(app, sel, value, event = "input") {
  e2e_eval(app, sprintf(
    "(function(){var e=document.querySelector(%s);e.value=%s;e.dispatchEvent(new Event(%s,{bubbles:true}));return e.value;})()",
    to_js_str(sel), to_js_str(as.character(value)), to_js_str(event)
  ))
}

# Read an element's trimmed textContent (a readout reflects the server-side
# reactiveVal — the source of truth to compare gd state against).
e2e_readout <- function(app, sel) {
  e2e_eval(app, sprintf(
    "(function(){var e=document.querySelector(%s);return e?e.textContent.trim():null;})()",
    to_js_str(sel)
  ))
}

# A real left-button drag with intermediate moves — plotly's select tool builds
# the outline from the move stream, so a single jump produces no selection.
e2e_drag <- function(app, x1, y1, x2, y2, steps = 6) {
  b <- app$session
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

# A settle window (rarely needed — prefer e2e_poll / e2e_wait_idle).
e2e_settle <- function(sec = 2) Sys.sleep(sec)

e2e_exceptions <- function(app) app$caps$exceptions
e2e_console <- function(app) app$caps$console

# Fail if the app's stderr emitted an R error since the last drain.
e2e_expect_no_error <- function(app) {
  lines <- tryCatch(app$proc$read_error_lines(), error = function(e) character())
  errs <- grep("Error", lines, value = TRUE)
  testthat::expect_equal(errs, character(),
    info = paste("app stderr errors:", paste(errs, collapse = " | ")))
}

# Poll an R-side reader until a predicate holds (or timeout), returning the last
# value so the caller can assert on it.
e2e_poll <- function(reader, pred, timeout = 15, interval = 0.3) {
  deadline <- Sys.time() + timeout
  repeat {
    v <- tryCatch(reader(), error = function(e) NULL)
    if (!is.null(v) && isTRUE(tryCatch(pred(v), error = function(e) FALSE))) return(v)
    if (Sys.time() > deadline) return(v)
    Sys.sleep(interval)
  }
}

# --- the plotly `e2e_plt_*` layer -------------------------------------------
# `gd` selects which graph div to drive — defaults to the sole PlotlyOutput on
# the page; pass a container selector (e.g. "#plot-b") to target one of several.

# Evaluate a JS body that has `gd` (the graph div) in scope.
e2e_plt_eval <- function(app, body, gd = PLOTLY_GD, await = FALSE) {
  e2e_eval(app, sprintf(
    "(function(){var gd=document.querySelector('%s');%s})()", gd, body
  ), await = await)
}

# Wait for the plot to render N traces (the readiness gate).
e2e_plt_await <- function(app, n_traces, gd = PLOTLY_GD, timeout = 40) {
  e2e_wait_until(app, sprintf(
    "window.Plotly && document.querySelector('%s') && document.querySelector('%s').data && document.querySelector('%s').data.length === %d",
    gd, gd, gd, n_traces
  ), timeout = timeout)
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
