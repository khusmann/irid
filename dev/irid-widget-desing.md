# irid Widget Mechanism Design

## Problem

irid's event system is built around DOM events. When a user writes:

```r
tags$input(value = text, onInput = \(e) update(e$value))
```

`process_tags` extracts the `onInput` handler, `mount` registers a DOM event
listener on the client, and `buildPayload` in `irid.js` reads the DOM event
object to construct the payload sent to R.

This works for native HTML elements. But JS libraries (CodeMirror, Monaco,
Leaflet, D3, charting libraries, etc.) expose their own callback API — not
DOM events. Their events carry library-specific data (cursor positions,
selected features, zoom levels, data point indices) that the DOM event
object doesn't contain.

`htmlwidgets` solves this via a rigid lifecycle contract: every widget
implements `renderValue()`, `resize()`, and receives a monolithic JSON blob.
Each package reinvents the wiring in its own way, and the file-naming
convention (`binding.js`) is loose enough that there's no reliable way to
introspect or compose widgets.

## Goal

Design a mechanism for coupling arbitrary JS library events and data with
irid's reactive event system that:

1. **Completes the event protocol** — gives user JS a programmatic way to
   fire irid events (the missing piece for non-DOM event sources).
2. **Stays minimal** — one JS primitive, one R constructor, zero new message
   types that duplicate existing protocol.
3. **Aligns with irid's philosophy** — functions, not expressions; fine-grained
   reactivity; composable components.
4. **Uses `htmlDependency` for bundling** — no special package structure
   beyond what `htmltools` already provides.
5. **Is packageable** — the same convention works for ad-hoc app code and
   published packages.

## Scope

This document covers the first-class widget mechanism: a protocol where
a JS library receives data from R and sends events back, with full lifecycle
management (init, update, destroy). It does **not** cover:

- **Stateless DOM enhancements** (e.g. a tooltip library that reads `title`
  attributes). Those can use `htmlDependency` directly with no irid support
  beyond what `htmltools` already provides.
- **Simple wrapper components** where the JS library fires DOM events on the
  container element (e.g. a custom `<select>` polyfill that dispatches native
  `change` events). Those already work with irid's existing DOM event protocol
  — no new mechanism needed.

---

## Design

The mechanism has three layers:

### Layer 1: JS primitive — `irid.sendEvent()`

**What:** A function added to `window.irid` that lets any JS code trigger an
irid event programmatically, using the same input-naming convention and
optimistic-update sequence tracking as DOM events.

```js
irid.sendEvent(elementId, eventName, payload);
```

**How it works:**

```
payload ← merge(payload, { id: elementId, nonce: random, __irid_seq: ++seq })
inputId ← "irid_ev_" + elementId + "_" + eventName
Shiny.setInputValue(inputId, payload, { priority: "event" })
```

- `elementId` must match the `id` attribute of an element in the DOM.
- `eventName` becomes the event type (e.g. `"select"`, `"cursorActivity"`).
- `payload` is a plain object of key/value pairs. The R side receives these
  as named fields in the `event` object passed to the handler.
- `id`, `nonce`, and `__irid_seq` are added automatically (same as
  `buildPayload` for DOM events); they are stripped before the user's
  handler sees the event object.
- The sequence counter (`sequences[elementId]`) is shared between DOM events
  and `sendEvent` calls on the same element, so optimistic-update gating
  works uniformly.

**Why this is Layer 1:** Without `sendEvent`, there is no way for a JS
library to inject data into irid's reactive pipeline. Everything else builds
on this.

---

### Layer 2: R primitive — `IridWidget()`

A constructor that creates a widget node — the R-side counterpart of a JS
library binding. `process_tags` and `mount` handle it as a first-class irid
construct, just like `Each`, `When`, and `Match`.

```r
IridWidget(
  dep,                  # htmlDependency for the widget's JS/CSS
  container,            # function(id) that returns the HTML container tag

  # Reactive data channels (R → client) -------------------
  # Named arguments become data channels. Each is observed
  # and pushed to the client as a custom message.
  #   - A reactiveVal / reactive / function: observed, sent on change
  #   - A static value: sent once on init, never observed
  ... ,

  # Event handlers (client → R) ---------------------------
  # Named with on* prefix, like irid's event convention.
  # Processed exactly like on* attributes on regular tags.
  # The JS dispatches events via irid.sendEvent().
  on* = function(event, id) { ... },

  # Static configuration -----------------------------------
  .config = list(...),  # sent once on init, merged with bindings
  .event = ...,         # timing config (same as element-level .event)
  .theme = NULL         # optional htmlDependency for CSS only
)
```

**What `process_tags` does with a widget node:**

1. **Assigns an ID** using the shared counter (or reuses a user-provided `id`
   from the container).
2. **Calls `container(id)`** to produce the static HTML element. The container
   MUST include `id` in its attributes — `process_tags` ensures this.
3. **Separates bindings from event handlers**: named args that are functions
   become reactive data channels; `on*` args become event entries (same as
   regular tags).
4. **Attaches the dependency** via `htmltools::attachDependencies`.
5. **Records a widget entry** in the result, containing:
   - `id` — the element ID
   - `config` — static config merged with initial binding values
   - `channels` — named list of reactive getter functions (observed)

**What `mount` does with a widget entry:**

1. **Sends `irid-widget-init`** on mount: a custom message with
   `{id, config, channels}` where `channels` maps channel names → initial
   values. The JS receives this and initializes the library.
2. **Creates observers** for each reactive channel. On change, sends
   `irid-widget-channel` with `{id, channel, value}`.
3. **Registers event handlers** exactly like regular events — `observeEvent`
   on `session$input[[paste0("irid_ev_", id, "_", eventName)]]`.
4. **Sends `irid-widget-destroy`** on unmount (via `$destroy()`), so the JS
   can tear down the library instance.

---

### Layer 3: JS conventions — the client side

A widget's JavaScript registers itself by listening for `irid-widget-init`
messages and filtering on `msg.id` or a CSS class.

```js
// In the widget's JS bundle
Shiny.addCustomMessageHandler('irid-widget-init', function(msg) {
  if (!msg.containerClass || !el.matches(msg.containerClass)) return;

  var el = document.getElementById(msg.id);
  if (!el) return;

  // Initialize the library on the container element
  var widget = new SomeLibrary(el, msg.config);

  // Set initial values for data channels
  if (msg.channels.content) widget.setValue(msg.channels.content);
  if (msg.channels.options)  widget.setOptions(msg.channels.options);

  // Forward library events to irid
  widget.on('select', function(data) {
    irid.sendEvent(msg.id, 'select', data);
  });
  widget.on('change', function(data) {
    irid.sendEvent(msg.id, 'input', data);
  });

  // Listen for R → client data updates
  Shiny.addCustomMessageHandler('irid-widget-channel', function(update) {
    if (update.id !== msg.id) return;
    if (update.channel === 'content') widget.setValue(update.value);
    if (update.channel === 'options')  widget.setOptions(update.value);
  });

  // Cleanup
  Shiny.addCustomMessageHandler('irid-widget-destroy', function(destroy) {
    if (destroy.id !== msg.id) return;
    widget.destroy();
  });
});
```

**Simpler alternative — class-based dispatch:**

Instead of each widget registering its own `irid-widget-init` handler (which
would conflict across widgets), the irid `irid.js` runtime can dispatch to
registered widget initializers:

```js
// In irid.js
window.irid = window.irid || {};
irid.widgets = irid.widgets || {};

// Widgets register themselves
irid.registerWidget = function(name, initFn) {
  irid.widgets[name] = initFn;
};

// irid.js handles the init message and dispatches
Shiny.addCustomMessageHandler('irid-widget-init', function(msg) {
  var init = irid.widgets[msg.widget];
  if (init) init(msg);
});
```

The widget's HTML container carries `data-irid-widget="widgetName"` which
mount includes in the init message. The JS registers:

```js
irid.registerWidget('codemirror', function(msg) {
  var el = document.getElementById(msg.id);
  // ... setup ...
});
```

This avoids handler-name conflicts and lets irid manage the message
handlers centrally. But it also requires a registry, which is a mild
departure from the "no framework" approach. Both approaches are viable;
the non-registry approach (each widget adds its own handler) is simpler
for single-use widgets but requires care with handler naming.

**Recommendation:** Use a registry (`irid.registerWidget`) for shareable
widget packages, and direct `Shiny.addCustomMessageHandler` for ad-hoc
app code. irid.js provides both the `sendEvent()` primitive and the
optional registry.

---

## Message Protocol Summary

| Direction | Message | When | Payload |
|-----------|---------|------|---------|
| R → client | `irid-widget-init` | On mount | `{id, widget, config, channels: {name: value, ...}}` |
| R → client | `irid-widget-channel` | Reactive channel fires | `{id, channel: "name", value: ...}` |
| R → client | `irid-widget-destroy` | On unmount | `{id}` |
| Client → R | `irid.sendEvent()` | Library callback fires | Uses existing `irid_ev_{id}_{event}` input |

Client → R events use the exact same pipeline as DOM events: same input
naming, same `observeEvent` in mount, same optimistic-update sequence
tracking. The R side sees no difference between a DOM event and a
library event.

R → client data channels are separate from `irid-attr`/`irid-text` because
widget data is arbitrary JSON (nested objects, arrays) rather than a DOM
attribute string. Using `irid-attr` for complex data would require
`JSON.stringify` / `JSON.parse` round-trips at every update.
`irid-widget-channel` carries the value verbatim.

---

## Usage Examples

### Example 1: Simple counter widget (ad-hoc, no registry)

**JS** (`counter-widget.js`):

```js
(function() {
  Shiny.addCustomMessageHandler('irid-widget-init', function(msg) {
    if (msg.widget !== 'counter') return;
    var el = document.getElementById(msg.id);
    if (!el) return;

    var count = msg.config.initial || 0;
    el.textContent = count;

    el.addEventListener('click', function() {
      count++;
      el.textContent = count;
      irid.sendEvent(msg.id, 'click', { count: count });
    });
  });
})();
```

**R** (`counter.R`):

```r
counter_dep <- function() {
  htmltools::htmlDependency(
    "counter-widget", "1.0.0",
    src = system.file("counter", package = "mywidgets"),
    script = "counter-widget.js"
  )
}

Counter <- function(initial = 0, onClick = NULL) {
  IridWidget(
    dep = counter_dep(),
    container = \(id) tags$span(id = id, class = "irid-widget counter"),
    .config = list(initial = initial),
    onClick = onClick
  )
}
```

**Usage:**

```r
App <- function() {
  clicks <- reactiveVal(0)
  Counter(
    initial = 5,
    onClick = \(e) clicks(e$count)
  )
}
```

---

### Example 2: CodeMirror editor (packaged widget)

**R** (`iridCodeMirror/R/codemirror.R`):

```r
codemirror_dep <- function() {
  htmltools::htmlDependency(
    "codemirror", "5.65.0",
    src = system.file("codemirror", package = "iridCodeMirror"),
    script = "codemirror-bundle.js",
    stylesheet = "codemirror.css"
  )
}

CodeMirror <- function(
  content,
  mode = "javascript",
  theme = "default",
  onChange = NULL,
  onCursorActivity = NULL
) {
  IridWidget(
    dep = codemirror_dep(),
    container = \(id) tags$div(
      id = id,
      class = "irid-widget codemirror",
      style = "height: 400px; border: 1px solid #ccc;"
    ),
    content = content,                     # reactive data channel
    .config = list(mode = mode, theme = theme),
    onChange = onChange,                   # event handler
    onCursorActivity = onCursorActivity    # event handler
  )
}
```

**JS** (`codemirror-bindings.js`):

```js
irid.registerWidget('codemirror', function(msg) {
  var el = document.getElementById(msg.id);
  if (!el) return;

  var editor = CodeMirror(el, {
    value: msg.channels.content || '',
    mode: msg.config.mode || 'javascript',
    theme: msg.config.theme || 'default',
    lineNumbers: true
  });

  editor.on('change', function() {
    irid.sendEvent(msg.id, 'change', { value: editor.getValue() });
  });

  editor.on('cursorActivity', function() {
    var cursor = editor.getCursor();
    irid.sendEvent(msg.id, 'cursoractivity', {
      line: cursor.line,
      ch: cursor.ch
    });
  });
});

// Handle content updates from R
Shiny.addCustomMessageHandler('irid-widget-channel', function(msg) {
  if (msg.channel !== 'content') return;
  // Find the editor instance for this element
  var el = document.getElementById(msg.id);
  if (!el || !el.CodeMirror) return;
  var cursor = el.CodeMirror.getCursor();
  el.CodeMirror.setValue(msg.value);
  el.CodeMirror.setCursor(cursor);
});
```

**Usage:**

```r
App <- function() {
  text <- reactiveVal("# Hello\n\nWorld")
  src <- reactiveVal("console.log('hello')")

  page_fluid(
    CodeMirror(content = text, mode = "markdown"),
    CodeMirror(content = src, mode = "javascript",
      onChange = \(e) print(paste("Changed:", nchar(e$value))))
  )
}
```

---

### Example 3: Leaflet map

```r
LeafletMap <- function(
  center = c(0, 0),
  zoom = 2,
  markers = NULL,
  onClick = NULL,
  onMarkerClick = NULL
) {
  IridWidget(
    dep = leaflet_dep(),
    container = \(id) tags$div(
      id = id,
      class = "irid-widget leaflet-map",
      style = "height: 500px;"
    ),
    center = center,        # reactive or static
    zoom = zoom,            # reactive or static
    markers = markers,       # reactive or static
    onClick = onClick,
    onMarkerClick = onMarkerClick,
    .config = list(tiles = "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
  )
}
```

---

## Comparison with htmlwidgets

| Aspect | htmlwidgets | irid IridWidget |
|--------|-------------|-----------------|
| State model | Monolithic JSON blob per render | Fine-grained reactive channels |
| R → client | `renderValue(x)` — full redraw per update | Per-channel messages — update only what changed |
| Client → R | Single `event` callback struct | Standard irid event handlers with timing config |
| Lifecycle | Fixed file structure (`binding.js`, `widget.yaml`) | Anything an `htmlDependency` can bundle |
| Composability | Hard — widgets are islands | Widgets are components; nest in When/Each/Match |
| Event timing | No rate limiting | Full `event_*` config through `.event` |
| Optimistic updates | Not supported | Automatic via sequence protocol |

The key difference: htmlwidgets treats a widget as a black box with one
giant data pipe in each direction. irid treats a widget as a component
with many small data channels, each independently reactive.

---

## Changes to irid codebase

The following changes are needed to implement this design.

### `inst/js/irid.js` — Add `irid.sendEvent()` and optional widget registry

```js
// --- Programmatic event dispatch for JS libraries ---
// Shares the sequence counter and input-naming convention
// with DOM events, so optimistic-update tracking works
// uniformly.

window.irid = window.irid || {};

irid.sendEvent = function(elementId, eventName, payload) {
  var inputId = 'irid_ev_' + elementId + '_' + eventName;
  payload = payload || {};
  payload.id = elementId;
  payload.nonce = Math.random();
  if (!sequences[elementId]) sequences[elementId] = 0;
  payload.__irid_seq = ++sequences[elementId];
  sendPayload(inputId, payload);
};

// Optional widget registry — dispatched from irid-widget-init
irid.widgets = irid.widgets || {};
irid.registerWidget = function(name, initFn) {
  irid.widgets[name] = initFn;
};

Shiny.addCustomMessageHandler('irid-widget-init', function(msg) {
  var init = irid.widgets[msg.widget];
  if (init) init(msg);
});

Shiny.addCustomMessageHandler('irid-widget-channel', function(msg) {
  var widget = document.getElementById(msg.id);
  if (!widget) return;
  // Dispatch a custom event on the element so widget code
  // can listen without managing multiple Shiny handlers
  var event = new CustomEvent('irid-widget-channel', {
    detail: { channel: msg.channel, value: msg.value }
  });
  widget.dispatchEvent(event);
});

Shiny.addCustomMessageHandler('irid-widget-destroy', function(msg) {
  var widget = document.getElementById(msg.id);
  if (!widget) return;
  var event = new CustomEvent('irid-widget-destroy', { detail: msg });
  widget.dispatchEvent(event);
});
```

**Why custom events on the element:** Instead of each widget registering
its own `irid-widget-channel` handler (which would require unique handler
names or filtering on `msg.id`), we dispatch a DOM custom event on the
widget element. Widget code listens on its own element:

```js
el.addEventListener('irid-widget-channel', function(e) {
  if (e.detail.channel === 'content') {
    editor.setValue(e.detail.value);
  }
});

el.addEventListener('irid-widget-destroy', function() {
  editor.toTextArea(); // or whatever teardown is needed
});
```

This avoids handler-name conflicts entirely — every widget type uses the
same `irid-widget-channel` / `irid-widget-destroy` message types, and
dispatch happens by element ID, not by handler name.

### `R/process_tags.R` — Handle `irid_widget` nodes

Add a branch in `process_tags`'s `walk()` function, similar to the existing
`irid_output` / `irid_each` / `irid_match` / `irid_when` branches:

```r
if (inherits(node, "irid_widget")) {
  id <- next_id()

  # Separate dot-dot-dot args into:
  # - channels: named reactive bindings (non-on* functions)
  # - events: on* handlers (same as regular tag events)
  # - static: non-function values (passed through to config)

  channels <- list()
  events <- list()
  static_config <- node$.config

  for (nm in setdiff(names(node$args), ".config")) {
    val <- node$args[[nm]]
    if (grepl("^on[A-Z]", nm)) {
      js_event <- tolower(sub("^on", "", nm))
      events[[length(events) + 1L]] <- list(
        event = js_event,
        id = id,
        handler = val,
        autobind = FALSE
      )
    } else if (is_irid_reactive(val)) {
      channels[[nm]] <- val
    } else {
      static_config[[nm]] <- val
    }
  }

  # Resolve timing for events (same as regular tags)
  element_event_lookup <- normalize_element_event(node$.event)
  for (i in seq_along(events)) {
    e <- events[[i]]
    cfg <- resolve_event_config(e$event, element_event_lookup)
    events[[i]]$mode <- cfg$mode
    events[[i]]$ms <- cfg$ms
    events[[i]]$leading <- cfg$leading
    events[[i]]$coalesce <- cfg$coalesce
    events[[i]]$prevent_default <- FALSE
  }

  # Add to result
  result$widgets[[length(result$widgets) + 1L]] <<- list(
    id = id,
    dep = node$dep,
    widget_name = node$widget_name,
    channels = channels,
    config = static_config
  )

  # Also merge events into the main events list
  result$events <- c(result$events, events)

  # Produce the container
  container <- node$container(id)
  container$attribs$id <- id
  return(htmltools::attachDependencies(container, node$dep))
}
```

### `R/mount.R` — Wire up widget lifecycle

Add widget mounting in `irid_mount_processed`, after the existing event and
binding setup:

```r
# Mount widgets
for (w in result$widgets) {
  # Get initial values for all channels
  initial_channels <- list()
  for (nm in names(w$channels)) {
    initial_channels[[nm]] <- shiny::isolate(w$channels[[nm]]())
  }

  # Send init message
  session$sendCustomMessage("irid-widget-init", list(
    id = w$id,
    widget = w$widget_name,
    config = w$config,
    channels = initial_channels
  ))

  # Set up observers for each reactive channel
  for (nm in names(w$channels)) {
    local({
      channel_name <- nm
      channel_fn <- w$channels[[nm]]
      wid <- w$id
      obs <- shiny::observe({
        val <- channel_fn()
        session$sendCustomMessage("irid-widget-channel", list(
          id = wid,
          channel = channel_name,
          value = val
        ))
      })
      observers[[length(observers) + 1L]] <<- obs
    })
  }

  # Track for destroy
  widget_ids <- c(widget_ids, w$id)
}
```

Add destroy logic:

```r
# In the destroy function
for (wid in widget_ids) {
  session$sendCustomMessage("irid-widget-destroy", list(id = wid))
}
```

### `R/irid_widget.R` — New file with the `IridWidget()` constructor

```r
#' Create an irid widget node
#'
#' A first-class irid construct that wraps a JS library as a reactive
#' component. Widgets receive fine-grained data via named channels
#' (R → client) and send events back via standard irid `on*` handlers
#' (client → R), using `irid.sendEvent()`.
#'
#' @param dep An `htmlDependency` containing the widget's JS code.
#' @param container A function `function(id)` that returns the widget's
#'   HTML container tag. The tag must include the `id` attribute.
#' @param ... Named arguments. Functions with `on*` names become event
#'   handlers. Other functions become reactive data channels (observed
#'   and pushed to the client on change). Static values are sent once
#'   on init.
#' @param .config Static configuration merged with non-reactive named
#'   args and sent to the client on init.
#' @param .event Optional event timing config (same as the element-level
#'   `.event` prop).
#' @param .widget_name A string identifying the widget type on the
#'   client. Defaults to the first registered JS widget matching the
#'   container's class.
#' @return An irid widget node.
#' @export
IridWidget <- function(dep, container, ..., .config = list(),
                       .event = NULL, .widget_name = NULL) {
  args <- list(...)
  structure(
    list(
      dep = dep,
      container = container,
      args = args,
      .config = .config,
      .event = .event,
      widget_name = .widget_name %||% extract_widget_name(dep)
    ),
    class = "irid_widget"
  )
}

extract_widget_name <- function(dep) {
  # Default: derive from the dependency name
  gsub("[-_]", "", dep$name)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
```

---

## Packaging Convention

An irid widget package follows a simple structure. The key rule: the
JS code is bundled as an `htmlDependency`. Beyond that, no scaffolding
is required.

```
iridCodeMirror/
  R/
    codemirror.R          # CodeMirror() component function
  inst/
    codemirror/
      codemirror-bundle.js   # CodeMirror library + irid bindings
      codemirror.css         # CodeMirror styles
    javascript/              # Alternative: irid loads anything from script=
      ...                    #   in the htmlDependency
  DESCRIPTION
  NAMESPACE
```

The `htmlDependency` can reference files from `inst/` (or a package
subdirectory). The JS code can use either the registry pattern
(`irid.registerWidget('name', initFn)`) or direct
`Shiny.addCustomMessageHandler` calls.

**No YAML files. No naming conventions beyond what `htmlDependency`
requires.** The widget is just an R function that returns an irid widget
node.

---

## Open Questions

1. **Channel deduplication.** When a channel's value hasn't changed, should
   the observer skip the `irid-widget-channel` message? Currently `observe`
   fires whenever its reactive dependency invalidates, which may produce
   redundant messages. Using `observeEvent` with a gating predicate would
   solve this, but adds complexity. For now, let the JS side handle
   redundant updates (most libraries' `setValue`/`setOptions` are no-ops
   when nothing changed).

2. **Initial value vs channel observer race.** The `irid-widget-init` message
   includes initial channel values. If a channel's reactive fires before
   the init message is processed (unlikely but possible), the client gets
   the init value, then the first channel update, then the init again.
   This is benign — the JS library's `setValue` is idempotent — but worth
   noting.

3. **Throttle/debounce on `sendEvent`.** Currently `sendEvent` calls
   `sendPayload` directly (immediate dispatch). Should it respect the
   event-level timing config that `mount` registered? This would require
   the JS to know the throttle/debounce config, which is available in the
   `irid-widget-init` message. We could include the event timing config
   so the widget JS can wrap `sendEvent` appropriately, or keep `sendEvent`
   as immediate and let the R-side `observeEvent` handle coalescing via
   `session$input` (which it already does via `priority = "event"`).
   **Recommendation:** `sendEvent` fires immediately. If a widget needs
   rate limiting, the R handler uses `event_throttle` / `event_debounce`
   via `.event`, same as DOM events.

4. **Container element restrictions.** The container function returns an
   `htmltools` tag. Most libraries expect a `<div>`, but some need
   `<textarea>`, `<canvas>`, or `<video>`. The design imposes no
   restriction — the container function can return any tag. The `id`
   is injected by `process_tags`.

5. **Nested widget content (children).** Can a widget contain reactive
   children (e.g. a Leaflet popup that uses irid bindings)? This would
   require `process_tags` to walk the widget's container children and
   extract bindings, events, etc. — adding significant complexity.
   **Recommendation:** Widgets are leaf nodes in the irid tree. If a
   widget needs to embed irid-reactive content (e.g. a tooltip with
   reactive text), the widget JS can use `irid.sendEvent` to request
   the content from R, or the widget container can be a placeholder
   that `irid-swap` fills later.
