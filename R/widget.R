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
#'   (typically a `reactiveVal`, store leaf, or `reactiveProxy`).
#'   Errors at construction if not a function.
#' @param field The payload field name to read on each event.
#' @param then Optional side handler called after the write. 0-arg or
#'   1-arg accepted.
#' @return A 1-arg function suitable for an [IridWidget()] `events =` entry.
#' @export
write_back <- function(callable, field, then = NULL) {
  if (!is.function(callable)) {
    stop("`callable` must be a function", call. = FALSE)
  }
  if (!is.character(field) || length(field) != 1L || !nzchar(field)) {
    stop("`field` must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.null(then) && !is.function(then)) {
    stop("`then` must be a function or NULL", call. = FALSE)
  }
  force(callable); force(field); force(then)
  then_arity <- if (is.null(then)) NULL else length(formals(then))
  function(e) {
    if (can_accept_write(callable)) callable(e[[field]])
    if (!is.null(then)) {
      if (then_arity == 0L) then() else then(e)
    }
  }
}

#' Layer wrapper-default event-timing config under a caller's `.event`
#'
#' Three-tier resolution for an element-level `.event` prop:
#'   1. Caller's `.event` (highest) — a scalar `irid_event_config` wins
#'      everywhere; a named list wins per event.
#'   2. Wrapper defaults (middle) — the `...` entries supply per-event
#'      defaults the wrapper author thinks are sensible for the library
#'      (e.g. `change = event_debounce(200)` for an editor).
#'   3. Framework default (lowest) — applied by [process_tags()] for any
#'      event not covered by the layered result.
#'
#' Generic — plain-tag wrappers can use this too. A `SearchInput`
#' wrapper might write `event_defaults(.event, input = event_debounce(500))`
#' to make debounced input the default for its callers.
#'
#' @param user The `.event` value the caller passed (often `NULL`).
#' @param ... Named `irid_event_config` entries (wrapper defaults).
#' @return The merged `.event` value, suitable to pass to [IridWidget()].
#' @export
event_defaults <- function(user, ...) {
  defaults <- list(...)
  if (is.null(user)) {
    # Empty layered config — return NULL so the downstream `.event`
    # path treats it as "no config" rather than erroring on an
    # empty named list.
    return(if (length(defaults) == 0L) NULL else defaults)
  }
  # Caller scalar broadcasts and wins everywhere; wrapper defaults are
  # dropped. Validation of `user`'s shape is deferred to the existing
  # `normalize_element_event` path in process_tags so error messages
  # match plain-tag `.event` errors.
  if (inherits(user, "irid_event_config")) return(user)
  if (is.list(user)) return(utils::modifyList(defaults, user))
  user
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
#' client-side to the widget's `update(key, value, sequence)` hook. Event
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
#'   values ride in the init message as constants.
#' @param events Named list of event handlers (client → server). Keys
#'   are lowercase kebab-case event names (matching the web's
#'   `CustomEvent` convention). Each value is a 0/1/2-arg handler.
#' @param deps Optional `html_dependency` or list of them. Required for
#'   any widget whose JS isn't already loaded by some other means.
#' @param container Optional `shiny.tag` for the wrapper element.
#'   Defaults to `tags$div()`. irid sets `id` and `data-irid-widget`
#'   automatically.
#' @param .event Element-level event-timing config — same shape as on a
#'   plain tag (`event_immediate()` / `event_throttle()` / `event_debounce()`,
#'   or a named list keyed by event). Applies to both widget events and
#'   any DOM events on the container.
#' @return A irid widget construct with class `irid_widget`.
#' @export
IridWidget <- function(
  name,
  props = list(),
  events = list(),
  deps = NULL,
  container = NULL,
  .event = NULL
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
  if (length(events) > 0L) {
    e_nms <- names(events)
    if (is.null(e_nms) || any(!nzchar(e_nms))) {
      stop("every entry in `events` must be named", call. = FALSE)
    }
    for (i in seq_along(events)) {
      if (!is.function(events[[i]])) {
        stop("`events$", e_nms[[i]], "` must be a function; got ",
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
      container = container,
      event_config = .event
    ),
    class = "irid_widget"
  )
}

# Per-widget-event default timing. Unlike DOM events (where `input` is
# debounced and everything else is immediate), widget event names are
# library-specific (`cursor-changed`, `relayout`, ...) so the framework
# has no per-name intuition to encode. Every widget event defaults to
# `event_immediate()`; wrappers layer their own per-event defaults via
# `event_defaults()`.
widget_default_for_event <- function(event_name) {
  event_immediate()
}
