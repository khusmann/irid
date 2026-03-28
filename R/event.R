#' Event handler wrappers
#'
#' Control how event callbacks are dispatched from the browser to the server.
#'
#' - `event_immediate()`: Fires on every event with no rate limiting. Bare
#'   functions passed as event handlers are implicitly wrapped with
#'   `event_immediate()`.
#' - `event_throttle()`: Fires at most every `ms` milliseconds while the
#'   event is active.
#' - `event_debounce()`: Waits until the user pauses for `ms` milliseconds
#'   before firing.
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
#' @param fn An event handler function receiving `(event)` or `(event, id)`.
#' @param coalesce If `TRUE`, gate on server idle so events never queue
#'   faster than the server can process them. Defaults to `FALSE` for
#'   `event_immediate()` and `TRUE` for `event_throttle()`/`event_debounce()`.
#' @param prevent_default If `TRUE`, call `event.preventDefault()` in the
#'   browser before dispatching. Defaults to `FALSE`.
#' @param ms Minimum interval (throttle) or quiet period (debounce) in
#'   milliseconds.
#' @param leading If `TRUE` (default), fire immediately on the first
#'   event. If `FALSE`, wait for the timer before firing.
#' @return A wrapped handler.
#'
#' @name event-wrappers
NULL

#' @rdname event-wrappers
#' @export
event_immediate <- function(fn, coalesce = FALSE, prevent_default = FALSE) {
  structure(fn, class = c("nacre_event", "function"),
            mode = "immediate", coalesce = coalesce,
            prevent_default = prevent_default)
}

#' @rdname event-wrappers
#' @export
event_throttle <- function(fn, ms, leading = TRUE, coalesce = TRUE, prevent_default = FALSE) {
  structure(fn, class = c("nacre_event", "function"),
            mode = "throttle", ms = ms, leading = leading,
            coalesce = coalesce, prevent_default = prevent_default)
}

#' @rdname event-wrappers
#' @export
event_debounce <- function(fn, ms, coalesce = TRUE, prevent_default = FALSE) {
  structure(fn, class = c("nacre_event", "function"),
            mode = "debounce", ms = ms, coalesce = coalesce,
            prevent_default = prevent_default)
}
