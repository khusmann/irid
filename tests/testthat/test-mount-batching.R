# Flush-coalesced render batching (`irid_send` / `irid_arm_render_batch` in
# mount.R). The render-phase messages of one flush — irid-mutate / irid-attr
# (dom/text) / irid-wire / irid-widget-init — ride a single `irid-batch` frame
# the client replays in order, so a nested control-flow render lands in one paint
# instead of one-per-message. These tests assert on the RAW (unflattened) stream.

# All irid-batch envelopes, in send order.
batches <- function(s) Filter(function(m) m$type == "irid-batch", s$raw_msgs())

# The ops of the single batch a mount-then-flush produced.
sole_batch_ops <- function(s) {
  b <- batches(s)
  expect_length(b, 1L)
  b[[1]]$message$ops
}

mount <- function(node) {
  s <- new_fake_session()
  handle <- shiny::isolate(irid:::irid_mount_processed(process_tags(node), s))
  list(session = s, handle = handle)
}

test_that("a flush's render messages coalesce into one irid-batch", {
  items <- shiny::reactiveVal(list("a", "b", "c"))
  m <- mount(shiny::tags$ul(Each(items, \(x) shiny::tags$li(\() x()))))

  # Nothing on the wire until the flush drains the batch.
  expect_length(m$session$raw_msgs(), 0L)

  m$session$flushReact()
  # Exactly one frame, and it is the batch (no loose irid-mutate/-attr).
  expect_length(m$session$raw_msgs(), 1L)
  ops <- sole_batch_ops(m$session)
  types <- vapply(ops, function(op) op$type, character(1L))
  expect_true("irid-mutate" %in% types)   # the Each insert
  expect_true("irid-attr" %in% types)     # the per-item reactive text

  m$handle$destroy()
})

test_that("batch ops preserve emission order: a mutate precedes its text attr", {
  items <- shiny::reactiveVal(list("a"))
  m <- mount(shiny::tags$ul(Each(items, \(x) shiny::tags$li(\() x()))))
  m$session$flushReact()

  types <- vapply(sole_batch_ops(m$session), function(op) op$type, character(1L))
  first_mutate <- which(types == "irid-mutate")[1]
  first_attr <- which(types == "irid-attr")[1]
  expect_true(first_mutate < first_attr) # insert the node before writing its text

  m$handle$destroy()
})

test_that("each flush produces its own batch", {
  items <- shiny::reactiveVal(list("a"))
  m <- mount(shiny::tags$ul(Each(items, \(x) shiny::tags$li(\() x()))))
  m$session$flushReact()
  expect_length(batches(m$session), 1L)

  items(list("a", "b")) # append an item -> a second render
  m$session$flushReact()
  expect_length(batches(m$session), 2L)

  m$handle$destroy()
})

test_that("a wire row rides the batch, after the mutate that inserts its element", {
  items <- shiny::reactiveVal(list("a"))
  m <- mount(shiny::tags$ul(Each(items, \(x) {
    shiny::tags$li(onClick = function() NULL, \() x())
  })))
  m$session$flushReact()

  types <- vapply(sole_batch_ops(m$session), function(op) op$type, character(1L))
  expect_true("irid-wire" %in% types)
  expect_true(which(types == "irid-mutate")[1] < which(types == "irid-wire")[1])

  m$handle$destroy()
})
