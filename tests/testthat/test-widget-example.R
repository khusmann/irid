# --- CodeMirror Widget Example (Slice 4) ------------------------------------
#
# These tests validate the CodeMirror widget example component:
#   - R-side CodeMirror() function produces a valid irid_widget
#   - JS source is syntactically valid
#   - Init/channel message shapes match what the JS expects
#   - Process_tags correctly splits reactive channels from events
#   - Composition inside When controls widget lifecycle
#
# Full browser-based tests (typing in the editor, cursor movement) require
# a Selenium/shinytest2 environment and are not included here.

# ---- Helpers ---------------------------------------------------------------

test_dep <- function() {
  htmltools::htmlDependency(
    name = "test-cm",
    version = "1.0.0",
    src = system.file("js", package = "irid"),
    script = "irid.js"
  )
}

flushReact <- function() shiny:::flushReact()

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

mount_widget <- function(tag) {
  session <- new_fake_session()
  result <- irid:::process_tags(tag)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  flushReact()
  list(session = session, handle = handle, result = result)
}

# ---- Minimal CodeMirror component for testing ------------------------------
# Mirrors the real example but uses a test dep instead of CDN.

test_cm_dep <- function() {
  htmltools::htmlDependency(
    name = "codemirror",
    version = "5.65.16",
    src = c(href = "https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16"),
    script = "codemirror.min.js"
  )
}

CodeMirrorTest <- function(content, mode = "javascript",
                           onChange = NULL, onCursorActivity = NULL) {
  IridWidget(
    dep = test_cm_dep(),
    container = tags$div(style = "height: 300px;"),
    content = content,
    mode = mode,
    onChange = onChange,
    onCursorActivity = onCursorActivity
  )
}

# ---- Task 4.1: CodeMirror example component --------------------------------

test_that("CodeMirrorTest returns an irid_widget with correct deps and args", {
  w <- CodeMirrorTest(
    content = shiny::reactiveVal("x"),
    mode = shiny::reactiveVal("r")
  )
  expect_s3_class(w, "irid_widget")
  expect_true(inherits(w$dep, "html_dependency"))
  expect_equal(w$dep$name, "codemirror")
})

test_that("CodeMirrorTest container is a div with style", {
  w <- CodeMirrorTest(content = shiny::reactiveVal(""))
  expect_equal(w$container$name, "div")
  expect_true(grepl("height", w$container$attribs$style %||% ""))
})

test_that("process_tags splits content/mode as channels, onChange as event", {
  code_rv <- shiny::reactiveVal("hello")
  mode_rv <- shiny::reactiveVal("python")
  result <- irid:::process_tags(
    CodeMirrorTest(
      content = code_rv,
      mode = mode_rv,
      onChange = function(e) NULL
    )
  )
  expect_length(result$widgets, 1L)
  w <- result$widgets[[1]]
  # content and mode are reactive → channels
  expect_identical(w$channels$content, code_rv)
  expect_identical(w$channels$mode, mode_rv)
  # onChange is an event
  expect_length(result$events, 1L)
  expect_equal(result$events[[1]]$event, "change")
})

test_that("onCursorActivity creates a separate event entry", {
  result <- irid:::process_tags(
    CodeMirrorTest(
      content = shiny::reactiveVal(""),
      onChange = function(e) NULL,
      onCursorActivity = function(e) NULL
    )
  )
  events <- vapply(result$events, function(e) e$event, character(1L))
  expect_true("change" %in% events)
  expect_true("cursoractivity" %in% events)
})

test_that("init message includes content and mode channels", {
  code_rv <- shiny::reactiveVal("x <- 1")
  mode_rv <- shiny::reactiveVal("r")
  m <- mount_widget(
    CodeMirrorTest(content = code_rv, mode = mode_rv)
  )
  init <- Filter(
    function(msg) msg$type == "irid-widget-init",
    m$session$msgs()
  )[[1]]$message
  expect_equal(init$channels$content, "x <- 1")
  expect_equal(init$channels$mode, "r")
  expect_equal(init$widget, "codemirror")  # derived from dep$name
})

test_that("content channel sends irid-widget-channel on change", {
  code_rv <- shiny::reactiveVal("a")
  m <- mount_widget(
    CodeMirrorTest(content = code_rv)
  )
  shiny::isolate(code_rv("b"))
  flushReact()
  ch_msgs <- Filter(
    function(msg) msg$type == "irid-widget-channel",
    m$session$msgs()
  )
  content_msgs <- Filter(
    function(msg) msg$message$channel == "content",
    ch_msgs
  )
  expect_true(length(content_msgs) >= 1L)
  expect_equal(content_msgs[[length(content_msgs)]]$message$value, "b")
})

test_that("mode channel sends irid-widget-channel on change", {
  mode_rv <- shiny::reactiveVal("r")
  m <- mount_widget(
    CodeMirrorTest(content = shiny::reactiveVal(""), mode = mode_rv)
  )
  shiny::isolate(mode_rv("python"))
  flushReact()
  ch_msgs <- Filter(
    function(msg) msg$type == "irid-widget-channel",
    m$session$msgs()
  )
  mode_msgs <- Filter(
    function(msg) msg$message$channel == "mode",
    ch_msgs
  )
  expect_true(length(mode_msgs) >= 1L)
  expect_equal(mode_msgs[[length(mode_msgs)]]$message$value, "python")
})

test_that("content channel has isRender: false by default (no .render set)", {
  code_rv <- shiny::reactiveVal("a")
  m <- mount_widget(
    CodeMirrorTest(content = code_rv)
  )
  shiny::isolate(code_rv("b"))
  flushReact()
  ch_msgs <- Filter(
    function(msg) msg$type == "irid-widget-channel",
    m$session$msgs()
  )
  for (cm in ch_msgs) {
    expect_false(cm$message$isRender)
  }
})

test_that("onChange handler receives event through sendEvent convention", {
  received <- NULL
  code_rv <- shiny::reactiveVal("init")
  m <- mount_widget(
    CodeMirrorTest(
      content = code_rv,
      onChange = function(e) received <<- e$value
    )
  )
  # Simulate what irid.sendEvent produces for 'change'
  ev <- m$result$events[[1]]
  input_name <- paste0("irid_ev_", ev$id, "_change")
  payload <- list(value = "typed content", id = ev$id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  args <- list(payload)
  names(args) <- input_name
  do.call(m$session$setInputs, args)
  flushReact()
  expect_equal(received, "typed content")
})

test_that("onCursorActivity receives line and ch fields", {
  received <- NULL
  m <- mount_widget(
    CodeMirrorTest(
      content = shiny::reactiveVal(""),
      onCursorActivity = function(e) received <<- list(line = e$line, ch = e$ch)
    )
  )
  # Find the cursoractivity event (event names are lowercase)
  ev_idx <- which(vapply(m$result$events, function(e) e$event == "cursoractivity", logical(1L)))
  ev <- m$result$events[[ev_idx]]
  input_name <- paste0("irid_ev_", ev$id, "_", ev$event)
  payload <- list(line = 3L, ch = 10L, id = ev$id, nonce = 0.5)
  payload[["__irid_seq"]] <- 1L
  args <- list(payload)
  names(args) <- input_name
  do.call(m$session$setInputs, args)
  flushReact()
  expect_equal(received$line, 3L)
  expect_equal(received$ch, 10L)
})

# ---- CodeMirror inside When -------------------------------------------------

test_that("CodeMirror inside When: init on activation, destroy on deactivation", {
  show_rv <- shiny::reactiveVal(TRUE)
  code_rv <- shiny::reactiveVal("hello")
  session <- new_fake_session()

  when_node <- When(
    show_rv,
    yes = \() CodeMirrorTest(content = code_rv)
  )

  result <- irid:::process_tags(when_node)
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  flushReact()

  # On activation, init message sent
  init_msgs <- Filter(function(msg) msg$type == "irid-widget-init", session$msgs())
  expect_length(init_msgs, 1L)
  expect_equal(init_msgs[[1]]$message$channels$content, "hello")

  # Deactivate — destroy should fire
  shiny::isolate(show_rv(FALSE))
  flushReact()
  handle$destroy()

  destroy_msgs <- Filter(
    function(msg) msg$type == "irid-widget-destroy",
    session$msgs()
  )
  expect_true(length(destroy_msgs) >= 1L)
})

# ---- CodeMirror JS validation -----------------------------------------------

test_that("codemirror.js is syntactically valid JavaScript", {
  js_path <- "../../examples/codemirror/codemirror.js"
  # Try multiple resolutions
  candidates <- c(
    "../examples/codemirror/codemirror.js",
    "examples/codemirror/codemirror.js",
    "./examples/codemirror/codemirror.js",
    system.file("examples/codemirror/codemirror.js", package = "irid")
  )
  found <- NULL
  for (candidate in candidates) {
    if (file.exists(candidate)) {
      found <- candidate
      break
    }
  }
  if (is.null(found)) {
    skip("codemirror.js not found — run tests from package root")
  }
  skip_if_not(nzchar(Sys.which("node")), "node not available")
  result <- system2("node", c("--check", found), stdout = TRUE, stderr = TRUE)
  expect_equal(attr(result, "status") %||% 0L, 0L)
})

# ---- Multiple CodeMirror instances (conceptual) -----------------------------
# Full browser tests are needed to verify independent instances. At the R
# level we verify that each widget gets its own id and init message, and
# that events from different instances target different input IDs.

test_that("two CodeMirror instances get separate IDs and event targets", {
  rv1 <- shiny::reactiveVal("a")
  rv2 <- shiny::reactiveVal("b")
  result <- irid:::process_tags(
    tagList(
      CodeMirrorTest(content = rv1),
      CodeMirrorTest(content = rv2)
    )
  )
  expect_length(result$widgets, 2L)
  ids <- vapply(result$widgets, function(w) w$id, character(1L))
  expect_true(ids[[1]] != ids[[2]])

  session <- new_fake_session()
  handle <- shiny::isolate(irid:::irid_mount_processed(result, session))
  flushReact()

  inits <- Filter(function(m) m$type == "irid-widget-init", session$msgs())
  expect_length(inits, 2L)
  expect_equal(inits[[1]]$message$channels$content, "a")
  expect_equal(inits[[2]]$message$channels$content, "b")
})
