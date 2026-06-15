# Spike for issue #26 — widget-init dependency-load race.
#
# Question (step 0 of the proposal): does `Shiny.renderDependencies` await
# actual <script> execution before returning? If it did, the race wouldn't
# exist and no substrate fix would be needed.
#
# Boots a throwaway *plain Shiny* app (so the only thing under test is the
# stock `Shiny.renderDependencies` API — no irid code involved). The widget's
# "library" script is served from a SECOND port whose handler sleeps 150ms
# before responding, so the cold load is unambiguously async — this removes the
# loopback/HTTP-cache timing artifact where a warm subresource appears to
# execute synchronously (that warm-path sync is exactly what makes the bug
# intermittent in dev, but the cold path is what bites on first mount in prod).
#
# Then drives headless Chrome to:
#   (0) report what `renderDependencies([dep])` RETURNS (undefined? promise?);
#   (b) sample the dep's global at the sync / microtask / macrotask boundaries
#       right after the call returns (the race window — the factory runs here);
#   (A) confirm approach-A's mechanism — polling a `requires` predicate — does
#       resolve once the script finally executes, and report the lag.
#
# Pinned: Shiny — re-confirm on bump.
#
# Run:  Rscript dev/spikes/render-deps-timing.R
# Build-ignored via `^dev$` in .Rbuildignore.

stopifnot(requireNamespace("shiny"), requireNamespace("chromote"),
          requireNamespace("callr"), requireNamespace("httpuv"))

`%||%` <- function(a, b) if (is.null(a)) b else a
cat("Shiny version:", as.character(utils::packageVersion("shiny")), "\n\n")

# --- the throwaway app + slow script server, booted in a child process ------

boot_fn <- function(port, libport) {
  # Slow script server on its own port: the handler sleeps before responding,
  # guaranteeing the global is NOT set at the sync/micro/macro boundaries.
  # `no-store` keeps every load cold so the result is stable across runs.
  httpuv::startServer("127.0.0.1", libport, list(
    call = function(req) {
      Sys.sleep(0.15)
      list(
        status = 200L,
        headers = list("Content-Type" = "application/javascript",
                       "Cache-Control" = "no-store"),
        body = "window.__SPIKE_GLOBAL = { readyAt: Date.now() };"
      )
    }
  ))
  ui <- shiny::basicPage(shiny::tags$p("spike"))
  server <- function(input, output, session) {}
  shiny::runApp(shiny::shinyApp(ui, server),
                port = port, host = "127.0.0.1", launch.browser = FALSE)
}

port <- httpuv::randomPort()
libport <- httpuv::randomPort()
proc <- callr::r_bg(boot_fn, args = list(port = port, libport = libport),
                    supervise = FALSE)
on.exit(tryCatch(proc$kill(), error = function(e) NULL), add = TRUE)

deadline <- Sys.time() + 60
repeat {
  seen <- tryCatch(proc$read_error_lines(), error = function(e) character())
  if (any(grepl("Listening on", seen, fixed = TRUE))) break
  if (!proc$is_alive()) stop("app died:\n", paste(seen, collapse = "\n"))
  if (Sys.time() > deadline) stop("app never listened")
  Sys.sleep(0.2)
}
url <- sprintf("http://127.0.0.1:%d", port)
cat("app at", url, "  slow-script server at port", libport, "\n")

# --- drive headless chrome --------------------------------------------------

b <- chromote::ChromoteSession$new()
on.exit(tryCatch(b$close(), error = function(e) NULL), add = TRUE)
b$Runtime$enable(wait_ = TRUE)
b$Page$navigate(url, wait_ = TRUE)

ev <- function(js, await = TRUE) {
  r <- b$Runtime$evaluate(js, returnByValue = TRUE, awaitPromise = await,
                          wait_ = TRUE)
  if (!is.null(r$exceptionDetails)) {
    stop("JS error: ", r$exceptionDetails$exception$description %||%
           r$exceptionDetails$text)
  }
  r$result$value
}

deadline <- Sys.time() + 30
repeat {
  if (isTRUE(ev("!!(window.Shiny && Shiny.renderDependencies)"))) break
  if (Sys.time() > deadline) stop("Shiny.renderDependencies never appeared")
  Sys.sleep(0.2)
}

# The dep object in the same shape irid ships over irid-widget-init: a resolved
# href + a script filename. Points at the slow server (cross-origin is fine for
# <script> execution). The path is ignored by the slow handler.
test_js <- sprintf("
(function () {
  delete window.__SPIKE_GLOBAL;
  var dep = { name: 'spikelib', version: '0.0.1',
              src: { href: 'http://127.0.0.1:%d' }, script: ['splib.js'] };
  var ret = Shiny.renderDependencies([dep]);
  var sync = (typeof window.__SPIKE_GLOBAL !== 'undefined');
  var retType = (ret === undefined ? 'undefined'
                 : (ret && typeof ret.then === 'function' ? 'promise'
                    : typeof ret));
  return new Promise(function (resolve) {
    Promise.resolve().then(function () {
      var micro = (typeof window.__SPIKE_GLOBAL !== 'undefined');
      setTimeout(function () {
        var macro = (typeof window.__SPIKE_GLOBAL !== 'undefined');
        resolve({ returnType: retType, sync: sync, micro: micro, macro: macro });
      }, 0);
    });
  });
})()
", libport)
res1 <- ev(test_js, await = TRUE)

# Approach A: poll the `requires`-style predicate, time the lag to readiness.
poll_js <- "
(function () {
  return new Promise(function (resolve) {
    var start = performance.now();
    (function check() {
      if (typeof window.__SPIKE_GLOBAL !== 'undefined') {
        resolve(Math.round(performance.now() - start));
      } else if (performance.now() - start > 5000) {
        resolve(-1);
      } else { setTimeout(check, 5); }
    })();
  });
})()
"
lag <- ev(poll_js, await = TRUE)

cat("\n--- Verdicts ----------------------------------------------------\n")
cat("(0) renderDependencies() return type :", res1$returnType, "\n")
cat("(b) global defined SYNC after return  :", res1$sync, "\n")
cat("    global defined after MICROtask    :", res1$micro, "\n")
cat("    global defined after MACROtask    :", res1$macro, "\n")
cat("(A) requires-poll resolved after     :", lag, "ms\n")
cat("----------------------------------------------------------------\n\n")

if (identical(res1$returnType, "undefined") && !isTRUE(res1$macro)) {
  cat("CONFIRMED: renderDependencies returns (undefined) and does NOT await\n")
  cat("script execution -- on a cold load the global is still absent a\n")
  cat("macrotask later. The race is real; a substrate readiness gate is\n")
  cat("needed. Approach-A polling closed the gap in", lag, "ms.\n")
} else if (identical(res1$returnType, "promise")) {
  cat("SURPRISE: renderDependencies returns a PROMISE on this Shiny version --\n")
  cat("if it resolves on load, the existing Promise.resolve() wrap may suffice.\n")
} else {
  cat("UNEXPECTED -- global resolved before macrotask even on the slow path.\n")
  cat("Inspect res1; the injection path may differ on this Shiny version.\n")
}
