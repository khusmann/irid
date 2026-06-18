# End-to-end test for the per-element event-ordering queue. An immediate
# onKeyDown (Enter) fired right after typing must not overtake the still-
# debouncing value binding: the queue flushes the pending input first, so the
# server's add() observes the typed value rather than a stale/empty one. The
# fixture (fixtures/event-order.R) appends the bound value on Enter. See
# helper-e2e.R.

# Atomically set the value, fire the debounced `input`, then immediately fire
# `keydown` Enter — synchronously, well inside the 200ms debounce window. This
# is the race: without ordering, the immediate keydown sends before the input.
e2e_type_then_enter <- function(app, sel, value) {
  e2e_eval(app, sprintf(
    "(function(){var el=document.querySelector(%s);el.value=%s;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));return true;})()",
    to_js_str(sel), to_js_str(as.character(value))
  ))
}

test_that("Enter right after typing appends the typed value, not a stale one", {
  app <- e2e_app("event-order.R")

  e2e_wait_until(app, "!!document.querySelector('#ro-added')")
  e2e_wait_idle(app)

  e2e_type_then_enter(app, "#field", "milk")
  e2e_wait_until(app, "document.querySelector('#ro-added').textContent.trim() === 'milk'")

  # A second round confirms the queue keeps working across sends.
  e2e_type_then_enter(app, "#field", "eggs")
  e2e_wait_until(app, "document.querySelector('#ro-added').textContent.trim() === 'milk|eggs'")

  expect_equal(e2e_readout(app, "#ro-added"), "milk|eggs")
  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})
