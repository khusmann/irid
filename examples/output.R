library(shiny)
library(bslib)
library(nacre)

OutputApp <- function() {
  bins <- reactiveVal(30)

  page_sidebar(
    title = "Old Faithful Geyser Data",
    sidebar = sidebar(
      tags$label("Number of bins:", class = "form-label"),
      tags$input(
        type = "range", min = 1, max = 50,
        class = "form-range",
        value = bins,
        onInput = \(value) bins(as.numeric(value))
      )
    ),
    shiny_output(renderPlot, plotOutput, {
      x <- faithful[, 2]
      b <- seq(min(x), max(x), length.out = bins() + 1)
      hist(x, breaks = b, col = "darkgray", border = "white",
           xlab = "Waiting time to next eruption (in mins)",
           main = "Histogram of waiting times")
    })
  )
}

nacreApp(OutputApp)
