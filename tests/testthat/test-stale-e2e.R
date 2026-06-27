# End-to-end tests for the stale UI indicator (stale.ts) — a DOM-bound module
# with no vitest net. Asserts: the `irid-stale` class appears on <html> once the
# server stays busy past the timeout and clears once it settles (staying up for
# the whole busy window, no flicker), and a handler faster than the timeout
# never shows it (the show timer is reset on idle first). Fixture: stale.R.
#
#   IRID_E2E=1 Rscript -e 'devtools::test(filter = "stale-e2e")'

HAS_STALE <- "document.documentElement.classList.contains('irid-stale')"

# Record every CHANGE of the irid-stale class on <html> into window.__staleLog
# (1 = added, 0 = removed). Installed before the action so the full transition
# history is observable — a flicker would show up as extra entries.
install_stale_log <- function(app) {
  e2e_eval(app, paste0(
    "window.__staleLog=[];",
    "(function(){var last=", HAS_STALE, ";",
    "new MutationObserver(function(){var now=", HAS_STALE, ";",
    "if(now!==last){last=now;window.__staleLog.push(now?1:0);}})",
    ".observe(document.documentElement,{attributes:true,attributeFilter:['class']});})();",
    "true"
  ))
}

test_that("indicator shows while busy past the timeout, then clears (no flicker)", {
  app <- e2e_app("stale.R")
  e2e_wait_until(app, "!!document.getElementById('btn-slow')")
  e2e_wait_idle(app)
  expect_false(e2e_eval(app, HAS_STALE))

  install_stale_log(app)
  e2e_click(app, "#btn-slow")

  # Appears once busy passes the 400ms timeout, while the 700ms handler runs.
  e2e_wait_until(app, HAS_STALE)
  # Server finishes (round-trip landed) and the bar clears after the idle debounce.
  e2e_wait_until(app, "document.getElementById('ro-slow').textContent.trim() === '1'")
  e2e_wait_until(app, paste0("!", HAS_STALE))

  # Exactly one add then one remove — it never toggled off mid-busy and back on.
  expect_equal(as.integer(unlist(e2e_eval(app, "window.__staleLog"))), c(1L, 0L))
  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("a handler faster than the timeout never shows the indicator", {
  app <- e2e_app("stale.R")
  e2e_wait_until(app, "!!document.getElementById('btn-fast')")
  e2e_wait_idle(app)

  install_stale_log(app)
  e2e_click(app, "#btn-fast")

  # The 30ms handler settles well before the 400ms show timer; idle resets it.
  e2e_wait_until(app, "document.getElementById('ro-fast').textContent.trim() === '1'")
  e2e_wait_idle(app)
  expect_false(e2e_eval(app, HAS_STALE))
  expect_equal(length(e2e_eval(app, "window.__staleLog")), 0L)

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})
