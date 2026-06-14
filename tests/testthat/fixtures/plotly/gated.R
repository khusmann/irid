# gated.R — e2e rows 20-21: per-flush coalescing + destroy on gate flip.
#
# - Row 20: "Bump" writes the spec (new data) AND a range in ONE handler, so both
#   land in the same Shiny flush. The widget must coalesce them into a single
#   update({spec, xaxis_range}) -> one Plotly.react (no flash). A plotly_afterplot
#   counter wired by the test measures redraws.
# - Row 21: "Toggle" flips a `When` gate that mounts/unmounts the plot. Unmounting
#   must run the widget's destroy() (Plotly.purge) and remove its container.

library(irid)
library(plotly)

App <- function() {
  show <- reactiveVal(TRUE)
  n    <- reactiveVal(20L)     # data size -> spec changes
  xr   <- reactiveVal(NULL)

  App_plot <- function() {
    k <- n()
    plot_ly(x = seq_len(k), y = sin(seq_len(k) / 3),
            type = "scatter", mode = "lines", name = "wave") |>
      layout(uirevision = "keep")
  }

  tags$div(
    class = "p-3",
    tags$div(
      class = "d-flex gap-2 mb-2",
      tags$button(id = "btn-bump", class = "btn btn-sm btn-primary",
                  onClick = \() { n(n() + 10L); xr(c(2, 8)) },
                  "Bump (spec + range together)"),
      tags$button(id = "btn-toggle", class = "btn btn-sm btn-secondary",
                  onClick = \() show(!show()), "Toggle plot")
    ),
    When(
      show,
      \() PlotlyOutput(
        App_plot,
        xaxis_range = xr,
        container = tags$div(style = "height: 380px;")
      ),
      \() tags$div(id = "plot-hidden", "plot hidden")
    )
  )
}

App
