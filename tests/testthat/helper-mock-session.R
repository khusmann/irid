# Shared unit-test harness (no browser). Auto-sourced by testthat before the
# test files, so any test can use these without redefining them.

# A MockShinySession that captures the custom messages a mount would send.
# `s$msgs()` returns the protocol stream tests assert on. There are only three
# server->client messages — `irid-config`, `irid-render`, `irid-ready` — and every
# DOM/widget update of one flush rides one `irid-render` frame as an ordered op
# list (see `irid_send`). `s$msgs()` splices each `irid-render` frame's ops in
# place, so the stream is a flat mix of:
#   - real messages (`irid-config` / `irid-ready`) as `{type, message}`, and
#   - render ops, each as-is — the flat op object with its `kind` and fields.
# Tests filter ops on `m$kind` (e.g. "attr") and read fields directly (`m$attr`,
# `m$value`, `m$gate`); messages on `m$type`. An op has no `$type` and a message
# has no `$kind`, so the two never collide. `s$raw_msgs()` exposes the unflattened
# stream for tests that assert on the `irid-render` frame itself.
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

# Splice each `irid-render` frame's ordered ops into the stream as-is (each op the
# flat object it is on the wire, with its `kind`), passing real messages
# (`irid-config` / `irid-ready`) through unchanged as `{type, message}`.
flatten_irid_render <- function(msgs) {
  out <- list()
  for (m in msgs) {
    if (identical(m$type, "irid-render")) {
      for (op in m$message$ops) out[[length(out) + 1L]] <- op
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
