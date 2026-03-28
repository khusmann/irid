library(shiny)
library(bslib)
library(nacre)

c_to_f <- function(c) round(c * 9 / 5 + 32, 1)
f_to_c <- function(f) round((f - 32) * 5 / 9, 1)

temp_zone <- function(c) {
  zones <- list(
    list(max = 0, label = "Freezing", color = "info"),
    list(max = 15, label = "Cold", color = "primary"),
    list(max = 30, label = "Comfortable", color = "success"),
    list(max = Inf, label = "Hot", color = "danger")
  )
  Find(\(z) c <= z$max, zones)
}

Slider <- function(val, on_change, min, max) {
  tags$div(
    class = "d-flex flex-column align-items-center",
    tags$small(class = "text-muted", max),
    tags$input(
      type = "range", min = min, max = max,
      style = "appearance: slider-vertical; height: 200px; width: 30px;",
      value = val,
      onInput = event_throttle(\(event) on_change(event$valueAsNumber), 100)
    ),
    tags$small(class = "text-muted", min)
  )
}

TemperatureApp <- function() {
  celsius <- reactiveVal(0)
  fahrenheit <- reactive(c_to_f(celsius()))

  page_fluid(
    tags$div(
      class = "mx-auto",
      style = "max-width: 500px;",

      tags$h2(class = "mt-4 mb-3", "Temperature Converter"),

      card(
        card_body(
          tags$div(
            class = "d-flex justify-content-evenly align-items-center mb-3",
            tags$div(
              class = "text-center",
              tags$label(class = "form-label fw-semibold", "Celsius"),
              tags$input(
                type = "number",
                class = "form-control form-control-lg text-center",
                value = celsius,
                onInput = \(event) {
                  c <- event$valueAsNumber
                  if (!is.na(c)) celsius(c)
                }
              ),
              tags$div(class = "mt-3",
                Slider(celsius, celsius, -40, 60)
              )
            ),
            tags$span(class = "fs-4 text-muted", "="),
            tags$div(
              class = "text-center",
              tags$label(class = "form-label fw-semibold", "Fahrenheit"),
              tags$input(
                type = "number",
                class = "form-control form-control-lg text-center",
                value = fahrenheit,
                onInput = \(event) {
                  f <- event$valueAsNumber
                  if (!is.na(f)) celsius(f_to_c(f))
                }
              ),
              tags$div(class = "mt-3",
                Slider(fahrenheit, \(f) celsius(f_to_c(f)), -40, 140)
              )
            )
          ),

          tags$div(
            class = "text-center mt-3",
            tags$span(
              class = \() {
                z <- temp_zone(celsius())
                paste("badge fs-6", paste0("bg-", z$color))
              },
              \() temp_zone(celsius())$label
            )
          )
        )
      )
    )
  )
}

nacreApp(TemperatureApp)
