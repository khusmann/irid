#' Wrap a reader and optional writer as a callable
#'
#' Builds a callable proxy from a 0-arg `get` reader and an optional
#' 1-arg `set` writer. The proxy is itself a callable: `proxy()` invokes
#' `get()`, `proxy(value)` invokes `set(value)`. Auto-bind treats the
#' proxy like any other callable, so it composes with `value` and
#' `checked` props without any special handling.
#'
#' `set` is a side-effectful handler, not a pure transform. It receives
#' the incoming value and decides what to do — write to a target, write
#' a transformed value, set an error flag, trigger a side effect, or
#' drop the write entirely. Because `set` is a closure, it can read
#' sibling state for cross-field validation.
#'
#' Pass `set = NULL` (or omit it) to make the proxy read-only — writes
#' are silently dropped. With auto-bind, this lets the input snap back
#' to the current value via the optimistic-update protocol.
#'
#' Proxies compose: a proxy is itself a callable (0-arg → `get`, 1-arg →
#' `set`), so another `reactiveProxy` can use it as either its `get` or
#' its `set`.
#'
#' @param get A 0-arg callable returning the read value. Typically a
#'   `reactiveVal`, a `reactiveStore` leaf, another `reactiveProxy`, or
#'   a closure like `\() transform(rv())`.
#' @param set A 1-arg function called with the incoming value on write,
#'   or `NULL` for a read-only proxy. Defaults to `NULL`.
#' @return A callable with class `c("reactiveProxy", "reactive", "function")`.
#' @export
reactiveProxy <- function(get, set = NULL) {
  if (!is.function(get)) {
    stop("`get` must be a function", call. = FALSE)
  }
  if (!is.null(set) && !is.function(set)) {
    stop("`set` must be a function or NULL", call. = FALSE)
  }
  force(get)
  force(set)
  fn <- function(...) {
    if (missing(..1)) {
      get()
    } else {
      if (!is.null(set)) set(..1)
      invisible(NULL)
    }
  }
  class(fn) <- c("reactiveProxy", "reactive", "function")
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
