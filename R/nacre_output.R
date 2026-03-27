nacreApp <- function(fn, ...) {
  ui <- fluidPage(nacreOutput("nacre-app"))
  server <- function(input, output, session) {
    output[["nacre-app"]] <- renderNacre(fn())
  }
  shinyApp(ui, server, ...)
}

nacreOutput <- function(id) {
  tagList(
    uiOutput(id),
    nacre_dependency()
  )
}

renderNacre <- function(expr, env = parent.frame(), quoted = FALSE) {
  func <- shiny::exprToFunction(expr, env, quoted)

  renderUI({
    session <- getDefaultReactiveDomain()
    tag_tree <- isolate(func())

    result <- process_tags(tag_tree)

    session$onFlushed(function() {
      # Set up event listeners
      if (length(result$events) > 0L) {
        event_msgs <- lapply(result$events, function(ev) {
          input_id <- paste0("nacre_ev_", ev$id, "_", ev$event)
          handler <- ev$handler
          nformals <- length(formals(handler))

          observeEvent(session$input[[input_id]], {
            ev_data <- session$input[[input_id]]
            if (nformals == 0L) {
              handler()
            } else if (nformals == 1L) {
              handler(ev_data$value)
            } else {
              handler(ev_data$value, ev_data$id)
            }
          }, ignoreInit = TRUE)

          list(
            id = ev$id,
            event = ev$event,
            inputId = input_id
          )
        })
        session$sendCustomMessage("nacre-events", event_msgs)
      }

      # Set up reactive attribute bindings
      lapply(result$bindings, function(b) {
        observe({
          val <- b$fn()
          session$sendCustomMessage("nacre-attr", list(
            id = b$id,
            attr = b$attr,
            value = val
          ))
        })
      })
    }, once = TRUE)

    result$tag
  })
}
