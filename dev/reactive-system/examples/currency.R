# reactiveProxy for formatting: store holds cents, input shows formatted dollars

library(irid)

CurrencyInput <- function(amount, label = "Amount") {
  tags$div(
    tags$label(label),
    tags$input(value = amount)
  )
}

parse_dollars <- function(v) {
  round(as.numeric(gsub("[$,]", "", v)) * 100)
}

format_dollars <- function(cents) {
  sprintf("$%.2f", cents / 100)
}

CurrencyApp <- function() {
  state <- reactiveStore(list(
    price_cents    = 1999L,
    shipping_cents = 499L
  ))

  price_display <- reactiveProxy(state$price_cents,
    get = format_dollars,
    set = \(v) state$price_cents(parse_dollars(v))
  )

  shipping_display <- reactiveProxy(state$shipping_cents,
    get = format_dollars,
    set = \(v) state$shipping_cents(parse_dollars(v))
  )

  page_fluid(
    CurrencyInput(price_display,    label = "Price"),
    CurrencyInput(shipping_display, label = "Shipping"),
    tags$p(\() {
      total <- state$price_cents() + state$shipping_cents()
      paste("Total:", format_dollars(total))
    })
  )
}

iridApp(CurrencyApp)
