library(shiny)
library(bslib)
library(nacre)

ToggleApp <- function() {
  show <- reactiveVal(TRUE)

  page_fluid(
    card(
      card_header("When / Toggle"),
      card_body(
        tags$button(
          class = "btn btn-primary mb-3",
          onClick = \() show(!show()),
          \() if (show()) "Hide Content" else "Show Content"
        ),
        When(show,
          tags$div(
            class = "alert alert-success",
            tags$strong("Visible!"),
            " This content is shown."
          ),
          otherwise = tags$div(
            class = "alert alert-warning",
            tags$strong("Hidden."),
            " Showing the fallback instead."
          )
        )
      )
    )
  )
}

nacreApp(ToggleApp)
