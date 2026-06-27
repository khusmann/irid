# Locks the `nonce` deletion (protocol step 5 / spike finding 8). irid sends every
# client->server payload with `{priority: "event"}`, which bypasses Shiny's
# no-resend dedup (`InputNoResendDecorator`, guarded by `opts.priority !==
# "event"`), so two consecutive identical-intent events both reach the server
# observer. The Math.random() `nonce` that used to force value-distinctness is
# gone; the envelope's per-channel `seq` keeps sends distinct as well. This is the
# durable replacement for the throwaway spike's source-read of finding 8 — it
# fails loudly if a future Shiny ever makes event-priority inputs dedup.
#
# See fixtures/event-dedup.R and helper-e2e.R.

test_that("two back-to-back clicks both reach the server observer", {
  app <- e2e_app("event-dedup.R")

  e2e_wait_until(app, "!!document.querySelector('#ro-count')")
  e2e_wait_idle(app)

  # Fire two clicks synchronously, in one tick, before the server responds — two
  # back-to-back event-priority sends on the same channel.
  e2e_eval(app, "(function(){var b=document.querySelector('#bump');b.click();b.click();return true;})()")
  e2e_wait_until(app, "document.querySelector('#ro-count').textContent.trim() === '2'")

  expect_equal(e2e_readout(app, "#ro-count"), "2")
  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})
