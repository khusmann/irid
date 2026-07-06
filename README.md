
<!-- README.md is generated from README.Rmd. Please edit that file -->

# irid <a href="https://irid.kylehusmann.com"><img src="man/figures/logo.png" align="right" height="138" /></a>

<!-- badges: start -->

[![CRAN
status](https://www.r-pkg.org/badges/version/irid)](https://CRAN.R-project.org/package=irid)
[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![R-CMD-check](https://github.com/khusmann/irid/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/khusmann/irid/actions/workflows/R-CMD-check.yaml)
[![Codecov test
coverage](https://codecov.io/gh/khusmann/irid/graph/badge.svg)](https://app.codecov.io/gh/khusmann/irid)
<!-- badges: end -->

**Component-based UI for Shiny, with fine-grained reactivity.**

If you’ve ever fought `updateSliderInput`, wrestled
`freezeReactiveValue`, or watched `renderUI` destroy your DOM on every
change, irid is for you.

irid lets you bind a `reactiveVal` directly to any DOM attribute —
change the reactive, and that one attribute updates without re-rendering
the whole component. There’s no [ui/server
split](https://www.kylehusmann.com/posts/2026/shinys-achilles-heel/):
your component is an ordinary R function holding both state and markup.

``` r
library(irid)
library(bslib)

OldFaithful <- function() {
  bins <- reactiveVal(30L)

  page_fluid(
    card(
      card_body(
        tags$label(\() paste0("Number of bins: ", bins())),
        tags$input(
          type = "range", min = "1", max = "50",
          value = reactiveProxy(get = bins, set = \(v) bins(as.integer(v)))
        ),
        PlotOutput(\() {
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

iridApp(OldFaithful)
```

<a href="https://irid.kylehusmann.com/apps/old-faithful/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank"><strong>Try
it live</strong></a>

See more examples:

- <a href="https://irid.kylehusmann.com/apps/temperature/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank">Temperature
  Converter</a>
- <a href="https://irid.kylehusmann.com/apps/todo/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank">Todo
  List</a>
- <a href="https://irid.kylehusmann.com/apps/plotly/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank">Reactive
  Plotly</a>

## 100% backward compatible

You don’t have to go all-in. Drop irid components into an existing Shiny
app to handle complex interactivity with `iridOutput`/`renderIrid`:

``` r
ui <- fluidPage(
  iridOutput("oldFaithful"),
  tableOutput("summary")
)

server <- function(input, output, session) {
  output$oldFaithful <- renderIrid(OldFaithful())  # irid component
  output$summary <- renderTable(summary(faithful))   # classic Shiny
}

shinyApp(ui, server)
```

Old Shiny inputs and irid components coexist in the same server scope.
Migrate one `renderUI` at a time, or switch to `iridApp` when you’re
ready.

See also:
<a href="https://irid.kylehusmann.com/apps/shiny-interop/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank">Shiny
Interop</a> example.

## Installation

``` r
# install.packages("pak")
pak::pak("khusmann/irid")
```

## Learn more

See the [Getting
Started](https://irid.kylehusmann.com/articles/irid.html) vignette to
get started.

## Why irid?

irid comes from *iridescent* — like the rainbow shimmer inside a shell,
formed by its layered structure. A component layer for Shiny — extra
shiny, for Shiny.

## Inspiration

irid brings ideas from modern JavaScript component frameworks to Shiny —
especially [Solid.js](https://www.solidjs.com/), which pioneered
fine-grained reactivity where each change updates only the specific DOM
node it’s bound to. Shiny’s reactive engine (`reactiveVal`, `reactive`,
`observe`) was already close to this model; irid closes the gap by
connecting it directly to the DOM the way Solid does. React’s component
model and controlled input patterns were also an influence.
