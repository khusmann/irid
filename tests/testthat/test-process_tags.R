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

# Invoke an autobind handler with a synthetic DOM-event payload. Just a
# call — the surrounding test asserts the resulting state.
invoke_write <- function(handler, value) {
  shiny::isolate(handler(list(value = value)))
}

test_that("reactiveVal (1 formal) gets a write handler", {
  rv <- shiny::reactiveVal("init")
  h <- autobind_handler_for(rv)
  invoke_write(h, "typed")
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

test_that("store leaf gets a write handler (end-to-end through process_tags)", {
  state <- reactiveStore(list(name = "Alice"))
  h <- autobind_handler_for(state$name)
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
  expect_equal(res_value$events[[1]]$event, "change")
  res_value$events[[1]]$handler(list(value = "opt-2"))
  expect_equal(shiny::isolate(rv_value()), "opt-2")
})

test_that("autobind handler is tagged with irid_write_targets = attr_name", {
  # Drives the per-binding force-send: when this autobind handler fires,
  # only the matching binding gets force-sent (not every binding on the
  # element). Both writable and read-only autobind handlers declare the
  # target — read-only needs it for the snap-back path.
  rv <- shiny::reactiveVal("init")
  res <- process_tags(tags$input(value = rv))
  expect_equal(attr(res$events[[1]]$handler, "irid_write_targets"), "value")
  expect_equal(res$events[[1]]$write_targets, "value")

  ro <- shiny::reactive(rv())
  res_ro <- process_tags(tags$input(value = ro))
  expect_equal(attr(res_ro$events[[1]]$handler, "irid_write_targets"), "value")
  expect_equal(res_ro$events[[1]]$write_targets, "value")
})

test_that("autobind handler reads correct key when prop is not last", {
  # Regression: `make_autobind_handler` used to capture `attr_name` lazily,
  # so the closure resolved it via the for-loop's final `name` binding —
  # any non-reactive attribute after `value`/`checked` would silently
  # redirect the read to the wrong event field.
  rv_value <- shiny::reactiveVal("init")
  res_value <- process_tags(
    tags$input(value = rv_value, class = "form-control")
  )
  res_value$events[[1]]$handler(list(value = "typed", class = "irrelevant"))
  expect_equal(shiny::isolate(rv_value()), "typed")

  rv_checked <- shiny::reactiveVal(FALSE)
  res_checked <- process_tags(
    tags$input(type = "checkbox", checked = rv_checked, class = "x")
  )
  res_checked$events[[1]]$handler(list(checked = TRUE, class = "irrelevant"))
  expect_true(shiny::isolate(rv_checked()))
})

# --- One channel per event (events.md §4) ------------------------------------
#
# A given DOM event is driven by a value binding OR an explicit `on*` handler,
# never both. The check is per-event, not per-element — a binding and an
# explicit handler on *different* events coexist freely. A single explicit
# handler per event (no composition).

test_that("value + onInput on the same element errors (one channel)", {
  rv <- shiny::reactiveVal("")
  expect_error(
    process_tags(tags$input(value = rv, onInput = function(e) NULL)),
    "bound \\*or\\* handled"
  )
})

test_that("checked + onChange on a checkbox errors (one channel)", {
  rv <- shiny::reactiveVal(FALSE)
  expect_error(
    process_tags(
      tags$input(type = "checkbox", checked = rv, onChange = function(e) NULL)
    ),
    "bound \\*or\\* handled"
  )
})

test_that("value + onChange on a <select> errors (autobinds on change)", {
  rv <- shiny::reactiveVal("")
  expect_error(
    process_tags(tags$select(value = rv, onChange = function(e) NULL)),
    "bound \\*or\\* handled"
  )
})

test_that("value + onClick coexist (different events, two entries)", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, onClick = function() NULL)
  )
  expect_length(result$events, 2L)
  events <- vapply(result$events, function(e) e$event, character(1L))
  expect_setequal(events, c("input", "click"))
})

test_that("value + onKeyDown coexist (binding + unrelated event)", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, onKeyDown = function(e) NULL)
  )
  expect_length(result$events, 2L)
  events <- vapply(result$events, function(e) e$event, character(1L))
  expect_setequal(events, c("input", "keydown"))
  expect_length(result$bindings, 1L)
})

test_that("duplicate explicit handlers on one event error", {
  h1 <- function(e) NULL
  h2 <- function(e) NULL
  expect_error(
    process_tags(htmltools::tag("input", list(onInput = h1, onInput = h2))),
    "duplicate handler for event `input`"
  )
})

test_that("value = reactiveProxy(get, set) bridges the sync-write case", {
  # The §4 both-case: a controlled value whose write runs a side-effect.
  # The proxy's `set` IS the handler; one channel, no explicit `on*`.
  rv <- shiny::reactiveVal("a")
  log <- character()
  p <- reactiveProxy(get = rv, set = function(v) { log <<- c(log, v); rv(v) })
  result <- process_tags(tags$input(value = p))
  expect_length(result$events, 1L)
  shiny::isolate(result$events[[1]]$handler(list(value = "typed")))
  expect_equal(shiny::isolate(rv()), "typed")
  expect_equal(log, "typed")
})

# --- irid_wire carrier config ------------------------------------------------

test_that("bare onClick equals irid_wire(handler) with default config", {
  h <- function() NULL
  bare <- process_tags(tags$button(onClick = h))
  wired <- process_tags(tags$button(onClick = irid_wire(h)))
  expect_equal(bare$events[[1]]$mode, "immediate")
  expect_equal(wired$events[[1]]$mode, "immediate")
  expect_equal(bare$events[[1]]$event, "click")
  expect_equal(wired$events[[1]]$event, "click")
})

test_that("irid_wire timing sets the dispatch mode", {
  result <- process_tags(
    tags$button(onClick = irid_wire(\() NULL, irid_throttle(100)))
  )
  expect_equal(result$events[[1]]$mode, "throttle")
  expect_equal(result$events[[1]]$ms, 100)
  expect_true(result$events[[1]]$leading)
})

test_that("irid_wire with dom_opts but no timing keeps the per-event default", {
  # The submit event has no per-event default override, so it stays
  # immediate even though dom_opts is set — dom_opts must not clobber timing.
  result <- process_tags(
    tags$form(onSubmit = irid_wire(
      \() NULL, dom_opts = irid_dom_opts(prevent_default = TRUE)
    ))
  )
  expect_equal(result$events[[1]]$mode, "immediate")
  expect_true(result$events[[1]]$prevent_default)
})

test_that("dom_opts flags land on the event row", {
  result <- process_tags(
    tags$div(onClick = irid_wire(\() NULL, dom_opts = irid_dom_opts(
      prevent_default = TRUE, stop_propagation = TRUE,
      capture = TRUE, passive = TRUE
    )))
  )
  e <- result$events[[1]]
  expect_true(e$prevent_default)
  expect_true(e$stop_propagation)
  expect_true(e$capture)
  expect_true(e$passive)
})

test_that("coalesce derives from timing mode; carrier override wins", {
  immediate <- process_tags(tags$button(onClick = irid_wire(\() NULL)))
  expect_false(immediate$events[[1]]$coalesce)

  throttled <- process_tags(
    tags$button(onClick = irid_wire(\() NULL, irid_throttle(100)))
  )
  expect_true(throttled$events[[1]]$coalesce)

  overridden <- process_tags(
    tags$button(onClick = irid_wire(\() NULL, irid_throttle(100), coalesce = FALSE))
  )
  expect_false(overridden$events[[1]]$coalesce)
})

test_that("config-only wire (dom_opts, no handler) is client-only", {
  result <- process_tags(
    tags$form(onSubmit = irid_wire(
      dom_opts = irid_dom_opts(prevent_default = TRUE)
    ))
  )
  expect_length(result$events, 1L)
  expect_null(result$events[[1]]$handler)
  expect_true(result$events[[1]]$prevent_default)
  expect_equal(result$events[[1]]$event, "submit")
})

test_that("irid_wire can tune a value binding's timing", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = irid_wire(rv, irid_debounce(500)))
  )
  expect_length(result$bindings, 1L)
  expect_equal(result$bindings[[1]]$attr, "value")
  expect_length(result$events, 1L)
  expect_equal(result$events[[1]]$mode, "debounce")
  expect_equal(result$events[[1]]$ms, 500)
})

test_that("value = irid_wire() with no subject errors", {
  expect_error(
    process_tags(tags$input(value = irid_wire(timing = irid_debounce(200)))),
    "needs a reactive subject"
  )
})

# --- Per-event default timing ------------------------------------------------
#
# The default rule is keyed only on the DOM event name: `input` →
# `irid_debounce(200)`, the high-frequency continuous streams →
# `irid_throttle(100)` (+ derived coalesce), everything else →
# `irid_immediate()`.

test_that("explicit onInput defaults to debounce(200)", {
  result <- process_tags(tags$input(onInput = function(e) NULL))
  expect_equal(result$events[[1]]$mode, "debounce")
  expect_equal(result$events[[1]]$ms, 200)
})

test_that("explicit onChange defaults to immediate", {
  result <- process_tags(tags$input(onChange = function(e) NULL))
  expect_equal(result$events[[1]]$mode, "immediate")
})

test_that("explicit onClick defaults to immediate", {
  result <- process_tags(tags$button(onClick = function() NULL))
  expect_equal(result$events[[1]]$mode, "immediate")
})

test_that("high-frequency events default to throttle(100) + coalesce", {
  hi_events <- c(
    onMouseMove = "mousemove", onPointerMove = "pointermove",
    onTouchMove = "touchmove", onDrag = "drag", onDragOver = "dragover",
    onScroll = "scroll", onWheel = "wheel", onResize = "resize"
  )
  for (attr in names(hi_events)) {
    args <- list(function(e) NULL)
    names(args) <- attr
    result <- process_tags(do.call(tags$div, args))
    ev <- result$events[[1]]
    expect_equal(ev$event, hi_events[[attr]])
    expect_equal(ev$mode, "throttle", info = attr)
    expect_equal(ev$ms, 100, info = attr)
    expect_true(ev$coalesce, info = attr)
  }
})

test_that("explicit immediate wins over a high-frequency default", {
  result <- process_tags(
    tags$div(onMouseMove = irid_wire(function(e) NULL, irid_immediate()))
  )
  expect_equal(result$events[[1]]$mode, "immediate")
  expect_false(result$events[[1]]$coalesce)
})

test_that("explicit coalesce = FALSE keeps the throttle default but ungates", {
  result <- process_tags(
    tags$div(onMouseMove = irid_wire(function(e) NULL, coalesce = FALSE))
  )
  expect_equal(result$events[[1]]$mode, "throttle")
  expect_equal(result$events[[1]]$ms, 100)
  expect_false(result$events[[1]]$coalesce)
})

test_that("autobind value defaults to debounce(200) (input event)", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(tags$input(value = rv))
  expect_equal(result$events[[1]]$mode, "debounce")
  expect_equal(result$events[[1]]$ms, 200)
})

test_that("autobind checked defaults to immediate (change event)", {
  rv <- shiny::reactiveVal(FALSE)
  result <- process_tags(tags$input(type = "checkbox", checked = rv))
  expect_equal(result$events[[1]]$mode, "immediate")
})

test_that("irid_wire timing overrides the per-event default", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = irid_wire(rv, irid_immediate()))
  )
  expect_equal(result$events[[1]]$mode, "immediate")
})

# --- Misuse: irid construct passed as a slot value ---------------------------
#
# `irid_wire` is the one valid construct in an event / value / checked slot.
# Bare timing shapes, `irid_dom_opts`, control-flow nodes, and outputs are
# meaningful only elsewhere; as a slot value they would serialize as raw HTML,
# so process_tags rejects them loudly.

test_that("bare timing shape on an `on*` prop errors with a pairing hint", {
  expect_error(
    process_tags(tags$button(onClick = irid_immediate())),
    "irid_timing"
  )
  expect_error(
    process_tags(tags$button(onClick = irid_immediate())),
    "pair with a subject inside `irid_wire\\(\\)`.*onClick"
  )
})

test_that("bare timing shape on a non-event attribute uses a generic hint", {
  expect_error(
    process_tags(tags$div(class = irid_immediate())),
    "Timing shapes belong inside `irid_wire\\(timing = ...\\)`"
  )
})

test_that("irid_throttle / irid_debounce on an `on*` prop also error", {
  expect_error(
    process_tags(tags$button(onClick = irid_throttle(100))),
    "irid_timing"
  )
  expect_error(
    process_tags(tags$input(onInput = irid_debounce(200))),
    "irid_timing"
  )
})

test_that("irid_dom_opts as a slot value errors with a wrapping hint", {
  expect_error(
    process_tags(tags$div(onClick = irid_dom_opts(prevent_default = TRUE))),
    "`irid_dom_opts\\(\\)` belongs inside `irid_wire\\(dom_opts = ...\\)`"
  )
})

test_that("irid_wire on a plain attribute binding errors", {
  expect_error(
    process_tags(tags$div(class = irid_wire(\() "x"))),
    "configures event.*and.*value.*checked.*slots"
  )
})

test_that("control-flow nodes as slot values error with a child-slot hint", {
  expect_error(
    process_tags(tags$div(class = Each(\() 1:3, \(i) tags$span(i)))),
    "irid_each.*children"
  )
  expect_error(
    process_tags(tags$div(class = When(\() TRUE, \() "yes"))),
    "irid_when.*children"
  )
  expect_error(
    process_tags(tags$div(class = Match(\() TRUE, Default(\() "hi")))),
    "irid_match.*children"
  )
})

test_that("Output node as a slot value errors", {
  expect_error(
    process_tags(tags$div(class = PlotOutput(\() plot(1)))),
    "irid_output.*children"
  )
})

test_that("error message mentions the offending slot name", {
  expect_error(
    process_tags(tags$button(onClick = irid_immediate())),
    "onClick"
  )
  expect_error(
    process_tags(tags$div(class = Each(\() 1:3, \(i) tags$span(i)))),
    "class"
  )
})

test_that("control-flow nodes are still valid as children", {
  result <- process_tags(
    tags$div(Each(\() 1:3, \(i) tags$span(i)))
  )
  expect_length(result$control_flows, 1L)
  expect_equal(result$control_flows[[1]]$type, "each")
})

# --- Misc binding/event coexistence ------------------------------------------

test_that("without dom_opts, every event entry has prevent_default = FALSE", {
  result <- process_tags(
    tags$input(onKeyDown = function(e) NULL, onClick = function(e) NULL)
  )
  for (e in result$events) {
    expect_false(e$prevent_default)
    expect_false(e$stop_propagation)
    expect_false(e$capture)
    expect_false(e$passive)
  }
})

test_that("dom_opts is per-slot, not broadcast across events", {
  result <- process_tags(
    tags$form(
      onSubmit = irid_wire(\() NULL,
                           dom_opts = irid_dom_opts(prevent_default = TRUE)),
      onClick = \(e) NULL
    )
  )
  submit_e <- Filter(function(e) e$event == "submit", result$events)[[1]]
  click_e <- Filter(function(e) e$event == "click", result$events)[[1]]
  expect_true(submit_e$prevent_default)
  expect_false(click_e$prevent_default)
})
