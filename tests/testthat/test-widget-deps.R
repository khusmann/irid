# Tests for `register_widget_dep` — the bridge that turns each
# widget-supplied `htmlDependency` into something `Shiny.renderDependencies`
# can fetch from the running app.
#
# UI-attached deps get auto-registered as Shiny static resources;
# deps shipped via the `irid-widget-init` custom message do not, so the
# mount path runs each one through `register_widget_dep` first.

# --- href-only deps pass through ---------------------------------------------

test_that("href-only dep is returned unchanged", {
  # CDN-style — no server resource needed, no createWebDependency call.
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

# --- Package-relative deps get resolved + registered -------------------------

test_that("package + src$file resolves to absolute path and registers", {
  skip_if_not_installed("plotly")
  dep <- htmltools::htmlDependency(
    name = paste0("test-plotly-main-", as.integer(Sys.time())),
    version = "2.25.2",
    src = c(file = "htmlwidgets/lib/plotlyjs"),
    script = "plotly-latest.min.js",
    package = "plotly"
  )
  out <- register_widget_dep(dep)

  # After registration, src is an href (Shiny serves it at that URL).
  expect_null(out$src$file)
  expect_true(!is.null(out$src$href))
  expect_null(out$package)
  expect_equal(out$name, dep$name)
  expect_equal(out$version, dep$version)

  # The href was added to Shiny's resource paths.
  expect_true(out$src$href %in% names(shiny::resourcePaths()))
})

test_that("absolute src$file with no package still registers", {
  # Mirrors the irid-shipped widget asset case (`system.file("widgets/...")`
  # in plotly_irid_dependency).
  tmp <- tempfile("irid-widget-asset-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE))
  writeLines("// stub", file.path(tmp, "factory.js"))

  dep <- htmltools::htmlDependency(
    name = paste0("test-abs-", as.integer(Sys.time())),
    version = "0.0.1",
    src = c(file = tmp),
    script = "factory.js"
  )
  out <- register_widget_dep(dep)

  expect_null(out$src$file)
  expect_true(!is.null(out$src$href))
  expect_true(out$src$href %in% names(shiny::resourcePaths()))
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
    "Could not locate the 'this-package-does-not-exist-9999' package"
  )
})

# --- Integration: mount sends resolved deps on irid-widget-init -------------

test_that("mount runs each widget dep through register_widget_dep before sending init", {
  # Use an absolute-src dep so registration is observable (the href shows
  # up in resourcePaths). The init message's `deps` field should carry
  # the registered (href-shape) dep, not the unresolved (file-shape) one.
  tmp <- tempfile("irid-widget-asset-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE))
  writeLines("// stub", file.path(tmp, "factory.js"))

  dep <- htmltools::htmlDependency(
    name = paste0("test-mount-", as.integer(Sys.time())),
    version = "0.0.1",
    src = c(file = tmp),
    script = "factory.js"
  )

  # Capture custom messages sent through a stub session.
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
  expect_null(init_deps[[1]]$src$file)
  expect_true(!is.null(init_deps[[1]]$src$href))
})
