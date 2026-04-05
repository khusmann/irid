
<!-- README.md is generated from README.Rmd. Please edit that file -->

# irid <a href="https://irid.kylehusmann.com"><img src="man/figures/logo.png" align="right" height="138" /></a>

<!-- badges: start -->

[![WIP](https://img.shields.io/badge/status-WIP-yellow)](https://github.com/khusmann/irid)
<!-- badges: end -->

If you’ve ever fought `updateSliderInput`, wrestled
`freezeReactiveValue`, or watched `renderUI` destroy your DOM on every
change — irid is for you.

irid lets you bind a `reactiveVal` directly to any DOM attribute. One
reactive changes, one attribute updates. No `ui`/`server` split. No
fragile input IDs to wire together. Just component functions with
reactive state and DOM in the same scope.

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
          value = bins,
          onInput = \(event) bins(as.integer(event$value))
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

- <a href="https://irid.kylehusmann.com/apps/composing/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank">Composing
  Components</a>
- <a href="https://irid.kylehusmann.com/apps/todo/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank">Todo
  List</a>
- <a href="https://irid.kylehusmann.com/apps/temperature/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank">Temperature
  Converter</a>
- <a href="https://irid.kylehusmann.com/apps/optimistic-updates/index.html?_shinylive-mode=editor-terminal-viewer" target="_blank">Optimistic
  Updates</a>

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

Irid comes from *iridescent* — like the rainbow shimmer inside a shell,
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
