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
  if (!is_branch_input(initial)) {
    stop("`initial` must be a named list", call. = FALSE)
  }
  build_node(initial, "", root = TRUE)
}

is_branch_input <- function(x) {
  if (!is.list(x)) return(FALSE)
  if (length(x) == 0L) return(TRUE)
  nm <- names(x)
  !is.null(nm) && all(nzchar(nm))
}

build_node <- function(value, path, root = FALSE) {
  if (is_branch_input(value)) {
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
    make_leaf(value)
  }
}

make_leaf <- function(initial_value) {
  rv <- shiny::reactiveVal(initial_value)
  fn <- function(...) {
    if (missing(..1)) rv() else rv(..1)
  }
  class(fn) <- c("reactiveLeaf", "function")
  fn
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
