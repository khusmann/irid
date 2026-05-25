# irid widgets — design v2

A first-class wrapper mechanism for arbitrary JavaScript libraries
(CodeMirror, Plotly, Leaflet, Monaco, charting libs, data grids) — exposed
as a single R component constructor that composes inside `When` / `Each` /
`Match` and rides the existing irid reactive plumbing.

---

## Design principles

1. **Reuse existing channels; don't invent parallel ones.** State updates
   ride `irid-attr` under a reserved `widget:<key>` attr prefix.  Events
   ride `irid-events` and the existing managed-state machinery (`setupThrottle` /
   `setupDebounce` / `setupImmediate`). The wire protocol grows by
   additive fields on shapes that already exist, not by a new tier of
   message types. This means the optimistic-update sequence counter, the
   `.event` element-level timing config, and the stale-UI indicator
   *all work for widget events with no widget-specific code in the
   transport*.
2. **Autobind lives in the wrapper, not the framework.** DOM IDL hands
   irid a *universal* (prop, write event, event field) triple that
   holds for every DOM element — `value` ↔ `input` ↔ `e.value` — so
   irid hard-codes it at the framework level. JS libraries have no
   universal triple, so `IridWidget` exposes only `state` (one-way
   in) and `events` (raw callbacks out). The widget's R wrapper is the
   right place to synthesize a round-trip: it knows the library, it
   composes a one-line event handler that writes through the caller's
   reactive. irid exports a tiny helper — `can_accept_write()` — so
   the wrapper handles writable / read-only callables uniformly, and
   the framework's force-send-on-no-op path takes care of the
   read-only snap-back without any extra code in the wrapper. The
   wrapper's *caller* still writes `CodeMirror(content = rv)` and
   gets the round-trip transparently — the boilerplate is paid once,
   inside the wrapper, by the wrapper's author.
3. **Lifecycle is irid's; library code is the author's.** The widget
   author writes `init` (returning `update` / `destroy` hooks) and never
   touches Shiny APIs, sequence counters, or anchor maps. irid guarantees:
   dependency dedup, race-free init under arbitrary script load order,
   and per-instance teardown when the surrounding `When` / `Each` /
   `Match` range is detached.
4. **Two-phase rendering composes naturally.** `IridWidget(...)` is a
   *process-tags* citizen: it emits a marker element plus a widget-init
   record. Mount sends a deferred `irid-widget-init` after the swap, so
   the element exists in the DOM by the time the JS factory runs. The
   marker element survives reorders inside `Each` (insertBefore preserves
   identity), so widget instances are preserved across keyed reorders.
5. **The client's update hook is advisory, not authoritative.** Echo
   messages from the server arrive at the widget as `update(key, value,
   sequence)`; the hook is expected to be idempotent (e.g. skip if the
   widget's current value already matches). The sequence number is
   threaded through for widgets that want to implement focused-input /
   server-transform semantics, but most widgets ignore it.

---

## 1. R-side API

### Constructor

```r
IridWidget(
  type,           # string — registry key, must match a JS-side defineWidget
  state    = list(),
  events   = list(),
  config   = list(),
  deps     = NULL,
  container = NULL,
  .event   = NULL,
  .prevent_default = NULL
)
```

### Argument semantics

- **`type`** (required, character scalar). The widget kind, e.g.
  `"codemirror"`. The client looks this up in its `defineWidget`
  registry. If the type isn't registered when an init message arrives
  (because the script tag hasn't finished loading), the init is queued
  and drained when the matching `defineWidget` call lands. The user
  picks the string; convention is to use the package- or
  library-prefixed kebab form (`"plotly"`, `"cm6-editor"`,
  `"leaflet-map"`).

- **`state`** (named list of callables). Reactive inputs flowing
  server→client. Each entry must be a callable irid treats as reactive
  (a `reactiveVal`, `reactive(...)`, store leaf, `reactiveProxy`, or a
  bare 0-arg function). For each entry `key = fn`, `process_tags` emits:
  - one binding `{id, attr = "widget:<key>", fn}` — mount opens an
    observer that fires `irid-attr` on change; the client routes
    `widget:*` attrs to the widget's `update` hook.
  - the key's *initial value* is read via `isolate(fn())` at mount time
    and sent in the init message, so mount does not subscribe to the
    widget's state.
  - Write-back is *not* wired automatically. The widget's R wrapper
    composes an `events` handler that writes through the caller's
    reactive — see the *Autobind in the wrapper* section below and
    the worked example.

- **`events`** (named list of handler functions). Event sinks flowing
  client→server. Each entry `name = handler` becomes an event entry in
  `process_tags` output with:
  - `event = name` (lowercase, the convention is `change`, `select`,
    `zoom`, `mouseover`, etc. — no `on` prefix because there's no DOM
    event mediating)
  - `handler = handler`
  - `source = "widget"` — a new field that mount forwards to the client
    on the `irid-events` message. The client distinguishes widget events
    from DOM events here: widget events get the managed-state init
    (throttle/debounce/coalesce/sequence) but *no* `addEventListener`
    call. The widget JS pushes events through the managed-state via
    `irid.sendWidgetEvent(...)`.
  - handler arity is dispatched the same way it is for DOM events
    (0/1/2 formals → `()` / `(payload)` / `(payload, id)`); the
    `event_obj` cleaning (`__irid_seq` / `id` / `nonce` stripped) is
    unchanged.
  - payload shape is a *record* (`\(e) e$content`, `\(e) e$cursor`),
    consistent with DOM event handlers across the rest of irid.
    Single-value events should still emit `{content: value}` rather
    than the bare value, so the handler signature is uniform.

- **`config`** (named list). Static init-time configuration. Sent once
  with the init message; never observed. Plain R values only — no
  reactive callables. If the user passes a callable, it is silently
  `isolate()`-read at mount time (a function value would never reach
  the client cleanly anyway, since it has no JSON form).
  Rationale for separating `state` from `config`: it documents intent
  ("this never changes") and saves an observer per static option.

- **`deps`** (`html_dependency`, list of them, or `NULL`). JS/CSS
  dependencies the widget needs to function. **Required for any widget
  whose JS file is not already loaded by some other means.** See the
  *Dependency handling* section below — `htmltools::as.character()`
  strips deps, so irid hoists them out of widget nodes and ships them
  on the wire so dynamic insertion (inside `When` / `Each`) still
  loads them.

- **`container`** (`shiny.tag` or `NULL`). Optional user-supplied
  wrapper. Defaults to `tags$div()`. irid imposes only two invariants:
  the container is given an auto-generated `id`, and a
  `data-irid-widget="<type>"` attribute is added so the client's
  detach-walker can find live widget instances inside a range that is
  about to be torn down. If the user pre-sets `id`, irid honors it
  (mirrors the existing `process_tags` behaviour for `id` on event
  elements). Children of the container are allowed — they are passed
  through the HTML — and the widget JS can choose to honor or replace
  them.

- **`.event`** (`irid_event_config` or named list). Element-level
  timing config — same shape and semantics as on a plain tag. A
  scalar `event_throttle(...)` covers every event the widget emits; a
  named list keyed by widget-event name overrides per event. Unmapped
  events fall back to the per-event default rule. Because widget event
  names aren't DOM events, the default rule keys on `input` →
  `event_debounce(200)`, everything else → `event_immediate()` — same
  as for plain tags. (Authors who want a different default per widget
  type document it; we don't have a per-type override layer.)

- **`.prevent_default`** unused for widget events (no underlying DOM
  event to suppress) but accepted for shape-consistency with `tags$*`
  and the validation path. We could plausibly forbid it — easier to
  accept-and-ignore for now.

### Autobind in the wrapper

A widget's R wrapper expresses round-trip wiring by composing an
`events` handler that writes through the caller's reactive. The
canonical shape:

```r
CodeMirror <- function(content, on_change = NULL, ...) {
  IridWidget(
    type   = "codemirror",
    state  = list(content = content),
    events = list(change = \(e) {
      if (can_accept_write(content)) content(e$content)
      if (!is.null(on_change)) on_change(e)
    }),
    ...
  )
}
```

Three things to note:

- **`can_accept_write(callable)`** is a public helper exported by
  irid. It returns `TRUE` for any callable that can accept a write
  (a `reactiveVal`, store leaf, `reactiveProxy` with a setter, a
  closure with at least one formal, a primitive), and `FALSE` for
  read-only callables (`reactive(...)`, `\() expr`, `reactiveProxy`
  with no setter). Wrappers use it to gate the write-back call so a
  read-only `content` callable doesn't error.

- **Read-only snap-back happens automatically.** Even when the gate
  blocks the write, the event listener has *already fired* — that
  alone is enough. The event observer in `mount.R` runs the
  force-send-on-no-op loop after every handler: it reads every
  binding for the source element via `bindings_by_id[[source_id]]`,
  isolate-evaluates the current canonical value, and emits an
  `irid-attr widget:<key>` tagged with the sequence. The widget's
  `update(key, value, sequence)` hook sees a value different from
  its current state and snaps back. *The wrapper writes nothing
  extra to get this — registering the listener is sufficient.*

- **Ordering** (write before user handler, in the same flush) is
  whatever the wrapper writes. The convention modeled here — write
  first, then user handler — matches DOM autobind, where the
  explicit `on*` always sees post-write state. Wrappers should
  follow it and document any deviation.

For widgets with several round-trip keys, the wrapper writes one
handler per event. A small per-wrapper helper can keep this tidy:

```r
write_through <- function(callable, value, side_effect = NULL) {
  if (can_accept_write(callable)) callable(value)
  if (!is.null(side_effect)) side_effect()
}

events = list(
  change           = \(e) write_through(content, e$content,
                                        side_effect = \() on_change(e)),
  `cursor-changed` = \(e) write_through(cursor,  e$cursor)
)
```

That's enough scaffolding for most widgets; `IridWidget` itself
stays narrow.

### What `IridWidget` is, structurally

It's neither a control-flow node nor an `Output`. It's a third
process-tags citizen with class `irid_widget`. Its contribution to a
processed tag tree:

- A clean tag tree (the container, with auto-assigned `id` and the
  `data-irid-widget` attribute, plus any user children)
- N entries appended to `$bindings` (one per `state` key, attr =
  `widget:<key>`)
- M entries appended to `$events`, one per explicit `events` entry,
  marked with `source = "widget"`. (No framework-level autobind path,
  so no `merge_pending_events` collision case to handle for widgets —
  duplicate event-name entries from the wrapper would be a wrapper
  bug.)
- One entry appended to `$widget_inits` — a new sibling list to
  `$bindings` / `$events` / `$control_flows` / `$shiny_outputs` —
  carrying `{id, type, config, state_fns, deps}`. `state_fns` is the
  raw list of callables; mount uses them to isolate-read initial
  values when constructing the init message.

By piggybacking on existing extraction lists for bindings and events,
the widget gets the existing observer/event plumbing for *free* — the
new code path is only the init message + the deps hoisting.

### Lifecycle inside `When` / `Each` / `Match`

The widget container lives inside a control-flow wrapper range; its
lifetime is the lifetime of that range. Concretely:

- **`When` true→false transition.** The enclosing mount's
  `destroy()` runs all observers for the widget's state and event
  entries; the `irid-swap` empties the range. The detached fragment
  is walked client-side for `data-irid-widget` elements; their
  `destroy()` hooks run before the elements are GC'd. *Client-driven
  teardown by design* — no `irid-widget-destroy` message — so the
  cleanup still happens if the server crashes between observer
  teardown and the swap.

- **`Each` keyed reorder.** `irid-mutate` lifts each child range into
  a fragment and reinserts it before the container's end anchor.
  Element identity (including the widget container) is preserved, so
  the widget JS instance survives — exactly the property that makes
  Each reorders cheap for DOM, made identically cheap for widgets.

- **`Each` keyed shape-change rebuild.** Same path as remove + add —
  the widget is destroyed and a new instance is constructed with the
  fresh initial state. This matches the existing irid contract: a
  shape transition is "this was a different thing".

- **`Match` case-change.** Same as `When` — old case mount destroyed,
  old widget destroyed via the detach walker, new case mounted, new
  widget initialized.

- **In-place state updates** (the common case — slot accessor /
  mini-store propagation fires only the changed leaf's binding): the
  widget's `update(key, value, sequence)` hook runs. No remount, no
  DOM churn.

### Identity across re-renders

Widget identity is tied to the widget *container's element identity*
in the DOM. That means:

- **Survives:** `Each` keyed reorders, in-place state updates,
  ancestor attr changes.
- **Does not survive:** any `irid-swap` of an ancestor range
  (`When` / `Match`), shape-changing `Each` rebuilds, removes.

This is intuitive once stated — the same rule as `tags$input`'s focus
state — and consistent with how irid handles client-only DOM state
elsewhere.

### Dependency handling

`htmltools::as.character()` on a tag tree **strips
`html_dependency` metadata**, and irid's `irid-swap` /
`irid-mutate` paths use `as.character()` to serialize the HTML they
ship. So deps attached to a widget tag via
`htmltools::attachDependencies()` (or carried implicitly by a
`tagList` containing a dep) would be silently lost the first time the
widget is inserted dynamically.

The fix: `IridWidget(deps = ...)` is the *only* supported way to
declare widget deps. `process_tags` lifts them off the widget node
into the `widget_inits` entry. Mount packs them into the
`irid-widget-init` message. The client passes them to
`Shiny.renderDependencies(...)` (or our own helper that calls the same
underlying dedup-by-name+version logic) before calling the widget's
factory.

For widgets at the top of the page (mounted via `iridApp`'s `ui()`
pass — no `irid-swap` involved), `iridApp` already calls
`htmltools::attachDependencies(..., irid_dependency())` to load
irid.js. We extend that: top-level mount also collects deps from
`widget_inits` discovered during `process_tags` and attaches them
alongside the irid dep, so the initial document carries the `<script>`
/ `<link>` tags in `<head>`. The `irid-widget-init` message still
ships the deps as well (a no-op for already-loaded deps thanks to
dedup) — this is the simplest way to handle a widget that first
appears inside a dynamically-mounted `renderIrid` block.

---

## 2. Wire protocol

Two channels are extended; one new message type is added.

### `irid-attr` (existing — extended)

```js
{ id: "irid-7", attr: "widget:content", value: "new code\n", sequence?: 12 }
```

A `attr` of the form `widget:<key>` routes to the widget's `update`
hook for `id`, passing `(key, value, sequence)`. All other attr values
behave as today. The optimistic-update gating (focused-element value
echo) does *not* apply to widget attrs — that's the widget author's
job inside `update` (compare to current widget state, decide whether
to apply, optionally use `sequence` to gate stale echoes the same way
the focused-input path does).

### `irid-events` (existing — extended)

Each event entry gains a `source` field, defaulting to `"dom"`. When
`source: "widget"`:

```js
{
  id: "irid-7", event: "change",
  inputId: "irid_ev_irid-7_change",
  mode: "debounce", ms: 200, leading: false, coalesce: false,
  source: "widget",
  preventDefault: false
}
```

The client initializes the managed-state entry exactly as today
(`setupThrottle` / `setupDebounce` / `setupImmediate`), but *skips*
the `el.addEventListener` step. The widget JS pushes events through
the managed state via the helper `irid.sendWidgetEvent(id, event,
payload)`, which:

1. looks up `managed[inputId]`
2. attaches `id`, a nonce, and an incremented `sequences[id]`
   counter to `payload` — exactly like `buildPayload` does for DOM
   events
3. calls the managed-state `maybeSend` path so throttle / debounce /
   coalesce / sequence / stale-indicator gating all apply uniformly

This means a widget's `change` event participates in the *same*
sequence counter as a sibling `<input>`'s `input` event. Echo gating
on cross-element bindings works without any widget-specific code in
mount.R.

### `irid-widget-init` (new)

```js
{
  id: "irid-7",
  type: "codemirror",
  state: { content: "initial code\n", language: "r" },
  config: { theme: "dracula", lineNumbers: true },
  deps: [
    { name: "codemirror", version: "6.0.1",
      script: "...", stylesheet: "..." }
  ]
}
```

Sent **after** the swap/mutate that introduces the widget's container
into the DOM. Two-step ordering — and the deferred-flush ordering of
`session$sendCustomMessage` — guarantees the container element exists
by the time the client looks it up.

Client receipt:

1. Load `deps` via `Shiny.renderDependencies(deps)` (or our own
   wrapper that calls the same underlying dedup). This injects
   `<link>` and `<script>` tags into `<head>`. Already-loaded deps
   are no-ops. Returns a promise (or accepts a callback) for "all
   deps ready".
2. Once deps ready, look up `defineWidget`'s registry for `type`.
3. **If type is registered**: look up `document.getElementById(id)`,
   call the factory `init(el, state, config, send)`, store the
   returned `{update, destroy}` handle in a per-id widget map.
4. **If type is not registered** (script still parsing /
   load order race): queue `{id, state, config, el}` under the type
   key. `defineWidget(type, factory)` drains the queue for `type`
   when called.

The init message is **idempotent on the client**: if a widget is
already mounted at `id`, the message is dropped. This guards against
the duplicate-init scenario when an `Each` reorder is misclassified
by the server (it shouldn't, but defense in depth costs nothing).

### Race answers (the platform realities)

- **Async `<script>` order.** Handled by the registry queue:
  `irid-widget-init` can arrive before its `defineWidget` call lands.
  The init is buffered until the type is registered.
- **Repeated re-insertion of `<script src=>`.** Deps never flow
  through the HTML stream. `irid-swap` / `irid-mutate` HTML carries
  only the container element. Deps come in on `irid-widget-init`,
  and `Shiny.renderDependencies` dedupes by name+version, so a
  widget's JS file is fetched once per session and executed once.
  Re-inserting a `When` branch re-fires `irid-widget-init`, which
  hits the dedupe and just calls the factory — no second
  `<script>` injection.
- **`htmltools::as.character()` strips deps.** Handled by routing
  deps through `IridWidget(deps = ...)` → `widget_inits` →
  `irid-widget-init` rather than through the HTML stream.
- **Widget events share timing/sequence machinery.** Handled by
  threading widget events through `irid-events` with `source:
  "widget"` and routing pushes through `managed[inputId]`.
- **`isolate()` at init.** The `state_fns` list is read with
  `isolate(fn())` in the init-message constructor; mount does not
  subscribe to widget state when sending init. The per-key observers
  are what subscribe — they get registered as ordinary bindings.

---

## 3. JS-side API

### What irid provides

A small object exported on `window.irid`:

```js
window.irid = {
  defineWidget(type, factory) { ... },
  sendWidgetEvent(id, event, payload) { ... }
}
```

- **`defineWidget(type, factory)`**: register a widget kind. `factory`
  is `function (el, state, config, send) -> { update, destroy }`. If
  the type already has queued inits, the registration drains them in
  arrival order before returning.
- **`sendWidgetEvent(id, event, payload)`**: route an event payload
  through the managed-state pipeline for the `(id, event)` pair.
  `event` is the lowercase event name from the R `events` list. The
  helper is a no-op if no managed-state exists for the pair (e.g. the
  widget JS fires events the R side didn't subscribe to) — silent
  rather than thrown, so the JS code can register all its events
  unconditionally and only the ones with an R subscriber actually
  round-trip.

### What the widget author writes

```js
irid.defineWidget("codemirror", function (el, state, config, send) {
  // el: the container DOM element (already in the document)
  // state: initial state values {content: "..."}; same keys as R `state =`
  // config: static config from R `config =`
  // send: send(event, payload) — push events through irid's pipeline
  //       same DOM event-payload shape constraint (strings/numbers/booleans);
  //       irid adds id, nonce, __irid_seq

  var editor = createEditor(el, {
    doc: state.content,
    theme: config.theme,
    extensions: [/* ... */]
  });

  editor.on("doc-change", function () {
    send("change", { content: editor.getValue() });
  });

  return {
    update: function (key, value, sequence) {
      if (key === "content") {
        if (value === editor.getValue()) return;       // idempotence
        editor.setValue(value);
      } else if (key === "language") {
        editor.setLanguage(value);
      }
    },
    destroy: function () {
      editor.destroy();
    }
  };
});
```

Contract details:

- **`el`** is owned by the widget for the duration of its lifetime —
  irid will not modify it. The widget may set children, attrs,
  classes freely.
- **`state`** is a plain object with the initial values for every R
  `state =` key. The widget is responsible for applying them during
  init.
- **`config`** is a plain object. The widget treats it as read-only
  after init — no updates will arrive.
- **`send(event, payload)`** is a closure over `(id, event)`. The
  widget calls it whenever a user action should reach R. `payload` is
  any JSON-serializable object; the R handler receives it with `id`,
  `nonce`, `__irid_seq` stripped. If no R subscriber exists for an
  event name (the R side simply omitted that handler), `send` is a
  silent no-op — the widget can fire events unconditionally.
- **`update(key, value, sequence)`** runs in response to a single
  `state` key changing. `sequence` is `undefined` for programmatic
  updates (no event triggered the change) and a number for echoes from
  an event that originated on the same widget. *Idempotence is the
  widget author's responsibility* — most updates round-trip the value
  the widget just sent.
- **`destroy()`** runs before the widget's container is detached from
  the DOM. The widget should tear down anything that isn't pure DOM
  inside `el`: window listeners, animation frames, timers, web socket
  connections, ResizeObservers, etc. DOM children of `el` will be GC'd
  by detachment; the widget doesn't need to clear them.

### Teardown — client side

Walks added to `irid-swap` and `irid-mutate`:

- When `detachRange` runs over a removed range, in addition to
  unregistering nested anchors and calling `Shiny.unbindAll`, irid
  walks the range for elements with `data-irid-widget` and calls each
  widget's `destroy()` from the per-id widget map. The map entry is
  cleared.
- When `Each`'s `irid-mutate` reorders ranges via insertBefore, no
  detach happens — widget identity is preserved.

This is symmetric with how anchors are deregistered. No extra wire
traffic; the server already destroys the widget's observers via the
enclosing mount's `destroy()`.

---

## 4. Worked example — CodeMirror

### R component function

```r
CodeMirrorDeps <- function() {
  htmltools::htmlDependency(
    name    = "cm6",
    version = "6.0.1",
    src     = system.file("widgets/cm6", package = "myapp"),
    script  = c("codemirror.bundle.js", "cm6-irid.js"),
    stylesheet = "codemirror.css"
  )
}

#' CodeMirror editor widget
#'
#' @param content    reactive callable for the document text. A writable
#'   reactive (`reactiveVal`, store leaf, `reactiveProxy` with a setter,
#'   ...) gets a round-trip; a read-only callable (`reactive(...)`,
#'   0-arg closure) renders read-only and snaps the editor back on any
#'   user edit.
#' @param on_change  optional side handler `\(e) ...` to run after the
#'   write-back. Useful for logging or cross-field effects.
#' @param language   static language name (e.g. "r", "javascript").
#' @param theme      static theme name (e.g. "dracula").
CodeMirror <- function(
  content,
  on_change = NULL,
  language  = "r",
  theme     = "dracula"
) {
  IridWidget(
    type   = "codemirror",
    state  = list(content = content),
    events = list(change = \(e) {
      if (can_accept_write(content)) content(e$content)
      if (!is.null(on_change)) on_change(e)
    }),
    config = list(language = language, theme = theme),
    deps   = CodeMirrorDeps(),
    container = tags$div(
      class = "border rounded",
      style = "height: 300px; overflow: hidden;"
    ),
    .event = event_debounce(200, coalesce = TRUE)
  )
}
```

The wrapper's *caller* never sees the autobind plumbing:

```r
# Minimal round-trip — no handler boilerplate at the call site.
CodeMirror(content = doc)

# Same widget, view-only — `reactive()` makes it read-only; the wrapper's
# `can_accept_write` gate skips the write, and the force-send-on-no-op
# path echoes the canonical value back, snapping the editor.
CodeMirror(content = reactive(paste0("# Generated\n", source_text())))

# Bring-your-own side handler. The wrapper's `change` handler calls
# `on_change(e)` after the write, in the same flush.
CodeMirror(
  content   = doc,
  on_change = \(e) audit_log(now(), e$content)
)
```

### JS binding

```js
// inst/widgets/cm6/cm6-irid.js
// loaded by CodeMirrorDeps()

import {EditorView, basicSetup} from "codemirror";
import {EditorState} from "@codemirror/state";
import {r}          from "@codemirror/lang-r";
import {javascript} from "@codemirror/lang-javascript";
import {dracula}    from "thememirror";

var LANGS = { r: r, javascript: javascript };

irid.defineWidget("codemirror", function (el, state, config, send) {
  var view = new EditorView({
    parent: el,
    state: EditorState.create({
      doc: state.content,
      extensions: [
        basicSetup,
        LANGS[config.language](),
        config.theme === "dracula" ? dracula : [],
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
      if (key !== "content") return;
      var current = view.state.doc.toString();
      if (value === current) return;       // echo of what we just sent
      view.dispatch({
        changes: { from: 0, to: current.length, insert: value }
      });
    },
    destroy: function () {
      view.destroy();
    }
  };
});
```

### Usage inside a `When` (the integration test)

```r
library(irid)
library(bslib)

App <- function() {
  editor_open <- reactiveVal(TRUE)
  doc <- reactiveVal("# Hello, irid widgets!\nplot(1:10)\n")

  page_fluid(
    tags$div(
      class = "d-flex gap-2 mb-2 align-items-center",
      tags$label(
        class = "form-check form-switch",
        tags$input(
          type = "checkbox",
          class = "form-check-input",
          checked = editor_open
        ),
        tags$span(class = "form-check-label", "Show editor")
      ),
      tags$span(
        class = "text-muted",
        \() paste0("Length: ", nchar(doc()))
      )
    ),
    When(
      editor_open,
      \() CodeMirror(content = doc, language = "r")
    ),
    tags$pre(class = "border rounded p-2 mt-2 bg-light", \() doc())
  )
}

iridApp(App)
```

The `CodeMirror(content = doc)` line is the *whole* round-trip wiring
from the caller's perspective, mirror image of `tags$input(value =
rv)`. The `\(e) { if (can_accept_write(content)) content(e$content); ... }`
handler baked into `CodeMirror`'s wrapper is what makes that possible —
one event entry written once when wrapping the library, then transparent
for every caller.

### What you should observe in the running app

1. **Initial mount.** `iridApp`'s `ui()` pass calls `process_tags` and
   `htmltools::attachDependencies` to attach both `irid_dependency()`
   and `CodeMirrorDeps()` to the document — the CodeMirror `<script>`
   loads as a normal page asset. The `<div data-irid-widget="codemirror" id="irid-7">`
   sits empty in the static HTML. On `server()`,
   `irid_mount_processed` sends one `irid-widget-init` for `irid-7`.
   The client looks up the registry, finds `"codemirror"`, calls the
   factory. The editor materializes inside the div.

2. **Typing in the editor.** Each keystroke fires
   `view.updateListener` → `send("change", {content: ...})` →
   `irid.sendWidgetEvent("irid-7", "change", {content})`. The managed
   state for `irid_ev_irid-7_change` is `event_debounce(200, coalesce =
   TRUE)`. After 200ms of pause + server idle, one Shiny
   `setInputValue` lands; the R event observer fires `on_change(e)`,
   which calls `doc(e$content)`. The `doc` binding observer for the
   `<pre>` text child fires (the `irid:text` binding) and updates the
   preview. The widget's own `widget:content` binding observer also
   fires, sending `irid-attr {attr: "widget:content", value: ..., sequence: N}` —
   the client routes it to the widget's `update`, which sees
   `value === current` and skips. No cursor jump, no flicker.

3. **Toggle the switch off.** `editor_open` flips to `FALSE`. The
   `When` observer destroys the inner mount (tearing down the widget's
   state binding observer and event observer), sends `irid-swap` with
   empty HTML. The client `detachRange` walker finds
   `[data-irid-widget]` inside the detached fragment, calls the
   widget's `destroy()` — the EditorView is torn down — and clears the
   per-id widget map entry.

4. **Toggle the switch back on.** `editor_open` flips to `TRUE`. The
   `When` observer constructs a fresh `CodeMirror(...)` tag tree,
   processes it, sends the `irid-swap` HTML, mounts new observers, and
   sends a new `irid-widget-init`. The widget's initial `content` is
   read via `isolate(doc())` — the current text, preserved across the
   off/on cycle by the `doc` reactive on the R side. The widget
   re-mounts with the previous text. *Cursor position, undo history,
   selection — gone, by design.*

5. **Programmatic update.** Add a button:
   `tags$button(onClick = \() doc("// reset\n"), "Reset")`. Click it.
   `doc` updates → the widget's `widget:content` binding observer
   fires. Because the click handler's source ID is the button (not the
   widget), the binding observer omits the sequence — the client
   treats it as a programmatic update, the widget's `update` hook sees
   a value different from `editor.getValue()`, and applies it. The
   editor replaces its document. Symmetric with the
   button-clears-text-input case in `optimistic_updates.R`.

---

## 5. Open questions — explicit answers

| Question | Answer |
|---|---|
| Constructor signature — reactive in, events out, static config? | Three named-list args: `state` (reactive in, observed per-key), `events` (callbacks out, registered per event name), `config` (static, sent once at init). Plus `container`, `deps`, `.event`. |
| Should widgets autobind? | **No framework-level autobind; per-widget round-trip lives in the wrapper.** The wrapper composes an `events` handler that calls the caller's reactive (`content(e$content)`), gated by the exported `can_accept_write()` helper for read-only safety. Read-only snap-back happens automatically via the existing force-send-on-no-op path — the wrapper just needs the listener registered. Boilerplate is paid once per wrapper, never per call. |
| JS/CSS dep attachment? | `deps = ` arg accepts one `html_dependency` or a list. `process_tags` lifts them off the widget node into `widget_inits` because `htmltools::as.character()` strips them. Mount ships them on the `irid-widget-init` message; client renders via `Shiny.renderDependencies` (dedup by name+version). |
| How does the JS file declare "I handle widget type X"? | Explicit registry: `irid.defineWidget("type", factory)`. Inits arriving before the registration are queued and drained on registration. Robust under arbitrary script load order. |
| JS lifecycle contract? | Factory returns `{update, destroy}`. `update(key, value, sequence)` per-key. `destroy()` before container detachment. `init` signature `(el, state, config, send)`. |
| `When`/`Each`/`Match` teardown ordering? | Server-side: `irid_mount_processed`'s `destroy()` tears down state/event observers as part of the enclosing mount's `observers` list. Client-side: `irid-swap` / `irid-mutate` detach walkers find `data-irid-widget` elements in the detached fragment and call their `destroy()` hooks before GC. No `irid-widget-destroy` message — purely client-driven. |
| Container element ownership? | User-supplied via `container = tags$div(...)`. irid injects `id` and `data-irid-widget = type`. User can set classes, styles, even children. Default `tags$div()`. |
| Widget identity across re-renders? | Tied to container's DOM element identity. **Survives** `Each` keyed reorders (insertBefore preserves identity). **Does not survive** `When`/`Match` branch flips or `Each` shape-change rebuilds — those rebuild the widget fresh. Same semantics as `<input>` focus/scroll/selection state. |
| Initial state read — reactive dep? | `state_fns` are read via `isolate(fn())` at init-message construction. Mount does not subscribe to widget state. The per-key bindings subscribe — the same `observe()` pattern that exists today. |
| Widget events sharing timing / sequence machinery? | Yes. Widget events ride `irid-events` with `source: "widget"`. The client initializes managed state (throttle/debounce/coalesce/sequence) but skips `addEventListener`. The widget JS pushes via `irid.sendWidgetEvent`, which routes through the managed state and `Shiny.setInputValue` — `.event` config and stale indicator work transparently. |
| Race: script not loaded when init arrives? | Registry queue. Inits buffer per type until `defineWidget(type, ...)` lands; drained on registration. |
| Race: `<script src>` re-execution on re-insertion? | Avoided. Deps never flow through swap/mutate HTML. They ride `irid-widget-init` and `Shiny.renderDependencies` dedupes — one `<script>` fetch per session. |

---

## 6. Test plan implications

The widget mechanism extends three existing testing surfaces and adds a
fourth:

- **`process_tags` extraction** gets:
  - widget node produces `$widget_inits` entry with `{id, type, config, state_fns, deps}`
  - state keys become `$bindings` with `attr = "widget:<key>"`
  - events become `$events` with `source = "widget"`
  - container `id` and `data-irid-widget` are set on the output tag

- **Public helper `can_accept_write()`** gets:
  - returns `TRUE` for primitives, closures with ≥1 formal,
    `reactiveVal`, store leaves, `reactiveProxy` with a setter
  - returns `FALSE` for `reactive(...)`, `\() expr` closures,
    `reactiveProxy` with no setter
  - exported from the package (rename of internal
    `can_accept_write` in `process_tags.R`, or wrapper around it)
  - documented with the wrapper-author autobind pattern as the canonical
    use case

- **Observer lifecycle** gets:
  - destroying the enclosing mount tears down widget state observers and event observers
  - widget inside `When` mounts/unmounts on toggle (init message after swap; destroy via detach walker)
  - widget inside keyed `Each` survives reorder (`insertBefore` preserves identity; no init re-send)
  - widget inside positional `Each` survives same-length in-place updates (per-key updates via `irid-attr widget:*`)

- **Client-side handling** gets:
  - `irid-attr` with `widget:<key>` routes to the widget's `update` hook
  - `irid-events` with `source: "widget"` initializes managed state but skips `addEventListener`
  - `irid.sendWidgetEvent` builds payload with `id` / `nonce` / `__irid_seq` and pushes through `managed[inputId]`
  - `detachRange` walks for `data-irid-widget` elements and invokes their `destroy()` hooks
  - `defineWidget` drains queued inits in arrival order
  - duplicate `irid-widget-init` for the same id is a no-op

- **Widget API contract** (new surface):
  - factory called once per mount with `(el, state, config, send)`
  - `update(key, value, sequence)` called for each `irid-attr widget:*`
  - `send(event, payload)` is a no-op if no R subscriber exists
  - `destroy()` called before container detachment

---

## 7. Non-goals / explicitly out of scope

- **Cross-widget message passing.** Widgets communicate via shared
  reactive state on the R side, period. There is no client-side
  "broadcast" channel between widget instances. This keeps the data
  flow direction unambiguous and matches the rest of irid.
- **Widgets as inputs to other widgets without a round-trip.**
  Sometimes a chart widget wants to consume the live editor content
  without paying for the R round-trip. Tempting; out of scope.
  Workaround: a shared `reactiveVal` and `.event = event_throttle(100,
  coalesce = TRUE)`.
- **Server-side widget rendering.** Always client-rendered. (htmlwidgets
  has a static-rendering mode for knitr; irid widgets don't.)
- **Built-in widgets shipped in the `irid` package.** Widgets live in
  user packages or example dirs; `irid` provides only `IridWidget()`
  and the JS runtime.
