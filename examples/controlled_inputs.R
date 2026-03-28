library(shiny)
library(bslib)
library(nacre)

ControlledInputs <- function() {
  name <- reactiveVal("")

  page_fluid(
    card(
      card_header("Controlled Inputs"),
      card_body(
        tags$p(class = "text-muted", "Type in any input — the others follow."),
        tags$input(type = "text", class = "form-control mb-2",
          placeholder = "Input 1",
          value = name, onInput = \(value) name(value)),
        tags$input(type = "text", class = "form-control mb-2",
          placeholder = "Input 2",
          value = name, onInput = \(value) name(value)),
        tags$input(type = "text", class = "form-control",
          placeholder = "Input 3",
          value = name, onInput = \(value) name(value))
      )
    )
  )
}

nacreApp(ControlledInputs)
