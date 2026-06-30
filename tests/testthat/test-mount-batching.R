# Flush-coalesced render (`irid_send` / `irid_arm_render` in mount.R). Every
# DOM/widget op of one flush — mutate / attr (dom/widget) / text / wire /
# widget-init — rides a single `irid-render` frame the client applies in one pass,
# so a nested control-flow render lands in one paint instead of one-per-message.
# These tests assert on the RAW (unflattened) stream.

# All irid-render frames, in send order.
renders <- function(s) Filter(function(m) m$type == "irid-render", s$raw_msgs())

# The ops of the single render a mount-then-flush produced.
sole_render_ops <- function(s) {
  r <- renders(s)
  expect_length(r, 1L)
  r[[1]]$message$ops
}

op_kinds <- function(ops) vapply(ops, function(op) op$kind, character(1L))

mount <- function(node) {
  s <- new_fake_session()
  handle <- shiny::isolate(irid:::irid_mount_processed(process_tags(node), s))
  list(session = s, handle = handle)
}

test_that("a flush's render ops coalesce into one irid-render frame", {
  items <- shiny::reactiveVal(list("a", "b", "c"))
  m <- mount(shiny::tags$ul(Each(items, \(x) shiny::tags$li(\() x()))))

  # Nothing on the wire until the flush drains the render.
  expect_length(m$session$raw_msgs(), 0L)

  m$session$flushReact()
  # Exactly one frame, and it is the render (no loose ops).
  expect_length(m$session$raw_msgs(), 1L)
  kinds <- op_kinds(sole_render_ops(m$session))
  expect_true("mutate" %in% kinds)   # the Each insert
  expect_true("text" %in% kinds)     # the per-item reactive text

  m$handle$destroy()
})

test_that("render ops preserve emission order: a mutate precedes its text op", {
  items <- shiny::reactiveVal(list("a"))
  m <- mount(shiny::tags$ul(Each(items, \(x) shiny::tags$li(\() x()))))
  m$session$flushReact()

  kinds <- op_kinds(sole_render_ops(m$session))
  first_mutate <- which(kinds == "mutate")[1]
  first_text <- which(kinds == "text")[1]
  expect_true(first_mutate < first_text) # insert the node before writing its text

  m$handle$destroy()
})

test_that("each flush produces its own render frame", {
  items <- shiny::reactiveVal(list("a"))
  m <- mount(shiny::tags$ul(Each(items, \(x) shiny::tags$li(\() x()))))
  m$session$flushReact()
  expect_length(renders(m$session), 1L)

  items(list("a", "b")) # append an item -> a second render
  m$session$flushReact()
  expect_length(renders(m$session), 2L)

  m$handle$destroy()
})

test_that("a wire op rides the render, after the mutate that inserts its element", {
  items <- shiny::reactiveVal(list("a"))
  m <- mount(shiny::tags$ul(Each(items, \(x) {
    shiny::tags$li(onClick = function() NULL, \() x())
  })))
  m$session$flushReact()

  kinds <- op_kinds(sole_render_ops(m$session))
  expect_true("wire" %in% kinds)
  expect_true(which(kinds == "mutate")[1] < which(kinds == "wire")[1])

  m$handle$destroy()
})
