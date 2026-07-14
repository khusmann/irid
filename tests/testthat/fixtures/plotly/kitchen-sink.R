# kitchen-sink.R — test-owned PlotlyOutput fixture (e2e rows 1-17, 22-26).
#
# Modeled on inst/examples/plotly/app.R but OWNED BY THE SUITE: it diverges on purpose so
# the load-bearing round-trip bugs are exercised. Stable element ids let the
# harness target controls and readouts without scraping text. The selection is
# bound via a *translating* reactiveProxy (car name <-> row index into the full
# data) rather than a plain reactiveVal, so the own-mutation deselect echo (row
# 24) is genuinely destructive when unguarded — a plain reactiveVal would re-set
# the same value and mask the bug.
#
# The fixture's last expression is the bare `App` function; the harness wraps it
# in iridApp() in the background process.

library(irid)
library(bslib)
library(plotly)

# mtcars split by cylinder -> three scatter traces (4/6/8). A high enough hp
# filter drops the 4-cyl group entirely (max 4-cyl hp is 113), taking gd.data
# from 3 traces to 2 — the trace *recomposition* rows 23/26 require.
cars <- transform(mtcars, cyl = factor(cyl), name = rownames(mtcars))

App <- function() {
  hp_min   <- reactiveVal(0L)
  revision <- reactiveVal(1L)

  xrange   <- reactiveVal(NULL)
  yrange   <- reactiveVal(NULL)
  dragmode <- reactiveVal("select")
  hovermode <- reactiveVal("closest")
  visible  <- reactiveVal(NULL)

  hovered  <- reactiveVal(NULL)           # last onHover point
  legend   <- reactiveVal(NULL)           # last onLegendClick curve

  # Selection stored as ROW INDICES into the full `cars`; exposed to the plot as
  # a translating proxy (index <-> car name). Index storage survives filtering
  # (the plot is keyed on names, the store on stable indices).
  sel_idx  <- reactiveVal(integer())
  sel_proxy <- reactiveProxy(
    get = \() cars$name[sel_idx()],
    set = \(v) sel_idx(if (is.null(v) || !length(v)) integer() else match(v, cars$name))
  )

  clicked  <- reactiveVal(NULL)
  last_evt <- reactiveVal("(none)")

  filtered <- reactive(cars[cars$hp >= hp_min(), ])

  # Reject hp-axis zooms narrower than 40 units -> snap-back to the last range.
  ygate <- reactiveProxy(
    get = yrange,
    set = \(v) if (is.null(v) || (v[2] - v[1]) >= 40) yrange(v)
  )

  # bslib `page_sidebar`/`sidebar` defer their wrapper to render-time
  # `.renderHooks` (resolved by process_tags since #27) — so this e2e fixture
  # also exercises that render-hook path in a real browser, not just the static
  # grid markup. The control ids are unchanged; the harness targets them all the
  # same inside the sidebar.
  page_sidebar(
    title = "PlotlyOutput e2e kitchen sink",

    sidebar = sidebar(
      # `id` lands on the sidebar `<aside>` — a render-hook element (#27) — so
      # the e2e suite can assert it resolved to a non-zero-width element.
      id = "control-panel",
      title = "Controls",
      tags$label(\() paste0("Min horsepower: ", hp_min())),
      tags$input(
        id = "hp-slider",
        type = "range", class = "form-range",
        min = "0", max = "300", step = "10",
        value = reactiveProxy(get = hp_min, set = \(v) hp_min(as.integer(v)))
      ),
      tags$label(class = "mt-2", "Drag mode"),
      tags$select(
        id = "dragmode",
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
          id = "btn-economy",
          class = "btn btn-sm btn-outline-primary",
          onClick = \() { xrange(c(20, 35)); ygate(c(50, 130)) },
          "Zoom to economy cars"
        ),
        tags$button(
          id = "btn-hide8",
          class = "btn btn-sm btn-outline-secondary",
          onClick = \() visible(c("8" = "legendonly")),
          "Hide 8-cyl trace"
        ),
        tags$button(
          id = "btn-sports",
          class = "btn btn-sm btn-outline-primary",
          onClick = \() sel_proxy(c("Maserati Bora", "Ferrari Dino")),
          "Select sports cars"
        ),
        tags$button(
          id = "btn-clear",
          class = "btn btn-sm btn-outline-secondary",
          onClick = \() sel_proxy(character()),
          "Clear selection"
        ),
        tags$button(
          id = "btn-hover-x",
          class = "btn btn-sm btn-outline-info",
          onClick = \() hovermode("x"),
          "Hovermode x"
        ),
        tags$button(
          id = "btn-reset",
          class = "btn btn-sm btn-outline-danger",
          onClick = \() {
            revision(revision() + 1L)
            xrange(NULL); yrange(NULL)
            sel_proxy(character()); visible(NULL)
          },
          "Reset view"
        )
      )
    ),

    PlotlyOutput(
      \() {
        df <- filtered()
        plot_ly(
          df,
          x = ~mpg, y = ~hp, color = ~cyl,
          type = "scatter", mode = "markers",
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
      xaxis_range      = xrange,
      yaxis_range      = ygate,
      dragmode         = dragmode,
      hovermode        = hovermode,
      selected_ids     = sel_proxy,
      trace_visibility = visible,
      onClick       = \(e) clicked(e$points[[1]]),
      onHover       = \(e) hovered(e$points[[1]]),
      onLegendClick = \(e) legend(e$curveNumber),
      onDoubleclick = \() last_evt("double-click (autoscale)"),
      onRelayout    = \(e) {
        keys <- names(e)
        last_evt(if (length(keys)) paste(keys, collapse = ", ") else "(empty)")
      },
      container = tags$div(style = "height: 480px;")
    ),

    tags$div(
      class = "row mt-2 small",
      tags$div(
        class = "col-md-4",
        tags$strong("Viewport"), tags$br(),
        tags$span(id = "ro-viewport", \() {
          fmt <- \(r) if (is.null(r)) "auto" else paste0("[", round(r[1], 1), ", ", round(r[2], 1), "]")
          paste0("mpg: ", fmt(xrange()), " | hp: ", fmt(yrange()))
        }),
        tags$br(),
        tags$span(id = "ro-dragmode", \() paste0("dragmode: ", dragmode())),
        tags$br(),
        tags$span(id = "ro-hovermode", \() paste0("hovermode: ", hovermode()))
      ),
      tags$div(
        class = "col-md-4",
        tags$strong("Selection"), tags$br(),
        tags$span(id = "ro-selection", \() {
          s <- cars$name[sel_idx()]
          if (!length(s)) "none" else paste0(length(s), ": ", paste(s, collapse = ", "))
        }),
        tags$br(),
        tags$span(id = "ro-visibility", \() {
          v <- visible()
          if (is.null(v) || !length(v)) "visibility: default"
          else paste0("visibility: ", paste(names(v), v, sep = "=", collapse = ", "))
        })
      ),
      tags$div(
        class = "col-md-4",
        tags$strong("Events"), tags$br(),
        tags$span(id = "ro-click", \() {
          p <- clicked()
          if (is.null(p)) "click a point" else paste0("clicked: ", p$customdata, " (", p$x, " mpg, ", p$y, " hp)")
        }),
        tags$br(),
        tags$span(id = "ro-relayout", \() paste0("last relayout: ", last_evt())),
        tags$br(),
        tags$span(id = "ro-hover", \() {
          p <- hovered()
          if (is.null(p)) "hover a point" else paste0("hover: ", p$customdata)
        }),
        tags$br(),
        tags$span(id = "ro-legend", \() {
          cn <- legend()
          if (is.null(cn)) "no legend click" else paste0("legend: ", cn)
        })
      )
    )
  )
}

App
