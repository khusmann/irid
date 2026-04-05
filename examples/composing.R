# Composing Components
#
# A irid component is just a function that returns a tag tree. Pass
# reactiveVals as arguments to share state between components — the parent
# owns the state, children read and write it.
#
# This example creates two independent counters whose values feed a shared
# total displayed above them.

library(irid)
library(bslib)

Counter <- function(label, count) {
  card(
    card_header(label),
    card_body(
      tags$h2(
        class = "text-center",
        \() paste("Count:", count())
      ),
      tags$input(
        type = "range", min = 0, max = 100,
        value = count,
        onInput = \(event) count(event$valueAsNumber)
      ),
      tags$button(
        class = "btn btn-outline-secondary btn-sm",
        disabled = \() count() == 0,
        onClick = \() count(0),
        "Reset"
      )
    )
  )
}

App <- function() {
  count_a <- reactiveVal(0)
  count_b <- reactiveVal(0)

  page_fluid(
    tags$h3(
      class = "text-center",
      \() paste("Total:", count_a() + count_b())
    ),
    layout_columns(
      Counter("A", count_a),
      Counter("B", count_b)
    ),
    tags$button(
      class = "btn btn-outline-primary",
      disabled = \() count_a() == 0 && count_b() == 0,
      onClick = \() { count_a(0); count_b(0) },
      "Reset All"
    )
  )
}

iridApp(App)
