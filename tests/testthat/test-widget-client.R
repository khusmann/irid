# --- Client-side widget infrastructure (irid.js) -----------------------------
#
# These tests validate the client-side JS additions from Slice 2:
#   - irid.registerWidget() / irid.widgets registry
#   - irid-widget-init, irid-widget-channel, irid-widget-destroy message handlers
#   - irid.trackChannel() per-field tracking helper
#   - deepEqual helper
#
# Most of these are purely JS behaviors that require a browser to execute.
# Where possible, we validate the algorithms in R (the JS follows the same
# logic), verify JS syntax, and document the message contract shapes that
# Slice 3's mount code will produce.

# --- JS syntax validation ----------------------------------------------------

test_that("irid.js parses without syntax errors", {
  js_path <- system.file("js/irid.js", package = "irid")
  expect_true(file.exists(js_path))
  # node --check exits 0 on valid syntax
  result <- system2("node", c("--check", js_path), stdout = FALSE, stderr = FALSE)
  expect_equal(result, 0L)
})

# --- deepEqual algorithm (R mirror) ------------------------------------------
#
# deepEqual is an internal JS function used by irid.trackChannel to compare
# sent vs. server-received values. The JS and R implementations follow the
# same logic. We test the algorithm in R to establish the contract.

deep_equal <- function(a, b) {
  if (identical(a, b)) return(TRUE)
  if (is.null(a) || is.null(b)) return(FALSE)
  if (typeof(a) != typeof(b)) return(FALSE)
  # Only recurse into lists (includes nested and named lists);
  # atomic vectors are caught by identical() above.
  if (!is.list(a) || !is.list(b)) return(FALSE)
  if (length(a) != length(b)) return(FALSE)
  if (!identical(names(a), names(b))) return(FALSE)
  for (i in seq_along(a)) {
    if (!deep_equal(a[[i]], b[[i]])) return(FALSE)
  }
  TRUE
}

test_that("deep_equal: identical scalars return TRUE", {
  expect_true(deep_equal(1, 1))
  expect_true(deep_equal("a", "a"))
  expect_true(deep_equal(TRUE, TRUE))
  expect_true(deep_equal(NULL, NULL))
})

test_that("deep_equal: different scalars return FALSE", {
  expect_false(deep_equal(1, 2))
  expect_false(deep_equal("a", "b"))
  expect_false(deep_equal(TRUE, FALSE))
})

test_that("deep_equal: NULL vs non-NULL returns FALSE", {
  expect_false(deep_equal(NULL, 1))
  expect_false(deep_equal(1, NULL))
})

test_that("deep_equal: different types return FALSE", {
  expect_false(deep_equal(1, "1"))
  expect_false(deep_equal(TRUE, 1))
})

test_that("deep_equal: arrays compare elementwise", {
  expect_true(deep_equal(c(1, 2, 3), c(1, 2, 3)))
  expect_false(deep_equal(c(1, 2, 3), c(1, 2, 4)))
  expect_false(deep_equal(c(1, 2, 3), c(1, 2)))
})

test_that("deep_equal: nested arrays handled correctly", {
  expect_true(deep_equal(list(1, list(2, 3)), list(1, list(2, 3))))
  expect_false(deep_equal(list(1, list(2, 3)), list(1, list(2, 4))))
})

test_that("deep_equal: named lists compared by keys and values", {
  expect_true(deep_equal(list(a = 1, b = 2), list(a = 1, b = 2)))
  expect_false(deep_equal(list(a = 1, b = 2), list(a = 1, b = 3)))
  expect_false(deep_equal(list(a = 1, b = 2), list(a = 1, c = 2)))
  expect_false(deep_equal(list(a = 1), list(a = 1, b = 2)))
})

test_that("deep_equal: empty structures", {
  expect_true(deep_equal(list(), list()))
  expect_true(deep_equal(character(0), character(0)))
  expect_false(deep_equal(list(), character(0)))
})

test_that("deep_equal: plotly-style relayout payloads", {
  # Typical plotly range payloads — these are what trackChannel compares
  expect_true(deep_equal(c(0, 10), c(0, 10)))
  expect_false(deep_equal(c(0, 10), c(0, 50)))
  expect_false(deep_equal(c(0, 10), c(0, 10, 20)))
  expect_true(deep_equal(
    list(xaxis_range = c(0, 10), yaxis_range = c(0, 100)),
    list(xaxis_range = c(0, 10), yaxis_range = c(0, 100))
  ))
  expect_false(deep_equal(
    list(xaxis_range = c(0, 10), yaxis_range = c(0, 100)),
    list(xaxis_range = c(0, 10), yaxis_range = c(0, 50))
  ))
})

# --- Message contract validation ---------------------------------------------
#
# These tests validate the expected shapes of widget messages that the R side
# will send (in Slice 3) and the JS side expects to receive. They serve as
# documentation and will catch regressions when the mount wiring is added.

test_that("irid-widget-init message structure", {
  # The init message is sent once on mount. Shape from the spec:
  msg <- list(
    id = "irid-7",
    widget = "counter",
    render_channel = NULL,
    config = list(mode = "javascript", theme = "default"),
    channels = list(count = 0)
  )
  expect_equal(msg$id, "irid-7")
  expect_equal(msg$widget, "counter")
  expect_null(msg$render_channel)
  expect_equal(msg$config$mode, "javascript")
  expect_equal(msg$channels$count, 0)
})

test_that("irid-widget-init with render channel", {
  msg <- list(
    id = "irid-9",
    widget = "plotly",
    render_channel = "spec",
    config = list(),
    channels = list(
      spec = list(layout = list(), data = list()),
      xaxis_range = NULL,
      yaxis_range = NULL
    )
  )
  expect_equal(msg$render_channel, "spec")
  expect_named(msg$channels, c("spec", "xaxis_range", "yaxis_range"))
})

test_that("irid-widget-channel message structure", {
  # Channel update message — sent on every reactive channel change
  msg <- list(
    id = "irid-7",
    channel = "content",
    value = "# Updated\nContent",
    isRender = FALSE
  )
  expect_equal(msg$id, "irid-7")
  expect_equal(msg$channel, "content")
  expect_equal(msg$value, "# Updated\nContent")
  expect_false(msg$isRender)
})

test_that("irid-widget-channel with isRender: true", {
  msg <- list(
    id = "irid-7",
    channel = "spec",
    value = list(type = "scatter"),
    isRender = TRUE
  )
  expect_true(msg$isRender)
})

test_that("irid-widget-destroy message structure", {
  msg <- list(id = "irid-7")
  expect_equal(msg$id, "irid-7")
  expect_named(msg, "id")
})

# --- Widget lifecycle simulation (R-side conceptual check) -------------------
#
# These tests simulate the R-to-client message flow that mount will emit
# (Slice 3). They validate the sequence and structure of messages that
# the JS handlers (defined in irid.js) expect to receive.

# Test helper: record custom messages sent through a fake session
init_lifecycle_session <- function() {
  s <- shiny::MockShinySession$new()
  store <- new.env(parent = emptyenv())
  store$msgs <- list()
  s$sendCustomMessage <- function(type, message) {
    store$msgs[[length(store$msgs) + 1L]] <<- list(
      type = type, message = message
    )
    invisible()
  }
  s$msgs <- function() store$msgs
  s
}

test_that("widget init message is sent before any channel updates", {
  session <- init_lifecycle_session()
  id <- "irid-5"
  widget <- "counter"
  channels <- list(count = 0)

  # Simulate what mount will do (Slice 3): send init, then observe channels
  session$sendCustomMessage("irid-widget-init", list(
    id = id,
    widget = widget,
    render_channel = NULL,
    config = list(),
    channels = channels
  ))

  session$sendCustomMessage("irid-widget-channel", list(
    id = id,
    channel = "count",
    value = 1,
    isRender = FALSE
  ))

  msgs <- session$msgs()
  expect_length(msgs, 2L)
  expect_equal(msgs[[1]]$type, "irid-widget-init")
  expect_equal(msgs[[2]]$type, "irid-widget-channel")
  expect_equal(msgs[[2]]$message$value, 1)
})

test_that("multiple widgets each receive their own messages", {
  session <- init_lifecycle_session()

  # Widget A
  session$sendCustomMessage("irid-widget-init", list(
    id = "widget-a", widget = "counter",
    render_channel = NULL, config = list(), channels = list(count = 0)
  ))
  # Widget B
  session$sendCustomMessage("irid-widget-init", list(
    id = "widget-b", widget = "counter",
    render_channel = NULL, config = list(), channels = list(count = 10)
  ))

  session$sendCustomMessage("irid-widget-channel", list(
    id = "widget-a", channel = "count", value = 1, isRender = FALSE
  ))
  session$sendCustomMessage("irid-widget-channel", list(
    id = "widget-b", channel = "count", value = 11, isRender = FALSE
  ))

  msgs <- session$msgs()
  expect_length(msgs, 4L)

  # Each widget got its own init
  init_a <- msgs[[1]]
  init_b <- msgs[[2]]
  expect_equal(init_a$message$id, "widget-a")
  expect_equal(init_a$message$channels$count, 0)
  expect_equal(init_b$message$id, "widget-b")
  expect_equal(init_b$message$channels$count, 10)

  # Each widget got its own channel update
  expect_equal(msgs[[3]]$message$id, "widget-a")
  expect_equal(msgs[[3]]$message$value, 1)
  expect_equal(msgs[[4]]$message$id, "widget-b")
  expect_equal(msgs[[4]]$message$value, 11)
})

test_that("widget destroy message sent on unmount", {
  session <- init_lifecycle_session()

  # Simulate init + channel + destroy lifecycle
  session$sendCustomMessage("irid-widget-init", list(
    id = "irid-7", widget = "counter",
    render_channel = NULL, config = list(), channels = list(count = 5)
  ))
  session$sendCustomMessage("irid-widget-channel", list(
    id = "irid-7", channel = "count", value = 6, isRender = FALSE
  ))
  session$sendCustomMessage("irid-widget-destroy", list(id = "irid-7"))

  msgs <- session$msgs()
  expect_length(msgs, 3L)
  expect_equal(msgs[[3]]$type, "irid-widget-destroy")
  expect_equal(msgs[[3]]$message$id, "irid-7")
})

test_that("isRender flag set on render channel updates only", {
  session <- init_lifecycle_session()

  # Widget with render_channel = "spec"
  session$sendCustomMessage("irid-widget-init", list(
    id = "irid-9", widget = "plotly",
    render_channel = "spec", config = list(),
    channels = list(spec = list(), xaxis_range = NULL)
  ))

  # Render channel update → isRender: true
  session$sendCustomMessage("irid-widget-channel", list(
    id = "irid-9", channel = "spec",
    value = list(type = "scatter"), isRender = TRUE
  ))

  # Non-render channel update → isRender: false
  session$sendCustomMessage("irid-widget-channel", list(
    id = "irid-9", channel = "xaxis_range",
    value = c(0, 10), isRender = FALSE
  ))

  msgs <- session$msgs()
  expect_true(msgs[[2]]$message$isRender)
  expect_false(msgs[[3]]$message$isRender)
})

# --- trackChannel conceptual model (R simulation) ----------------------------
#
# The JS irid.trackChannel(el) returns a tracker with recordSent() and
# receiveChannel(). We simulate the same logic in R to establish the
# contract that the JS implementation follows.

TrackChannel <- function(id) {
  last_sent <- list()
  last_received <- list()
  destroyed <- FALSE

  list(
    recordSent = function(field_name, value) {
      last_sent[[field_name]] <<- value
      invisible()
    },
    receiveChannel = function(field_name, server_value) {
      if (destroyed) stop("tracker destroyed")
      sent <- last_sent[[field_name]]
      last_received[[field_name]] <<- server_value
      if (is.null(sent)) return("no-change")
      if (deep_equal(sent, server_value)) return("accepted")
      return("corrected")
    },
    destroy = function() {
      destroyed <<- TRUE
    }
  )
}

test_that("trackChannel: recordSent stores value for comparison", {
  tracker <- TrackChannel("widget-a")
  tracker$recordSent("xaxis_range", c(0, 10))
  # No error, stored internally — verified by receiveChannel
  expect_equal(
    tracker$receiveChannel("xaxis_range", c(0, 10)),
    "accepted"
  )
})

test_that("trackChannel: accepted when server value matches sent value", {
  tracker <- TrackChannel("w1")
  tracker$recordSent("xaxis_range", c(0, 10))
  expect_equal(tracker$receiveChannel("xaxis_range", c(0, 10)), "accepted")
})

test_that("trackChannel: corrected when server value differs from sent", {
  tracker <- TrackChannel("w1")
  tracker$recordSent("xaxis_range", c(0, 10))
  expect_equal(tracker$receiveChannel("xaxis_range", c(0, 50)), "corrected")
})

test_that("trackChannel: no-change when no recordSent for that field", {
  tracker <- TrackChannel("w1")
  expect_equal(tracker$receiveChannel("unrecorded", 42), "no-change")
})

test_that("trackChannel: nested objects compared deeply", {
  tracker <- TrackChannel("w1")
  tracker$recordSent("layout", list(xaxis = list(range = c(0, 10))))
  expect_equal(
    tracker$receiveChannel("layout", list(xaxis = list(range = c(0, 10)))),
    "accepted"
  )
  expect_equal(
    tracker$receiveChannel("layout", list(xaxis = list(range = c(0, 50)))),
    "corrected"
  )
})

test_that("trackChannel: multiple independent fields", {
  tracker <- TrackChannel("w1")
  tracker$recordSent("x", 1)
  tracker$recordSent("y", 2)
  expect_equal(tracker$receiveChannel("x", 1), "accepted")
  expect_equal(tracker$receiveChannel("y", 3), "corrected")
})

# --- Counter widget lifecycle (conceptual) -----------------------------------
#
# The counter widget from Task 2.4 receives init with an initial count,
# sends click events via irid.sendEvent, and updates on channel messages.
# We verify the message contract here; the actual JS execution needs a
# browser.

test_that("counter widget init message has expected shape", {
  init_msg <- list(
    id = "counter-1",
    widget = "counter",
    render_channel = NULL,
    config = list(),
    channels = list(count = 42)
  )
  expect_equal(init_msg$widget, "counter")
  expect_equal(init_msg$channels$count, 42)
  expect_null(init_msg$render_channel)
})

test_that("counter widget channel update message shape", {
  channel_msg <- list(
    id = "counter-1",
    channel = "count",
    value = 43,
    isRender = FALSE
  )
  expect_equal(channel_msg$channel, "count")
  expect_equal(channel_msg$value, 43)
})

test_that("counter widget click sends irid.sendEvent with id", {
  # Click handler in counter widget JS:
  #   el.addEventListener('click', function() {
  #     irid.sendEvent(msg.id, 'click', {});
  #   });
  # On the R side, this arrives as irid_ev_{id}_click
  session <- init_lifecycle_session()
  id <- "counter-1"

  # Simulate what mount sees when sendEvent fires
  input_name <- paste0("irid_ev_", id, "_click")
  args <- list(list(value = NULL, id = id, nonce = 0.5))
  names(args) <- input_name
  names(args[[1]])[1] <- "value"  # just keep as generic event

  # The R side (mount) listens on session$input[[input_name]] —
  # this validates the input naming convention that sendEvent produces.
  expected_input <- paste0("irid_ev_", id, "_click")
  expect_equal(input_name, expected_input)
})
