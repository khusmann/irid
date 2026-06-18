# End-to-end test for client-side event filtering: wire_dom_opts(filter = ...)
# drops events whose JS predicate is falsy *before* any server round-trip. The
# fixture (fixtures/event-filter.R) gates an onKeyDown handler to Enter; the
# server counter must only move on Enter, never on other keys. See helper-e2e.R.

# Dispatch a real keydown carrying a specific `key`, the field the filter reads.
e2e_keydown <- function(app, sel, key) {
  e2e_eval(app, sprintf(
    "(function(){var el=document.querySelector(%s);el.dispatchEvent(new KeyboardEvent('keydown',{key:%s,bubbles:true,cancelable:true}));return true;})()",
    to_js_str(sel), to_js_str(key)
  ))
}

test_that("non-Enter keydowns are filtered client-side; only Enter round-trips", {
  app <- e2e_app("event-filter.R")

  # Wait for irid to mount the readout + wire the keydown listener before
  # dispatching at it.
  e2e_wait_until(app, "document.querySelector('#ro-count') && document.querySelector('#ro-count').textContent.trim() === '0'")
  e2e_wait_idle(app)

  # Several non-Enter keys: the filter drops each in the browser, so the server
  # never sees them. Settle, then confirm the counter never moved.
  for (k in c("a", "b", "Shift", "Escape")) e2e_keydown(app, "#field", k)
  e2e_wait_idle(app)
  expect_equal(e2e_readout(app, "#ro-count"), "0")
  expect_equal(e2e_readout(app, "#ro-key"), "")

  # Enter passes the filter and round-trips: counter goes to exactly 1 (proving
  # the earlier keys were dropped, not queued) and the handler saw "Enter".
  e2e_keydown(app, "#field", "Enter")
  e2e_wait_until(app, "document.querySelector('#ro-count').textContent.trim() === '1'")
  expect_equal(e2e_readout(app, "#ro-key"), "Enter")

  # A second Enter advances again; an interleaved non-Enter still does not.
  e2e_keydown(app, "#field", "x")
  e2e_keydown(app, "#field", "Enter")
  e2e_wait_until(app, "document.querySelector('#ro-count').textContent.trim() === '2'")

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})
