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

# --- Mount lifecycle ---------------------------------------------------------

mount_match <- function(node) {
  s <- new_fake_session()
  result <- process_tags(node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, s))
  list(
    session = s,
    handle = handle,
    mutates = function() Filter(function(m) m$kind == "mutate", s$msgs())
  )
}

# The active case body rides a child-anchor range, so its HTML arrives in the
# mutate's `inserts`. Concatenate for a substring assertion.
mutate_inserts <- function(msg) paste(unlist(msg$inserts), collapse = "")

test_that("Match renders the first matching case", {
  m <- mount_match(Match(
    \() "b",
    Case("a", \() tags$p("A")),
    Case("b", \() tags$p("B"))
  ))
  flushReact()
  mu <- m$mutates()
  expect_length(mu, 1L)
  expect_match(mutate_inserts(mu[[1]]), "B")
  m$handle$destroy()
})

test_that("Match emits nothing when no case matches and no Default", {
  # Empty case on initial mount: nothing to remove or insert, so no mutate.
  m <- mount_match(Match(\() "z", Case("a", \() tags$p("A"))))
  flushReact()
  expect_length(m$mutates(), 0L)
  m$handle$destroy()
})

test_that("Match short-circuits while the active case is unchanged", {
  v <- shiny::reactiveVal("a1")
  m <- mount_match(Match(
    v,
    Case(\(x) startsWith(x, "a"), \() tags$p("A")),
    Default(\() tags$p("other"))
  ))
  flushReact()
  n <- length(m$mutates())
  v("a2") # still matches the first case
  flushReact()
  expect_equal(length(m$mutates()), n) # no remount
  m$handle$destroy()
})

test_that("Match destroys the previous case when the active case changes", {
  v <- shiny::reactiveVal("a")
  m <- mount_match(Match(
    v,
    Case("a", \() tags$p("A")),
    Case("b", \() tags$p("B"))
  ))
  flushReact()
  expect_match(mutate_inserts(m$mutates()[[1]]), "A")

  v("b")
  flushReact()
  mu <- m$mutates()
  expect_length(mu, 2L)
  expect_length(mu[[2]]$removes, 1L)
  expect_match(mutate_inserts(mu[[2]]), "B")
  m$handle$destroy()
})

test_that("Match projects a record case body as a mini-store", {
  rec <- shiny::reactiveVal(list(label = "hi", n = 1))
  binding <- NULL
  m <- mount_match(Match(
    rec,
    Case(\(v) TRUE, function(v) {
      binding <<- v
      tags$span(`data-label` = function() v$label())
    })
  ))
  flushReact()
  expect_s3_class(binding, "reactiveStore")
  expect_equal(shiny::isolate(binding$label()), "hi")
  m$handle$destroy()
})
