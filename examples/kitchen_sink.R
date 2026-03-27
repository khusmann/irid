library(shiny)
library(bslib)
library(nacre)

ListPage <- function(items, new_item) {
  show_stats <- reactiveVal(TRUE)

  tags$div(
    class = "card p-3",
    tags$h4("Dynamic List"),

    # Add item form
    tags$div(
      class = "input-group mb-3",
      tags$input(
        type = "text",
        class = "form-control",
        placeholder = "Add item...",
        value = new_item,
        onInput = \(value) new_item(value)
      ),
      tags$button(
        class = "btn btn-success",
        disabled = \() nchar(new_item()) == 0,
        onClick = \() {
          items(c(items(), list(new_item())))
          new_item("")
        },
        "Add"
      )
    ),

    # When: conditionally show stats
    tags$div(
      class = "mb-3",
      tags$button(
        class = "btn btn-sm btn-outline-secondary",
        onClick = \() show_stats(!show_stats()),
        \() if (show_stats()) "Hide Stats" else "Show Stats"
      ),
      When(show_stats,
        tags$p(class = "text-muted mt-2",
          \() paste(length(items()), "items in the list")
        )
      )
    ),

    # Index: positional list rendering
    tags$ul(
      class = "list-group",
      Index(items, \(item, i) {
        tags$li(
          class = "list-group-item d-flex justify-content-between align-items-center",
          tags$span(\() item()),
          tags$button(
            class = "btn btn-sm btn-outline-danger",
            onClick = \() items(items()[-i]),
            "Remove"
          )
        )
      })
    )
  )
}

PlotPage <- function() {
  bins <- reactiveVal(30)

  tags$div(
    class = "card p-3",
    tags$h4("Old Faithful"),
    tags$label("Bins:", class = "form-label"),
    tags$input(
      type = "range", min = 1, max = 50,
      class = "form-range",
      value = bins,
      onInput = \(value) bins(as.numeric(value))
    ),
    shiny_output(renderPlot, plotOutput, {
      x <- faithful[, 2]
      b <- seq(min(x), max(x), length.out = bins() + 1)
      hist(x, breaks = b, col = "darkgray", border = "white",
           xlab = "Waiting time (mins)",
           main = "Histogram of waiting times")
    })
  )
}

AboutPage <- function() {
  tags$div(
    class = "card p-3",
    tags$h4("About"),
    tags$p("This example demonstrates all nacre control flow primitives:"),
    tags$ul(
      tags$li(tags$strong("Match/Case/Default"), " — tab switching"),
      tags$li(tags$strong("When"), " — toggle stats visibility"),
      tags$li(tags$strong("Index"), " — dynamic item list"),
      tags$li(tags$strong("shiny_output"), " — inline plot")
    )
  )
}

TabBar <- function(tab, tabs) {
  tags$div(
    class = "btn-group mb-3",
    lapply(tabs, \(t) {
      tags$button(
        class = \() paste("btn", if (tab() == t$id) "btn-primary" else "btn-outline-primary"),
        onClick = \() tab(t$id),
        t$label
      )
    })
  )
}

KitchenSinkApp <- function() {
  tab <- reactiveVal("list")
  items <- reactiveVal(list("Apple", "Banana", "Cherry"))
  new_item <- reactiveVal("")

  page_fluid(
    tags$h2("Nacre Kitchen Sink"),

    TabBar(tab, list(
      list(id = "list", label = "List Demo"),
      list(id = "plot", label = "Plot Demo"),
      list(id = "about", label = "About")
    )),

    Match(
      Case(\() tab() == "list", ListPage(items, new_item)),
      Case(\() tab() == "plot", PlotPage()),
      Default(AboutPage())
    )
  )
}

nacreApp(KitchenSinkApp)
