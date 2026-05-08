#' Hierarchical reactive state container
#'
#' Builds a callable hierarchical state tree from a nested list. Named lists
#' become navigable branches; everything else (scalars, vectors, `NULL`,
#' unnamed lists) becomes a leaf backed by a single [shiny::reactiveVal()].
#'
#' Every node is callable: `node()` reads, `node(value)` writes. Leaves
#' replace; branches patch (only the keys present in the patch are updated).
#' Unknown keys on a branch write are an error. Types are not enforced.
#'
#' @param initial A named list describing the initial shape. Unnamed lists
#'   at any position are stored atomically as a single `reactiveVal`.
#' @return A callable root branch with class `c("reactiveStore",
#'   "reactiveBranch", "function")`.
#' @export
reactiveStore <- function(initial) {
  build_node(initial, "", root = TRUE)
}

# TRUE = branch, FALSE = leaf (scalar or atomic-list); errors on
# partially-named lists, which are neither.
is_branch <- function(value, path) {
  if (!is.list(value)) return(FALSE)
  if (length(value) == 0L) return(TRUE)
  nm <- names(value)
  if (is.null(nm)) return(FALSE)
  if (all(nzchar(nm))) return(TRUE)
  empty_idx <- which(!nzchar(nm))
  stop(sprintf(
    "List at %s is partially named (positions %s have no names). %s",
    if (nzchar(path)) sprintf("'%s'", path) else "store root",
    paste(empty_idx, collapse = ", "),
    "Use a fully named list (branch) or a fully unnamed list (atomic leaf)."
  ), call. = FALSE)
}

build_node <- function(value, path, root = FALSE) {
  if (is_branch(value, path)) {
    keys <- names(value)
    if (is.null(keys)) keys <- character(0)
    children <- stats::setNames(
      lapply(keys, function(k) {
        child_path <- if (nzchar(path)) paste0(path, "$", k) else k
        build_node(value[[k]], child_path)
      }),
      keys
    )
    make_branch(children, keys, path, root = root)
  } else {
    if (root) stop("`initial` must be a named list", call. = FALSE)
    make_leaf(value, atomic_list = is.list(value), path = path)
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
  class(fn) <- if (atomic_list) {
    c("reactiveAtomicLeaf", "reactiveLeaf", "function")
  } else {
    c("reactiveLeaf", "function")
  }
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

make_branch <- function(children, keys, path, root = FALSE) {
  label <- if (nzchar(path)) sprintf("'%s'", path) else "root"
  fn <- function(...) {
    if (missing(..1)) {
      if (length(keys) == 0L) {
        list()
      } else {
        stats::setNames(lapply(keys, function(k) children[[k]]()), keys)
      }
    } else {
      patch <- ..1
      if (!is.list(patch)) {
        stop(sprintf(
          "Branch write to %s expected a named list, got %s",
          label, paste(class(patch), collapse = "/")
        ), call. = FALSE)
      }
      if (length(patch) > 0L) {
        patch_keys <- names(patch)
        if (is.null(patch_keys) || !all(nzchar(patch_keys))) {
          stop(sprintf(
            "Branch write to %s expected a named list (got unnamed elements)",
            label
          ), call. = FALSE)
        }
        unknown <- setdiff(patch_keys, keys)
        if (length(unknown) > 0L) {
          stop(sprintf(
            "Unknown keys in store node %s: %s",
            label, paste(unknown, collapse = ", ")
          ), call. = FALSE)
        }
        for (k in patch_keys) children[[k]](patch[[k]])
      }
      invisible(NULL)
    }
  }
  class(fn) <- if (root) {
    c("reactiveStore", "reactiveBranch", "function")
  } else {
    c("reactiveBranch", "function")
  }
  fn
}

#' @export
`$.reactiveBranch` <- function(x, name) {
  environment(x)$children[[name]]
}

#' @export
`$.reactiveLeaf` <- function(x, name) {
  NULL
}

# ---- Branch introspection ---------------------------------------------------

#' @export
names.reactiveBranch <- function(x) {
  environment(x)$keys
}

#' @export
length.reactiveBranch <- function(x) {
  length(environment(x)$keys)
}

#' @export
`[[.reactiveBranch` <- function(x, i) {
  env <- environment(x)
  keys <- env$keys
  if (is.numeric(i)) {
    if (length(i) != 1L) {
      stop("`[[` on a reactiveStore branch requires a single index",
           call. = FALSE)
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
      stop("`[[` on a reactiveStore branch requires a single key",
           call. = FALSE)
    }
    if (!(i %in% keys)) {
      stop(sprintf("Unknown key '%s' in store node", i), call. = FALSE)
    }
    env$children[[i]]
  } else {
    stop("`[[` on a reactiveStore branch requires a string or integer index",
         call. = FALSE)
  }
}

#' @export
`[[<-.reactiveBranch` <- function(x, i, value) {
  stop(
    "Cannot assign into a reactiveStore branch with `[[<-`. ",
    "Use `branch$key(value)` or `branch(list(key = value))`.",
    call. = FALSE
  )
}

#' @export
as.list.reactiveBranch <- function(x, ...) {
  # Returns the named list of child callables. `branch()` returns resolved
  # values; this returns the callables themselves so that `lapply` (which
  # calls `as.list` on class-bearing objects) can iterate child nodes.
  environment(x)$children
}

#' @export
print.reactiveBranch <- function(x, ...) {
  keys <- environment(x)$keys
  if (length(keys) == 0L) {
    cat("<reactiveStore branch> [0 children]\n")
  } else {
    cat(sprintf(
      "<reactiveStore branch> [%d %s: %s]\n",
      length(keys),
      if (length(keys) == 1L) "child" else "children",
      paste(keys, collapse = ", ")
    ))
  }
  invisible(x)
}

# Soft vctrs integration: lets `purrr::imap()` etc. iterate a branch directly,
# without taking vctrs as Imports. The method registers only when vctrs is
# loaded. The proxy is the named list of child callables — same as
# `as.list(branch)` — so consumers see the structural list of nodes.
#' @exportS3Method vctrs::vec_proxy
vec_proxy.reactiveBranch <- function(x, ...) {
  environment(x)$children
}

#' @export
str.reactiveBranch <- function(object, indent.str = "", ...) {
  keys <- environment(object)$keys
  children <- environment(object)$children
  cat("<reactiveStore branch> with", length(keys), "children\n")
  for (k in keys) {
    child <- children[[k]]
    cat(indent.str, " $ ", k, sep = "")
    if (inherits(child, "reactiveBranch")) {
      cat(": ")
      str(child, indent.str = paste0(indent.str, " .."), ...)
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
