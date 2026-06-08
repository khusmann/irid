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
            }
            if (u.selectionSet) {
              // Fires on every selection move — clicks, arrow keys,
              // and typing (typing advances the cursor). Independent
              // of the docChanged branch so the cursor display stays
              // accurate during typing. Safe to fire alongside change
              // because the framework\'s force-send-on-no-op is now
              // scoped per-binding: this event\'s handler (the
              // wrapper\'s `onCursorChanged`) declares no write target,
              // so it doesn\'t fan out to the `content` binding.
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
      update: function (key, value) {
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

# Local helper: resolve per-event timing from caller's `.event` —
# scalar broadcasts, list lookup, fallback to default. Local because
# scalar-broadcast `.event` and this helper are slated for removal in
# 0.3.0 (the `.event` floor will accept `on*` keys, and the per-event
# `event_pick(...)` call collapses to `.event$onName %||% default`).
event_pick <- function(user, key, default) {
  if (is.null(user)) return(default)
  if (inherits(user, "irid_event_config")) return(user)
  if (is.list(user)) {
    val <- user[[key]]
    if (!is.null(val)) return(val)
  }
  default
}

CodeMirror <- function(
  content,
  language        = "javascript",
  theme           = "dracula",
  onChange        = NULL,
  onCursorChanged = NULL,
  .event          = NULL
) {
  IridWidget(
    name   = "codemirror",
    props  = list(content = content, language = language, theme = theme),
    events = list(
      widget_event(
        name    = "change",
        handler = write_back(content, "content", then = onChange),
        timing  = event_pick(.event, "change", irid_debounce(200))
      ),
      widget_event(
        name    = "cursor-changed",
        handler = onCursorChanged,
        timing  = event_pick(.event, "cursor-changed", irid_throttle(100))
      )
    ),
    deps   = CodeMirrorDeps(),
    container = tags$div(
      class = "border rounded",
      style = "height: 300px; overflow: hidden;"
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
