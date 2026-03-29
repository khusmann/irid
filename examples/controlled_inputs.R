# Controlled Inputs
#
# In most UI frameworks, inputs and state are kept in sync by making the input
# *controlled* — the input's displayed value is always derived from application
# state, not managed independently by the browser. nacre brings this pattern to
# Shiny: you bind a reactive value directly to an input's `value` attribute, and
# every update flows through that single source of truth.
#
# This example shows three text inputs all bound to the same `reactiveVal`. Type
# in any one of them and the others instantly reflect the change — there's no
# extra synchronization logic, just one shared value.

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
          value = name, onInput = \(event) name(event$value)),
        tags$input(type = "text", class = "form-control mb-2",
          placeholder = "Input 2",
          value = name, onInput = \(event) name(event$value)),
        tags$input(type = "text", class = "form-control",
          placeholder = "Input 3",
          value = name, onInput = \(event) name(event$value))
      )
    )
  )
}

nacreApp(ControlledInputs)
