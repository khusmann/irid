# PlotlyOutput — stable, identity-based selection (design approach #1)
#
# The kitchen-sink example binds `selected_points` (plotly's native, *positional*
# (curve, point) selection) and has to CLEAR the selection whenever the filter
# changes the data, because the indices stop lining up.
#
# This example takes the other road: the selection is not a plotly concept at
# all, it is **app state keyed on the data** — a set of car names. The plot is a
# pure function of (data, selected names): each render derives a per-point
# `sel` column and styles the markers from it. Because the highlight is
# recomputed from names against whatever rows currently exist, the selection
# SURVIVES filtering for free — points still present stay highlighted, filtered-
# out ones simply drop. No clear-on-filter, no index bookkeeping.
#
# Capture uses the discrete `onSelected` callback (the raw selected points,
# including `customdata`), not the two-way `selected_points` prop — so nothing
# writes positional indices back, and the spec stays the single source of truth
# for what is highlighted.

library(irid)
library(bslib)
library(plotly)

cars <- transform(mtcars, name = rownames(mtcars), cyl = factor(cyl))
cyl_pal <- c("4" = "#4c9f70", "6" = "#e07a5f", "8" = "#6a8eae")

App <- function() {
  hp_min   <- reactiveVal(0L)
  selected <- reactiveVal(character())   # the selection: a set of car NAMES

  page_fluid(
    title = "Stable (identity-based) plotly selection",
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
            # NOTE: no clear-on-filter here. Selection is keyed on car name and
            # re-derived every render, so filtering preserves it automatically.
            value = reactiveProxy(get = hp_min, set = \(v) hp_min(as.integer(v)))
          ),
          tags$button(
            class = "btn btn-sm btn-outline-secondary mt-2 w-100",
            onClick = \() selected(character()),
            "Clear selection"
          ),
          tags$hr(),
          tags$strong("Selected cars"),
          tags$div(
            class = "small text-muted",
            \() {
              s <- selected()
              if (!length(s)) "Box-select some points…" else paste(s, collapse = ", ")
            }
          )
        )
      ),
      tags$div(
        class = "col-md-9",
        PlotlyOutput(
          \() {
            df <- cars[cars$hp >= hp_min(), ]
            # Derive the highlight from app state — the whole trick.
            df$sel    <- df$name %in% selected()
            df$mcolor <- ifelse(df$sel, "#d6336c", cyl_pal[as.character(df$cyl)])
            df$msize  <- ifelse(df$sel, 16, 10)
            df$mwidth <- ifelse(df$sel, 2, 0)
            plot_ly(
              df,
              x = ~mpg, y = ~hp,
              type = "scatter", mode = "markers",
              customdata = ~name, text = ~name,
              hovertemplate = "%{text}<br>%{x} mpg, %{y} hp<extra></extra>",
              marker = list(
                size  = ~msize,
                color = ~mcolor,
                line  = list(color = "#212529", width = ~mwidth)
              )
            ) |>
              layout(
                uirevision = "keep",          # data changes preserve zoom
                dragmode   = "select",
                xaxis = list(title = "mpg"),
                yaxis = list(title = "horsepower")
              )
          },
          # Capture the box contents as NAMES (data-domain keys), not indices.
          onSelected = \(e) {
            names <- vapply(e$points, \(p) p$customdata, character(1))
            selected(unique(names))
          },
          container = tags$div(style = "height: 480px;")
        )
      )
    )
  )
}

iridApp(App)
