# Fixture for the controlled-input optimistic-update gate + reactive DOM writes
# (test-controlled-input-e2e.R). The seq math is vitest-covered (core/seq); this
# exercises the BROWSER-side application in handlers.ts that vitest can't see:
#
#  - #plain  (value = text):        a same-value echo to a focused input is a
#                                   no-op skip (cursor preserved).
#  - #trunc  (value = truncated):   a server transform (10-char cap) applies
#                                   even while the input is focused.
#  - #btn-clear -> text(""):        a programmatic write from ANOTHER element
#                                   applies while #trunc is focused.
#  - #ro-text (\() text()):         reactive text child — irid-attr target=text.
#  - #box data-active:              reactive DOM attribute — setAttribute on a
#                                   value, removeAttribute on FALSE.

library(irid)

App <- function() {
  text   <- reactiveVal("")
  active <- reactiveVal(FALSE)

  truncated <- reactiveProxy(
    get = \() substr(text(), 1, 10),
    set = \(v) text(substr(v, 1, 10))
  )

  tags$div(
    tags$input(id = "plain", type = "text", value = text),
    tags$input(id = "trunc", type = "text", value = truncated),
    tags$button(id = "btn-clear", onClick = \() text(""), "clear"),
    tags$span(id = "ro-text", \() text()),
    tags$div(id = "box", "data-active" = \() if (active()) "yes" else FALSE),
    tags$button(id = "btn-toggle", onClick = \() active(!active()), "toggle")
  )
}

App
