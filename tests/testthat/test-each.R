flushReact <- function() shiny:::flushReact()

new_scope <- function() irid:::make_scope(NULL)

# --- Constructor validation --------------------------------------------------

test_that("Each requires a callable items", {
  expect_error(Each("not a function", \(x) x), "callable")
  expect_error(Each(NULL, \(x) x), "callable")
})

test_that("Each requires a function fn", {
  expect_error(Each(\() list(1), "not a function"), "function")
})

test_that("Each accepts NULL by (positional, the default)", {
  e <- Each(\() list(1), \(x) x)
  expect_s3_class(e, "irid_each")
  expect_null(e$by)
})

test_that("Each accepts a function by (keyed)", {
  e <- Each(\() list(list(id = 1)), \(x) x, by = \(x) x$id)
  expect_true(is.function(e$by))
})

test_that("Each rejects non-NULL non-function by", {
  expect_error(Each(\() list(1), \(x) x, by = "id"), "NULL or a function")
})

# --- process_tags extraction -------------------------------------------------

test_that("process_tags emits an each control flow", {
  items_fn <- \() list(1, 2, 3)
  fn <- \(x) tags$span(x)
  result <- process_tags(Each(items_fn, fn))
  expect_length(result$control_flows, 1L)
  cf <- result$control_flows[[1]]
  expect_equal(cf$type, "each")
  expect_identical(cf$items, items_fn)
  expect_identical(cf$fn, fn)
  expect_null(cf$by)
})

test_that("process_tags carries by when provided", {
  by_fn <- \(x) x$id
  result <- process_tags(
    Each(\() list(list(id = 1)), \(x) tags$span(), by = by_fn)
  )
  cf <- result$control_flows[[1]]
  expect_identical(cf$by, by_fn)
})

# --- Scalar slot accessor ----------------------------------------------------

test_that("make_slot_accessor reads the current value", {
  parent <- shiny::reactiveVal(c("a", "b", "c"))
  i <- 2L
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    get_value = function() parent()[[i]],
    set_value = function(v) {
      x <- shiny::isolate(parent()); x[[i]] <- v; parent(x)
    },
    scope = scope
  )
  expect_equal(shiny::isolate(acc()), "b")
})

test_that("make_slot_accessor write routes through set_value", {
  parent <- shiny::reactiveVal(c("a", "b", "c"))
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    get_value = function() parent()[[2L]],
    set_value = function(v) {
      x <- shiny::isolate(parent()); x[[2L]] <- v; parent(x)
    },
    scope = scope
  )
  acc("B")
  flushReact()
  expect_equal(shiny::isolate(parent()), c("a", "B", "c"))
  expect_equal(shiny::isolate(acc()), "B")
})

test_that("make_slot_accessor only fires on its own slot change", {
  parent <- shiny::reactiveVal(c("a", "b", "c"))
  scope1 <- new_scope()
  scope2 <- new_scope()
  acc1 <- irid:::make_slot_accessor(
    function() parent()[[1L]],
    function(v) { x <- shiny::isolate(parent()); x[[1L]] <- v; parent(x) },
    scope1
  )
  acc2 <- irid:::make_slot_accessor(
    function() parent()[[2L]],
    function(v) { x <- shiny::isolate(parent()); x[[2L]] <- v; parent(x) },
    scope2
  )
  c1 <- 0L; c2 <- 0L
  o1 <- shiny::observe({ acc1(); c1 <<- c1 + 1L })
  o2 <- shiny::observe({ acc2(); c2 <<- c2 + 1L })
  flushReact()
  base1 <- c1; base2 <- c2

  parent(c("A", "b", "c"))  # only slot 1 changed
  flushReact()
  expect_equal(c1 - base1, 1L)
  expect_equal(c2 - base2, 0L)

  o1$destroy(); o2$destroy()
})

test_that("slot accessor write updates the local rv synchronously", {
  # Mirrors `make_mini_store`'s leaf-sync regression — without a
  # synchronous local write, the event observer's force-send echo
  # reads the stale rv value and the client overwrites the user's
  # typed input.
  parent <- shiny::reactiveVal(c("a", "b", "c"))
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    function() parent()[[2L]],
    function(v) { x <- shiny::isolate(parent()); x[[2L]] <- v; parent(x) },
    scope
  )
  acc("B")
  # No flushReact() — read mid-flight.
  expect_equal(shiny::isolate(acc()), "B")
})

test_that("scope$destroy() tears down slot accessor's propagating observer", {
  parent <- shiny::reactiveVal(c("a", "b"))
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    function() parent()[[1L]],
    function(v) { x <- parent(); x[[1L]] <- v; parent(x) },
    scope
  )
  shiny::isolate(acc())  # subscribe
  flushReact()
  scope$destroy()
  parent(c("Z", "b"))
  flushReact()
  expect_equal(shiny::isolate(acc()), "a")
})
