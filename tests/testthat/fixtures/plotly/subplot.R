# subplot.R — e2e row 18: subplot axes route independently.
#
# A two-panel subplot gives xaxis and xaxis2; binding xaxis_range and
# xaxis2_range must each move only its own panel. Two buttons set each range so
# the test can drive one axis and assert the other is untouched. Numeric axes
# keep the range assertions simple.

library(irid)
library(plotly)

App <- function() {
  x1 <- reactiveVal(NULL)
  x2 <- reactiveVal(NULL)

  d <- data.frame(x = 1:50, y = sin(1:50 / 5), z = cos(1:50 / 5))

  App_plot <- function() {
    p1 <- plot_ly(d, x = ~x, y = ~y, type = "scatter", mode = "lines",
                  name = "sin")
    p2 <- plot_ly(d, x = ~x, y = ~z, type = "scatter", mode = "lines",
                  name = "cos")
    subplot(p1, p2, nrows = 1, margin = 0.05) |>
      layout(uirevision = "keep")
  }

  tags$div(
    class = "p-3",
    tags$div(
      class = "d-flex gap-2 mb-2",
      tags$button(id = "btn-x1", class = "btn btn-sm btn-primary",
                  onClick = \() x1(c(10, 20)), "Set x1"),
      tags$button(id = "btn-x2", class = "btn btn-sm btn-primary",
                  onClick = \() x2(c(30, 40)), "Set x2")
    ),
    PlotlyOutput(
      App_plot,
      xaxis_range  = x1,
      xaxis2_range = x2,
      container = tags$div(style = "height: 400px;")
    )
  )
}

App
