#' Per-item / per-case reactive scope
#'
#' Wraps a Shiny session into a small "scope" object whose responsibility is
#' to bound the lifetime of reactives and observers created inside per-item
#' (`Each`) or per-case (`Match`) mounts. Every per-item / per-case mount
#' creates one scope at construction; on unmount, `scope$destroy()` tears
#' down everything created against it.
#'
#' **Two implementations, chosen by runtime feature detection.**
#'
#' - **shiny#4372 path** (when `session$onDestroy`/`session$destroy` exist):
#'   `make_scope` allocates a child scope via `session$makeScope(id)`.
#'   Reactive primitives constructed while that child is the default reactive
#'   domain auto-register a weak destroy handle against it, so
#'   `child$destroy()` reclaims observers
#'   **and** `reactiveVal`s in one call. `with_scope(expr)` runs `expr` under
#'   the child domain (`shiny::withReactiveDomain`); `register_observer` is a
#'   no-op (auto-tracked).
#' - **Fallback path** (any shiny without #4372): a thin manual tracker.
#'   Observers register via `register_observer` and are torn down in
#'   `destroy`. `with_scope` is identity — `reactiveVal`s created inside still
#'   leak until session end (no public API to destroy a `reactiveVal`
#'   pre-#4372). This is today's behavior.
#'
#' The seam is forward-compatible: every per-item / per-case reactive is
#' constructed through `with_scope`, so the same call sites reclaim correctly
#' once a user upgrades to a shiny carrying #4372 — no irid change required.
#'
#' **Teardown ordering.** On unmount, callers MUST destroy the per-item
#' / per-case `mount` handle *before* the scope. The mount's observers
#' (auto-bind bindings, event handlers) read mini-store / slot-accessor
#' leaves that live in the scope; under #4372 a destroyed leaf *throws* on
#' access (it is actively destroyed, not lazily GC'd), so tearing the scope
#' down first would make those observers error on their next read. The order
#' is mount → scope at every site that owns both.
#'
#' shiny#4372: <https://github.com/rstudio/shiny/pull/4372> merged 2026-05-29,
#' not yet on CRAN as of this writing. Verified against shiny 1.13.0.9000
#' (HEAD 44fd783); re-confirm method names / weak-ref semantics on bump. Every
#' site that depends on this seam is tagged `# shiny#4372:` for grep-ability.
#'
#' @param session A Shiny session, a child scope proxy, or `NULL` in tests.
#' @param id Scope identifier for the shiny#4372 child scope (a non-empty
#'   string; the caller's element/wrapper counter token). Required — every
#'   call site already has a unique counter token. Unused on the fallback
#'   path, but always supplied so the scope's identity is explicit.
#' @return A list with `session`, `register_observer(obs)`,
#'   `with_scope(expr)`, and `destroy()`.
#' @keywords internal
make_scope <- function(session, id) {
  # shiny#4372: feature-detect the scoped-teardown API on `onDestroy`/`destroy`,
  # the session methods #4372 adds. Reactives constructed under the child scope's
  # domain register their weak destroy handle against the proxy's `onDestroy`.
  has_scope <- !is.null(session) &&
    is.function(session$onDestroy) &&
    is.function(session$destroy)

  if (has_scope) {
    # shiny#4372: child scope auto-tracks observers AND reactiveVals
    # constructed under its reactive domain; `destroy()` cascades to both.
    child <- session$makeScope(id)
    list(
      session = child,
      # Observers created under the child domain auto-register — no-op the
      # manual tracker (call sites still call it; harmless).
      register_observer = function(obs) invisible(),
      # Construct `expr` under the child reactive domain so reactiveVals
      # (which take no `domain =` arg) register their weak destroy handle
      # against the child. Lazy: `expr` is a promise, forced inside the domain.
      with_scope = function(expr) shiny::withReactiveDomain(child, expr),
      # The proxy self-destruct (no-arg) — `session$destroy(id)` errors on the
      # root session unless given a namespace; the proxy form is the documented
      # child-teardown path.
      destroy = function() child$destroy()
    )
  } else {
    # Fallback: manual observer tracker; reactiveVals leak until session end.
    observers <- list()
    list(
      session = session,
      register_observer = function(obs) {
        observers[[length(observers) + 1L]] <<- obs
      },
      # Identity (forcing the promise) — preserves today's exact behavior:
      # reactiveVals pick up the ambient domain, no #4372 child to attach to.
      with_scope = function(expr) expr,
      destroy = function() {
        # shiny#4372: manual observer teardown — replaced by the scope cascade.
        for (obs in observers) obs$destroy()
        observers <<- list()
        invisible()
      }
    )
  }
}
