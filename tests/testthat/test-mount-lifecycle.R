# Mount teardown (R/mount.R, the `destroy()` returned by irid_mount_processed).
# Verifies destroy tears down the mount's own observers and cascades into the
# active child mounts of every control-flow node (When/Match/Each), recursively.
#
# Each inner binding is driven by an EXTERNAL reactiveVal captured in the body
# closure (not the item/branch value), so "did the observer fire?" is a clean
# signal independent of the reconcilers: while mounted, bumping the external rv
# echoes irid-attr; after destroy, a live observer would still echo — so silence
# proves teardown.

flushReact <- function() shiny:::flushReact()

new_fake_session <- function() {
  s <- shiny::MockShinySession$new()
  store <- new.env(parent = emptyenv())
  store$msgs <- list()
  s$sendCustomMessage <- function(type, message) {
    store$msgs[[length(store$msgs) + 1L]] <<- list(type = type, message = message)
    invisible()
  }
  s$msgs <- function() store$msgs
  s
}

# irid-attr echoes for a given attr name.
attrs <- function(s, attr) {
  Filter(
    function(m) m$type == "irid-attr" && identical(m$message$attr, attr),
    s$msgs()
  )
}

mount <- function(node) {
  s <- new_fake_session()
  result <- process_tags(node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, s))
  list(session = s, handle = handle)
}

test_that("destroy() tears down the mount's own binding observers", {
  ext <- shiny::reactiveVal("p")
  m <- mount(shiny::tags$div(`data-e` = function() ext()))
  flushReact()
  ext("q")
  flushReact()
  expect_true(any(vapply(
    attrs(m$session, "data-e"),
    function(x) identical(x$message$value, "q"), logical(1)
  )))

  m$handle$destroy()
  n <- length(attrs(m$session, "data-e"))
  ext("r")
  flushReact()
  expect_equal(length(attrs(m$session, "data-e")), n) # silent after destroy
})

test_that("destroy() cascades into a When's active branch child mount", {
  ext <- shiny::reactiveVal("p")
  m <- mount(When(\() TRUE, \() shiny::tags$div(`data-e` = function() ext())))
  flushReact()
  ext("q")
  flushReact()
  expect_true(any(vapply(
    attrs(m$session, "data-e"),
    function(x) identical(x$message$value, "q"), logical(1)
  )))

  m$handle$destroy()
  n <- length(attrs(m$session, "data-e"))
  ext("r")
  flushReact()
  expect_equal(length(attrs(m$session, "data-e")), n)
})

test_that("destroy() cascades into a Match's active case (and per-case scope)", {
  ext <- shiny::reactiveVal("p")
  m <- mount(Match(
    \() "a",
    Case("a", \() shiny::tags$div(`data-e` = function() ext()))
  ))
  flushReact()
  ext("q")
  flushReact()
  expect_true(any(vapply(
    attrs(m$session, "data-e"),
    function(x) identical(x$message$value, "q"), logical(1)
  )))

  m$handle$destroy()
  n <- length(attrs(m$session, "data-e"))
  ext("r")
  flushReact()
  expect_equal(length(attrs(m$session, "data-e")), n)
})

test_that("destroy() cascades into all of an Each's per-item child mounts", {
  ext <- shiny::reactiveVal("p")
  items <- shiny::reactiveVal(list(1, 2, 3))
  m <- mount(Each(items, function(item) {
    shiny::tags$div(`data-e` = function() ext())
  }))
  flushReact()
  ext("q")
  flushReact()
  # one echo per item
  q <- Filter(
    function(x) identical(x$message$value, "q"),
    attrs(m$session, "data-e")
  )
  expect_length(q, 3L)

  m$handle$destroy()
  n <- length(attrs(m$session, "data-e"))
  ext("r")
  flushReact()
  expect_equal(length(attrs(m$session, "data-e")), n)
})

test_that("destroy() propagates recursively through nested control flow", {
  # When wrapping Each: the deepest per-item bindings must be torn down when the
  # outermost mount is destroyed.
  ext <- shiny::reactiveVal("p")
  items <- shiny::reactiveVal(list(1, 2))
  m <- mount(When(
    \() TRUE,
    \() Each(items, function(item) shiny::tags$div(`data-e` = function() ext()))
  ))
  flushReact()
  ext("q")
  flushReact()
  q <- Filter(
    function(x) identical(x$message$value, "q"),
    attrs(m$session, "data-e")
  )
  expect_length(q, 2L)

  m$handle$destroy()
  n <- length(attrs(m$session, "data-e"))
  ext("r")
  flushReact()
  expect_equal(length(attrs(m$session, "data-e")), n)
})
