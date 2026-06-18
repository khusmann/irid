# Fixture for client-side event filtering (wire_dom_opts(filter = ...)).
#
# A text input carries a `value` autobind (input channel) plus an `onKeyDown`
# handler gated to Enter via a client-side filter. The handler bumps a server
# counter and records the key it saw. Non-Enter keydowns must be dropped in the
# browser and never reach the server, so the counter only ever moves on Enter.
# See test-event-filter-e2e.R.

library(irid)

function() {
  field <- reactiveVal("")
  enter_count <- reactiveVal(0L)
  last_key <- reactiveVal("")

  tags$div(
    tags$input(
      id = "field",
      type = "text",
      value = field,
      onKeyDown = wire(
        \(e) {
          enter_count(enter_count() + 1L)
          last_key(e$key)
        },
        dom_opts = wire_dom_opts(filter = "e.key === 'Enter'")
      )
    ),
    tags$span(id = "ro-count", \() as.character(enter_count())),
    tags$span(id = "ro-key", \() last_key())
  )
}
