# PlotlyOutput — stable selection via a translating reactiveProxy (approach #1b)
#
# The kitchen-sink example binds `selected_points` directly, so the selection is
# plotly's *positional* (curve, point) and breaks when filtering renumbers the
# points. This example keeps that same two-way `selected_points` binding — and
# plotly's native dimming — but routes it through a `reactiveProxy` that
# translates between plotly's index frame and a stable set of data keys (car
# names). The proxy is a bidirectional adapter:
#
#   set(frame)  plotly's (curve, point) indices ->  store the matching NAMES
#   get()       the stored names               ->  (curve, point) against the
#                                                   CURRENT data
#
# Because `get()` re-resolves names → indices against the current (filtered)
# data every time the binding fires, the selection follows the data: filtered-
# out points drop, and they come back highlighted when they re-enter. The
# underlying `selected_names` reactiveVal is the source of truth — clear or set
# it from anywhere (a button, an observer, a bookmark) and the plot follows.

library(irid)
library(bslib)
library(plotly)

cars    <- transform(mtcars, name = rownames(mtcars), cyl = factor(cyl))
cyl_pal <- c("4" = "#4c9f70", "6" = "#e07a5f", "8" = "#6a8eae")

App <- function() {
  hp_min         <- reactiveVal(0L)
  selected_names <- reactiveVal(character())   # source of truth: a set of names

  # The data the plot currently shows — both the spec and the proxy resolve
  # against this, so the (curve, point) ↔ name translation always matches what
  # is on screen. Single trace ⇒ curve is always 1 and point is the row index.
  filtered <- reactive(cars[cars$hp >= hp_min(), ])

  selected <- reactiveProxy(
    get = \() {
      df   <- filtered()
      rows <- which(df$name %in% selected_names())   # names -> current rows
      if (!length(rows)) NULL
      else list(curve = rep(1L, length(rows)), point = rows)   # 1-based frame
    },
    set = \(frame) {
      if (is.null(frame)) {
        selected_names(character())                  # deselect / clear
      } else {
        df  <- filtered()
        pts <- as.integer(unlist(frame$point))       # current rows -> names
        selected_names(unique(df$name[pts]))
      }
    }
  )

  page_fluid(
    title = "Stable plotly selection via a translating reactiveProxy",
    tags$h4(class = "my-3", "Stable selection — survives filtering"),
    tags$div(
      class = "row g-3",
      tags$div(
        class = "col-md-3",
        tags$div(
          class = "border rounded p-3",
          tags$label(\() paste0("Min horsepower: ", hp_min())),
          tags$input(
            type = "range", class = "form-range",
            min = "0", max = "300", step = "10",
            # No clear-on-filter: the proxy re-resolves names against the
            # current data, so filtering preserves the selection.
            value = reactiveProxy(get = hp_min, set = \(v) hp_min(as.integer(v)))
          ),
          tags$button(
            class = "btn btn-sm btn-outline-secondary mt-2 w-100",
            # Clearing is just writing the source-of-truth reactiveVal.
            onClick = \() selected_names(character()),
            "Clear selection"
          ),
          tags$button(
            class = "btn btn-sm btn-outline-primary mt-2 w-100",
            # Set the selection from *outside* the plot — keyed on names.
            onClick = \() selected_names(c("Maserati Bora", "Ferrari Dino")),
            "Select the sports cars"
          ),
          tags$hr(),
          tags$strong("Selected cars"),
          tags$div(
            class = "small text-muted",
            \() {
              s <- selected_names()
              if (!length(s)) "Box-select some points…" else paste(s, collapse = ", ")
            }
          )
        )
      ),
      tags$div(
        class = "col-md-9",
        PlotlyOutput(
          \() {
            df <- filtered()
            plot_ly(
              df,
              x = ~mpg, y = ~hp,
              type = "scatter", mode = "markers",
              customdata = ~name, text = ~name,
              hovertemplate = "%{text}<br>%{x} mpg, %{y} hp<extra></extra>",
              marker = list(size = 12, color = cyl_pal[as.character(df$cyl)])
            ) |>
              layout(
                uirevision = "keep",          # data changes preserve zoom
                dragmode   = "select",
                xaxis = list(title = "mpg"),
                yaxis = list(title = "horsepower")
              )
          },
          # Native plotly selection, routed through the translating proxy.
          selected_points = selected,
          container = tags$div(style = "height: 480px;")
        )
      )
    )
  )
}

iridApp(App)
