#' Create a nacre application
#'
#' Builds a Shiny app from a nacre tag tree. The tag tree is processed at build
#' time into static HTML; reactive bindings and event handlers are mounted
#' automatically on the server side.
#'
#' @param tag_tree A nacre tag tree (e.g. a `page_sidebar()` call containing
#'   reactive attributes and event handlers).
#' @param ... Additional arguments passed to [shiny::shinyApp()].
#' @return A Shiny app object.
#' @export
nacreApp <- function(tag_tree, ...) {
  result <- process_tags(tag_tree)
  ui <- htmltools::attachDependencies(result$tag, nacre_dependency())
  server <- function(input, output, session) {
    nacre_mount_processed(result, session)
  }
  shinyApp(ui, server, ...)
}

#' Create a nacre UI output placeholder
#'
#' Creates a [shiny::uiOutput()] with the nacre JavaScript dependency
#' attached. Use this in a standard Shiny UI to mark where [renderNacre()]
#' should inject its content.
#'
#' @param id The output ID, matching the corresponding `renderNacre` call.
#' @return An HTML tag with the nacre dependency.
#' @export
nacreOutput <- function(id) {
  htmltools::attachDependencies(
    uiOutput(id),
    nacre_dependency()
  )
}

#' Render nacre content inside a Shiny app
#'
#' A render function for use with [nacreOutput()]. Evaluates `expr` to
#' produce a nacre tag tree, processes it, and mounts reactive bindings and
#' event handlers after the UI is flushed.
#'
#' @param expr An expression that returns a nacre tag tree.
#' @param env The environment in which to evaluate `expr`.
#' @param quoted If `TRUE`, `expr` is already a quoted expression.
#' @return A [shiny::renderUI()] result.
#' @export
renderNacre <- function(expr, env = parent.frame(), quoted = FALSE) {
  func <- shiny::exprToFunction(expr, env, quoted)

  renderUI({
    session <- getDefaultReactiveDomain()
    tag_tree <- isolate(func())
    result <- process_tags(tag_tree)

    session$onFlushed(function() {
      nacre_mount_processed(result, session)
    }, once = TRUE)

    result$tag
  })
}
