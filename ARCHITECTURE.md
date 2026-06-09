# Architecture

## File Layout

```
R/
  app.R           iridApp, iridOutput, renderIrid
  primitives.R    When, Each, Match/Case/Default, Output
  event.R         irid_wire carrier; irid_immediate/throttle/debounce timing
                  shapes; irid_dom_opts; merge.irid_wire
  process_tags.R  Tag tree walker — extracts reactive bindings, events, control flows, widgets
  mount.R         Mounts processed tags into a Shiny session (observers, lifecycle)
  store.R         reactiveStore — hierarchical reactive state container
  mini_store.R    make_mini_store / make_slot_accessor / is_record — per-item / per-case projections used by Each and Match
  scope.R         make_scope — per-item / per-case lifetime container; shim for shiny#4372 subdomain teardown
  proxy.R         reactiveProxy — callable built from a reader and optional writer
  widget.R        IridWidget (two-way props) + dep-registration
  irid-package.R Package-level imports

inst/js/
  irid.js        Client-side message handlers (vanilla JS, no build step)

inst/widgets/<name>/
  <name>-irid.js   Per-widget factory registration (one dir per shipped widget;
                   user widgets live in user packages, not here)

examples/
  old_faithful.R        Old Faithful geyser histogram with PlotOutput
  composing.R           Two Counter instances showing closure-based isolation
  temperature.R         Bidirectional temperature converter (controlled inputs)
  todo.R                Todo app (Each positional, When, dynamic lists)
  optimistic_updates.R  Controlled inputs with simulated server latency
  shiny_interop.R       irid components inside a standard Shiny module
  cards.R               Dynamic column cards (Each, keyed by column name)
  each_nested.R         Nested Each + recursive mini-store fields
  each_heterogeneous.R  Block editor with mixed record shapes + Match dispatch
  codemirror.R          CodeMirror editor widget via IridWidget + esm.sh CDN
```

## Design Principles

**Functions, not expressions.** irid's core rule is: pass a function to make
something reactive. This applies uniformly across tag attributes, tag children,
and `Output`/`PlotOutput`/`TableOutput`/`DTOutput`. Shiny's render functions
use expression-based NSE (`renderPlot({ ... })`), but irid wraps them with a
function interface for two reasons: (1) consistency — users never need an
exception for outputs; (2) composability — a named function can be passed
directly (`PlotOutput(my_plot_fn)`), which expressions cannot support.

## Two-Phase Rendering

irid splits rendering into two phases: **process** and **mount**.

### Phase 1: `process_tags`

Walks the tag tree recursively and produces:

- **`tag`** — A clean HTML tag tree with all functions removed. Reactive
  attributes are replaced by stable auto-generated element IDs. Control-flow
  nodes become a pair of HTML **comment anchors**
  (`<!--irid:s:ID--><!--irid:e:ID-->`) that mark the range where content
  should be inserted. Per-slot config carried by `irid_wire` (timing,
  coalesce, DOM listener options) is consumed during the walk and never
  reaches HTML serialization. Widget nodes become their container element
  with `id` and `data-irid-widget="<name>"` attributes attached.
- **`bindings`** — List of binding rows for each reactive attribute,
  reactive text child, or reactive widget prop. Each row carries a
  `target` field that drives client-side dispatch:
  - `target = "dom"` rows are `{id, target, attr, fn}` — the binding
    mutates a DOM attribute/property on `getElementById(id)`.
  - `target = "text"` rows are `{id, target, fn}` (no `attr`) — the
    binding replaces the content between the comment-anchor pair `id`
    with a single text node. Reactive text children use the anchor-pair
    form so they remain valid inside restricted-content parents
    (`<option>`, `<textarea>`, ...) where a `<span>` wrapper would be
    stripped by the HTML parser.
  - `target = "widget"` rows are `{id, target, attr, fn}` — the binding
    routes per-key updates to the widget instance's `update(key, value)`
    hook.
- **`events`** — List of `{id, event, handler, source, mode, ms, leading,
  coalesce, prevent_default, stop_propagation, capture, passive}`, one entry
  per `(id, event)`. `source = "dom"` for events attached to a DOM element
  via `addEventListener`; `source = "widget"` for widget events (pushed via
  `sendEvent()`) and two-way-prop write-backs (pushed via `setProp()`). A
  `kind` field distinguishes a `"prop"` write-back (input
  `irid_prop_{id}_{key}`) from a regular `"event"` (input
  `irid_ev_{id}_{event}`); DOM-event rows omit `kind`. A given DOM event is
  claimed by **at most one** of {value-binding autobind, explicit `on*`} —
  there is no merge (see the one-channel rule below). `handler` is `NULL` for
  a config-only event (an `irid_wire` with `dom_opts` but no subject) — the
  client attaches a listener for the DOM flags but never round-trips.
- **`control_flows`** — List of `{type, id, ...}` for each `When`, `Each`,
  or `Match` node.
- **`shiny_outputs`** — List of `{id, render_call}` for each `Output` node.
- **`widget_inits`** — List of `{id, name, prop_fns, static_props, deps}`
  for each `IridWidget` node. `prop_fns` is the named list of callable
  props (read with `isolate(fn())` at mount-time to seed the init
  payload); `static_props` is the named list of non-callable values
  shipped verbatim. See the *Widgets* section below.

When a state-binding prop (`value`, `checked`) holds a callable, process_tags
emits both a binding (server → client read) and a synthetic event entry
(client → server write). The synthetic handler is arity-dispatched: 0-arg
callables get a no-op handler so the listener still fires and the
optimistic-update protocol echoes the current value back. 1-arg+ callables
receive the event field of the same name as the prop (`e$value` for `value`,
`e$checked` for `checked`) — irid stays close to the DOM IDL, so the prop
name and the event field name always match.

**One channel per event.** A given DOM event is driven by a value binding
*or* an explicit `on*` handler, never both. `value = rv` and `onInput = ...`
on the same `<input>` is an error, not a merge — the binding already claims
the `input` event. The check is per-event: `value = rv` coexists with
`onKeyDown` (different events) freely. Likewise, two explicit handlers on the
same event error (no composition). The sync-write-on-bound-value case uses
`value = reactiveProxy(get, set)` — the proxy's `set` *is* the handler that
runs on write; async reactions observe the bound reactive. This deletes the
old autobind↔explicit merge, its ordering rule, and the two-timings
collision.

**Per-slot config (`irid_wire`).** Timing, backpressure, and DOM listener
options ride the slot they configure. A bare callable (`onClick = \() …`,
`value = rv`) is sugar for `irid_wire(callable)` with default config;
`irid_wire(subject, timing, coalesce, dom_opts)` tunes it. The timing shapes
(`irid_immediate()`, `irid_throttle(ms, leading)`, `irid_debounce(ms)`) are
pure — they carry only mode-specific fields. `coalesce` is universal so it
lives on the carrier; when `NULL` it derives from the mode (`immediate →
FALSE`, rate-limited → `TRUE`). When a wire carries no `timing`, the
per-event default applies, keyed on the DOM event name: `input` →
`irid_debounce(200)`, everything else → `irid_immediate()`. DOM listener
flags (`prevent_default`, `stop_propagation`, `capture`, `passive`) bundle
into `irid_dom_opts()` inside the wire; each defaults to `FALSE`.

The tag tree is now plain HTML that can be sent to the client. All reactive
wiring is deferred to mount.

### Phase 2: `irid_mount_processed`

Takes the output of `process_tags` and a Shiny `session`, then wires up:

1. **Reactive bindings** — Each binding gets an `observe()` that sends
   `irid-attr` messages when the reactive value changes.
2. **Event handlers** — Each event gets an `observeEvent()` on a namespaced
   input ID (`irid_ev_{id}_{event}`). The handler is dispatched based on its
   formal argument count (0, 1, or 2 args). Event registration is sent to the
   client as a `irid-events` message.
3. **Shiny outputs** — Each output's render call is assigned to
   `session$output[[id]]`.
4. **Control-flow nodes** — Each node gets an `observe()` that manages its
   lifecycle (see below).

Returns a mount handle with `$tag` (the processed HTML) and `$destroy()` (tears
down all observers).

## Control Flow Lifecycle

**When** and **Match** each manage a single `current_mount` — a mount handle
from a recursive `irid_mount_processed` call. Both short-circuit: the observer
re-evaluates on every reactive invalidation but only destroys and recreates the
branch when the active branch actually changes. This is critical when wrapping
`Each` — without the short-circuit, any change to a reactive dependency shared
with the condition would destroy the inner mount and lose per-item state.

**When** is the binary specialization: `condition` is a reactive boolean,
`yes` and `otherwise` are 0-arg functions that return a tag tree. Bodies are
called fresh on each activation (the previous branch's closures were torn
down with its reactives, so a captured tag tree would reference dead state).

**Match** dispatches on a leading callable's value. The `Match` observer reads
`callable()`, walks each `Case`'s predicate (1-arg of the bound value or
0-arg cross-cutting; literal predicates are normalised to
`\(v) identical(v, literal)`), and picks the first truthy one. On
active-case change, the previous mount and the per-case `scope` are
destroyed; a fresh `scope` is created; if the bound value is a record
(`is_record()`), it is projected as a mini-store (`make_mini_store()`)
and passed to the case body, otherwise the bare callable is passed; the body
function is called and the result is mounted. Same-case value changes do not
remount — the active mini-store's internal observer auto-propagates value
changes to its leaves so only the bindings whose field actually changed
re-fire.

**Each** manages per-item mount handles and uses `irid-mutate` for granular DOM
mutations. Each item is bracketed by its own pair of comment anchors so the
client can insert, remove, and reorder individual children. The callback
receives a per-item callable plus an optional position accessor:

- **Record items** → per-item mini-store (`make_mini_store()`). `item()` reads the
  whole record; `item(record)` writes it back; `item$field()` reads a leaf;
  `item$field(v)` is a synthetic setter that writes through the parent
  collection. Data flows one direction: parent → mini-store leaves → DOM,
  with synthetic setters routing writes back up. The reactive graph is
  acyclic — leaves never hold independent state.
- **Scalar items** → per-item scalar slot accessor (`make_slot_accessor()`)
  (a `reactiveProxy` over an internal `reactiveVal`). `item()` reads;
  `item(v)` writes back to the parent's slot.

Accessor type is decided per-entry from the item's current value, so
heterogeneous lists work — a slot holding a record gets a mini-store
while its sibling holding a scalar gets a scalar accessor. Wrap the
per-item callable in `Match` to dispatch on shape inside the callback.
When a slot's value transitions between shapes (scalar↔record, or a
record's keys change), the outer reconciler treats it as a remove +
rebuild of just that entry — a fresh scope, accessor, and DOM range —
emitted as a single `irid-mutate` with `order` so the client repositions
the rebuilt range.

The reconciliation strategy is selected by `by`:

- **Positional** (`by = NULL`, the default) — slot *i* is slot *i*. The list
  can grow or shrink at the end; in-place value changes propagate via each
  slot accessor's internal observer (no DOM work). Same-length value changes
  fire only the slots whose value actually changed. A surviving slot whose
  shape changed is rebuilt in place.
- **Keyed** (`by = fn`) — items are tracked across reorders, adds, and
  removes by their `by(item)` key. Kept items have their existing
  mini-store / accessor reused (no remount, no new scope) and self-update
  via the propagating observer; new items are mounted; removed items are
  destroyed; reordered items have their DOM nodes moved via `irid-mutate`'s
  `order` mechanism. A kept key whose value's shape changed is rebuilt.

The callback is arity-polymorphic — `\() body`, `\(item) body`, or
`\(item, pos) body`. `pos` is always a 0-arg reactive accessor for the
item's current 1-indexed slot: a constant signal under `by = NULL` (slot
number is the identity), live under `by = fn` (fires on reorder).

Each per-item / per-case mount creates its own `scope` (see
`make_scope()`) to bound the lifetime of the per-item / per-case
reactives and observers. Today the scope is a thin manual observer
tracker; once [shiny#4372](https://github.com/rstudio/shiny/pull/4372)
merges, `make_scope` becomes a one-line wrapper around
`session$makeSubdomain()` and the auto-destroy registry handles teardown.
Every site that depends on the shim is tagged `# shiny#4372:` so the
post-merge swap is mechanical.

**Known limitation — reactive-leak until shiny#4372 lands.** `scope$destroy()`
tears down the observers it tracks, but cannot tear down the `reactiveVal`s
held inside mini-store leaves and slot accessors — Shiny exposes no public
API for destroying a `reactiveVal`. Each unmounted `Each` item and each
unmounted `Match` case leaves its leaves behind in the session's reactive
graph. For short-lived sessions this is harmless; for long-lived sessions
that churn list contents (e.g. a dashboard where rows are added/removed
continuously), the leaked leaves accumulate and grow session memory. The
leak is bounded per-session — it resets when the session ends — but apps in
that shape should monitor session lifetime until shiny#4372 lands and the
subdomain cascade reclaims the leaves.

## Comment-Anchor Range Protocol

Control-flow containers and `Each` items are represented in the DOM as
pairs of HTML comment markers rather than wrapper elements. This keeps them
valid children of any parent — including restricted-content elements like
`<select>`, `<table>`, `<tbody>`, and `<ul>` — where a wrapper `<div>` would
be dropped or hoisted by the browser's HTML parser.

```html
<select>
  <!--irid:s:irid-5-->
  <!--irid:s:irid-7--><option>Foo</option><!--irid:e:irid-7-->
  <!--irid:s:irid-8--><option>Bar</option><!--irid:e:irid-8-->
  <!--irid:e:irid-5-->
</select>
```

The client maintains a `Map` from anchor ID to `{start, end}` comment-node
references (`anchors` in `irid.js`). It is populated on initial page load by
walking `document.body` for comment nodes and lazily refreshed on cache miss
to handle dynamic content delivered via `renderIrid` (which arrives as a
Shiny output binding update, not a irid custom message).

Inserted HTML is parsed via `Range.createContextualFragment` using the
anchor's parent as the parsing context, so content like `<option>` or `<tr>`
parses correctly against its surrounding element.

Removed ranges are moved into a detached `DocumentFragment` and their nested
anchors are deregistered from the `Map` via a `TreeWalker` over the fragment.
Reordering moves ranges by lifting each `[start..end]` range into a fragment
and reinserting it before the container's end anchor — element identity and
anchor references are preserved across moves.

## Client-Side Protocol

`irid.js` registers Shiny custom message handlers for `irid-config`,
`irid-attr`, `irid-swap`, `irid-mutate`, `irid-events`, and
`irid-widget-init`.

### `irid-attr`

```js
// target = "dom" — DOM property/attribute write
{id: "irid-3", target: "dom",  attr: "value", value: "hello", sequence: 12}

// target = "text" — text replacement in a comment-anchor range
{id: "irid-5", target: "text", value: "Count: 42"}

// target = "widget" — route a coalesced batch to a widget's update() hook.
// `values` is always a {attr -> value} map (one or more keys), built by
// coalescing every widget binding that fired in the same server flush.
{id: "irid-7", target: "widget",
 values: {content: "...", cursor: {line: 1, ch: 1}}, sequence: 12}
```

Dispatches on `msg.target`. For `"dom"`: sets a DOM property or
attribute on `getElementById(msg.id)`. Special-cased properties:
`value`, `disabled`, `checked`, `innerHTML` are set as JS properties
(not HTML attributes); `textContent` is set via the `.textContent`
property; other attributes use `setAttribute()`; `false` / `null`
values call `removeAttribute()`. Skips the update if the element
has focus and `msg.attr === "value"` (optimistic update — see below).
For `"text"`: looks up the comment-anchor pair `msg.id`, removes
everything between the start and end anchors (running
`Shiny.unbindAll` on each removed element), and inserts a single
text node when `value` is non-empty. For `"widget"`: looks up the
widget registered at `msg.id` and calls `handle.update(msg.values)`
with the coalesced `{attr -> value}` map; the widget's update hook
owns the "compare against current state, skip on match" logic — irid
stays generic because what counts as "current state" is
library-specific. The universal stale-echo gate above ensures the
widget never sees out-of-order batches, so the hook doesn't need a
sequence argument. See [Widgets](#widgets) for the per-flush
batching that builds `values`.

### `irid-swap`

```js
{id: "irid-5", html: "<li>new content</li>"}
```

Looks up the anchor pair for `id`, detaches everything between the start
and end anchors (running `Shiny.unbindAll` on each removed element), parses
`html` as a contextual fragment, registers nested anchors, inserts the
fragment before the end anchor, then defers `Shiny.bindAll` on the parent
to initialize any Shiny outputs in the new content.

### `irid-mutate`

```js
{
  id: "irid-5",
  removes: ["irid-7", "irid-9"],
  inserts: ["<div id='irid-12' ...>...</div>"],
  order: ["irid-6", "irid-12", "irid-8"]
}
```

Performs granular range mutations between the container's anchors. Used by
`Each` instead of `irid-swap` to avoid destroying and recreating all
children on every list change.

1. **Removes** — For each child ID, looks up its anchor pair and moves the
   entire `[start..end]` range into a detached fragment (unbinding elements
   and deregistering nested anchors).
2. **Inserts** — Parses each HTML fragment in the container's parent context,
   registers its anchors, and inserts it before the container's end anchor.
3. **Order** (optional) — Reorders children by lifting each child's range
   into a fragment and reinserting it before the container's end anchor in
   the desired order. Moves preserve element identity and anchor references.

After all mutations, `Shiny.bindAll` is deferred via `setTimeout(0)` to
initialize any new Shiny outputs.

### `irid-events`

```js
[
  {
    id: "irid-2",
    event: "input",
    inputId: "irid_ev_irid-2_input",
    source: "dom",
    mode: "throttle",
    ms: 100,
    leading: true,
    coalesce: true,
    preventDefault: false,
    stopPropagation: false,
    capture: false,
    passive: false,
    clientOnly: false,
  },
];
```

For each entry, initializes a managed-state record under `inputId`
(throttle/debounce/coalesce/sequence gating). If `source = "dom"`, also
attaches a DOM event listener on the element — the listener applies the
`preventDefault` / `stopPropagation` flags (and registers with the
`capture` / `passive` options), reads the element's `value` (and other
event fields), and pushes the payload through the managed-state via
`Shiny.setInputValue(inputId, payload, {priority: "event"})`. A
`clientOnly` entry (a config-only `irid_wire` with `dom_opts` but no
handler) attaches a bare listener that applies the DOM flags and never
sends — no managed state, no round-trip. If `source = "widget"`, the
listener-attach step is skipped;
the widget JS pushes payloads through `irid.sendWidgetEvent(id, event,
payload)`, which uses the same managed-state machinery. The DOM and
widget paths share one sequence counter per element id, so cross-element
echoes are gated uniformly.

When `coalesce` is true, the rate limiter also gates on server idle state
(via `Shiny.shinyapp.$idleTimeout`), so events never queue faster than
the server can process them.

### `irid-widget-init`

```js
{
  id:    "irid-7",
  name:  "codemirror",
  props: { content: "...", language: "r", theme: "dracula" },
  deps:  [{ name: "cm6", version: "6.0.1", src: { href: "..." }, ... }]
}
```

Sent after the swap/mutate that introduces the widget's container into
the DOM. The client:

1. Calls `Shiny.renderDependencies(msg.deps)` to inject `<script>` /
   `<link>` tags. Deps are dedup'd by name across the session.
2. Looks up the factory registered under `msg.name`. If none is
   registered yet (script still loading), buffers `{id, props}` under
   `pendingInits[name]` and drains it when `irid.defineWidget(name, ...)`
   eventually lands.
3. Once the factory is available, calls
   `factory(el, props, sendEvent, setProp)` and stores the returned
   `{update, destroy}` handle in a per-id widget map.
   The init message is idempotent — a duplicate for an already-mounted
   id is dropped.

## Controlled Input: Optimistic Updates

When a user types into a focused input, the server echoes the value back through
the reactive binding. Without care, this echo can cause cursor jumping or
overwrite characters the user typed while the server was processing. Conversely,
programmatic updates (e.g. clearing an input after form submission) must always
apply, even while the element is focused.

**Sequence numbers** solve this. Each event payload includes an incrementing
`__irid_seq`. The R event observer stores it on
`session$userData$irid_current_sequence` and registers `session$onFlushed` to
clear it after the flush completes. Binding observers attach the sequence to
`irid-attr` messages when present. On the client, `irid-attr` for `value` on a
focused element uses the sequence to decide:

- **Stale echo** (sequence < client's latest sent) → skip.
- **Current echo, same value** (sequence ≥ latest sent, `el.value === msg.value`)
  → no-op skip (avoids cursor position reset).
- **Server transform** (sequence ≥ latest sent, different value) → apply (e.g.
  server uppercases input).
- **Programmatic update** (no sequence) → always apply.

Key design points:

- **`onFlushed` for cleanup.** The sequence is stored as a plain (non-reactive)
  session variable so binding observers can read it without creating a reactive
  dependency. `session$onFlushed(once = TRUE)` clears it after the entire reactive
  chain settles — derived reactives and chained observers all see the sequence
  within the same flush, but the next flush starts clean.

- **Cross-element updates.** The R side stores both the sequence and the source
  element ID. Binding observers only attach the sequence when `b$id` matches the
  event source. If a button click's handler clears a text input, the text input's
  binding sees a different source and omits the sequence — so the client treats it
  as a programmatic update and applies it. Without this, the button's sequence
  (e.g. 1) would be compared against the text input's independent counter (e.g. 5)
  and incorrectly rejected as stale.

- **Multiple events in one flush.** If two event observers run in the same flush,
  the later one's sequence overwrites the earlier. This is correct — it means all
  bindings in that flush are tagged with the latest sequence, which is the most
  conservative (least likely to be considered stale).

- **`__irid_seq` is excluded** from the `event_obj` passed to user handlers, so
  it is an internal-only field.

- **Force-send on no-op.** After running the user's event handler, the event
  observer reads all bindings for the source element with `isolate()` and sends
  `irid-attr` messages tagged with the sequence. This covers the case where the
  handler sets a `reactiveVal` to the same value it already holds (a no-op that
  doesn't invalidate the binding observer). Without the force-send, the client
  would receive no echo and could not apply a server transform. For example, a
  handler that truncates `text(substr(event$value, 1, 10))` when `text()` is
  already 10 characters — the reactive doesn't change, but the client still needs
  the truncated value to replace what the user typed. When the reactive *does*
  change, both the force-send and the binding observer fire with the same value;
  the client handles the duplicate harmlessly.

## Stale UI Indicator

When the server takes too long to respond after an event, an animated progress
bar appears fixed at the top of the viewport to signal that displayed state may
be stale. Elements remain fully interactive — this is a visual cue, not a
disabled state.

**Option:** `irid.stale_timeout` — milliseconds to wait before showing the
indicator. Default `200`. Set to `NULL` to disable.

**Flow:**

1. The session entry points (`iridApp` server, `renderIrid` `onFlushed`) send
   a `irid-config` message with the timeout from `getOption("irid.stale_timeout")`.
2. On the client, every `sendPayload` call starts a show timer (if not already
   running). It also cancels any pending clear, keeping the indicator up if a
   new event fires shortly after the server goes idle.
3. If `shiny:idle` fires before the show timer, the timer is reset.
4. If the show timer fires first, `irid-stale` is added to `<html>`, which
   shows an animated progress bar fixed at the top of the viewport via
   `irid.css`. The progress bar color is customizable with the
   `--irid-stale-color` CSS variable (defaults to Bootstrap gray).
5. When `shiny:idle` fires, a debounced clear is scheduled (100ms). If
   `shiny:busy` fires before the clear executes (e.g. a reactive chain
   triggers a follow-up flush), the clear is cancelled. The indicator only
   removes once the server is truly idle for the full debounce window.

**Debug:** `irid.debug.latency` (seconds) adds a `Sys.sleep` to every event
handler. The `optimistic_updates` example exposes this as a slider.

## Reactive Proxy

`reactiveProxy(get, set = NULL)` builds a callable from a 0-arg `get` reader
and an optional 1-arg `set` writer, while remaining callable itself.
`proxy()` invokes `get()`; `proxy(value)` invokes `set(value)` when set is
non-`NULL`, or drops the write silently. Auto-bind dispatches on
`is.function()`, so a proxy slots into any prop that accepts a `reactiveVal`
or store leaf without special handling. Proxies compose — using another
proxy as `get` is just using another callable.

`set` is a side-effectful handler, not a pure transform: it can write to a
target, transform first, gate conditionally, or drop the write entirely.
Because `set` is a closure, it can read sibling state for cross-field
validation. With `set = NULL` (the default), writes are silently dropped —
paired with the optimistic-update protocol above, this makes a focused input
snap back to the current server value, which is the read-only contract for
controlled inputs.

## Widgets

`IridWidget(name, props, events, deps, container)` is the
process-tags citizen for arbitrary JavaScript libraries (CodeMirror,
Plotly, Leaflet, ...). It expresses one R-side component on top of an
init/update/destroy contract on the JS side, and reuses every existing
irid channel — `irid-attr` for one-way prop updates, `irid-events` for
event payloads, the optimistic-update sequence counter, the `irid_wire`
timing config, the stale indicator, the comment-anchor lifecycle. No
widget-specific code lives in the transport.

### Constructor

```r
IridWidget(
  name,                # registry name; must match a JS defineWidget call
  props     = list(),  # named list; per-key is.function() dispatch
  events    = list(),  # named list of handler fns (lowercase kebab keys)
  deps      = NULL,    # html_dependency or list of them
  container = NULL     # optional shiny.tag; defaults to tags$div()
)
```

`props` follows irid's "functions, not expressions" rule per-key, and
props are **two-way-capable by default**, exactly like DOM `value` /
`checked`. A callable value (`reactiveVal`, store leaf, `reactiveProxy`,
...) gets *both* directions wired: a server → client binding (one observer
firing `irid-attr target="widget"` → the factory's `update` hook on change)
**and** a synthesized client → server write-back, accepted when the widget
JS calls `setProp(key, value)`. A non-callable value rides in the init
message and is never re-sent (init-only library options need no separate
API — pass a constant, no observer). Wrapping a prop in `irid_wire` only
*tunes* its write-back timing; it never enables or disables two-way.

`events` carries genuine notifications that correspond to *no* prop. Keys
are lowercase kebab-case (web `CustomEvent` convention — `cursor-changed`,
`relayout`). No `on` prefix because there's no DOM event mediating — the
widget JS chooses what to fire via `sendEvent()`. Each value is a handler
or an `irid_wire` (to tune timing); `NULL` (or a `merge()` resolving to a
subject-less wire) is dropped, so optional handlers forward declaratively.

### Two-way props: `setProp` + `irid_prop_*`

irid hard-codes DOM autobind for `value`/`checked` because the DOM IDL
gives every element a uniform (prop, event, event-field) triple. Widget
props get the same treatment by construction: R always sets up the
inbound-accept + snap-back for a callable prop, and whether it's *actually*
two-way is decided by whether the widget JS pushes through the prop channel.

The new primitive is **`setProp` + a per-prop `irid_prop_{id}_{key}`
input** — the client → server partner of the existing server → client
`irid-attr target="widget"` → `update` hook. `setProp("content", value)`
pushes through the **same managed-state / sequence transport as
`sendEvent`** (so optimistic-update gating and echo-sequencing apply), but
to `irid_prop_{id}_{key}` instead of `irid_ev_{id}_{event}`. process_tags
emits, per callable prop, a `kind = "prop"` event row whose synthesized
handler writes the bound reactive (gated by the internal `can_accept_write`
predicate); mount wires an `observeEvent` on that input. A read-only
reactive's write is dropped, and the force-send-on-no-op loop (scoped
per-binding via `write_targets = key`) echoes the canonical value back as a
`target="widget"` `irid-attr`, snapping the library state. A bound prop is
not *also* handled — to react to its change, observe the reactive or pass a
`reactiveProxy`.

**Cost:** latent snap-back machinery on every callable prop even if the JS
never pushes it. It never fires unless `setProp` is called — cheap, and it
buys full DOM↔widget symmetry with no per-prop two-way marker.

### JS-side API

`window.irid` exposes one public method, `defineWidget(name, factory)`,
where `factory` is `(el, props, sendEvent, setProp) -> { update, destroy }`.
The factory runs once per mount:

```js
irid.defineWidget("codemirror", function (el, props, sendEvent, setProp) {
  // el:        container DOM element (already attached)
  // props:     merged object — all props, callable and constant alike
  // sendEvent: sendEvent(event, payload) — push a notification
  // setProp:   setProp(key, value)       — push a two-way prop's new value
  var view = new EditorView({ /* ... */ });
  return {
    update: function (values) {               // batch in (server -> client)
      // `values` is a {attr -> value} map carrying every prop that
      // changed in one flush (one or more keys). Apply each present key;
      // fold them into one library transaction where possible.
      if ("content" in values && values.content !== view.state.doc.toString()) {
        view.dispatch({ /* ... */ });
      }
      // keys the widget can't or won't live-update have no branch —
      // they're silently ignored
    },
    destroy: function () { view.destroy(); }
  };
});
```

Contract notes:
- `props` arrives as a single merged object; callable-vs-constant on
  the R side is invisible here — the distinction shows up only in
  whether subsequent `irid-attr target="widget"` messages arrive.
- `update(values)` receives a `{attr -> value}` map, never a single
  `(key, value)` pair — even a one-prop change arrives as a one-entry
  map. Multiple props that changed in the same server flush arrive
  coalesced in one call (see [Per-flush batching](#per-flush-update-batching)),
  so the hook handles `Object.keys(values)` uniformly (independent
  `if ("k" in values)` checks, not an `else if` chain). It fires only
  for keys that were callable on the R side, and must be idempotent
  (most updates round-trip the value the widget just pushed via
  `setProp`).
- `setProp(key, value)` is the client → server half of a two-way prop;
  `sendEvent(event, payload)` pushes a notification. Both are silent
  no-ops when no R subscriber exists, so the widget can wire them
  unconditionally.
- `destroy` runs before the container is detached. The widget should
  tear down anything that isn't pure DOM under `el` (timers,
  ResizeObservers, web sockets, ...); DOM children of `el` will be
  GC'd with detachment.

### Lifecycle and dependencies

The widget's R-side observers (per callable prop: one server→client
binding plus one client→server write-back; one per event) are owned by
the enclosing mount; `destroy()` on the mount tears them down. Client-side, `detachRange` (used by `irid-swap` and
`irid-mutate`) walks the removed fragment for `[data-irid-widget]`
elements and calls each widget's `destroy()` before `Shiny.unbindAll`.
No `irid-widget-destroy` message — the teardown is purely client-driven
so it still happens if the server crashes between observer teardown
and the swap.

Widget identity is tied to the container's DOM element identity. **Survives:**
`Each` keyed reorders (insertBefore preserves identity), in-place state
updates, ancestor attr changes. **Does not survive:** `When` / `Match`
branch flips, `Each` shape-change rebuilds, removes — those rebuild the
widget fresh, matching how `<input>` focus/scroll/selection state
behaves in the same situations.

Widget deps ride a single channel — the `irid-widget-init` message —
so both top-level mounts and dynamically-mounted widgets (inside
`When` / `Each` / `Match`) follow one code path. UI-attached deps are
auto-registered as Shiny static resources, but custom-message deps are
not, so `register_widget_dep(dep)` runs before each init: it resolves
`package`-relative `src$file` to an absolute path and routes file-backed
deps through `shiny::createWebDependency()` (which calls
`addResourcePath` and rewrites `src` to an href). href-only deps and
head-only deps pass through unchanged. `Shiny.renderDependencies`
dedups by name across the session, so re-firing `irid-widget-init` on
a remount is a no-op for the deps step.

### Force-send is per-binding

The event observer's force-send-on-no-op loop in `mount.R` only echoes
bindings whose `attr` is in the firing event's declared write targets
(`ev$write_targets`). The two synthesized write-backs — the DOM autobind
factory (`make_autobind_handler`) and the widget two-way-prop factory
(`make_widget_writeback`) — attach the target attr to the returned handler
as an `irid_write_targets` attribute, which `process_tags` lifts onto the
event row. **Hand-rolled handlers** (a wrapper's own `function(e) {…}`, or
any explicit `on*`) declare no targets and skip force-send entirely —
they're responsible for echo correctness themselves, and the natural
binding observer fires when the reactiveVal changes.

Without this scoping, an event whose handler doesn't write a particular
binding's reactiveVal would still cause that binding's current value to
be force-sent. If the binding's write was debounced and hadn't delivered
yet, the server's stale reactiveVal would be echoed back and clobber
in-flight client state — concretely, the CodeMirror demo's
`cursor-changed` event firing during typing would force-send `content`,
overwriting the user's typed characters with the server's pre-typing
value. Per-binding scoping eliminates this entire class of cross-binding
clobber.

### Per-flush update batching

Multiple bound props on one widget updating in the same Shiny flush are
coalesced into a **single** `irid-attr target="widget"` message carrying a
`values: {attr -> value}` map, delivered as one `update(values)` call.
Without this, each binding observer would send its own `irid-attr`; the
messages race on the wire and, for atomic-render libraries (Plotly,
Mapbox) where every message triggers a full redraw, two messages mean
two redraws and a visible flash.

Server side, `irid_queue_widget_attr` ([mount.R](R/mount.R)) appends each
`(attr, value)` to a per-widget pending map on
`session$userData$irid_widget_pending` instead of sending immediately; a
one-shot `session$onFlushed` handler drains every widget's map at flush
end. Both widget send sites route through it — the binding observers and
the event force-send-on-no-op echo — so they coalesce together within a
flush. DOM and text targets are unaffected (no analogous race; each DOM
attribute write is its own concern). The batch sequence is the highest
contributed by any binding in the flush (or absent for a purely
programmatic update); the universal stale-echo gate compares it exactly
as before.

Batching is **intra-flush only**: a prop updating in one flush and
another in a later flush still produce two messages (delaying delivery
would fight Shiny's reactive model). For libraries with incremental
update primitives (CodeMirror's separate `view.dispatch()` calls) the
distinction is invisible; the win is for atomic-render libraries, where a
coordinated same-flush multi-write now redraws once. Design rationale and
non-goals in
[dev/widget-batched-updates-design.md](dev/widget-batched-updates-design.md).

## Remaining Work

### `Portal` (planned)

Not yet implemented. Would render content into a different DOM target. Needs
`process_tags` handling and client-side support.

### `Catch` (planned)

Not yet implemented. Would provide error boundaries: if any `observe()` inside
the content tree errors, tear it down and render a fallback.

### Reactive child validation

Reactive children should return text only. Currently no validation — non-text
returns silently produce unexpected output.

### Client-side event filtering (planned)

Add a `filter` field to `irid_dom_opts()` that accepts a JS expression
string. The expression is evaluated client-side with the DOM event object
as `e` — if falsy, the event is never sent to the server (zero
round-trips). This avoids flooding the server with events the handler
doesn't care about (e.g. `onKeyDown` that only handles Enter). Deferred to
a follow-up; `irid_dom_opts` is built extensible so adding `filter` is
additive.

An `irid_key_filter()` helper would generate the JS expression for common
key matching:

```r
tags$input(
  value = field,
  onKeyDown = irid_wire(
    \(e) submit(),
    dom_opts = irid_dom_opts(filter = irid_key_filter("Enter"))
  )
)
```

Once `filter` is available, the todo example's `onKeyDown = \(event) if (event$key == "Enter") add_todo()` can be restored. It was removed in the interim because without client-side filtering, every keydown is sent to the server — which, combined with the missing event queue ordering (see `dev/client-event-queue-design.md`), causes Enter to race ahead of the pending `onInput` debounce and submit an incomplete value.

### Testing

See [TESTING.md](TESTING.md) for the full test plan.
