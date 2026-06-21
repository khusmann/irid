# Scope lifetime container (R/scope.R). Two implementations, chosen by runtime
# feature detection of the shiny#4372 scoped-teardown API.
#
# The fallback-path tests run on any shiny. The reclamation tests are gated on
# `shiny_has_scope()` and SKIP on a shiny without #4372 (CRAN today). They start
# running automatically once a shiny carrying #4372 is installed — no edit
# needed. To run them now, load the dev shiny first, e.g.:
#   .libPaths(c("/tmp/shiny4372-lib", .libPaths()))
#   pkgload::load_all(".claude/worktrees/shiny-dev"); pkgload::load_all(".")
#   testthat::test_file("tests/testthat/test-scope.R")

# Cheap, instantiation-free probe for the #4372 methods (`onDestroy`/`destroy`)
# on the MockShinySession R6 generator — matches make_scope's predicate.
shiny_has_scope <- function() {
  all(c("onDestroy", "destroy") %in% names(shiny::MockShinySession$public_methods))
}

# --- Fallback path (no #4372) ------------------------------------------------

test_that("fallback scope tracks and tears down registered observers", {
  scope <- irid:::make_scope(NULL, "test")
  destroyed <- 0L
  fake_obs <- list(destroy = function() destroyed <<- destroyed + 1L)
  scope$register_observer(fake_obs)
  scope$register_observer(fake_obs)
  scope$destroy()
  expect_equal(destroyed, 2L)
})

test_that("fallback with_scope is identity (forces and returns the value)", {
  scope <- irid:::make_scope(NULL, "test")
  expect_equal(scope$with_scope(40L + 2L), 42L)
})

test_that("fallback scope$session is the passed session", {
  expect_null(irid:::make_scope(NULL, "test")$session)
})

# --- shiny#4372 path: reclamation (gated) ------------------------------------

test_that("make_scope selects the #4372 child-scope branch when available", {
  skip_if_not(shiny_has_scope(), "shiny lacks #4372 scoped teardown")
  session <- shiny::MockShinySession$new()
  scope <- irid:::make_scope(session, id = "s_branch")
  # scope$session is a child scope proxy (has its own destroy), not the raw
  # session; register_observer is a no-op (returns invisibly without erroring).
  expect_true(is.function(scope$session$destroy))
  noop <- list(destroy = function() stop("called"))
  expect_null(scope$register_observer(noop))
})

test_that("scope$destroy reclaims a reactiveVal built via with_scope (#4372)", {
  skip_if_not(shiny_has_scope(), "shiny lacks #4372 scoped teardown")
  session <- shiny::MockShinySession$new()
  scope <- irid:::make_scope(session, id = "s_rv")
  rv <- scope$with_scope(shiny::reactiveVal(1L))
  expect_equal(shiny::isolate(rv()), 1L)

  scope$destroy()
  # Post-destroy the reactiveVal is actively destroyed and throws on access.
  expect_error(shiny::isolate(rv()), "destroyed")
})

test_that("scope$destroy reclaims mini-store leaf reactiveVals (#4372)", {
  skip_if_not(shiny_has_scope(), "shiny lacks #4372 scoped teardown")
  session <- shiny::MockShinySession$new()
  scope <- irid:::make_scope(session, id = "s_mini")
  parent <- shiny::reactiveVal(list(a = 1, b = 2))
  mini <- irid:::make_mini_store(parent, parent, scope)
  leaf <- mini$a
  expect_equal(shiny::isolate(leaf()), 1)

  scope$destroy()
  expect_error(shiny::isolate(leaf()), "destroyed")
})

test_that("scope$destroy reclaims slot-accessor reactiveVals (#4372)", {
  skip_if_not(shiny_has_scope(), "shiny lacks #4372 scoped teardown")
  session <- shiny::MockShinySession$new()
  scope <- irid:::make_scope(session, id = "s_slot")
  parent <- shiny::reactiveVal(list(10, 20))
  acc <- irid:::make_slot_accessor(
    get_value = function() parent()[[1]],
    set_value = function(v) {
      p <- parent()
      p[[1]] <- v
      parent(p)
    },
    scope = scope
  )
  expect_equal(shiny::isolate(acc()), 10)

  scope$destroy()
  expect_error(shiny::isolate(acc()), "destroyed")
})
