#' Event & binding dispatch config
#'
#' Configure how an event handler or value binding is dispatched between the
#' browser and the server. A single per-slot carrier, [wire()], rides
#' the slot it configures — an `on*` handler slot or a `value`/`checked`
#' binding slot — so an event's timing, backpressure, and DOM-listener
#' options live next to the handler/reactive they govern rather than in
#' separate element-level lists.
#'
#' @section Timing shapes:
#' The timing constructors are pure shapes — they describe *when* an event
#' fires and carry no other config:
#'
#' - `wire_immediate()`: Fires on every event with no rate limiting.
#' - `wire_throttle(ms, leading)`: Fires at most every `ms` milliseconds
#'   while the event is active.
#' - `wire_debounce(ms)`: Waits until the user pauses for `ms` milliseconds
#'   before firing.
#'
#' When a wire carries no `timing`, irid applies a per-event default keyed on
#' the DOM event name: `input` → `wire_debounce(200)` (typing produces a
#' flood of intermediate values); the high-frequency continuous streams
#' (`mousemove`, `pointermove`, `touchmove`, `drag`, `dragover`, `scroll`,
#' `wheel`, `resize`) → `wire_throttle(100)` (paced "latest position"
#' stream, with the derived `coalesce = TRUE` keeping it from outrunning the
#' server); every other event → `wire_immediate()`. Explicit `timing` always
#' wins over the default.
#'
#' @section Backpressure (`coalesce`):
#' `coalesce` is universal across timing modes, so it lives on the carrier,
#' not in the shapes. When `TRUE`, dispatch gates on server-idle state so
#' events never queue faster than the server can process them. When `NULL`
#' (the default), it derives from the timing mode: `FALSE` for
#' `wire_immediate()`, `TRUE` for `wire_throttle()` / `wire_debounce()`.
#'
#' @section DOM listener options:
#' [wire_dom_opts()] bundles the DOM-only listener flags. It is legal only
#' where the event is backed by a real DOM listener (a plain tag, a custom
#' element emitting cancelable events); placing it on a widget-emitted event
#' errors. Whether `prevent_default` has any effect further depends on the
#' event being cancelable — a runtime fact.
#'
#' @section The event object:
#' The `event` argument passed to handlers is a list containing all
#' primitive-valued properties (string, numeric, logical) from the browser
#' event object, plus these element properties:
#' \describe{
#'   \item{`value`}{The element's current value (character).}
#'   \item{`valueAsNumber`}{Numeric value of the element, or `NA` if the
#'     input is empty or non-numeric (e.g. a blank text box). Useful for
#'     range and number inputs.}
#'   \item{`checked`}{Logical, for checkbox and radio inputs.}
#' }
#' Keyboard events additionally include `key`, `code`, `ctrlKey`,
#' `shiftKey`, `altKey`, and `metaKey`.
#'
#' @param subject The handler or reactive the wire configures. The slot
#'   decides which: a bare callable means "bind" in `value =` / `checked =`
#'   and "handle" in an `on*` slot. `NULL` (the default) carries config
#'   only — used by widget wrappers that supply a default shape for the
#'   caller to override via [merge()].
#' @param timing An `irid_wire_timing` shape (`wire_immediate()`,
#'   `wire_throttle()`, `wire_debounce()`), or `NULL` for the per-event
#'   default.
#' @param coalesce Logical scalar, or `NULL` to derive from the timing mode.
#' @param dom_opts A [wire_dom_opts()] record, or `NULL`.
#' @param ms Minimum interval (throttle) or quiet period (debounce) in
#'   milliseconds.
#' @param leading If `TRUE` (default), fire immediately on the first event.
#'   If `FALSE`, wait for the timer before firing.
#' @param prevent_default Call `event.preventDefault()` before dispatch.
#' @param stop_propagation Call `event.stopPropagation()` before dispatch.
#' @param capture Register the listener in the capture phase.
#' @param passive Register the listener as passive.
#'
#' @return `wire()` returns an `irid_wire`; the timing constructors
#'   return an `irid_wire_timing`; `wire_dom_opts()` returns an `irid_dom_opts`.
#'
#' @name wire
NULL

#' @rdname wire
#' @export
wire_immediate <- function() {
  structure(list(mode = "immediate"), class = "irid_wire_timing")
}

#' @rdname wire
#' @export
wire_throttle <- function(ms, leading = TRUE) {
  rlang::check_number_decimal(ms)
  rlang::check_bool(leading)
  structure(
    list(mode = "throttle", ms = ms, leading = leading),
    class = "irid_wire_timing"
  )
}

#' @rdname wire
#' @export
wire_debounce <- function(ms) {
  rlang::check_number_decimal(ms)
  structure(list(mode = "debounce", ms = ms), class = "irid_wire_timing")
}

#' @rdname wire
#' @export
wire_dom_opts <- function(prevent_default = FALSE, stop_propagation = FALSE,
                          capture = FALSE, passive = FALSE) {
  rlang::check_bool(prevent_default)
  rlang::check_bool(stop_propagation)
  rlang::check_bool(capture)
  rlang::check_bool(passive)
  structure(
    list(
      prevent_default = prevent_default, stop_propagation = stop_propagation,
      capture = capture, passive = passive
    ),
    class = "irid_dom_opts"
  )
}

#' @rdname wire
#' @export
wire <- function(subject = NULL, timing = NULL, coalesce = NULL,
                 dom_opts = NULL) {
  check_function(subject, allow_null = TRUE)
  if (!is.null(timing) && !inherits(timing, "irid_wire_timing")) {
    cli::cli_abort(c(
      "{.arg timing} must be an {.cls irid_wire_timing} or {.code NULL}.",
      "i" = "Build one with {.fn wire_immediate}, {.fn wire_throttle}, \\
             or {.fn wire_debounce}.",
      "x" = "You supplied {.obj_type_friendly {timing}}."
    ))
  }
  rlang::check_bool(coalesce, allow_null = TRUE)
  if (!is.null(dom_opts) && !inherits(dom_opts, "irid_dom_opts")) {
    cli::cli_abort(c(
      "{.arg dom_opts} must be an {.cls irid_dom_opts} or {.code NULL}.",
      "i" = "Build one with {.fn wire_dom_opts}.",
      "x" = "You supplied {.obj_type_friendly {dom_opts}}."
    ))
  }
  structure(
    list(subject = subject, timing = timing, coalesce = coalesce,
         dom_opts = dom_opts),
    class = "irid_wire"
  )
}

# Normalize a slot value into an `irid_wire`. A bare callable becomes a
# subject-only wire; an existing `irid_wire` passes through; `NULL` becomes
# an empty wire (config-only identity). Anything else errors — callers use
# this to accept "bare handler/reactive OR irid_wire" uniformly.
as_wire <- function(x) {
  if (is.null(x)) return(wire())
  if (inherits(x, "irid_wire")) return(x)
  if (is.function(x)) return(wire(subject = x))
  cli::cli_abort(c(
    "Expected a function or a {.cls irid_wire}.",
    "x" = "You supplied {.obj_type_friendly {x}}."
  ))
}

#' Overlay one `wire` over another
#'
#' Override-wins overlay used where a widget wrapper layers a caller's input
#' over its own default config. Each field of `y` (`subject`, `timing`,
#' `coalesce`, `dom_opts`) wins when non-`NULL`; otherwise `x`'s field
#' carries through. `y` may be `NULL` (identity) or a bare callable (fills in
#' only the subject), both normalized first.
#'
#' Extends the base [merge()] generic rather than introducing a new one.
#'
#' @param x The default `wire`.
#' @param y The override: a `wire`, a bare callable, or `NULL`.
#' @param ... Unused.
#' @return A `wire`.
#' @keywords internal
#' @exportS3Method base::merge
merge.irid_wire <- function(x, y, ...) {
  y <- as_wire(y)
  wire(
    subject  = y$subject  %||% x$subject,
    timing   = y$timing   %||% x$timing,
    coalesce = y$coalesce %||% x$coalesce,
    dom_opts = y$dom_opts %||% x$dom_opts
  )
}
