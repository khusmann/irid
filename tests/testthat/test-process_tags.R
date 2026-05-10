# --- Auto-bind handler arity dispatch ----------------------------------------
#
# `make_autobind_handler` decides whether a callable bound to a state-binding
# prop (value/checked) gets a write handler (`function(e) fn(e[[attr_name]])`)
# or a no-op handler (`function(e) NULL`). The dispatch is arity-based and
# must work consistently across every callable shape irid accepts.

# Walk a single `<input value = X>` through process_tags and return the
# synthetic event entry's handler.
autobind_handler_for <- function(callable) {
  result <- process_tags(tags$input(value = callable))
  expect_length(result$events, 1L)
  expect_equal(result$events[[1]]$event, "input")
  result$events[[1]]$handler
}

# Pulls the underlying handler out of a single-source merged event entry.
# `merge_pending_events` always wraps even single handlers when they share
# a DOM event, but for the no-collision case it returns the original closure.
expect_writes <- function(handler, callable, value) {
  shiny::isolate(handler(list(value = value)))
}

test_that("reactiveVal (1 formal) gets a write handler", {
  rv <- shiny::reactiveVal("init")
  h <- autobind_handler_for(rv)
  expect_writes(h, rv, "typed")
  expect_equal(shiny::isolate(rv()), "typed")
})

test_that("reactive() (0 formals) gets a no-op handler", {
  rv <- shiny::reactiveVal("seed")
  r <- shiny::reactive(rv())
  h <- autobind_handler_for(r)
  # Calling with the DOM payload must not error and must not mutate
  # anything — the handler exists only to keep the listener live.
  expect_silent(h(list(value = "ignored")))
  expect_equal(shiny::isolate(rv()), "seed")
})

test_that("reactiveProxy(get, set) writes through `set`", {
  rv <- shiny::reactiveVal("a")
  p <- reactiveProxy(get = rv, set = function(v) rv(toupper(v)))
  h <- autobind_handler_for(p)
  shiny::isolate(h(list(value = "b")))
  expect_equal(shiny::isolate(rv()), "B")
})

test_that("reactiveProxy(get) (read-only) silently drops writes", {
  rv <- shiny::reactiveVal("x")
  p <- reactiveProxy(get = rv)
  h <- autobind_handler_for(p)
  expect_silent(shiny::isolate(h(list(value = "y"))))
  expect_equal(shiny::isolate(rv()), "x")
})

test_that("store leaf gets a write handler", {
  # Built directly because `length.reactiveLeaf` throws, which trips
  # htmltools' attribute-dropping pass. The arity-dispatch logic is what
  # we're pinning here, not the htmltools integration.
  state <- reactiveStore(list(name = "Alice"))
  h <- make_autobind_handler(state$name, "value")
  shiny::isolate(h(list(value = "Bob")))
  expect_equal(shiny::isolate(state$name()), "Bob")
})

test_that("0-arg lambda gets a no-op handler", {
  rv <- shiny::reactiveVal("seed")
  fn <- (\() rv())
  h <- autobind_handler_for(fn)
  expect_silent(h(list(value = "ignored")))
  expect_equal(shiny::isolate(rv()), "seed")
})

test_that("1-arg lambda gets a write handler", {
  captured <- NULL
  fn <- function(v) captured <<- v
  h <- autobind_handler_for(fn)
  h(list(value = "delivered"))
  expect_equal(captured, "delivered")
})

test_that("function(...) gets a write handler (dots accept the value)", {
  captured <- NULL
  fn <- function(...) captured <<- ..1
  h <- autobind_handler_for(fn)
  h(list(value = "via-dots"))
  expect_equal(captured, "via-dots")
})

test_that("primitive functions are treated as writable", {
  # `formals(sum)` is NULL, so the naive `length(formals(...)) >= 1` check
  # would mis-classify primitives as 0-arg no-ops. They do accept arguments,
  # so they must get a write handler. Binding `sum` to `value` is silly,
  # but the classification rule still has to be right.
  expect_true(can_accept_write(sum))
  expect_true(can_accept_write(`+`))
})

test_that("checked reads from e$checked, value reads from e$value", {
  # The synthetic handler reads the event field whose name matches the prop
  # — this is the DOM-IDL alignment the autobind table encodes.
  rv_checked <- shiny::reactiveVal(FALSE)
  res_checked <- process_tags(
    tags$input(type = "checkbox", checked = rv_checked)
  )
  expect_equal(res_checked$events[[1]]$event, "change")
  res_checked$events[[1]]$handler(list(checked = TRUE))
  expect_true(shiny::isolate(rv_checked()))

  rv_value <- shiny::reactiveVal("")
  res_value <- process_tags(tags$select(value = rv_value))
  expect_equal(res_value$events[[1]]$event, "input")
  res_value$events[[1]]$handler(list(value = "opt-2"))
  expect_equal(shiny::isolate(rv_value()), "opt-2")
})

# --- Misuse: irid construct passed as an attribute value ---------------------
#
# Any value with an `irid_*` class falls into the "irid construct" bucket
# and is meaningful only in specific positions (`.event` prop, child slot).
# As an attribute value it would silently fall through to `kept_attribs` and
# get serialized as raw HTML; process_tags must reject this loudly.

test_that("event_immediate() on an `on*` prop errors with migration hint", {
  expect_error(
    process_tags(tags$button(onClick = event_immediate())),
    "irid_event_config"
  )
  expect_error(
    process_tags(tags$button(onClick = event_immediate())),
    "\\.event"
  )
})

test_that("event_throttle() / event_debounce() on an `on*` prop also error", {
  expect_error(
    process_tags(tags$button(onClick = event_throttle(100))),
    "irid_event_config"
  )
  expect_error(
    process_tags(tags$input(onInput = event_debounce(200))),
    "irid_event_config"
  )
})

test_that("event_*() on a non-event attribute also errors", {
  # The check fires before the attribute name is interpreted, so it catches
  # the misuse anywhere — not just on `on*` props.
  expect_error(
    process_tags(tags$div(class = event_immediate())),
    "irid_event_config"
  )
})

test_that("control-flow nodes as attribute values error with a child-slot hint", {
  # Each / Index / When / Match are children, never attributes.
  expect_error(
    process_tags(tags$div(class = Each(\() 1:3, \(i) tags$span(i)))),
    "irid_each.*children"
  )
  expect_error(
    process_tags(tags$div(class = When(\() TRUE, "yes"))),
    "irid_when.*children"
  )
  expect_error(
    process_tags(tags$div(class = Match(Default("hi")))),
    "irid_match.*children"
  )
})

test_that("Output node as an attribute value errors", {
  expect_error(
    process_tags(tags$div(class = PlotOutput(\() plot(1)))),
    "irid_output.*children"
  )
})

test_that("error message mentions the offending attribute name", {
  expect_error(
    process_tags(tags$button(onClick = event_immediate())),
    "onClick"
  )
  expect_error(
    process_tags(tags$div(class = Each(\() 1:3, \(i) tags$span(i)))),
    "class"
  )
})

test_that("normalize_element_event(list()) errors with an emptiness hint", {
  # `htmltools::tag()` drops empty-list attribs before process_tags sees
  # them, so this branch is reachable only via a hand-built tag or a
  # direct call. Test via the helper so we still pin the message shape
  # for the defensive path.
  expect_error(normalize_element_event(list()), "empty")
})

test_that("`.event` with unnamed entries errors with a naming hint", {
  expect_error(
    process_tags(
      tags$input(
        value = shiny::reactiveVal(""),
        .event = list(event_debounce(100))
      )
    ),
    "fully named"
  )
})

test_that("event_*() is still valid as the `.event` element prop", {
  # `.event` is stripped before the per-attribute loop, so a config there
  # must NOT trigger the misuse error.
  expect_silent(
    process_tags(
      tags$button(
        "Save",
        onClick = function() NULL,
        .event = event_throttle(500)
      )
    )
  )
})

test_that("control-flow nodes are still valid as children", {
  # The misuse guard fires only inside the per-attribute loop. Children get
  # walked separately and continue to produce control_flow entries normally.
  result <- process_tags(
    tags$div(Each(\() 1:3, \(i) tags$span(i)))
  )
  expect_length(result$control_flows, 1L)
  expect_equal(result$control_flows[[1]]$type, "each")
})
