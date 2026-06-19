# Spike: confirm the shiny#4372 scoped-teardown runtime behavior before
# implementing irid issue #24. Throwaway — build-ignored (dev/spikes).
#
# RUN AGAINST A SHINY WITH #4372 MERGED (>= 2026-05-29 main, not CRAN 1.7.4):
#   Rscript dev/spikes/scope-teardown-4372.R
#
# Prints PASS/FAIL verdicts for each design assumption. Record the printed
# `packageVersion("shiny")` + git SHA back into dev/scope-teardown-4372.md.

library(shiny)

ok <- function(label, cond) {
  cat(sprintf("[%s] %s\n", if (isTRUE(cond)) "PASS" else "FAIL", label))
}
info <- function(...) cat(sprintf(...), "\n")

info("shiny version: %s", as.character(packageVersion("shiny")))

# A MockShinySession is the cheapest way to exercise makeScope/destroy outside a
# running app. The PR adds these to MockShinySession too. If construction fails,
# we're on a pre-#4372 shiny — bail loudly.
session <- tryCatch(
  shiny::MockShinySession$new(),
  error = function(e) { info("could not build MockShinySession: %s", conditionMessage(e)); NULL }
)

ok("session$makeScope is a function", !is.null(session) && is.function(session$makeScope))
ok("session$destroy is a function",   !is.null(session) && is.function(session$destroy))
ok("session$onDestroy is a function", !is.null(session) && is.function(session$onDestroy))

if (is.null(session) || !is.function(session$makeScope)) {
  info("STOP: this shiny lacks #4372. Re-run against merged shiny.")
  quit(status = 1)
}

# ---- 1. child scope proxy shape ------------------------------------------
child <- session$makeScope(as.character(1L))
ok("makeScope returns a proxy with $destroy",   is.function(child$destroy))
ok("makeScope returns a proxy with $onDestroy", is.function(child$onDestroy))
ok("makeScope tolerates an integer-stringified id", TRUE)  # reached => no error

# ---- 2/3. observer scoped to child stops firing after destroy(id) --------
fire_count <- 0L
rv <- NULL
withReactiveDomain(child, {
  rv <<- reactiveVal(0L)
  observe({ rv(); fire_count <<- fire_count + 1L }, domain = child)
})
session$flushReact()
before <- fire_count
rv(1L); session$flushReact()
ok("observe in child fired on dependency change", fire_count > before)

child$destroy()           # or session$destroy("1") — confirm which is canonical
after_destroy <- fire_count
rv(2L); session$flushReact()
ok("observe stopped firing after destroy()", fire_count == after_destroy)

# ---- 2(B). does reactiveVal() accept a domain= arg? ----------------------
has_domain_arg <- "domain" %in% names(formals(reactiveVal))
ok("reactiveVal() has a `domain` formal (mechanism B)", has_domain_arg)
info("=> if FALSE, scope reactiveVals via withReactiveDomain (mechanism A)")

# ---- 4. reactiveVal is actually reclaimed (weak-ref finalizer fires) ------
finalized <- new.env(); finalized$hit <- FALSE
child2 <- session$makeScope(as.character(2L))
withReactiveDomain(child2, {
  rv2 <- reactiveVal(0L)
  # Finalizer on the rv's enclosing environment — fires when GC reclaims it.
  reg.finalizer(environment(rv2), function(e) finalized$hit <<- TRUE, onexit = FALSE)
})
child2$destroy()
rm(rv2); gc(); gc()
ok("reactiveVal env finalized after destroy + gc (reclamation runs)", finalized$hit)
info("   (FAIL here may mean a lingering reference, not a broken API — inspect)")

# ---- 5. child proxy forwards the methods the inner mount needs ------------
ok("child$sendCustomMessage is a function", is.function(child$sendCustomMessage))
ok("child$output is present",               !is.null(child$output))
# insertUI reads getDefaultReactiveDomain(); confirm it resolves under the child.

# ---- 6. pre-#4372 no-op sanity (informational) ---------------------------
# withReactiveDomain(session, expr) should be a no-op when session is already the
# active domain — the fallback path relies on this. Just exercise it here.
withReactiveDomain(session, info("withReactiveDomain(session, ...) ran"))

info("done.")
</content>
