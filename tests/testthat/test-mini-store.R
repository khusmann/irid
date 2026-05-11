flushReact <- function() shiny:::flushReact()

new_scope <- function() irid:::make_scope(NULL)

new_mini <- function(initial) {
  parent <- shiny::reactiveVal(initial)
  list(
    parent = parent,
    mini = irid:::make_mini_store(
      get_record = parent,
      set_record = parent,
      scope = new_scope()
    )
  )
}

# --- Construction & shape ----------------------------------------------------

test_that("keys, names, length match the initial record", {
  fix <- new_mini(list(a = 1, b = "x", c = TRUE))
  expect_equal(names(fix$mini), c("a", "b", "c"))
  expect_equal(length(fix$mini), 3L)
})

test_that("initial values are readable from leaves", {
  fix <- new_mini(list(a = 1, b = "x"))
  expect_equal(shiny::isolate(fix$mini$a()), 1)
  expect_equal(shiny::isolate(fix$mini$b()), "x")
})

test_that("whole-record read returns the initial record", {
  fix <- new_mini(list(a = 1, b = "x"))
  expect_equal(shiny::isolate(fix$mini()), list(a = 1, b = "x"))
})

test_that("non-list initial errors", {
  scope <- new_scope()
  rv <- shiny::reactiveVal(1)
  expect_error(
    irid:::make_mini_store(rv, rv, scope),
    "fully named list"
  )
})

test_that("unnamed initial errors", {
  scope <- new_scope()
  rv <- shiny::reactiveVal(list("a", "b"))
  expect_error(
    irid:::make_mini_store(rv, rv, scope),
    "fully named list"
  )
})

# --- Read / write round-trips ------------------------------------------------

test_that("whole-record write routes through set_record", {
  fix <- new_mini(list(a = 1, b = 2))
  fix$mini(list(a = 10, b = 20))
  flushReact()
  expect_equal(shiny::isolate(fix$parent()), list(a = 10, b = 20))
  expect_equal(shiny::isolate(fix$mini()), list(a = 10, b = 20))
})

test_that("synthetic setter routes through set_record (parent updates)", {
  fix <- new_mini(list(a = 1, b = 2))
  fix$mini$a(99)
  flushReact()
  expect_equal(shiny::isolate(fix$parent()), list(a = 99, b = 2))
  expect_equal(shiny::isolate(fix$mini$a()), 99)
})

test_that("synthetic setter does not bypass set_record", {
  parent <- shiny::reactiveVal(list(a = 1, b = 2))
  writes <- list()
  set_record <- function(v) {
    writes[[length(writes) + 1L]] <<- v
    parent(v)
  }
  mini <- irid:::make_mini_store(
    get_record = parent,
    set_record = set_record,
    scope = new_scope()
  )
  mini$a(7)
  expect_equal(length(writes), 1L)
  expect_equal(writes[[1]], list(a = 7, b = 2))
})

test_that("parent change propagates to leaves", {
  fix <- new_mini(list(a = 1, b = 2))
  # subscribe to leaves so the propagating observer has work to do
  shiny::isolate(fix$mini$a())
  fix$parent(list(a = 5, b = 6))
  flushReact()
  expect_equal(shiny::isolate(fix$mini$a()), 5)
  expect_equal(shiny::isolate(fix$mini$b()), 6)
})

# --- Fine-grained reactivity -------------------------------------------------

test_that("only changed leaves fire on parent patch", {
  fix <- new_mini(list(a = 1, b = 2))
  count_a <- 0L
  count_b <- 0L
  obs_a <- shiny::observe({ fix$mini$a(); count_a <<- count_a + 1L })
  obs_b <- shiny::observe({ fix$mini$b(); count_b <<- count_b + 1L })
  flushReact()
  initial_a <- count_a
  initial_b <- count_b

  fix$parent(list(a = 10, b = 2))
  flushReact()
  expect_equal(count_a - initial_a, 1L)
  expect_equal(count_b - initial_b, 0L)

  obs_a$destroy()
  obs_b$destroy()
})

test_that("synthetic setter only fires the targeted leaf", {
  fix <- new_mini(list(a = 1, b = 2))
  count_a <- 0L
  count_b <- 0L
  obs_a <- shiny::observe({ fix$mini$a(); count_a <<- count_a + 1L })
  obs_b <- shiny::observe({ fix$mini$b(); count_b <<- count_b + 1L })
  flushReact()
  initial_a <- count_a
  initial_b <- count_b

  fix$mini$a(42)
  flushReact()
  expect_equal(count_a - initial_a, 1L)
  expect_equal(count_b - initial_b, 0L)

  obs_a$destroy()
  obs_b$destroy()
})

test_that("identical write does not fire leaf observers", {
  fix <- new_mini(list(a = 1, b = 2))
  count_a <- 0L
  obs_a <- shiny::observe({ fix$mini$a(); count_a <<- count_a + 1L })
  flushReact()
  initial_a <- count_a

  fix$parent(list(a = 1, b = 99))  # a unchanged
  flushReact()
  expect_equal(count_a - initial_a, 0L)

  obs_a$destroy()
})

# --- Fixed-shape rejection ---------------------------------------------------

test_that("write with unknown key errors", {
  fix <- new_mini(list(a = 1, b = 2))
  expect_error(fix$mini(list(a = 1, b = 2, c = 3)),
               "Unknown keys.*c")
})

test_that("write with non-list errors", {
  fix <- new_mini(list(a = 1, b = 2))
  expect_error(fix$mini(42), "named list")
})

test_that("write with unnamed list errors", {
  fix <- new_mini(list(a = 1, b = 2))
  expect_error(fix$mini(list(1, 2)), "fully named list")
})

test_that("partial whole-record write succeeds for known keys", {
  fix <- new_mini(list(a = 1, b = 2))
  fix$mini(list(a = 99))
  flushReact()
  expect_equal(shiny::isolate(fix$parent()), list(a = 99))
})

# --- Scope cleanup -----------------------------------------------------------

test_that("scope$destroy() tears down internal observer", {
  parent <- shiny::reactiveVal(list(a = 1, b = 2))
  scope <- new_scope()
  mini <- irid:::make_mini_store(parent, parent, scope)

  # Force the propagating observer to register a dependency
  shiny::isolate(mini$a())
  flushReact()

  scope$destroy()

  # After destroy, parent changes should not reach leaves
  parent(list(a = 99, b = 2))
  flushReact()
  expect_equal(shiny::isolate(mini$a()), 1)
})

# --- Auto-bind compatibility -------------------------------------------------

test_that("per-field accessor passes is_irid_reactive", {
  fix <- new_mini(list(a = 1))
  expect_true(irid:::is_irid_reactive(fix$mini$a))
})

test_that("mini-store callable passes is_irid_reactive", {
  fix <- new_mini(list(a = 1))
  expect_true(irid:::is_irid_reactive(fix$mini))
})
