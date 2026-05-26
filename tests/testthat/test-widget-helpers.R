# --- can_accept_write --------------------------------------------------------
#
# Writability predicate used by widget wrappers (via `write_back`) and the
# DOM autobind path (`value`/`checked` write-backs). Returns TRUE for any
# callable that can take a positional arg; FALSE for 0-arg callables and
# read-only `reactiveProxy`.

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

# --- write_back --------------------------------------------------------------

test_that("write_back writes through a writable callable", {
  rv <- shiny::reactiveVal("init")
  h <- write_back(rv, "content")
  shiny::isolate(h(list(content = "typed")))
  expect_equal(shiny::isolate(rv()), "typed")
})

test_that("write_back + 1-arg `then` writes then calls then(e)", {
  rv <- shiny::reactiveVal("init")
  seen <- NULL
  h <- write_back(rv, "content", then = function(e) seen <<- e$content)
  shiny::isolate(h(list(content = "typed")))
  expect_equal(shiny::isolate(rv()), "typed")
  expect_equal(seen, "typed")
})

test_that("write_back + 0-arg `then` writes then calls then()", {
  rv <- shiny::reactiveVal("init")
  fired <- FALSE
  h <- write_back(rv, "content", then = function() fired <<- TRUE)
  shiny::isolate(h(list(content = "typed")))
  expect_equal(shiny::isolate(rv()), "typed")
  expect_true(fired)
})

test_that("write_back with read-only callable silently skips the write", {
  rv <- shiny::reactiveVal("init")
  read_only <- shiny::reactive(rv())
  h <- write_back(read_only, "content")
  expect_silent(shiny::isolate(h(list(content = "typed"))))
  expect_equal(shiny::isolate(rv()), "init")
})

test_that("write_back with read-only callable still runs `then`", {
  rv <- shiny::reactiveVal("init")
  read_only <- shiny::reactive(rv())
  fired <- FALSE
  h <- write_back(read_only, "content", then = function(e) fired <<- TRUE)
  shiny::isolate(h(list(content = "ignored")))
  expect_true(fired)
})

test_that("write_back with missing field passes NULL to callable", {
  captured <- "untouched"
  fn <- function(v) captured <<- v
  h <- write_back(fn, "content")
  h(list(other_field = "x"))
  expect_null(captured)
})

test_that("write_back errors at construction if callable isn't a function", {
  expect_error(write_back("not a fn", "content"), "must be a function")
  expect_error(write_back(NULL, "content"), "must be a function")
})

test_that("write_back errors at construction on a bad `field`", {
  rv <- shiny::reactiveVal("x")
  expect_error(write_back(rv, ""), "non-empty character scalar")
  expect_error(write_back(rv, c("a", "b")), "non-empty character scalar")
})

test_that("write_back errors at construction if `then` isn't a function or NULL", {
  rv <- shiny::reactiveVal("x")
  expect_error(write_back(rv, "content", then = "string"),
               "function or NULL")
})

# --- event_defaults ----------------------------------------------------------
#
# Three-tier resolution: caller's `.event` > wrapper defaults > framework
# default. `event_defaults` collapses the top two tiers; the third tier
# lives in `process_tags` (`widget_default_for_event`).

test_that("event_defaults returns `...` list when user is NULL", {
  out <- event_defaults(NULL, change = event_debounce(200), click = event_immediate())
  expect_named(out, c("change", "click"))
  expect_equal(out$change$mode, "debounce")
  expect_equal(out$click$mode, "immediate")
})

test_that("event_defaults: caller scalar broadcasts, wrapper defaults dropped", {
  user <- event_throttle(100)
  out <- event_defaults(user, change = event_debounce(200))
  # Returns the caller's scalar unchanged — process_tags will broadcast it.
  expect_identical(out, user)
})

test_that("event_defaults: caller named list overrides per event, defaults fill in", {
  out <- event_defaults(
    list(click = event_throttle(50)),
    change = event_debounce(200),
    click = event_immediate()
  )
  expect_equal(out$change$mode, "debounce")
  expect_equal(out$click$mode, "throttle")
  expect_equal(out$click$ms, 50)
})

test_that("event_defaults with no `...` defaults still works", {
  # `event_defaults(.event)` is a valid no-op when the wrapper has no
  # opinions — should return the caller's value as-is.
  expect_null(event_defaults(NULL))
  scalar <- event_immediate()
  expect_identical(event_defaults(scalar), scalar)
  lst <- list(click = event_immediate())
  expect_equal(event_defaults(lst), lst)
})
