# Fixture for the flush-render bindAll scope (test-render-e2e.R).
#
# Two control-flow regions in DISJOINT DOM subtrees (neither wrapper div is an
# ancestor of the other), both gated on the SAME reactive. One click flips both
# `When`s in one flush -> two `mutate` ops ride one `irid-render`. Each branch
# inserts a Shiny output (a text output), which only renders once
# `Shiny.bindAll` runs on its subtree. The render's single post-pass bindAll
# must therefore cover EVERY mutated subtree, not just the first — otherwise the
# second region's output is inserted but never bound, and stays blank.

library(irid)

App <- function() {
  shown <- reactiveVal(FALSE)

  tags$div(
    tags$button(id = "btn-show", onClick = \() shown(TRUE), "show"),

    tags$div(
      id = "region-a",
      When(shown, \() Output(shiny::renderText, shiny::textOutput, \() "ALPHA-BOUND"))
    ),
    tags$div(
      id = "region-b",
      When(shown, \() Output(shiny::renderText, shiny::textOutput, \() "BRAVO-BOUND"))
    )
  )
}

App
