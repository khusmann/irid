
<!-- README.md is generated from README.Rmd. Please edit that file -->

# nacre <img src="man/figures/logo.png" align="right" height="139" />

**An extra layer of Shiny for Shiny.**

nacre is a thin rendering layer on top of Shiny that replaces `renderUI`
with Solid-style fine-grained DOM bindings. Write your server logic with
`reactiveVal` and `reactive` as usual — nacre just changes how
reactivity connects to the DOM.

## The Problem

Shiny’s UI layer has two modes, and both are broken:

**Static inputs** (`sliderInput`, `selectInput`) are uncontrolled. The
browser owns the state. The server can only ask the client to change via
`updateSliderInput`, `freezeReactiveValue`, etc. You can’t drive an
input from a `reactiveVal`.

**`renderUI`** is the escape hatch for dynamic content. But it destroys
and recreates entire DOM subtrees on every change — causing flicker,
lost input state, and expensive round-trips.

Meanwhile, the reactive engine (`reactiveVal`, `reactive`, `observe`) is
excellent. The problem isn’t reactivity — it’s how reactivity connects
to the DOM.

## The Idea

One simple rule: **pass a function instead of a value to make any tag
attribute reactive.**

The framework calls each reactive function inside its own `observe()`,
scoped to that single DOM attribute. When the reactive value changes,
only that attribute updates. No VDOM, no diffing, no DOM destruction.

``` r
library(shiny)
library(nacre)

App <- function() {
  count <- reactiveVal(0)
  color <- reactiveVal("black")

  fluidPage(
    tags$h1(
      style = \() paste0("color:", color()),
      \() paste("Count:", count())
    ),
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

No new reactivity model. No hooks. No dependency arrays. Just Shiny
reactives wired directly to DOM nodes.

## Installation

You can install the development version of nacre from GitHub with:

``` r
# install.packages("pak")
pak::pak("khusmann/nacre")
```

## Usage

### Full nacre app — `nacreApp`

When your entire app is nacre. All state is `reactiveVal`, all inputs
are controlled. No `ui`/`server` split:

``` r
App <- function() {
  name <- reactiveVal("")

  fluidPage(
    tags$input(type = "text", value = name,
      onInput = \(event) name(event$value)),
    tags$p(\() paste("Hello,", name()))
  )
}

nacreApp(App)
```

`nacreApp` processes the tag tree at build time into static HTML and
mounts reactive observers on the server. It returns a `shinyApp` object,
so it works with `runApp()`, `shinytest2`, and deployment tools.

### Incremental adoption — `nacreOutput` / `renderNacre`

Drop nacre components into an existing Shiny app. Old Shiny inputs and
nacre inputs coexist because they share the server function’s scope:

``` r
ThresholdControl <- function(threshold) {
    tags$div(
      tags$input(
        type = "range", min = 0, max = 1, step = 0.1,
        value = threshold,
        onInput = \(event) threshold(event$valueAsNumber)
      ),
      tags$span(\() paste("Threshold:", threshold()))
    )
}

ui <- fluidPage(
  sliderInput("n", "N", 1, 100, 50),
  nacreOutput("filters"),
  plotOutput("plot")
)

server <- function(input, output, session) {
  threshold <- reactiveVal(0.5)

  output$filters <- renderNacre(ThresholdControl(threshold))

  output$plot <- renderPlot({
    mtcars |> head(input$n) |>
      dplyr::filter(mpg > threshold() * 30) |>
      ggplot2::ggplot(ggplot2::aes(wt, mpg)) + ggplot2::geom_point()
  })
}

shinyApp(ui, server)
```

Nacre works with Shiny modules via standard `NS()` / `moduleServer()` —
no special API needed.

The migration path:

1.  Start with a normal Shiny app
2.  Drop in one `nacreOutput`/`renderNacre` for a painful `renderUI`
3.  Gradually convert more components
4.  Eventually switch to `nacreApp` when the whole app is nacre
5.  Old `sliderInput` etc still work at every stage

## Core Concepts

### Reactive Attributes

Any tag attribute can be static or reactive:

``` r
tags$div(class = "panel")                                          # static
tags$div(class = \() if (is_active()) "panel active" else "panel") # reactive
```

Since `reactiveVal` and `reactive` are both functions, they work
directly:

``` r
name <- reactiveVal("hello")
upper_name <- reactive(toupper(name()))

tags$span(upper_name)   # works — reactive is a function
tags$span(name)         # works — reactiveVal is a function
tags$span(\() name())   # also works — anonymous function
```

### Reactive Children

Tag children can also be reactive functions, but they must return **text
only** — not tag trees. Use control flow primitives for structural
changes.

``` r
tags$span(\() paste("Count:", count()))                            # text — works
tags$div(When(show, tags$p("Hello"), otherwise = tags$span("Bye")))  # structural
```

### Event Callbacks

Event callbacks receive `(event)` or `(event, id)`. The `event` is a
list of all primitive-valued properties from the browser event, plus
element properties like `value`, `valueAsNumber`, and `checked`. Define
callbacks with 0, 1, or 2 parameters as needed:

``` r
onInput = \(event) threshold(event$valueAsNumber)  # event object
onClick = \(event, id) handle_click(id)             # event + element id
onClick = \() count(count() + 1)                    # neither
```

### Controlled Inputs

Inputs are controlled by binding their `value` attribute to a
`reactiveVal`:

``` r
threshold <- reactiveVal(0.5)

tags$input(
  type = "range", min = 0, max = 1, step = 0.1,
  value = threshold,
  onInput = \(event) threshold(event$valueAsNumber)
)
```

The `reactiveVal` is the source of truth. Setting `threshold(0.5)` from
anywhere updates the slider. Multiple inputs can share the same
`reactiveVal` — type in one, the others update. No `updateTextInput`. No
`freezeReactiveValue`.

### Optimistic Updates

The browser updates the focused input immediately. The server round-trip
confirms it for other inputs bound to the same `reactiveVal`, but the
focused element skips the confirmation (it already has the right value).

## Control Flow Primitives

Because the component function runs **once** (like Solid, unlike React),
you can’t use plain `if`/`else` for conditional rendering. nacre
provides control flow primitives for structural DOM changes.

### When

``` r
When(logged_in,
  Dashboard(),
  otherwise = LoginPanel()
)
```

When the condition changes, the old content is torn down and the new
content is mounted atomically.

### Match / Case / Default

``` r
Match(
  Case(\() tab() == "home",     HomePage()),
  Case(\() tab() == "data",     DataPage()),
  Case(\() tab() == "settings", SettingsPage()),
  Default(NotFoundPage())
)
```

### Each

Dynamic lists. Replaces `renderUI(lapply(...))`. The callback receives
each item as a **plain value** — when the list changes, all items are
destroyed and recreated. (Future: keyed reordering via the `by` argument
will move DOM nodes instead of recreating them.)

``` r
tags$ul(
  Each(items, \(item) {
    tags$li(item$name)
  })
)
```

The `index` parameter is optional:

``` r
Each(items, \(item, index) {
  tags$li(paste(index, item$name))
})
```

### Index

Like `Each`, but keyed by **position**. The callback receives each item
as a **reactive accessor** (`item()` to read). When values change
without a length change, each slot’s `reactiveVal` is updated in place —
existing observers re-fire without DOM recreation:

``` r
tags$ul(
  Index(items, \(item) {
    tags$li(\() item()$name)
  })
)
```

**When to use which:** Use `Each` when items have a stable identity
(todos, users, records). Use `Index` when you care about positions
(ranking, slots, columns).

## Shiny Outputs

Binary artifacts like plots and tables use Shiny’s existing render
infrastructure via `Output`:

``` r
Output(renderPlot, plotOutput, {
  ggplot(mtcars, aes(wt, mpg)) + geom_point()
})
```

Convenience wrappers:

``` r
PlotOutput({ ggplot(mtcars, aes(wt, mpg)) + geom_point() })
TableOutput({ head(mtcars) })
DTOutput({ mtcars })
```

Works with any render/output pair — pass both functions explicitly to
`Output`.

## Event Rate Limiting

Bare `onInput` callbacks are automatically debounced (200 ms) so the
server only sees the settled value. All other events fire immediately.
Override with explicit wrappers:

``` r
# Immediate — override debounce default for onInput
onInput = event_immediate(\(event) name(event$value))

# Throttle — fire at most every N ms (continuous feedback)
onInput = event_throttle(\(event) threshold(event$valueAsNumber), 100)

# Debounce — custom delay
onInput = event_debounce(\(event) name(event$value), 500)
```

`event_throttle()` and `event_debounce()` support **adaptive
coalescing** (`coalesce = TRUE`, the default): the client also waits for
the server to finish processing before sending the next event,
preventing queue buildup when the server is slow.

## API

| Function | Purpose |
|----|----|
| `nacreApp(tag_tree)` | Create a full nacre app |
| `nacreOutput(id)` / `renderNacre(expr)` | Drop nacre into an existing Shiny app |
| `When(condition, yes, otherwise)` | Conditional rendering |
| `Match(Case(...), ..., Default(...))` | Multi-branch conditional |
| `Each(items, fn, by)` | Dynamic lists (recreate on change) |
| `Index(items, fn)` | Dynamic lists (positional update) |
| `Output(render_fn, output_fn, expr)` | Inline Shiny output |
| `PlotOutput(expr)` | Plot output shorthand |
| `TableOutput(expr)` | Table output shorthand |
| `DTOutput(expr)` | DT DataTable output shorthand |
| `Portal(target, content)` | Render elsewhere in DOM *(stub)* |
| `Catch(content, fallback)` | Error boundary *(stub)* |
| `event_immediate(fn)` | Explicit immediate event (default) |
| `event_debounce(fn, ms)` | Debounce an event callback |
| `event_throttle(fn, ms)` | Throttle an event callback |

## Design Principles

1.  **No new reactivity model.** `reactiveVal` and `reactive` are the
    API.
2.  **Functions-as-attributes is the only new concept.** If you know
    Shiny, you can learn nacre in five minutes.
3.  **Surgical updates.** One reactive changes, one DOM attribute
    updates. Nothing else is touched.
4.  **Explicit rate limiting.** No hidden debounce or throttle. A bare
    callback is immediate.
5.  **Controlled inputs by default.** The `reactiveVal` is the source of
    truth.
6.  **Existing Shiny outputs still work.** Migrate incrementally.
