#' Mini-store projection over a record
#'
#' Builds a `reactiveStore`-shaped callable tree that projects a single record
#' out of a parent collection. Reads route through `get_record()`; writes
#' (whole-record or per-field synthetic setters) route through
#' `set_record()`. The mini-store never holds independent state for the
#' record — the parent collection is the single source of truth.
#'
#' Used by `Each` (record items) and `Match` (record bound value) to project
#' fine-grained leaf reactivity out of a coarse-grained parent.
#'
#' Shape is locked at construction from the keys of the record returned by
#' `get_record()`. Writes with unknown keys error, same rule as
#' `reactiveStore`.
#'
#' Internally, each leaf is a `reactiveVal` kept in sync with `get_record()`
#' by an internal observer that diffs and writes only changed leaves. This
#' is what delivers the "only changed fields fire" promise: a parent patch
#' that touches one field invalidates only that one leaf's observers.
#' (Risks decision from PLAN: diff inside the projection rather than at the
#' call site — same effect, smaller surface area for callers to get wrong.)
#'
#' Per-field accessors are `reactiveProxy`s with a `get` reading the
#' internal leaf and a `set` patching the parent record via `set_record`.
#' Auto-bind treats them like any other callable.
#'
#' @param get_record A 0-arg reactive callable that returns the current
#'   record (a fully named list).
#' @param set_record A 1-arg function called with the new record on
#'   whole-record write or after a per-field synthetic setter has built
#'   the patched record.
#' @param scope A scope from [make_scope()]. The internal observer is
#'   created against `scope$session` and registered for cleanup so
#'   `scope$destroy()` tears it down.
#' @return A callable with class `c("reactiveStore", "reactive", "function")`,
#'   shaped like a `reactiveStore` branch — `mini()` reads the record,
#'   `mini(record)` writes it, `mini$field()` reads a leaf, and
#'   `mini$field(v)` writes through the parent.
#' @keywords internal
make_mini_store <- function(get_record, set_record, scope) {
  initial <- shiny::isolate(get_record())
  if (!is.list(initial) || is.null(names(initial)) ||
      any(!nzchar(names(initial)))) {
    stop(
      "make_mini_store: initial record must be a fully named list",
      call. = FALSE
    )
  }
  keys <- names(initial)

  leaves <- stats::setNames(
    lapply(keys, function(k) shiny::reactiveVal(initial[[k]])),
    keys
  )

  # Diff incoming records against the current leaf values and write only
  # changed leaves. Keys present in the locked shape but missing from the
  # incoming record are skipped (shape is fixed; missing keys are user
  # error and surface elsewhere — Match remounts on shape change, Each on
  # keyed reconcile).
  obs <- shiny::observe({
    new_record <- get_record()
    for (k in keys) {
      if (k %in% names(new_record)) {
        new_v <- new_record[[k]]
        old_v <- shiny::isolate(leaves[[k]]())
        if (!identical(old_v, new_v)) {
          leaves[[k]](new_v)
        }
      }
    }
  }, domain = scope$session)
  scope$register_observer(obs)

  accessors <- stats::setNames(
    lapply(keys, function(k) {
      force(k)
      reactiveProxy(
        get = function() leaves[[k]](),
        set = function(v) {
          # `isolate` so a synthetic setter triggered from outside a
          # reactive context still works (event handlers, raw calls in
          # tests) and so the setter never subscribes to the whole record.
          patched <- utils::modifyList(
            shiny::isolate(get_record()), stats::setNames(list(v), k)
          )
          set_record(patched)
        }
      )
    }),
    keys
  )

  fn <- function(...) {
    if (missing(..1)) {
      stats::setNames(lapply(keys, function(k) leaves[[k]]()), keys)
    } else {
      v <- ..1
      validate_mini_store_write(v, keys)
      set_record(v)
      invisible(NULL)
    }
  }

  e <- environment(fn)
  e$keys <- keys
  e$children <- accessors
  e$label <- "mini-store"
  class(fn) <- c("reactiveStore", "reactive", "function")

  fn
}

validate_mini_store_write <- function(value, keys) {
  if (!is.list(value)) {
    stop(
      "mini-store write expected a named list, got ",
      paste(class(value), collapse = "/"),
      call. = FALSE
    )
  }
  if (length(value) == 0L) return(invisible())
  nm <- names(value)
  if (is.null(nm) || any(!nzchar(nm))) {
    stop("mini-store write expected a fully named list", call. = FALSE)
  }
  unknown <- setdiff(nm, keys)
  if (length(unknown) > 0L) {
    stop(
      "Unknown keys in mini-store write: ",
      paste(unknown, collapse = ", "),
      call. = FALSE
    )
  }
  invisible()
}
