library(shiny)
library(nacre)

CounterApp <- function() {
  count <- reactiveVal(0)
  color <- reactiveVal("black")

  tags$div(
    tags$h1(
      style = \() paste0("color:", color()),
      \() paste("Count:", count())
    ),
    tags$input(
      type = "range", min = 0, max = 100,
      value = count,
      onInput = \(value) count(as.numeric(value))
    ),
    tags$button(
      disabled = \() count() == 0,
      onClick = \() count(0),
      "Reset"
    )
  )
}

ui <- fluidPage(
  nacreOutput("app")
)

server <- function(input, output, session) {
  output$app <- renderNacre({
    CounterApp()
  })
}

shinyApp(ui, server)
