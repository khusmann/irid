# Temperature Converter
#
# A classic reactive UI challenge: two inputs representing the same value in
# different units, where editing either one should update the other. In
# traditional Shiny this requires careful coordination to avoid feedback loops.
# With nacre's controlled inputs, the solution is straightforward — one
# `reactiveVal` holds the canonical Celsius value, and the Fahrenheit
# thermometer derives from it via a `reactive()`. Both thermometers stay in
# sync automatically.
#
# The app is composed from two reusable components: `Thermometer` (a labeled
# vertical slider) and `TemperatureDisplay` (a readout with a zone badge).

library(shiny)
library(bslib)
library(nacre)

c_to_f <- function(c) round(c * 9 / 5 + 32, 1)
f_to_c <- function(f) round((f - 32) * 5 / 9, 1)

Thermometer <- function(label, value, on_change, min, max) {
  tags$div(
    class = "text-center",
    tags$label(class = "form-label fw-semibold", label),
    tags$div(
      class = "d-flex flex-column align-items-center",
      tags$small(class = "text-muted", max),
      tags$input(
        type = "range", min = min, max = max,
        style = "appearance: slider-vertical; height: 200px; width: 30px;",
        value = value,
        onInput = event_throttle(\(event) on_change(event$valueAsNumber), 100)
      ),
      tags$small(class = "text-muted", min)
    )
  )
}

TemperatureDisplay <- function(celsius, fahrenheit) {
  temp_zone <- function(c) {
    zones <- list(
      list(max = 0, label = "Freezing", color = "info", emoji = "\u2744\uFE0F"),
      list(max = 15, label = "Cold", color = "primary", emoji = "\U0001F327\uFE0F"),
      list(max = 30, label = "Comfortable", color = "success", emoji = "\u2600\uFE0F"),
      list(max = Inf, label = "Hot", color = "danger", emoji = "\U0001F525")
    )
    Find(\(z) c <= z$max, zones)
  }

  tags$div(
    class = "text-center mb-3",
    tags$div(
      class = "fs-4 fw-bold",
      \() paste0(celsius(), "\u00B0C = ", fahrenheit(), "\u00B0F")
    ),
    tags$div(
      class = "mt-1",
      tags$span(
        class = \() {
          z <- temp_zone(celsius())
          paste("badge fs-6", paste0("bg-", z$color))
        },
        \() temp_zone(celsius())$label
      )
    )
  )
}

TemperatureApp <- function() {
  celsius <- reactiveVal(20)
  fahrenheit <- reactive(c_to_f(celsius()))

  page_fluid(
    tags$div(
      class = "mx-auto",
      style = "max-width: 500px;",

      tags$h2(class = "mt-4 mb-3", "Temperature Converter"),

      card(
        card_body(
          TemperatureDisplay(celsius, fahrenheit),

          tags$div(
            class = "d-flex justify-content-evenly align-items-center",
            Thermometer("Celsius", celsius, celsius, -40, 60),
            Thermometer("Fahrenheit", fahrenheit, \(f) celsius(f_to_c(f)), -40, 140)
          )
        )
      )
    )
  )
}

nacreApp(TemperatureApp)
