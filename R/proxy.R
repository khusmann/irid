#' Wrap a callable with custom read and write behavior
#'
#' Wraps a target callable with optional `get` (read transform) and `set`
#' (write handler). The proxy is itself a callable: `proxy()` reads through
#' `get`, `proxy(value)` calls `set`. Auto-bind treats the proxy like any
#' other callable, so it composes with `value`/`checked`/`selected` props
#' without any special handling.
#'
#' `set` is a side-effectful handler, not a pure transform. It receives the
#' incoming value and decides what to do — write to the target, write a
#' transformed value, set an error flag, trigger a side effect, or drop the
#' write entirely. Because `set` is a closure, it can read sibling state for
#' cross-field validation.
#'
#' Pass `set = NULL` to make the proxy read-only — writes are silently
#' dropped. With auto-bind, this lets the input snap back to the current
#' value via the optimistic-update protocol.
#'
#' Proxies compose: another `reactiveProxy` can wrap the result of one,
#' since a proxy is itself a callable.
#'
#' @param target A callable (function). Typically a `reactiveVal`, a
#'   `reactiveStore` leaf, or another `reactiveProxy`.
#' @param get A unary function applied to `target()` on read. Defaults to
#'   [base::identity()] (no read transform).
#' @param set A unary function called with the incoming value on write, or
#'   `NULL` to drop writes silently. Defaults to `\(v) target(v)`
#'   (pass-through write to the target).
#' @return A callable with class `c("reactiveProxy", "function")`.
#' @export
reactiveProxy <- function(target, get = identity, set = \(v) target(v)) {
  if (!is.function(target)) {
    stop("`target` must be a callable (function)", call. = FALSE)
  }
  if (!is.function(get)) {
    stop("`get` must be a function", call. = FALSE)
  }
  if (!is.null(set) && !is.function(set)) {
    stop("`set` must be a function or NULL", call. = FALSE)
  }
  force(target)
  force(get)
  force(set)
  fn <- function(...) {
    if (missing(..1)) {
      get(target())
    } else {
      if (!is.null(set)) set(..1)
      invisible(NULL)
    }
  }
  class(fn) <- c("reactiveProxy", "function")
  fn
}

#' @export
print.reactiveProxy <- function(x, ...) {
  if (is.null(environment(x)$set)) {
    cat("<reactiveProxy> (read-only)\n")
  } else {
    cat("<reactiveProxy>\n")
  }
  invisible(x)
}
