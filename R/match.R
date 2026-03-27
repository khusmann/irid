#' @export
Case <- function(condition, content) {
  list(condition = condition, content = content)
}

#' @export
Default <- function(content) {
  list(condition = function() TRUE, content = content)
}

#' @export
Match <- function(...) {
  cases <- list(...)
  structure(
    list(cases = cases),
    class = "nacre_match"
  )
}
