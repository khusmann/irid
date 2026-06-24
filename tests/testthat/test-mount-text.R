test_that("coerce_text_child accepts length-1 atomics and NULL", {
  expect_equal(irid:::coerce_text_child("hello"), "hello")
  expect_equal(irid:::coerce_text_child(42), "42")
  expect_equal(irid:::coerce_text_child(TRUE), "TRUE")
  expect_equal(irid:::coerce_text_child(NULL), character(0))
  # NA coerces to NA_character_ (client treats as empty)
  expect_equal(irid:::coerce_text_child(NA), NA_character_)
})

test_that("coerce_text_child rejects HTML tags", {
  expect_error(
    irid:::coerce_text_child(shiny::div("hi")),
    "must return a single text value.*HTML tag"
  )
  expect_error(
    irid:::coerce_text_child(shiny::tagList(shiny::span("a"))),
    "HTML tag"
  )
})

test_that("coerce_text_child rejects multi-element vectors", {
  expect_error(
    irid:::coerce_text_child(c("a", "b")),
    "length-2 character vector"
  )
  expect_error(
    irid:::coerce_text_child(1:3),
    "length-3"
  )
})

test_that("coerce_text_child rejects lists", {
  expect_error(
    irid:::coerce_text_child(list(a = 1)),
    "must return a single text value"
  )
})
