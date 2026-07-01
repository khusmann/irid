# End-to-end tests for the Each / irid-mutate granular-DOM protocol — the
# client-side anchors + handlers surface that has no vitest net (DOM-bound).
# Covers inserts, removes, keyed reorder (element identity preserved), in-place
# value updates that do NOT remount, a restricted-content parent (<ul>), and the
# positional (by = NULL) grow/shrink path. Fixture: fixtures/each.R. See
# helper-e2e.R and TESTING.md for gating + conventions.
#
#   IRID_E2E=1 Rscript -e 'devtools::test(filter = "each-e2e")'

# data-id attributes of #klist's <li>, in DOM order. Proves the <li> are real
# element children of the <ul> (not hoisted out of a wrapper) and tracks order.
klist_ids <- function(app) {
  as.character(e2e_eval(app, paste0(
    "Array.prototype.map.call(",
    "document.querySelectorAll('#klist > li'),",
    "function(li){return li.getAttribute('data-id');})"
  )))
}

# data-id attributes of #olist's <li> (the renderIrid-delivered Each).
olist_ids <- function(app) {
  as.character(e2e_eval(app, paste0(
    "Array.prototype.map.call(",
    "document.querySelectorAll('#olist > li'),",
    "function(li){return li.getAttribute('data-id');})"
  )))
}

# text of #plist's <li>, in DOM order (positional scalar Each).
plist_texts <- function(app) {
  as.character(e2e_eval(app, paste0(
    "Array.prototype.map.call(",
    "document.querySelectorAll('#plist > li'),",
    "function(li){return li.textContent.trim();})"
  )))
}

test_that("keyed Each inserts and removes items in a restricted parent", {
  app <- e2e_app("each.R")
  e2e_wait_until(app, "document.querySelectorAll('#klist > li').length === 3")
  e2e_wait_idle(app)

  # parseFragment used the <ul> context — the <li> are direct element children.
  expect_equal(klist_ids(app), c("a", "b", "c"))

  # Insert: append a new item at the end (irid-mutate `inserts`).
  e2e_click(app, "#btn-append")
  e2e_wait_until(app, "document.querySelectorAll('#klist > li').length === 4")
  expect_equal(klist_ids(app), c("a", "b", "c", "d"))

  # Remove from the middle (irid-mutate `removes` — detachRange + dereg).
  e2e_click(app, "#btn-remove")
  e2e_wait_until(app, "document.querySelectorAll('#klist > li').length === 3")
  expect_equal(klist_ids(app), c("a", "c", "d"))

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("keyed reorder moves ranges, preserving element identity", {
  app <- e2e_app("each.R")
  e2e_wait_until(app, "document.querySelectorAll('#klist > li').length === 3")
  e2e_wait_idle(app)

  # Get to order a,c,d (append d, then remove b) so reverse is unambiguous.
  # Wait for each op to land — `length===3` alone is also the initial state.
  e2e_click(app, "#btn-append")
  e2e_wait_until(app, "document.querySelectorAll('#klist > li').length === 4")
  e2e_click(app, "#btn-remove")
  e2e_wait_until(app, "!document.querySelector('#klist > li[data-id=b]')")
  expect_equal(klist_ids(app), c("a", "c", "d"))

  # Stamp a JS marker on the middle <li>; a reorder must MOVE that element (the
  # irid-mutate `order` path lifts the range), not rebuild it.
  e2e_eval(app, "document.querySelector('#klist > li[data-id=c]').__mark = 'M'")
  e2e_click(app, "#btn-reverse")
  e2e_wait_until(app, "document.querySelector('#klist > li').getAttribute('data-id') === 'd'")
  expect_equal(klist_ids(app), c("d", "c", "a"))
  # Same DOM element survived the move — identity (and its marker) preserved.
  expect_true(e2e_eval(app, "document.querySelector('#klist > li[data-id=c]').__mark === 'M'"))

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("an in-place value change updates text without remounting the item", {
  app <- e2e_app("each.R")
  e2e_wait_until(app, "document.querySelectorAll('#klist > li').length === 3")
  e2e_wait_idle(app)

  # Stamp the 'a' <li>; renaming it must update only its inner text (a `text`
  # op), reusing the same element — no remove/insert, marker survives.
  e2e_eval(app, "document.querySelector('#klist > li[data-id=a]').__keep = 'K'")
  e2e_click(app, "#btn-rename")
  e2e_wait_until(app, "document.querySelector('#klist > li[data-id=a]').textContent.indexOf('Alpha2') !== -1")

  expect_equal(klist_ids(app), c("a", "b", "c"))  # structure unchanged
  expect_true(e2e_eval(app, "document.querySelector('#klist > li[data-id=a]').__keep === 'K'"))

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("Each delivered via renderIrid mutates (lookupAnchors lazy re-scan)", {
  app <- e2e_app("each-output.R")
  # The output renders its initial item; its anchors are NOT in the load-time
  # index (they arrived as an output binding, not a custom message).
  e2e_wait_until(app, "document.querySelectorAll('#olist > li').length === 1")
  e2e_wait_idle(app)
  expect_equal(olist_ids(app), c("x"))

  # First add -> first irid-mutate -> lookupAnchors MISSES the container anchor
  # -> must lazily re-scan document.body to find it, or the insert is dropped.
  e2e_click(app, "#btn-add")
  e2e_wait_until(app, "document.querySelectorAll('#olist > li').length === 2")
  expect_equal(olist_ids(app), c("x", "n1"))

  # A second add proves the re-indexed anchor stays usable.
  e2e_click(app, "#btn-add")
  e2e_wait_until(app, "document.querySelectorAll('#olist > li').length === 3")
  expect_equal(olist_ids(app), c("x", "n1", "n2"))

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})

test_that("positional Each grows and shrinks (by = NULL inserts/removes)", {
  app <- e2e_app("each.R")
  e2e_wait_until(app, "document.querySelectorAll('#plist > li').length === 2")
  e2e_wait_idle(app)
  expect_equal(plist_texts(app), c("one", "two"))

  e2e_click(app, "#btn-grow")
  e2e_wait_until(app, "document.querySelectorAll('#plist > li').length === 3")
  expect_equal(plist_texts(app), c("one", "two", "three"))

  e2e_click(app, "#btn-shrink")
  e2e_wait_until(app, "document.querySelectorAll('#plist > li').length === 1")
  expect_equal(plist_texts(app), c("one"))

  expect_equal(e2e_exceptions(app), character())
  e2e_expect_no_error(app)
})
