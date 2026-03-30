# Optimistic Updates
#
# When a user types into a controlled input, nacre applies the change
# immediately in the browser before the server round-trip completes — an
# *optimistic update*. If the server responds with a different value (e.g. it
# truncates the input), the browser reconciles to the server's version. This
# keeps the UI feeling instant while still letting the server be the authority
# on state.
#
# This example lets you explore three scenarios and dial in a simulated server
# delay to make the reconciliation visible:
#
# 1. Programmatic clear — a button sets the value to "" server-side; the input
#    should empty immediately.
# 2. Server transform — the server enforces a 10-character limit; typing past
#    it snaps back.
# 3. Mirror — a read-only input always shows the confirmed server value, useful
#    for verifying what the server actually holds.

library(nacre)
library(bslib)

OptimisticUpdates <- function() {
  text <- reactiveVal("")
  max_chars <- 10L
  delay_ms <- reactiveVal(0L)

  page_fluid(
    card(
      card_header("Optimistic Update Tests"),
      card_body(
        tags$h6("1. Programmatic clear"),
        tags$p(class = "text-muted", "Type something, click Clear. Input should empty."),
        tags$div(
          class = "input-group mb-3",
          tags$input(type = "text", class = "form-control",
            placeholder = "Type here...",
            value = text,
            onInput = \(event) text(event$value)),
          tags$button(class = "btn btn-outline-secondary",
            onClick = \() text(""), "Clear")
        ),

        tags$h6(paste0("2. Server transform (max ", max_chars, " chars)")),
        tags$p(class = "text-muted", "Type past the limit. Server truncates to 10 chars."),
        tags$input(type = "text", class = "form-control mb-3",
          value = \() substr(text(), 1, max_chars),
          onInput = \(event) text(substr(event$value, 1, max_chars))),

        tags$h6("3. Server echo (mirror)"),
        tags$p(class = "text-muted", "Read-only mirror. Should always match server state."),
        tags$input(type = "text", class = "form-control mb-3",
          value = text, disabled = \() TRUE),

        tags$p(
          class = "text-muted",
          \() paste0("Server value (", nchar(text()), " chars): \"", text(), "\"")
        )
      )
    ),
    card(
      card_header("Debug: Simulated Server Delay"),
      card_body(
        tags$label("for" = "delay-slider", class = "form-label",
          \() paste0("Delay: ", delay_ms(), " ms")),
        tags$input(id = "delay-slider", type = "range",
          class = "form-range", min = "0", max = "3000", step = "50",
          value = delay_ms,
          onInput = \(event) {
            val <- as.integer(event$value)
            delay_ms(val)
            options(nacre.debug.latency = val / 1000)
          })
      )
    )
  )
}

nacreApp(OptimisticUpdates)

