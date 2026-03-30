
<!-- README.md is generated from README.Rmd. Please edit that file -->

# nacre <img src="man/figures/logo.png" align="right" height="139" />

<!-- badges: start -->

[![WIP](https://img.shields.io/badge/status-WIP-yellow)](https://github.com/khusmann/nacre)
<!-- badges: end -->

If you’ve ever fought `updateSliderInput`, wrestled
`freezeReactiveValue`, or watched `renderUI` destroy your DOM on every
change — nacre is for you.

nacre lets you bind a `reactiveVal` directly to any DOM attribute. One
reactive changes, one attribute updates. No re-rendering, no flicker, no
`update*Input` callbacks.

``` r
library(bslib)
library(nacre)

App <- function() {
  count <- reactiveVal(0)

  page_fluid(
    tags$h1(\() paste("Count:", count())),
    tags$input(
      type = "range", min = 0, max = 100,
      value = count,
      onInput = \(event) count(event$valueAsNumber)
    ),
    tags$button(
      disabled = \() count() == 0,
      onClick = \() count(0),
      "Reset"
    )
  )
}

nacreApp(App)
```

No `ui`/`server` split. No fragile input IDs to wire together. Just
component functions with reactive state and DOM in the same scope.

See more examples: [Todo
List](https://nacre.kylehusmann.com/articles/examples.html#todo-list),
[Old
Faithful](https://nacre.kylehusmann.com/articles/examples.html#old-faithful),
[Temperature
Converter](https://nacre.kylehusmann.com/articles/examples.html#temperature-converter),
[Shiny
Modules](https://nacre.kylehusmann.com/articles/examples.html#shiny-modules),
[Optimistic
Updates](https://nacre.kylehusmann.com/articles/examples.html#optimistic-updates)

## 100% backward compatible

You don’t have to go all-in. Drop nacre components into an existing
Shiny app with `nacreOutput`/`renderNacre`:

``` r
Greeting <- function() {
  name <- reactiveVal("")
  tags$div(
    tags$input(type = "text", value = name,
      onInput = \(event) name(event$value)
    ),
    tags$p(\() paste("Hello,", name()))
  )
}

ui <- fluidPage(
  nacreOutput("greeting"),
  plotOutput("plot")
)

server <- function(input, output, session) {
  output$greeting <- renderNacre(Greeting())  # nacre component
  output$plot <- renderPlot(plot(1:10))
}

shinyApp(ui, server)
```

Old Shiny inputs and nacre components coexist in the same server scope.
Migrate one `renderUI` at a time, or switch to `nacreApp` when you’re
ready.

## Installation

``` r
# install.packages("pak")
pak::pak("khusmann/nacre")
```

## Learn more

See `vignette("nacre")` to get started.

## Why nacre?

Nacre is the iridescent layer that forms inside a shell. This package is
a thin rendering layer that forms on top of Shiny. An extra layer of
shiny, for Shiny.

## Inspiration

nacre brings ideas from modern JavaScript component frameworks to Shiny
— especially [Solid.js](https://www.solidjs.com/), which pioneered
fine-grained reactivity without a virtual DOM. Shiny’s reactive engine
(`reactiveVal`, `reactive`, `observe`) was already close to this model;
nacre closes the gap by connecting it directly to the DOM the way Solid
does. React’s component model and controlled input patterns were also an
influence.
