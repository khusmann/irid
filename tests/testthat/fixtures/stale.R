# Fixture for the stale UI indicator (test-stale-e2e.R, stale.ts).
#
# stale_timeout sits at 400ms. A "slow" handler (700ms) sleeps well past it (the
# indicator must appear while the server is busy, then clear once it settles); a
# "fast" handler (30ms) finishes well under it (the show timer is reset on idle
# before it ever fires, so the bar never appears). The threshold is pulled toward
# the slow handler rather than the 30/700 log-midpoint (~145ms) on purpose:
# round-trip latency only adds to the fast side's busy window, so a wider fast
# margin is what keeps a slow CI runner from crossing it and flipping the bar on
# (E2E_TIMEOUT_SCALE scales the wait ceilings but not this fixed threshold). The
# slow side keeps a 1.75x+ margin on a rock-solid Sys.sleep, so it loses nothing.
# Set at source time — irid_send_config reads the option at session start.

library(irid)

options(irid.stale_timeout = 400)

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
