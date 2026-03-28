# -- Conditional rendering ------------------------------------------------

#' Conditionally render content
#'
#' Renders `yes` when `condition` is `TRUE`, and `otherwise` (if provided)
#' when it is `FALSE`. The active branch is fully mounted and the inactive
#' branch is destroyed.
#'
#' @param condition A reactive expression that returns a logical value.
#' @param yes Tag tree to render when the condition is `TRUE`.
#' @param otherwise Optional tag tree to render when the condition is `FALSE`.
#' @return A nacre control-flow node.
#' @export
When <- function(condition, yes, otherwise = NULL) {
  structure(
    list(condition = condition, yes = yes, otherwise = otherwise),
    class = "nacre_when"
  )
}

# -- List rendering -------------------------------------------------------

#' Render a list by recreating all items
#'
#' Iterates over a reactive list and calls `fn` for each item. When the list
#' changes, all items are destroyed and recreated. For a version that updates
#' items in place, see [Index()].
#'
#' @param items A reactive expression that returns a list.
#' @param fn A function of `(item, index)` where `item` is a zero-argument
#'   accessor for the item value and `index` is its position. Should return a
#'   tag tree.
#' @return A nacre control-flow node.
#' @export
Each <- function(items, fn) {
  # TODO: implement keyed-by-identity rendering (reorder DOM nodes instead

  # of recreating) to preserve per-item state across list mutations.
  structure(
    list(items = items, fn = fn),
    class = "nacre_each"
  )
}

#' Render a list with positional updates
#'
#' Like [Each()], but when list values change without a length change, each
#' slot's reactive value is updated in place rather than recreating the DOM.
#' A full rebuild occurs only when the list length changes.
#'
#' @param items A reactive expression that returns a list.
#' @param fn A function of `(item, index)` where `item` is a
#'   [shiny::reactiveVal()] for the item at that position and `index` is its
#'   position. Should return a tag tree.
#' @return A nacre control-flow node.
#' @export
Index <- function(items, fn) {
  # TODO: implement incremental add/remove instead of full rebuild on
  # length change, so existing slots keep their observers.
  structure(
    list(items = items, fn = fn),
    class = "nacre_index"
  )
}

# -- Pattern matching -----------------------------------------------------

#' Define a case for [Match()]
#'
#' @param condition A reactive expression that returns a logical value.
#' @param content Tag tree to render when this case matches.
#' @return A case definition (a list).
#' @export
Case <- function(condition, content) {
  list(condition = condition, content = content)
}

#' Define a default (fallback) case for [Match()]
#'
#' A convenience wrapper around [Case()] with a condition that is always
#' `TRUE`. Place this as the last argument to `Match`.
#'
#' @param content Tag tree to render when no other case matches.
#' @return A case definition (a list).
#' @export
Default <- function(content) {
  list(condition = function() TRUE, content = content)
}

#' Render the first matching case
#'
#' Evaluates cases in order and renders the content of the first case whose
#' condition is `TRUE`. Use [Case()] to define conditions and [Default()] for
#' a fallback.
#'
#' @param ... One or more [Case()] or [Default()] values.
#' @return A nacre control-flow node.
#' @export
Match <- function(...) {
  cases <- list(...)
  structure(
    list(cases = cases),
    class = "nacre_match"
  )
}

# -- Shiny output wrapper -------------------------------------------------

#' Embed a Shiny render/output pair in a nacre tag tree
#'
#' A generic wrapper that pairs a Shiny render function with its
#' corresponding output function. For common cases, use the convenience
#' wrappers [PlotOutput()], [TableOutput()], or [DTOutput()].
#'
#' @param render_fn A Shiny render function (e.g. `renderPlot`).
#' @param output_fn A Shiny output function (e.g. `plotOutput`).
#' @param expr An expression passed to `render_fn`.
#' @param ... Additional arguments passed to `output_fn`.
#' @param env The environment in which to evaluate `expr`.
#' @param quoted If `TRUE`, `expr` is already a quoted expression.
#' @return A nacre output node.
#' @export
Output <- function(render_fn, output_fn, expr, ...,
                   env = parent.frame(), quoted = FALSE) {
  expr_q <- if (quoted) expr else substitute(expr)
  render_call <- eval(as.call(list(substitute(render_fn), expr_q)), env)
  result <- list(
    output_fn = output_fn,
    output_fn_args = list(...),
    render_call = render_call
  )
  class(result) <- "nacre_output"
  result
}

#' Embed a plot output in a nacre tag tree
#'
#' Shorthand for `Output(renderPlot, plotOutput, ...)`.
#'
#' @param expr An expression that produces a plot.
#' @param ... Additional arguments passed to [shiny::plotOutput()].
#' @param env The environment in which to evaluate `expr`.
#' @return A nacre output node.
#' @export
PlotOutput <- function(expr, ..., env = parent.frame()) {
  expr_q <- substitute(expr)
  Output(shiny::renderPlot, shiny::plotOutput, expr_q, ..., env = env, quoted = TRUE)
}

#' Embed a table output in a nacre tag tree
#'
#' Shorthand for `Output(renderTable, tableOutput, ...)`.
#'
#' @param expr An expression that produces a table.
#' @param ... Additional arguments passed to [shiny::tableOutput()].
#' @param env The environment in which to evaluate `expr`.
#' @return A nacre output node.
#' @export
TableOutput <- function(expr, ..., env = parent.frame()) {
  expr_q <- substitute(expr)
  Output(shiny::renderTable, shiny::tableOutput, expr_q, ..., env = env, quoted = TRUE)
}

#' Embed a DT DataTable output in a nacre tag tree
#'
#' Shorthand for `Output(DT::renderDT, DT::DTOutput, ...)`. Requires the
#' **DT** package.
#'
#' @param expr An expression that produces a DataTable.
#' @param ... Additional arguments passed to `DT::DTOutput()`.
#' @param env The environment in which to evaluate `expr`.
#' @return A nacre output node.
#' @export
DTOutput <- function(expr, ..., env = parent.frame()) {
  if (!requireNamespace("DT", quietly = TRUE)) {
    stop("Package 'DT' is required for DTOutput(). Install it with install.packages('DT').")
  }
  expr_q <- substitute(expr)
  Output(DT::renderDT, DT::DTOutput, expr_q, ..., env = env, quoted = TRUE)
}

# -- Portal (stub) --------------------------------------------------------

#' Render content into a different location in the DOM (stub)
#'
#' Placeholder for portal functionality. Not yet implemented.
#'
#' @param target The target element ID where content should be rendered.
#' @param content Tag tree to render at the target location.
#' @return A nacre portal node.
#' @export
Portal <- function(target, content) {
  structure(
    list(target = target, content = content),
    class = "nacre_portal"
  )
}

# -- Error boundary (stub) -----------------------------------------------

#' Catch rendering errors and show a fallback (stub)
#'
#' Placeholder for error boundary functionality. Not yet implemented.
#'
#' @param content Tag tree to render.
#' @param fallback Tag tree to render if `content` produces an error.
#' @return A nacre error boundary node.
#' @export
Catch <- function(content, fallback) {
  structure(
    list(content = content, fallback = fallback),
    class = "nacre_catch"
  )
}
