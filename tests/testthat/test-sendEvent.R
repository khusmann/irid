# --- irid.sendEvent() JS primitive + R-side event dispatch -------------------
#
# These tests exercise the R-side event pipeline that `irid.sendEvent()` on
# the JS side feeds into. `sendEvent` constructs a payload and sends it via
# `Shiny.setInputValue("irid_ev_{id}_{event}", payload)`. On the R side,
# `irid_mount_processed` listens on `session$input[["irid_ev_{id}_{event}"]]`
# and dispatches to the user's handler.
#
# We simulate the JS side by calling `session$setInputs()` with the
# appropriate input name and payload shape — exactly what `sendEvent`
# produces in the browser.

flushReact <- function() shiny:::flushReact()

# Create a minimal fake Shiny session that records custom messages (so we
# can verify force-send side effects) and supports setInputs for simulating
# incoming events.
new_fake_session <- function() {
  s <- shiny::MockShinySession$new()
  store <- new.env(parent = emptyenv())
  store$msgs <- list()
  store$userData <- list()
  s$sendCustomMessage <- function(type, message) {
    store$msgs[[length(store$msgs) + 1L]] <<- list(
      type = type, message = message
    )
    invisible()
  }
  s$msgs <- function() store$msgs
  s
}

# Simulate what irid.sendEvent produces on the JS side: set a Shiny input
# named `irid_ev_{id}_{event}` with the given payload.
simulate_send_event <- function(session, input_name, payload) {
  args <- list(payload)
  names(args) <- input_name
  do.call(session$setInputs, args)
}

# Process a tag with an event handler and mount it, returning the session
# and mount handle.
mount_handler <- function(tag) {
  session <- new_fake_session()
  result <- irid:::process_tags(tag)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  # Flush after mount so observers are properly initialized
  flushReact()
  list(session = session, handle = handle, result = result)
}

# --- Basic sendEvent integration ---------------------------------------------

test_that("irid.sendEvent payload triggers R handler with correct value", {
  captured <- NULL
  tag <- tags$button(id = "btn", onClick = function(e) {
    captured <<- e$value
  })
  m <- mount_handler(tag)
  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_click")

  # Simulate what irid.sendEvent("btn", "click", {value: 42}) sends
  payload <- list(value = 42, id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  simulate_send_event(m$session, input_name, payload)

  expect_equal(captured, 42)
})

test_that("multiple sendEvent calls increment sequence counter in R handler", {
  sequences_seen <- integer()
  tag <- tags$button(id = "btn", onClick = function(e) NULL)
  m <- mount_handler(tag)
  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_click")

  # Capture the sequence from inside the handler. The sequence is stored
  # on session$userData during the handler run, then cleared by onFlushed
  # at the end of the flush cycle. We capture it via a proxy value.
  captured_seq <- NULL
  captured_source <- NULL
  local_session <- NULL

  mk_tag <- function() {
    tags$button(id = "btn2", onClick = function(e) {
      seq_info <- local_session$userData$irid_current_sequence
      captured_seq <<- seq_info$seq
      captured_source <<- seq_info$source
    })
  }

  tag2 <- mk_tag()
  m2 <- mount_handler(tag2)
  local_session <- m2$session

  ev_id2 <- m2$result$events[[1]]$id
  input_name2 <- paste0("irid_ev_", ev_id2, "_click")

  # Send first event
  p1 <- list(value = "a", id = ev_id2, nonce = 0.1)
  p1[["__irid_seq"]] <- 1L
  simulate_send_event(m2$session, input_name2, p1)

  expect_equal(captured_seq, 1L)
  expect_equal(captured_source, ev_id2)

  # Send second event — sequence should increment
  p2 <- list(value = "b", id = ev_id2, nonce = 0.2)
  p2[["__irid_seq"]] <- 2L
  simulate_send_event(m2$session, input_name2, p2)

  expect_equal(captured_seq, 2L)
})

# --- Handler arity dispatch ---------------------------------------------------

test_that("0-arg handler is called with no arguments", {
  called <- FALSE
  tag <- tags$button(onClick = function() {
    called <<- TRUE
  })
  m <- mount_handler(tag)
  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_click")

  payload <- list(id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  simulate_send_event(m$session, input_name, payload)
  flushReact()

  expect_true(called)
})

test_that("1-arg handler receives the event object", {
  received <- NULL
  tag <- tags$button(onClick = function(e) {
    received <<- e
  })
  m <- mount_handler(tag)
  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_click")

  payload <- list(value = "hello", id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  simulate_send_event(m$session, input_name, payload)
  flushReact()

  expect_equal(received$value, "hello")
  # id, nonce, __irid_seq must be stripped before reaching the handler
  expect_null(received$id)
  expect_null(received$nonce)
  expect_null(received[["__irid_seq"]])
})

test_that("2-arg handler receives event object and source element ID", {
  received_event <- NULL
  received_id <- NULL
  tag <- tags$button(id = "mybtn", onClick = function(e, id) {
    received_event <<- e
    received_id <<- id
  })
  m <- mount_handler(tag)
  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_click")

  payload <- list(value = 99, id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  simulate_send_event(m$session, input_name, payload)
  flushReact()

  expect_equal(received_event$value, 99)
  expect_equal(received_id, ev_id)
})

# --- Event data sanitization --------------------------------------------------

test_that("NULL values in event data are converted to NA for the handler", {
  received <- NULL
  tag <- tags$input(onInput = function(e) {
    received <<- e
  })
  m <- mount_handler(tag)
  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_input")

  # Some JS event properties are null — they should become NA in R
  payload <- list(value = "text", valueAsNumber = NULL, id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  simulate_send_event(m$session, input_name, payload)
  flushReact()

  expect_equal(received$value, "text")
  expect_equal(received$valueAsNumber, NA)
})

test_that("id, nonce, __irid_seq are stripped from the event object", {
  received <- NULL
  tag <- tags$button(onClick = function(e) {
    received <<- e
  })
  m <- mount_handler(tag)
  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_click")

  payload <- list(x = 1, y = 2, id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  simulate_send_event(m$session, input_name, payload)
  flushReact()

  expect_equal(received$x, 1)
  expect_equal(received$y, 2)
  expect_null(received$id)
  expect_null(received$nonce)
  expect_null(received[["__irid_seq"]])
})

# --- Event on elements without explicit id ------------------------------------

test_that("event on element without explicit id still dispatches correctly", {
  captured <- NULL
  # No id attribute — process_tags assigns one
  tag <- tags$button(onClick = function(e) {
    captured <<- e$value
  })
  m <- mount_handler(tag)
  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_click")

  payload <- list(value = "no-id", id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  simulate_send_event(m$session, input_name, payload)

  expect_equal(captured, "no-id")
})

# --- Force-send on event (optimistic-update protocol) -------------------------
# When an event handler runs, mount force-sends the current binding values
# for the source element, tagged with the event's sequence. This lets the
# client apply server transforms even when the handler sets a reactive to
# the same value (a no-op that doesn't invalidate the binding observer).

test_that("force-send sends binding values tagged with sequence on event", {
  rv <- shiny::reactiveVal("init")
  tag <- tags$input(value = rv, onInput = function(e) {
    rv(e$value)
  })
  m <- mount_handler(tag)

  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_input")

  payload <- list(value = "typed", id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  simulate_send_event(m$session, input_name, payload)

  msgs <- m$session$msgs()
  # Both the force-send from the event observer AND the binding observer
  # fire with the sequence. Check that at least one irid-attr message has
  # the correct value and sequence.
  attr_msgs <- Filter(
    function(m) m$type == "irid-attr" && m$message$attr == "value",
    msgs
  )
  expect_true(length(attr_msgs) >= 1L)
  # The latest irid-attr should have the typed value
  last_attr <- attr_msgs[[length(attr_msgs)]]
  expect_equal(last_attr$message$value, "typed")
  # At least one should carry the sequence
  any_with_seq <- any(vapply(attr_msgs, function(m) {
    identical(m$message$sequence, 1L)
  }, logical(1L)))
  expect_true(any_with_seq)
})
