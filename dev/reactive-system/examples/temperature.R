# reactiveProxy for bidirectional transform: store holds Celsius, input shows Fahrenheit

library(irid)

TemperatureInput <- function(temp, label = "Temperature") {
  tags$div(
    tags$label(label),
    tags$input(type = "number", value = temp)
  )
}

TemperatureApp <- function() {
  state <- reactiveStore(list(
    temp_c = 20
  ))

  temp_f <- reactiveProxy(state$temp_c,
    get = \(c) c * 9/5 + 32,
    set = \(f) state$temp_c((as.numeric(f) - 32) * 5/9)
  )

  page_fluid(
    tags$h2("Temperature converter"),
    TemperatureInput(state$temp_c, label = "Celsius"),
    TemperatureInput(temp_f,       label = "Fahrenheit"),
    tags$p(\() sprintf("Stored value: %.2f°C", state$temp_c()))
  )
}

iridApp(TemperatureApp)
