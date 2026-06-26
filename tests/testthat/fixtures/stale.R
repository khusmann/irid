# Fixture for the stale UI indicator (test-stale-e2e.R, stale.ts).
#
# stale_timeout is lowered to 150ms so the show timer fires quickly. A "slow"
# handler sleeps well past it (the indicator must appear while the server is
# busy, then clear once it settles); a "fast" handler finishes under it (the
# show timer is reset on idle before it ever fires, so the bar never appears).
# Set at source time — irid_send_config reads the option at session start.

library(irid)

options(irid.stale_timeout = 150)

App <- function() {
  slow_n <- reactiveVal(0L)
  fast_n <- reactiveVal(0L)

  tags$div(
    tags$button(
      id = "btn-slow",
      onClick = \() { Sys.sleep(0.7); slow_n(slow_n() + 1L) },
      "slow"
    ),
    tags$button(
      id = "btn-fast",
      onClick = \() { Sys.sleep(0.03); fast_n(fast_n() + 1L) },
      "fast"
    ),
    tags$span(id = "ro-slow", \() as.character(slow_n())),
    tags$span(id = "ro-fast", \() as.character(fast_n()))
  )
}

App
