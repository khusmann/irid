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
   universal triple, so `IridWidget` exposes only `props` (one-way
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
  name,           # string — registry key, must match a JS-side defineWidget
  props    = list(),
  events   = list(),
  deps     = NULL,
  container = NULL,
  .event   = NULL,
)
```

### Argument semantics

- **`name`** (required, character scalar). The widget's registry name,
  e.g. `"codemirror"`. The client looks this up in its `defineWidget`
  registry. If the name isn't registered when an init message arrives
  (because the script tag hasn't finished loading), the init is queued
  and drained when the matching `defineWidget` call lands. The user
  picks the string; convention is to use the package- or
  library-prefixed kebab form (`"plotly"`, `"cm6-editor"`,
  `"leaflet-map"`).

- **`props`** (named list). Inputs flowing server→client.
  **Per-key dispatch on `is.function()`**, mirroring how `tags$*`
  attributes work elsewhere in irid:

  - **Callable** (`reactiveVal`, `reactive(...)`, store leaf,
    `reactiveProxy`, bare 0-arg closure) → `process_tags` emits a
    binding `{id, attr = "widget:<key>", fn}`. Mount opens an
    observer that fires `irid-attr` on change; the client routes
    `widget:*` attrs to the widget's `update(key, value, sequence)`
    hook. Initial value is read via `isolate(fn())` at mount time
    and bundled into the init message, so mount itself does not
    subscribe to the prop.
  - **Non-callable** (string, number, list, `NULL`, anything else) →
    bundled into the init message as the prop's value. No observer
    registered.

  This matches irid's "functions, not expressions" rule: anywhere a
  value goes in irid, passing a function makes it reactive. Widgets
  are no exception.

  **Init-only library options.** Some library knobs genuinely can't
  be live-updated (CodeMirror extensions are committed at
  `EditorState.create` time; Monaco's `automaticLayout` only takes
  effect at construction; Plotly's init opts aren't re-read on
  update). For these:

  - The wrapper's *documentation* tells callers "this is init-only;
    passing a reactive will only use its initial value."
  - The widget's JS `update` hook *has no branch* for that key — the
    update message arrives, the switch on `key` falls through, the
    update is silently dropped. Same shape as a Shiny module
    silently no-op'ing on an input it doesn't read.

  This is the cost of the unified `props` arg: a caller can pass a
  reactive to an init-only key and get silent one-shot behavior. The
  benefit is symmetry with the rest of irid, full caller discretion
  over what's reactive in their app, and migration paths (adding live
  update support to a previously-init-only option doesn't change the
  wrapper signature).

  Write-back for callable props is *not* wired automatically. The
  widget's R wrapper composes an `events` handler that writes through
  the caller's reactive — see *Autobind in the wrapper* below and
  the worked example.

- **`events`** (named list of handler functions). Event sinks flowing
  client→server. Each entry `<event> = handler` becomes an event entry in
  `process_tags` output with:
  - `event = <event>` (lowercase kebab-case by convention, matching the
    web's `CustomEvent` tradition — single-word names like `change`,
    `select`, `zoom`; multi-word names like `cursor-changed`, `doc-change`.
    No `on` prefix because there's no DOM event mediating. The R-side
    wrapper translates between this wire name and its R-facing `on*` arg
    — see the *Multi-event wrappers* sketch for the pairing. Multi-word
    entries need backticks in R, e.g. `` `cursor-changed` = handler ``,
    which usefully signals "wire name, not R identifier" at the call site.)
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
  `data-irid-widget="<name>"` attribute is added so the client's
  detach-walker can find live widget instances inside a range that is
  about to be torn down. If the user pre-sets `id`, irid honors it
  (mirrors the existing `process_tags` behaviour for `id` on event
  elements). Children of the container are allowed — they are passed
  through the HTML — and the widget JS can choose to honor or replace
  them.

- **`.event`** (`irid_event_config` or named list). Element-level
  timing config — same shape and semantics as on a plain tag. A
  scalar `event_throttle(...)` broadcasts to every event on the
  element; a named list keyed by event name overrides per event.
  Resolution is **three-tier**:

  1. **Caller's `.event`** (highest). Whatever the wrapper passes
     in. A scalar broadcasts and wins everywhere; a named list wins
     per-event.
  2. **Wrapper defaults** (middle). The wrapper layers its preferred
     per-event config via `event_defaults(.event, change = ...)`
     before handing `.event` to `IridWidget`. See the *Wrapper
     defaults* section below.
  3. **Framework default** (lowest). For widget events, every event
     defaults to `event_immediate()` — no `input → debounce(200)`
     special case (that rule is DOM-tuned and doesn't fit
     library-specific widget event names). For DOM events on the
     container — see next bullet — the existing tag rule applies
     (`input → debounce(200)`, everything else `immediate`).

  This `.event` covers both *widget* events (from the `events` arg)
  and any *DOM* events the user puts directly on the container (see
  next bullet). Both join the same per-element event table and look
  up by event name. Collision between a widget event name and a DOM
  event name on the same container is author error; we don't
  disambiguate. In practice JS libraries use library-specific names
  (`cursor-changed`, `nodeSelect`) that don't collide with DOM
  event names.

- **DOM events on the container.** The container is a normal
  `shiny.tag`, so `container = tags$div(onClick = \() ...)` works
  and the `onClick` is extracted by `process_tags` exactly like a
  regular DOM event. DOM and widget events coexist on the same
  element id, both subject to the same `.event` lookup.

### Autobind in the wrapper

A widget's R wrapper expresses round-trip wiring by composing an
`events` handler that writes through the caller's reactive. irid
exports two helpers for this — `can_accept_write()` (the writability
predicate) and `write_back()` (a handler factory that wraps the
common pattern). The canonical wrapper:

```r
CodeMirror <- function(content, on_change = NULL, ...) {
  IridWidget(
    name   = "codemirror",
    props  = list(content = content),
    events = list(change = write_back(content, "content", then = on_change)),
    ...
  )
}
```

#### The two helpers

- **`can_accept_write(callable)`** — the low-level predicate. Returns
  `TRUE` for any callable that can accept a write (a `reactiveVal`,
  store leaf, `reactiveProxy` with a setter, a closure with ≥1
  formal, a primitive), and `FALSE` for read-only callables
  (`reactive(...)`, `\() expr`, `reactiveProxy` with no setter), or
  non-callables. Wrappers use it to gate write attempts so a
  read-only callable doesn't error.

- **`write_back(callable, field, then = NULL)`** — the sugar. Returns
  an event handler that:
  1. Writes `e[[field]]` to `callable` *iff* `can_accept_write(callable)`.
  2. Calls the optional `then` handler after, arity-dispatched —
     `then()` for 0-arg, `then(e)` for 1+-arg. Matches the same
     arity convention as `mount.R` uses elsewhere.

  Sketch:

  ```r
  write_back <- function(callable, field, then = NULL) {
    force(callable); force(field); force(then)
    function(e) {
      if (can_accept_write(callable)) callable(e[[field]])
      if (!is.null(then)) {
        if (length(formals(then)) == 0L) then() else then(e)
      }
    }
  }
  ```

`write_back` is the recommended path. Drop to a hand-written
`\(e) ...` only when bespoke logic is needed (transform before
writing, conditional gating, writing through multiple props in one
handler).

#### Read-only snap-back happens automatically

Even when the writability gate blocks the call, the event listener
has *already fired* — that alone is enough. The event observer in
`mount.R` runs the force-send-on-no-op loop after every handler: it
reads every binding for the source element via
`bindings_by_id[[source_id]]`, isolate-evaluates the current
canonical value, and emits an `irid-attr widget:<key>` tagged with
the sequence. The widget's `update(key, value, sequence)` hook sees
a value different from its current state and snaps back. *The
wrapper writes nothing extra to get this — registering the listener
is sufficient.*

#### Ordering — write first, then user handler

`write_back` calls the writable callable *before* the `then`
handler. This matches DOM autobind, where the explicit `on*` always
sees post-write state. Wrappers should follow the same convention;
deviations should be documented.

#### Multi-event wrappers

For widgets with several round-trip keys, the wrapper becomes a
table of `write_back` calls. The R-side wrapper args are camelCase
`on*` (mirroring the DOM-event convention elsewhere in irid); the
events-list keys are kebab-case (the wire/JS name, matching the web's
`CustomEvent` convention), and the wrapper provides the translation:

```r
# Wrapper signature: camelCase on* args
MyWidget <- function(
  content, cursor, scrollTop,
  onChange        = NULL,
  onCursorChanged = NULL,
  onScroll        = NULL,
  onBlur          = NULL,
  ...
) {
  IridWidget(
    name   = "my-widget",
    props  = list(content = content, cursor = cursor, scrollTop = scrollTop),
    events = list(                                # kebab-case wire names
      change           = write_back(content,   "content",   then = onChange),
      `cursor-changed` = write_back(cursor,    "cursor",    then = onCursorChanged),
      scroll           = write_back(scrollTop, "scrollTop", then = onScroll),
      blur             = onBlur %||% function(e) NULL
    ),
    ...
  )
}
```

One line per event in the `events` list. The R↔wire mapping is "strip
`on`, kebab the camelCase" — i.e. `onCursorChanged` ↔ `cursor-changed`.
For standard DOM events on the container (`onClick`, `onMouseDown`), the
platform happens to use no-separator instead (`click`, `mousedown`), but
the mental model is the same: R-side stays camelCase, wire-side follows
the appropriate web convention for its category.

### Wrapper defaults — `event_defaults()`

Different widgets want different transport defaults: a CodeMirror
`change` is best debounced; a Plotly `click` should fire immediately;
a Leaflet `moveend` might want throttling. The widget *wrapper*
knows what's sensible; the framework can't. So irid exports a small
helper that lets the wrapper layer its preferred per-event defaults
underneath whatever `.event` the caller passes:

```r
event_defaults <- function(user, ...) {
  defaults <- list(...)
  if (is.null(user)) return(defaults)
  if (inherits(user, "irid_event_config")) return(user)  # caller scalar wins everywhere
  modifyList(defaults, user)                              # caller's per-event entries win
}
```

The canonical wrapper convention: accept `.event` as a passthrough
parameter, default `NULL`, layer wrapper defaults via
`event_defaults()`:

```r
CodeMirror <- function(content, ..., .event = NULL) {
  IridWidget(
    name   = "codemirror",
    props  = list(content = content),
    events = list(change = write_back(content, "content")),
    .event = event_defaults(
      .event,
      change = event_debounce(200, coalesce = TRUE)
    ),
    ...
  )
}
```

Three call-site shapes work uniformly:

```r
# 1) Caller passes nothing → wrapper defaults apply.
CodeMirror(content = doc)

# 2) Caller passes a scalar → broadcasts and wins everywhere,
#    wrapper defaults are dropped.
CodeMirror(content = doc, .event = event_throttle(100))

# 3) Caller passes a named list → per-event override; wrapper
#    defaults fill in any events the caller didn't mention.
CodeMirror(content = doc, .event = list(change = event_immediate()))
```

`event_defaults()` is generic — plain-tag wrappers can use it too.
A `SearchInput` wrapper might write
`event_defaults(.event, input = event_debounce(500))` to make
debounced-input the default for its callers.

### What `IridWidget` is, structurally

It's neither a control-flow node nor an `Output`. It's a third
process-tags citizen with class `irid_widget`. Its contribution to a
processed tag tree:

- A clean tag tree (the container, with auto-assigned `id` and the
  `data-irid-widget` attribute, plus any user children)
- N entries appended to `$bindings` (one per *callable* `props` key,
  attr = `widget:<key>`). Non-callable props produce no binding.
- M entries appended to `$events`, one per explicit `events` entry,
  marked with `source = "widget"`. (No framework-level autobind path,
  so no `merge_pending_events` collision case to handle for widgets —
  duplicate event-name entries from the wrapper would be a wrapper
  bug.)
- One entry appended to `$widget_inits` — a new sibling list to
  `$bindings` / `$events` / `$control_flows` / `$shiny_outputs` —
  carrying `{id, name, prop_fns, static_props, deps}` where
  `prop_fns` is the named list of callable prop entries and
  `static_props` is the named list of non-callable entries. Mount
  resolves them at init-message construction: `isolate(fn())` for
  each callable, the literal value for each static. The client sees
  one unified `props` object — it doesn't need to know which keys
  were reactive on the R side.

By piggybacking on existing extraction lists for bindings and events,
the widget gets the existing observer/event plumbing for *free* — the
new code path is only the init message + the deps hoisting.

### Lifecycle inside `When` / `Each` / `Match`

The widget container lives inside a control-flow wrapper range; its
lifetime is the lifetime of that range. Concretely:

- **`When` true→false transition.** The enclosing mount's
  `destroy()` runs all observers for the widget's prop bindings and
  event entries; the `irid-swap` empties the range. The detached fragment
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
  name: "codemirror",          // widget registry name
  props: {
    content: "initial code\n", // came from a reactive on R side
    theme: "dracula",          // came from a constant on R side
    language: "r",
    lineNumbers: true
  },
  deps: [
    { name: "cm6", version: "6.0.1",    // htmltools dep name (separate concept)
      script: "...", stylesheet: "..." }
  ]
}
```

The client receives one unified `props` object. Whether each key was
reactive or constant on the R side is invisible at this layer — the
distinction shows up only in whether subsequent `irid-attr widget:<key>`
messages arrive for that key.

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
2. Once deps ready, look up `defineWidget`'s registry for `name`.
3. **If the name is registered**: look up `document.getElementById(id)`,
   call the factory `init(el, props, send)`, store the returned
   `{update, destroy}` handle in a per-id widget map.
4. **If the name is not registered** (script still parsing /
   load order race): queue `{id, props, el}` under the name key.
   `defineWidget(name, factory)` drains the queue for `name` when
   called.

The init message is **idempotent on the client**: if a widget is
already mounted at `id`, the message is dropped. This guards against
the duplicate-init scenario when an `Each` reorder is misclassified
by the server (it shouldn't, but defense in depth costs nothing).

### Race answers (the platform realities)

- **Async `<script>` order.** Handled by the registry queue:
  `irid-widget-init` can arrive before its `defineWidget` call lands.
  The init is buffered until the name is registered.
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
- **`isolate()` at init.** Callable props are read with `isolate(fn())`
  in the init-message constructor; mount does not subscribe to widget
  state when sending init. The per-key observers are what subscribe —
  they get registered as ordinary bindings.

---

## 3. JS-side API

### What irid provides

A small object exported on `window.irid`:

```js
window.irid = {
  defineWidget(name, factory) { ... },
  sendWidgetEvent(id, event, payload) { ... }
}
```

- **`defineWidget(name, factory)`**: register a widget under a given
  registry name. `factory` is `function (el, props, send) -> { update,
  destroy }`. If the name already has queued inits, the registration
  drains them in arrival order before returning.
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
irid.defineWidget("codemirror", function (el, props, send) {
  // el:    the container DOM element (already in the document)
  // props: initial values for every R `props =` key
  // send:  send(event, payload) — push events through irid's pipeline
  //        (records of strings/numbers/booleans; irid adds id, nonce,
  //        __irid_seq)

  var editor = createEditor(el, {
    doc: props.content,
    theme: props.theme,
    language: props.language,
    extensions: [/* ... */]
  });

  editor.on("doc-change", function () {
    send("change", { content: editor.getValue() });
  });

  return {
    update: function (key, value, sequence) {
      // Branch only on keys the widget can live-update. Anything not
      // listed here (e.g. `language`, `extensions`) is silently dropped
      // — those are init-only per CodeMirror's API.
      if (key === "content") {
        if (value === editor.getValue()) return;       // idempotence
        editor.setValue(value);
      } else if (key === "theme") {
        editor.setTheme(value);
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
- **`props`** is a plain object with the initial values for every R
  `props =` key, regardless of whether each was reactive or constant
  on the R side. The widget applies them during init.
- **`send(event, payload)`** is a closure over `(id, event)`. The
  widget calls it whenever a user action should reach R. `payload` is
  any JSON-serializable object; the R handler receives it with `id`,
  `nonce`, `__irid_seq` stripped. If no R subscriber exists for an
  event name (the R side simply omitted that handler), `send` is a
  silent no-op — the widget can fire events unconditionally.
- **`update(key, value, sequence)`** runs in response to a single
  `props` key changing — only fires for keys that were callable on
  the R side. `sequence` is `undefined` for programmatic updates (no
  event triggered the change) and a number for echoes from an event
  that originated on the same widget. *Idempotence is the widget
  author's responsibility* — most updates round-trip the value the
  widget just sent. Keys the widget can't or won't live-update should
  simply have no branch in the switch; the update is dropped.
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
#' @param content   document text. Constant or reactive. A writable
#'   reactive (`reactiveVal`, store leaf, `reactiveProxy` with a setter,
#'   ...) gets a round-trip; a read-only callable (`reactive(...)`,
#'   0-arg closure) renders read-only and snaps the editor back on any
#'   user edit; a plain string mounts the editor with that initial
#'   text and never updates.
#' @param theme     theme name. Constant or reactive — reactive values
#'   are applied live via the JS `setTheme` API.
#' @param language  language name. **Init-only** per CodeMirror's API.
#'   A reactive value is read once at mount; later changes are ignored.
#' @param onChange  optional side handler `\(e) ...` to run after the
#'   write-back. Named `onChange` to mirror irid's tag-event convention
#'   (`tags$input(onChange = ...)`). Useful for logging or cross-field
#'   effects.
CodeMirror <- function(
  content,
  theme    = "dracula",
  language = "r",
  onChange = NULL,
  .event   = NULL
) {
  IridWidget(
    name   = "codemirror",
    props  = list(content = content, theme = theme, language = language),
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
```

The wrapper's *caller* never sees the autobind plumbing, and decides
per-arg what's reactive:

```r
# Everything static.
CodeMirror(content = "hello\n")

# Reactive content, static theme/language — minimal round-trip.
CodeMirror(content = doc)

# Reactive theme too — caller wants the editor to follow the app's
# dark-mode toggle.
CodeMirror(content = doc, theme = current_theme)

# Read-only view. The wrapper's `can_accept_write` gate skips the
# write, the force-send-on-no-op path echoes the canonical value
# back, snapping the editor.
CodeMirror(content = reactive(paste0("# Generated\n", source_text())))

# Bring-your-own side handler. The wrapper's `change` handler calls
# `onChange(e)` after the write, in the same flush.
CodeMirror(
  content  = doc,
  onChange = \(e) audit_log(now(), e$content)
)

# Caller passes a reactive to `language` — silently one-shot,
# because the wrapper's docs flagged it as init-only and the widget's
# JS update hook has no branch for "language".
CodeMirror(content = doc, language = current_lang)
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

irid.defineWidget("codemirror", function (el, props, send) {
  var view = new EditorView({
    parent: el,
    state: EditorState.create({
      doc: props.content,
      extensions: [
        basicSetup,
        LANGS[props.language](),                          // init-only
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
        var current = view.state.doc.toString();
        if (value === current) return;     // echo of what we just sent
        view.dispatch({
          changes: { from: 0, to: current.length, insert: value }
        });
      } else if (key === "theme") {
        // Live theme swap via a reconfigurable compartment (omitted for brevity)
        applyTheme(view, value);
      }
      // No branch for "language" — init-only per CodeMirror;
      // updates are silently dropped.
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
rv)`. The `write_back(content, "content", then = on_change)` baked
into `CodeMirror`'s wrapper is what makes that possible — one event
entry written once when wrapping the library, then transparent for
every caller.

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
   prop binding observer and event observer), sends `irid-swap` with
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
| Constructor signature — reactive in, events out, static config? | Two named-list args: `props` (per-key dispatch on `is.function()` — callable = observed reactive, non-callable = init-only constant), `events` (callbacks out, registered per event name). Plus `container`, `deps`, `.event`. No separate `state` / `config` split; the distinction lives per-key inside `props` and matches irid's "functions, not expressions" rule. |
| Should widgets autobind? | **No framework-level autobind; per-widget round-trip lives in the wrapper.** irid exports two helpers: `can_accept_write()` (writability predicate) and `write_back(callable, field, then = NULL)` (handler factory that combines the write, the writability gate, and an optional chained user handler in one line per event). Read-only snap-back happens automatically via the existing force-send-on-no-op path — `write_back` only needs the listener registered. Boilerplate is paid once per wrapper, never per call. |
| JS/CSS dep attachment? | `deps = ` arg accepts one `html_dependency` or a list. `process_tags` lifts them off the widget node into `widget_inits` because `htmltools::as.character()` strips them. Mount ships them on the `irid-widget-init` message; client renders via `Shiny.renderDependencies` (dedup by name+version). |
| How does the JS file declare "I handle widget named X"? | Explicit registry: `irid.defineWidget("name", factory)`. Inits arriving before the registration are queued and drained on registration. Robust under arbitrary script load order. |
| JS lifecycle contract? | Factory returns `{update, destroy}`. `update(key, value, sequence)` per-key — only fires for keys that were callable on the R side; init-only keys have no update branch. `destroy()` before container detachment. Factory signature `(el, props, send)`. |
| `When`/`Each`/`Match` teardown ordering? | Server-side: `irid_mount_processed`'s `destroy()` tears down prop and event observers as part of the enclosing mount's `observers` list. Client-side: `irid-swap` / `irid-mutate` detach walkers find `data-irid-widget` elements in the detached fragment and call their `destroy()` hooks before GC. No `irid-widget-destroy` message — purely client-driven. |
| Container element ownership? | User-supplied via `container = tags$div(...)`. irid injects `id` and `data-irid-widget = name`. User can set classes, styles, even children. Default `tags$div()`. |
| Widget identity across re-renders? | Tied to container's DOM element identity. **Survives** `Each` keyed reorders (insertBefore preserves identity). **Does not survive** `When`/`Match` branch flips or `Each` shape-change rebuilds — those rebuild the widget fresh. Same semantics as `<input>` focus/scroll/selection state. |
| Initial props read — reactive dep? | Callable props are read via `isolate(fn())` at init-message construction. Static props pass through literally. Mount itself does not subscribe to widget props. The per-key bindings (one per callable prop) subscribe — same `observe()` pattern as existing reactive attrs. |
| Widget events sharing timing / sequence machinery? | Yes. Widget events ride `irid-events` with `source: "widget"`. The client initializes managed state (throttle/debounce/coalesce/sequence) but skips `addEventListener`. The widget JS pushes via `irid.sendWidgetEvent`, which routes through the managed state and `Shiny.setInputValue` — `.event` config and stale indicator work transparently. |
| `.event` defaults for widget events? | Three-tier: caller's `.event` > wrapper defaults (via `event_defaults()` helper) > framework default = `event_immediate()` for every widget event (no `input → debounce(200)` special case — that rule is DOM-tuned). Wrapper convention is to accept `.event` as a passthrough arg and layer per-event defaults with `event_defaults(.event, change = ..., ...)`. |
| DOM events on the widget container? | Allowed — `container = tags$div(onClick = ...)` works; `process_tags` extracts those as ordinary DOM events. They coexist with widget events on the same element id and share the same `.event` lookup. Name collisions (e.g. widget JS emits `"click"` while user has `onClick`) are author error. |
| Race: script not loaded when init arrives? | Registry queue. Inits buffer per name until `defineWidget(name, ...)` lands; drained on registration. |
| Race: `<script src>` re-execution on re-insertion? | Avoided. Deps never flow through swap/mutate HTML. They ride `irid-widget-init` and `Shiny.renderDependencies` dedupes — one `<script>` fetch per session. |

---

## 6. Test plan implications

The widget mechanism extends three existing testing surfaces and adds a
fourth:

- **`process_tags` extraction** gets:
  - widget node produces `$widget_inits` entry with `{id, name, prop_fns, static_props, deps}`
  - callable prop keys become `$bindings` with `attr = "widget:<key>"`
  - non-callable prop keys produce no binding (their value rides in
    `static_props` on the init message only)
  - events become `$events` with `source = "widget"`
  - container `id` and `data-irid-widget` are set on the output tag
  - mixed-shape `props` list (some callables, some not) is fully
    supported — each key dispatches on `is.function()` independently

- **Public helper `can_accept_write()`** gets:
  - returns `TRUE` for primitives, closures with ≥1 formal,
    `reactiveVal`, store leaves, `reactiveProxy` with a setter
  - returns `FALSE` for `reactive(...)`, `\() expr` closures,
    `reactiveProxy` with no setter, non-callables
  - exported from the package (rename of internal
    `can_accept_write` in `process_tags.R`, or wrapper around it)
  - documented with the wrapper-author autobind pattern as the canonical
    use case

- **Public helper `write_back(callable, field, then = NULL)`** gets:
  - writable callable + 1-arg `then` → handler writes through
    callable, then calls `then(e)`
  - writable callable + 0-arg `then` → handler writes through
    callable, then calls `then()`
  - writable callable + `NULL` `then` → handler only writes
  - read-only callable → write is silently skipped (gated by
    `can_accept_write`); `then` still runs; force-send-on-no-op
    fires the echo so the widget snaps back
  - non-callable in `callable` slot is a programming error — should
    error at construction (the wrapper is using the helper
    incorrectly)
  - missing `field` in payload at runtime → `callable(NULL)`; the
    widget author / wrapper author is responsible for emitting the
    declared field

- **Public helper `event_defaults(user, ...)`** gets:
  - `user = NULL` → returns the `...` list as-is
  - `user` is a scalar `irid_event_config` → returns `user` unchanged
    (caller scalar wins everywhere; wrapper defaults dropped)
  - `user` is a named list → returns a `modifyList` merge where
    `user`'s entries win over the `...` defaults; defaults fill in
    for events `user` didn't mention
  - malformed `user` (anything else) → defers to the existing
    `normalize_element_event` validation in `process_tags.R`, so
    errors surface at process time with the same messages
  - widget framework default = `event_immediate()` for every event
    (no `input` special case)
  - DOM framework default unchanged: `input → event_debounce(200)`,
    everything else → `event_immediate()`

- **Observer lifecycle** gets:
  - destroying the enclosing mount tears down widget prop observers and event observers
  - widget inside `When` mounts/unmounts on toggle (init message after swap; destroy via detach walker)
  - widget inside keyed `Each` survives reorder (`insertBefore` preserves identity; no init re-send)
  - widget inside positional `Each` survives same-length in-place updates (per-key updates via `irid-attr widget:*`)
  - constant prop with same value across re-render fires no update (no observer registered)
  - reactive prop passed to a key the widget's JS doesn't handle: the
    update message arrives, the JS `update` falls through, no
    error — silently one-shot in effect

- **Client-side handling** gets:
  - `irid-attr` with `widget:<key>` routes to the widget's `update` hook
  - `irid-events` with `source: "widget"` initializes managed state but skips `addEventListener`
  - `irid.sendWidgetEvent` builds payload with `id` / `nonce` / `__irid_seq` and pushes through `managed[inputId]`
  - `detachRange` walks for `data-irid-widget` elements and invokes their `destroy()` hooks
  - `defineWidget` drains queued inits in arrival order
  - duplicate `irid-widget-init` for the same id is a no-op

- **Widget API contract** (new surface):
  - factory called once per mount with `(el, props, send)`
  - `update(key, value, sequence)` called for each `irid-attr widget:*`
    (only for keys that were callable on the R side)
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
- **Custom DOM events on regular `tags$*` elements.** This doc sets a
  kebab-case convention for *widget* events (matching the web's
  `CustomEvent` tradition), but irid's existing DOM-event surface on
  regular tags transforms `on*` args to no-separator form
  (`onMouseDown` → `mousedown`) to match standard DOM event names.
  Custom DOM events fired by Web Components or third-party JS —
  `CustomEvent("cursor-changed")` — are therefore not reachable through
  `tags$*(onCursorChanged = ...)` today. Aligning the DOM-event surface
  to use a *lookup-with-kebab-fallback* transformation (standard event
  names keep no-separator; everything else falls back to kebab) is the
  follow-up that closes this gap and unlocks the Web Components
  ecosystem at low ceremony. See `custom-dom-events-design.md`.
