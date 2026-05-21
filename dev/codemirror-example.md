# CodeMirror Widget Example — Construction Guide

**Location:** `examples/codemirror/`

This example demonstrates the full irid widget pattern: a CodeMirror editor
wrapped as an `IridWidget` with reactive channels for content and mode,
event handlers for change and cursor activity, and lifecycle management
inside a `When` block.

---

## File overview

```
examples/codemirror/
  app.R           — Shiny app entry point, registers resource path
  codemirror.R    — R-side component: deps, CodeMirror() constructor
  codemirror.js   — Client-side widget binding: init, events, channels
```

---

## The R side (`codemirror.R`)

### `codemirror_dep()`

Returns an `htmlDependency` for CodeMirror 5 from CDN.

**Important:** Uses the `head` field (raw HTML) instead of `src` + `script`.
This is because:

1. The mode scripts (`javascript.min.js`, `python.min.js`, …) must load
   **after** `codemirror.min.js` — they call `CodeMirror.defineMode()` at
   the top level, which requires the `CodeMirror` global.
2. Dynamically-inserted `<script>` tags (via `createContextualFragment` in
   `irid-swap`) load and execute in arbitrary order — separate tags don't
   guarantee order.
3. jsdelivr's `combine` endpoint concatenates multiple files into one
   response in order, solving the ordering problem with a single request.
4. The combine URL uses `@` and `,` characters. If passed through
   `src` + `script`, `renderDependencies` URL-encodes them (`%40`, `%2C`),
   producing a 404. The `head` field bypasses URL encoding.

```r
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
      "href=\"https://cdnjs.cloudflare.com/ajax/libs/",
      "codemirror/5.65.16/codemirror.min.css\" />"
    )
  )
}
```

### `widget_js_dep()`

Returns an `htmlDependency` for the local `codemirror.js` binding file.

Uses `href` source (not `file`) because the dependency is served via
`shiny::addResourcePath`, which is registered in `app.R`. The generated
URL is `<script src="codemirror-widget/codemirror.js">`.

```r
widget_js_dep <- function() {
  htmltools::htmlDependency(
    name = "codemirror-widget",
    version = "1.0.0",
    src = list(href = "codemirror-widget"),
    script = "codemirror.js"
  )
}
```

### `CodeMirror()` constructor

Wraps `IridWidget()`. Named args are split by `process_tags`:

| Arg | Type | Becomes |
|-----|------|---------|
| `content` | `reactiveVal` (callable) | Reactive channel |
| `mode` | `reactiveVal` (callable) | Reactive channel |
| `onChange` | function | Event handler (DOM event `change`) |
| `onCursorActivity` | function | Event handler (DOM event `cursoractivity`) |

Both dependencies (CDN + widget JS) are combined into `widget$dep` as a list:

```r
widget$dep <- list(widget$dep, widget_js_dep())
```

### Why `widget$dep` is a list

`attachDependencies()` in `process_tags` accepts both single dependencies
and lists. The CDN dep provides the CodeMirror library and modes; the widget
JS dep provides the `irid.registerWidget('codemirror', …)` call that bridges
CodeMirror to irid's widget protocol. Both must be present for the editor to
work.

---

## The app (`app.R`)

### Resource path registration

Before the app is created, a Shiny resource path is registered so the
browser can load the local `codemirror.js` file:

```r
shiny::addResourcePath("codemirror-widget", normalizePath("."))
```

This maps the URL `/codemirror-widget/codemirror.js` to the file on disk.
Without this, the `href`-based dependency would point to a nonexistent URL.

### Reactive state

Three reactive values drive the app:

- `code` — holds the editor content (string)
- `show_editor` — controls `When` activation (logical)
- `language` — holds the CodeMirror mode name (string)

### Widget inside `When`

The CodeMirror editor is rendered inside a `When` block:

```r
When(show_editor,
  yes = \() CodeMirror(
    content = code,
    mode = language,
    onChange = \(event) code(event$value)
  )
)
```

When `show_editor` becomes `TRUE`, the `yes` branch creates the widget:
1. `CodeMirror()` returns an `irid_widget` object
2. `process_tags` assigns an ID, extracts channels and events
3. `irid-swap` inserts the widget HTML (with dependencies) between the
   When anchor pair
4. `irid-widget-init` is sent; the widget JS polls for `CodeMirror`,
   initializes the editor
5. Channel observers send content/mode updates reactively

When `show_editor` becomes `FALSE`, `$destroy()` fires, sending
`irid-widget-destroy`, and the editor element is removed from the DOM.

---

## The JavaScript side (`codemirror.js`)

### Registration

```js
irid.registerWidget('codemirror', function(msg) { … });
```

The init function receives the full `irid-widget-init` message:

```js
{
  id: "irid-7",
  widget: "codemirror",
  render_channel: null,
  config: {},
  channels: {
    content: "# Type some code here…",
    mode: "python"
  }
}
```

### CDN polling

The init function polls for `CodeMirror` to be defined (50ms intervals)
before initializing. This handles the case where the combined CDN script
hasn't finished loading by the time the widget init function runs (the
init may have been queued by `irid.js` while the script loads, then
flushed when the script registers).

```js
function tryInit() {
  if (typeof CodeMirror === 'undefined') {
    setTimeout(tryInit, 50);
    return;
  }
  var editor = CodeMirror(el, { … });
  // …
}
tryInit();
```

### Echo suppression

A `lastSentContent` variable tracks the value sent in the most recent
`irid.sendEvent` call. Content channel updates that match it are skipped
(they're server echoes of the user's own typing). Additionally, all content
channel updates are skipped while the editor has focus, preventing cursor
jump during fast typing:

```js
if (editor.hasFocus()) {
  lastSentContent = null;
  return;
}
if (lastSentContent !== null && detail.value === lastSentContent) {
  lastSentContent = null;
  return;
}
```

---

## The init-deferred queue in `irid.js`

When `irid-widget-init` fires before `codemirror.js` has loaded (the
scripts are still being fetched), the widget init is queued:

```js
Shiny.addCustomMessageHandler('irid-widget-init', function(msg) {
  var init = irid.widgets[msg.widget];
  if (init) {
    init(msg);
  } else {
    irid._pendingInits[msg.widget] = irid._pendingInits[msg.widget] || [];
    irid._pendingInits[msg.widget].push(msg);
  }
});
```

When the script finishes loading and calls `irid.registerWidget`, the
queue is flushed:

```js
irid.registerWidget = function(name, initFn) {
  irid.widgets[name] = initFn;
  var pending = irid._pendingInits[name];
  if (pending) {
    for (var i = 0; i < pending.length; i++) initFn(pending[i]);
    delete irid._pendingInits[name];
  }
};
```

This two-phase init (queue → register → flush) handles the fundamental
race between custom message processing and dynamic script loading.

---

## Dependency rendering for custom messages

`htmltools::as.character()` on a `shiny.tag` strips all `html_dependency`
metadata — the output HTML has no `<script>` or `<link>` tags. This is by
design (Shiny's output pipeline processes dependencies separately), but
irid's control flow sends raw HTML over `irid-swap` / `irid-mutate`
messages, bypassing that pipeline.

Every tag rendered for a custom message must have its dependencies
rendered manually. The `render_tag_html()` helper in `R/mount.R` does this:

```r
render_tag_html <- function(tag) {
  deps <- htmltools::findDependencies(tag)
  dep_html <- if (length(deps) > 0L) {
    as.character(htmltools::renderDependencies(deps))
  } else {
    ""
  }
  tag_html <- as.character(tag)
  paste0(dep_html, "\n", tag_html)
}
```

This is used at all four serialization sites in `mount.R`:
When, Each (keyed), Each (positional), and Match.
