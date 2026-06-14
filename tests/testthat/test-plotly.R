# Unit tests for the PlotlyOutput R surface (R/plotly.R). These pin the exact
# R-side boundary logic that the e2e suite only exercises through the full
# browser round-trip — coercion of wire-decoded values, the per-name lazy-capture
# guard, state-arg validation, and the identity-key spec validation. They are
# fast and always run (no browser, no skip).

# --- coerce_plotly_value: the wire-decode boundary --------------------------

test_that("coerce_plotly_value normalizes each field to its R shape", {
  # Ranges arrive as R *lists* under Shiny's simplifyVector = FALSE.
  expect_identical(coerce_plotly_value("xaxis_range", list(40, 200)), c(40, 200))
  expect_identical(coerce_plotly_value("yaxis2_range", list(1.5, 9)), c(1.5, 9))

  # selected_ids -> character vector.
  expect_identical(
    coerce_plotly_value("selected_ids", list("Mazda", "Ferrari Dino")),
    c("Mazda", "Ferrari Dino")
  )

  # trace_visibility -> named character map (names preserved).
  expect_identical(
    coerce_plotly_value("trace_visibility", list(`8` = "legendonly")),
    c(`8` = "legendonly")
  )

  # Scalars pass through untouched.
  expect_identical(coerce_plotly_value("dragmode", "pan"), "pan")
})

test_that("coerce_plotly_value maps the null->NA clear back to NULL", {
  # A setProp(key, null) arrives as a scalar NA (mount maps JS null -> NA); every
  # real value is a length>=2 vector, so a scalar NA unambiguously means "clear".
  expect_null(coerce_plotly_value("yaxis_range", NA))
  expect_null(coerce_plotly_value("selected_ids", NA))
  expect_null(coerce_plotly_value("dragmode", NULL))
})

# --- coerce_state_prop: per-name coercion + the lazy-capture guard ----------

test_that("coerce_state_prop coerces only the write path; reads pass through", {
  rv <- local({ store <- NULL; function(v) if (missing(v)) store else store <<- v })
  p <- coerce_state_prop("xaxis_range", rv)
  p(list(40, 200))                      # write: coerced list -> numeric
  expect_identical(rv(), c(40, 200))    # read: the user's canonical value
  expect_identical(p(), c(40, 200))
})

test_that("coerce_state_prop forces name/callable per call (no loop-variable bleed)", {
  # The §1 lazy-capture bug: without force(), every proxy built in a construction
  # loop would resolve `name`/`callable` to the loop's FINAL values, so each
  # write would coerce under the wrong field. Build two in a loop and assert each
  # lands under its own name's coercion.
  results <- new.env()
  proxies <- list()
  for (nm in c("xaxis_range", "selected_ids")) {
    target <- local({
      key <- nm
      function(v) if (!missing(v)) assign(key, v, envir = results)
    })
    proxies[[nm]] <- coerce_state_prop(nm, target)
  }
  proxies[["xaxis_range"]](list(40, 200))
  proxies[["selected_ids"]](list("a", "b"))
  expect_identical(results$xaxis_range, c(40, 200))   # numeric, not c("40","200")
  expect_identical(results$selected_ids, c("a", "b"))
})

test_that("coerce_state_prop returns constants (incl. NULL) untouched", {
  expect_identical(coerce_state_prop("dragmode", "pan"), "pan")
  expect_null(coerce_state_prop("xaxis_range", NULL))
})

# --- prepare_state_props: timing defaults + passthrough ---------------------

test_that("prepare_state_props throttles relayout-sourced props, not selection", {
  rng <- prepare_state_props(list(xaxis_range = function() NULL))$xaxis_range
  expect_s3_class(rng, "irid_wire")
  expect_equal(rng$timing$mode, "throttle")

  drag <- prepare_state_props(list(dragmode = function() NULL))$dragmode
  expect_equal(drag$timing$mode, "throttle")

  # selection / visibility stay immediate (no default timing applied).
  sel <- prepare_state_props(list(selected_ids = function() NULL))$selected_ids
  expect_s3_class(sel, "irid_wire")
  expect_null(sel$timing)
})

test_that("prepare_state_props passes constants through and honors a caller wire", {
  out <- prepare_state_props(list(dragmode = "pan"))
  expect_identical(out$dragmode, "pan")

  # A caller-supplied wire's timing wins over the default throttle.
  w <- wire(subject = function() NULL, timing = wire_debounce(500))
  out <- prepare_state_props(list(xaxis_range = w))
  expect_equal(out$xaxis_range$timing$mode, "debounce")
})

# --- state-arg name validation ----------------------------------------------

test_that("plotly_state_arg_ok recognizes the table incl. subplot axes", {
  expect_true(plotly_state_arg_ok("xaxis_range"))
  expect_true(plotly_state_arg_ok("yaxis_range"))
  expect_true(plotly_state_arg_ok("xaxis2_range"))
  expect_true(plotly_state_arg_ok("yaxis10_range"))
  expect_true(plotly_state_arg_ok("dragmode"))
  expect_true(plotly_state_arg_ok("hovermode"))
  expect_true(plotly_state_arg_ok("selected_ids"))
  expect_true(plotly_state_arg_ok("trace_visibility"))

  expect_false(plotly_state_arg_ok("zaxis_range"))
  expect_false(plotly_state_arg_ok("xaxis_domain"))
  expect_false(plotly_state_arg_ok("selected_points"))   # old name, removed
})

test_that("validate_plotly_state_args rejects unnamed and unknown args", {
  expect_silent(validate_plotly_state_args(list()))
  expect_silent(validate_plotly_state_args(
    list(xaxis_range = 1, dragmode = "pan")
  ))
  expect_error(
    validate_plotly_state_args(list(1)),
    "must be named"
  )
  expect_error(
    validate_plotly_state_args(list(nonsense = 1)),
    "Unknown named state argument"
  )
})

# --- identity-key spec validation -------------------------------------------

test_that("validate_plotly_ids errors without ids, warns on duplicates", {
  skip_if_not_installed("plotly")
  expect_error(
    validate_plotly_ids(list(list(x = 1:3, y = 1:3))),
    "ids"
  )
  expect_silent(validate_plotly_ids(list(list(ids = c("a", "b")))))
  expect_warning(
    validate_plotly_ids(list(list(ids = c("a", "a")))),
    "not unique"
  )
})

test_that("validate_plotly_trace_names errors when unnamed, warns on duplicates", {
  skip_if_not_installed("plotly")
  expect_error(
    validate_plotly_trace_names(list(list(x = 1:3), list(x = 4:6))),
    "unnamed"
  )
  expect_silent(validate_plotly_trace_names(list(list(name = "a"), list(name = "b"))))
  expect_warning(
    validate_plotly_trace_names(list(list(name = "a"), list(name = "a"))),
    "not unique"
  )
})

# --- to_plotly_spec: serialization + key gating -----------------------------

test_that("to_plotly_spec returns a JSON string and enforces key requirements", {
  skip_if_not_installed("plotly")
  p <- plotly::plot_ly(
    data.frame(x = 1:3, y = 1:3, k = letters[1:3]),
    x = ~x, y = ~y, ids = ~k, name = "t", type = "scatter", mode = "markers"
  )
  json <- to_plotly_spec(p)
  expect_type(json, "character")
  expect_length(json, 1L)
  expect_match(json, "\"data\"")

  # require_ids passes with ids present; require_names passes with a name.
  expect_type(to_plotly_spec(p, require_ids = TRUE, require_names = TRUE), "character")

  # A plot without ids fails the require_ids gate.
  q <- plotly::plot_ly(
    data.frame(x = 1:3, y = 1:3), x = ~x, y = ~y, type = "scatter", mode = "markers"
  )
  expect_error(to_plotly_spec(q, require_ids = TRUE), "ids")
})

# --- constructor argument validation ----------------------------------------

test_that("PlotlyOutput rejects a non-function spec and unknown state args", {
  skip_if_not_installed("plotly")
  expect_error(PlotlyOutput(spec = "not a function"), "spec")
  expect_error(
    PlotlyOutput(spec = function() NULL, bogus_range = function() NULL),
    "Unknown named state argument"
  )
})
