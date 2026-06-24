# Output and its wrappers (R/primitives.R) + their process_tags extraction:
# each Output node becomes a `shiny_outputs` {id, render_call} entry, and is
# replaced in the static tree by its output_fn tag carrying that id.

# --- Constructor wiring ------------------------------------------------------

test_that("Output pairs a render fn with an output fn", {
  o <- Output(shiny::renderText, shiny::textOutput, function() "hi")
  expect_s3_class(o, "irid_output")
  expect_s3_class(o$render_call, "shiny.render.function")
  expect_identical(o$output_fn, shiny::textOutput)
})

# --- process_tags extraction -------------------------------------------------

test_that("Output emits a shiny_outputs entry + an output tag with its id", {
  res <- process_tags(
    Output(shiny::renderText, shiny::textOutput, function() "hi")
  )
  expect_length(res$shiny_outputs, 1L)
  so <- res$shiny_outputs[[1]]
  expect_match(so$id, "^irid-")
  expect_s3_class(so$render_call, "shiny.render.function")
  # the output container carries the id
  expect_match(as.character(res$tag), so$id)
})

test_that("an Output nested in a tag tree is extracted and replaced in place", {
  res <- process_tags(tags$div(PlotOutput(function() plot(1))))
  expect_length(res$shiny_outputs, 1L)
  html <- as.character(res$tag)
  expect_match(html, "shiny-plot-output")
  expect_match(html, res$shiny_outputs[[1]]$id)
})

test_that("PlotOutput pairs renderPlot with plotOutput", {
  res <- process_tags(PlotOutput(function() plot(1)))
  expect_length(res$shiny_outputs, 1L)
  expect_match(as.character(res$tag), "shiny-plot-output")
})

test_that("TableOutput pairs renderTable with tableOutput", {
  res <- process_tags(TableOutput(function() data.frame(x = 1)))
  expect_length(res$shiny_outputs, 1L)
  expect_match(as.character(res$tag), res$shiny_outputs[[1]]$id)
})

test_that("Output forwards output_fn args (e.g. width/height) to the tag", {
  res <- process_tags(
    PlotOutput(function() plot(1), width = "300px", height = "200px")
  )
  html <- as.character(res$tag)
  expect_match(html, "300px")
  expect_match(html, "200px")
})

test_that("DTOutput errors without DT, extracts cleanly when DT present", {
  if (requireNamespace("DT", quietly = TRUE)) {
    res <- process_tags(DTOutput(function() data.frame(x = 1)))
    expect_length(res$shiny_outputs, 1L)
    expect_match(as.character(res$tag), res$shiny_outputs[[1]]$id)
  } else {
    expect_error(DTOutput(function() NULL), "DT")
  }
})

test_that("an Output node used as a slot value (not a child) errors", {
  expect_error(
    process_tags(tags$div(class = PlotOutput(\() plot(1)))),
    "irid_output.*children"
  )
})

test_that("multiple Output nodes get distinct ids", {
  res <- process_tags(tags$div(
    PlotOutput(function() plot(1)),
    TableOutput(function() data.frame(x = 1))
  ))
  expect_length(res$shiny_outputs, 2L)
  ids <- vapply(res$shiny_outputs, function(s) s$id, character(1))
  expect_equal(length(unique(ids)), 2L)
})

# --- mount ------------------------------------------------------------------

test_that("mounting assigns each Output's render_call to session$output", {
  s <- shiny::MockShinySession$new()
  res <- process_tags(
    Output(shiny::renderText, shiny::textOutput, function() "hello")
  )
  handle <- shiny::isolate(irid:::irid_mount_processed(res, s))
  id <- res$shiny_outputs[[1]]$id
  # The render_call was installed under its id and renders the value.
  expect_equal(s$getOutput(id), "hello")
  handle$destroy()
})
