# PlotlyOutput — the kitchen-sink widget demo
#
# One app that exercises as much of the PlotlyOutput surface as fits
# coherently. What it covers:
#
#   - Reactive spec: the hp-threshold slider filters the data; Plotly.react()
#     updates in place and `uirevision` keeps the user's zoom/pan across the
#     data change (the whole point versus the {plotly} htmlwidget).
#   - Two-way `xaxis_range` / `yaxis_range`: a live "viewport" readout updates
#     as you drag-zoom, and a "Zoom to economy cars" button writes the ranges
#     back to move the plot programmatically.
#   - reactiveProxy snap-back: the y-axis (hp) rejects zooms narrower than 40
#     units — try to zoom in tight and the plot snaps back to the last range.
#   - `dragmode` two-way: the <select> sets it; picking a tool on plotly's own
#     modebar writes it back and the <select> follows.
#   - `selected_ids`: identity-keyed box/lasso selection. The plot supplies a
#     per-point key (`ids = ~name`), and the selection is a character vector of
#     those names — so it SURVIVES filtering (points that scroll out come back
#     highlighted) and can be set/cleared from anywhere ("Select sports cars" /
#     "Clear"), all via plotly's native dimming. No index bookkeeping: the value
#     is just the names, bound to a plain reactiveVal.
#   - `trace_visibility`: a sparse { trace name -> tri-state } map (keyed by
#     name, like selected_ids is by id). Clicking the legend writes it back;
#     "Hide 8-cyl" sets `c("8" = "legendonly")` — correct even after a filter
#     renumbers the traces.
#   - Discrete callbacks: onClick inspects a point, onDoubleclick logs a reset,
#     onRelayout shows the raw payload keys of the last gesture.
#   - uirevision reset: "Reset view" bumps a revision the spec feeds into
#     layout(uirevision = ...), clearing all plotly UI state at once.

library(irid)
library(bslib)
library(plotly)

# mtcars with a factor color split -> three scatter traces (4/6/8 cylinders),
# which gives us multiple traces for selection, legend visibility, and color.
cars <- transform(mtcars, cyl = factor(cyl), name = rownames(mtcars))

App <- function() {
  hp_min   <- reactiveVal(0L)             # data filter (drives the spec)
  revision <- reactiveVal(1L)             # uirevision bump -> reset all UI state

  xrange   <- reactiveVal(NULL)           # mpg axis
  yrange   <- reactiveVal(NULL)           # hp axis (gated below)
  dragmode <- reactiveVal("select")
  sel_cars <- reactiveVal(character())    # selection: a set of car NAMES
  visible  <- reactiveVal(NULL)           # tri-state char vector | NULL

  clicked  <- reactiveVal(NULL)           # last onClick point
  last_evt <- reactiveVal("(none)")       # last onRelayout payload keys

  filtered <- reactive(cars[cars$hp >= hp_min(), ])

  # Reject hp-axis zooms narrower than 40 units — a rejected write snaps the
  # plot back to the last accepted range (the per-binding force-send echo).
  ygate <- reactiveProxy(
    get = yrange,
    set = \(v) if (is.null(v) || (v[2] - v[1]) >= 40) yrange(v)
  )

  # bslib's `page_sidebar` / `sidebar` defer their wrapper to render time via
  # tag `.renderHooks`; irid's process_tags resolves those (#27), so the bslib
  # sidebar layout materializes natively.
  page_sidebar(
    title = "PlotlyOutput kitchen sink",

    # --- control panel (sidebar) ------------------------------------------
    sidebar = sidebar(
      title = "Controls",
      tags$label(\() paste0("Min horsepower: ", hp_min())),
      tags$input(
        type = "range", class = "form-range",
        min = "0", max = "300", step = "10",
        # No clear-on-filter: the selection is keyed on car name (ids), so
        # filtering preserves it — filtered-out cars come back highlighted.
        value = reactiveProxy(get = hp_min, set = \(v) hp_min(as.integer(v)))
      ),
      tags$label(class = "mt-2", "Drag mode"),
      tags$select(
        class = "form-select form-select-sm",
        value = dragmode,
        tags$option(value = "zoom", "Zoom"),
        tags$option(value = "pan", "Pan"),
        tags$option(value = "select", "Box select"),
        tags$option(value = "lasso", "Lasso select")
      ),
      tags$div(
        class = "d-grid gap-2 mt-3",
        tags$button(
          class = "btn btn-sm btn-outline-primary",
          onClick = \() { xrange(c(20, 35)); ygate(c(50, 130)) },
          "Zoom to economy cars"
        ),
        tags$button(
          class = "btn btn-sm btn-outline-secondary",
          # trace_visibility is keyed by trace NAME (here the cyl level),
          # not position — so this stays correct even when filtering drops
          # a group and renumbers the traces.
          onClick = \() visible(c("8" = "legendonly")),
          "Hide 8-cyl trace"
        ),
        tags$button(
          class = "btn btn-sm btn-outline-primary",
          # Set the selection from outside the plot — keyed on names.
          onClick = \() sel_cars(c("Maserati Bora", "Ferrari Dino")),
          "Select sports cars"
        ),
        tags$button(
          class = "btn btn-sm btn-outline-secondary",
          onClick = \() sel_cars(character()),
          "Clear selection"
        ),
        tags$button(
          class = "btn btn-sm btn-outline-danger",
          # Bump uirevision AND release the bound ranges/selection so the
          # view fully resets to the spec's autorange.
          onClick = \() {
            revision(revision() + 1L)
            xrange(NULL); yrange(NULL)
            sel_cars(character()); visible(NULL)
          },
          "Reset view"
        )
      )
    ),

    # --- plot (main) ------------------------------------------------------
    PlotlyOutput(
      \() {
        df <- filtered()
        plot_ly(
          df,
          x = ~mpg, y = ~hp, color = ~cyl,
          type = "scatter", mode = "markers",
          # `ids` keys the selection (stable per-point identity); `customdata`
          # stays free for the onClick readout below — two distinct jobs.
          ids = ~name, text = ~name, customdata = ~name,
          marker = list(size = 11)
        ) |>
          layout(
            uirevision = revision(),
            dragmode   = "select",
            xaxis = list(title = "mpg"),
            yaxis = list(title = "horsepower")
          )
      },
      xaxis_range     = xrange,
      yaxis_range     = ygate,
      dragmode        = dragmode,
      selected_ids    = sel_cars,
      trace_visibility = visible,
      onClick      = \(e) clicked(e$points[[1]]),
      onDoubleclick = \() last_evt("double-click (autoscale)"),
      onRelayout   = \(e) {
        keys <- names(e)
        last_evt(if (length(keys)) paste(keys, collapse = ", ") else "(empty)")
      },
      # give the plot an explicit height so it renders independently of the
      # surrounding fill context
      container = tags$div(style = "height: 480px;")
    ),

    # --- live readouts ----------------------------------------------------
    tags$div(
      class = "row mt-2 small",
      tags$div(
        class = "col-md-4",
        tags$strong("Viewport"), tags$br(),
        \() {
          fmt <- \(r) if (is.null(r)) "auto" else paste0("[", round(r[1], 1), ", ", round(r[2], 1), "]")
          paste0("mpg: ", fmt(xrange()), " | hp: ", fmt(yrange()))
        },
        tags$br(),
        \() paste0("dragmode: ", dragmode())
      ),
      tags$div(
        class = "col-md-4",
        tags$strong("Selection"), tags$br(),
        \() {
          s <- sel_cars()
          if (!length(s)) "none" else paste0(length(s), ": ", paste(s, collapse = ", "))
        },
        tags$br(),
        \() {
          v <- visible()
          if (is.null(v) || !length(v)) "visibility: default"
          else paste0("visibility: ", paste(names(v), v, sep = "=", collapse = ", "))
        }
      ),
      tags$div(
        class = "col-md-4",
        tags$strong("Events"), tags$br(),
        \() {
          p <- clicked()
          if (is.null(p)) "click a point…" else paste0("clicked: ", p$customdata, " (", p$x, " mpg, ", p$y, " hp)")
        },
        tags$br(),
        \() paste0("last relayout: ", last_evt())
      )
    )
  )
}

iridApp(App)
