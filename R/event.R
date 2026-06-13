# NULL-coalescing helper. base R gained `%||%` in 4.4.0, but irid targets
# R >= 4.1.0, so define our own (package-internal; shadows base within the
# namespace where present).
`%||%` <- function(x, y) if (is.null(x)) y else x

#' Event & binding dispatch config
#'
#' Configure how an event handler or value binding is dispatched between the
#' browser and the server. A single per-slot carrier, [irid_wire()], rides
#' the slot it configures — an `on*` handler slot or a `value`/`checked`
#' binding slot — so an event's timing, backpressure, and DOM-listener
#' options live next to the handler/reactive they govern rather than in
#' separate element-level lists.
#'
#' @section Timing shapes:
#' The timing constructors are pure shapes — they describe *when* an event
#' fires and carry no other config:
#'
#' - `irid_immediate()`: Fires on every event with no rate limiting.
#' - `irid_throttle(ms, leading)`: Fires at most every `ms` milliseconds
#'   while the event is active.
#' - `irid_debounce(ms)`: Waits until the user pauses for `ms` milliseconds
#'   before firing.
#'
#' When a wire carries no `timing`, irid applies a per-event default keyed on
#' the DOM event name: `input` → `irid_debounce(200)` (typing produces a
#' flood of intermediate values); the high-frequency continuous streams
#' (`mousemove`, `pointermove`, `touchmove`, `drag`, `dragover`, `scroll`,
#' `wheel`, `resize`) → `irid_throttle(100)` (paced "latest position"
#' stream, with the derived `coalesce = TRUE` keeping it from outrunning the
#' server); every other event → `irid_immediate()`. Explicit `timing` always
#' wins over the default.
#'
#' @section Backpressure (`coalesce`):
#' `coalesce` is universal across timing modes, so it lives on the carrier,
#' not in the shapes. When `TRUE`, dispatch gates on server-idle state so
#' events never queue faster than the server can process them. When `NULL`
#' (the default), it derives from the timing mode: `FALSE` for
#' `irid_immediate()`, `TRUE` for `irid_throttle()` / `irid_debounce()`.
#'
#' @section DOM listener options:
#' [irid_dom_opts()] bundles the DOM-only listener flags. It is legal only
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
#' @param timing An `irid_timing` shape (`irid_immediate()`,
#'   `irid_throttle()`, `irid_debounce()`), or `NULL` for the per-event
#'   default.
#' @param coalesce Logical scalar, or `NULL` to derive from the timing mode.
#' @param dom_opts An [irid_dom_opts()] record, or `NULL`.
#' @param ms Minimum interval (throttle) or quiet period (debounce) in
#'   milliseconds.
#' @param leading If `TRUE` (default), fire immediately on the first event.
#'   If `FALSE`, wait for the timer before firing.
#' @param prevent_default Call `event.preventDefault()` before dispatch.
#' @param stop_propagation Call `event.stopPropagation()` before dispatch.
#' @param capture Register the listener in the capture phase.
#' @param passive Register the listener as passive.
#'
#' @return `irid_wire()` returns an `irid_wire`; the timing constructors
#'   return an `irid_timing`; `irid_dom_opts()` returns an `irid_dom_opts`.
#'
#' @name irid_wire
NULL

#' @rdname irid_wire
#' @export
irid_immediate <- function() {
  structure(list(mode = "immediate"), class = "irid_timing")
}

#' @rdname irid_wire
#' @export
irid_throttle <- function(ms, leading = TRUE) {
  if (!is.numeric(ms) || length(ms) != 1L || is.na(ms)) {
    stop("`ms` must be a numeric scalar", call. = FALSE)
  }
  if (!is.logical(leading) || length(leading) != 1L || is.na(leading)) {
    stop("`leading` must be `TRUE` or `FALSE`", call. = FALSE)
  }
  structure(
    list(mode = "throttle", ms = ms, leading = leading),
    class = "irid_timing"
  )
}

#' @rdname irid_wire
#' @export
irid_debounce <- function(ms) {
  if (!is.numeric(ms) || length(ms) != 1L || is.na(ms)) {
    stop("`ms` must be a numeric scalar", call. = FALSE)
  }
  structure(list(mode = "debounce", ms = ms), class = "irid_timing")
}

#' @rdname irid_wire
#' @export
irid_dom_opts <- function(prevent_default = FALSE, stop_propagation = FALSE,
                          capture = FALSE, passive = FALSE) {
  flags <- list(
    prevent_default = prevent_default, stop_propagation = stop_propagation,
    capture = capture, passive = passive
  )
  for (nm in names(flags)) {
    v <- flags[[nm]]
    if (!is.logical(v) || length(v) != 1L || is.na(v)) {
      stop("`", nm, "` must be `TRUE` or `FALSE`", call. = FALSE)
    }
  }
  structure(flags, class = "irid_dom_opts")
}

#' @rdname irid_wire
#' @export
irid_wire <- function(subject = NULL, timing = NULL, coalesce = NULL,
                      dom_opts = NULL) {
  if (!is.null(subject) && !is.function(subject)) {
    stop("`subject` must be a function (handler or reactive) or NULL; got ",
         paste(class(subject), collapse = "/"), call. = FALSE)
  }
  if (!is.null(timing) && !inherits(timing, "irid_timing")) {
    stop("`timing` must be an `irid_timing` (from `irid_immediate()`, ",
         "`irid_throttle()`, or `irid_debounce()`) or NULL; got ",
         paste(class(timing), collapse = "/"), call. = FALSE)
  }
  if (!is.null(coalesce) &&
      (!is.logical(coalesce) || length(coalesce) != 1L || is.na(coalesce))) {
    stop("`coalesce` must be `TRUE`, `FALSE`, or NULL", call. = FALSE)
  }
  if (!is.null(dom_opts) && !inherits(dom_opts, "irid_dom_opts")) {
    stop("`dom_opts` must be an `irid_dom_opts` (from `irid_dom_opts()`) ",
         "or NULL; got ", paste(class(dom_opts), collapse = "/"),
         call. = FALSE)
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
as_irid_wire <- function(x) {
  if (is.null(x)) return(irid_wire())
  if (inherits(x, "irid_wire")) return(x)
  if (is.function(x)) return(irid_wire(subject = x))
  stop("expected a function or an `irid_wire`; got ",
       paste(class(x), collapse = "/"), call. = FALSE)
}

#' Overlay one `irid_wire` over another
#'
#' Override-wins overlay used where a widget wrapper layers a caller's input
#' over its own default config. Each field of `y` (`subject`, `timing`,
#' `coalesce`, `dom_opts`) wins when non-`NULL`; otherwise `x`'s field
#' carries through. `y` may be `NULL` (identity) or a bare callable (fills in
#' only the subject), both normalized first.
#'
#' Extends the base [merge()] generic rather than introducing a new one.
#'
#' @param x The default `irid_wire`.
#' @param y The override: an `irid_wire`, a bare callable, or `NULL`.
#' @param ... Unused.
#' @return An `irid_wire`.
#' @keywords internal
#' @exportS3Method base::merge
merge.irid_wire <- function(x, y, ...) {
  y <- as_irid_wire(y)
  irid_wire(
    subject  = y$subject  %||% x$subject,
    timing   = y$timing   %||% x$timing,
    coalesce = y$coalesce %||% x$coalesce,
    dom_opts = y$dom_opts %||% x$dom_opts
  )
}
