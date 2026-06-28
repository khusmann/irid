# Per-channel stale-echo sequencing (#28).
#
# Drives the event observers in `irid_mount_processed` with simulated client
# inputs (each an `{ id, seq, data }` envelope) and inspects the resulting
# `irid-attr` echoes. The core invariant: an echo is stamped with the sequence
# of ITS OWN channel, so a sibling channel firing in the same flush — another
# prop, or a notification — cannot make a current echo look stale.

attr_msgs <- function(session) {
  Filter(function(m) m$type == "irid-attr", session$msgs())
}

# Mount a widget, drain the initial (programmatic) flush, and return a context
# whose `$drain()` returns only the irid-attr echoes produced after `expr`.
mount_and_settle <- function(node) {
  s <- new_fake_session()
  result <- process_tags(node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, s))
  s$flushReact()
  base <- length(attr_msgs(s))
  list(
    session = s, result = result, handle = handle,
    wid = result$bindings[[1]]$id,
    new_attrs = function() {
      all <- attr_msgs(s)
      if (length(all) <= base) list() else all[(base + 1L):length(all)]
    }
  )
}

test_that("two props written in one flush each carry their own channel+seq", {
  # The prop-vs-prop regression: under a shared per-element counter, prop `a`'s
  # echo (lower seq) was gated by prop `b`'s later send. Per channel, each
  # echo carries its own seq.
  a <- shiny::reactiveVal("a0")
  b <- shiny::reactiveVal("b0")
  ctx <- mount_and_settle(IridWidget(name = "test", props = list(a = a, b = b)))
  wid <- ctx$wid

  ctx$session$setInputs(
    !!paste0("irid_prop_", wid, "_a") :=
      list(id = wid, seq = 5, data = list(value = "a1")),
    !!paste0("irid_prop_", wid, "_b") :=
      list(id = wid, seq = 9, data = list(value = "b1"))
  )
  ctx$session$flushReact()

  msgs <- ctx$new_attrs()
  expect_length(msgs, 1L)                    # coalesced into one widget batch
  vm <- msgs[[1]]$message$valueGates
  expect_equal(vm$a$seq, 5)
  expect_equal(vm$b$seq, 9)
  # Distinct channels — `a`'s is not `b`'s.
  expect_true(grepl("_a$", vm$a$channel))
  expect_true(grepl("_b$", vm$b$channel))
  expect_false(identical(vm$a$channel, vm$b$channel))

  ctx$handle$destroy()
})

test_that("a sibling notification does not pollute a prop's echo sequence", {
  # `selected_ids` (a prop) and `relayout` (a sendEvent notification with no
  # write target) fire from the SAME gesture. The notification carries a higher
  # seq but writes nothing, so the prop's echo keeps its own lower seq.
  selected <- shiny::reactiveVal(NULL)
  relayouts <- shiny::reactiveVal(0L)
  node <- IridWidget(
    name = "test",
    props = list(selected_ids = selected),
    events = list(relayout = function(e) relayouts(relayouts() + 1L))
  )
  ctx <- mount_and_settle(node)
  wid <- ctx$wid

  ctx$session$setInputs(
    !!paste0("irid_prop_", wid, "_selected_ids") :=
      list(id = wid, seq = 3, data = list(value = list("p1"))),
    !!paste0("irid_ev_", wid, "_relayout") :=
      list(id = wid, seq = 8, data = list())
  )
  ctx$session$flushReact()

  msgs <- ctx$new_attrs()
  expect_length(msgs, 1L)
  vm <- msgs[[1]]$message$valueGates
  # The prop echo carries ITS seq (3), not the notification's later 8.
  expect_equal(vm$selected_ids$seq, 3)
  expect_true(grepl("_selected_ids$", vm$selected_ids$channel))

  ctx$handle$destroy()
})

test_that("a hand-rolled handler's binding echo is ungated (no sequence)", {
  # Behaviour change (#28): gating is keyed by declared `write_targets`. A
  # hand-rolled `on*` handler declares none, so a binding it drives echoes with
  # no sequence (applied as programmatic). `value = rv` autobinds on `input`;
  # the hand-rolled `onKeyDown` is a separate, undeclared channel.
  rv <- shiny::reactiveVal("x")
  node <- shiny::tags$input(value = rv, onKeyDown = function(e) rv("typed"))
  ctx <- mount_and_settle(node)
  wid <- ctx$wid

  ctx$session$setInputs(
    !!paste0("irid_ev_", wid, "_keydown") :=
      list(id = wid, seq = 7, data = list(key = "a"))
  )
  ctx$session$flushReact()

  msgs <- ctx$new_attrs()
  # The value binding echoed the new value, with a null gate (programmatic).
  value_echo <- Filter(function(m) identical(m$message$attr, "value"), msgs)
  expect_length(value_echo, 1L)
  expect_equal(value_echo[[1]]$message$value, "typed")
  expect_true("gate" %in% names(value_echo[[1]]$message))
  expect_null(value_echo[[1]]$message$gate)

  ctx$handle$destroy()
})

test_that("an autobind handler stamps its value binding with seq + channel", {
  # The managed path: `value = rv` declares `value` as its write target, so a
  # client write of the input echoes back gated (seq + channel present).
  rv <- shiny::reactiveVal("x")
  ctx <- mount_and_settle(shiny::tags$input(value = rv))
  wid <- ctx$wid

  ctx$session$setInputs(
    !!paste0("irid_ev_", wid, "_input") :=
      list(id = wid, seq = 4, data = list(value = "y"))
  )
  ctx$session$flushReact()

  # Both the binding observer and the no-op force-send echo `value` (a known,
  # harmless duplicate) — each must carry the input channel's seq.
  value_echo <- Filter(
    function(m) identical(m$message$attr, "value"), ctx$new_attrs()
  )
  expect_gte(length(value_echo), 1L)
  for (m in value_echo) {
    expect_equal(m$message$gate$seq, 4)
    expect_true(grepl("_input$", m$message$gate$channel))
  }

  ctx$handle$destroy()
})

test_that("widget event messages carry kind and a namespaced inputId", {
  # The module fix: the client indexes widget streams by `{kind}:{id}:{event}`,
  # so the server must label each widget channel with its kind, and the inputId
  # must be the namespaced send target (MockShinySession namespaces as
  # "mock-session-").
  v <- shiny::reactiveVal("v0")
  node <- IridWidget(
    name = "test",
    props = list(v = v),
    events = list(ping = function(e) NULL)
  )
  s <- new_fake_session()
  result <- process_tags(node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, s))

  ev_msg <- Filter(function(m) m$type == "irid-wire", s$msgs())
  expect_length(ev_msg, 1L)
  rows <- ev_msg[[1]]$message
  bykind <- stats::setNames(
    rows, vapply(rows, function(r) r$event, character(1))
  )

  expect_equal(bykind$v$kind, "prop")
  expect_equal(bykind$ping$kind, "event")
  # inputId is namespaced (the client's managed key / send target).
  expect_true(grepl("^mock-session-irid_prop_.*_v$", bykind$v$channel))
  expect_true(grepl("^mock-session-irid_ev_.*_ping$", bykind$ping$channel))

  handle$destroy()
})
