# Shiny Modules
#
# nacre components work naturally inside standard Shiny modules. Use
# nacreOutput() and renderNacre() to embed a nacre component tree inside a
# module's UI and server functions, exactly like any other Shiny output. The
# reactive state lives inside the module's server function, so each module
# instance is fully independent.
#
# This example instantiates two counter modules side by side, each with a
# display component and a controls component that share the same reactiveVal.

library(nacre)
library(shiny)
library(bslib)

# nacre components -----------------------------------------------------------

CountDisplay <- function(count) {
  tags$h2(
    class = "text-center display-4",
    \() count()
  )
}

CountControls <- function(count) {
  tags$div(
    tags$input(
      type = "range", min = 0, max = 100,
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

# shiny module ---------------------------------------------------------------

counter_ui <- function(id) {
  ns <- NS(id)
  card(
    card_header(id),
    card_body(
      nacreOutput(ns("display")),
      nacreOutput(ns("controls"))
    )
  )
}

counter_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    count <- reactiveVal(0)
    output$display <- renderNacre(CountDisplay(count))
    output$controls <- renderNacre(CountControls(count))
  })
}

# shiny app ------------------------------------------------------------------

ui <- page_fluid(
  tags$h3("Nacre + Shiny Modules"),
  layout_columns(
    counter_ui("A"),
    counter_ui("B")
  )
)

server <- function(input, output, session) {
  counter_server("A")
  counter_server("B")
}

shinyApp(ui, server)
