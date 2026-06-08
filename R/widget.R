#' Build a write-back event handler for a widget wrapper
#'
#' Returns an event handler that:
#'   1. Writes `e[[field]]` to `callable` iff `can_accept_write(callable)`.
#'   2. Calls the optional `then` handler after — `then()` for 0-arg,
#'      `then(e)` for 1+-arg.
#'
#' This is the canonical way a widget wrapper closes the round-trip on a
#' state-like prop. The widget's `events =` entry becomes a one-liner:
#'
#' ```r
#' events = list(change = write_back(content, "content", then = onChange))
#' ```
#'
#' Read-only callables (`reactive(...)`, a `\() expr` closure) make the
#' write silently skip, but the event listener still fires — the
#' force-send-on-no-op path in mount echoes the canonical value back to
#' the client, which snaps the widget back. The wrapper writes nothing
#' extra to get this behavior.
#'
#' @param callable A callable that will receive `e[[field]]` on write
#'   (typically a `reactiveVal`, store leaf, or `reactiveProxy`), or
#'   `NULL` for "no write target." With both `callable` and `then`
#'   `NULL`, returns `NULL` so the wrapper's `events =` entry collapses
#'   to nothing (IridWidget drops NULL entries).
#' @param field The payload field name to read on each event.
#' @param then Optional side handler called after the write. 0-arg or
#'   1-arg accepted.
#' @return A 1-arg function suitable for an [IridWidget()] `events =`
#'   entry — or `NULL` if both `callable` and `then` are `NULL`.
#' @export
write_back <- function(callable, field, then = NULL) {
  if (!is.null(callable) && !is.function(callable)) {
    stop("`callable` must be a function or NULL", call. = FALSE)
  }
  if (!is.character(field) || length(field) != 1L || !nzchar(field)) {
    stop("`field` must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.null(then) && !is.function(then)) {
    stop("`then` must be a function or NULL", call. = FALSE)
  }
  if (is.null(callable) && is.null(then)) return(NULL)
  force(callable); force(field); force(then)
  then_arity <- if (is.null(then)) NULL else length(formals(then))
  h <- function(e) {
    if (!is.null(callable) && can_accept_write(callable)) callable(e[[field]])
    if (!is.null(then)) {
      if (then_arity == 0L) then() else then(e)
    }
  }
  # Declare which binding this handler writes through, so the framework's
  # force-send-on-no-op loop only echoes THIS binding (not every binding
  # on the source element). Without this, an event whose handler doesn't
  # write a particular binding's reactiveVal would still cause that
  # binding's current value to be force-sent — and if the binding's
  # write is debounced and hasn't delivered yet, the server reactiveVal
  # is stale, and the client's in-flight state gets clobbered.
  if (!is.null(callable)) attr(h, "irid_write_targets") <- field
  h
}

#' Declare one widget event
#'
#' A `widget_event` record bundles the wire-name, timing config, and
#' handler for one event a widget can emit. Wrappers compose a list of
#' these inline as the `events =` arg to [IridWidget()], so each event's
#' name / timing / handler appear together in one place rather than
#' being split across separate slots.
#'
#' The handler argument may be `NULL` — `widget_event()` returns `NULL`
#' in that case so the wrapper can pass an optional caller-provided
#' handler through declaratively, and `IridWidget()` drops the entry.
#'
#' Wrappers that want to surface caller-side timing overrides typically
#' define a local picker inline (see `examples/codemirror.R`):
#'
#' ```r
#' widget_event(
#'   name    = "cursor-changed",
#'   timing  = irid_throttle(100),
#'   handler = onCursorChanged
#' )
#' ```
#'
#' @param name Wire-name of the event the widget JS dispatches (e.g.
#'   `"change"`, `"cursor-changed"`). Required, non-empty character scalar.
#' @param handler 0/1/2-arg handler function for the event, or `NULL` to
#'   skip registration (typically when the caller didn't pass a handler).
#' @param timing An `irid_timing` shape (`irid_immediate()` /
#'   `irid_throttle()` / `irid_debounce()`). Defaults to
#'   `irid_immediate()` — every widget event fires per-dispatch unless
#'   the wrapper overrides. Widget event names are library-specific so
#'   the framework has no per-name intuition to encode (unlike DOM
#'   `input` → `irid_debounce(200)`).
#' @return A `widget_event` record, or `NULL` when `handler` is `NULL`.
#' @export
widget_event <- function(name, handler = NULL, timing = irid_immediate()) {
  if (is.null(handler)) return(NULL)
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("`name` must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.function(handler)) {
    stop("`handler` must be a function or NULL; got ",
         paste(class(handler), collapse = "/"), call. = FALSE)
  }
  if (!inherits(timing, "irid_timing")) {
    stop("`timing` must be an `irid_timing`; got ",
         paste(class(timing), collapse = "/"), call. = FALSE)
  }
  structure(
    list(name = name, handler = handler, timing = timing),
    class = "widget_event"
  )
}

#' Construct a widget — a wrapper for an arbitrary JavaScript library
#'
#' `IridWidget()` is the third irid process-tags citizen (alongside
#' control-flow nodes and `Output`). It emits a container element plus an
#' init record that mount turns into an `irid-widget-init` custom message.
#' The client's `irid.defineWidget("<name>", factory)` registration is
#' looked up by `name` and called once per mount.
#'
#' Reactive `props` open a one-way observer (server → client), routed
#' client-side to the widget's `update(key, value)` hook. Event
#' handlers in `events` go in the other direction: the widget JS calls
#' `send(event, payload)`, the payload arrives R-side through the
#' standard `irid-events` machinery (timing, sequence, stale-indicator
#' gating all work uniformly).
#'
#' Per-widget round-trip wiring lives in the widget's R wrapper — see
#' [write_back()] for the canonical pattern.
#'
#' @param name Widget registry name, matching a JS-side
#'   `irid.defineWidget("<name>", ...)` call. Required, non-empty
#'   character scalar.
#' @param props Named list of inputs (server → client). Per-key dispatch
#'   on [is.function()]: callable values become observers; non-callable
#'   values ride in the init message as constants. `NULL` entries are
#'   forwarded to JS as `null` (not dropped), so wrappers can declare
#'   their full prop shape with optional slots
#'   (`props = list(content = ..., cursor = cursor)` where `cursor` may
#'   be `NULL`) and the JS factory sees a predictable, complete object.
#' @param events List of [widget_event()] records (client → server). Each
#'   record bundles wire-name, timing config, and handler for one event
#'   the widget JS can dispatch. `NULL` entries (from `widget_event()`
#'   calls whose handler was `NULL`) are dropped, so wrappers can forward
#'   optional handlers declaratively.
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
  if (!is.list(events)) {
    stop("`events` must be a list; got ",
         paste(class(events), collapse = "/"), call. = FALSE)
  }
  # NULL entries (from `widget_event()` calls with NULL handler) are
  # dropped so wrappers can forward optional handlers declaratively.
  events <- events[!vapply(events, is.null, logical(1L))]
  if (length(events) > 0L) {
    for (i in seq_along(events)) {
      if (!inherits(events[[i]], "widget_event")) {
        stop("every entry in `events` must be a `widget_event` (from `widget_event()`); ",
             "entry ", i, " had class ",
             paste(class(events[[i]]), collapse = "/"), call. = FALSE)
      }
    }
  }
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
