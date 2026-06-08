# Normalize and validate a widget `events` list. Each entry is keyed by the
# wire event name the widget JS dispatches and is a bare handler, an
# `irid_wire`, or `NULL`. NULL entries (and `merge()` results that resolve to
# a NULL subject — an optional handler the caller didn't supply) are dropped,
# so wrappers can forward optional handlers declaratively. `dom_opts` is
# illegal on a widget event (it is delivered via `sendEvent()`, not a DOM
# listener, so `preventDefault` and friends have nothing to act on).
normalize_widget_events <- function(events) {
  if (!is.list(events)) {
    stop("`events` must be a list; got ",
         paste(class(events), collapse = "/"), call. = FALSE)
  }
  events <- events[!vapply(events, is.null, logical(1L))]
  if (length(events) == 0L) return(list())
  nms <- names(events)
  if (is.null(nms) || any(!nzchar(nms))) {
    stop("every entry in `events` must be named with its wire event name",
         call. = FALSE)
  }
  out <- list()
  for (key in nms) {
    val <- events[[key]]
    if (!is.function(val) && !inherits(val, "irid_wire")) {
      stop("`events$", key, "` must be a function or an `irid_wire`; got ",
           paste(class(val), collapse = "/"), call. = FALSE)
    }
    w <- as_irid_wire(val)
    if (!is.null(w$dom_opts)) {
      stop("`dom_opts` is not allowed on the widget event `", key,
           "`: `prevent_default` and friends need a DOM listener, but a ",
           "widget event is delivered through `sendEvent()`.", call. = FALSE)
    }
    # A NULL subject (bare `NULL`, or `merge(default, NULL)` for an optional
    # handler) means no handler — drop the entry.
    if (is.null(w$subject)) next
    out[[key]] <- w
  }
  out
}

#' Construct a widget — a wrapper for an arbitrary JavaScript library
#'
#' `IridWidget()` is the third irid process-tags citizen (alongside
#' control-flow nodes and `Output`). It emits a container element plus an
#' init record that mount turns into an `irid-widget-init` custom message.
#' The client's `irid.defineWidget("<name>", factory)` registration is
#' looked up by `name` and called once per mount.
#'
#' **Props are two-way-capable by default**, exactly like DOM `value` /
#' `checked`. A callable prop (`reactiveVal`, store leaf, `reactiveProxy`,
#' ...) reads inbound to the widget (server → client, routed to the
#' factory's `update(key, value)` hook) *and* accepts write-back: when the
#' widget JS calls `setProp(key, value)`, irid writes the value through the
#' bound reactive (gated by writability — a read-only reactive's write is
#' dropped and the canonical value is snapped back). Whether a prop is
#' *actually* two-way depends on whether the widget JS pushes through
#' `setProp`; the snap-back machinery is latent until it does. A non-callable
#' prop rides in the init message as a constant and is never re-sent.
#'
#' Wrap a prop in [irid_wire()] only to **tune** its round-trip timing
#' (`content = irid_wire(content, irid_debounce(200))`) — never to enable or
#' disable two-way. To react to a prop's change, observe the bound reactive
#' or pass a `reactiveProxy`; a bound prop is not *also* handled.
#'
#' `events` carries genuine notifications the widget emits that correspond to
#' no prop (e.g. `cursor-changed`). Keys are the wire event names the widget
#' JS passes to `sendEvent()` (lowercase kebab-case by web `CustomEvent`
#' convention). Each value is a handler or an [irid_wire()] (to tune timing);
#' `NULL` entries are dropped so optional handlers forward declaratively.
#' `dom_opts` is illegal on a widget event.
#'
#' @param name Widget registry name, matching a JS-side
#'   `irid.defineWidget("<name>", ...)` call. Required, non-empty
#'   character scalar.
#' @param props Named list of props. Callable values are two-way-capable
#'   bindings; non-callable values are init-only constants. `NULL` entries
#'   are forwarded to JS as `null` (not dropped). Wrap a value in
#'   [irid_wire()] to tune its write-back timing.
#' @param events Named list of notifications (client → server), keyed by wire
#'   event name. Each value is a handler, an [irid_wire()], or `NULL`
#'   (dropped). `dom_opts` is not allowed.
#' @param deps Optional `html_dependency` or list of them. Required for
#'   any widget whose JS isn't already loaded by some other means.
#' @param container Optional `shiny.tag` for the wrapper element.
#'   Defaults to `tags$div()`. irid sets `id` and `data-irid-widget`
#'   automatically. Configure any DOM events on the container by wrapping
#'   their handlers in [irid_wire()] on the container directly.
#' @return A irid widget construct with class `irid_widget`.
#' @export
IridWidget <- function(
  name,
  props = list(),
  events = list(),
  deps = NULL,
  container = NULL
) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("`name` must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.list(props)) {
    stop("`props` must be a list; got ",
         paste(class(props), collapse = "/"), call. = FALSE)
  }
  if (length(props) > 0L) {
    p_nms <- names(props)
    if (is.null(p_nms) || any(!nzchar(p_nms))) {
      stop("every entry in `props` must be named", call. = FALSE)
    }
  }
  events <- normalize_widget_events(events)
  if (!is.null(deps)) {
    if (inherits(deps, "html_dependency")) {
      deps <- list(deps)
    } else if (is.list(deps)) {
      ok <- vapply(deps, inherits, logical(1L), "html_dependency")
      if (!all(ok)) {
        stop("`deps` must be an `html_dependency` or a list of them",
             call. = FALSE)
      }
    } else {
      stop("`deps` must be NULL, an `html_dependency`, or a list of them; got ",
           paste(class(deps), collapse = "/"), call. = FALSE)
    }
  }
  if (!is.null(container) && !inherits(container, "shiny.tag")) {
    stop("`container` must be NULL or a `shiny.tag`; got ",
         paste(class(container), collapse = "/"), call. = FALSE)
  }
  structure(
    list(
      name = name,
      props = props,
      events = events,
      deps = deps,
      container = container
    ),
    class = "irid_widget"
  )
}

# File-backed dependencies (anything with `src$file` or a `package` arg)
# need their path registered as a Shiny static resource before the client
# can fetch them. UI-attached deps get this automatically; deps shipped
# via the `irid-widget-init` custom message do not — `Shiny.renderDependencies`
# resolves URLs but doesn't register routes. `createWebDependency` does
# both, but it can't resolve `package`-relative `src$file` on its own,
# so do that first.
#
# href-only deps (CDN-style — e.g. the CodeMirror example) and head-only
# deps pass through unchanged.
register_widget_dep <- function(dep) {
  if (!is.null(dep$package)) {
    root <- system.file(package = dep$package)
    if (!nzchar(root)) {
      stop(
        "Could not locate the '", dep$package, "' package for ",
        "widget dependency '", dep$name, "'.",
        call. = FALSE
      )
    }
    if (!is.null(dep$src$file)) {
      dep$src <- list(file = file.path(root, dep$src$file))
    }
    dep$package <- NULL
  }
  if (!is.null(dep$src$file)) {
    dep <- shiny::createWebDependency(dep)
  }
  dep
}
