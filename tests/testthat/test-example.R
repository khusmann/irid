# The iridExample runner (R/example.R): dependency parsing, the up-front
# dependency check, and the no-arg / unknown-name listing behaviour. Launching
# an actual app needs a running server, so that path is exercised with runApp
# stubbed — asserting which directory and display mode it hands off.

# --- example_deps ------------------------------------------------------------

write_example <- function(...) {
  path <- withr::local_tempfile(fileext = ".R", .local_envir = parent.frame())
  writeLines(c(...), path)
  path
}

test_that("example_deps collects library/require packages minus irid", {
  path <- write_example(
    "library(irid)",
    "library(bslib)",
    "require(plotly)"
  )
  expect_equal(example_deps(path), c("bslib", "plotly"))
})

test_that("example_deps handles both symbol and string package names", {
  path <- write_example('library("bslib")', "library(DT)")
  expect_equal(example_deps(path), c("bslib", "DT"))
})

test_that("example_deps returns empty for an irid-only example", {
  path <- write_example("library(irid)", "iridApp(function() NULL)")
  expect_equal(example_deps(path), character())
})

# --- check_example_deps ------------------------------------------------------

test_that("check_example_deps passes silently when deps are installed", {
  path <- write_example("library(irid)", "library(shiny)")
  expect_silent(check_example_deps(path, "demo"))
})

test_that("check_example_deps names a single missing package", {
  path <- write_example("library(irid)", "library(nopkgxyz)")
  expect_error(
    check_example_deps(path, "demo"),
    "nopkgxyz",
    class = "rlang_error"
  )
})

test_that("check_example_deps names all missing packages", {
  path <- write_example("library(nopkgA)", "library(nopkgB)")
  err <- expect_error(check_example_deps(path, "demo"))
  expect_match(conditionMessage(err), "nopkgA")
  expect_match(conditionMessage(err), "nopkgB")
})

# --- iridExample listing -----------------------------------------------------

test_that("iridExample() lists the shipped examples and returns them invisibly", {
  expect_message(res <- iridExample(), "Available irid examples")
  expect_type(res, "character")
  expect_true(all(c("todo", "old-faithful") %in% res))
  expect_equal(res, sort(res))
})

test_that("iridExample() with an unknown name warns and lists", {
  expect_warning(
    expect_message(iridExample("does-not-exist"), "Available irid examples"),
    "No irid example named"
  )
})

test_that("iridExample() runs the example directory in showcase mode by default", {
  captured <- NULL
  local_mocked_bindings(
    runApp = function(appDir, ..., display.mode) {
      captured <<- list(dir = appDir, mode = display.mode)
      invisible(NULL)
    },
    .package = "shiny"
  )
  expect_no_warning(iridExample("old-faithful"))
  expect_match(captured$dir, "old-faithful$")
  expect_true(file.exists(file.path(captured$dir, "app.R")))
  expect_equal(captured$mode, "showcase")
})

test_that("iridExample() honours display.mode = 'normal'", {
  captured <- NULL
  local_mocked_bindings(
    runApp = function(appDir, ..., display.mode) {
      captured <<- display.mode
      invisible(NULL)
    },
    .package = "shiny"
  )
  iridExample("counter", display.mode = "normal")
  expect_equal(captured, "normal")
})
