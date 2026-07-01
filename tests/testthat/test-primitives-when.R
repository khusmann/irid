# When (R/primitives.R) — binary control-flow primitive. Constructor validation,
# process_tags extraction, and the mount-time observer lifecycle: which branch
# renders, the short-circuit that protects inner state, branch-switch teardown.

# --- Constructor validation --------------------------------------------------

test_that("When accepts a condition + bodies", {
  w <- When(\() TRUE, \() "yes", \() "no")
  expect_s3_class(w, "irid_when")
  expect_true(is.function(w$condition))
  expect_true(is.function(w$yes))
  expect_true(is.function(w$otherwise))
})

test_that("When accepts a NULL otherwise", {
  w <- When(\() TRUE, \() "yes")
  expect_s3_class(w, "irid_when")
  expect_null(w$otherwise)
})

test_that("When requires a function yes", {
  expect_error(When(\() TRUE, "raw tag tree"), "0-arg function returning a tag tree")
})

test_that("When otherwise must be a function or NULL", {
  expect_error(
    When(\() TRUE, \() "yes", "raw tag tree"),
    "0-arg function returning a tag tree or"
  )
})

# --- process_tags extraction -------------------------------------------------

test_that("process_tags emits a when control flow carrying condition + bodies", {
  cnd <- \() TRUE
  y <- \() tags$p("a")
  n <- \() tags$p("b")
  result <- process_tags(When(cnd, y, n))
  expect_length(result$control_flows, 1L)
  cf <- result$control_flows[[1]]
  expect_equal(cf$type, "when")
  expect_identical(cf$condition, cnd)
  expect_identical(cf$yes, y)
  expect_identical(cf$otherwise, n)
})

test_that("When emits a comment-anchor pair (no wrapper element)", {
  result <- process_tags(When(\() TRUE, \() "x"))
  html <- as.character(result$tag)
  expect_match(html, "<!--irid:s:irid-1-->")
  expect_match(html, "<!--irid:e:irid-1-->")
  expect_no_match(html, "<div")
})

# --- Mount lifecycle ---------------------------------------------------------

mount_when <- function(node) {
  session <- new_fake_session()
  result <- process_tags(node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  list(
    session = session,
    handle = handle,
    mutates = function() Filter(function(m) m$kind == "mutate", session$msgs()),
    attr_msgs = function(attr) Filter(
      function(m) m$kind == "attr" && identical(m$attr, attr),
      session$msgs()
    )
  )
}

# The body rides a child-anchor range, so its HTML arrives in the mutate's
# `inserts` (a list of fragments). Concatenate them for a substring assertion.
mutate_inserts <- function(msg) paste(unlist(msg$inserts), collapse = "")

test_that("renders the yes branch when the condition is TRUE", {
  m <- mount_when(When(\() TRUE, \() tags$p("yes"), \() tags$p("no")))
  flushReact()
  mu <- m$mutates()
  expect_length(mu, 1L)
  expect_match(mutate_inserts(mu[[1]]), "yes")
  m$handle$destroy()
})

test_that("renders the otherwise branch when the condition is FALSE", {
  m <- mount_when(When(\() FALSE, \() tags$p("yes"), \() tags$p("no")))
  flushReact()
  mu <- m$mutates()
  expect_length(mu, 1L)
  expect_match(mutate_inserts(mu[[1]]), "no")
  m$handle$destroy()
})

test_that("renders nothing when FALSE and no otherwise", {
  # Empty branch on initial mount: nothing to remove, nothing to insert, so no
  # mutate is emitted at all (the container range is already empty).
  m <- mount_when(When(\() FALSE, \() tags$p("yes")))
  flushReact()
  expect_length(m$mutates(), 0L)
  m$handle$destroy()
})

test_that("re-evaluating with the same condition does not rebuild (short-circuit)", {
  # The observer re-fires (its dependency changed) but the boolean is unchanged,
  # so the active branch must not be rebuilt — this is what protects inner state
  # when When wraps Each/Match.
  src <- shiny::reactiveVal(1L)
  builds <- 0L
  m <- mount_when(When(
    \() src() > 0L,
    \() {
      builds <<- builds + 1L
      tags$p("on")
    }
  ))
  flushReact()
  expect_equal(builds, 1L)
  n_mutates <- length(m$mutates())

  src(2L) # still > 0 — condition stays TRUE
  flushReact()
  expect_equal(builds, 1L) # no rebuild
  expect_equal(length(m$mutates()), n_mutates) # no new mutate
  m$handle$destroy()
})

test_that("switching branches re-renders the other branch (remove old + insert new)", {
  cond <- shiny::reactiveVal(TRUE)
  m <- mount_when(When(cond, \() tags$p("yes"), \() tags$p("no")))
  flushReact()
  expect_match(mutate_inserts(m$mutates()[[1]]), "yes")

  cond(FALSE)
  flushReact()
  mu <- m$mutates()
  expect_length(mu, 2L)
  # The flip removes the old child range and inserts the new branch.
  expect_length(mu[[2]]$removes, 1L)
  expect_match(mutate_inserts(mu[[2]]), "no")
  m$handle$destroy()
})

test_that("switching branches tears down the previous branch's observers", {
  # A reactive attr binding in the yes branch fires an attr op while mounted.
  # After flipping to otherwise, the yes mount is destroyed, so further changes
  # to its reactive must produce no echo.
  cond <- shiny::reactiveVal(TRUE)
  xval <- shiny::reactiveVal("a")
  m <- mount_when(When(
    cond,
    \() tags$div(`data-x` = \() xval()),
    \() tags$span("off")
  ))
  flushReact()
  expect_gte(length(m$attr_msgs("data-x")), 1L) # initial binding fired

  xval("b")
  flushReact()
  n <- length(m$attr_msgs("data-x"))
  expect_true(any(vapply(
    m$attr_msgs("data-x"),
    function(mm) identical(mm$value, "b"),
    logical(1)
  )))

  cond(FALSE) # destroys the yes branch
  flushReact()
  xval("c") # observer is gone — no further echo
  flushReact()
  expect_equal(length(m$attr_msgs("data-x")), n)
  m$handle$destroy()
})
