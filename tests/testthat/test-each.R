flushReact <- function() shiny:::flushReact()

new_scope <- function() irid:::make_scope(NULL)

# --- Constructor validation --------------------------------------------------

test_that("Each requires a callable items", {
  expect_error(Each("not a function", \(x) x), "callable")
  expect_error(Each(NULL, \(x) x), "callable")
})

test_that("Each requires a function fn", {
  expect_error(Each(\() list(1), "not a function"), "function")
})

test_that("Each accepts NULL by (positional, the default)", {
  e <- Each(\() list(1), \(x) x)
  expect_s3_class(e, "irid_each")
  expect_null(e$by)
})

test_that("Each accepts a function by (keyed)", {
  e <- Each(\() list(list(id = 1)), \(x) x, by = \(x) x$id)
  expect_true(is.function(e$by))
})

test_that("Each rejects non-NULL non-function by", {
  expect_error(Each(\() list(1), \(x) x, by = "id"), "NULL or a function")
})

# --- process_tags extraction -------------------------------------------------

test_that("process_tags emits an each control flow", {
  items_fn <- \() list(1, 2, 3)
  fn <- \(x) tags$span(x)
  result <- process_tags(Each(items_fn, fn))
  expect_length(result$control_flows, 1L)
  cf <- result$control_flows[[1]]
  expect_equal(cf$type, "each")
  expect_identical(cf$items, items_fn)
  expect_identical(cf$fn, fn)
  expect_null(cf$by)
})

test_that("process_tags carries by when provided", {
  by_fn <- \(x) x$id
  result <- process_tags(
    Each(\() list(list(id = 1)), \(x) tags$span(), by = by_fn)
  )
  cf <- result$control_flows[[1]]
  expect_identical(cf$by, by_fn)
})

# --- Scalar slot accessor ----------------------------------------------------

test_that("make_slot_accessor reads the current value", {
  parent <- shiny::reactiveVal(c("a", "b", "c"))
  i <- 2L
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    get_value = function() parent()[[i]],
    set_value = function(v) {
      x <- shiny::isolate(parent()); x[[i]] <- v; parent(x)
    },
    scope = scope
  )
  expect_equal(shiny::isolate(acc()), "b")
})

test_that("make_slot_accessor write routes through set_value", {
  parent <- shiny::reactiveVal(c("a", "b", "c"))
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    get_value = function() parent()[[2L]],
    set_value = function(v) {
      x <- shiny::isolate(parent()); x[[2L]] <- v; parent(x)
    },
    scope = scope
  )
  acc("B")
  flushReact()
  expect_equal(shiny::isolate(parent()), c("a", "B", "c"))
  expect_equal(shiny::isolate(acc()), "B")
})

test_that("make_slot_accessor only fires on its own slot change", {
  parent <- shiny::reactiveVal(c("a", "b", "c"))
  scope1 <- new_scope()
  scope2 <- new_scope()
  acc1 <- irid:::make_slot_accessor(
    function() parent()[[1L]],
    function(v) { x <- shiny::isolate(parent()); x[[1L]] <- v; parent(x) },
    scope1
  )
  acc2 <- irid:::make_slot_accessor(
    function() parent()[[2L]],
    function(v) { x <- shiny::isolate(parent()); x[[2L]] <- v; parent(x) },
    scope2
  )
  c1 <- 0L; c2 <- 0L
  o1 <- shiny::observe({ acc1(); c1 <<- c1 + 1L })
  o2 <- shiny::observe({ acc2(); c2 <<- c2 + 1L })
  flushReact()
  base1 <- c1; base2 <- c2

  parent(c("A", "b", "c"))  # only slot 1 changed
  flushReact()
  expect_equal(c1 - base1, 1L)
  expect_equal(c2 - base2, 0L)

  o1$destroy(); o2$destroy()
})

test_that("slot accessor write updates the local rv synchronously", {
  # Mirrors `make_mini_store`'s leaf-sync regression — without a
  # synchronous local write, the event observer's force-send echo
  # reads the stale rv value and the client overwrites the user's
  # typed input.
  parent <- shiny::reactiveVal(c("a", "b", "c"))
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    function() parent()[[2L]],
    function(v) { x <- shiny::isolate(parent()); x[[2L]] <- v; parent(x) },
    scope
  )
  acc("B")
  # No flushReact() — read mid-flight.
  expect_equal(shiny::isolate(acc()), "B")
})

test_that("scope$destroy() tears down slot accessor's propagating observer", {
  parent <- shiny::reactiveVal(c("a", "b"))
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    function() parent()[[1L]],
    function(v) { x <- parent(); x[[1L]] <- v; parent(x) },
    scope
  )
  shiny::isolate(acc())  # subscribe
  flushReact()
  scope$destroy()
  parent(c("Z", "b"))
  flushReact()
  expect_equal(shiny::isolate(acc()), "a")
})

# --- Shape-change resilience -------------------------------------------------
#
# Heterogeneous Each: the outer reconciler owns shape transitions and
# rebuilds the affected entry. The slot accessor / mini-store propagators
# must not poison their internal state when they observe a shape change
# before the reconciler tears them down on the same flush.

test_that("slot accessor propagator no-ops when parent value becomes a record", {
  # Heterogeneous-list scenario: slot was a scalar, now is a record.
  # The accessor's rv must stay at its last scalar value; the outer
  # reconciler will rebuild this entry as a mini-store.
  parent <- shiny::reactiveVal(list("a", "b"))
  scope <- new_scope()
  acc <- irid:::make_slot_accessor(
    function() parent()[[1L]],
    function(v) { x <- shiny::isolate(parent()); x[[1L]] <- v; parent(x) },
    scope
  )
  shiny::isolate(acc())  # subscribe
  flushReact()
  parent(list(list(id = 1, text = "x"), "b"))  # slot 1 now a record
  flushReact()
  # rv should still hold the previous scalar — propagator declined the
  # record write. (In practice the outer reconciler tears this scope
  # down before any binding reads through the stale accessor.)
  expect_equal(shiny::isolate(acc()), "a")
})

test_that("mini-store propagator no-ops on partial-named parent", {
  # `is_branch` errors on partially-named lists; the propagator must
  # use `is_record` (permissive) so a malformed transient parent state
  # doesn't crash the observer.
  parent <- shiny::reactiveVal(list(a = 1, b = 2))
  scope <- new_scope()
  mini <- irid:::make_mini_store(parent, parent, scope)
  shiny::isolate(mini$a())
  flushReact()
  parent(list(a = 9, 2))  # partial-named — `is_record` returns FALSE
  expect_silent(flushReact())
  expect_equal(shiny::isolate(mini$a()), 1)  # propagator skipped
})

test_that("mini-store propagator no-ops when parent value becomes a scalar", {
  parent <- shiny::reactiveVal(list(a = 1, b = 2))
  scope <- new_scope()
  mini <- irid:::make_mini_store(parent, parent, scope)
  shiny::isolate(mini$a())
  flushReact()
  parent("scalar")
  expect_silent(flushReact())
  expect_equal(shiny::isolate(mini$a()), 1)
})

# --- Reconciler integration (heterogeneous Each + shape transitions) --------
#
# These exercise the actual `cf$type == "each"` reconciler in `mount.R`
# with a fake session that records the `irid-mutate` payloads. The
# fake session is intentionally minimal — it only captures the message
# stream so we can assert "remove + insert + order" came through on a
# shape transition.

new_fake_session <- function() {
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

mount_each <- function(items, fn, by = NULL) {
  session <- new_fake_session()
  result <- process_tags(Each(items, fn, by = by))
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  list(session = session, handle = handle)
}

test_that("Each builds a mini-store for record items and a slot accessor for scalars", {
  # All-records list — every entry gets a mini-store.
  rec_items <- shiny::reactiveVal(list(
    list(id = 1L, x = 1),
    list(id = 2L, x = 2)
  ))
  rec_calls <- list()
  m1 <- mount_each(rec_items, function(item) {
    rec_calls[[length(rec_calls) + 1L]] <<- item
    shiny::tags$span()
  })
  flushReact()
  expect_s3_class(rec_calls[[1]], "reactiveStore")
  expect_s3_class(rec_calls[[2]], "reactiveStore")
  m1$handle$destroy()

  # All-scalars list — every entry gets a scalar accessor.
  scl_items <- shiny::reactiveVal(list("a", "b"))
  scl_calls <- list()
  m2 <- mount_each(scl_items, function(item) {
    scl_calls[[length(scl_calls) + 1L]] <<- item
    shiny::tags$span()
  })
  flushReact()
  expect_false(inherits(scl_calls[[1]], "reactiveStore"))
  expect_false(inherits(scl_calls[[2]], "reactiveStore"))
  m2$handle$destroy()
})

test_that("Each shape transitions via parent collection write trigger rebuild", {
  # Regression for the variant-kind transition pattern: the user
  # reshapes a slot in the parent collection (e.g., a `kind_proxy`
  # swapping a heading record for a todo record by writing through
  # `items`). The Each reconciler detects the shape change for that
  # entry and rebuilds with a new mini-store of the right shape.
  # A direct shape-changing write through the mini-store would error
  # (mini-stores are shape-strict, same contract as reactiveStore).
  items <- shiny::reactiveVal(list(list(id = 1L, type = "heading", text = "")))
  built_minis <- list()
  m <- mount_each(
    items,
    function(item) {
      built_minis[[length(built_minis) + 1L]] <<- item
      shiny::tags$span()
    },
    by = function(b) b$id
  )
  flushReact()
  expect_equal(length(built_minis), 1L)
  expect_equal(names(shiny::isolate(built_minis[[1]]())),
               c("id", "type", "text"))

  # Same-shape write through the mini-store: paragraph keeps
  # (id, type, text). No rebuild — the original mini-store handles
  # the in-place patch.
  built_minis[[1]](list(id = 1L, type = "paragraph", text = "hi"))
  flushReact()
  expect_equal(length(built_minis), 1L)

  # Shape-changing write through the *parent collection* (`items`):
  # todo adds `done`. The reconciler rebuilds.
  items(list(list(id = 1L, type = "todo", text = "hi", done = FALSE)))
  flushReact()
  expect_equal(length(built_minis), 2L)
  expect_equal(names(shiny::isolate(built_minis[[2]]())),
               c("id", "type", "text", "done"))

  # Direct write through the mini-store with an unknown key errors —
  # the mini-store enforces the same shape contract as reactiveStore.
  expect_error(
    built_minis[[2]](list(id = 1L, type = "todo", text = "hi",
                          done = FALSE, extra = "novel")),
    "Unknown keys"
  )
  m$handle$destroy()
})

test_that("Each rebuilds the entry when a positional slot's record shape changes", {
  # Heterogeneous records in positional mode: slot 1 goes from a 2-key
  # record to a 3-key record. The reconciler must detect the shape
  # change (keys differ) and rebuild that one slot.
  items <- shiny::reactiveVal(list(
    list(id = 1L, x = 1),
    list(id = 2L, x = 2)
  ))
  m <- mount_each(items, function(item) shiny::tags$span())
  flushReact()
  initial_msg_count <- length(m$session$msgs())

  items(list(
    list(id = 1L, x = 1, extra = "added"),
    list(id = 2L, x = 2)
  ))
  flushReact()

  msgs <- m$session$msgs()
  expect_gt(length(msgs), initial_msg_count)
  last <- msgs[[length(msgs)]]
  expect_equal(last$type, "irid-mutate")
  # Shape change in positional mode: remove + insert + order.
  expect_equal(length(last$message$removes), 1L)
  expect_equal(length(last$message$inserts), 1L)
  expect_equal(length(last$message$order), 2L)
  m$handle$destroy()
})

test_that("Each rebuilds the entry when a keyed item's shape changes", {
  items <- shiny::reactiveVal(list(
    list(id = "a", v = 1),
    list(id = "b", v = 2)
  ))
  m <- mount_each(
    items,
    function(item) shiny::tags$span(),
    by = function(x) x$id
  )
  flushReact()
  initial_msg_count <- length(m$session$msgs())

  # Same keys, but item "a" now has an extra field — different record
  # shape. The reconciler must tear it down and rebuild rather than
  # short-circuiting on identical keys.
  items(list(
    list(id = "a", v = 1, extra = "new-field"),
    list(id = "b", v = 2)
  ))
  flushReact()

  msgs <- m$session$msgs()
  expect_gt(length(msgs), initial_msg_count)
  last <- msgs[[length(msgs)]]
  expect_equal(last$type, "irid-mutate")
  expect_equal(length(last$message$removes), 1L)
  expect_equal(length(last$message$inserts), 1L)
  m$handle$destroy()
})

test_that("Each short-circuits same-keys + same-shape (no mutate emitted)", {
  # Regression check on the focus-preservation short-circuit.
  items <- shiny::reactiveVal(list(
    list(id = "a", v = 1),
    list(id = "b", v = 2)
  ))
  m <- mount_each(
    items,
    function(item) shiny::tags$span(),
    by = function(x) x$id
  )
  flushReact()
  initial_msg_count <- length(m$session$msgs())

  # In-place value edit, same keys, same shape — only the leaf
  # propagators do work; no DOM mutate.
  items(list(
    list(id = "a", v = 99),
    list(id = "b", v = 2)
  ))
  flushReact()
  expect_equal(length(m$session$msgs()), initial_msg_count)
  m$handle$destroy()
})

test_that("Each positional same-length + same-shape emits no mutate", {
  items <- shiny::reactiveVal(list("a", "b", "c"))
  m <- mount_each(items, function(item) shiny::tags$span())
  flushReact()
  initial_msg_count <- length(m$session$msgs())

  items(list("A", "B", "C"))
  flushReact()
  expect_equal(length(m$session$msgs()), initial_msg_count)
  m$handle$destroy()
})

test_that("validate_each_kinds rejects mixed records and scalars", {
  expect_error(
    irid:::validate_each_kinds(list("a", list(id = 1L, x = 2))),
    "all records.*or all scalars"
  )
  expect_error(
    irid:::validate_each_kinds(list(list(id = 1L), "footer")),
    "all records.*or all scalars"
  )
})

test_that("validate_each_kinds accepts all-records (any shapes)", {
  # Heterogeneous records — different leaf trees — are allowed.
  expect_silent(irid:::validate_each_kinds(list(
    list(id = 1L, type = "heading", text = "H"),
    list(id = 2L, type = "todo", text = "T", done = FALSE),
    list(id = 3L, type = "paragraph", text = "P")
  )))
})

test_that("validate_each_kinds accepts all-scalars and empty", {
  expect_silent(irid:::validate_each_kinds(list("a", "b", "c")))
  expect_silent(irid:::validate_each_kinds(list()))
  expect_silent(irid:::validate_each_kinds(list(1L, 2L, 3L)))
})

test_that("Each positional shape transition does not affect sibling slots", {
  # Heterogeneous *records*: slot 2 starts as a paragraph shape and
  # transitions to a todo shape (gains `done`). The Each reconciler
  # rebuilds only slot 2; siblings stay put.
  items <- shiny::reactiveVal(list(
    list(id = 1L, type = "heading",   text = "H"),
    list(id = 2L, type = "paragraph", text = "P"),
    list(id = 3L, type = "heading",   text = "H2")
  ))
  m <- mount_each(items, function(item) shiny::tags$span())
  flushReact()

  items(list(
    list(id = 1L, type = "heading",   text = "H"),
    list(id = 2L, type = "todo",      text = "P", done = FALSE),
    list(id = 3L, type = "heading",   text = "H2")
  ))
  flushReact()

  msgs <- m$session$msgs()
  last <- msgs[[length(msgs)]]
  expect_equal(length(last$message$removes), 1L)
  expect_equal(length(last$message$inserts), 1L)
  # Order array reflects the new arrangement of all 3 slots.
  expect_equal(length(last$message$order), 3L)
  m$handle$destroy()
})
