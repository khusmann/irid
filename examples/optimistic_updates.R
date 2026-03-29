library(shiny)
library(bslib)
library(nacre)


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
