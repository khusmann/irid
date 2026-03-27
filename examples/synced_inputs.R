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

nacreApp(SyncedInputs)
