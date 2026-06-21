# Spike: runtime confirmation of the shiny#4372 scoped-teardown behavior for
# irid issue #24. Throwaway — build-ignored (dev/spikes). The API was already
# resolved by reading the merged source (see dev/scope-teardown-4372.md); this
# just confirms it end-to-end at runtime.
#
# RUN with the dev shiny loaded (checked out at .claude/worktrees/shiny-dev):
#   Rscript -e 'pkgload::load_all(".claude/worktrees/shiny-dev"); source("dev/spikes/scope-teardown-4372.R")'
#
# Pinned to shiny 1.13.0.9000 / HEAD 44fd783 — re-confirm on bump.

ok   <- function(label, cond) cat(sprintf("[%s] %s\n", if (isTRUE(cond)) "PASS" else "FAIL", label))
info <- function(...) cat(sprintf(...), "\n")

info("shiny version: %s", as.character(packageVersion("shiny")))

session <- tryCatch(shiny::MockShinySession$new(), error = function(e) {
  info("could not build MockShinySession: %s", conditionMessage(e)); NULL
})
if (is.null(session) || !is.function(session$makeScope)) {
  ok("session$makeScope exists (shiny has #4372)", FALSE)
  info("STOP: this shiny lacks #4372. Load .claude/worktrees/shiny-dev.")
  return(invisible())
}

# ---- 1. child scope proxy shape + namespace format -----------------------
child <- session$makeScope(as.character(7L))   # stringified counter token
ok("makeScope(stringified-counter) returns proxy with $destroy",   is.function(child$destroy))
ok("makeScope returns proxy with $onDestroy",                      is.function(child$onDestroy))

# ---- 2. mechanism A: reactiveVal scoped via withReactiveDomain -----------
ok("reactiveVal() has NO `domain` formal (mechanism B absent)",
   !("domain" %in% names(formals(shiny::reactiveVal))))

# ---- 3. scope reactiveVal is actively destroyed (throws) after destroy() --
# Stronger than GC-eligibility: post-destroy, .destroyed is set and any
# get/set raises destroyedReactiveError. This is why irid's teardown order
# MUST be mount -> scope (no lingering reader may touch a destroyed leaf).
fire <- 0L; rv <- NULL
shiny::withReactiveDomain(child, {
  rv <<- shiny::reactiveVal(0L)
  shiny::observe({ rv(); fire <<- fire + 1L }, domain = child)
})
session$flushReact(); base <- fire
rv(1L); session$flushReact()
ok("scoped observe fired on dependency change", fire > base)

child$destroy()
threw <- tryCatch({ rv(2L); FALSE }, error = function(e) grepl("destroyed", conditionMessage(e)))
ok("scope reactiveVal throws on access after destroy() (actively reclaimed)", threw)

# ---- 4. reactiveVal env finalized after destroy + gc ---------------------
fin <- new.env(); fin$hit <- FALSE
child2 <- session$makeScope(as.character(8L))
shiny::withReactiveDomain(child2, {
  rv2 <- shiny::reactiveVal(0L)
  reg.finalizer(environment(rv2), function(e) fin$hit <<- TRUE, onexit = FALSE)
})
child2$destroy(); rm(rv2); gc(); gc()
ok("child-scope reactiveVal env finalized after destroy + gc", fin$hit)
info("   (FAIL may mean a lingering reference, not a broken API — inspect)")

# ---- 5. bonus: user observe() in a body eval is reclaimed ----------------
user_fire <- 0L; trig <- NULL
child3 <- session$makeScope(as.character(9L))
shiny::withReactiveDomain(child3, {
  # Simulate a user-authored observe() inside an Each item body.
  trig <<- shiny::reactiveVal(0L)
  shiny::observe({ trig(); user_fire <<- user_fire + 1L })   # NO explicit domain
})
session$flushReact(); ub <- user_fire
trig(1L); session$flushReact()
ok("user observe (no explicit domain) picked up child as default domain", user_fire > ub)
child3$destroy()
reclaimed <- tryCatch({ trig(2L); FALSE }, error = function(e) grepl("destroyed", conditionMessage(e)))
ok("user observe + its rv reclaimed by child$destroy() (the bonus)", reclaimed)

# ---- 6. pre-#4372 no-op sanity -------------------------------------------
shiny::withReactiveDomain(session, info("withReactiveDomain(session, ...) ran (no-op when already active)"))

info("done.")
