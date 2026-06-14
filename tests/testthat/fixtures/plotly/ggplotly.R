# ggplotly.R — e2e row 19: ggplotly() parity.
#
# A ggplot converted with ggplotly() builds to the same plotly structure, so the
# same range bindings work. A button sets xaxis_range / yaxis_range; the test
# asserts the plot renders and the binding moves the axes.

library(irid)
library(plotly)
library(ggplot2)

App <- function() {
  xr <- reactiveVal(NULL)
  yr <- reactiveVal(NULL)

  App_plot <- function() {
    g <- ggplot(mtcars, aes(mpg, hp)) +
      geom_point() +
      theme_minimal()
    ggplotly(g) |> layout(uirevision = "keep")
  }

  tags$div(
    class = "p-3",
    tags$button(id = "btn-zoom", class = "btn btn-sm btn-primary mb-2",
                onClick = \() { xr(c(15, 25)); yr(c(80, 200)) },
                "Zoom"),
    PlotlyOutput(
      App_plot,
      xaxis_range = xr,
      yaxis_range = yr,
      container = tags$div(style = "height: 400px;")
    )
  )
}

App
