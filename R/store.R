#' Hierarchical reactive state container
#'
#' Builds a callable hierarchical state tree from a nested list. Bare named
#' lists become navigable `reactiveStore` nodes (every sub-tree is itself a
#' `reactiveStore`); everything else (scalars, vectors, `NULL`, unnamed bare
#' lists, and classed lists such as `data.frame` / tibble) becomes a
#' `reactiveLeaf` backed by a single [shiny::reactiveVal()].
#'
#' Every node is callable: `node()` reads, `node(value)` writes. Leaves
#' replace; store nodes patch (only the keys present in the patch are
#' updated). Unknown keys are an error. Types are not enforced.
#'
#' @param initial A bare named list describing the initial shape. Bare lists
#'   that are empty or unnamed at any position become atomic-list leaves —
#'   a single `reactiveVal` holding the list verbatim. Classed lists (e.g.,
#'   `data.frame`, tibble) are stored opaquely as scalar leaves: their class
#'   is preserved across reads and writes, and write shape is not validated.
#' @return A callable `reactiveStore` node with class
#'   `c("reactiveStore", "function")`. Sub-trees share the same class;
#'   atomic positions are `c("reactiveLeaf", "function")`.
#' @export
reactiveStore <- function(initial) {
  build_node(initial, "", root = TRUE)
}

# A "bare list" is an unclassed list — `list()` but not `data.frame`,
# tibble, or any other S3/S4 classed list-like object. Only bare lists
# are eligible to become store nodes or atomic-list leaves; classed lists
# fall through to opaque scalar leaves.
is_bare_list <- function(value) {
  is.list(value) && !is.object(value)
}

# TRUE = store node, FALSE = leaf (scalar, classed list, or atomic bare
# list); errors on partially-named bare lists, which are neither. Empty
# bare lists always register as atomic-list leaves — store nodes are
# structurally frozen at construction, so an empty store node would be a
# permanent dead-end (no keys to patch, can't grow).
is_branch <- function(value, path) {
  if (!is_bare_list(value)) return(FALSE)
  if (length(value) == 0L) return(FALSE)
  nm <- names(value)
  if (is.null(nm)) return(FALSE)
  if (all(nzchar(nm))) return(TRUE)
  empty_idx <- which(!nzchar(nm))
  stop(sprintf(
    "List at %s is partially named (positions %s have no names). %s",
    if (nzchar(path)) sprintf("'%s'", path) else "store root",
    paste(empty_idx, collapse = ", "),
    "Use a fully named list (store node) or a fully unnamed list (atomic leaf)."
  ), call. = FALSE)
}

build_node <- function(value, path, root = FALSE) {
  if (is_branch(value, path)) {
    keys <- names(value)
    children <- stats::setNames(
      lapply(keys, function(k) {
        child_path <- if (nzchar(path)) paste0(path, "$", k) else k
        build_node(value[[k]], child_path)
      }),
      keys
    )
    make_store(children, keys, path)
  } else {
    if (root) stop("`initial` must be a named list", call. = FALSE)
    make_leaf(value, atomic_list = is_bare_list(value), path = path)
  }
}

make_leaf <- function(initial_value, atomic_list = FALSE, path = "") {
  label <- if (nzchar(path)) sprintf("'%s'", path) else "leaf"
  rv <- shiny::reactiveVal(initial_value)
  fn <- function(...) {
    if (missing(..1)) {
      rv()
    } else {
      val <- ..1
      if (atomic_list) validate_atomic_list_write(val, label)
      rv(val)
    }
  }
  class(fn) <- c("reactiveLeaf", "function")
  fn
}

validate_atomic_list_write <- function(val, label) {
  if (!is.list(val)) {
    stop(sprintf(
      "Atomic-list leaf %s requires an unnamed list, got %s.",
      label, paste(class(val), collapse = "/")
    ), call. = FALSE)
  }
  if (length(val) == 0L) return(invisible())
  nm <- names(val)
  if (is.null(nm)) return(invisible())
  if (all(nzchar(nm))) {
    stop(sprintf(
      "Atomic-list leaf %s does not accept a named list. Use an unnamed list.",
      label
    ), call. = FALSE)
  }
  empty_idx <- which(!nzchar(nm))
  stop(sprintf(
    "Atomic-list leaf %s does not accept a partially-named list (positions %s unnamed). Use a fully unnamed list.",
    label, paste(empty_idx, collapse = ", ")
  ), call. = FALSE)
}

make_store <- function(children, keys, path) {
  label <- if (nzchar(path)) sprintf("'%s'", path) else "root"
  fn <- function(...) {
    if (missing(..1)) {
      stats::setNames(lapply(keys, function(k) children[[k]]()), keys)
    } else {
      patch <- ..1
      validate_write(fn, patch)
      if (length(patch) > 0L) {
        for (k in names(patch)) children[[k]](patch[[k]])
      }
      invisible(NULL)
    }
  }
  class(fn) <- c("reactiveStore", "function")
  fn
}

# Recursively validates a write/patch against the target subtree without
# committing — throws on the first shape violation, otherwise returns
# invisibly. Store nodes enforce: list-shaped, fully named, no unknown
# keys. Leaves enforce: atomic-list shape (when applicable). Used by store
# write paths so a downstream rejection (e.g., a named list arriving at an
# atomic-list leaf five levels deep) leaves siblings unmodified.
validate_write <- function(node, value) {
  env <- environment(node)
  if (inherits(node, "reactiveLeaf")) {
    if (isTRUE(env$atomic_list)) {
      validate_atomic_list_write(value, env$label)
    }
    return(invisible())
  }
  label <- env$label
  if (!is.list(value)) {
    stop(sprintf(
      "Write to %s expected a named list, got %s",
      label, paste(class(value), collapse = "/")
    ), call. = FALSE)
  }
  if (length(value) == 0L) return(invisible())
  patch_keys <- names(value)
  if (is.null(patch_keys) || !all(nzchar(patch_keys))) {
    stop(sprintf(
      "Write to %s expected a named list (got unnamed elements)",
      label
    ), call. = FALSE)
  }
  unknown <- setdiff(patch_keys, env$keys)
  if (length(unknown) > 0L) {
    stop(sprintf(
      "Unknown keys in store node %s: %s",
      label, paste(unknown, collapse = ", ")
    ), call. = FALSE)
  }
  for (k in patch_keys) {
    validate_write(env$children[[k]], value[[k]])
  }
  invisible()
}

#' @export
`$.reactiveStore` <- function(x, name) {
  environment(x)$children[[name]]
}

#' @export
`$.reactiveLeaf` <- function(x, name) {
  NULL
}

# ---- Store-node introspection ----------------------------------------------

#' @export
names.reactiveStore <- function(x) {
  environment(x)$keys
}

#' @export
length.reactiveStore <- function(x) {
  length(environment(x)$keys)
}

#' @export
`[[.reactiveStore` <- function(x, i) {
  env <- environment(x)
  keys <- env$keys
  if (is.numeric(i)) {
    if (length(i) != 1L) {
      stop(
        "`[[` on a reactiveStore requires a single index",
        call. = FALSE
      )
    }
    idx <- as.integer(i)
    if (is.na(idx) || idx < 1L || idx > length(keys)) {
      stop(sprintf(
        "Index %s out of range for store node with %d children",
        format(i), length(keys)
      ), call. = FALSE)
    }
    env$children[[keys[idx]]]
  } else if (is.character(i)) {
    if (length(i) != 1L || is.na(i)) {
      stop(
        "`[[` on a reactiveStore requires a single key",
        call. = FALSE
      )
    }
    if (!(i %in% keys)) {
      stop(sprintf("Unknown key '%s' in store node", i), call. = FALSE)
    }
    env$children[[i]]
  } else {
    stop(
      "`[[` on a reactiveStore requires a string or integer index",
      call. = FALSE
    )
  }
}

#' @export
`[[<-.reactiveStore` <- function(x, i, value) {
  stop(
    "Cannot assign into a reactiveStore with `[[<-`. ",
    "Use `store$key(value)` or `store(list(key = value))`.",
    call. = FALSE
  )
}

#' @export
as.list.reactiveStore <- function(x, ...) {
  # Returns the named list of child callables. `store()` returns resolved
  # values; this returns the callables themselves so that `lapply` (which
  # calls `as.list` on class-bearing objects) can iterate child nodes.
  environment(x)$children
}

#' @export
print.reactiveStore <- function(x, ...) {
  keys <- environment(x)$keys
  cat(sprintf(
    "<reactiveStore> [%d %s: %s]\n",
    length(keys),
    if (length(keys) == 1L) "child" else "children",
    paste(keys, collapse = ", ")
  ))
  invisible(x)
}

# Soft vctrs integration: lets `purrr::imap()` etc. iterate a store node
# directly, without taking vctrs as Imports. The method registers only
# when vctrs is loaded. The proxy is the named list of child callables —
# same as `as.list(store)` — so consumers see the structural list of nodes.
#' @exportS3Method vctrs::vec_proxy
vec_proxy.reactiveStore <- function(x, ...) {
  environment(x)$children
}

#' @export
str.reactiveStore <- function(object, indent.str = "", ...) {
  keys <- environment(object)$keys
  children <- environment(object)$children
  cat("<reactiveStore> with", length(keys), "children\n")
  for (k in keys) {
    child <- children[[k]]
    cat(indent.str, " $ ", k, sep = "")
    if (inherits(child, "reactiveStore")) {
      cat(": ")
      utils::str(child, indent.str = paste0(indent.str, " .."), ...)
    } else {
      val <- shiny::isolate(child())
      cat(": ")
      utils::str(val, ...)
    }
  }
  invisible()
}

# ---- Leaf introspection (errors that point at the right call) --------------

#' @export
print.reactiveLeaf <- function(x, ...) {
  val <- shiny::isolate(x())
  if (is.null(val)) {
    cat("<reactiveStore leaf> = NULL\n")
  } else if (is.atomic(val) && length(val) == 1L) {
    cat(sprintf("<reactiveStore leaf> = %s\n", format(val)))
  } else {
    cat(sprintf(
      "<reactiveStore leaf> [%s, length %d]\n",
      paste(class(val), collapse = "/"), length(val)
    ))
  }
  invisible(x)
}

#' @export
length.reactiveLeaf <- function(x) {
  stop(
    "`length()` is not defined for a reactiveStore leaf. ",
    "Use `length(leaf())` to read the underlying value's length.",
    call. = FALSE
  )
}

#' @export
names.reactiveLeaf <- function(x) {
  stop(
    "`names()` is not defined for a reactiveStore leaf. ",
    "Use `names(leaf())` to read the underlying value's names.",
    call. = FALSE
  )
}

#' @export
`[[.reactiveLeaf` <- function(x, i) {
  stop(
    "`[[` is not defined for a reactiveStore leaf. ",
    "Use `leaf()[[i]]` for a snapshot read, or `Each()` to iterate ",
    "an atomic-list leaf reactively.",
    call. = FALSE
  )
}
