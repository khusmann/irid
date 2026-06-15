# Tests for `register_widget_dep` — the bridge that turns each
# widget-supplied `htmlDependency` into something `Shiny.renderDependencies`
# can load from the `irid-widget-init` message.
#
# UI-attached deps get auto-registered as Shiny static resources; deps shipped
# via the custom message do not, and shinylive won't serve a resource path
# registered mid-session. So `register_widget_dep` inlines each file-backed
# dep's script/stylesheet into its `head` HTML — no resource path at all.

# --- href-only deps pass through ---------------------------------------------

test_that("href-only dep is returned unchanged", {
  # CDN-style — no file to inline, nothing to do.
  dep <- htmltools::htmlDependency(
    name = "cdn-thing", version = "1.0",
    src = c(href = "https://example.com/"),
    script = "lib.js"
  )
  out <- register_widget_dep(dep)
  expect_identical(out, dep)
})

test_that("head-only dep (no src) is returned unchanged", {
  # CodeMirror-style — a raw `<script type=module>` injected via `head`,
  # no src to resolve.
  dep <- htmltools::htmlDependency(
    name = "head-only", version = "1.0",
    src = c(href = "https://example.com/"),
    head = htmltools::HTML("<script>/* inline */</script>")
  )
  out <- register_widget_dep(dep)
  expect_identical(out, dep)
})

# --- File-backed deps get inlined into `head` --------------------------------

test_that("package + src$file inlines the script into head (no resource path)", {
  skip_if_not_installed("plotly")
  dep <- htmltools::htmlDependency(
    name = "test-plotly-main", version = "2.25.2",
    src = c(file = "htmlwidgets/lib/plotlyjs"),
    script = "plotly-latest.min.js",
    package = "plotly"
  )
  out <- register_widget_dep(dep)

  # No resource path: src/script/package are all gone, content lives in head.
  # (Assert with startsWith/endsWith, not expect_match — testthat's matcher is
  # pathologically slow on the multi-MB plotly bundle.)
  expect_null(out$src)
  expect_null(out$script)
  expect_null(out$package)
  expect_true(startsWith(out$head, "<script>"))
  expect_true(endsWith(out$head, "</script>"))
  expect_gt(nchar(out$head), 1000L)        # the real plotly bundle
  expect_equal(out$name, dep$name)
  expect_equal(out$version, dep$version)

  # Nothing was added to Shiny's resource paths.
  expect_false("test-plotly-main-2.25.2" %in% names(shiny::resourcePaths()))
})

test_that("absolute src$file with no package inlines too", {
  # Mirrors the irid-shipped widget asset case (`system.file("widgets/...")`).
  tmp <- tempfile("irid-widget-asset-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE))
  writeLines("/* STUB-FACTORY */", file.path(tmp, "factory.js"))

  dep <- htmltools::htmlDependency(
    name = "test-abs", version = "0.0.1",
    src = c(file = tmp),
    script = "factory.js"
  )
  out <- register_widget_dep(dep)

  expect_null(out$src)
  expect_null(out$script)
  expect_match(out$head, "STUB-FACTORY", fixed = TRUE)
})

test_that("a stylesheet is inlined as <style>", {
  tmp <- tempfile("irid-widget-css-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE))
  writeLines(".sentinel { color: red; }", file.path(tmp, "thing.css"))

  dep <- htmltools::htmlDependency(
    name = "test-css", version = "0.0.1",
    src = c(file = tmp),
    stylesheet = "thing.css"
  )
  out <- register_widget_dep(dep)

  expect_null(out$src)
  expect_null(out$stylesheet)
  expect_match(out$head, "<style>.sentinel", fixed = TRUE)
})

test_that("a literal </script> in the source is escaped so it can't close the tag", {
  tmp <- tempfile("irid-widget-evil-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE))
  writeLines('var s = "</script>";', file.path(tmp, "evil.js"))

  dep <- htmltools::htmlDependency(
    name = "test-evil", version = "0.0.1",
    src = c(file = tmp),
    script = "evil.js"
  )
  out <- register_widget_dep(dep)

  expect_match(out$head, "<\\/script>", fixed = TRUE)        # escaped form present
  # The only real (tag-closing) </script> is the one we wrote as the wrapper.
  expect_equal(lengths(regmatches(out$head, gregexpr("</script>", out$head, fixed = TRUE))), 1L)
})

# --- Failure mode ------------------------------------------------------------

test_that("missing package errors with a clear message", {
  dep <- htmltools::htmlDependency(
    name = "needs-missing-pkg", version = "1.0",
    src = c(file = "lib"),
    script = "x.js",
    package = "this-package-does-not-exist-9999"
  )
  expect_error(
    register_widget_dep(dep),
    "Could not locate the this-package-does-not-exist-9999 package"
  )
})

# --- Per-session dedupe ------------------------------------------------------

test_that("widget_deps_to_send drops a dep already sent this session", {
  tmp <- tempfile("irid-widget-dedupe-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE))
  writeLines("/* once */", file.path(tmp, "lib.js"))

  dep <- htmltools::htmlDependency(
    name = "test-dedupe", version = "0.0.1",
    src = c(file = tmp), script = "lib.js"
  )
  session <- list(userData = new.env())

  first <- widget_deps_to_send(list(dep), session)
  expect_length(first, 1L)
  expect_match(first[[1]]$head, "once", fixed = TRUE)

  # Same name@version again -> nothing re-sent.
  second <- widget_deps_to_send(list(dep), session)
  expect_length(second, 0L)

  # A bumped version is a different key -> sent again.
  dep2 <- htmltools::htmlDependency(
    name = "test-dedupe", version = "0.0.2",
    src = c(file = tmp), script = "lib.js"
  )
  third <- widget_deps_to_send(list(dep2), session)
  expect_length(third, 1L)
})

# --- Integration: mount sends inlined deps on irid-widget-init ---------------

test_that("mount inlines each widget dep before sending init", {
  tmp <- tempfile("irid-widget-asset-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE))
  writeLines("/* MOUNT-STUB */", file.path(tmp, "factory.js"))

  dep <- htmltools::htmlDependency(
    name = "test-mount", version = "0.0.1",
    src = c(file = tmp),
    script = "factory.js"
  )

  sent <- list()
  fake_session <- list(
    sendCustomMessage = function(type, msg) {
      sent[[length(sent) + 1L]] <<- list(type = type, msg = msg)
    },
    input = list(),
    output = list(),
    userData = new.env(),
    onFlushed = function(fn, once = TRUE) invisible()
  )

  w <- IridWidget("test-widget", deps = dep)
  processed <- process_tags(w)
  irid_mount_processed(processed, fake_session)

  init <- Filter(function(m) m$type == "irid-widget-init", sent)
  expect_length(init, 1L)
  init_deps <- init[[1]]$msg$deps
  expect_length(init_deps, 1L)
  expect_null(init_deps[[1]]$src)
  expect_match(init_deps[[1]]$head, "MOUNT-STUB", fixed = TRUE)
})
