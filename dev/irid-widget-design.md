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
Leaflet, D3, charting libraries like plotly.js, etc.) expose their own
callback API — not DOM events. Their events carry library-specific data
(cursor positions, selected features, zoom levels, data point indices) that
the DOM event object doesn't contain.

For simple wrappers, the missing piece is the ability to send events into
irid's pipeline. But complex libraries like plotly introduce additional
needs: preserving user interaction state (zoom, pan, selection) across
data updates, distinguishing user-initiated changes from spec-computed
auto-fit, and snapping back when the server rejects a state write.

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
2. **Stays minimal** — one JS primitive, one R constructor, zero new Shiny
   input types (client→R events reuse the existing `irid_ev_*` convention).
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
inputId ← "irid_ev_" + elementId + "_" + eventName.toLowerCase()
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

A low-level constructor for **package authors**. End-users never call
`IridWidget()` directly — they use higher-level component functions like
`CodeMirror()`, `LeafletMap()`, or `Counter()` that wrap `IridWidget()`
internally. `process_tags` and `mount` handle the widget node as a
first-class irid construct, just like `Each`, `When`, and `Match`.

```r
IridWidget(
  dep,                  # htmlDependency for the widget's JS/CSS
  container,            # shiny.tag — the DOM element the library attaches to

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

)
```

**What `process_tags` does with a widget node:**

1. **Assigns an ID** using the shared counter.
2. **Injects the ID** into the container tag: `container$attribs$id <- id`.
   The container is a static `shiny.tag` — the ID is managed entirely by
   `process_tags`, never by the package author.
3. **Adds the `irid-widget` class** to the container so JS code can discover
   widget elements by class: `container$attribs$class <- paste(class, "irid-widget")`.
4. **Separates bindings from event handlers**: named args that are functions
   become reactive data channels; `on*` args become event entries (same as
   regular tags).
5. **Attaches the dependency** via `htmltools::attachDependencies`.
6. **Records a widget entry** in the result, containing:
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
| R → client | `irid-widget-init` | On mount | `{id, widget, render_channel, config, channels: {name: value, ...}}` |
| R → client | `irid-widget-channel` | Reactive channel fires | `{id, channel: "name", value: ..., isRender: bool}` |
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

### Channel semantics: render vs. tracking

Not all channels are equal. Some channels carry the **primary render
payload** — the data the widget needs to paint itself (e.g. a serialized
plotly JSON spec, a set of map markers). Others are **tracking channels**
— the server's current opinion on a user-controllable field, sent purely
so the JS can compare it against what the client last sent (for snap-back
correction when a write is rejected).

To avoid heuristic channel-name checks in JS ("if channel is `spec`, do a
full render; else just update the tracking map"), `IridWidget` accepts an
optional `.render` argument that names the render channel:

```r
IridWidget(
  dep, container,
  spec        = merged_spec,    # render channel — triggers Plotly.react()
  xaxis_range = xrange,         # tracking channel — server's opinion
  yaxis_range = yrange,         # tracking channel — server's opinion
  .render = "spec"
)
```

When `.render` is set:
- The `irid-widget-init` message includes `render: "spec"` so the JS
  knows which channel drives full re-renders.
- All `irid-widget-channel` messages carry `isRender: true` when the
  channel matches `.render`, letting the JS dispatch accordingly without
  hardcoded names.
- When `.render` is `NULL` (the default), no channel is special — every
  channel update is handled independently by the widget JS.

---

### Server-authoritative value tracking (`irid.trackChannel`)

Widgets that bind user-interactive state (axis ranges, selected points,
drag modes) need to know when the server disagrees with the client's
current value — typically because a `reactiveProxy` rejected or
transformed a write. This "snap-back" pattern requires per-field tracking
of what the client sent vs. what the server last confirmed.

`irid.js` provides a helper for this, scoped per widget element:

```js
// In widget init code
var tracker = irid.trackChannel(el);

// Called when the widget sends a user-initiated state change to R
//   fieldName: e.g. "xaxis_range"
//   value:     the value just sent via irid.sendEvent()
tracker.recordSent(fieldName, value);

// Called in the irid-widget-channel listener, after the server pushes back
//   fieldName, serverValue: from e.detail
// Returns: "accepted" | "corrected" | "no-change"
tracker.receiveChannel(fieldName, serverValue, function(newValue) {
  // If "corrected", newValue is the server-authoritative value.
  // The widget should force the library to reflect it
  // (e.g. Plotly.relayout(el, { 'xaxis.range': newValue })).
  // If "accepted" or "no-change", nothing to do.
});
```

Internally, `trackChannel` maintains per-field maps of `lastSent[field]`
and `lastReceived[field]`. When a channel update arrives, it compares the
server's value against the last sent value (deep equal). If they differ,
it calls the correction callback with the server's value. If they match,
it's a no-op.

The tracker is automatically cleaned up when the widget element is removed
(handled by `irid-widget-destroy`).

**Why a shared helper:** Every widget with rejectable writes (plotly axis
ranges, map viewports, editor selections, data-grid sort states) would
otherwise reimplement this same diff-and-correct loop. `irid.trackChannel`
is a small piece of shared infrastructure that makes the pattern trivial
while staying consistent with the "minimal primitives" philosophy.

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
    container = tags$span(class = "counter"),
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
    container = tags$div(
      class = "codemirror",
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
    container = tags$div(
      class = "leaflet-map",
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

### `inst/js/irid.js` — Add `irid.sendEvent()`, widget registry, channel tracking, and correction dispatch

```js
// --- Programmatic event dispatch for JS libraries ---
// Shares the sequence counter and input-naming convention
// with DOM events, so optimistic-update tracking works
// uniformly.

window.irid = window.irid || {};

irid.sendEvent = function(elementId, eventName, payload) {
  var inputId = 'irid_ev_' + elementId + '_' + eventName.toLowerCase();
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
  // can listen without managing multiple Shiny handlers.
  // isRender flag tells the widget whether this channel
  // drives a full re-render vs. updating tracking state.
  var event = new CustomEvent('irid-widget-channel', {
    detail: { channel: msg.channel, value: msg.value, isRender: !!msg.isRender }
  });
  widget.dispatchEvent(event);
});

Shiny.addCustomMessageHandler('irid-widget-destroy', function(msg) {
  var widget = document.getElementById(msg.id);
  if (!widget) return;
  var event = new CustomEvent('irid-widget-destroy', { detail: msg });
  widget.dispatchEvent(event);
});

// --- Server-authoritative value tracking ---
// Helps widgets detect when the server rejects or transforms
// a user-initiated state write (snap-back correction).
irid._trackers = irid._trackers || {};

irid.trackChannel = function(el) {
  var id = el.id;
  if (irid._trackers[id]) return irid._trackers[id];

  var lastSent = {};
  var lastReceived = {};

  function deepEqual(a, b) {
    if (a === b) return true;
    if (typeof a !== typeof b) return false;
    if (typeof a !== 'object' || a === null || b === null) return false;
    if (Array.isArray(a) !== Array.isArray(b)) return false;
    var keys = Object.keys(a);
    if (keys.length !== Object.keys(b).length) return false;
    for (var i = 0; i < keys.length; i++) {
      if (!deepEqual(a[keys[i]], b[keys[i]])) return false;
    }
    return true;
  }

  var tracker = {
    recordSent: function(fieldName, value) {
      lastSent[fieldName] = value;
    },
    receiveChannel: function(fieldName, serverValue, onCorrect) {
      var sent = lastSent[fieldName];
      lastReceived[fieldName] = serverValue;
      if (sent === undefined) return 'no-change';
      if (deepEqual(sent, serverValue)) return 'accepted';
      if (onCorrect) onCorrect(serverValue);
      return 'corrected';
    },
    _destroy: function() {
      delete irid._trackers[id];
    }
  };

  irid._trackers[id] = tracker;
  el.addEventListener('irid-widget-destroy', function() {
    tracker._destroy();
  });

  return tracker;
};
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
    render = node$.render,
    channels = channels,
    config = static_config
  )

  # Also merge events into the main events list
  result$events <- c(result$events, events)

  # Produce the container
  container <- node$container                # static shiny.tag
  container$attribs$id <- id                 # id injected by process_tags
  container$attribs$class <- paste(          # irid-widget class added for
    trimws(container$attribs$class %||% ""), # JS-side element discovery
    "irid-widget"
  )
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
    render_channel = w$render,
    config = w$config,
    channels = initial_channels
  ))

  # Set up observers for each reactive channel
  for (nm in names(w$channels)) {
    local({
      channel_name <- nm
      channel_fn <- w$channels[[nm]]
      wid <- w$id
      is_render <- identical(channel_name, w$render)
      obs <- shiny::observe({
        val <- channel_fn()
        session$sendCustomMessage("irid-widget-channel", list(
          id = wid,
          channel = channel_name,
          value = val,
          isRender = is_render
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
#' @param container A `shiny.tag` — the DOM element the JS library attaches
#'   to. The ID is injected by `process_tags`; the container does not need
#'   to include one.
#' @param ... Named arguments. Functions with `on*` names become event
#'   handlers. Other functions become reactive data channels (observed
#'   and pushed to the client on change). Static values are sent once
#'   on init.
#' @param .config Static configuration merged with non-reactive named
#'   args and sent to the client on init.
#' @param .event Optional event timing config (same as the element-level
#'   `.event` prop).
#' @param .render Optional string naming the render channel. When set,
#'   the init message includes `render_channel` and channel updates for
#'   that channel carry `isRender: true`. The widget JS uses this to
#'   distinguish full re-render payloads from tracking channels (server-
#'   authoritative values used for snap-back correction). Defaults to
#'   `NULL` (no channel is special — the widget JS handles all updates
#'   independently).
#' @param .widget_name A string identifying the widget type on the
#'   client. Defaults to the first registered JS widget matching the
#'   container's class.
#' @return An irid widget node.
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

## Design Rationale: Complex libraries (plotly-grade)

The widget mechanism provides transport: init, channel push, event receive,
destroy. It does not prescribe how a widget uses these primitives internally.

Libraries like plotly.js need more than transport — they need:

- **Monolithic render payloads** (a full JSON spec with merged user state)
  sent as a single channel, distinct from per-field tracking channels.
- **Snap-back correction** when the server rejects a user state write
  (e.g. a zoom narrower than a minimum range), requiring per-field
  comparison of client-sent vs. server-authoritative values.
- **User-initiated vs. auto-fit filtering** to prevent spec-computed
  layout changes from being captured as user state.

All three are implemented *on top of* `IridWidget`, not inside it:

| Concern | Where it lives |
|---------|---------------|
| Spec serialization + merge | R-side wrapper (e.g. `PlotlyOutput()`) |
| Render vs. tracking distinction | `.render` annotation on `IridWidget` |
| Snap-back tracking | `irid.trackChannel(el)` JS helper |
| User-vs-auto event filtering | Custom JS in the widget bundle |
| Lifecycle, events, deps, timing | `IridWidget` + `irid.sendEvent()` |

`IridWidget` stays minimal. The `.render` annotation and `trackChannel`
helper are small additions that prevent every complex widget from
reinventing the same wire-level patterns, without turning the mechanism
into a framework.

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

3. **Per-field tracking overhead.** `irid.trackChannel` maintains per-field
   maps of `lastSent` and `lastReceived`. For widgets with many bound
   fields (e.g. a plot with many subplot axes), this accumulates state.
   However, the arrays involved are typically two numbers (axis ranges),
   a small set of point indices (selection), or a short string (drag
   mode) — the overhead is negligible. Deep comparison uses a simple
   structural equal; if this becomes a bottleneck, widget authors can
   opt out of tracking and implement their own comparison.

4. **Throttle/debounce on `sendEvent`.** Currently `sendEvent` calls
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

5. **Container element restrictions.** The container is a static `shiny.tag`.
   Most libraries expect a `<div>`, but some need `<textarea>`, `<canvas>`,
   or `<video>`. The design imposes no restriction — the container can be
   any tag. The `id` is injected and the `irid-widget` class is added by
   `process_tags`.

6. **Nested widget content (children).** Can a widget contain reactive
   children (e.g. a Leaflet popup that uses irid bindings)? This would
   require `process_tags` to walk the widget's container children and
   extract bindings, events, etc. — adding significant complexity.
   **Recommendation:** Widgets are leaf nodes in the irid tree. If a
   widget needs to embed irid-reactive content (e.g. a tooltip with
   reactive text), the widget JS can use `irid.sendEvent` to request
   the content from R, or the widget container can be a placeholder
   that `irid-swap` fills later.
