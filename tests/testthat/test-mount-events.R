# Event-handler wiring in irid_mount_processed (R/mount.R): formal-arity
# dispatch (0/1/2-arg handlers) and the config-only (handler-less) wire that
# registers a client listener but no server observer.

mount_node <- function(node) {
  s <- new_fake_session()
  result <- process_tags(node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, s))
  s$flushReact() # settle the initial mount before firing inputs
  list(session = s, result = result, handle = handle)
}

# The element id process_tags assigned to the (single) event row.
event_id <- function(result) result$events[[1]]$id

test_that("a 0-arg handler is invoked with no arguments", {
  fired <- 0L
  m <- mount_node(shiny::tags$button(onClick = function() fired <<- fired + 1L))
  id <- event_id(m$result)
  m$session$setInputs(
    !!paste0("irid_ev_", id, "_click") := list(id = id, data = list())
  )
  m$session$flushReact()
  expect_equal(fired, 1L)
  m$handle$destroy()
})

test_that("a 1-arg handler receives the event data under the envelope", {
  seen <- NULL
  m <- mount_node(shiny::tags$button(onClick = function(e) seen <<- e))
  id <- event_id(m$result)
  m$session$setInputs(
    !!paste0("irid_ev_", id, "_click") := list(id = id, data = list(x = 5))
  )
  m$session$flushReact()
  expect_equal(seen$x, 5)
  # The envelope (id/seq) is unwrapped — the handler sees only the event data.
  expect_false("id" %in% names(seen))
  expect_false("seq" %in% names(seen))
  m$handle$destroy()
})

test_that("a 2-arg handler receives the event object and the source id", {
  seen_id <- NULL
  m <- mount_node(shiny::tags$button(
    onClick = function(e, src) seen_id <<- src
  ))
  id <- event_id(m$result)
  m$session$setInputs(
    !!paste0("irid_ev_", id, "_click") := list(id = id, data = list())
  )
  m$session$flushReact()
  expect_equal(seen_id, id)
  m$handle$destroy()
})

test_that("a config-only wire registers a client listener but no observer", {
  # `wire` carrying only dom_opts (no handler) is client-only: the irid-events
  # row is marked clientOnly and no server observer is created.
  m <- mount_node(shiny::tags$button(
    onClick = wire(dom_opts = wire_dom_opts(prevent_default = TRUE))
  ))
  ev_msgs <- Filter(function(x) x$type == "irid-events", m$session$msgs())
  expect_length(ev_msgs, 1L)
  row <- ev_msgs[[1]]$message[[1]]
  expect_true(row$clientOnly)
  m$handle$destroy()
})

test_that("irid.debug.latency does not suppress the handler", {
  fired <- 0L
  m <- mount_node(shiny::tags$button(onClick = function() fired <<- fired + 1L))
  id <- event_id(m$result)
  withr::with_options(list(irid.debug.latency = 0.001), {
    m$session$setInputs(
      !!paste0("irid_ev_", id, "_click") := list(id = id, data = list())
    )
    m$session$flushReact()
  })
  expect_equal(fired, 1L)
  m$handle$destroy()
})
