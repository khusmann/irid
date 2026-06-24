# Shared unit-test harness (no browser). Auto-sourced by testthat before the
# test files, so any test can use these without redefining them.

# A MockShinySession that captures the custom messages a mount would send.
# `s$msgs()` returns the captured list of {type, message} entries; tests filter
# it for irid-attr / irid-swap / irid-events / irid-config to assert behavior.
new_fake_session <- function() {
  s <- shiny::MockShinySession$new()
  store <- new.env(parent = emptyenv())
  store$msgs <- list()
  s$sendCustomMessage <- function(type, message) {
    store$msgs[[length(store$msgs) + 1L]] <<- list(type = type, message = message)
    invisible()
  }
  s$msgs <- function() store$msgs
  s
}

# Flush pending reactive invalidations outside an observer context.
flushReact <- function() shiny:::flushReact()
