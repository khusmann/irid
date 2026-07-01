# End-to-end tests for the async-factory widget contract (#26). Uses the
# synthetic `testw` widget (fixtures/widget-async.R) whose factory blocks on
# `window.__testGo`, making the construction window observable. See the Widgets
# section of ARCHITECTURE.md (async-factory contract) and helper-e2e.R.

tw  <- function(app) e2e_eval(app, "window.__tw || null")
tws <- function(app) e2e_eval(app, "window.__tws || null")
go  <- function(app) e2e_eval(app, "window.__testGo = true")

test_that("a synchronous factory commits immediately (the commit(result) branch)", {
  app <- e2e_app("widget-async.R")

  # No gate, no __testGo — a sync factory commits synchronously on mount.
  e2e_wait_until(app, "window.__tws && window.__tws.inited")
  # The widget can commit before irid finishes wiring the PAGE's DOM listeners
  # (#btn-change); a click dispatched in that cold-boot window is lost. Wait for
  # irid to settle so the button is bound before clicking it.
  e2e_wait_idle(app)
  expect_equal(tws(app)$initialLabel, "A")  # seeded from init props

  # Updates flow normally through the committed handle. (The binding observer's
  # initial run echoes the seed "A" as the first update — uncoalesced because a
  # sync factory has no buffer window — so assert the *change* lands, not [[1]].)
  e2e_click(app, "#btn-change")
  e2e_wait_until(
    app,
    "window.__tws.updates.length && window.__tws.updates[window.__tws.updates.length - 1].label === 'B'"
  )
  ups <- tws(app)$updates
  expect_equal(ups[[length(ups)]]$label, "B")
  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("updates during async construction are buffered, then flushed in order", {
  app <- e2e_app("widget-async.R")

  # Factory has started but is parked on the gate — not yet inited.
  e2e_wait_until(app, "window.__tw && window.__tw.started")
  expect_false(tw(app)$inited)

  # Change a bound prop while the factory is still awaiting. The substrate must
  # BUFFER this widget attr op (handle is null), not drop it or error.
  e2e_click(app, "#btn-change")
  e2e_wait_idle(app)
  expect_false(tw(app)$inited)              # still parked
  expect_equal(length(tw(app)$updates), 0)  # nothing delivered yet
  expect_equal(e2e_exceptions(app), character())

  # Release the gate -> factory commits -> buffered update flushes.
  go(app)
  e2e_wait_until(app, "window.__tw.inited")
  res <- tw(app)
  expect_equal(res$initialLabel, "A")       # seeded from init props
  expect_equal(length(res$updates), 1)      # the buffered change, delivered once
  expect_equal(res$updates[[1]]$label, "B")
  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("teardown during async construction disposes the resolved handle", {
  app <- e2e_app("widget-async.R")

  e2e_wait_until(app, "window.__tw && window.__tw.started")
  expect_false(tw(app)$inited)

  # Tear the widget down (flip the When gate) WHILE the factory is still
  # awaiting. The entry is flagged destroyed; handle doesn't exist yet.
  e2e_click(app, "#btn-hide")
  e2e_wait_until(app, "!!document.getElementById('tw-hidden')")

  # Now let the factory finish. Its handle must be DISPOSED on commit (destroy
  # runs), not adopted as a detached zombie.
  go(app)
  e2e_wait_until(app, "window.__tw.destroyed")
  expect_true(tw(app)$destroyed)
  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})
