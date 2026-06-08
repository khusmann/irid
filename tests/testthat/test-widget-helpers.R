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

test_that("write_back errors at construction if callable isn't a function or NULL", {
  expect_error(write_back("not a fn", "content"), "function or NULL")
  expect_error(write_back(42, "content"), "function or NULL")
})

test_that("write_back(NULL, field) with no `then` returns NULL (IridWidget drops it)", {
  # Collapsed to NULL so the wrapper's events entry vanishes — declarative
  # forwarding of optional `cursor`/`onCursorChanged` without conditionals.
  expect_null(write_back(NULL, "content"))
})

test_that("write_back(NULL, field, then = fn) returns a handler that just runs `then`", {
  # NULL callable + non-NULL then = "no write target, but the wrapper still
  # wants the discrete onCursorChanged callback to fire."
  seen <- NULL
  h <- write_back(NULL, "content", then = function(e) seen <<- e$content)
  expect_true(is.function(h))
  h(list(content = "x"))
  expect_equal(seen, "x")
})

test_that("write_back(NULL, field, then = fn) with 0-arg then fires then()", {
  fired <- FALSE
  h <- write_back(NULL, "content", then = function() fired <<- TRUE)
  h(list(content = "x"))
  expect_true(fired)
})

# `irid_write_targets` attribute drives the force-send-on-no-op loop in
# mount.R — only bindings whose `attr` is in the firing event handler's
# declared targets get echoed. Without per-handler scoping, a debounced
# binding's stale server value can clobber in-flight client state.

test_that("write_back tags its returned handler with irid_write_targets = field", {
  rv <- shiny::reactiveVal("x")
  h <- write_back(rv, "content")
  expect_equal(attr(h, "irid_write_targets"), "content")
})

test_that("write_back with `then` still declares the field as a write target", {
  rv <- shiny::reactiveVal("x")
  h <- write_back(rv, "content", then = function(e) NULL)
  expect_equal(attr(h, "irid_write_targets"), "content")
})

test_that("write_back(NULL, field, then = fn) declares NO write target", {
  # NULL callable means no binding to echo — the handler is just side
  # effects. Force-send should skip.
  h <- write_back(NULL, "content", then = function(e) NULL)
  expect_null(attr(h, "irid_write_targets"))
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

# --- widget_event ------------------------------------------------------------
#
# Per-event record bundling wire name, handler, and timing for one widget
# event. Returns NULL when handler is NULL so wrappers can forward optional
# handlers declaratively (IridWidget drops NULL entries).

test_that("widget_event returns NULL when handler is NULL", {
  expect_null(widget_event(name = "change", handler = NULL))
  expect_null(widget_event(name = "change", handler = NULL, timing = irid_debounce(200)))
})

test_that("widget_event builds a record with name, handler, timing", {
  h <- function(e) NULL
  t <- irid_throttle(100)
  w <- widget_event(name = "cursor-changed", handler = h, timing = t)
  expect_s3_class(w, "widget_event")
  expect_equal(w$name, "cursor-changed")
  expect_identical(w$handler, h)
  expect_identical(w$timing, t)
})

test_that("widget_event timing defaults to irid_immediate()", {
  h <- function(e) NULL
  w <- widget_event(name = "change", handler = h)
  expect_s3_class(w$timing, "irid_timing")
  expect_equal(w$timing$mode, "immediate")
})

test_that("widget_event errors on bad name", {
  h <- function(e) NULL
  expect_error(widget_event(name = "", handler = h), "non-empty character scalar")
  expect_error(widget_event(name = c("a", "b"), handler = h), "non-empty character scalar")
  expect_error(widget_event(name = NA_character_, handler = h), "non-empty character scalar")
})

test_that("widget_event errors on non-function handler", {
  expect_error(widget_event(name = "change", handler = "string"), "must be a function or NULL")
  expect_error(widget_event(name = "change", handler = 42), "must be a function or NULL")
})

test_that("widget_event errors on bad timing (including NULL)", {
  h <- function(e) NULL
  expect_error(
    widget_event(name = "change", handler = h, timing = "not a config"),
    "must be an `irid_timing`"
  )
  expect_error(
    widget_event(name = "change", handler = h, timing = list()),
    "must be an `irid_timing`"
  )
  expect_error(
    widget_event(name = "change", handler = h, timing = NULL),
    "must be an `irid_timing`"
  )
})

