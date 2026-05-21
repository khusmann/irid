# CodeMirror Widget — R-side component
#
# Provides the CodeMirror() component function that wraps
# IridWidget() as a reference for package authors.

#' CodeMirror CDN dependency
#'
#' Loads CodeMirror 5.65.16 from jsdelivr with language modes
#' for JavaScript, Python, R, and XML/HTML combined into a
#' single script via the `head` field to guarantee execution
#' order (the mode scripts need the `CodeMirror` global to be
#' defined first, and separate `<script>` tags inserted
#' dynamically can load in any order).
codemirror_dep <- function() {
  htmltools::htmlDependency(
    name = "codemirror",
    version = "5.65.16",
    src = c(href = "."),
    head = paste0(
      "<script src=\"https://cdn.jsdelivr.net/combine/",
      "npm/codemirror@5.65.16/lib/codemirror.min.js,",
      "npm/codemirror@5.65.16/mode/javascript/javascript.min.js,",
      "npm/codemirror@5.65.16/mode/python/python.min.js,",
      "npm/codemirror@5.65.16/mode/r/r.min.js,",
      "npm/codemirror@5.65.16/mode/xml/xml.min.js",
      "\"></script>",
      "<link rel=\"stylesheet\" ",
      "href=\"https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/codemirror.min.css\" />"
    )
  )
}

#' Widget JS dependency
#'
#' Serves codemirror.js via a web-accessible resource path.
#' The resource path must be registered before use with
#' `shiny::addResourcePath("codemirror-widget", dir)`.
widget_js_dep <- function() {
  htmltools::htmlDependency(
    name = "codemirror-widget",
    version = "1.0.0",
    src = list(href = "codemirror-widget"),
    script = "codemirror.js"
  )
}

#' CodeMirror editor component
#'
#' Wraps CodeMirror as an irid widget. `content` is a reactive
#' channel holding the editor content. `mode` is a reactive
#' channel for the syntax-highlighting language. `onChange` and
#' `onCursorActivity` are event handlers.
#'
#' @param content A reactive value (callable) holding the editor
#'   content as a string.
#' @param mode A reactive value (callable) holding the CodeMirror
#'   mode name ("javascript", "python", "r", "xml", etc.).
#' @param onChange Handler called with `event$value` when the
#'   editor content changes.
#' @param onCursorActivity Handler called with `event$line` and
#'   `event$ch` when the cursor moves.
#' @return An `irid_widget` object.
CodeMirror <- function(content, mode = "javascript",
                       onChange = NULL, onCursorActivity = NULL) {
  widget <- IridWidget(
    dep = codemirror_dep(),
    container = tags$div(style = "height: 300px; border: 1px solid #ddd;
      border-radius: 4px; overflow: hidden;"),
    content = content,
    mode = mode,
    onChange = onChange,
    onCursorActivity = onCursorActivity
  )
  # Attach widget JS as an additional dependency so both the
  # CodeMirror library (CDN) and the widget binding (local)
  # are loaded on the container element.
  widget$dep <- list(widget$dep, widget_js_dep())
  widget
}
