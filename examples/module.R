# Shiny Modules
#
# nacre components compose naturally with standard Shiny modules. Use
# `nacreOutput()` and `renderNacre()` to embed a nacre component tree inside a
# module's UI and server functions, exactly like any other Shiny output. The
# reactive state lives inside the module's server function, so each module
# instance is fully independent.
#
# This example instantiates two counter modules side by side. Each has its own
# slider, reset button, and a `verbatimTextOutput` showing the server-side
# value — confirming that state is isolated per instance.

library(shiny)
library(bslib)
library(nacre)

Counter <- function(count) {
  tags$div(
    tags$h2(
      class = "text-center",
      \() paste("Count:", count())
    ),
    tags$input(
      type = "range", min = 0, max = 100,
      class = "form-range",
      value = count,
      onInput = \(event) count(event$valueAsNumber)
    ),
    tags$button(
      class = "btn btn-outline-secondary btn-sm",
      disabled = \() count() == 0,
      onClick = \() count(0),
      "Reset"
    )
  )
}

counterUI <- function(id) {
  ns <- NS(id)
  card(
    card_header(id),
    card_body(
      nacreOutput(ns("counter")),
      verbatimTextOutput(ns("debug"))
    )
  )
}

counterServer <- function(id) {
  moduleServer(id, function(input, output, session) {
    count <- reactiveVal(0)
    output$counter <- renderNacre(Counter(count))
    output$debug <- renderText(paste("Server sees:", count()))
  })
}

ui <- page_fluid(
  tags$h3("Nacre + Shiny Modules"),
  layout_columns(
    counterUI("A"),
    counterUI("B")
  )
)

server <- function(input, output, session) {
  counterServer("A")
  counterServer("B")
}

shinyApp(ui, server)
