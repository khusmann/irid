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
#' @param example Name of the example to run, without the `.R` extension (e.g.
#'   `"todo"`, `"old_faithful"`) — the same name used in its website URL. If
#'   omitted, the available examples are listed.
#' @param ... Additional arguments passed to [shiny::runApp()].
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
iridExample <- function(example = NULL, ...) {
  examples_dir <- system.file("examples", package = "irid")
  available <- sort(tools::file_path_sans_ext(
    list.files(examples_dir, pattern = "\\.R$")
  ))

  if (is.null(example) || !example %in% available) {
    if (!is.null(example)) {
      cli::cli_warn("No irid example named {.val {example}}.")
    }
    cli::cli_inform(c(
      "Available irid examples:",
      stats::setNames(available, rep("*", length(available))),
      "i" = "Run one with e.g. {.code iridExample(\"{available[[1]]}\")}."
    ))
    return(invisible(available))
  }

  path <- file.path(examples_dir, paste0(example, ".R"))
  check_example_deps(path, example)

  # Each example script ends in an `iridApp()` call, so sourcing it yields the
  # app object as the value of its final expression. Sourced into a child of
  # the global environment so the scripts' `library()` calls behave as they
  # would at the console.
  app <- source(path, local = new.env(parent = globalenv()))$value
  shiny::runApp(app, ...)
}
