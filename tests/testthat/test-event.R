# --- Timing shapes -----------------------------------------------------------

test_that("timing shapes carry only their mode-specific fields", {
  expect_s3_class(wire_immediate(), "irid_wire_timing")
  expect_equal(wire_immediate()$mode, "immediate")
  expect_null(wire_immediate()$coalesce)

  d <- wire_debounce(200)
  expect_equal(d$mode, "debounce")
  expect_equal(d$ms, 200)
  expect_null(d$coalesce)

  t <- wire_throttle(100, leading = FALSE)
  expect_equal(t$mode, "throttle")
  expect_equal(t$ms, 100)
  expect_false(t$leading)
})

test_that("timing constructors validate their args", {
  expect_error(wire_debounce("x"), "`ms` must be a numeric scalar")
  expect_error(wire_throttle(NA), "`ms` must be a numeric scalar")
  expect_error(wire_throttle(100, leading = NA), "`leading` must be")
})

# --- wire_dom_opts -----------------------------------------------------------

test_that("wire_dom_opts defaults all flags to FALSE", {
  o <- wire_dom_opts()
  expect_s3_class(o, "irid_dom_opts")
  expect_false(o$prevent_default)
  expect_false(o$stop_propagation)
  expect_false(o$capture)
  expect_false(o$passive)
})

test_that("wire_dom_opts validates flags are logical scalars", {
  expect_error(wire_dom_opts(prevent_default = 1), "`prevent_default` must be")
  expect_error(wire_dom_opts(capture = NA), "`capture` must be")
  expect_error(wire_dom_opts(passive = c(TRUE, FALSE)), "`passive` must be")
})

# --- wire ---------------------------------------------------------------

test_that("wire holds subject + config", {
  h <- function() NULL
  w <- wire(h, wire_debounce(200), coalesce = FALSE,
                 dom_opts = wire_dom_opts(prevent_default = TRUE))
  expect_s3_class(w, "irid_wire")
  expect_identical(w$subject, h)
  expect_equal(w$timing$mode, "debounce")
  expect_false(w$coalesce)
  expect_true(w$dom_opts$prevent_default)
})

test_that("wire validates each field", {
  expect_error(wire(subject = 5), "`subject` must be a function")
  expect_error(wire(timing = wire_dom_opts()), "`timing` must be an `irid_wire_timing`")
  expect_error(wire(coalesce = "yes"), "`coalesce` must be")
  expect_error(wire(dom_opts = wire_immediate()), "`dom_opts` must be an `irid_dom_opts`")
})

# --- merge.irid_wire ---------------------------------------------------------

test_that("merge overlays override fields, keeping defaults otherwise", {
  default <- wire(timing = wire_debounce(200))
  rv <- shiny::reactiveVal("x")
  out <- merge(default, rv)
  expect_identical(out$subject, rv)            # override fills subject
  expect_equal(out$timing$mode, "debounce")    # default timing carries through
})

test_that("merge(default, NULL) is identity", {
  default <- wire(timing = wire_throttle(100))
  out <- merge(default, NULL)
  expect_equal(out$timing$mode, "throttle")
  expect_null(out$subject)
})

test_that("merge(default, bare function) fills only the subject", {
  default <- wire(timing = wire_throttle(100), coalesce = TRUE)
  h <- function() NULL
  out <- merge(default, h)
  expect_identical(out$subject, h)
  expect_equal(out$timing$mode, "throttle")
  expect_true(out$coalesce)
})

test_that("merge override timing wins over default", {
  default <- wire(timing = wire_debounce(200))
  override <- wire(function() NULL, wire_immediate())
  out <- merge(default, override)
  expect_equal(out$timing$mode, "immediate")
})

test_that("merge dispatches through the base generic", {
  # Registered as merge.irid_wire on base::merge — calling merge() on an
  # wire must route here, not to merge.default.
  out <- merge(wire(timing = wire_debounce(200)), function() NULL)
  expect_s3_class(out, "irid_wire")
})
