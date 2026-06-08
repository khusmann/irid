# Tests for process_tags' irid_widget branch — extraction shape, two-way
# prop bindings + write-back rows, event rows, container id + marker, and
# coexistence with DOM events on the container.

# --- Helpers -----------------------------------------------------------------

single_init <- function(processed) {
  expect_length(processed$widget_inits, 1L)
  processed$widget_inits[[1]]
}

binding_for <- function(processed, target, attr) {
  matches <- Filter(
    function(b) b$target == target && identical(b$attr, attr),
    processed$bindings
  )
  expect_length(matches, 1L)
  matches[[1]]
}

# The synthesized write-back / event row for a given (kind, event).
event_row <- function(processed, kind, event) {
  matches <- Filter(
    function(e) identical(e$kind, kind) && e$event == event,
    processed$events
  )
  expect_length(matches, 1L)
  matches[[1]]
}

# --- Construction validation -------------------------------------------------

test_that("IridWidget errors on a missing/empty name", {
  expect_error(IridWidget(name = ""), "non-empty character scalar")
  expect_error(IridWidget(name = NA_character_), "non-empty character scalar")
  expect_error(IridWidget(name = c("a", "b")), "non-empty character scalar")
  expect_error(IridWidget(name = 42), "non-empty character scalar")
})

test_that("IridWidget errors on malformed props/events", {
  expect_error(IridWidget("w", props = 1), "`props` must be a list")
  expect_error(IridWidget("w", events = "x"), "`events` must be a list")
  expect_error(
    IridWidget("w", props = list("unnamed")),
    "every entry in `props` must be named"
  )
  expect_error(
    IridWidget("w", events = list("not a fn or wire")),
    "must be named"
  )
  expect_error(
    IridWidget("w", events = list(change = 42)),
    "must be a function or an `irid_wire`"
  )
})

test_that("IridWidget accepts a bare function or an irid_wire as an event", {
  h <- function(e) NULL
  w1 <- IridWidget("w", events = list(change = h))
  expect_length(w1$events, 1L)
  expect_s3_class(w1$events$change, "irid_wire")
  expect_identical(w1$events$change$subject, h)

  w2 <- IridWidget("w", events = list(
    change = irid_wire(h, irid_throttle(50))
  ))
  expect_equal(w2$events$change$timing$mode, "throttle")
})

test_that("IridWidget errors on dom_opts on a widget event", {
  expect_error(
    IridWidget("w", events = list(
      change = irid_wire(function(e) NULL,
                         dom_opts = irid_dom_opts(prevent_default = TRUE))
    )),
    "`dom_opts` is not allowed on the widget event"
  )
})

test_that("IridWidget errors on bad deps", {
  expect_error(IridWidget("w", deps = list("not a dep")), "html_dependency")
  expect_error(IridWidget("w", deps = 42), "html_dependency")
})

test_that("IridWidget errors on a non-tag container", {
  expect_error(IridWidget("w", container = "string"), "shiny.tag")
})

test_that("IridWidget accepts a single html_dependency or a list", {
  dep <- htmltools::htmlDependency("d", "1.0", src = c(href = "/"))
  expect_equal(IridWidget("w", deps = dep)$deps, list(dep))
  expect_equal(IridWidget("w", deps = list(dep))$deps, list(dep))
})

test_that("NULL / subject-less event entries are dropped", {
  h <- function(e) NULL
  # Bare NULL drops; a merge() that resolves to a subject-less wire drops.
  w <- IridWidget("w", events = list(
    change          = h,
    `cursor-changed` = NULL,
    blur            = merge(irid_wire(timing = irid_throttle(100)), NULL)
  ))
  expect_length(w$events, 1L)
  expect_named(w$events, "change")
})

test_that("NULL props are preserved through to static_props (JS null)", {
  w <- IridWidget("w", props = list(content = "hi", cursor = NULL))
  expect_setequal(names(w$props), c("content", "cursor"))

  out <- process_tags(w)
  sp <- out$widget_inits[[1]]$static_props
  expect_setequal(names(sp), c("content", "cursor"))
  expect_null(sp$cursor)

  json <- shiny:::toJSON(sp)
  expect_match(as.character(json), '"cursor":null', fixed = TRUE)
})

# --- Extraction shape: two-way props -----------------------------------------

test_that("widget node produces a widget_inits entry", {
  w <- IridWidget("codemirror", props = list(theme = "dracula"))
  out <- process_tags(w)
  init <- single_init(out)
  expect_equal(init$name, "codemirror")
  expect_named(init$static_props, "theme")
  expect_equal(init$static_props$theme, "dracula")
  expect_length(init$prop_fns, 0L)
})

test_that("callable prop is two-way: binding + prop_fns + kind='prop' row", {
  rv <- shiny::reactiveVal("hi\n")
  w <- IridWidget("codemirror", props = list(content = rv))
  out <- process_tags(w)

  b <- binding_for(out, "widget", "content")     # server -> client
  expect_identical(b$fn, rv)

  init <- single_init(out)
  expect_named(init$prop_fns, "content")
  expect_length(init$static_props, 0L)

  pe <- event_row(out, "prop", "content")        # client -> server
  expect_equal(pe$source, "widget")
  expect_equal(pe$write_targets, "content")
})

test_that("prop write-back writes the reactive via e$value", {
  rv <- shiny::reactiveVal("a")
  out <- process_tags(IridWidget("w", props = list(content = rv)))
  pe <- event_row(out, "prop", "content")
  shiny::isolate(pe$handler(list(value = "typed")))
  expect_equal(shiny::isolate(rv()), "typed")
})

test_that("read-only prop write-back is a no-op but still declares its target", {
  rv <- shiny::reactiveVal("seed")
  ro <- shiny::reactive(rv())
  out <- process_tags(IridWidget("w", props = list(content = ro)))
  pe <- event_row(out, "prop", "content")
  expect_silent(shiny::isolate(pe$handler(list(value = "ignored"))))
  expect_equal(shiny::isolate(rv()), "seed")
  expect_equal(pe$write_targets, "content")       # snap-back via force-send
})

test_that("irid_wire tunes a prop's write-back timing (no enable/disable)", {
  rv <- shiny::reactiveVal("")
  out <- process_tags(IridWidget("w", props = list(
    content = irid_wire(rv, irid_debounce(200))
  )))
  # still a binding + prop_fns (two-way unchanged)
  binding_for(out, "widget", "content")
  expect_named(single_init(out)$prop_fns, "content")
  pe <- event_row(out, "prop", "content")
  expect_equal(pe$mode, "debounce")
  expect_equal(pe$ms, 200)
})

test_that("non-callable prop produces no binding; rides in static_props", {
  w <- IridWidget("w", props = list(theme = "dracula", lineNumbers = TRUE))
  out <- process_tags(w)
  expect_length(out$bindings, 0L)
  expect_length(out$events, 0L)
  init <- single_init(out)
  expect_equal(init$static_props$theme, "dracula")
  expect_true(init$static_props$lineNumbers)
})

test_that("mixed-shape props dispatch per-key", {
  rv <- shiny::reactiveVal("init")
  w <- IridWidget("w", props = list(
    content = rv, theme = "dracula", lineNumbers = TRUE
  ))
  out <- process_tags(w)
  expect_length(out$bindings, 1L)
  expect_equal(out$bindings[[1]]$attr, "content")
  init <- single_init(out)
  expect_named(init$prop_fns, "content")
  expect_setequal(names(init$static_props), c("theme", "lineNumbers"))
})

# --- Extraction shape: events ------------------------------------------------

test_that("events become kind='event' rows with source='widget'", {
  h <- function(e) NULL
  w <- IridWidget("w", events = list(`cursor-changed` = h))
  out <- process_tags(w)
  ev <- event_row(out, "event", "cursor-changed")
  expect_equal(ev$source, "widget")
  expect_identical(ev$handler, h)
})

test_that("hand-rolled event handlers declare no write_targets", {
  w <- IridWidget("w", events = list(`cursor-changed` = function(e) NULL))
  out <- process_tags(w)
  expect_null(event_row(out, "event", "cursor-changed")$write_targets)
})

test_that("widget event default timing is irid_immediate()", {
  h <- function(e) NULL
  w <- IridWidget("w", events = list(
    `cursor-changed` = h,
    blur             = h,
    input            = h   # no input→debounce(200) special case for widgets
  ))
  out <- process_tags(w)
  for (ev in out$events) expect_equal(ev$mode, "immediate", info = ev$event)
})

test_that("irid_wire timing lands on the emitted event row", {
  h <- function(e) NULL
  w <- IridWidget("w", events = list(
    `cursor-changed` = irid_wire(h, irid_throttle(100)),
    blur             = irid_wire(h, irid_debounce(200))
  ))
  out <- process_tags(w)
  cc <- event_row(out, "event", "cursor-changed")
  bl <- event_row(out, "event", "blur")
  expect_equal(cc$mode, "throttle"); expect_equal(cc$ms, 100)
  expect_equal(bl$mode, "debounce"); expect_equal(bl$ms, 200)
})

# --- Container handling ------------------------------------------------------

test_that("container id is auto-generated when not user-supplied", {
  out <- process_tags(IridWidget("w"))
  init <- single_init(out)
  expect_true(nzchar(init$id))
  expect_equal(out$tag$attribs$id, init$id)
})

test_that("user-supplied id on the container is honored", {
  out <- process_tags(IridWidget("w", container = htmltools::tags$div(id = "my-editor")))
  expect_equal(single_init(out)$id, "my-editor")
  expect_equal(out$tag$attribs$id, "my-editor")
})

test_that("data-irid-widget attribute is set to the widget name", {
  out <- process_tags(IridWidget("codemirror"))
  expect_equal(out$tag$attribs[["data-irid-widget"]], "codemirror")
})

test_that("user-set data-irid-widget on container is overwritten", {
  out <- process_tags(IridWidget(
    "actual-name",
    container = htmltools::tags$div(`data-irid-widget` = "user-bogus")
  ))
  expect_equal(out$tag$attribs[["data-irid-widget"]], "actual-name")
})

test_that("container's existing classes/styles are preserved", {
  out <- process_tags(IridWidget(
    "w",
    container = htmltools::tags$div(class = "border rounded", style = "height: 300px;")
  ))
  expect_equal(out$tag$attribs$class, "border rounded")
  expect_equal(out$tag$attribs$style, "height: 300px;")
})

test_that("container with a DOM-event on* emits a source='dom' event on the same id", {
  w <- IridWidget(
    "w",
    events = list(`cursor-changed` = function(e) NULL),
    container = htmltools::tags$div(onClick = function(e) NULL)
  )
  out <- process_tags(w)
  by_event <- setNames(out$events, vapply(out$events, function(e) e$event, character(1L)))
  expect_setequal(names(by_event), c("cursor-changed", "click"))
  expect_equal(by_event$`cursor-changed`$source, "widget")
  expect_equal(by_event$click$source, "dom")
  expect_equal(by_event$`cursor-changed`$id, by_event$click$id)
})

# --- Deps --------------------------------------------------------------------

test_that("deps land in widget_inits$deps verbatim", {
  dep <- htmltools::htmlDependency("cm6", "6.0.1", src = c(href = "/cm/"))
  out <- process_tags(IridWidget("w", deps = dep))
  expect_equal(single_init(out)$deps, list(dep))
})

test_that("multiple widgets in one tree each get their own widget_inits entry", {
  dep1 <- htmltools::htmlDependency("d1", "1.0", src = c(href = "/"))
  dep2 <- htmltools::htmlDependency("d2", "1.0", src = c(href = "/"))
  out <- process_tags(htmltools::tagList(
    IridWidget("w1", deps = dep1),
    IridWidget("w2", deps = dep2)
  ))
  expect_length(out$widget_inits, 2L)
  expect_equal(out$widget_inits[[1]]$deps, list(dep1))
  expect_equal(out$widget_inits[[2]]$deps, list(dep2))
})

# --- Empty / default cases ---------------------------------------------------

test_that("empty props/events still produce a valid init entry", {
  out <- process_tags(IridWidget("w"))
  expect_length(out$bindings, 0L)
  expect_length(out$events, 0L)
  init <- single_init(out)
  expect_length(init$prop_fns, 0L)
  expect_length(init$static_props, 0L)
  expect_equal(init$name, "w")
})

test_that("default container is a plain div", {
  expect_equal(process_tags(IridWidget("w"))$tag$name, "div")
})

# --- Misuse: widget as attribute value --------------------------------------

test_that("widget passed as an attribute value errors with the existing guard", {
  expect_error(
    process_tags(htmltools::tags$div(class = IridWidget("w"))),
    "irid_widget"
  )
})
