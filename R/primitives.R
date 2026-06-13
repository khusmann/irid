# -- Conditional rendering ------------------------------------------------

#' Conditionally render content
#'
#' Renders the `yes` branch when `condition` is `TRUE`, and `otherwise`
#' (if provided) when it is `FALSE`. The active branch is fully mounted
#' and the inactive branch is destroyed.
#'
#' Conceptually a fixed-shape binary specialization of [Match()]:
#' `When(\() cond, \() yes, \() no)` is equivalent to
#' `Match(\() cond, Case(TRUE, \() yes), Case(FALSE, \() no))`.
#'
#' Bodies are 0-arg functions that return tag trees — not tag trees
#' directly. `When` mounts and unmounts the active branch on transition,
#' so each activation must construct a fresh tag tree (the previous
#' branch's closures were torn down with its reactives). Reach for
#' [Match()] when the branch needs to consume the dispatching value.
#'
#' @param condition A reactive expression that returns a logical value.
#' @param yes A 0-arg function returning the tag tree to render when the
#'   condition is `TRUE`.
#' @param otherwise An optional 0-arg function returning the tag tree to
#'   render when the condition is `FALSE`. With `NULL`, nothing mounts on
#'   the false branch.
#' @return A irid control-flow node.
#' @export
When <- function(condition, yes, otherwise = NULL) {
  if (!is_function(yes)) {
    cli::cli_abort(c(
      "{.arg yes} must be a 0-arg function returning a tag tree, \\
       e.g. {.code \\() tags$div(...)}.",
      "x" = "You supplied {.obj_type_friendly {yes}}."
    ))
  }
  if (!is.null(otherwise) && !is_function(otherwise)) {
    cli::cli_abort(c(
      "{.arg otherwise} must be a 0-arg function returning a tag tree or {.code NULL}.",
      "x" = "You supplied {.obj_type_friendly {otherwise}}."
    ))
  }
  structure(
    list(condition = condition, yes = yes, otherwise = otherwise),
    class = "irid_when"
  )
}

# -- List rendering -------------------------------------------------------

#' Render a reactive list
#'
#' Iterates over a reactive list and calls `fn` for each item. The
#' callback receives a per-item callable (a mini-store for record items,
#' a scalar accessor for atomic items) and an optional position
#' accessor. The reconciliation strategy is selected by `by`:
#'
#' - **Positional** (`by = NULL`, the default) — slot *i* is slot *i*.
#'   The list can grow or shrink at the end; in-place value changes
#'   update each slot's accessor without DOM recreation.
#' - **Keyed** (`by = \(x) x$id`) — items are tracked across reorders,
#'   adds, and removes by their key. Kept items propagate new values
#'   through their mini-store (only changed leaves fire); reordered
#'   items have their DOM nodes moved (no recreation).
#'
#' Records are projected as a per-item mini-store: `item()` reads the
#' whole record, `item(record)` writes it back, `item$field()` reads a
#' leaf, and `item$field(v)` is a synthetic setter that writes through
#' the parent. Scalars are passed as a per-item callable: `item()` reads,
#' `item(value)` writes back to the parent's slot.
#'
#' Records may be heterogeneous in shape — different leaf trees per
#' entry. Each slot's mini-store is sized to its own item, and a
#' [Match()] inside the body dispatches on the discriminator:
#'
#' ```r
#' Each(state$blocks, by = \(b) b$id, \(block) {
#'   Match(block,
#'     Case(\(b) b$type == "heading",   \(b) Heading(b)),
#'     Case(\(b) b$type == "paragraph", \(b) Paragraph(b)),
#'     Case(\(b) b$type == "todo",      \(b) Todo(b))
#'   )
#' })
#' ```
#'
#' When a record's shape changes (different key set, or a sub-record's
#' shape shifts), that one entry is torn down and rebuilt with the new
#' mini-store. Shape-stable updates use the fine-grained in-place path.
#'
#' Mixing records and scalars in the same list is rejected at flush
#' time as a likely data-modeling slip — wrap scalars in
#' `list(value = ...)` to mix them.
#'
#' @param items A reactive expression that returns a list.
#' @param fn A function of `(item)`, `(item, pos)`, or `()`. `item` is
#'   the per-item callable (mini-store or scalar accessor); `pos` is a
#'   0-arg reactive accessor returning the item's current 1-indexed
#'   slot. `pos` is constant under `by = NULL` (positional identity)
#'   and live under `by = fn` (fires on reorder).
#' @param by `NULL` for positional reconciliation, or a function that
#'   extracts a unique comparable key from each item for keyed
#'   reconciliation.
#' @return A irid control-flow node.
#' @export
Each <- function(items, fn, by = NULL) {
  if (!is_function(items)) {
    cli::cli_abort("{.arg items} must be a callable, e.g. {.code reactiveVal} or {.code \\() ...}.")
  }
  check_function(fn)
  check_function(by, allow_null = TRUE)
  structure(
    list(items = items, by = by, fn = fn),
    class = "irid_each"
  )
}

# -- Pattern matching -----------------------------------------------------

#' Define a case for [Match()]
#'
#' @param predicate One of: a function `\(v) cond` of the bound value, a
#'   function `\() cond` ignoring the bound value (cross-cutting), or a
#'   literal value (matched against the bound value via [identical()]).
#' @param body A function `\(v) tag_tree` or `\() tag_tree` that returns
#'   the tag tree to render when this case is active. The function is
#'   called fresh on each case activation — the active case's reactives
#'   and DOM are torn down on transition, so a tag tree captured outside
#'   the function would reference dead closures.
#' @return A case definition (a list).
#' @export
Case <- function(predicate, body) {
  if (!is_function(body)) {
    cli::cli_abort(c(
      "{.arg body} must be a function returning a tag tree, \\
       e.g. {.code \\() tags$div(...)}.",
      "x" = "You supplied {.obj_type_friendly {body}}."
    ))
  }
  list(predicate = predicate, body = body)
}

#' Define a default (fallback) case for [Match()]
#'
#' Sugar for `Case(\() TRUE, body)` — matches when no earlier `Case` does.
#' Place this as the last argument to `Match`.
#'
#' @param body A function returning the tag tree to render when no other
#'   case matches. Same arity rules as [Case()] body.
#' @return A case definition (a list).
#' @export
Default <- function(body) {
  Case(function() TRUE, body)
}

#' Render the first matching case
#'
#' Evaluates cases in order against a bound value and renders the body of
#' the first case whose predicate is `TRUE`. Records are projected as a
#' mini-store for the active case's body; scalars are passed as the bare
#' callable. On active-case change, the previous case is torn down (its
#' reactives, DOM, and mini-store) and the new case is mounted fresh.
#'
#' Use a choice function as the leading callable to fold unrelated reactive
#' state into a tagged variant on the fly:
#'
#' ```r
#' Match(\() if (loading()) list(tag = "loading") else list(tag = "data", x = data()),
#'   Case(\(r) r$tag == "loading", \() Spinner()),
#'   Case(\(r) r$tag == "data",    \(r) Items(r$x))
#' )
#' ```
#'
#' Conceptually, [When()] is a fixed-shape binary specialization of `Match`.
#'
#' @param callable The bound value — any 0-arg callable. Records (named
#'   lists) are projected as a mini-store; scalars are passed as the bare
#'   callable.
#' @param ... One or more [Case()] / [Default()] values.
#' @return A irid control-flow node.
#' @export
Match <- function(callable, ...) {
  if (!is_function(callable)) {
    cli::cli_abort(c(
      "{.fn Match} requires a leading callable: a {.code reactiveVal}, \\
       {.code reactive}, store leaf, mini-store, or {.code \\() ...} closure.",
      "x" = "You supplied {.obj_type_friendly {callable}}."
    ))
  }
  cases <- lapply(list(...), normalize_match_case)
  structure(
    list(callable = callable, cases = cases),
    class = "irid_match"
  )
}

# Normalises a Case's predicate into a function. Literals become equality
# matches via `identical`. Function-shaped predicates are stored as-is and
# their arity is read at dispatch time (0-arg → cross-cutting,
# 1-arg → predicate of bound value).
normalize_match_case <- function(case) {
  pred <- case$predicate
  if (!is_function(pred)) {
    literal <- pred
    pred <- function(v) identical(v, literal)
  }
  list(predicate = pred, body = case$body)
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
    cli::cli_abort(c(
      "The {.pkg DT} package is required for {.fn DTOutput}.",
      "i" = 'Install it with {.run install.packages("DT")}.'
    ))
  }
  Output(DT::renderDT, DT::DTOutput, fn, ...)
}
