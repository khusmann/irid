# End-to-end test for the flush-render bindAll scope (applyRender in handlers.ts).
# One `irid-render` can carry mutates for several disjoint control-flow regions
# (see fixtures/render.R). The single post-pass `Shiny.bindAll` must bind every
# mutated subtree so a Shiny output inserted by ANY mutate gets wired — not only
# the first mutate's subtree. See helper-e2e.R and TESTING.md for gating.
#
#   IRID_E2E=1 Rscript -e 'devtools::test(filter = "render-e2e")'

# textContent of the text output inside a region (empty string if it never bound).
region_text <- function(app, region) {
  as.character(e2e_eval(app, sprintf(
    "(document.querySelector('#%s .shiny-text-output') || {}).textContent || ''",
    region
  )))
}

test_that("one flush's render binds Shiny outputs from every mutate, not just the first", {
  app <- e2e_app("render.R")
  e2e_wait_idle(app)

  # Both When branches start empty — no output element yet.
  expect_false(e2e_eval(app, "!!document.querySelector('#region-a .shiny-text-output')"))
  expect_false(e2e_eval(app, "!!document.querySelector('#region-b .shiny-text-output')"))

  # One click flips BOTH Whens in the same flush -> two `mutate` ops in one
  # `irid-render`, inserting a text output into each disjoint region.
  e2e_click(app, "#btn-show")

  # Both output elements are inserted regardless (the mutate runs); the question
  # is whether each got bound. Wait for the elements, then for reactive idle so a
  # bound output has received its value.
  e2e_wait_until(app, paste(
    "document.querySelector('#region-a .shiny-text-output') &&",
    "document.querySelector('#region-b .shiny-text-output')"
  ))
  e2e_wait_idle(app)

  # Both must have rendered. The bug bound only the first mutate's subtree, so
  # the other region's output stayed unbound and blank.
  expect_match(region_text(app, "region-a"), "ALPHA-BOUND")
  expect_match(region_text(app, "region-b"), "BRAVO-BOUND")

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})
