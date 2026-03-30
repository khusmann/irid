# Old Faithful
#
# The classic Shiny demo, rebuilt with nacre. A slider controls the number of
# bins in a histogram of eruption wait times from the Old Faithful geyser
# dataset. The slider is a controlled input bound to a `reactiveVal`, and the
# plot is rendered with `PlotOutput`.

library(bslib)
library(nacre)

OldFaithful <- function() {
  bins <- reactiveVal(30L)

  page_fluid(
    tags$div(
      class = "mx-auto",
      style = "max-width: 700px;",

      tags$h2(class = "mt-4 mb-3", "Old Faithful Geyser Data"),

      card(
        card_body(
          tags$label("for" = "bins-slider", class = "form-label",
            \() paste0("Number of bins: ", bins())),
          tags$input(id = "bins-slider", type = "range",
            class = "form-range", min = "1", max = "50",
            value = bins,
            onInput = \(event) bins(as.integer(event$value))),

          PlotOutput({
            x <- faithful$waiting
            b <- seq(min(x), max(x), length.out = bins() + 1)
            hist(x, breaks = b, col = "darkgray", border = "white",
              xlab = "Waiting time to next eruption (in mins)",
              main = "Histogram of waiting times")
          })
        )
      )
    )
  )
}

nacreApp(OldFaithful)
