# End-to-end tests for the controlled-input optimistic-update gate and reactive
# DOM writes in handlers.ts (`attr` target=dom / `text` ops) — the browser-side
# behavior the core/seq vitest suite cannot reach. Fixture: controlled.R.
#
#   IRID_E2E=1 Rscript -e 'devtools::test(filter = "controlled-input-e2e")'

# Focus an input, set the value, and fire its (debounced) input event.
focus_type <- function(app, sel, value) {
  e2e_eval(app, sprintf(
    "(function(){var e=document.querySelector(%s);e.focus();e.value=%s;e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()",
    to_js_str(sel), to_js_str(as.character(value))
  ))
}

test_that("a server transform applies to a focused input; the text child follows", {
  app <- e2e_app("controlled.R")
  e2e_wait_until(app, "!!document.getElementById('trunc')")
  e2e_wait_idle(app)

  # Type 12 chars while focused; the server caps at 10 and echoes the truncated
  # value, which must apply over the focused input (server is the authority).
  focus_type(app, "#trunc", "abcdefghijkl")
  e2e_wait_until(app, "document.getElementById('trunc').value === 'abcdefghij'")
  expect_equal(e2e_eval(app, "document.getElementById('trunc').value"), "abcdefghij")
  # The reactive text child (target=text) reflects the server value.
  e2e_wait_until(app, "document.getElementById('ro-text').textContent === 'abcdefghij'")

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("a programmatic write from another element applies while focused", {
  app <- e2e_app("controlled.R")
  e2e_wait_until(app, "!!document.getElementById('trunc')")
  e2e_wait_idle(app)

  # Wait on the SERVER readout (not the client value) so the debounced input has
  # actually landed before we clear — otherwise it races the clear and re-sets it.
  focus_type(app, "#trunc", "abcdefghij")
  e2e_wait_until(app, "document.getElementById('ro-text').textContent === 'abcdefghij'")

  # Keep #trunc focused; a button clears text(). The echo is keyed to the
  # BUTTON, so #trunc's binding finds no sequence entry -> programmatic -> the
  # focused input still empties.
  e2e_eval(app, "document.getElementById('trunc').focus(); true")
  e2e_click(app, "#btn-clear")
  e2e_wait_until(app, "document.getElementById('trunc').value === '' && document.getElementById('plain').value === ''")
  e2e_wait_until(app, "document.getElementById('ro-text').textContent === ''")

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("a same-value echo to a focused input is skipped (cursor preserved)", {
  app <- e2e_app("controlled.R")
  e2e_wait_until(app, "!!document.getElementById('plain')")
  e2e_wait_idle(app)

  e2e_set_input(app, "#plain", "hello")
  e2e_wait_until(app, "document.getElementById('ro-text').textContent === 'hello'")

  # Focus, put the cursor mid-string, then re-fire input WITHOUT changing the
  # value. The server's no-op write force-sends the same value back; the client
  # must skip applying it — applying would reset the cursor to the end (5).
  e2e_eval(app, "(function(){var e=document.querySelector('#plain');e.focus();e.setSelectionRange(2,2);e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
  e2e_wait_idle(app)
  expect_equal(e2e_eval(app, "document.querySelector('#plain').value"), "hello")
  expect_equal(e2e_eval(app, "document.querySelector('#plain').selectionStart"), 2)

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("a reactive DOM attribute is set on a value and removed on FALSE", {
  app <- e2e_app("controlled.R")
  e2e_wait_until(app, "!!document.getElementById('box')")
  e2e_wait_idle(app)
  # FALSE initial value -> attribute absent (removeAttribute branch).
  expect_false(e2e_eval(app, "document.getElementById('box').hasAttribute('data-active')"))

  e2e_click(app, "#btn-toggle")  # TRUE -> setAttribute('data-active', 'yes')
  e2e_wait_until(app, "document.getElementById('box').getAttribute('data-active') === 'yes'")

  e2e_click(app, "#btn-toggle")  # FALSE -> removeAttribute('data-active')
  e2e_wait_until(app, "!document.getElementById('box').hasAttribute('data-active')")

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})
