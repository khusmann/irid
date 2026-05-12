#' Per-item / per-case reactive scope
#'
#' Wraps a Shiny session into a small "scope" object whose responsibility is
#' to bound the lifetime of reactives and observers created inside per-item
#' (`Each`) or per-case (`Match`) mounts. Every per-item / per-case mount
#' creates one scope at construction; on unmount, `scope$destroy()` tears
#' down everything registered against it.
#'
#' Today the implementation is a thin manual tracker: observers register
#' themselves via `register_observer()` and are destroyed in
#' `destroy()`. Reactives created inside the scope (mini-store leaves,
#' scalar slot accessors) leak until the parent session ends — there is no
#' public API for destroying a `reactiveVal`.
#'
#' **Teardown ordering.** On unmount, callers MUST destroy the per-item
#' / per-case `mount` handle *before* the scope: the mount's observers
#' (auto-bind bindings, event handlers) read mini-store / slot-accessor
#' leaves that live in the scope, so tearing the scope down first
#' would leave the mount's observers firing against dead state during
#' the same flush. The order is mount → scope at every site that owns
#' both.
#'
#' shiny#4372: once <https://github.com/rstudio/shiny/pull/4372> merges,
#' `make_scope` becomes a one-line wrapper around `session$makeSubdomain()`
#' and the new subdomain teardown handles observers *and* reactives in one
#' call. The manual-tracking body of `make_scope`, the per-item observer
#' registrations in `mount.R`, and the manual-observer cleanup loop in
#' `irid_mount_processed` all become redundant at that point — every site
#' that depends on this shim is tagged `# shiny#4372:` for grep-ability.
#'
#' @param session A Shiny session, or `NULL` in tests.
#' @return A list with `session`, `register_observer(obs)`, and `destroy()`.
#' @keywords internal
make_scope <- function(session) {
  observers <- list()
  list(
    session = session,
    register_observer = function(obs) {
      observers[[length(observers) + 1L]] <<- obs
    },
    destroy = function() {
      # shiny#4372: manual observer teardown — replaced by subdomain cascade.
      for (obs in observers) obs$destroy()
      observers <<- list()
      invisible()
    }
  )
}
