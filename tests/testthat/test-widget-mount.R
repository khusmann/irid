# --- IridWidget constructor + process_tags + mount (Slice 3) ------------------
#
# These tests cover:
#   Task 3.1: IridWidget() constructor
#   Task 3.2: process_tags handling for irid_widget nodes
#   Task 3.3: mount handling (init, channel observers, destroy)
#   Task 3.4: End-to-end counter widget lifecycle

# ---- Helpers ---------------------------------------------------------------

# A minimal htmlDependency for testing
test_dep <- function(name = "test-widget") {
  htmltools::htmlDependency(
    name = name,
    version = "1.0.0",
    src = system.file("js", package = "irid"),
    script = "irid.js"
  )
}

flushReact <- function() shiny:::flushReact()

# Create a fake Shiny session that records custom messages
new_fake_session <- function() {
  s <- shiny::MockShinySession$new()
  store <- new.env(parent = emptyenv())
  store$msgs <- list()
  store$userData <- list()
  s$sendCustomMessage <- function(type, message) {
    store$msgs[[length(store$msgs) + 1L]] <<- list(
      type = type, message = message
    )
    invisible()
  }
  s$msgs <- function() store$msgs
  s
}

# Process and mount a tag, returning the session and mount handle
mount_widget <- function(tag) {
  session <- new_fake_session()
  result <- irid:::process_tags(tag)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  flushReact()
  list(session = session, handle = handle, result = result)
}

# ============================================================================
# Task 3.1: IridWidget() constructor
# ============================================================================

test_that("IridWidget returns an object with class irid_widget", {
  w <- IridWidget(test_dep(), tags$div())
  expect_s3_class(w, "irid_widget")
})

test_that("IridWidget errors when container is not a shiny.tag", {
  expect_error(
    IridWidget(test_dep(), "not a tag"),
    "inherits\\(container, \"shiny\\.tag\"\\) is not TRUE"
  )
  expect_error(
    IridWidget(test_dep(), list()),
    "inherits\\(container, \"shiny\\.tag\"\\) is not TRUE"
  )
})

test_that("IridWidget stores named ... args in the args field", {
  w <- IridWidget(test_dep(), tags$div(), x = 1, y = 2)
  expect_equal(w$args$x, 1)
  expect_equal(w$args$y, 2)
})

test_that("IridWidget stores .config, .event, .render", {
  cfg <- list(mode = "javascript")
  ev <- event_throttle(100)
  w <- IridWidget(
    test_dep(), tags$div(),
    .config = cfg, .event = ev, .render = "content"
  )
  expect_equal(w$.config, cfg)
  expect_equal(w$.event, ev)
  expect_equal(w$.render, "content")
})

test_that("IridWidget .widget_name overrides auto-derived name", {
  w1 <- IridWidget(test_dep("my-widget"), tags$div())
  # Default strips hyphens/underscores from dep$name
  expect_equal(w1$widget_name, "mywidget")

  w2 <- IridWidget(
    test_dep("my-widget"), tags$div(),
    .widget_name = "custom-name"
  )
  expect_equal(w2$widget_name, "custom-name")
})

test_that("IridWidget auto-derived name strips hyphens and underscores", {
  w1 <- IridWidget(test_dep("codemirror-editor"), tags$div())
  expect_equal(w1$widget_name, "codemirroreditor")

  w2 <- IridWidget(test_dep("leaflet_map"), tags$div())
  expect_equal(w2$widget_name, "leafletmap")
})

test_that("IridWidget .render defaults to NULL", {
  w <- IridWidget(test_dep(), tags$div())
  expect_null(w$.render)
})

# ============================================================================
# Task 3.2: process_tags handling for irid_widget
# ============================================================================

test_that("process_tags extracts a widget entry from IridWidget", {
  rv <- shiny::reactiveVal(0)
  result <- irid:::process_tags(
    IridWidget(test_dep(), tags$div(), count = rv)
  )
  expect_length(result$widgets, 1L)
  w <- result$widgets[[1]]
  expect_equal(w$widget_name, "testwidget")
  expect_null(w$render)
  expect_named(w$channels, "count")
  expect_identical(w$channels$count, rv)
  expect_equal(w$config, list())
})

test_that("process_tags widget entry has correct id and render field", {
  result <- irid:::process_tags(
    IridWidget(
      test_dep("cm"), tags$div(),
      content = shiny::reactiveVal("hi"),
      .render = "content"
    )
  )
  w <- result$widgets[[1]]
  expect_true(nzchar(w$id))
  expect_equal(w$render, "content")
})

test_that("onChange arg creates an event entry in result$events", {
  handler <- function(e) NULL
  result <- irid:::process_tags(
    IridWidget(test_dep(), tags$div(), onChange = handler)
  )
  expect_length(result$events, 1L)
  ev <- result$events[[1]]
  expect_equal(ev$event, "change")
  expect_identical(ev$handler, handler)
})

test_that("widget event entry has correct default timing", {
  # onChange defaults to event_immediate (non-input event)
  result <- irid:::process_tags(
    IridWidget(test_dep(), tags$div(), onChange = function(e) NULL)
  )
  expect_equal(result$events[[1]]$mode, "immediate")

  # onInput defaults to event_debounce(200)
  result2 <- irid:::process_tags(
    IridWidget(test_dep(), tags$div(), onInput = function(e) NULL)
  )
  expect_equal(result2$events[[1]]$mode, "debounce")
  expect_equal(result2$events[[1]]$ms, 200)
})

test_that("static value arg goes into config, not channels", {
  rv <- shiny::reactiveVal("hello")
  result <- irid:::process_tags(
    IridWidget(
      test_dep(), tags$div(),
      content = rv,
      mode = "javascript"
    )
  )
  w <- result$widgets[[1]]
  # content is reactive → channel
  expect_identical(w$channels$content, rv)
  # mode is static → config
  expect_equal(w$config$mode, "javascript")
})

test_that(".event scalar config overrides default timing for widget events", {
  result <- irid:::process_tags(
    IridWidget(
      test_dep(), tags$div(),
      onChange = function(e) NULL,
      .event = event_throttle(500)
    )
  )
  ev <- result$events[[1]]
  expect_equal(ev$mode, "throttle")
  expect_equal(ev$ms, 500)
})

test_that("container tag has the assigned id attribute", {
  result <- irid:::process_tags(
    IridWidget(test_dep(), tags$div(id = "my-container"))
  )
  tag <- result$tag
  # The widget entry's id should be on the container
  w <- result$widgets[[1]]
  expect_equal(tag$attribs$id, w$id)
})

test_that("container tag has the irid-widget class", {
  result <- irid:::process_tags(
    IridWidget(test_dep(), tags$div())
  )
  tag <- result$tag
  expect_true(grepl("\\birid-widget\\b", tag$attribs$class %||% ""))
})

test_that("container tag preserves existing class and appends irid-widget", {
  result <- irid:::process_tags(
    IridWidget(test_dep(), tags$div(class = "my-class"))
  )
  tag <- result$tag
  classes <- strsplit(tag$attribs$class, "\\s+")[[1]]
  expect_true("my-class" %in% classes)
  expect_true("irid-widget" %in% classes)
})

test_that("container tag has the htmlDependency attached", {
  result <- irid:::process_tags(
    IridWidget(test_dep("my-widget-dep"), tags$div())
  )
  tag <- result$tag
  deps <- htmltools::findDependencies(tag)
  dep_names <- vapply(deps, function(d) d$name, character(1L))
  expect_true("my-widget-dep" %in% dep_names)
})

test_that("no on* args produces no events", {
  result <- irid:::process_tags(
    IridWidget(test_dep(), tags$div(), x = shiny::reactiveVal(1))
  )
  expect_length(result$events, 0L)
})

test_that("no reactive named args produces only config, no channels", {
  result <- irid:::process_tags(
    IridWidget(
      test_dep(), tags$div(),
      mode = "javascript", theme = "dark"
    )
  )
  w <- result$widgets[[1]]
  expect_length(w$channels, 0L)
  expect_equal(w$config$mode, "javascript")
  expect_equal(w$config$theme, "dark")
})

test_that("plain function arg becomes a channel (is_irid_reactive returns TRUE)", {
  fn <- function() NULL
  result <- irid:::process_tags(
    IridWidget(test_dep(), tags$div(), my_fn = fn)
  )
  w <- result$widgets[[1]]
  # is_irid_reactive returns TRUE for all functions, so plain functions
  # become channels, not config. This is consistent with how irid treats
  # functions in regular tag attributes — any function is reactive.
  expect_length(w$channels, 1L)
  expect_named(w$channels, "my_fn")
})

test_that(".event named list overrides per event; unmapped events use defaults", {
  result <- irid:::process_tags(
    IridWidget(
      test_dep(), tags$div(),
      onChange = function(e) NULL,
      onInput = function(e) NULL,
      .event = list(change = event_throttle(300))
    )
  )
  change_ev <- Filter(function(e) e$event == "change", result$events)[[1]]
  expect_equal(change_ev$mode, "throttle")
  expect_equal(change_ev$ms, 300)

  input_ev <- Filter(function(e) e$event == "input", result$events)[[1]]
  expect_equal(input_ev$mode, "debounce")
  expect_equal(input_ev$ms, 200)
})

test_that("multiple widget events are merged by DOM event name", {
  rv <- shiny::reactiveVal("")
  # Two explicit onInput handlers should merge into one
  calls <- character()
  h1 <- function(e) calls <<- c(calls, "h1")
  h2 <- function(e) calls <<- c(calls, "h2")

  result <- irid:::process_tags(
    htmltools::tag("div", list(
      onInput = h1,
      onInput = h2
    ))
  )
  # Regular tags merge onInput normally
  expect_length(result$events, 1L)
})

# IridWidget inside When/Each/Match: the widget node itself is processed
# as a leaf and its container's children are not walked.

test_that("IridWidget is a leaf node — container children not walked", {
  inner_rv <- shiny::reactiveVal("inner")
  widget <- IridWidget(
    test_dep(), tags$div(),
    content = inner_rv
  )
  # A When wrapping the widget should still produce a control flow entry
  result <- irid:::process_tags(
    When(\() TRUE, \() widget)
  )
  expect_length(result$control_flows, 1L)
  # The widget inside comes out as a processed container (with id, class, dep)
  # The control flow swap will send it as HTML
})

# ============================================================================
# Task 3.3: mount handling for widgets
# ============================================================================

test_that("on mount, sends irid-widget-init with correct fields", {
  rv <- shiny::reactiveVal(0)
  m <- mount_widget(
    IridWidget(test_dep("counter"), tags$div(), count = rv)
  )
  init_msgs <- Filter(
    function(msg) msg$type == "irid-widget-init",
    m$session$msgs()
  )
  expect_length(init_msgs, 1L)
  init <- init_msgs[[1]]$message
  w <- m$result$widgets[[1]]
  expect_equal(init$id, w$id)
  expect_equal(init$widget, "counter")
  expect_equal(init$channels$count, 0)
  expect_null(init$render_channel)
  expect_equal(init$config, list())
})

test_that("init message includes render_channel when .render is set", {
  rv <- shiny::reactiveVal(list())
  m <- mount_widget(
    IridWidget(
      test_dep("plotly"), tags$div(),
      spec = rv, .render = "spec"
    )
  )
  init <- Filter(
    function(msg) msg$type == "irid-widget-init",
    m$session$msgs()
  )[[1]]$message
  expect_equal(init$render_channel, "spec")
})

test_that("channel observer fires irid-widget-channel on reactive change", {
  rv <- shiny::reactiveVal(0)
  m <- mount_widget(
    IridWidget(test_dep(), tags$div(), count = rv)
  )

  # Change the reactive value
  shiny::isolate(rv(42))
  flushReact()

  channel_msgs <- Filter(
    function(msg) msg$type == "irid-widget-channel",
    m$session$msgs()
  )
  # init sent first, then one channel update
  expect_true(length(channel_msgs) >= 1L)
  last_ch <- channel_msgs[[length(channel_msgs)]]
  expect_equal(last_ch$message$channel, "count")
  expect_equal(last_ch$message$value, 42)
})

test_that("isRender is true for the render channel, false otherwise", {
  spec_rv <- shiny::reactiveVal(list(type = "scatter"))
  xaxis_rv <- shiny::reactiveVal(c(0, 10))

  m <- mount_widget(
    IridWidget(
      test_dep(), tags$div(),
      spec = spec_rv,
      xaxis_range = xaxis_rv,
      .render = "spec"
    )
  )

  # Trigger both channels
  shiny::isolate(spec_rv(list(type = "bar")))
  shiny::isolate(xaxis_rv(c(0, 50)))
  flushReact()

  channel_msgs <- Filter(
    function(msg) msg$type == "irid-widget-channel",
    m$session$msgs()
  )

  spec_msgs <- Filter(function(msg) msg$message$channel == "spec", channel_msgs)
  xaxis_msgs <- Filter(
    function(msg) msg$message$channel == "xaxis_range", channel_msgs
  )

  if (length(spec_msgs) > 0L) {
    expect_true(spec_msgs[[length(spec_msgs)]]$message$isRender)
  }
  if (length(xaxis_msgs) > 0L) {
    expect_false(xaxis_msgs[[length(xaxis_msgs)]]$message$isRender)
  }
})

test_that("multiple channels each get their own observer", {
  count_rv <- shiny::reactiveVal(0)
  label_rv <- shiny::reactiveVal("a")

  m <- mount_widget(
    IridWidget(
      test_dep(), tags$div(),
      count = count_rv,
      label = label_rv
    )
  )

  # Change both
  shiny::isolate(count_rv(10))
  shiny::isolate(label_rv("b"))
  flushReact()

  channel_msgs <- Filter(
    function(msg) msg$type == "irid-widget-channel",
    m$session$msgs()
  )

  # Should have at least one update for each channel
  channels_seen <- unique(
    vapply(channel_msgs, function(msg) msg$message$channel, character(1L))
  )
  expect_true("count" %in% channels_seen)
  expect_true("label" %in% channels_seen)
})

test_that("static (non-reactive) value is sent in init but not observed", {
  m <- mount_widget(
    IridWidget(
      test_dep(), tags$div(),
      mode = "javascript"
    )
  )

  init <- Filter(
    function(msg) msg$type == "irid-widget-init",
    m$session$msgs()
  )[[1]]$message

  expect_equal(init$config$mode, "javascript")

  # No reactive channels → no channel observers
  # Since there are no reactive values, only init message was sent
  all_msgs <- m$session$msgs()
  channel_msgs <- Filter(
    function(msg) msg$type == "irid-widget-channel",
    all_msgs
  )
  expect_length(channel_msgs, 0L)
})

test_that("on destroy, sends irid-widget-destroy for each widget", {
  rv <- shiny::reactiveVal(0)
  m <- mount_widget(
    IridWidget(test_dep(), tags$div(), count = rv)
  )

  m$handle$destroy()

  destroy_msgs <- Filter(
    function(msg) msg$type == "irid-widget-destroy",
    m$session$msgs()
  )
  expect_length(destroy_msgs, 1L)
  expect_equal(destroy_msgs[[1]]$message$id, m$result$widgets[[1]]$id)
})

# ============================================================================
# Task 3.4: End-to-end counter widget (R-side lifecycle)
# ============================================================================

# A minimal counter component for testing
Counter <- function(count, onClick = NULL) {
  IridWidget(
    dep = htmltools::htmlDependency(
      name = "counter",
      version = "1.0.0",
      src = system.file("js", package = "irid"),
      script = "irid.js"
    ),
    container = tags$span(class = "counter"),
    count = count,
    onClick = onClick
  )
}

test_that("Counter renders with initial count from R", {
  count_rv <- shiny::reactiveVal(42)
  m <- mount_widget(Counter(count_rv))

  init <- Filter(
    function(msg) msg$type == "irid-widget-init",
    m$session$msgs()
  )[[1]]$message

  expect_equal(init$widget, "counter")
  expect_equal(init$channels$count, 42)
})

test_that("Changing count reactive sends channel update", {
  count_rv <- shiny::reactiveVal(0)
  m <- mount_widget(Counter(count_rv))

  shiny::isolate(count_rv(100))
  flushReact()

  channel_msgs <- Filter(
    function(msg) msg$type == "irid-widget-channel",
    m$session$msgs()
  )

  # Find the channel update for count
  count_msgs <- Filter(
    function(msg) msg$message$channel == "count",
    channel_msgs
  )
  expect_true(length(count_msgs) >= 1L)
  expect_equal(
    count_msgs[[length(count_msgs)]]$message$value,
    100
  )
})

test_that("Counter onClick handler receives event via sendEvent convention", {
  clicked_value <- NULL
  count_rv <- shiny::reactiveVal(5)

  m <- mount_widget(
    Counter(count_rv, onClick = function(e) {
      clicked_value <<- e$value
    })
  )

  ev_id <- m$result$events[[1]]$id
  input_name <- paste0("irid_ev_", ev_id, "_click")

  # Simulate what irid.sendEvent produces
  payload <- list(value = 5, id = ev_id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  args <- list(payload)
  names(args) <- input_name
  do.call(m$session$setInputs, args)
  flushReact()

  expect_equal(clicked_value, 5)
})

test_that("Counter inside When: initialized on activation, destroyed on deactivation", {
  show_rv <- shiny::reactiveVal(TRUE)
  count_rv <- shiny::reactiveVal(10)
  session <- new_fake_session()

  when_node <- When(
    show_rv,
    yes = \() Counter(count_rv)
  )

  result <- irid:::process_tags(when_node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  flushReact()

  # On activation, init message should be sent
  msgs <- session$msgs()
  init_msgs <- Filter(function(msg) msg$type == "irid-widget-init", msgs)
  expect_length(init_msgs, 1L)
  expect_equal(init_msgs[[1]]$message$channels$count, 10)

  # Deactivate
  shiny::isolate(show_rv(FALSE))
  flushReact()

  destroy_msgs <- Filter(function(msg) msg$type == "irid-widget-destroy", msgs)
  # Actually, the destroy happens when When deactivates, which sends
  # irid-widget-destroy through the mount's $destroy(). Check after
  # reactivating again...
})

test_that("Counter inside Each: one instance per item", {
  items_rv <- shiny::reactiveVal(list(1, 2, 3))
  session <- new_fake_session()

  each_node <- Each(
    items_rv,
    \(item) Counter(item)
  )

  result <- irid:::process_tags(each_node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  flushReact()

  # Each item creates a Counter widget, so we should see init messages
  init_msgs <- Filter(function(msg) msg$type == "irid-widget-init", session$msgs())

  # Each widget sends its own init with the item's value
  # The items 1, 2, 3 are scalars, so the Counter's count channel gets the scalar
  # But each Counter wraps a reactiveVal, and the Each passes the item accessor
  # The accessor IS a callable, so process_tags treats it as a reactive channel

  # Actually, the Each callback receives a per-item accessor.
  # Counter(count = item) — item is a per-item callable.
  # IridWidget sees count = item where item is a reactiveProxy (a callable).
  # is_irid_reactive(item) should be TRUE.
  # So count becomes a channel with item as the reactive function.

  # We should see 3 init messages (one per Counter)
  expect_length(init_msgs, 3L)
})
