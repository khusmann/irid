library(shiny)
library(bslib)
library(nacre)

CounterApp <- function() {
  count <- reactiveVal(0)
  color <- reactive({
    r <- round(count() * 255 / 100)
    b <- 255 - r
    sprintf("rgb(%d,0,%d)", r, b)
  })

  page_fluid(
    card(
      card_header("Counter"),
      card_body(
        tags$h1(
          class = "text-center",
          style = \() paste0("color:", color()),
          \() paste("Count:", count())
        ),
        tags$input(
          type = "range", min = 0, max = 100,
          class = "form-range",
          value = count,
          onInput = event_throttle(\(value) count(as.numeric(value)), 100)
        ),
        tags$button(
          class = "btn btn-outline-secondary",
          disabled = \() count() == 0,
          onClick = \() count(0),
          "Reset"
        )
      )
    )
  )
}

nacreApp(CounterApp())
