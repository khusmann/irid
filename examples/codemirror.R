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
#   - A `<pre>` bound to `\() doc()` (visual confirmation of the round-trip).
#   - A character-count label (proves the reactive participates normally in
#     the rest of the tree).
#   - A "Reset" button writing through `doc(...)` (programmatic update — no
#     sequence — applies even with the editor focused).

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
  import {EditorState}
    from "https://esm.sh/@codemirror/state@6";
  import {javascript}
    from "https://esm.sh/@codemirror/lang-javascript@6";
  import {dracula}
    from "https://esm.sh/thememirror@2";

  const LANGS = { javascript };

  window.irid.defineWidget("codemirror", function (el, props, send) {
    const view = new EditorView({
      parent: el,
      state: EditorState.create({
        doc: props.content,
        extensions: [
          basicSetup,
          (LANGS[props.language] || LANGS.javascript)(),
          props.theme === "dracula" ? dracula : [],
          EditorView.updateListener.of(function (u) {
            if (u.docChanged) {
              send("change", { content: u.state.doc.toString() });
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
        }
        // theme / language are init-only in this minimal demo — no branch.
      },
      destroy: function () { view.destroy(); }
    };
  });
</script>')
  )
}

CodeMirror <- function(
  content,
  language = "javascript",
  theme    = "dracula",
  onChange = NULL,
  .event   = NULL
) {
  IridWidget(
    name   = "codemirror",
    props  = list(content = content, language = language, theme = theme),
    events = list(change = write_back(content, "content", then = onChange)),
    deps   = CodeMirrorDeps(),
    container = tags$div(
      class = "border rounded",
      style = "height: 300px; overflow: hidden;"
    ),
    .event = event_defaults(
      .event,
      change = event_debounce(200, coalesce = TRUE)
    )
  )
}

App <- function() {
  editor_open <- reactiveVal(TRUE)
  doc <- reactiveVal("// Hello, irid widgets!\nconsole.log('hi');\n")

  page_fluid(
    tags$div(
      class = "d-flex gap-3 mb-2 align-items-center",
      tags$label(
        class = "form-check form-switch m-0",
        tags$input(
          type = "checkbox",
          class = "form-check-input",
          checked = editor_open
        ),
        tags$span(class = "form-check-label ms-1", "Show editor")
      ),
      tags$span(
        class = "text-muted",
        \() paste0("Length: ", nchar(doc()))
      ),
      tags$button(
        class = "btn btn-sm btn-outline-secondary",
        onClick = \() doc("// reset\n"),
        "Reset"
      )
    ),
    When(
      editor_open,
      \() CodeMirror(content = doc)
    ),
    tags$pre(
      class = "border rounded p-2 mt-2 bg-light",
      style = "min-height: 4em;",
      \() doc()
    )
  )
}

iridApp(App)
