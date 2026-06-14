# helper-e2e.R — generic e2e driver for irid apps. The PlotlyOutput-specific
# layer (e2e_plt_*) lives in helper-e2e-plt.R. Design + rationale:
# dev/plotly-e2e-testing-design.md. Boots a fixture app in a background callr
# process and drives headless Chrome via chromote.
#
#   app <- e2e_app("plotly/kitchen-sink.R")
#   e2e_click(app, "#btn-economy")
#   e2e_readout(app, "#ro-selection")

# --- prerequisites / skip gate ----------------------------------------------

# Gate every e2e case on the IRID_E2E=1 opt-in (plus CRAN + browser-present).
# Set it locally when working on something the suite covers; in CI the dedicated
# e2e job (.github/workflows/e2e.yaml) sets it, while the main R-CMD-check job
# leaves it unset so e2e skips there. A bare devtools::test() doesn't boot Chrome.
skip_unless_e2e <- function() {
  testthat::skip_on_cran()                       # CRAN policy: no browser
  testthat::skip_if(Sys.getenv("IRID_E2E") != "1",
                    "e2e: set IRID_E2E=1 to run (see helper-e2e.R)")
  testthat::skip_if_not_installed("chromote")
  testthat::skip_if_not_installed("callr")
  testthat::skip_if(is.null(chromote::find_chrome()), "no Chrome found")
}

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
      a$value %||% a$description %||% ""
    }, character(1))
    caps$console <- c(caps$console, paste(msg$type, paste(txt, collapse = " ")))
  })
  b$Runtime$exceptionThrown(function(msg) {
    d <- msg$exceptionDetails
    caps$exceptions <- c(caps$exceptions,
      d$exception$description %||% d$text %||% "exception")
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
    msg <- det$exception$description %||% det$text %||% "unknown JS error"
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
