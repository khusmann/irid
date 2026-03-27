library(shiny)
library(nacre)

SyncedInputs <- function() {
  name <- reactiveVal("")

  tags$div(
    tags$input(type = "text", value = name,
      onInput = \(value) name(value)),
    tags$input(type = "text", value = name,
      onInput = \(value) name(value)),
    tags$input(type = "text", value = name,
      onInput = \(value) name(value))
  )
}

ui <- fluidPage(
  nacreOutput("sync")
)

server <- function(input, output, session) {
  output$sync <- renderNacre({
    SyncedInputs()
  })
}

shinyApp(ui, server)
