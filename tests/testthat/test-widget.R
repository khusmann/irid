# Tests for process_tags' irid_widget branch — extraction shape, binding
# / event row contents, container id + data-irid-widget marker, and
# coexistence with DOM events on the container.

# --- Helpers -----------------------------------------------------------------

# Find the single widget_init in a processed result and return it.
single_init <- function(processed) {
  expect_length(processed$widget_inits, 1L)
  processed$widget_inits[[1]]
}

# Find the single binding matching a (target, attr) pair.
binding_for <- function(processed, target, attr) {
  matches <- Filter(
    function(b) b$target == target && identical(b$attr, attr),
    processed$bindings
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
    IridWidget("w", events = list("not a widget_event")),
    "must be a `widget_event`"
  )
  expect_error(
    IridWidget("w", events = list(change = function(e) NULL)),
    "must be a `widget_event`"
  )
})

test_that("IridWidget errors on bad deps", {
  expect_error(
    IridWidget("w", deps = list("not a dep")),
    "html_dependency"
  )
  expect_error(IridWidget("w", deps = 42), "html_dependency")
})

test_that("IridWidget errors on a non-tag container", {
  expect_error(IridWidget("w", container = "string"), "shiny.tag")
})

test_that("IridWidget accepts a single html_dependency or a list", {
  dep <- htmltools::htmlDependency("d", "1.0", src = c(href = "/"))
  w1 <- IridWidget("w", deps = dep)
  expect_equal(w1$deps, list(dep))
  w2 <- IridWidget("w", deps = list(dep))
  expect_equal(w2$deps, list(dep))
})

test_that("NULL entries in events are dropped before validation", {
  # `widget_event()` returns NULL when handler is NULL, so wrappers can
  # forward optional handlers declaratively without conditional list-building.
  h <- function(e) NULL
  w <- IridWidget("w", events = list(
    widget_event(name = "change",         handler = h),
    widget_event(name = "cursor-changed", handler = NULL)   # → NULL, dropped
  ))
  expect_length(w$events, 1L)
  expect_equal(w$events[[1]]$name, "change")

  # All-NULL events list collapses to empty — no validation error.
  w2 <- IridWidget("w", events = list(
    widget_event(name = "change", handler = NULL),
    widget_event(name = "blur",   handler = NULL)
  ))
  expect_length(w2$events, 0L)
})

test_that("NULL props are preserved through to static_props and JSON-serialize to JS null", {
  # The construct keeps NULL props (no drop), so wrappers can declare
  # their full prop shape with optional slots and the JS factory sees
  # a predictable, complete object.
  w <- IridWidget("w", props = list(content = "hi", cursor = NULL))
  expect_setequal(names(w$props), c("content", "cursor"))

  # process_tags routes them through static_props with the key intact
  # (uses `[name]<-` to dodge R's NULL-removes-key quirk).
  out <- process_tags(w)
  sp <- out$widget_inits[[1]]$static_props
  expect_setequal(names(sp), c("content", "cursor"))
  expect_null(sp$cursor)

  # Shiny's JSON serializer (`null = "null"`) turns NULL list entries
  # into JS `null` — not `{}`, not absent — so the widget's `props`
  # object always has the wrapper-declared keys.
  json <- shiny:::toJSON(sp)
  expect_match(as.character(json), '"cursor":null', fixed = TRUE)
})

# --- Extraction shape --------------------------------------------------------

test_that("widget node produces a widget_inits entry", {
  w <- IridWidget("codemirror", props = list(theme = "dracula"))
  out <- process_tags(w)
  init <- single_init(out)
  expect_equal(init$name, "codemirror")
  expect_named(init$static_props, "theme")
  expect_equal(init$static_props$theme, "dracula")
  expect_length(init$prop_fns, 0L)
})

test_that("callable prop becomes a target='widget' binding + prop_fns entry", {
  rv <- shiny::reactiveVal("hi\n")
  w <- IridWidget("codemirror", props = list(content = rv))
  out <- process_tags(w)

  b <- binding_for(out, "widget", "content")
  expect_equal(b$attr, "content")
  expect_equal(b$target, "widget")
  expect_identical(b$fn, rv)

  init <- single_init(out)
  expect_named(init$prop_fns, "content")
  expect_length(init$static_props, 0L)
})

test_that("non-callable prop produces no binding; rides in static_props", {
  w <- IridWidget("w", props = list(theme = "dracula", lineNumbers = TRUE))
  out <- process_tags(w)
  expect_length(out$bindings, 0L)
  init <- single_init(out)
  expect_equal(init$static_props$theme, "dracula")
  expect_true(init$static_props$lineNumbers)
})

test_that("mixed-shape props dispatch per-key", {
  rv <- shiny::reactiveVal("init")
  w <- IridWidget("w", props = list(
    content = rv,            # callable
    theme = "dracula",       # static string
    lineNumbers = TRUE       # static logical
  ))
  out <- process_tags(w)

  # `content` → binding + prop_fns
  expect_length(out$bindings, 1L)
  expect_equal(out$bindings[[1]]$attr, "content")
  expect_equal(out$bindings[[1]]$target, "widget")

  init <- single_init(out)
  expect_named(init$prop_fns, "content")
  expect_setequal(names(init$static_props), c("theme", "lineNumbers"))
})

test_that("events become $events rows with source='widget'", {
  h <- function(e) NULL
  w <- IridWidget("w", events = list(widget_event(name = "change", handler = h)))
  out <- process_tags(w)
  expect_length(out$events, 1L)
  ev <- out$events[[1]]
  expect_equal(ev$event, "change")
  expect_equal(ev$source, "widget")
  expect_identical(ev$handler, h)
})

test_that("widget event rows carry the handler's write_targets attribute (via write_back)", {
  rv <- shiny::reactiveVal("x")
  w <- IridWidget(
    "w",
    props  = list(content = rv),
    events = list(widget_event(name = "change", handler = write_back(rv, "content")))
  )
  out <- process_tags(w)
  expect_equal(out$events[[1]]$write_targets, "content")
})

test_that("widget event rows have NULL write_targets for hand-rolled handlers", {
  # Hand-rolled handlers don't declare write targets → no force-send.
  rv <- shiny::reactiveVal("x")
  w <- IridWidget(
    "w",
    props  = list(content = rv),
    events = list(widget_event(name = "change", handler = function(e) NULL))
  )
  out <- process_tags(w)
  expect_null(out$events[[1]]$write_targets)
})

test_that("widget event default timing is irid_immediate() when widget_event timing is omitted", {
  h <- function(e) NULL
  w <- IridWidget("w", events = list(
    widget_event(name = "change",         handler = h),
    widget_event(name = "cursor-changed", handler = h),
    widget_event(name = "input",          handler = h)   # no input→debounce(200) special case for widgets
  ))
  out <- process_tags(w)
  for (ev in out$events) {
    expect_equal(ev$mode, "immediate", info = ev$event)
  }
})

# --- Container handling ------------------------------------------------------

test_that("container id is auto-generated when not user-supplied", {
  w <- IridWidget("w")
  out <- process_tags(w)
  init <- single_init(out)
  expect_true(nzchar(init$id))
  expect_equal(out$tag$attribs$id, init$id)
})

test_that("user-supplied id on the container is honored", {
  w <- IridWidget("w", container = htmltools::tags$div(id = "my-editor"))
  out <- process_tags(w)
  init <- single_init(out)
  expect_equal(init$id, "my-editor")
  expect_equal(out$tag$attribs$id, "my-editor")
})

test_that("data-irid-widget attribute is set to the widget name", {
  w <- IridWidget("codemirror")
  out <- process_tags(w)
  expect_equal(out$tag$attribs[["data-irid-widget"]], "codemirror")
})

test_that("user-set data-irid-widget on container is overwritten", {
  w <- IridWidget(
    "actual-name",
    container = htmltools::tags$div(`data-irid-widget` = "user-bogus")
  )
  out <- process_tags(w)
  expect_equal(out$tag$attribs[["data-irid-widget"]], "actual-name")
})

test_that("container's existing classes/styles are preserved", {
  w <- IridWidget(
    "w",
    container = htmltools::tags$div(class = "border rounded", style = "height: 300px;")
  )
  out <- process_tags(w)
  expect_equal(out$tag$attribs$class, "border rounded")
  expect_equal(out$tag$attribs$style, "height: 300px;")
})

test_that("container with DOM-event on* emits a source='dom' event on the same id", {
  click <- function(e) NULL
  w <- IridWidget(
    "w",
    events = list(widget_event(name = "change", handler = function(e) NULL)),
    container = htmltools::tags$div(onClick = click)
  )
  out <- process_tags(w)
  expect_length(out$events, 2L)

  by_event <- setNames(out$events, vapply(out$events, function(e) e$event, character(1L)))
  expect_setequal(names(by_event), c("change", "click"))
  expect_equal(by_event$change$source, "widget")
  expect_equal(by_event$click$source, "dom")
  # Both share the same element id (the widget's id).
  expect_equal(by_event$change$id, by_event$click$id)
})

# --- widget_event timing -----------------------------------------------------

test_that("widget_event timing lands on the emitted event row", {
  h <- function(e) NULL
  w <- IridWidget("w", events = list(
    widget_event(name = "change", handler = h, timing = irid_debounce(200)),
    widget_event(name = "blur",   handler = h, timing = irid_throttle(100))
  ))
  out <- process_tags(w)
  by_event <- setNames(out$events, vapply(out$events, function(e) e$event, character(1L)))
  expect_equal(by_event$change$mode, "debounce")
  expect_equal(by_event$change$ms, 200)
  expect_equal(by_event$blur$mode, "throttle")
  expect_equal(by_event$blur$ms, 100)
})


# --- Deps --------------------------------------------------------------------

test_that("deps land in widget_inits$deps verbatim", {
  dep <- htmltools::htmlDependency("cm6", "6.0.1", src = c(href = "/cm/"))
  w <- IridWidget("w", deps = dep)
  out <- process_tags(w)
  init <- single_init(out)
  expect_equal(init$deps, list(dep))
})

test_that("multiple widgets in one tree each get their own widget_inits entry", {
  dep1 <- htmltools::htmlDependency("d1", "1.0", src = c(href = "/"))
  dep2 <- htmltools::htmlDependency("d2", "1.0", src = c(href = "/"))
  tree <- htmltools::tagList(
    IridWidget("w1", deps = dep1),
    IridWidget("w2", deps = dep2)
  )
  out <- process_tags(tree)
  expect_length(out$widget_inits, 2L)
  expect_equal(out$widget_inits[[1]]$deps, list(dep1))
  expect_equal(out$widget_inits[[2]]$deps, list(dep2))
})

# --- Empty cases -------------------------------------------------------------

test_that("empty props/events still produce a valid init entry", {
  w <- IridWidget("w")
  out <- process_tags(w)
  expect_length(out$bindings, 0L)
  expect_length(out$events, 0L)
  init <- single_init(out)
  expect_length(init$prop_fns, 0L)
  expect_length(init$static_props, 0L)
  expect_equal(init$name, "w")
})

# --- Default container -------------------------------------------------------

test_that("default container is a plain div", {
  w <- IridWidget("w")
  out <- process_tags(w)
  expect_equal(out$tag$name, "div")
})

# --- Misuse: widget as attribute value --------------------------------------

test_that("widget passed as an attribute value errors with the existing guard", {
  w <- IridWidget("w")
  expect_error(
    process_tags(htmltools::tags$div(class = w)),
    "irid_widget"
  )
})
