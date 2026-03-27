#' @export
Each <- function(items, fn) {
  structure(
    list(items = items, fn = fn),
    class = "nacre_each"
  )
}

#' @export
Index <- function(items, fn) {
  structure(
    list(items = items, fn = fn),
    class = "nacre_index"
  )
}
