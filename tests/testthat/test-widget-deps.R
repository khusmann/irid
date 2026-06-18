# Tests for widget dependency delivery (`deliver_widget_deps` in mount.R) — the
# native-render-pipeline path (`insertUI`) that delivers a widget's deps so they
# load under shinylive, INCLUDING a widget mounted only inside When/Each/Match
# (the case issue #34 could not serve). Deps no longer page-attach at render, nor
# ride the `irid-widget-init` custom message.

library(shiny)

mk_dep <- function(name, ...) {
  htmltools::htmlDependency(name, "1.0", src = c(href = "https://x/"),
                            script = "a.js", ...)
}

# A stub session that records insertUI content + custom messages and runs
# onFlushed callbacks immediately, so `insertUI` delivers synchronously here.
recording_session <- function() {
  rec <- new.env()
  rec$inserts <- list()
  rec$messages <- list()
  session <- list(
    userData = new.env(),
    ns = identity,
    input = list(),
    output = list(),
    onFlushed = function(fn, once = TRUE) { fn(); invisible() },
    sendInsertUI = function(selector, multiple, where, content) {
      rec$inserts[[length(rec$inserts) + 1L]] <- list(content)
    },
    sendCustomMessage = function(type, msg) {
      rec$messages[[length(rec$messages) + 1L]] <- list(list(type = type, msg = msg))
    }
  )
  session$rec <- rec
  session
}

# Dep names carried by all recorded inserts, in order.
inserted_dep_names <- function(session) {
  unlist(lapply(session$rec$inserts, function(ins) {
    vapply(ins[[1]]$deps, function(d) d$name, character(1L))
  }))
}

# --- delivery / dedup --------------------------------------------------------

test_that("deps are delivered via insertUI and tracked by name", {
  s <- recording_session()
  deliver_widget_deps(s, list(mk_dep("lib")))
  expect_equal(inserted_dep_names(s), "lib")
  expect_equal(s$userData$irid_deps_seen, "lib")
})

test_that("empty deps deliver nothing and set no state", {
  s <- recording_session()
  deliver_widget_deps(s, list())
  expect_length(s$rec$inserts, 0L)
  expect_null(s$userData$irid_deps_seen)
})

test_that("deps are deduped by name across deliveries (shared library once)", {
  s <- recording_session()
  deliver_widget_deps(s, list(mk_dep("plotly")))
  deliver_widget_deps(s, list(mk_dep("plotly"), mk_dep("d3")))  # plotly repeats
  expect_equal(inserted_dep_names(s), c("plotly", "d3"))        # plotly inserted once
  expect_setequal(s$userData$irid_deps_seen, c("plotly", "d3"))
})

test_that("a package/file-backed dep is resolved + served by the native pipeline", {
  # No irid-side registration (the old `register_widget_dep`): handing the raw
  # `package` + `src$file` dep to insertUI, Shiny's `processDeps` resolves it to
  # an href and registers the resource path itself.
  skip_if_not_installed("plotly")
  s <- recording_session()
  dep <- htmltools::htmlDependency(
    name = paste0("test-plotly-main-", as.integer(Sys.time())),
    version = "2.25.2",
    src = c(file = "htmlwidgets/lib/plotlyjs"),
    script = "plotly-latest.min.js",
    package = "plotly"
  )
  deliver_widget_deps(s, list(dep))
  resolved <- s$rec$inserts[[1]][[1]]$deps[[1]]
  expect_false(is.null(resolved$src$href))
  expect_true(resolved$src$href %in% names(shiny::resourcePaths()))
})

# --- mount integration -------------------------------------------------------

test_that("a widget mounted only inside control flow reaches delivery (#34)", {
  # The widget is behind a `When` closure, so process_tags never walks it and its
  # dep is not on the static page. It must still reach delivery the moment the
  # control-flow observer mounts it — exactly the dynamic-only case #34 could not
  # serve under shinylive.
  session <- MockShinySession$new()
  dep <- mk_dep("mylib")
  processed <- process_tags(tags$div(
    When(\() TRUE, \() IridWidget("demo", deps = dep))
  ))
  found <- htmltools::findDependencies(processed$tag)
  expect_false(any(vapply(found, function(d) identical(d$name, "mylib"), logical(1))))

  withReactiveDomain(session, {
    irid_mount_processed(processed, session)
    session$flushReact()
  })
  expect_true("mylib" %in% session$userData$irid_deps_seen)
})

test_that("an Each over many items delivers a shared dep once", {
  session <- MockShinySession$new()
  dep <- mk_dep("plotly")
  items <- reactiveVal(list("a", "b", "c"))
  processed <- process_tags(tags$div(
    Each(items, \(x) IridWidget("plt", deps = dep))
  ))
  withReactiveDomain(session, {
    irid_mount_processed(processed, session)
    session$flushReact()
  })
  expect_equal(session$userData$irid_deps_seen, "plotly")  # one name, three mounts
})

test_that("the irid-widget-init message no longer carries deps", {
  s <- recording_session()
  irid_mount_processed(process_tags(IridWidget("demo")), s)

  msgs <- lapply(s$rec$messages, function(m) m[[1]])
  init <- Filter(function(m) m$type == "irid-widget-init", msgs)
  expect_length(init, 1L)
  expect_false("deps" %in% names(init[[1]]$msg))
  expect_named(init[[1]]$msg, c("id", "name", "props"))
})
