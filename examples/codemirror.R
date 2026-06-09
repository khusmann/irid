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
#   - A character-count label and a `Lx:Cy` cursor display, the latter fed
#     by a **two-way bound `cursor` prop** ({line, ch}) — the editor pushes
#     selection moves via `setProp("cursor", ...)`, and a "Go to top" button
#     writes the prop back to reposition the editor.
#   - A `focus-changed` widget event (genuine notification, no prop) driving
#     a focus indicator — demonstrates multi-channel wrappers.
#   - A "Reset" button writing through `doc(...)` (programmatic update —
#     no sequence — applies even with the editor focused).
#   - A "Restore snippet" button writing `content` + `cursor` in one flush —
#     coalesced into a single batched `update({content, cursor})`.
#
# Server-update marker: every `view.dispatch` the `update` hook makes carries
# a CM6 `Annotation` (`SERVER_UPDATE`). The `updateListener` checks for it and
# skips the `setProp` write-back for server-initiated transactions. This is
# the wrapper-author's loop-breaker: without it, a server doc replace
# repositions the cursor and fires a spurious `selectionSet` -> `setProp`,
# echoing the server's own write straight back. The annotation is how the
# wrapper distinguishes "the user moved" from "the server moved me".

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
  import {EditorState, Compartment, Annotation}
    from "https://esm.sh/@codemirror/state@6";
  import {javascript}
    from "https://esm.sh/@codemirror/lang-javascript@6";
  import {python}
    from "https://esm.sh/@codemirror/lang-python@6";
  import {dracula}
    from "https://esm.sh/thememirror@2";

  const LANGS = { javascript, python };
  const langExt = (name) => (LANGS[name] || LANGS.javascript)();

  // Marks transactions the `update` hook dispatches, so the updateListener
  // can tell a server-applied change from a genuine user edit and avoid
  // echoing the server\'s own write straight back through setProp.
  const SERVER_UPDATE = Annotation.define();

  window.irid.defineWidget("codemirror", function (el, props, sendEvent, setProp) {
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
            // Skip write-backs for changes the server applied. Without this
            // guard, a server doc replace (or cursor move) would bounce
            // straight back through setProp, racing the real echo.
            const fromServer = u.transactions.some(
              (tr) => tr.annotation(SERVER_UPDATE)
            );
            if (u.docChanged && !fromServer) {
              // `content` is a two-way prop — push the new value back
              // through the prop channel, not a fake event.
              setProp("content", u.state.doc.toString());
            }
            if (u.selectionSet && !fromServer) {
              // `cursor` is a two-way bound prop — push every *user*
              // selection move (clicks, arrows, typing) through the prop
              // channel. Server-repositioned cursors are filtered above.
              const head = u.state.selection.main.head;
              const line = u.state.doc.lineAt(head);
              setProp("cursor", {
                line: line.number,
                ch: head - line.from
              });
            }
            if (u.focusChanged) {
              // A genuine notification with no corresponding prop.
              sendEvent("focus-changed", { focused: view.hasFocus });
            }
          })
        ]
      })
    });

    return {
      // Batched contract: `values` is a {attr -> value} map carrying every
      // prop that changed in one server flush (one or more keys). All keys
      // are folded into ONE `view.dispatch` so content + cursor + language
      // land as a single atomic transaction — no intermediate render.
      update: function (values) {
        const spec = {};

        // Resolve cursor against the post-update text: if content is also
        // in this batch, positions are computed against the NEW string so
        // the explicit selection stays in range.
        const targetText = "content" in values
          ? values.content
          : view.state.doc.toString();

        if ("content" in values && values.content !== view.state.doc.toString()) {
          spec.changes = {
            from: 0,
            to: view.state.doc.length,
            insert: values.content
          };
        }
        if ("language" in values) {
          spec.effects = langCompartment.reconfigure(langExt(values.language));
        }
        if ("cursor" in values) {
          const lines = targetText.split("\\n");
          const lineNo = Math.max(1, Math.min(values.cursor.line, lines.length));
          let pos = 0;
          for (let i = 0; i < lineNo - 1; i++) pos += lines[i].length + 1;
          pos += Math.min(values.cursor.ch, lines[lineNo - 1].length);
          if (pos !== view.state.selection.main.head) {
            spec.selection = { anchor: pos, head: pos };
          }
        }
        // theme is init-only in this demo — no branch.

        if ("changes" in spec || "selection" in spec || "effects" in spec) {
          // Mark the transaction as server-applied so the updateListener
          // doesn\'t echo it straight back through setProp.
          spec.annotations = SERVER_UPDATE.of(true);
          view.dispatch(spec);
        }
      },
      destroy: function () { view.destroy(); }
    };
  });
</script>')
  )
}

CodeMirror <- function(
  content,
  cursor         = NULL,
  language       = "javascript",
  theme          = "dracula",
  onFocusChanged = NULL
) {
  IridWidget(
    name   = "codemirror",
    props  = list(
      # `content` is two-way: the editor pushes edits via setProp("content").
      # `merge` layers the caller's reactive over a wrapper default timing,
      # so a caller can still override the debounce.
      content  = merge(irid_wire(timing = irid_debounce(200)), content),
      # `cursor` is two-way: the editor pushes selection moves via
      # setProp("cursor"), and a server write repositions the editor.
      cursor   = merge(irid_wire(timing = irid_throttle(100)), cursor),
      language = language,   # two-way-capable, but one-way in practice
      theme    = theme
    ),
    events = list(
      # A genuine notification (no corresponding prop). Optional — when
      # `onFocusChanged` is NULL the merge resolves to a subject-less wire
      # and IridWidget drops the entry.
      `focus-changed` = merge(irid_wire(timing = irid_immediate()),
                              onFocusChanged)
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
  cursor      <- reactiveVal(list(line = 1, ch = 0))
  focused     <- reactiveVal(FALSE)

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
          paste0("Cursor: L", c$line, ":C", c$ch)
        }
      ),
      tags$span(
        class = "text-muted",
        \() if (isTRUE(focused())) "focused" else "blurred"
      ),
      tags$button(
        class = "btn btn-sm btn-outline-secondary",
        # Server write through the cursor prop — repositions the editor.
        onClick = \() cursor(list(line = 1, ch = 0)),
        "Go to top"
      ),
      tags$button(
        class = "btn btn-sm btn-outline-secondary",
        onClick = \() doc("// reset\n"),
        "Reset"
      ),
      tags$button(
        class = "btn btn-sm btn-outline-primary",
        # Coordinated same-flush multi-write: both bound props change in one
        # flush, so the framework coalesces them into ONE `irid-attr` with a
        # two-key `values` map -> one `update({content, cursor})` -> one
        # `view.dispatch`. This is the batching path the design enables.
        onClick = \() {
          doc("function greet(name) {\n  return `hi ${name}`;\n}\n")
          cursor(list(line = 2, ch = 9))
        },
        "Restore snippet"
      )
    ),
    When(
      editor_open,
      \() CodeMirror(
        content        = doc,
        cursor         = cursor,
        language       = language,
        onFocusChanged = \(e) focused(e$focused)
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
