flushReact <- function() shiny:::flushReact()

# --- Construction & argument validation --------------------------------------

test_that("returns a callable with class reactiveProxy/function", {
  rv <- shiny::reactiveVal(1)
  p <- reactiveProxy(get = rv, set = rv)
  expect_true(is.function(p))
  expect_s3_class(p, "reactiveProxy")
})

test_that("inherits from 'reactive' so process_tags' is_irid_reactive accepts it", {
  rv <- shiny::reactiveVal(1)
  p <- reactiveProxy(get = rv, set = rv)
  expect_s3_class(p, "reactive")
})

test_that("non-callable get errors", {
  expect_error(reactiveProxy(1), "`get` must be a function")
  expect_error(reactiveProxy("hi"), "`get` must be a function")
  expect_error(reactiveProxy(NULL), "`get` must be a function")
})

test_that("set must be a function or NULL", {
  rv <- shiny::reactiveVal(1)
  expect_error(reactiveProxy(get = rv, set = 1), "function or")
})

# --- Default pass-through ----------------------------------------------------

test_that("default proxy reads the target's current value", {
  rv <- shiny::reactiveVal(42)
  p <- reactiveProxy(get = rv, set = rv)
  expect_equal(shiny::isolate(p()), 42)
})

test_that("default proxy writes through to the target", {
  rv <- shiny::reactiveVal(0)
  p <- reactiveProxy(get = rv, set = rv)
  p(7)
  expect_equal(shiny::isolate(rv()), 7)
})

test_that("write returns invisibly", {
  rv <- shiny::reactiveVal(0)
  p <- reactiveProxy(get = rv, set = rv)
  expect_invisible(p(1))
})

test_that("writing NULL through the default proxy writes NULL to target", {
  rv <- shiny::reactiveVal(1)
  p <- reactiveProxy(get = rv, set = rv)
  p(NULL)
  expect_null(shiny::isolate(rv()))
})

# --- Wrapping a reactiveStore leaf -------------------------------------------

test_that("proxy over a store leaf reads and writes through it", {
  state <- reactiveStore(list(name = "Alice"))
  p <- reactiveProxy(get = state$name, set = state$name)
  expect_equal(shiny::isolate(p()), "Alice")
  p("Bob")
  expect_equal(shiny::isolate(state$name()), "Bob")
})

test_that("proxy over a store node reads a snapshot and writes back", {
  state <- reactiveStore(list(user = list(name = "Alice", age = 30)))
  p <- reactiveProxy(get = state$user, set = state$user)
  expect_equal(shiny::isolate(p()), list(name = "Alice", age = 30))
  p(list(name = "Bob", age = 30))
  expect_equal(shiny::isolate(state$user$name()), "Bob")
  expect_equal(shiny::isolate(state$user$age()), 30)
})

# --- Custom get (read transform) ---------------------------------------------

test_that("get transforms reads", {
  rv <- shiny::reactiveVal(0)
  p <- reactiveProxy(get = \() rv() * 9 / 5 + 32)
  expect_equal(shiny::isolate(p()), 32)
  rv(100)
  expect_equal(shiny::isolate(p()), 212)
})

test_that("get does not affect writes", {
  rv <- shiny::reactiveVal(0)
  p <- reactiveProxy(
    get = \() rv() * 9 / 5 + 32,
    set = \(v) rv(v)
  )
  p(50)
  expect_equal(shiny::isolate(rv()), 50)
})

# --- Custom set (write handler) ----------------------------------------------

test_that("set handler is called with the incoming write", {
  rv <- shiny::reactiveVal("")
  seen <- NULL
  p <- reactiveProxy(get = rv, set = \(v) {
    seen <<- v
    rv(v)
  })
  p("hello")
  expect_equal(seen, "hello")
  expect_equal(shiny::isolate(rv()), "hello")
})

test_that("set can drop a write conditionally (validation gate)", {
  rv <- shiny::reactiveVal("ok")
  p <- reactiveProxy(get = rv, set = \(v) if (nchar(v) <= 5L) rv(v))
  p("short")
  expect_equal(shiny::isolate(rv()), "short")
  p("too long for the gate")
  expect_equal(shiny::isolate(rv()), "short")
})

test_that("set can transform before writing", {
  rv <- shiny::reactiveVal(0)
  p <- reactiveProxy(get = rv, set = \(v) rv(v * 2))
  p(5)
  expect_equal(shiny::isolate(rv()), 10)
})

# --- Bidirectional transform -------------------------------------------------

test_that("get/set together support bidirectional transforms", {
  temp_c <- shiny::reactiveVal(0)
  temp_f <- reactiveProxy(
    get = \() temp_c() * 9 / 5 + 32,
    set = \(f) temp_c((f - 32) * 5 / 9)
  )
  expect_equal(shiny::isolate(temp_f()), 32)
  temp_f(212)
  expect_equal(shiny::isolate(temp_c()), 100)
  expect_equal(shiny::isolate(temp_f()), 212)
})

# --- Read-only (set = NULL) --------------------------------------------------

test_that("set = NULL drops writes silently", {
  rv <- shiny::reactiveVal("Alice")
  p <- reactiveProxy(get = rv)
  p("Bob")
  expect_equal(shiny::isolate(rv()), "Alice")
})

test_that("set = NULL still reads through get", {
  rv <- shiny::reactiveVal("alice")
  p <- reactiveProxy(get = \() toupper(rv()))
  expect_equal(shiny::isolate(p()), "ALICE")
})

test_that("write to a read-only proxy returns invisibly", {
  rv <- shiny::reactiveVal(1)
  p <- reactiveProxy(get = rv)
  expect_invisible(p(2))
})

# --- Reactivity --------------------------------------------------------------

test_that("reading a proxy subscribes to the underlying target", {
  rv <- shiny::reactiveVal(1)
  p <- reactiveProxy(get = rv, set = rv)
  fired <- 0L
  obs <- shiny::observe({
    p()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)

  rv(2)
  flushReact()
  expect_equal(fired, 2L)
  obs$destroy()
})

test_that("writing through a proxy fires observers of the target leaf", {
  state <- reactiveStore(list(name = "A"))
  p <- reactiveProxy(get = state$name, set = state$name)
  fired <- 0L
  obs <- shiny::observe({
    state$name()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)

  p("B")
  flushReact()
  expect_equal(fired, 2L)
  obs$destroy()
})

test_that("read with custom get re-fires when the target changes", {
  rv <- shiny::reactiveVal(0)
  p <- reactiveProxy(get = \() rv() + 1)
  fired <- 0L
  last <- NA
  obs <- shiny::observe({
    last <<- p()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)
  expect_equal(last, 1)

  rv(10)
  flushReact()
  expect_equal(fired, 2L)
  expect_equal(last, 11)
  obs$destroy()
})

test_that("dropped writes do not invalidate target observers", {
  state <- reactiveStore(list(name = "A"))
  p <- reactiveProxy(get = state$name)
  fired <- 0L
  obs <- shiny::observe({
    state$name()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)
  p("B")
  flushReact()
  expect_equal(fired, 1L)
  obs$destroy()
})

# --- Cross-field validation via closure --------------------------------------

test_that("set closure can read sibling state for cross-field validation", {
  state <- reactiveStore(list(start = 1, end = 5))
  end_proxy <- reactiveProxy(
    get = state$end,
    set = \(v) if (v > shiny::isolate(state$start())) state$end(v)
  )
  end_proxy(10)
  expect_equal(shiny::isolate(state$end()), 10)
  end_proxy(0)
  expect_equal(shiny::isolate(state$end()), 10)
})

# --- Composability -----------------------------------------------------------

test_that("a reactiveProxy can wrap another reactiveProxy", {
  rv <- shiny::reactiveVal(100)
  dollars <- reactiveProxy(
    get = \() sprintf("$%.2f", rv() / 100),
    set = \(v) rv(round(as.numeric(gsub("[$,]", "", v)) * 100))
  )
  capped <- reactiveProxy(
    get = dollars,
    set = \(v) {
      n <- as.numeric(gsub("[$,]", "", v))
      if (!is.na(n) && n <= 50) dollars(v)
    }
  )
  expect_equal(shiny::isolate(capped()), "$1.00")

  capped("$25.00")
  expect_equal(shiny::isolate(rv()), 2500)
  expect_equal(shiny::isolate(capped()), "$25.00")

  capped("$999.00")
  expect_equal(shiny::isolate(rv()), 2500)
})

# --- print smoke tests -------------------------------------------------------

test_that("print(proxy) is non-empty", {
  rv <- shiny::reactiveVal(1)
  out <- capture.output(print(reactiveProxy(get = rv, set = rv)))
  expect_true(any(grepl("reactiveProxy", out)))
})

test_that("print(proxy) marks read-only when set = NULL", {
  rv <- shiny::reactiveVal(1)
  out <- capture.output(print(reactiveProxy(get = rv)))
  expect_true(any(grepl("read-only", out)))
})
