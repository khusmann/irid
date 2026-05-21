# CodeMirror Widget — irid Demo App
#
# A runnable example demonstrating the full widget pattern:
#   - htmlDependency (CodeMirror from CDN, widget JS from local file)
#   - irid.registerWidget() / irid.sendEvent() client-side
#   - IridWidget() R-side constructor
#   - Composition inside When (show/hide lifecycle)
#   - Reactive channels (content, mode) with isRender flag
#   - Event handlers (onChange, onCursorActivity)
#
# Usage:
#   Run this file as a Shiny app, or source it and call iridApp(App).
#   Requires internet access to load CodeMirror from CDN.

library(irid)
library(shiny)

# Source the CodeMirror component
source("codemirror.R")

# Register resource path so codemirror.js is web-accessible.
# Shiny serves files from the app directory under the
# "codemirror-widget" URL prefix.
shiny::addResourcePath("codemirror-widget", normalizePath("."))

App <- function() {
  # --- Reactive state ---
  code <- reactiveVal(
    '# Type some code here...\n\ndef greet(name):\n    return f"Hello, {name}!"\n\nprint(greet("World"))'
  )
  show_editor <- reactiveVal(TRUE)
  language <- reactiveVal("python")

  # --- UI ---
  fluidPage(
    titlePanel("CodeMirror Widget Example"),

    # Control bar
    div(
      class = "well",
      style = "display: flex; gap: 12px; align-items: center; flex-wrap: wrap;",
      tags$button(
        class = "btn btn-default",
        `data-toggle` = "button",
        \() if (show_editor()) "Hide Editor" else "Show Editor",
        onClick = \() show_editor(!show_editor())
      ),
      tags$span("Language:"),
      tags$select(
        style = "width: auto; display: inline-block;",
        tags$option(value = "python", "Python"),
        tags$option(value = "javascript", "JavaScript"),
        tags$option(value = "r", "R"),
        tags$option(value = "xml", "HTML/XML"),
        value = language
      ),
      tags$span(
        class = "text-muted",
        style = "font-size: 0.9em;",
        "Character count:", \() nchar(code())
      )
    ),

    # CodeMirror editor inside When — demonstrates lifecycle:
    #   show_editor=TRUE  → widget is created, init message sent
    #   show_editor=FALSE → widget is destroyed, destroy message sent
    #   show_editor=TRUE  → widget is re-created fresh (not re-used)
    When(show_editor,
      yes = \() CodeMirror(
        content = code,
        mode = language,
        onChange = \(event) code(event$value),
        onCursorActivity = \(event) {
          # In a real app, you'd update a reactive or log to console.
          # Here we just demonstrate the event fires.
          NULL
        }
      )
    ),

    # Output panel — shows current code, updates reactively
    div(
      style = "margin-top: 12px;",
      h4("Current Content"),
      pre(
        style = "background: #f5f5f5; padding: 12px; border-radius: 4px;",
        \() code()
      )
    )
  )
}

iridApp(App)
