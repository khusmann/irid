flushReact <- function() shiny:::flushReact()

# --- Constructor validation --------------------------------------------------

test_that("Match requires a leading callable", {
  expect_error(
    Match(Case(\(v) TRUE, \() "x")),
    "leading callable"
  )
  expect_error(
    Match("not a function", Case(\(v) TRUE, \() "x")),
    "leading callable"
  )
})

test_that("Case requires a function body", {
  expect_error(Case(\(v) TRUE, "raw tag tree"), "function returning a tag tree")
  expect_error(Default("raw tag tree"), "function returning a tag tree")
})

test_that("Match accepts a callable + Cases", {
  m <- Match(\() "a",
    Case(\(v) v == "a", \() "first"),
    Case("b",           \() "second"),
    Case(\() TRUE,      \() "third")
  )
  expect_s3_class(m, "irid_match")
  expect_length(m$cases, 3L)
  expect_true(is.function(m$callable))
})

test_that("Default is sugar for Case(\\() TRUE, body)", {
  d <- Default(\() "x")
  expect_true(is.function(d$predicate))
  expect_equal(length(formals(d$predicate)), 0L)
  expect_true(isTRUE(d$predicate()))
})

# --- Predicate normalisation -------------------------------------------------

test_that("function predicates are stored as-is (arity preserved)", {
  m <- Match(\() 1,
    Case(\(v) v > 0,  \() "pos"),
    Case(\() TRUE,    \() "fallback")
  )
  expect_equal(length(formals(m$cases[[1]]$predicate)), 1L)
  expect_equal(length(formals(m$cases[[2]]$predicate)), 0L)
})

test_that("literal predicates become identical-match functions", {
  m <- Match(\() "x", Case("hit", \() "yes"))
  pred <- m$cases[[1]]$predicate
  expect_true(is.function(pred))
  expect_equal(length(formals(pred)), 1L)
  expect_true(pred("hit"))
  expect_false(pred("miss"))
})

test_that("literal predicates use identical (not ==) semantics", {
  m <- Match(\() 1L, Case(1L, \() "int"))
  pred <- m$cases[[1]]$predicate
  # Type-strict — 1L matches 1L, not 1 (numeric)
  expect_true(pred(1L))
  expect_false(pred(1))
})

# --- process_tags extraction -------------------------------------------------

test_that("process_tags emits a match control flow with callable + cases", {
  cb <- \() "a"
  result <- process_tags(
    Match(cb,
      Case("a", \() tags$p("first")),
      Default(\() tags$p("fallback"))
    )
  )
  expect_length(result$control_flows, 1L)
  cf <- result$control_flows[[1]]
  expect_equal(cf$type, "match")
  expect_identical(cf$callable, cb)
  expect_length(cf$cases, 2L)
})

test_that("Match emits a comment-anchor pair (no wrapper element)", {
  result <- process_tags(
    Match(\() "a", Default(\() "x"))
  )
  html <- as.character(result$tag)
  expect_match(html, "<!--irid:s:irid-1-->")
  expect_match(html, "<!--irid:e:irid-1-->")
  expect_no_match(html, "<div")
})

# --- is_record helper --------------------------------------------------------

test_that("is_record distinguishes records from scalars/atomics", {
  expect_true(irid:::is_record(list(a = 1, b = 2)))
  expect_false(irid:::is_record(list(1, 2)))           # unnamed
  expect_false(irid:::is_record(list()))               # empty
  expect_false(irid:::is_record(list(a = 1, 2)))       # partially named
  expect_false(irid:::is_record("scalar"))             # string
  expect_false(irid:::is_record(42))                   # numeric
  expect_false(irid:::is_record(NULL))                 # null
})
