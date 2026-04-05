# Counter
#
# The simplest possible irid component. Demonstrates the three core bindings
# in one place: a reactive text child, a reactive attribute, and a direct
# event handler.
#
#   - `count` appears as a child of `tags$p()` -- its value is displayed
#     inline and updates when the reactive changes.
#   - The button's `disabled` attribute is a function, so it re-evaluates
#     whenever `count` changes.
#   - `onClick` is wired directly on the tag. No observers, no input/output
#     IDs, no `updateActionButton()` or `observeEvent()`.

library(irid)

Counter <- function() {
  count <- reactiveVal(0)

  tags$div(
    tags$p("Count: ", count),
    tags$button(
      "Increment",
      disabled = \() count() >= 10,
      onClick = \(ev) count(count() + 1)
    )
  )
}

iridApp(Counter)
