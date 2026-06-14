# two-plots.R — two PlotlyOutputs on one page, each with a stable container id,
# so the e2e `gd =` selector can target one independently of the other.

library(irid)
library(plotly)

App <- function() {
  mk <- function(y) {
    plot_ly(x = 1:10, y = y, type = "scatter", mode = "markers") |>
      layout(uirevision = "keep")
  }
  tags$div(
    class = "p-3",
    PlotlyOutput(\() mk(1:10),
                 container = tags$div(id = "plot-a", style = "height: 300px;")),
    PlotlyOutput(\() mk(10:1),
                 container = tags$div(id = "plot-b", style = "height: 300px;"))
  )
}

App
