# Tests for per-widget intra-flush batching of `irid-attr` updates.
#
# Two layers:
#   1. Direct unit tests of the `irid_queue_widget_attr` accumulator —
#      precise control over keys, values, sequence, and multi-widget drain.
#   2. Integration through `irid_mount_processed` — single vs. multi prop in
#      one flush, and props changing across separate flushes.
#
# `MockShinySession$flushReact()` flushes the reactive graph AND fires
# `onFlushed` callbacks registered during the flush — the same semantics the
# drain relies on in real Shiny.

# --- Helpers -----------------------------------------------------------------

new_batch_session <- function() {
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

# Just the `irid-attr` messages, in send order.
attr_msgs <- function(session) {
  Filter(function(m) m$type == "irid-attr", session$msgs())
}

mount_widget <- function(props) {
  session <- new_batch_session()
  result <- process_tags(IridWidget(name = "test", props = props))
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  list(session = session, handle = handle, result = result)
}

# --- Accumulator unit tests --------------------------------------------------

test_that("multiple attrs for one widget coalesce into one values map", {
  s <- new_batch_session()
  irid:::irid_queue_widget_attr(s, "w1", "content", "abc")
  irid:::irid_queue_widget_attr(s, "w1", "cursor", list(line = 2, ch = 4))

  # Nothing on the wire until the flush drains the pending map.
  expect_length(attr_msgs(s), 0L)

  s$flushReact()
  ms <- attr_msgs(s)
  expect_length(ms, 1L)
  msg <- ms[[1]]$message
  expect_equal(msg$id, "w1")
  expect_equal(msg$target, "widget")
  expect_equal(names(msg$values), c("content", "cursor"))
  expect_equal(msg$values$content, "abc")
  expect_equal(msg$values$cursor, list(line = 2, ch = 4))
  expect_null(msg$sequence)
})

test_that("separate widgets drain to separate messages", {
  s <- new_batch_session()
  irid:::irid_queue_widget_attr(s, "w1", "a", 1)
  irid:::irid_queue_widget_attr(s, "w2", "b", 2)
  s$flushReact()

  ms <- attr_msgs(s)
  expect_length(ms, 2L)
  ids <- vapply(ms, function(m) m$message$id, character(1))
  expect_setequal(ids, c("w1", "w2"))
  # Each widget's batch holds only its own key.
  for (m in ms) expect_length(m$message$values, 1L)
})

test_that("widgets drain in first-seen order, not alphabetical", {
  # Regression: `ls()` would sort "w-10" before "w-2"; the drain must keep
  # the order the widgets were first queued in (≈ observer fire order).
  s <- new_batch_session()
  irid:::irid_queue_widget_attr(s, "w-2", "a", 1)
  irid:::irid_queue_widget_attr(s, "w-10", "b", 2)
  irid:::irid_queue_widget_attr(s, "w-2", "c", 3)  # re-touch, no reorder
  s$flushReact()

  ids <- vapply(attr_msgs(s), function(m) m$message$id, character(1))
  expect_equal(ids, c("w-2", "w-10"))
})

test_that("batch sequence is the max contributed by any binding", {
  s <- new_batch_session()
  irid:::irid_queue_widget_attr(s, "w1", "a", 1, sequence = 3)
  irid:::irid_queue_widget_attr(s, "w1", "b", 2, sequence = 7)
  irid:::irid_queue_widget_attr(s, "w1", "c", 3, sequence = NULL)
  s$flushReact()

  expect_equal(attr_msgs(s)[[1]]$message$sequence, 7)
})

test_that("a purely programmatic batch carries no sequence", {
  s <- new_batch_session()
  irid:::irid_queue_widget_attr(s, "w1", "a", 1)
  s$flushReact()
  expect_false("sequence" %in% names(attr_msgs(s)[[1]]$message))
})

test_that("a later attr overwrites an earlier value for the same key", {
  s <- new_batch_session()
  irid:::irid_queue_widget_attr(s, "w1", "content", "old")
  irid:::irid_queue_widget_attr(s, "w1", "content", "new")
  s$flushReact()

  msg <- attr_msgs(s)[[1]]$message
  expect_length(msg$values, 1L)
  expect_equal(msg$values$content, "new")
})

test_that("a NULL value keeps its key in the values map", {
  s <- new_batch_session()
  irid:::irid_queue_widget_attr(s, "w1", "content", NULL)
  s$flushReact()

  msg <- attr_msgs(s)[[1]]$message
  expect_true("content" %in% names(msg$values))
  expect_null(msg$values$content)
})

test_that("the pending map is cleared after draining — no duplicate sends", {
  s <- new_batch_session()
  irid:::irid_queue_widget_attr(s, "w1", "a", 1)
  s$flushReact()
  expect_length(attr_msgs(s), 1L)

  # A second flush with nothing queued sends nothing more.
  s$flushReact()
  expect_length(attr_msgs(s), 1L)

  # A fresh queue after the drain registers a new drain and sends again.
  irid:::irid_queue_widget_attr(s, "w1", "b", 2)
  s$flushReact()
  ms <- attr_msgs(s)
  expect_length(ms, 2L)
  expect_equal(names(ms[[2]]$message$values), "b")
})

# --- Integration through mount -----------------------------------------------

test_that("a single bound prop drains one one-key values batch", {
  content <- shiny::reactiveVal("hi")
  m <- mount_widget(list(content = content))
  m$session$flushReact()

  ms <- attr_msgs(m$session)
  expect_length(ms, 1L)
  expect_equal(ms[[1]]$message$target, "widget")
  expect_equal(names(ms[[1]]$message$values), "content")
  expect_equal(ms[[1]]$message$values$content, "hi")

  m$handle$destroy()
})

test_that("two props changing in one flush drain as one multi-key batch", {
  content <- shiny::reactiveVal("hi")
  cursor  <- shiny::reactiveVal(list(line = 1, ch = 0))
  m <- mount_widget(list(content = content, cursor = cursor))

  # Initial mount fires both binding observers in the same flush.
  m$session$flushReact()
  ms <- attr_msgs(m$session)
  expect_length(ms, 1L)
  expect_setequal(names(ms[[1]]$message$values), c("content", "cursor"))
  expect_equal(ms[[1]]$message$values$content, "hi")
  expect_equal(ms[[1]]$message$values$cursor, list(line = 1, ch = 0))

  m$handle$destroy()
})

test_that("props changing in separate flushes drain as separate messages", {
  content <- shiny::reactiveVal("hi")
  cursor  <- shiny::reactiveVal(list(line = 1, ch = 0))
  m <- mount_widget(list(content = content, cursor = cursor))

  m$session$flushReact()            # initial combined batch
  base <- length(attr_msgs(m$session))

  shiny::isolate(content("yo"))
  m$session$flushReact()
  shiny::isolate(cursor(list(line = 3, ch = 2)))
  m$session$flushReact()

  new <- attr_msgs(m$session)[(base + 1L):length(attr_msgs(m$session))]
  expect_length(new, 2L)
  expect_equal(names(new[[1]]$message$values), "content")
  expect_equal(new[[1]]$message$values$content, "yo")
  expect_equal(names(new[[2]]$message$values), "cursor")
  expect_equal(new[[2]]$message$values$cursor, list(line = 3, ch = 2))

  m$handle$destroy()
})

test_that("a batch driven by the current event sequence carries that sequence", {
  content <- shiny::reactiveVal("hi")
  m <- mount_widget(list(content = content))
  m$session$flushReact()            # initial (programmatic) batch
  base <- length(attr_msgs(m$session))

  wid <- m$result$bindings[[1]]$id
  shiny::isolate(content("yo"))
  m$session$userData$irid_current_sequence <- list(seq = 42, source = wid)
  m$session$flushReact()

  last <- attr_msgs(m$session)[[base + 1L]]$message
  expect_equal(last$sequence, 42)

  m$handle$destroy()
})
