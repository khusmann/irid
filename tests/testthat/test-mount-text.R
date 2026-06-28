test_that("coerce_text_child accepts length-1 atomics and NULL", {
  expect_equal(irid:::coerce_text_child("hello"), "hello")
  expect_equal(irid:::coerce_text_child(42), "42")
  expect_equal(irid:::coerce_text_child(TRUE), "TRUE")
  # NULL / NA / empty all normalize to "" (the wire's "clear" signal).
  expect_equal(irid:::coerce_text_child(NULL), "")
  expect_equal(irid:::coerce_text_child(NA), "")
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

# --- extraction + mount of a reactive text child -----------------------------

test_that("a reactive text child becomes a target='text' binding + anchor pair", {
  res <- process_tags(shiny::tags$span(function() "hi"))
  expect_length(res$bindings, 1L)
  b <- res$bindings[[1]]
  expect_equal(b$target, "text")
  expect_null(b$attr) # text bindings carry no attr
  html <- as.character(res$tag)
  expect_match(html, paste0("<!--irid:s:", b$id, "-->"))
  expect_match(html, paste0("<!--irid:e:", b$id, "-->"))
})

test_that("mounting a reactive text child sends a target='text' irid-attr", {
  txt <- shiny::reactiveVal("hi")
  s <- new_fake_session()
  res <- process_tags(shiny::tags$span(function() txt()))
  handle <- shiny::isolate(irid:::irid_mount_processed(res, s))
  shiny:::flushReact()

  text_msgs <- Filter(
    function(m) m$type == "irid-attr" && identical(m$message$target, "text"),
    s$msgs()
  )
  expect_gte(length(text_msgs), 1L)
  expect_equal(text_msgs[[length(text_msgs)]]$message$value, "hi")

  txt("bye")
  shiny:::flushReact()
  last <- Filter(
    function(m) m$type == "irid-attr" && identical(m$message$target, "text"),
    s$msgs()
  )
  expect_equal(last[[length(last)]]$message$value, "bye")

  handle$destroy()
})
