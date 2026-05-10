#' Event timing and transport config
#'
#' Configure how event callbacks are dispatched from the browser to the
#' server. Pass the result to an element's `.event` prop to control timing
#' for **all** events on that element (auto-bind synthetic write-back plus
#' any explicit `on*` handlers).
#'
#' - `event_immediate()`: Fires on every event with no rate limiting.
#' - `event_throttle()`: Fires at most every `ms` milliseconds while the
#'   event is active.
#' - `event_debounce()`: Waits until the user pauses for `ms` milliseconds
#'   before firing.
#'
#' When `.event` is omitted, irid applies a per-event default keyed on the
#' DOM event name: `input` → `event_debounce(200)` (typing produces a flood
#' of intermediate values), every other event → `event_immediate()`. The
#' rule is the same whether the event entry came from an auto-bind synthetic
#' or an explicit `on*` handler, so adding `value = rv` to an existing
#' `onInput` doesn't silently shift its timing.
#'
#' `.event` accepts either a single config struct (applies to every event
#' on the element) or a named list for per-event overrides. List keys may
#' use either the lowercase DOM event name (`input`, `change`, `keydown`)
#' or the matching `on`-prop name (`onInput`, `onChange`, `onKeyDown`);
#' both forms normalize to the lowercase DOM event. Events not covered by
#' the list fall back to the per-event default. Malformed `.event` values
#' (a non-config, an unnamed list, or a list whose entries are not all
#' configs) raise an error during tag processing.
#'
#' Use the element-level `.prevent_default` prop to call
#' `event.preventDefault()` in the browser before dispatch. Like `.event`,
#' it accepts either a logical scalar (broadcasts to every event on the
#' element) or a named list keyed by DOM event for per-event overrides;
#' unmapped events default to `FALSE`.
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
#' @param coalesce If `TRUE`, gate on server idle so events never queue
#'   faster than the server can process them. Defaults to `FALSE` for
#'   `event_immediate()` and `TRUE` for `event_throttle()`/`event_debounce()`.
#' @param ms Minimum interval (throttle) or quiet period (debounce) in
#'   milliseconds.
#' @param leading If `TRUE` (default), fire immediately on the first
#'   event. If `FALSE`, wait for the timer before firing.
#' @return An `irid_event_config` struct.
#'
#' @name event-config
NULL

#' @rdname event-config
#' @export
event_immediate <- function(coalesce = FALSE) {
  structure(
    list(mode = "immediate", coalesce = coalesce),
    class = "irid_event_config"
  )
}

#' @rdname event-config
#' @export
event_throttle <- function(ms, leading = TRUE, coalesce = TRUE) {
  structure(
    list(mode = "throttle", ms = ms, leading = leading, coalesce = coalesce),
    class = "irid_event_config"
  )
}

#' @rdname event-config
#' @export
event_debounce <- function(ms, coalesce = TRUE) {
  structure(
    list(mode = "debounce", ms = ms, coalesce = coalesce),
    class = "irid_event_config"
  )
}
