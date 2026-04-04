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
#' @return A irid control-flow node.
#' @export
When <- function(condition, yes, otherwise = NULL) {
  structure(
    list(condition = condition, yes = yes, otherwise = otherwise),
    class = "irid_when"
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
#' @param fn A function of `(item)` or `(item, index)` where `item` is the
#'   plain item value and `index` is a [shiny::reactiveVal()] that tracks the
#'   item's current position (updated on reorder). Should return a tag tree.
#' @param by A function that extracts a comparable key from each item, used
#'   for keyed reordering. Keys must be unique. Defaults to [identity()].
#' @return A irid control-flow node.
#' @export
Each <- function(items, fn, by = identity) {
  structure(
    list(items = items, by = by, fn = fn),
    class = "irid_each"
  )
}

#' Render a list with positional updates
#'
#' Like [Each()], but when list values change without a length change, each
#' slot's reactive value is updated in place rather than recreating the DOM.
#' When the list grows, new slots are appended; when it shrinks, trailing
#' slots are destroyed.
#'
#' @param items A reactive expression that returns a list.
#' @param fn A function of `(item)` or `(item, index)` where `item` is a
#'   [shiny::reactiveVal()] for the item at that position and `index` is its
#'   fixed position (plain integer). Should return a tag tree.
#' @return A irid control-flow node.
#' @export
Index <- function(items, fn) {
  structure(
    list(items = items, fn = fn),
    class = "irid_index"
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
#' @return A irid control-flow node.
#' @export
Match <- function(...) {
  cases <- list(...)
  structure(
    list(cases = cases),
    class = "irid_match"
  )
}

# -- Shiny output wrapper -------------------------------------------------

#' Embed a Shiny render/output pair in a irid tag tree
#'
#' A generic wrapper that pairs a Shiny render function with its
#' corresponding output function. For common cases, use the convenience
#' wrappers [PlotOutput()], [TableOutput()], or [DTOutput()].
#'
#' @param render_fn A Shiny render function (e.g. `renderPlot`).
#' @param output_fn A Shiny output function (e.g. `plotOutput`).
#' @param fn A function passed to `render_fn`.
#' @param ... Additional arguments passed to `output_fn`.
#' @return A irid output node.
#' @export
Output <- function(render_fn, output_fn, fn, ...) {
  render_call <- render_fn({ fn() })
  result <- list(
    output_fn = output_fn,
    output_fn_args = list(...),
    render_call = render_call
  )
  class(result) <- "irid_output"
  result
}

#' Embed a plot output in a irid tag tree
#'
#' Shorthand for `Output(renderPlot, plotOutput, ...)`.
#'
#' @param fn A function that produces a plot.
#' @param ... Additional arguments passed to [shiny::plotOutput()].
#' @return A irid output node.
#' @export
PlotOutput <- function(fn, ...) {
  Output(shiny::renderPlot, shiny::plotOutput, fn, ...)
}

#' Embed a table output in a irid tag tree
#'
#' Shorthand for `Output(renderTable, tableOutput, ...)`.
#'
#' @param fn A function that produces a table.
#' @param ... Additional arguments passed to [shiny::tableOutput()].
#' @return A irid output node.
#' @export
TableOutput <- function(fn, ...) {
  Output(shiny::renderTable, shiny::tableOutput, fn, ...)
}

#' Embed a DT DataTable output in a irid tag tree
#'
#' Shorthand for `Output(DT::renderDT, DT::DTOutput, ...)`. Requires the
#' **DT** package.
#'
#' @param fn A function that produces a DataTable.
#' @param ... Additional arguments passed to `DT::DTOutput()`.
#' @return A irid output node.
#' @export
DTOutput <- function(fn, ...) {
  if (!requireNamespace("DT", quietly = TRUE)) {
    stop("Package 'DT' is required for DTOutput(). Install it with install.packages('DT').")
  }
  Output(DT::renderDT, DT::DTOutput, fn, ...)
}
