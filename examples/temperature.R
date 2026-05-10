# Temperature Converter
#
# A classic reactive UI challenge: two inputs representing the same value in
# different units, where editing either one should update the other. In
# traditional Shiny this needs careful coordination to avoid feedback loops.
# With irid the canonical Celsius value lives in a single `reactiveVal`, and
# Fahrenheit is a `reactiveProxy` view that converts in both directions —
# auto-bind keeps both thermometers in sync without any extra wiring.

library(irid)
library(bslib)

c_to_f <- function(c) round(c * 9 / 5 + 32, 1)
f_to_c <- function(f) round((f - 32) * 5 / 9, 1)

# Range inputs deliver strings on write. Coercing here means callers can pass
# any numeric callable without thinking about DOM types.
Thermometer <- function(label, value, min, max) {
  tags$div(
    class = "text-center",
    tags$label(class = "form-label fw-semibold", label),
    tags$div(
      class = "d-flex flex-column align-items-center",
      tags$small(class = "text-muted", max),
      tags$input(
        type = "range", min = min, max = max,
        style = "appearance: slider-vertical; height: 200px; width: 30px;",
        value = reactiveProxy(get = value, set = \(v) value(as.numeric(v))),
        .event = event_throttle(100)
      ),
      tags$small(class = "text-muted", min)
    )
  )
}

zones <- list(
  list(max = 0,   label = "Freezing",    color = "info"),
  list(max = 15,  label = "Cold",        color = "primary"),
  list(max = 30,  label = "Comfortable", color = "success"),
  list(max = Inf, label = "Hot",         color = "danger")
)

TemperatureDisplay <- function(celsius, fahrenheit) {
  zone <- reactive(Find(\(z) celsius() <= z$max, zones))
  tags$div(
    class = "text-center mb-3",
    tags$div(
      class = "fs-4 fw-bold",
      \() paste0(celsius(), "\u00B0C = ", fahrenheit(), "\u00B0F")
    ),
    tags$div(
      class = "mt-1",
      tags$span(
        class = \() paste0("badge fs-6 bg-", zone()$color),
        \() zone()$label
      )
    )
  )
}

TemperatureApp <- function() {
  celsius <- reactiveVal(20)
  fahrenheit <- reactiveProxy(
    get = \() c_to_f(celsius()),
    set = \(f) celsius(f_to_c(f))
  )

  page_fluid(
    card(
      card_body(
        TemperatureDisplay(celsius, fahrenheit),
        tags$div(
          class = "d-flex justify-content-evenly align-items-center",
          Thermometer("Celsius", celsius, -40, 60),
          Thermometer("Fahrenheit", fahrenheit, -40, 140)
        )
      )
    )
  )
}

iridApp(TemperatureApp)
