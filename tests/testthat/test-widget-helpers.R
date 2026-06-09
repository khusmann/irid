# --- can_accept_write --------------------------------------------------------
#
# Internal writability predicate used by the DOM autobind path
# (`value`/`checked` write-backs) and the synthesized widget two-way-prop
# write-back. Returns TRUE for any callable that can take a positional arg;
# FALSE for 0-arg callables and read-only `reactiveProxy`.

test_that("primitives are writable", {
  expect_true(can_accept_write(sum))
  expect_true(can_accept_write(`+`))
})

test_that("1-arg closure is writable", {
  expect_true(can_accept_write(function(v) v))
})

test_that("function with `...` is writable (dots accept the value)", {
  expect_true(can_accept_write(function(...) NULL))
})

test_that("0-arg closure is read-only", {
  expect_false(can_accept_write(function() NULL))
  expect_false(can_accept_write(\() 1))
})

test_that("reactiveVal is writable", {
  expect_true(can_accept_write(shiny::reactiveVal("x")))
})

test_that("reactive() is read-only", {
  rv <- shiny::reactiveVal("x")
  expect_false(can_accept_write(shiny::reactive(rv())))
})

test_that("reactiveProxy with setter is writable", {
  rv <- shiny::reactiveVal("x")
  p <- reactiveProxy(get = rv, set = function(v) rv(v))
  expect_true(can_accept_write(p))
})

test_that("reactiveProxy without setter is read-only", {
  rv <- shiny::reactiveVal("x")
  p <- reactiveProxy(get = rv)
  expect_false(can_accept_write(p))
})

test_that("store leaf is writable", {
  state <- reactiveStore(list(name = "Alice"))
  expect_true(can_accept_write(state$name))
})

test_that("non-callables return FALSE rather than erroring", {
  expect_false(can_accept_write(NULL))
  expect_false(can_accept_write(42))
  expect_false(can_accept_write("hello"))
  expect_false(can_accept_write(list(a = 1)))
})
