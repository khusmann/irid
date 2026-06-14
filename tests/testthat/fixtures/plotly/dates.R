# dates.R — e2e: a date-time x-axis. Plotly reports a date axis range as ISO
# date-time *strings* (not numbers), so the wire-boundary coercion must preserve
# them as character — `as.numeric` would turn every bound into NA. This fixture
# binds `xaxis_range` over a date axis and exercises both directions plus a
# rejecting proxy (snap-back), so the round-trip is asserted end-to-end.

library(irid)
library(plotly)

App <- function() {
  xr <- reactiveVal(NULL)

  # Reject any window narrower than ~30 days -> snap-back to the last range.
  # Operates on the date *strings* the client speaks; a too-narrow zoom reverts.
  xgate <- reactiveProxy(
    get = xr,
    set = \(v) {
      if (is.null(v) || length(v) != 2L) { xr(v); return() }
      span <- as.numeric(diff(as.Date(substr(v, 1, 10))))
      if (span >= 30) xr(v)
    }
  )

  ts <- data.frame(
    t = as.Date("2020-01-01") + seq(0, 364, by = 1),
    y = cumsum(rnorm(365))
  )

  App_plot <- function() {
    plot_ly(ts, x = ~t, y = ~y, type = "scatter", mode = "lines") |>
      layout(uirevision = "keep", xaxis = list(title = "date"))
  }

  tags$div(
    class = "p-3",
    tags$button(
      id = "btn-q2", class = "btn btn-sm btn-primary mb-2",
      onClick = \() xr(c("2020-04-01", "2020-06-30")),
      "Zoom to Q2"
    ),
    tags$button(
      id = "btn-reset", class = "btn btn-sm btn-secondary mb-2",
      onClick = \() xr(NULL),
      "Reset"
    ),
    PlotlyOutput(
      App_plot,
      xaxis_range = xgate,
      container = tags$div(style = "height: 360px;")
    ),
    # The readout reflects the server-side reactiveVal verbatim — the source of
    # truth the test compares gd.layout.xaxis.range against. A date range shows
    # its ISO bounds; an NA (the old as.numeric bug) would surface as "NA".
    tags$div(
      class = "small mt-2",
      tags$span(id = "ro-xrange", \() {
        v <- xr()
        if (is.null(v)) "x: auto" else paste0("x: ", v[1], " .. ", v[2])
      })
    )
  )
}

App
