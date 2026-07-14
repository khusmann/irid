# Package names an example declares via top-level `library()`/`require()`,
# minus irid itself. Examples state their dependencies this way, so parsing
# those calls keeps the runner's dependency check in sync with the scripts
# automatically as examples are added or changed.
example_deps <- function(path) {
  exprs <- parse(path)
  pkgs <- character()
  for (e in exprs) {
    if (is.call(e) && is.name(e[[1L]]) &&
        as.character(e[[1L]]) %in% c("library", "require") &&
        length(e) >= 2L) {
      arg <- e[[2L]]
      pkgs <- c(pkgs, if (is.character(arg)) arg else as.character(arg))
    }
  }
  setdiff(unique(pkgs), "irid")
}

# Stop with an actionable message naming what to install, rather than letting
# the app fail partway through with a cryptic "there is no package called ..."
# once it hits the missing dependency.
check_example_deps <- function(path, example, call = rlang::caller_env()) {
  pkgs <- example_deps(path)
  missing <- pkgs[!vapply(
    pkgs,
    function(p) requireNamespace(p, quietly = TRUE),
    logical(1L)
  )]
  if (length(missing) == 0L) return(invisible())

  install_hint <- if (length(missing) == 1L) {
    sprintf('install.packages("%s")', missing)
  } else {
    sprintf(
      "install.packages(c(%s))",
      paste0('"', missing, '"', collapse = ", ")
    )
  }
  cli::cli_abort(
    c(
      "The {.val {example}} example needs {cli::qty(missing)}{?a package/some packages} that {?is/are} not installed: {.pkg {missing}}.",
      "i" = "Install {cli::qty(missing)}{?it/them} with {.code {install_hint}}."
    ),
    call = call
  )
}

#' Run a irid example application
#'
#' Launches one of the example apps shipped with the package, mirroring
#' [shiny::runExample()]. The examples are the same apps published as editable
#' editors on the package website.
#'
#' Called with no argument (or an unrecognised name), it lists the available
#' examples instead of launching one.
#'
#' Some examples depend on packages beyond irid's hard dependencies (e.g.
#' bslib, plotly). The runner checks for these up front and, if any are
#' missing, stops with a message naming what to install. A couple of examples
#' (`codemirror`, `plotly`) also load JavaScript from a CDN at runtime, so they
#' need an internet connection even when run locally.
#'
#' By default the app runs in Shiny's *showcase* display mode, so the annotated
#' source appears beside the running app (as with [shiny::runExample()]). Pass
#' `display.mode = "normal"` to run the app on its own.
#'
#' The remaining arguments mirror [shiny::runExample()].
#'
#' @param example Name of the example to run (e.g. `"todo"`, `"old-faithful"`)
#'   — the same name used in its website URL. If omitted, the available
#'   examples are listed.
#' @param port The TCP port the application should listen on. Defaults to
#'   `getOption("shiny.port")`, or a random port if unset.
#' @param launch.browser If `TRUE`, the system's default web browser is
#'   launched automatically. Defaults to `TRUE` in interactive sessions.
#' @param host The IPv4 address the application should listen on. Defaults to
#'   `getOption("shiny.host", "127.0.0.1")`.
#' @param display.mode The display mode. Defaults to `"showcase"` — the
#'   annotated source shown alongside the running app; use `"normal"` to run
#'   the app by itself, or `"auto"` to defer to the app's own setting.
#' @return If `example` is supplied, launches the app and blocks until it is
#'   stopped. Otherwise returns the available example names invisibly as a
#'   character vector (after listing them).
#' @examples
#' # List the available examples
#' iridExample()
#'
#' if (interactive()) {
#'   iridExample("todo")
#' }
#' @export
iridExample <- function(example = NA,
                        port = getOption("shiny.port"),
                        launch.browser = getOption("shiny.launch.browser", interactive()),
                        host = getOption("shiny.host", "127.0.0.1"),
                        display.mode = c("showcase", "normal", "auto")) {
  examples_dir <- system.file("examples", package = "irid")
  available <- sort(list.dirs(examples_dir, recursive = FALSE, full.names = FALSE))

  if (is.null(example)) example <- NA
  if (isTRUE(is.na(example)) || !example %in% available) {
    if (!isTRUE(is.na(example))) {
      cli::cli_warn("No irid example named {.val {example}}.")
    }
    cli::cli_inform(c(
      "Available irid examples:",
      stats::setNames(available, rep("*", length(available))),
      "i" = "Run one with e.g. {.code iridExample(\"{available[[1]]}\")}."
    ))
    return(invisible(available))
  }

  display.mode <- match.arg(display.mode)
  app_dir <- file.path(examples_dir, example)
  check_example_deps(file.path(app_dir, "app.R"), example)

  # Each example is a directory-based Shiny app (its `app.R` ends in an
  # `iridApp()` call). Running the directory — rather than the app object —
  # lets Shiny read the source for showcase mode from `app.R`.
  shiny::runApp(
    app_dir,
    port = port,
    launch.browser = launch.browser,
    host = host,
    display.mode = display.mode
  )
}
