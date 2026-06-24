# When (R/primitives.R) — binary control-flow primitive. Constructor validation,
# process_tags extraction, and the mount-time observer lifecycle: which branch
# renders, the short-circuit that protects inner state, branch-switch teardown.

flushReact <- function() shiny:::flushReact()

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

new_fake_session <- function() {
  s <- shiny::MockShinySession$new()
  store <- new.env(parent = emptyenv())
  store$msgs <- list()
  s$sendCustomMessage <- function(type, message) {
    store$msgs[[length(store$msgs) + 1L]] <<- list(type = type, message = message)
    invisible()
  }
  s$msgs <- function() store$msgs
  s
}

mount_when <- function(node) {
  session <- new_fake_session()
  result <- process_tags(node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  list(
    session = session,
    handle = handle,
    swaps = function() Filter(function(m) m$type == "irid-swap", session$msgs()),
    attr_msgs = function(attr) Filter(
      function(m) m$type == "irid-attr" && identical(m$message$attr, attr),
      session$msgs()
    )
  )
}

test_that("renders the yes branch when the condition is TRUE", {
  m <- mount_when(When(\() TRUE, \() tags$p("yes"), \() tags$p("no")))
  flushReact()
  sw <- m$swaps()
  expect_length(sw, 1L)
  expect_match(sw[[1]]$message$html, "yes")
  m$handle$destroy()
})

test_that("renders the otherwise branch when the condition is FALSE", {
  m <- mount_when(When(\() FALSE, \() tags$p("yes"), \() tags$p("no")))
  flushReact()
  sw <- m$swaps()
  expect_length(sw, 1L)
  expect_match(sw[[1]]$message$html, "no")
  m$handle$destroy()
})

test_that("renders nothing (empty swap) when FALSE and no otherwise", {
  m <- mount_when(When(\() FALSE, \() tags$p("yes")))
  flushReact()
  sw <- m$swaps()
  expect_length(sw, 1L)
  expect_equal(sw[[1]]$message$html, "")
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
  n_swaps <- length(m$swaps())

  src(2L) # still > 0 — condition stays TRUE
  flushReact()
  expect_equal(builds, 1L) # no rebuild
  expect_equal(length(m$swaps()), n_swaps) # no new swap
  m$handle$destroy()
})

test_that("switching branches re-renders the other branch", {
  cond <- shiny::reactiveVal(TRUE)
  m <- mount_when(When(cond, \() tags$p("yes"), \() tags$p("no")))
  flushReact()
  expect_match(m$swaps()[[1]]$message$html, "yes")

  cond(FALSE)
  flushReact()
  sw <- m$swaps()
  expect_length(sw, 2L)
  expect_match(sw[[2]]$message$html, "no")
  m$handle$destroy()
})

test_that("switching branches tears down the previous branch's observers", {
  # A reactive attr binding in the yes branch fires irid-attr while mounted.
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
    function(mm) identical(mm$message$value, "b"),
    logical(1)
  )))

  cond(FALSE) # destroys the yes branch
  flushReact()
  xval("c") # observer is gone — no further echo
  flushReact()
  expect_equal(length(m$attr_msgs("data-x")), n)
  m$handle$destroy()
})
