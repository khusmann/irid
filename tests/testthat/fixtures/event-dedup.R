# Fixture for the payload-envelope dedup guard (test-event-dedup-e2e.R).
#
# A button whose immediate onClick handler bumps a counter. Clicking it twice
# back-to-back (same handler, no varying user payload) must bump the counter
# twice — every event-priority send reaches the server. This locks the `nonce`
# deletion (protocol step 5): irid no longer ships a Math.random() distinctness
# token, relying on {priority:"event"} (which bypasses Shiny's no-resend dedup)
# plus the per-channel `seq` in the envelope.

library(irid)

function() {
  count <- reactiveVal(0L)

  tags$div(
    tags$button(id = "bump", "bump", onClick = \() count(count() + 1L)),
    tags$span(id = "ro-count", \() as.character(count()))
  )
}
