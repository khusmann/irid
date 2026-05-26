# CodeMirror widget
#
# First non-trivial widget consumer: vets the IridWidget framework end-to-end
# against a real library. Single file by design — the dep ships an inline ES
# module that imports CodeMirror 6 from esm.sh and calls
# `irid.defineWidget("codemirror", ...)` at module-load time. No vendored
# bundle, no separate JS file, no `inst/widgets/cm6/` — useful as a demo;
# not viable for offline / air-gapped runs (CDN required).
#
# What the app exercises:
#   - A `When`-gated editor (mount/teardown via the detach walker).
#   - A reactive `language` prop — switching the `<select>` reconfigures
#     the editor's language extension via a CodeMirror 6 `Compartment`.
#   - A `<pre>` bound to `\() doc()` (visual confirmation of the round-trip).
#   - A character-count label and a `Lx:Cy` cursor display (the latter
#     fed by an `onCursorChanged` widget event, demonstrating multi-event
#     wrappers).
#   - A "Reset" button writing through `doc(...)` (programmatic update —
#     no sequence — applies even with the editor focused).

library(irid)
library(bslib)

CodeMirrorDeps <- function() {
  htmltools::htmlDependency(
    name    = "codemirror",
    version = "6.0.1",
    src     = c(href = "https://esm.sh/"),
    head    = htmltools::HTML('
<script type="module">
  import {basicSetup, EditorView}
    from "https://esm.sh/codemirror@6.0.2";
  import {EditorState, Compartment}
    from "https://esm.sh/@codemirror/state@6";
  import {javascript}
    from "https://esm.sh/@codemirror/lang-javascript@6";
  import {python}
    from "https://esm.sh/@codemirror/lang-python@6";
  import {dracula}
    from "https://esm.sh/thememirror@2";

  const LANGS = { javascript, python };
  const langExt = (name) => (LANGS[name] || LANGS.javascript)();

  window.irid.defineWidget("codemirror", function (el, props, send) {
    // Compartment wraps the language extension so it can be swapped at
    // runtime via `compartment.reconfigure(...)`. Without this, the
    // extension is committed at EditorState.create time and there is no
    // supported way to change the language live.
    const langCompartment = new Compartment();

    const view = new EditorView({
      parent: el,
      state: EditorState.create({
        doc: props.content,
        extensions: [
          basicSetup,
          langCompartment.of(langExt(props.language)),
          props.theme === "dracula" ? dracula : [],
          EditorView.updateListener.of(function (u) {
            if (u.docChanged) {
              send("change", { content: u.state.doc.toString() });
            } else if (u.selectionSet) {
              // Cursor move without a doc change — typing also moves
              // the cursor, but the doc-change branch already covers
              // that case, so this fires only on click / arrow-key /
              // selection moves.
              const head = u.state.selection.main.head;
              const line = u.state.doc.lineAt(head);
              send("cursor-changed", {
                line: line.number,
                ch: head - line.from
              });
            }
          })
        ]
      })
    });

    return {
      update: function (key, value, sequence) {
        if (key === "content") {
          const current = view.state.doc.toString();
          if (value === current) return;
          view.dispatch({
            changes: { from: 0, to: current.length, insert: value }
          });
        } else if (key === "language") {
          view.dispatch({
            effects: langCompartment.reconfigure(langExt(value))
          });
        }
        // theme is init-only in this demo — no branch.
      },
      destroy: function () { view.destroy(); }
    };
  });
</script>')
  )
}

CodeMirror <- function(
  content,
  language        = "javascript",
  theme           = "dracula",
  onChange        = NULL,
  onCursorChanged = NULL,
  .event          = NULL
) {
  # Omit the cursor-changed event registration when no handler is supplied
  # — keeps the managed-state table clean for callers who don't need it.
  events <- list(change = write_back(content, "content", then = onChange))
  if (!is.null(onCursorChanged)) {
    events[["cursor-changed"]] <- onCursorChanged
  }

  IridWidget(
    name   = "codemirror",
    props  = list(content = content, language = language, theme = theme),
    events = events,
    deps   = CodeMirrorDeps(),
    container = tags$div(
      class = "border rounded",
      style = "height: 300px; overflow: hidden;"
    ),
    .event = event_defaults(
      .event,
      change           = event_debounce(200, coalesce = TRUE),
      `cursor-changed` = event_throttle(100, coalesce = TRUE)
    )
  )
}

App <- function() {
  editor_open <- reactiveVal(TRUE)
  doc         <- reactiveVal("// Hello, irid widgets!\nconsole.log('hi');\n")
  language    <- reactiveVal("javascript")
  cursor      <- reactiveVal("")

  page_fluid(
    tags$div(
      class = "d-flex gap-3 mb-2 align-items-center flex-wrap",
      tags$label(
        class = "form-check form-switch m-0",
        tags$input(
          type  = "checkbox",
          class = "form-check-input",
          checked = editor_open
        ),
        tags$span(class = "form-check-label ms-1", "Show editor")
      ),
      tags$label(class = "m-0", "Language:"),
      tags$select(
        class = "form-select form-select-sm w-auto",
        value = language,
        tags$option(value = "javascript", "JavaScript"),
        tags$option(value = "python", "Python")
      ),
      tags$span(
        class = "text-muted",
        \() paste0("Length: ", nchar(doc()))
      ),
      tags$span(
        class = "text-muted",
        \() {
          c <- cursor()
          if (!nzchar(c)) "" else paste0("Cursor: ", c)
        }
      ),
      tags$button(
        class = "btn btn-sm btn-outline-secondary",
        onClick = \() doc("// reset\n"),
        "Reset"
      )
    ),
    When(
      editor_open,
      \() CodeMirror(
        content         = doc,
        language        = language,
        onCursorChanged = \(e) cursor(sprintf("L%d:C%d", e$line, e$ch))
      )
    ),
    tags$pre(
      class = "border rounded p-2 mt-2 bg-light",
      style = "min-height: 4em;",
      \() doc()
    )
  )
}

iridApp(App)
