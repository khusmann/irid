# Tests for the per-session renderUI dep sink (`install_widget_dep_sink` /
# `feed_widget_dep_sink` in mount.R) — the native-render-pipeline path that
# delivers a widget's dependencies so they load under shinylive, INCLUDING a
# widget mounted only inside `When`/`Each`/`Match` (the case issue #34 could not
# serve). Deps no longer page-attach at render, nor ride the `irid-widget-init`
# custom message.

library(shiny)

# Read the sink's accumulated deps (name -> html_dependency) off a session.
sink_deps <- function(session) isolate(session$userData$irid_deps_seen())

mk_dep <- function(name, ...) {
  htmltools::htmlDependency(name, "1.0", src = c(href = "https://x/"),
                            script = "a.js", ...)
}

# --- feed/dedup ---------------------------------------------------------------

test_that("feed_widget_dep_sink installs the sink and stores deps by name", {
  session <- MockShinySession$new()
  dep <- mk_dep("lib")
  withReactiveDomain(session, feed_widget_dep_sink(session, list(dep)))

  expect_true(isTRUE(session$userData$irid_dep_sink))
  seen <- sink_deps(session)
  expect_named(seen, "lib")
  expect_identical(seen$lib, dep)
})

test_that("empty deps neither install the sink nor error", {
  session <- MockShinySession$new()
  withReactiveDomain(session, feed_widget_dep_sink(session, list()))
  expect_null(session$userData$irid_dep_sink)
})

test_that("deps are deduped by name across feeds (shared library added once)", {
  session <- MockShinySession$new()
  shared1 <- mk_dep("plotly")
  shared2 <- mk_dep("plotly")          # same name, e.g. another Each item
  other   <- mk_dep("d3")
  withReactiveDomain(session, {
    feed_widget_dep_sink(session, list(shared1))
    feed_widget_dep_sink(session, list(shared2, other))
  })
  seen <- sink_deps(session)
  expect_setequal(names(seen), c("plotly", "d3"))
  expect_identical(seen$plotly, shared1)  # first wins; not overwritten
})

test_that("package/file-backed deps are stored verbatim (sink resolves at render)", {
  # The native pipeline resolves `package` + `src$file` itself, so the sink
  # carries the raw dep — no pre-registration (the old `register_widget_dep`).
  session <- MockShinySession$new()
  dep <- htmltools::htmlDependency(
    name = "pkgdep", version = "1.0",
    src = c(file = "htmlwidgets/lib/x"), script = "x.js", package = "somepkg"
  )
  withReactiveDomain(session, feed_widget_dep_sink(session, list(dep)))
  stored <- sink_deps(session)$pkgdep
  expect_equal(stored$package, "somepkg")
  expect_equal(stored$src$file, "htmlwidgets/lib/x")
})

# --- mount integration --------------------------------------------------------

test_that("a widget mounted only inside control flow reaches the sink (#34)", {
  # The widget is behind a `When` closure, so process_tags never walks it and
  # its dep is not on the static page. It must still reach the sink the moment
  # the control-flow observer mounts it — exactly the dynamic-only case #34
  # could not serve under shinylive.
  session <- MockShinySession$new()
  dep <- mk_dep("mylib")
  processed <- process_tags(tags$div(
    When(\() TRUE, \() IridWidget("demo", deps = dep))
  ))
  # The dep is NOT collected onto the static tag (closure not walked).
  found <- htmltools::findDependencies(processed$tag)
  expect_false(any(vapply(found, function(d) identical(d$name, "mylib"), logical(1))))

  withReactiveDomain(session, {
    irid_mount_processed(processed, session)
    session$flushReact()
  })
  expect_identical(sink_deps(session)$mylib, dep)
})

test_that("an Each over many items feeds a shared dep to the sink once", {
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
  seen <- sink_deps(session)
  expect_named(seen, "plotly")           # one entry despite three mounts
})

test_that("the irid-widget-init message no longer carries deps", {
  # A deps-free widget needs no sink, so a plain stub session captures the
  # init message shape directly.
  sent <- list()
  fake <- list(
    sendCustomMessage = function(type, msg) {
      sent[[length(sent) + 1L]] <<- list(type = type, msg = msg)
    },
    input = list(), output = list(), userData = new.env(),
    ns = identity, onFlushed = function(fn, once = TRUE) invisible()
  )
  irid_mount_processed(process_tags(IridWidget("demo")), fake)

  init <- Filter(function(m) m$type == "irid-widget-init", sent)
  expect_length(init, 1L)
  expect_false("deps" %in% names(init[[1]]$msg))
  expect_named(init[[1]]$msg, c("id", "name", "props"))
})
