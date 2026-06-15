# Spike for issue #26 — "wrap the dep with a notifier" idea.
#
# Since the <script> `load` event is dead under Shiny's jQuery-AJAX injection
# (see dep-await-contract.R), the alternative is: append a tiny NOTIFIER script
# as the LAST script of a dep, then POLL for its side effect. When the notifier
# has run, the library before it has run too — generic, no per-widget global.
#
# This works ONLY if jQuery executes a dep's scripts IN ORDER (notifier last).
# That is the load-bearing assumption; this spike tests it two ways:
#   O1  intra-dep order: one dep, script = [lib.js (SLOW resp), note.js (FAST)].
#       If order is preserved, __loaded == ['lib.js','note.js'] even though
#       note.js responds first. If broken, note.js lands first.
#   O2  inter-dep order: dep X = [libx.js (SLOW)], dep Y = [notey.js (FAST)],
#       rendered together. Notifier dep must run after the library dep.
#   O3  the actual mechanism: poll for the notifier token; assert the library
#       ran by the time the token appears.
#
# The slow server delays a response 300ms if the filename contains "lib", else
# 0ms — so a naive ASYNC loader would run the fast notifier first. Order
# surviving that is the real test.
#
# Run:  Rscript dev/spikes/dep-notifier-order.R   (build-ignored via ^dev$)

stopifnot(requireNamespace("shiny"), requireNamespace("chromote"),
          requireNamespace("callr"), requireNamespace("httpuv"))
`%||%` <- function(a, b) if (is.null(a)) b else a
cat("Shiny version:", as.character(utils::packageVersion("shiny")), "\n\n")

boot_fn <- function(port, libport) {
  httpuv::startServer("127.0.0.1", libport, list(
    call = function(req) {
      p <- req$PATH_INFO
      if (is.null(p) || !nzchar(p)) p <- "/x.js"
      f <- basename(p)
      if (grepl("lib", f)) Sys.sleep(0.3)        # library is SLOW to respond
      list(
        status = 200L,
        headers = list("Content-Type" = "application/javascript",
                       "Cache-Control" = "no-store"),
        body = sprintf("(window.__loaded=window.__loaded||[]).push('%s');", f)
      )
    }
  ))
  shiny::runApp(
    shiny::shinyApp(shiny::basicPage(shiny::tags$p("spike")),
                    function(input, output, session) {}),
    port = port, host = "127.0.0.1", launch.browser = FALSE
  )
}

port <- httpuv::randomPort(); libport <- httpuv::randomPort()
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
cat("app at", url, " slow-script server at", libport, "\n")

options(chromote.timeout = 120)
b <- chromote::ChromoteSession$new()
on.exit(tryCatch(b$close(), error = function(e) NULL), add = TRUE)
b$Runtime$enable(wait_ = TRUE)
b$Page$navigate(url, wait_ = TRUE)
ev <- function(js, await = TRUE) {
  r <- b$Runtime$evaluate(js, returnByValue = TRUE, awaitPromise = await,
                          wait_ = TRUE)
  if (!is.null(r$exceptionDetails))
    stop("JS error: ", r$exceptionDetails$exception$description %||%
           r$exceptionDetails$text)
  r$result$value
}
deadline <- Sys.time() + 30
repeat {
  if (isTRUE(ev("!!(window.Shiny && Shiny.renderDependencies)"))) break
  if (Sys.time() > deadline) stop("Shiny never appeared")
  Sys.sleep(0.2)
}

js <- sprintf("(async function () {
  var R = {}, LIB = 'http://127.0.0.1:%d';
  function dep(name, scripts) {
    return { name: name, version: '0.0.1', src: { href: LIB }, script: scripts };
  }
  function poll(token, ms) {
    return new Promise(function (res) {
      var t0 = Date.now();
      (function c() {
        if (window.__loaded && window.__loaded.indexOf(token) >= 0) res(true);
        else if (Date.now() - t0 > ms) res(false);
        else setTimeout(c, 10);
      })();
    });
  }
  function idx(f){ return window.__loaded ? window.__loaded.indexOf(f) : -1; }

  // O1 + O3 — intra-dep order via notifier poll
  Shiny.renderDependencies([dep('d1', ['lib.js', 'note.js'])]);
  R.O3_tokenAppeared = await poll('note.js', 5000);
  R.O1_libRan       = idx('lib.js') >= 0;
  R.O1_orderKept    = (idx('lib.js') >= 0 && idx('note.js') >= 0 &&
                       idx('lib.js') < idx('note.js'));

  // O2 — inter-dep order (separate library dep + notifier dep, one call)
  Shiny.renderDependencies([dep('dx', ['libx.js']), dep('dy', ['notey.js'])]);
  await poll('notey.js', 5000);
  R.O2_orderKept = (idx('libx.js') >= 0 && idx('notey.js') >= 0 &&
                    idx('libx.js') < idx('notey.js'));

  R.loaded = window.__loaded || [];
  return R;
})()", libport)

res <- ev(js, await = TRUE)
cat("\n--- raw ---\n"); str(res)
cat("\n--- Verdicts ---------------------------------------------------\n")
chk <- function(k) cat(sprintf("  %-22s %s\n", k, if (isTRUE(res[[k]])) "PASS" else "FAIL"))
chk("O3_tokenAppeared"); chk("O1_libRan"); chk("O1_orderKept"); chk("O2_orderKept")
cat("  load order:", paste(unlist(res$loaded), collapse = " -> "), "\n")
cat("---------------------------------------------------------------\n")
if (isTRUE(res$O1_orderKept) && isTRUE(res$O2_orderKept)) {
  cat("\nORDER PRESERVED: the notifier idea is viable — a notifier appended\n")
  cat("last reliably runs after the library, intra- and inter-dep.\n")
} else {
  cat("\nORDER NOT GUARANTEED: a fast notifier can beat a slow library — the\n")
  cat("notifier-poll would fire before the library is ready. Idea unsafe.\n")
}
