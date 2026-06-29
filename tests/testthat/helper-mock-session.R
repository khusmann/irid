# Shared unit-test harness (no browser). Auto-sourced by testthat before the
# test files, so any test can use these without redefining them.

# A MockShinySession that captures the custom messages a mount would send.
# `s$msgs()` returns the captured list of {type, message} entries; tests filter
# it for irid-attr / irid-mutate / irid-wire / irid-config to assert behavior.
#
# Render-phase messages (irid-mutate/-attr/-wire/-widget-init) are coalesced into
# a single `irid-batch` frame at flush end (see `irid_send`). `s$msgs()` flattens
# those envelopes back into individual {type, message} entries, so tests see each
# render message in the shape it had before coalescing. `s$raw_msgs()` exposes
# the unflattened stream for tests that assert on the batching itself.
new_fake_session <- function() {
  s <- shiny::MockShinySession$new()
  store <- new.env(parent = emptyenv())
  store$msgs <- list()
  s$sendCustomMessage <- function(type, message) {
    store$msgs[[length(store$msgs) + 1L]] <<- list(type = type, message = message)
    invisible()
  }
  s$msgs <- function() flatten_irid_batch(store$msgs)
  s$raw_msgs <- function() store$msgs
  # Remember the latest fake session so the bare `flushReact()` helper can route
  # through its `s$flushReact()`, which fires `onFlushed` — the render-batch +
  # widget-attr drains ride `session$onFlushed`, and the bare reactive flush
  # alone does not fire it, so without this a batched message never drains.
  .latest_fake_session$s <- s
  s
}

.latest_fake_session <- new.env(parent = emptyenv())
.latest_fake_session$s <- NULL

# Unwrap any `irid-batch` envelope into its ordered ops; pass other messages
# through. Each op `{type, message}` is exactly the message that, pre-coalescing,
# would have been sent on its own.
flatten_irid_batch <- function(msgs) {
  out <- list()
  for (m in msgs) {
    if (identical(m$type, "irid-batch")) {
      for (op in m$message$ops) {
        out[[length(out) + 1L]] <- list(type = op$type, message = op$message)
      }
    } else {
      out[[length(out) + 1L]] <- m
    }
  }
  out
}

# Flush pending reactive invalidations outside an observer context. Routes
# through the latest fake session's `flushReact()` so `onFlushed` fires (a render
# batch armed during the flush gets sent), matching real Shiny's flush ->
# onFlushed sequencing. Falls back to a bare reactive flush before any session.
flushReact <- function() {
  s <- .latest_fake_session$s
  if (is.null(s)) shiny:::flushReact() else s$flushReact()
}
