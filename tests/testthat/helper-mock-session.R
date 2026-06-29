# Shared unit-test harness (no browser). Auto-sourced by testthat before the
# test files, so any test can use these without redefining them.

# A MockShinySession that captures the custom messages a mount would send.
# `s$msgs()` returns the captured list of {type, message} entries; tests filter
# it for irid-attr / irid-mutate / irid-wire / irid-config to assert behavior.
#
# Every DOM/widget op of one flush is coalesced into a single `irid-render` frame
# at flush end (see `irid_send`). `s$msgs()` flattens that frame's ops back into
# individual {type, message} entries — one per op, `type` = `irid-<kind>`, the
# op's `kind` lifted off `message` — so tests filter on the op's kind and read its
# fields off `message`. `s$raw_msgs()` exposes the unflattened stream for tests
# that assert on the render frame itself.
new_fake_session <- function() {
  s <- shiny::MockShinySession$new()
  store <- new.env(parent = emptyenv())
  store$msgs <- list()
  s$sendCustomMessage <- function(type, message) {
    store$msgs[[length(store$msgs) + 1L]] <<- list(type = type, message = message)
    invisible()
  }
  s$msgs <- function() flatten_irid_render(store$msgs)
  s$raw_msgs <- function() store$msgs
  # Remember the latest fake session so the bare `flushReact()` helper can route
  # through its `s$flushReact()`, which fires `onFlushed` — the render drain rides
  # `session$onFlushed`, and the bare reactive flush alone does not fire it, so
  # without this the render frame never drains.
  .latest_fake_session$s <- s
  s
}

.latest_fake_session <- new.env(parent = emptyenv())
.latest_fake_session$s <- NULL

# Unwrap an `irid-render` frame into its ordered ops; pass other messages through.
# Each op is surfaced as a legacy `{type, message}` entry: `type` = `irid-<kind>`,
# and the op's `kind` field is lifted off so `message` carries only the op's data
# fields (the shape tests assert on).
flatten_irid_render <- function(msgs) {
  out <- list()
  for (m in msgs) {
    if (identical(m$type, "irid-render")) {
      for (op in m$message$ops) {
        kind <- op$kind
        op$kind <- NULL
        out[[length(out) + 1L]] <- list(
          type = paste0("irid-", kind), message = op
        )
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
