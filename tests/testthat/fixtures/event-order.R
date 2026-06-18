# Fixture for the per-element event-ordering queue (client-event-queue).
#
# Reproduces the todo race: a text input with a `value` autobind (debounced
# input channel, 200ms) plus an `onKeyDown` Enter handler (immediate) that
# appends the CURRENT bound value to a list. Pressing Enter right after typing —
# before the debounce flushes — must still append the typed value, because the
# queue flushes the pending input before sending the keydown. See
# test-event-order-e2e.R.

library(irid)

function() {
  field <- reactiveVal("")
  added <- reactiveVal(character())

  add <- function() added(c(added(), field()))

  tags$div(
    tags$input(
      id = "field",
      type = "text",
      value = field,
      onKeyDown = wire(
        \() add(),
        dom_opts = wire_dom_opts(filter = "e.key === 'Enter'")
      )
    ),
    tags$span(id = "ro-added", \() paste(added(), collapse = "|")),
    tags$span(id = "ro-field", \() field())
  )
}
