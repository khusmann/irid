# App entry points (R/app.R): iridApp (UI + server passes), iridOutput,
# renderIrid, and the irid_send_config helper. Driven without a browser via
# MockShinySession / testServer.

render_app_ui <- function(app) {
  req <- list(
    REQUEST_METHOD = "GET", PATH_INFO = "/", QUERY_STRING = "",
    HTTP_HOST = "x", SERVER_NAME = "x", SERVER_PORT = "1",
    rook.url_scheme = "http"
  )
  resp <- app$httpHandler(req)
  if (is.character(resp$content)) resp$content else rawToChar(resp$content)
}

# --- irid_send_config --------------------------------------------------------

test_that("irid_send_config sends irid-config with the stale-timeout option", {
  s <- new_fake_session()
  withr::with_options(
    list(irid.stale_timeout = 500),
    irid:::irid_send_config(s)
  )
  cfg <- Filter(function(m) m$type == "irid-config", s$msgs())
  expect_length(cfg, 1L)
  expect_equal(cfg[[1]]$message$staleTimeout, 500)
})

test_that("irid_send_config defaults the stale timeout to 200", {
  s <- new_fake_session()
  withr::with_options(
    list(irid.stale_timeout = NULL),
    irid:::irid_send_config(s)
  )
  cfg <- Filter(function(m) m$type == "irid-config", s$msgs())
  expect_equal(cfg[[1]]$message$staleTimeout, 200)
})

# --- iridApp -----------------------------------------------------------------

test_that("iridApp returns a shiny app whose UI carries the irid dependency", {
  fn <- function() {
    shiny::tags$div(
      `data-y` = function() "z",
      shiny::tags$input(value = shiny::reactiveVal("hi"))
    )
  }
  app <- iridApp(fn)
  expect_s3_class(app, "shiny.appobj")

  body <- render_app_ui(app)
  expect_match(body, "irid")             # JS/CSS dependency injected
  expect_match(body, "irid-[0-9]+")      # auto-generated element ids present
})

test_that("iridApp UI and server passes produce matching element ids", {
  # ui() and server() each call process_tags(fn()) independently; the
  # deterministic id counter makes their ids line up so the server's bindings
  # target the elements the UI rendered.
  fn <- function() {
    shiny::tags$div(
      `data-y` = function() "z",
      shiny::tags$input(value = shiny::reactiveVal("hi"))
    )
  }
  body <- render_app_ui(iridApp(fn))
  ui_ids <- unique(regmatches(body, gregexpr("irid-[0-9]+", body))[[1]])

  # The server side walks fn() through the same deterministic process_tags.
  binding_ids <- vapply(process_tags(fn())$bindings, function(b) b$id, character(1))
  expect_gt(length(binding_ids), 0L)  # guard against a vacuous all() pass
  expect_true(all(binding_ids %in% ui_ids))
})

test_that("iridApp server sends config synchronously and wires the tree", {
  rv <- shiny::reactiveVal("hi")
  fn <- function() shiny::tags$input(value = rv)
  app <- iridApp(fn)

  s <- new_fake_session()
  server_fn <- app$serverFuncSource()
  shiny::isolate(server_fn(s$input, s$output, s))
  s$flushReact()

  types <- vapply(s$msgs(), function(m) m$type, character(1))
  expect_true("irid-config" %in% types)  # sent before mounting
  expect_true("irid-events" %in% types)  # the value autobind registered an event
})

# --- iridOutput --------------------------------------------------------------

test_that("iridOutput attaches the irid dependency to a uiOutput", {
  out <- iridOutput("slot")
  deps <- htmltools::findDependencies(out)
  expect_true(any(vapply(deps, function(d) grepl("irid", d$name), logical(1))))
  expect_match(as.character(out), "slot")  # the output id is preserved
})

# --- renderIrid --------------------------------------------------------------

test_that("renderIrid renders the processed tag tree as the output's HTML", {
  rv <- shiny::reactiveVal("hi")
  server <- function(input, output, session) {
    output$content <- renderIrid(shiny::tags$input(value = rv))
  }
  shiny::testServer(server, {
    out <- session$getOutput("content")
    session$flushReact()  # fire the onFlushed config + mount callback
    html <- out$html
    expect_true(nchar(html) > 0)
    expect_match(html, "content-[0-9]+")  # processed: output-scoped id present
  })
})

test_that("renderIrid isolates its UI expression (no reactive dep on render)", {
  # The UI expression is evaluated under isolate(), so a reactive read inside it
  # does not re-run the render — bindings carry updates instead.
  txt <- shiny::reactiveVal("a")
  renders <- 0L
  server <- function(input, output, session) {
    output$content <- renderIrid({
      renders <<- renders + 1L
      shiny::tags$p(txt())
    })
  }
  shiny::testServer(server, {
    session$getOutput("content")
    expect_equal(renders, 1L)

    txt("b")
    session$flushReact()
    session$getOutput("content")
    expect_equal(renders, 1L)  # isolated — txt change did not re-render
  })
})
