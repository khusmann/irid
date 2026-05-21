#' Create a widget node for use in irid tag trees
#'
#' `IridWidget()` is a low-level constructor for package authors to wrap
#' JavaScript libraries (like CodeMirror, Leaflet, or Plotly) as irid
#' components. It returns a first-class irid node that [process_tags()]
#' and [irid_mount_processed()] handle alongside `Each`/`When`/`Match`.
#'
#' Named `...` arguments are split into three categories:
#' - Names matching `^on[A-Z]` become event handlers (same as tag `on*`
#'   attrs), with timing configured by `.event`.
#' - Reactive-valued functions (see [is_irid_reactive()]) become data
#'   channels: their values are observed and pushed to the client on
#'   change via `irid-widget-channel` messages.
#' - All other named values become static init-time config, merged with
#'   `.config` (`.config` values win on name collision).
#'
#' The `.render` argument names the channel that triggers a full re-render
#' on the client — channel messages for this field carry `isRender: true`.
#'
#' End-users never call `IridWidget()` directly. Package authors create
#' component functions like:
#' ```r
#' CodeMirror <- function(content, mode = "javascript",
#'                        onChange = NULL, onCursorActivity = NULL) {
#'   IridWidget(
#'     dep = codemirror_dep(),
#'     container = tags$div(style = "height: 300px;"),
#'     content = content,
#'     .config = list(mode = mode),
#'     onChange = onChange,
#'     onCursorActivity = onCursorActivity
#'   )
#' }
#' ```
#'
#' @param dep An [htmltools::htmlDependency()] for the widget's JS/CSS.
#' @param container A [shiny::tags] element that serves as the widget's
#'   DOM container. The element is assigned the widget's auto-generated
#'   ID and the `irid-widget` CSS class.
#' @param ... Named arguments: reactive functions become data channels,
#'   `on*` functions become event handlers, and all other values become
#'   static init-time config.
#' @param .config A named list of static configuration values. Merged with
#'   non-reactive, non-event `...` args (`.config` values take precedence).
#' @param .event An [irid_event_config] or named list of them, applied to
#'   every event on the widget (same semantics as the element-level
#'   `.event` prop on regular tags).
#' @param .render Optional string naming the render channel. Channel
#'   messages for this field carry `isRender: true`. Default `NULL`.
#' @param .widget_name Optional string to override the auto-derived widget
#'   name (from `dep$name` with hyphens/underscores stripped). Passed to
#'   the client as `msg.widget` in the init message.
#' @return An object of class `"irid_widget"`.
#' @export
IridWidget <- function(dep, container, ..., .config = list(),
                       .event = NULL, .render = NULL, .widget_name = NULL) {
  stopifnot(inherits(container, "shiny.tag"))
  args <- list(...)
  structure(
    list(
      dep = dep,
      container = container,
      args = args,
      .config = .config,
      .event = .event,
      .render = .render,
      widget_name = .widget_name %||% gsub("[-_]", "", dep$name)
    ),
    class = "irid_widget"
  )
}
