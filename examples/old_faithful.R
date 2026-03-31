# Old Faithful
#
# The classic Shiny demo, rebuilt with nacre. A slider controls the number of
# bins in a histogram of eruption wait times from the Old Faithful geyser
# dataset. The slider is a controlled input bound to a `reactiveVal`, and the
# plot is rendered with `PlotOutput`.

library(nacre)
library(bslib)

OldFaithful <- function() {
  bins <- reactiveVal(30L)

  page_fluid(
    card(
      card_body(
        tags$label(\() paste0("Number of bins: ", bins())),
        tags$input(
          type = "range", min = "1", max = "50",
          value = bins,
          onInput = \(event) bins(as.integer(event$value))
        ),
        PlotOutput({
          x <- faithful$waiting
          b <- seq(min(x), max(x), length.out = bins() + 1)
          hist(
            x, breaks = b,
            xlab = "Waiting time to next eruption (in mins)",
            main = "Histogram of waiting times"
          )
        })
      )
    )
  )
}

nacreApp(OldFaithful)
