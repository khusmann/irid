# Spike for issue #26 — §1 "await script execution" approach + its tripwires.
#
# ============================================================================
# FINDING (2026-06-14, Shiny 1.7.4 / jQuery 3.6.0):
#   §1a (let Shiny inject, MutationObserver-capture the <script>, await its
#   `load` event) DOES NOT WORK. Shiny injects deps via jQuery `$head.append`,
#   and jQuery intercepts `<script src>` and executes it through AJAX
#   `globalEval` (jQuery._evalUrl) — NOT a real script-tag fetch. Observed:
#     - renderDependencies injects TWO duplicate <script src> nodes per dep,
#     - NEITHER fires `load`/`error` (so awaiting the element load hangs),
#     - yet the script executes exactly once (the global appears).
#   So A1_capturedSync FAILS and the load-event awaits TIME OUT below — the
#   tripwire correctly flags that the naive approach's assumptions are false.
#
#   Consequence: a generic dep-layer fix would have to SELF-INJECT scripts
#   (§1b) to get a real load event — replicating Shiny's URL join + dedup +
#   attribute handling, i.e. the heavy, dep-shape-coupled version.
#
#   The contract `ready()` poll (§2) sidesteps all of this: it polls the
#   EXECUTION side effect (the global), which appears no matter how Shiny loads
#   the script (AJAX or tag). It needs essentially no Shiny-internal tripwire.
# ============================================================================
#
# Two jobs:
#  (1) Prototype `renderAndAwaitScripts` end to end against REAL Shiny + Chrome,
#      including the two-widgets-same-flush concurrency case.
#  (2) Assert the *undocumented Shiny behaviors* the approach leans on, as
#      standalone checks. These are the tripwires: if a future Shiny changes how
#      it injects dependencies, A1/A2/A3 fail immediately rather than letting
#      widgets break silently. They translate directly into a permanent
#      tests/testthat/test-widget-deps-e2e.R.
#
# Tripwires (Shiny contract we depend on):
#   A1  renderDependencies injects <script src> SYNCHRONOUSLY during the call
#       (so a MutationObserver + takeRecords captures it) and returns undefined.
#   A2  the injected element's `load` fires AFTER execution (global defined).
#   A3  a second renderDependencies with the same dep NAME injects nothing
#       (Shiny dedup) — the fact our concurrency handling assumes.
# irid-logic correctness:
#   A4  renderAndAwaitScripts: global undefined before ready, defined after.
#   A5  two same-flush inits sharing a dep: the deduped second still waits for
#       the in-flight script (closes the concurrency hole) — it does NOT resolve
#       early with the global still undefined.
#
# A slow script server (separate port, 150ms delay, no-store) forces cold loads
# so timing is deterministic. Each request sets a per-file global G_<file>.
#
# Run:  Rscript dev/spikes/dep-await-contract.R
# Build-ignored via `^dev$` in .Rbuildignore.

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
      message("LIBREQ ", f)
      Sys.sleep(0.15)                                  # force a cold, async load
      list(
        status = 200L,
        headers = list("Content-Type" = "application/javascript",
                       "Cache-Control" = "no-store"),
        # Record load by filename — no global-name derivation to get wrong.
        # f is a plain filename (e.g. "a.js"), safe to single-quote.
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
b$Runtime$consoleAPICalled(function(m) {
  txt <- vapply(m$args, function(a) a$value %||% a$description %||% "", character(1))
  cat("[console]", m$type, paste(txt, collapse = " "), "\n")
})
b$Runtime$exceptionThrown(function(m) {
  cat("[exception]", m$exceptionDetails$exception$description %||%
        m$exceptionDetails$text %||% "?", "\n")
})
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
  if (isTRUE(ev("!!(window.Shiny && Shiny.renderDependencies && window.MutationObserver)")))
    break
  if (Sys.time() > deadline) stop("Shiny never appeared")
  Sys.sleep(0.2)
}

# Mirror of the proposed irid instrumentation + all assertions, one async IIFE.
js <- sprintf("(async function () {
  var R = {}, LIB = 'http://127.0.0.1:%d';
  function dep(name, file) {
    return { name: name, version: '0.0.1', src: { href: LIB }, script: [file] };
  }
  var scriptsInFlight = new Set();
  function render(deps) {                 // == proposed renderAndAwaitScripts (capture half)
    var obs = new MutationObserver(function () {});
    obs.observe(document.documentElement, { childList: true, subtree: true });
    var ret = Shiny.renderDependencies(deps);
    var recs = obs.takeRecords(); obs.disconnect();
    var injected = [];
    recs.forEach(function (m) {
      Array.prototype.forEach.call(m.addedNodes, function (n) {
        if (n.tagName === 'SCRIPT' && n.src) {
          injected.push(n); scriptsInFlight.add(n);
          var done = function () { scriptsInFlight.delete(n); };
          n.addEventListener('load', done); n.addEventListener('error', done);
        }
      });
    });
    return { ret: ret, injected: injected };
  }
  function awaitInFlight() {              // await ALL in-flight (closes concurrency hole)
    var w = [];
    scriptsInFlight.forEach(function (n) {
      w.push(new Promise(function (res) {
        n.addEventListener('load', res); n.addEventListener('error', res);
      }));
    });
    return Promise.all(w);
  }
  function timed(p, label) {              // never hang the spike; report which step stalls
    return Promise.race([
      Promise.resolve(p).then(function () { return 'ok'; }),
      new Promise(function (res) { setTimeout(function () { res('TIMEOUT:' + label); }, 3000); })
    ]);
  }
  function loaded(f) { return !!window.__loaded && window.__loaded.indexOf(f) >= 0; }

  // A1 — sync capturable injection + undefined return
  var r1 = render([dep('a', 'a.js')]);
  R.A1_returnUndefined = (r1.ret === undefined);
  R.A1_capturedSync = (r1.injected.length === 1 && /a\\.js/.test(r1.injected[0].src));
  R.A1_injectedCount = r1.injected.length;
  R.A1_firstSrc = r1.injected[0] ? r1.injected[0].src : null;

  // A2 — load fires after execution
  if (r1.injected[0]) {
    R.A2_step = await timed(new Promise(function (res) {
      r1.injected[0].addEventListener('load', res);
      r1.injected[0].addEventListener('error', res);
    }), 'A2-load');
  } else { R.A2_step = 'no-node'; }
  R.A2_globalAfterLoad = loaded('a.js');

  // A3 — same dep name dedups (injects nothing)
  R.A3_dedupNoInject = (render([dep('a', 'a.js')]).injected.length === 0);

  // A4 — end to end cold (fresh dep b)
  render([dep('b', 'b.js')]);
  R.A4_undefinedBefore = !loaded('b.js');
  R.A4_step = await timed(awaitInFlight(), 'A4-inflight');
  R.A4_definedAfter = loaded('b.js');

  // A5 — two same-flush inits share dep c; deduped second must still wait
  render([dep('c', 'c.js')]);            // init 1 injects c.js
  var i2 = render([dep('c', 'c.js')]);   // init 2 dedups -> injects nothing
  R.A5_secondInjectedNothing = (i2.injected.length === 0);
  R.A5_cUndefinedAtStart = !loaded('c.js');
  R.A5_step = await timed(awaitInFlight(), 'A5-inflight');  // init 2's ready gate
  R.A5_cDefinedWhenSecondResolved = loaded('c.js');
  return R;
})()", libport)

res <- ev(js, await = TRUE)
cat("\n--- child stderr (LIBREQ = a script request reached the slow server) ---\n")
cat(paste(grep("LIBREQ", proc$read_error_lines(), value = TRUE), collapse = "\n"), "\n")
cat("\n--- raw ---\n"); str(res)

cat("\n--- Shiny-contract tripwires (fail loudly if Shiny changes) ----\n")
tw <- c("A1_returnUndefined", "A1_capturedSync", "A2_globalAfterLoad",
        "A3_dedupNoInject")
ok <- c("A4_undefinedBefore", "A4_definedAfter", "A5_secondInjectedNothing",
        "A5_cUndefinedAtStart", "A5_cDefinedWhenSecondResolved")
show <- function(keys) for (k in keys)
  cat(sprintf("  %-32s %s\n", k, if (isTRUE(res[[k]])) "PASS" else "FAIL"))
show(tw)
cat("--- irid-logic correctness ------------------------------------\n")
show(ok)
cat("---------------------------------------------------------------\n")

all_ok <- all(vapply(c(tw, ok), function(k) isTRUE(res[[k]]), logical(1)))
if (all_ok) {
  cat("\nALL PASS: §1 works on this Shiny, and A1-A3 are the tripwires that\n")
  cat("would catch a Shiny injection-behavior change in CI.\n")
} else {
  cat("\nSOME FAILED -- inspect; a failing A1-A3 means Shiny's injection\n")
  cat("contract differs from what §1 assumes on this version.\n")
}
