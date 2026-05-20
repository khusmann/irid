# Irid Widget Mechanism — Spec

**Status:** Proposed  
**Date:** May 2026

---

## TL;DR

irid's event system is built on DOM events. `buildPayload` reads the DOM event
object, `process_tags` extracts `on*` attribute handlers, and `mount` registers
DOM listeners. This works for native HTML but not for JS libraries (CodeMirror,
Monaco, Leaflet, D3, charting libs) that expose their own callback APIs.

We add one JS primitive — `irid.sendEvent(elementId, eventName, payload)` — that
lets any JavaScript code insert data into irid's existing event pipeline using
the exact same input-ID convention, sequence counter, and stale-indicator
integration that DOM events use. On the R side, we add `IridWidget()` — a
first-class irid construct handled by `process_tags` and `mount`, just like
`Each`/`When`/`Match` — that splits named `...` args into fine-grained reactive
data channels (R → client) and standard `on*` event handlers (client → R).
Widget JS/CSS is bundled as an `htmlDependency` with no special package
structure beyond what `htmltools` already provides.

Two small additions support complex libraries (plotly, map viewers, data
grids) that bind user-interactive state: a `.render` annotation to distinguish
full re-render payload channels from tracking-only channels, and a
`irid.trackChannel(el)` JS helper for per-field snap-back correction when the
server rejects or transforms a user state write.

This is not a framework for widgets. It is a minimal extension of irid's
existing protocol that completes the event path from JS libraries into the
reactive graph.

---

## Goals & Non-Goals

### Goals

- `irid.sendEvent(id, eventName, payload)` lets any JS code fire an irid event
  programmatically, sharing the sequence counter and input-naming convention
  with DOM events
- `IridWidget(dep, container, ...)` returns a first-class irid node that
  `process_tags` and `mount` handle alongside `Each`/`When`/`Match`.
  `IridWidget()` is a low-level constructor called inside package-author
  component functions (e.g. `CodeMirror()`), never directly by end-users.
- Named `...` args split into three categories: `on*` functions become event
  handlers (same as tag `on*` attrs), reactive-valued functions become data
  channels (observed and pushed to client on change), and static values become
  init-time config
- Event handlers use the same `event_*()` timing config and optimistic-update
  protocol as DOM events — no separate mechanism
- Data channels are per-field and independently reactive — not a monolithic JSON
  blob
- `.render` annotation on `IridWidget` distinguishes the render channel (triggers
  full re-render in JS) from tracking channels (server-authoritative values for
  snap-back correction); channel messages carry `isRender: true` for the render
  channel
- `irid.trackChannel(el)` JS helper provides per-field tracking of client-sent
  vs. server-received values, with a correction callback when they diverge
  (snap-back for rejected writes via `reactiveProxy`)
- Client → R events use the same `irid_ev_{id}_{event}` input pipeline; R side
  sees no difference between a DOM event and a `sendEvent` call
- R → client data uses `irid-widget-channel` messages (arbitrary JSON) rather
  than `irid-attr` (string attributes) or `irid-text` (text node replacements)
- Lifecycle: init message on mount, per-channel observer messages on change,
  destroy message on unmount
- Widget JS can use either the `irid.registerWidget()` registry (shared widgets)
  or direct `Shiny.addCustomMessageHandler` (ad-hoc code)
- No YAML files, no naming conventions beyond what `htmlDependency` requires
- Works with `When`/`Each`/`Match` — widgets inside control flow are initialized
  and destroyed as the flow activates and deactivates
- Works with `iridOutput`/`renderIrid` — widgets inside inline irid content
  follow that output's lifecycle

### Non-Goals

- Not a replacement for `htmlwidgets` — existing htmlwidgets packages continue
  working unchanged
- Not a general-purpose JS interop framework — only covers the R↔client
  data/event path that irid's DOM event system misses
- No YAML binding files, no widget metadata files, no special package generator
- No change to how plain DOM events work — `onClick`, `onInput`, etc. on regular
  tags are untouched
- Not adding a fourth message type — `irid-widget-channel` replaces what would
  otherwise be ad-hoc `irid-attr` for complex data, but the init/destroy
  messages are new
- The widget is a leaf node in the irid tree — container children are not
  recursively walked for bindings or events
- No JavaScript build step — widget JS is authored as vanilla JS (consistent
  with `irid.js` itself)

---

## Proposed Design

### Architecture

```
┌────────────────────────────────────────────────┐
│  R session                                     │
│                                                │
│  process_tags(widget_node)                     │
│    → id, events, channels, deps                │
│                                                │
│  irid_mount_processed(result, session)         │
│    → irid-widget-init (once)                   │
│    → observe(channel) → irid-widget-channel    │
│    → observeEvent(irid_ev_{id}_{ev}) → handler │
│    → destroy → irid-widget-destroy             │
└───────────┬───────────────────────┬────────────┘
            │ custom messages       │ Shiny.setInputValue
            ▼                       │ (irid_ev_*)
┌───────────────────────────┐       │
│  Browser (irid.js)        │       │
│                           │       │
│  irid.widgets[name](msg)  │◄──────┘
│    → init library         │
│    → register listener    │
│      → irid.sendEvent()   │──────► irid_ev_{id}_{ev}
│                           │
│  widget.addEventListener  │◄────── irid-widget-channel
│    ('irid-widget-channel')│     irid-widget-destroy
│                           │
│  widget.addEventListener  │◄────── irid-widget-destroy
│    ('irid-widget-destroy')│
└───────────────────────────┘
```

### Key data structures

**`process_tags` result** gains a new top-level field:

```r
result$widgets  # list of:
  list(
    id = "irid-7",
    widget_name = "codemirror",
    dep = <htmlDependency>,
    render = NULL,          # string or NULL — the render channel name
    channels = list(content = <reactiveVal>, ...),
    config = list(mode = "javascript", theme = "default")
  )
```

**`irid-widget-init` message** (R → client, sent once on mount):

```json
{
  "id": "irid-7",
  "widget": "codemirror",
  "render_channel": null,
  "config": { "mode": "javascript", "theme": "default" },
  "channels": { "content": "# Hello\nWorld" }
}
```

**`irid-widget-channel` message** (R → client, sent on every channel change):

```json
{
  "id": "irid-7",
  "channel": "content",
  "value": "# Updated\nContent",
  "isRender": false
}
```

**`irid.trackChannel(el)` tracking state** (JS-side, per widget element):

```js
// Internal to irid.js — widget JS accesses via the tracker object
irid._trackers[id] = {
  lastSent:    { xaxis_range: [0, 10], yaxis_range: [0, 100] },
  lastReceived: { xaxis_range: [0, 10], yaxis_range: [0, 100] }
}
// recordSent(field, value) updates lastSent
// receiveChannel(field, serverValue, onCorrect) compares and invokes onCorrect if diverged
```

**`irid-widget-destroy` message** (R → client, sent on unmount):

```json
{ "id": "irid-7" }
```

**Client → R events** use the existing `irid_ev_{id}_{event}` input — no new
message type. The R side's event dispatch (arity-based handler dispatch,
force-send echo, optimistic-update sequence) works identically.

### `IridWidget()` API

`IridWidget()` is a low-level constructor for package authors (like
`LeafletMap()`, `CodeMirror()`, or `Counter()`). End-users never call
`IridWidget()` directly.

```r
IridWidget(
  dep,                          # htmlDependency — widget JS/CSS
  container,                    # shiny.tag — the container element
  ...,                          # named: reactive channels + event handlers
  .config = list(),             # static config, merged with static ... args
  .event = NULL,                # irid_event_config or named list (like .event)
  .render = NULL,               # string: name of the render channel (or NULL)
  .widget_name = NULL           # derived from dep$name by default
)
```

**`process_tags` handling** — added as a branch in `walk()`, parallel to the
existing `irid_output`/`irid_each`/`irid_match`/`irid_when` branches:

1. Assign ID via `next_id()`
2. Iterate `node$args`:
   - Names matching `^on[A-Z]`: create event entry (same as tag `on*` — event,
     handler, timing config)
   - Values that are reactive (via `is_irid_reactive`): create channel entry
   - All others: merge into `static_config`
3. Merge `static_config` with `node$.config`
4. Store `node$.render` in the widget entry (forwarded to mount for init message
   and `isRender` flag on channel updates)
5. Add to `result$widgets`
6. Add events to `result$events` (so mount handles them identically)
7. Inject the `id` into the container, add the `irid-widget` class, and attach dependency

**`mount` handling** — added in `irid_mount_processed` after events and
bindings:

1. Collect initial channel values via `isolate(channel_fn())`
2. Send `irid-widget-init` with `{id, widget, render_channel, config, channels}`
3. For each channel: `observe({ session$sendCustomMessage("irid-widget-channel",
{id, channel, value, isRender: channel == render}) })`
4. Track widget IDs for destroy

**Destroy** — in the mount handle's `$destroy()`:
1. Send `irid-widget-destroy` for each tracked widget ID

### Client-side dispatch

`irid.js` adds a small registry and three message handlers:

```js
// Registry — optional, for shareable widgets
irid.registerWidget(name, initFn)  // stores initFn in irid.widgets[name]

// Message handlers
// irid-widget-init → dispatch to registered init function
// irid-widget-channel → CustomEvent on the element, detail includes isRender flag
// irid-widget-destroy → CustomEvent on the element

// Server-authoritative value tracking
irid.trackChannel(el)  // returns tracker with recordSent() and receiveChannel()
```

The registry dispatches `irid-widget-init` by looking up
`irid.widgets[msg.widget]`. This avoids handler-name conflicts across widget
types — each widget registers under its own name, and irid.js owns the single
`Shiny.addCustomMessageHandler` for init.

For channel updates and destroy, `irid.js` dispatches DOM `CustomEvent`s on the
widget element. Widget JS listens with
`el.addEventListener('irid-widget-channel', handler)` and
`el.addEventListener('irid-widget-destroy', handler)` — no per-widget Shiny
handlers, clean element-scoped lifecycle.

The `irid-widget-channel` custom event carries `detail.isRender` (from the
message's `isRender` field). Widget JS uses this to distinguish full re-render
payloads from tracking-channel updates without hardcoding channel names.

#### Per-field tracking (`irid.trackChannel`)

Widgets that bind user-interactive state need to know when the server rejects
or transforms a write (snap-back for `reactiveProxy`). `irid.trackChannel(el)`
returns a tracker scoped to the widget element:

```js
var tracker = irid.trackChannel(el);

// Call when the widget sends user state to R via irid.sendEvent()
tracker.recordSent('xaxis_range', [0, 10]);

// Call in the irid-widget-channel listener when a tracking channel arrives
tracker.receiveChannel('xaxis_range', [0, 8], function(corrected) {
  // Server rejected our zoom — force the library to reflect corrected value
  Plotly.relayout(el, { 'xaxis.range': corrected });
});
```

Returns `"accepted"` when server value matches last sent, `"corrected"`
when they diverge (invoking the correction callback), `"no-change"` when
no sent value was recorded yet. The tracker is automatically cleaned up
on `irid-widget-destroy`.

`irid.sendEvent()` shares the `sequences` map, `sendPayload()` function, and
stale-indicator integration that DOM events use. The event enters the same
`Shiny.setInputValue` pipeline with the same `priority: "event"`.

### Critical path — Plotly chart with bound state

1. `process_tags` encounters `IridWidget(dep, container, spec = merged_spec,
   xaxis_range = xrange, yaxis_range = yrange, .render = "spec",
   onClick = handler)`
2. Assigns `id = "irid-9"`, creates channels `spec → merged_spec,
   xaxis_range → xrange, yaxis_range → yrange`, creates event `click → handler`
3. Records `render = "spec"` in `result$widgets`
4. `mount` sends `irid-widget-init({id:"irid-9", widget:"plotly",
   render_channel:"spec", config:{}, channels:{spec:{...}, xaxis_range:null,
   yaxis_range:null}})`
5. `irid.js` dispatches to `irid.widgets["plotly"](msg)`
6. Plotly widget JS creates `var tracker = irid.trackChannel(el)`
7. Init code calls `Plotly.react(el, msg.channels.spec)`
8. User zooms → `plotly_relayout` fires →
   `tracker.recordSent('xaxis_range', [0, 10])` →
   `irid.sendEvent('irid-9', 'relayout', {xaxis_range: [0, 10]})`
9. R handler updates `xrange([0, 10])`; spec re-evaluates; mount sends
   both `spec` (isRender: true) and `xaxis_range` (isRender: false) channels
10. Plotly widget receives `spec` → `Plotly.react(el, newSpec)`
11. Plotly widget receives `xaxis_range` →
    `tracker.receiveChannel('xaxis_range', [0, 10], onCorrect)` →
    server accepted → `"accepted"` → no correction needed

If the server rejected (e.g. range too narrow): step 10 sends `xaxis_range:
[0, 50]` (the old value), tracker detects mismatch, correction callback fires
`Plotly.relayout(el, {'xaxis.range': [0, 50]})` to snap the chart back.

### Critical path — CodeMirror init

1. `process_tags` encounters `IridWidget(dep, container, content = text,
   onChange = handler)`
2. Assigns `id = "irid-5"`, creates channel `content → text`, creates event
   `change → handler`
3. Records in `result$widgets` and `result$events`
4. `mount` sends `irid-widget-init({id:"irid-5", widget:"codemirror", config:{},
   channels:{content:"# Hello"}})`
5. `irid.js` dispatches to `irid.widgets["codemirror"](msg)`
6. Init code finds `el = document.getElementById("irid-5")`, creates CodeMirror,
   sets value
7. CodeMirror fires `change` callback → `irid.sendEvent("irid-5", "change",
   {value: "..."})`
8. `irid.js` builds `{value: "...", id: "irid-5", nonce: ..., __irid_seq: 1}`,
   sends to `irid_ev_irid-5_change`
9. `mount`'s `observeEvent` fires → dispatches to `handler(event_obj, id)` with
   `on*` arity dispatch

### Failure modes

- **Channel reactive errors:** An error in a channel's reactive expression
  propagates through `observe`. The default Shiny error handler catches it and
  logs it. The channel stops sending updates until the reactive stabilizes. No
  crash, no cascade.
- **Missing container element:** `irid-widget-channel` and `irid-widget-destroy`
  handlers check `document.getElementById(msg.id)` and silently return if
  `null`. The JS library may leave behind a dead instance, but the element's
  absence means it was already torn down.
- **Unregistered widget name:** `irid-widget-init` silently drops unrecognized
  widget names (`irid.widgets[msg.widget]` is a no-op call — `undefined` is
  returned as a function call, but since it's `if (init) init(msg)`, undefined
  is skipped). The widget simply doesn't initialize. No crash.
- **Race: channel fires before init processed:** The `irid-widget-init` message
  is sent synchronously in `mount`; channel observers are set up immediately
  after. Shiny processes custom messages in FIFO order, so `irid-widget-init`
  arrives before any subsequent `irid-widget-channel`. No race in practice.
- **Widget inside swapping container (When/Each):** Mount sends
  `irid-widget-init`; destroy sends `irid-widget-destroy`. If the outer
  container is swapped via `irid-swap`, the inner widget's element is removed
  from the DOM. The channel/destroy messages find no element and silently skip.
  No orphaned JS instance remains (the element was removed, so the library
  instance attached to it is garbage-collected).
- **Widget inside mutating container (Each reorder):** The widget element
  retains its identity (moved, not removed). No re-init is needed — the widget's
  existing JS instance persists. Channel updates continue to arrive normally.

---

## Alternatives Considered

- **Use existing `irid-attr` with `JSON.stringify`/`JSON.parse`:** Rejected.
  Round-tripping structured data through DOM attributes is lossy (dates, nested
  objects), requires manual serialization at both ends, and conflates "set a DOM
  attribute" with "push data to widget logic". Separate message types are
  cleaner.

- **Widget init as data attributes on the container:** Rejected. Static config
  in `data-*` attributes works for simple values, but reactive channel values
  and library initialization require programmatic setup. Data attributes are
  readable by the widget's JS via `el.dataset`, but we'd need a second mechanism
  for channel updates anyway. The init message is simpler and supports arbitrary
  JSON config.

- **Ad-hoc `Shiny.addCustomMessageHandler` per widget with unique message
  names:** Rejected. This creates handler-name conflicts across packages (two
  widgets both registering `"chart-init"`). The `irid.widgets[name]` registry
  solves this cleanly. For ad-hoc app code, direct
  `Shiny.addCustomMessageHandler` is still available and recommended.

- **Use `session$output` / `renderUI` for widgets (htmlwidgets model):**
  Rejected. This bypasses irid's fine-grained reactivity and forces the
  monolithic-redraw model. A widget in a `renderUI` cannot participate in
  `When`/`Each`/`Match` lifecycle — it's a Shiny output island. `IridWidget`
  nodes live in `process_tags` and are mounted/unmounted alongside control flow.

- **Let widget JS read initial values from DOM (e.g. `el.textContent`):**
  Rejected for data channels (they need programmatic `setValue` calls), viable
  for static config via `data-*` attributes. The design supports both via the
  init message's `channels` and `config` fields.

---

## Security & Compliance

- **All widget data is app-author code.** There is no user-supplied input
  flowing through `irid.sendEvent` — the widget's own JS library triggers the
  callbacks. The payload is constructed by the widget author's JS, not by
  arbitrary user input.
- **No unsanitized HTML injection.** Widget channel data is delivered via a
  `CustomEvent`, not by setting `innerHTML`. The widget author controls how the
  data is used (e.g. `editor.setValue(str)` — a CodeMirror API, not DOM
  injection).
- **`htmlDependency` is the security boundary.** Widget JS runs in the app's
  origin and has the same privileges as any other app JS. Package authors
  control what code ships in their dependency.
- **No new Shiny input namespace exposure.** `irid_ev_{id}_{event}` is already
  the convention for all irid events. `sendEvent` reuses it — no new attack
  surface.

---

## Rollout & Observability

### No feature flag needed

The mechanism is opt-in. No existing code changes. Widget-specific JS is loaded
only by widgets that use it. The `irid.sendEvent()` function and `irid.widgets`
registry are additions to `irid.js` that don't affect existing DOM event paths.

### Observability

- A widget init can be traced via custom Shiny message logging:
  `session$sendCustomMessage("irid-widget-init", ...)` is visible in Shiny's
  debug logging when `options(shiny.trace = TRUE)`.
- A widget's channel observers fire just like any other irid observer. Errors in
  channel reactives surface through Shiny's standard observer error handling
  (logged, non-fatal).
- Events from `irid.sendEvent()` go through the same `Shiny.setInputValue` path
  as DOM events, visible in Shiny's trace logging with the same `irid_ev_`
  prefix.

---

## Vertical Slices

### Slice 1 — `irid.sendEvent()` JS primitive + test harness

**Delivers:** The JS function in `irid.js`, verified with a minimal HTML page
and a Shiny test app that fires a synthetic event and reads it in R.

Files changed: `inst/js/irid.js`, `tests/testthat/` (new test app)

### Slice 2 — Client-side init, channel, destroy handlers in `irid.js`

**Delivers:** `irid.registerWidget()`, `irid-widget-init` dispatch,
`irid-widget-channel` (with `isRender` flag) and `irid-widget-destroy`
custom event dispatch, `irid.trackChannel(el)` per-field tracking helper.

Files changed: `inst/js/irid.js`, `tests/testthat/`

### Slice 3 — `IridWidget()` constructor + `process_tags` / `mount` wiring

**Delivers:** The full R-side lifecycle: widget node extraction, init message,
channel observers, destroy message. Verified with a counter widget that receives
a reactive count from R and sends click events back.

Files changed: `R/irid_widget.R` (new), `R/process_tags.R`, `R/mount.R`,
`tests/testthat/`

### Slice 4 — Real widget example + packaging convention

**Delivers:** A runnable CodeMirror widget in `inst/examples/codemirror/` that
demonstrates the full pattern: `htmlDependency`, `irid.registerWidget()`,
`irid.sendEvent()`, `IridWidget()`. Demonstrates composition inside
`When`/`Each`.

Files changed: `examples/` (new example), `vignettes/` (updated)

---

## Task Decomposition — Slice 1: `irid.sendEvent()` JS primitive

### Task 1.1: Add `irid.sendEvent()` to `irid.js`

**Implement** the function that constructs the payload and calls `sendPayload`,
sharing the `sequences` counter.

```js
irid.sendEvent = function(elementId, eventName, payload) {
  var inputId = 'irid_ev_' + elementId + '_' + eventName.toLowerCase();
  payload = payload || {};
  payload.id = elementId;
  payload.nonce = Math.random();
  if (!sequences[elementId]) sequences[elementId] = 0;
  payload.__irid_seq = ++sequences[elementId];
  sendPayload(inputId, payload);
};
```

**Tests:**
- [ ] Calling `irid.sendEvent("el1", "custom", {x: 1})` calls
  `Shiny.setInputValue` with inputId `"irid_ev_el1_custom"` and `priority:
  "event"`
- [ ] The payload contains `id: "el1"`, `x: 1`, plus auto-added `nonce` and
  `__irid_seq`
- [ ] Two sequential calls increment `__irid_seq`
- [ ] `onEventSent()` is called (stale indicator path)

**Test approach:** Use `shiny.testserver` or a minimal test app. Inject Shiny
into a test DOM, call `irid.sendEvent`, verify `Shiny.setInputValue` was called
with the expected arguments.

Edge: No existing `sequences[elementId]` — starts at 1.
Edge: `payload` is `undefined` or `null` — defaults to `{}`.
Edge: `sequences` map is shared with DOM events (same `sequences` variable in the IIFE).

---

### Task 1.2: Add R-side test app that receives `sendEvent` payload

**Implement** a minimal test app in `tests/testthat/` that uses a plain tag with an event handler and triggers the event via JS evaluation.

```r
# In test-app
ui <- iridApp(function() {
  clicked <- reactiveVal(0)
  tags$div(
    id = "target",
    onClick = \(e) clicked(e$value)
  )
})
```

The test evaluates JS in the browser (via a Selenium/ShinyTest or shinytest2)
that calls `irid.sendEvent("target", "click", {value: 42})`, then asserts that R
received the event.

**Test:**
- [ ] `irid.sendEvent("target", "click", {value: 42})` causes the R handler to
  fire with `event$value == 42`

This is the full end-to-end path: JS → `sendEvent` → `Shiny.setInputValue` →
`session$input` → `observeEvent` → handler dispatch.

---

## Task Decomposition — Slice 3: `IridWidget()` R-side

### Task 3.1: `IridWidget()` constructor

**Implement** the R function in `R/irid_widget.R`.

```r
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
```

**Tests:**
- [ ] `IridWidget(dep, tags$div())` returns an object with class `"irid_widget"`
- [ ] `IridWidget(dep, "not a tag")` errors with `stopifnot`
- [ ] Named `...` args are stored in the `args` field
- [ ] `.config` is stored in the `.config` field
- [ ] `.event = event_throttle(100)` is stored in `.event`
- [ ] `.render = "spec"` is stored in `.render`
- [ ] `.render = NULL` (default) is stored as `NULL`
- [ ] `.widget_name` overrides the auto-derived name
- [ ] Auto-derived name strips hyphens and underscores from `dep$name`

---

### Task 3.2: `process_tags` handling for `irid_widget`

**Implement** the widget branch in `process_tags`'s `walk()` function.

- Assign ID via `next_id()`
- Separate args into channels (reactive functions), events (`on*` functions),
  and static config
- Merge static config with `.config`
- Add to `result$widgets` and `result$events`
- Produce container tag with dependency attached

**Tests:**
- [ ] `process_tags(IridWidget(dep, tags$div(), x =
  reactiveVal(1)))` produces `result$widgets` with one entry
- [ ] Widget entry has correct `id`, `render` (NULL or string), `channels`
  (named list with `x`), and `config` (empty)
- [ ] Widget entry stores `.render` value from the IridWidget node
- [ ] `onChange` arg creates an event entry in `result$events` with event name
  `"change"`
- [ ] Event entry has correct timing config (defaults for `"change"`:
  `immediate`)
- [ ] Static value arg (e.g. `mode = "javascript"`) goes into `config`, not
  `channels`
- [ ] `.event = event_debounce(500)` overrides the per-event timing for the
  widget's events
- [ ] Container tag has the assigned `id` attribute
- [ ] Container tag has the `htmlDependency` attached via `attachDependencies`
- [ ] Named args that are plain functions (not reactive-classed) go to config,
  not channels
- [ ] No `on*` args: no events produced
- [ ] No reactive named args: no channels produced, only config
- [ ] `IridWidget` inside `When`/`Each`/`Match`: processed as a leaf node, no
  recursion into container children

---

### Task 3.3: `mount` handling for widgets

**Implement** widget mounting in `irid_mount_processed`:

1. Build initial channels map via `isolate()`
2. Send `irid-widget-init` message
3. Create one `observe()` per reactive channel
4. Track widget IDs for destroy
5. Send `irid-widget-destroy` on unmount

**Tests:**
- [ ] On mount, sends `irid-widget-init` with correct `{id, widget,
  render_channel, config, channels}`
- [ ] Initial channel values are isolated (no reactive dependency created in
  mount)
- [ ] Channel observer fires `irid-widget-channel` with `isRender: true` when
  the channel name matches the widget's `.render`
- [ ] Channel observer fires `irid-widget-channel` with `isRender: false` for
  non-render channels
- [ ] Channel observer fires `irid-widget-channel` when the reactive changes
- [ ] Multiple channels each get their own observer
- [ ] Static channel (not reactive) is sent in init but not observed
- [ ] On `$destroy()`, sends `irid-widget-destroy` for each widget
- [ ] Widget inside `When`: init sent when branch activates, destroy sent when
  branch deactivates
- [ ] Widget inside `Each`: init sent per item on add, destroy sent per item on
  remove

**Test approach:** These are integration tests using a real or mocked Shiny
session. Verify custom message sends via `session$sendCustomMessage` calls. Use
`shiny::testServer` or a mock session.

---

### Task 3.4: End-to-end counter widget test

**Implement** a test app with a complete counter widget (JS + R) that exercises
the full lifecycle.

The widget: a `<span>` that displays a reactive count and sends click events
when clicked.

```r
Counter <- function(count, onClick = NULL) {
  IridWidget(
    dep = counter_dep(),           # htmlDependency with counter JS
    container = tags$span(class = "counter"),
    count = count,
    onClick = onClick
  )
}
```

**Tests:**
- [ ] Counter renders with initial count from R
- [ ] Changing `count` reactive updates the displayed count (via
  `irid-widget-channel`, with `isRender: false` or absent)
- [ ] `irid-widget-channel` custom event carries `detail.isRender` matching
  the message
- [ ] Clicking the counter triggers R handler via `irid.sendEvent("id", "click",
  {count: ...})`
- [ ] R handler receives `event$count` with correct value
- [ ] Counter inside `When(cond, ...)`: initialized when condition becomes TRUE,
  destroyed when FALSE
- [ ] Counter inside `Each(items, ...)`: one instance per item, destroyed on item
  removal

---

## Task Decomposition — Slice 2: Client-side handlers

### Task 2.1: `irid.registerWidget()` and init dispatch

**Implement** in `irid.js`:

```js
irid.widgets = irid.widgets || {};
irid.registerWidget = function(name, initFn) {
  irid.widgets[name] = initFn;
};

Shiny.addCustomMessageHandler('irid-widget-init', function(msg) {
  var init = irid.widgets[msg.widget];
  if (init) init(msg);
});
```

**Tests:**
- [ ] `irid.registerWidget("test", fn)` stores `fn` in `irid.widgets["test"]`
- [ ] Receiving `irid-widget-init` with `widget: "test"` calls the registered
  function
- [ ] Unregistered widget: no error, no call
- [ ] Registered function receives the full `msg` object

---

### Task 2.2: `irid-widget-channel` and `irid-widget-destroy` custom event dispatch

**Implement** in `irid.js`:

```js
Shiny.addCustomMessageHandler('irid-widget-channel', function(msg) {
  var el = document.getElementById(msg.id);
  if (!el) return;
  el.dispatchEvent(new CustomEvent('irid-widget-channel', {
    detail: { channel: msg.channel, value: msg.value, isRender: !!msg.isRender }
  }));
});

Shiny.addCustomMessageHandler('irid-widget-destroy', function(msg) {
  var el = document.getElementById(msg.id);
  if (!el) return;
  el.dispatchEvent(new CustomEvent('irid-widget-destroy', { detail: msg }));
});
```

**Tests:**
- [ ] Receiving `irid-widget-channel` dispatches
  `CustomEvent('irid-widget-channel')` on the element
- [ ] Custom event's `detail.channel` and `detail.value` match the message
- [ ] `detail.isRender` is `true` when message's `isRender` is truthy, `false` otherwise
- [ ] Missing element (already removed from DOM): silent skip, no error
- [ ] Receiving `irid-widget-destroy` dispatches
  `CustomEvent('irid-widget-destroy')` on the element
- [ ] Two widgets: each receives only its own channel/destroy messages (filtered
  by `msg.id`)

---

### Task 2.3: `irid.trackChannel()` JS helper

**Implement** in `irid.js`:

```js
irid._trackers = irid._trackers || {};

irid.trackChannel = function(el) {
  var id = el.id;
  if (irid._trackers[id]) return irid._trackers[id];

  var lastSent = {};
  var lastReceived = {};

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

**Tests:**
- [ ] `irid.trackChannel(el)` returns a tracker object for the element
- [ ] Calling `recordSent('xaxis_range', [0, 10])` stores the value
- [ ] `receiveChannel('xaxis_range', [0, 10], fn)` returns `"accepted"` when
  server value matches last sent (deep equal)
- [ ] `receiveChannel('xaxis_range', [0, 5], fn)` returns `"corrected"` when
  values differ, and invokes the `onCorrect` callback with the server value
- [ ] `receiveChannel('xaxis_range', [0, 10], fn)` returns `"no-change"` when
  no `recordSent` was called for that field
- [ ] Deep equal handles nested objects and arrays
- [ ] Same element returns the same tracker instance (singleton per element)
- [ ] Tracker cleans up on `irid-widget-destroy` custom event
- [ ] After destroy, calling `trackChannel` on the same element creates a fresh
  tracker

### Task 2.4: Counter widget JS

**Implement** the counter widget as a registered widget:

```js
irid.registerWidget('counter', function(msg) {
  var el = document.getElementById(msg.id);
  if (!el) return;

  var countEl = document.createElement('span');
  countEl.textContent = msg.channels.count !== undefined ? msg.channels.count : '';
  el.appendChild(countEl);

  el.addEventListener('click', function() {
    irid.sendEvent(msg.id, 'click', {});
  });

  el.addEventListener('irid-widget-channel', function(e) {
    if (e.detail.channel === 'count') {
      countEl.textContent = e.detail.value;
    }
  });
});
```

**Tests:**
- [ ] Initializes the counter element with the initial channel value
- [ ] Click fires `irid.sendEvent(msg.id, 'click', {count: ...})`
- [ ] Channel updates change the displayed text

---

## Task Decomposition — Slice 4: Real widget example

### Task 4.1: CodeMirror example component

**Implement** a `CodeMirror()` component function in `examples/codemirror/` with
JS bindings, and wire it into the examples vignette.

The R component:

```r
CodeMirror <- function(content, mode = "javascript",
                       onChange = NULL, onCursorActivity = NULL) {
  IridWidget(
    dep = codemirror_dep(),
    container = tags$div(style = "height: 300px;"),
    content = content,
    .config = list(mode = mode),
    onChange = onChange,
    onCursorActivity = onCursorActivity
  )
}
```

The JS registers with `irid.registerWidget('codemirror', ...)`, initializes
CodeMirror on the container, forwards `change` and `cursorActivity` events via
`irid.sendEvent`, and listens for content updates on the custom event.

**Test:**
- [ ] Example renders in `iridApp()`
- [ ] Typing in the editor triggers the `onChange` R handler
- [ ] Cursor movement triggers the `onCursorActivity` R handler
- [ ] Updating the `content` reactive updates the editor content
- [ ] Two CodeMirror instances on the same page: independent state, independent
  events
- [ ] CodeMirror inside `When`/`Each`: creates/destroys correctly

---

### Task 4.2: Update examples vignette

**Update** `vignettes/articles/examples.Rmd` to reference the CodeMirror example.

**Test:**
- [ ] Vignette builds without errors

---

## Summary of changes by file

| File | Change |
|------|--------|
| `inst/js/irid.js` | Add `irid.sendEvent()`, `irid.registerWidget()`, `irid.trackChannel()`, handlers for `irid-widget-init`, `irid-widget-channel` (with `isRender`), `irid-widget-destroy` |
| `R/irid_widget.R` | New file: `IridWidget()` constructor with `.render` arg, `%||%` helper, `extract_widget_name()` |
| `R/process_tags.R` | Add `irid_widget` branch in `walk()`, store `.render` in widget entry, add `$widgets` to result list |
| `R/mount.R` | Add widget mounting (init with `render_channel`, channel observers with `isRender`, destroy), tracking in mount handle |
| `tests/testthat/` | Unit + integration tests for each task |
| `examples/codemirror/` | New example: CodeMirror editor widget |
| `vignettes/articles/examples.Rmd` | Reference CodeMirror example |
