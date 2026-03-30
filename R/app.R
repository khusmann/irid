nacre_send_config <- function(session) {
  session$sendCustomMessage("nacre-config", list(
    staleTimeout = getOption("nacre.stale_timeout", default = 200)
  ))
}

#' Create a nacre application
#'
#' Builds a Shiny app from a function that returns a nacre tag tree. The
#' function is called once per session so that each client gets its own
#' reactive state.
#'
#' @param fn A zero-argument function that returns a nacre tag tree (e.g. a
#'   `page_sidebar()` call containing reactive attributes and event handlers).
#' @param ... Additional arguments passed to [shiny::shinyApp()].
#' @return A Shiny app object.
#' @export
nacreApp <- function(fn, ...) {
  # We avoid uiOutput/renderUI here so the app's tag tree is the top-level
  # document (no wrapper div). Instead, ui() and server both call fn() +
  # process_tags() independently — the local ID counter in process_tags
  # ensures they produce matching element IDs.
  ui <- function(req) {
    htmltools::attachDependencies(
      process_tags(fn())$tag,
      nacre_dependency()
    )
  }
  server <- function(input, output, session) {
    nacre_send_config(session)
    result <- process_tags(fn())
    nacre_mount_processed(result, session)
  }
  shiny::shinyApp(ui, server, ...)
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
    shiny::uiOutput(id),
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

  shiny::renderUI({
    session <- shiny::getDefaultReactiveDomain()
    tag_tree <- isolate(func())
    output_name <- shiny::getCurrentOutputInfo()$name
    result <- process_tags(tag_tree, counter = nacre_id_counter(output_name))

    session$onFlushed(function() {
      nacre_send_config(session)
      nacre_mount_processed(result, session)
    }, once = TRUE)

    result$tag
  })
}
