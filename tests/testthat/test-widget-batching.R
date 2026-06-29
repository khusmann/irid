# Widget prop writes in the unified render protocol.
#
# Each widget prop write is a single-key `attr` op (target = "widget") emitted in
# the flush's render frame — the same `irid_send` path as a DOM attr, no separate
# server coalescing. The per-widget MERGE (collect every target="widget" op for
# one id across the render, call update() once → one redraw) now lives in the
# CLIENT (handlers.ts `applyRender`); the e2e suite exercises the single-redraw
# behaviour. These tests assert the server emits the right per-op shapes, in the
# right order, in the right frame.

# Just the widget-target attr ops, in send order.
widget_attrs <- function(session) {
  Filter(
    function(m) m$type == "irid-attr" && identical(m$message$target, "widget"),
    session$msgs()
  )
}

# All irid-render frames in send order (for asserting one-frame vs. separate).
renders <- function(session) {
  Filter(function(m) m$type == "irid-render", session$raw_msgs())
}

mount_widget <- function(props) {
  session <- new_fake_session()
  result <- process_tags(IridWidget(name = "test", props = props))
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  list(session = session, handle = handle, result = result)
}

# --- per-op shape ------------------------------------------------------------

test_that("a single bound prop emits one single-key widget attr op", {
  content <- shiny::reactiveVal("hi")
  m <- mount_widget(list(content = content))
  m$session$flushReact()

  ms <- widget_attrs(m$session)
  expect_length(ms, 1L)
  expect_equal(ms[[1]]$message$target, "widget")
  expect_equal(ms[[1]]$message$attr, "content")
  expect_equal(ms[[1]]$message$value, "hi")

  m$handle$destroy()
})

test_that("two props changing in one flush emit two ops in one render frame", {
  content <- shiny::reactiveVal("hi")
  cursor  <- shiny::reactiveVal(list(line = 1, ch = 0))
  m <- mount_widget(list(content = content, cursor = cursor))

  # Initial mount fires both binding observers in the same flush -> one frame.
  m$session$flushReact()
  expect_length(renders(m$session), 1L)

  ms <- widget_attrs(m$session)
  by_attr <- stats::setNames(ms, vapply(ms, function(x) x$message$attr, character(1)))
  expect_setequal(names(by_attr), c("content", "cursor"))
  expect_equal(by_attr$content$message$value, "hi")
  expect_equal(by_attr$cursor$message$value, list(line = 1, ch = 0))

  m$handle$destroy()
})

test_that("props changing in separate flushes emit ops in separate frames", {
  content <- shiny::reactiveVal("hi")
  cursor  <- shiny::reactiveVal(list(line = 1, ch = 0))
  m <- mount_widget(list(content = content, cursor = cursor))

  m$session$flushReact()            # initial combined frame
  expect_length(renders(m$session), 1L)

  shiny::isolate(content("yo"))
  m$session$flushReact()
  shiny::isolate(cursor(list(line = 3, ch = 2)))
  m$session$flushReact()

  # Three frames total: initial, content, cursor.
  expect_length(renders(m$session), 3L)
  ms <- widget_attrs(m$session)
  last_two <- ms[(length(ms) - 1L):length(ms)]
  expect_equal(last_two[[1]]$message$attr, "content")
  expect_equal(last_two[[1]]$message$value, "yo")
  expect_equal(last_two[[2]]$message$attr, "cursor")
  expect_equal(last_two[[2]]$message$value, list(line = 3, ch = 2))

  m$handle$destroy()
})

test_that("a later write for the same key appears after the earlier one", {
  # Two flushes write the same prop; each is its own op, in order — the client
  # is what folds same-key writes (last wins per render).
  content <- shiny::reactiveVal("old")
  m <- mount_widget(list(content = content))
  m$session$flushReact()
  shiny::isolate(content("new"))
  m$session$flushReact()

  vals <- vapply(widget_attrs(m$session), function(x) x$message$value, character(1))
  expect_equal(vals, c("old", "new"))

  m$handle$destroy()
})

test_that("a NULL prop value rides as an explicit null op value", {
  content <- shiny::reactiveVal(NULL)
  m <- mount_widget(list(content = content))
  m$session$flushReact()

  op <- widget_attrs(m$session)[[1]]$message
  expect_equal(op$attr, "content")
  expect_true("value" %in% names(op))
  expect_null(op$value)

  m$handle$destroy()
})

# --- per-op gate -------------------------------------------------------------

test_that("a widget attr op carries its own {seq, channel} gate", {
  content <- shiny::reactiveVal("hi")
  m <- mount_widget(list(content = content))
  m$session$flushReact()            # initial (programmatic) frame
  base <- length(widget_attrs(m$session))

  wid <- m$result$bindings[[1]]$id
  shiny::isolate(content("yo"))
  # Per-channel shape: keyed by source id, then write-target attr.
  m$session$userData$irid_current_sequence <- list()
  m$session$userData$irid_current_sequence[[wid]] <-
    list(content = irid:::irid_echo_gate(42, "ch_content"))
  m$session$flushReact()

  last <- widget_attrs(m$session)[[base + 1L]]$message
  expect_equal(last$attr, "content")
  expect_equal(last$gate, list(seq = 42, channel = "ch_content"))

  m$handle$destroy()
})

test_that("a widget attr op with no current-sequence entry echoes ungated", {
  # A sibling channel recorded a DIFFERENT attr this flush; the content binding
  # finds no entry for its own attr, so its op carries a null gate (programmatic).
  content <- shiny::reactiveVal("hi")
  m <- mount_widget(list(content = content))
  m$session$flushReact()
  base <- length(widget_attrs(m$session))

  wid <- m$result$bindings[[1]]$id
  shiny::isolate(content("yo"))
  m$session$userData$irid_current_sequence <- list()
  m$session$userData$irid_current_sequence[[wid]] <-
    list(other_attr = irid:::irid_echo_gate(9, "ch_other"))
  m$session$flushReact()

  last <- widget_attrs(m$session)[[base + 1L]]$message
  expect_true("gate" %in% names(last))
  expect_null(last$gate)

  m$handle$destroy()
})

# --- named-vector encoding ---------------------------------------------------

test_that("json_map converts named-vector members to named lists (JSON objects)", {
  # A named atomic value would serialize via Shiny's keep_vec_names path and warn;
  # json_map converts it to a named list — same JSON object, no deprecation.
  expect_identical(
    json_map(list(vis = c("8" = "legendonly"))),
    list(vis = list(`8` = "legendonly"))
  )
  # Unnamed vectors stay vectors (JSON arrays); scalars pass through; recursion
  # preserves keys at depth.
  expect_identical(
    json_map(list(r = c(40, 200), m = "pan", nested = list(x = c(a = 1)))),
    list(r = c(40, 200), m = "pan", nested = list(x = list(a = 1)))
  )
  # An empty map serializes as `{}` (a named empty list), not `[]`.
  expect_identical(json_map(list()), stats::setNames(list(), character(0)))
})

test_that("a named-vector prop round-trips through mount as a JSON object", {
  # Integration guard for the global jsonify hook (`json_value`, used by both the
  # init `json_map` and the per-op `msg_irid_attr`): a generic widget whose prop
  # value is a named atomic vector must reach the wire as a named *list* — so Shiny
  # encodes it as a `{ }` object — on BOTH the init and the per-op attr paths.

  # (a) init path: a constant named-vector prop ships as a named list.
  init <- mount_widget(list(vis = c(`8` = "legendonly", `6` = "true")))
  init$session$flushReact() # drain the render frame carrying the widget-init
  init_msg <- Filter(function(m) m$type == "irid-widget-init", init$session$msgs())
  expect_length(init_msg, 1L)
  expect_identical(init_msg[[1]]$message$props$vis,
                   list(`8` = "legendonly", `6` = "true"))
  init$handle$destroy()

  # (b) attr path: a bound prop updating to a named vector rides as a list.
  vis <- shiny::reactiveVal(c(`8` = "legendonly"))
  m <- mount_widget(list(vis = vis))
  m$session$flushReact()
  expect_identical(widget_attrs(m$session)[[1]]$message$value,
                   list(`8` = "legendonly"))
  m$handle$destroy()
})
