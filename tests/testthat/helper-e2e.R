# helper-e2e.R — generic e2e driver for irid apps. The PlotlyOutput-specific
# layer (e2e_plt_*) lives in helper-e2e-plt.R. See TESTING.md (End-to-end tests)
# for gating + conventions. Boots a fixture app in a background callr process and
# drives headless Chrome via chromote.
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

# Central timeout budget. Every wait below routes its seconds through here so a
# slow runner can be absorbed with one knob instead of editing each call: set
# E2E_TIMEOUT_SCALE (e.g. "3" in CI) to multiply every timeout. Generous
# timeouts don't slow the happy path — a wait returns within one poll interval of
# its condition holding, so a big ceiling is pure insurance against a cold runner.
e2e_timeout <- function(sec) {
  scale <- suppressWarnings(as.numeric(Sys.getenv("E2E_TIMEOUT_SCALE", "1")))
  if (is.na(scale) || scale <= 0) scale <- 1
  sec * scale
}

# CI launch hardening, applied once at source time (before the first
# ChromoteSession launches Chrome). The default 10s port-open timeout is too
# tight for a cold GitHub runner — it intermittently aborts the very first test
# with "Chrome debugging port not open after 10 seconds". A bigger timeout
# absorbs the cold start; `--disable-dev-shm-usage` keeps headless Chrome off
# the runner's small /dev/shm (a separate startup-crash mode). No-ops locally.
if (requireNamespace("chromote", quietly = TRUE)) {
  options(chromote.timeout = e2e_timeout(60))
  chromote::set_chrome_args(
    unique(c(chromote::get_chrome_args(), "--disable-dev-shm-usage"))
  )
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
  # A fixture's last value is normally a zero-arg App fn (wrapped in iridApp).
  # A fixture exercising iridOutput/renderIrid instead returns a full
  # shiny.appobj (its own ui/server) — run that verbatim.
  sourced <- source(fixture_path)$value
  app <- if (inherits(sourced, "shiny.appobj")) sourced else irid::iridApp(sourced)
  shiny::runApp(
    app, port = port, host = "127.0.0.1", launch.browser = FALSE
  )
}

# Wait for Shiny's "Listening on ..." banner on the child's stderr. Not a
# socketConnection port poll: refused probes leak R connection slots, and ~17
# boots/suite exhaust R's ~128-connection table. Timeout is generous — the child
# runs load_all().
e2e_wait_listening <- function(proc, timeout = 90) {
  deadline <- Sys.time() + e2e_timeout(timeout)
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
  # Readiness barrier. After `navigate` returns the page is loaded but NOT yet
  # interactive: Shiny connects asynchronously and irid wires its listeners on
  # the initial flush's `irid-wire`, so a first interaction dispatched here can
  # be silently dropped (issue #59). The server sends `irid-ready` only once
  # every mount's listeners and server observers exist — wait for the client to
  # see it before handing back the (now genuinely interactive) handle.
  #
  # `window.__iridReady` flips on the FIRST mount that becomes ready, which is
  # exactly right for every current fixture (each is single-output). A
  # multi-output fixture should instead wait on its specific output's readiness:
  # the `irid:ready` DOM event carries `detail.id` (the output name), so record
  # the ready ids and wait on membership rather than this global flag.
  e2e_wait_until(app, "window.__iridReady === true", timeout = 30)
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

# Abort a test with the full picture at the moment of failure. The driver already
# captures the page's console + uncaught exceptions (see e2e_app); without dumping
# them here a CI timeout is just "waiting for: <js>" with no clue why. Also grabs a
# screenshot into E2E_ARTIFACTS (CI uploads it; falls back to tempdir locally), so
# an intermittent failure is diagnosable from one look instead of a re-run.
e2e_fail <- function(app, what, err = NULL) {
  dir <- Sys.getenv("E2E_ARTIFACTS", unset = tempdir())
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  shot <- tempfile(pattern = "e2e-fail-", tmpdir = dir, fileext = ".png")
  shot <- tryCatch({ app$session$screenshot(shot); shot },
                   error = function(e) NULL)
  console <- utils::tail(app$caps$console, 30)
  excs <- app$caps$exceptions
  stderr <- tryCatch(utils::tail(app$proc$read_error_lines(), 20),
                     error = function(e) character())
  stop(
    "e2e: ", what,
    if (!is.null(err)) paste0("\n  cause: ", conditionMessage(err)) else "",
    "\n--- console (last 30) ---\n", paste(console, collapse = "\n"),
    "\n--- page exceptions ---\n", paste(excs, collapse = "\n"),
    "\n--- app stderr (last 20) ---\n", paste(stderr, collapse = "\n"),
    "\n--- screenshot ---\n", shot %||% "(capture failed)",
    call. = FALSE
  )
}

# Poll a JS boolean expression until truthy. A plain R-side poll (round-trips are
# async, so we sample) — the value here over the old version is that a timeout is
# *loud*: it aborts via e2e_fail with the page console, exceptions, stderr, and a
# screenshot, rather than the bare "Timeout waiting for: <js>" it used to give.
# The predicate is guarded in-page so a not-yet-defined reference reads as false.
e2e_wait_until <- function(app, js_bool, timeout = 30, interval = 0.2) {
  deadline <- Sys.time() + e2e_timeout(timeout)
  guarded <- paste0(
    "(function(){try{return !!(", js_bool, ");}catch(e){return false;}})()"
  )
  repeat {
    if (isTRUE(e2e_eval(app, guarded))) return(invisible(TRUE))
    if (Sys.time() > deadline) e2e_fail(app, paste0("timeout waiting for: ", js_bool))
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
# busy toggle between flushes of a multi-flush reactive chain). A server that
# never settles in time is a real failure, not something to silently proceed
# past, so on timeout we abort with diagnostics rather than returning FALSE.
e2e_wait_idle <- function(app, quiet = 0.25, timeout = 15, interval = 0.1) {
  deadline <- Sys.time() + e2e_timeout(timeout)
  repeat {
    st <- e2e_eval(app, "({busy: window.__iridIdle ? window.__iridIdle.busy : false, since: window.__iridIdle ? (Date.now() - window.__iridIdle.lastChange) : 1e9})")
    if (isFALSE(st$busy) && st$since >= quiet * 1000) return(invisible(TRUE))
    if (Sys.time() > deadline) e2e_fail(app, "timeout waiting for server idle")
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

# Flush `n` animation frames and return. A deterministic settle for "let the
# browser finish the work it has already queued" (e.g. a pending plotly
# `afterplot` from the initial render) — unlike a wall-clock sleep it waits for
# exactly the queued frames, neither too short under load nor wastefully long.
e2e_raf <- function(app, n = 2) {
  e2e_eval(app, sprintf(
    "new Promise(function(res){var i=%d;(function tick(){if(i--<=0)return res(true);requestAnimationFrame(tick);})();})",
    as.integer(n)
  ), await = TRUE)
}

# A settle window (rarely needed — prefer e2e_await / e2e_wait_idle / e2e_raf).
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

# Poll an R-side reader until a predicate holds, returning the matching value so
# the caller can assert on it. Used where the truth lives in R (app stderr) or
# must round-trip through an R reader. On timeout it aborts with diagnostics and
# the last value seen — a timed-out poll used to return the stale value and
# surface as a baffling downstream assertion ("expected X, got NULL") instead of
# "waited for X and it never came". `app` is optional: pass it to get the full
# console/screenshot dump on timeout. `app` is auto-discovered from the calling
# test frame (every test binds `app <- e2e_app(...)`) so the readers' closures
# need no rewrite; pass it explicitly to override.
e2e_poll <- function(reader, pred, timeout = 15, interval = 0.3, app = NULL) {
  if (is.null(app)) {
    app <- tryCatch(get("app", envir = parent.frame()), error = function(e) NULL)
    if (!inherits(app, "e2e_app")) app <- NULL
  }
  deadline <- Sys.time() + e2e_timeout(timeout)
  last <- NULL
  repeat {
    last <- tryCatch(reader(), error = function(e) NULL)
    if (!is.null(last) && isTRUE(tryCatch(pred(last), error = function(e) FALSE))) {
      return(last)
    }
    if (Sys.time() > deadline) {
      msg <- paste0("e2e_poll predicate never held; last value: ",
                    paste(utils::capture.output(utils::str(last)), collapse = " "))
      if (!is.null(app)) e2e_fail(app, msg) else stop("e2e: ", msg, call. = FALSE)
    }
    Sys.sleep(interval)
  }
}
