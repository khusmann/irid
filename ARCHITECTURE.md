# Architecture

## File Layout

```
R/
  app.R           iridApp, iridOutput, renderIrid
  primitives.R    When, Each, Match/Case/Default, Output
  event.R         wire carrier; wire_immediate/throttle/debounce timing
                  shapes; wire_dom_opts; merge.irid_wire
  process_tags.R  Tag tree walker — extracts reactive bindings, events, control flows, widgets
  mount.R         Mounts processed tags into a Shiny session (observers, lifecycle)
  store.R         reactiveStore — hierarchical reactive state container
  mini_store.R    make_mini_store / make_slot_accessor / is_record — per-item / per-case projections used by Each and Match
  scope.R         make_scope — per-item / per-case lifetime container; feature-detects shiny#4372 scoped teardown
  proxy.R         reactiveProxy — callable built from a reader and optional writer
  widget.R        IridWidget (two-way props)
  irid-package.R Package-level imports

inst/js/
  irid.js        Built client runtime — esbuild bundle of srcts/src/core
                 (+ irid.js.map). Generated; edit the TS source, not this.

inst/widgets/<name>/
  <name>-irid.js   Built per-widget factory — esbuild bundle of
                   srcts/src/widgets/<name> (+ .map). Generated. (One dir per
                   shipped widget; user widgets live in user packages.)

srcts/             TypeScript source for the client — the single source vendored
                   into inst/ (eventually shared with a Python server). Built with
                   esbuild, typechecked with tsc, unit-tested with vitest; see
                   TESTING.md.
  src/protocol.ts        Typed wire protocol + public client API (type-only)
  src/core/*             core runtime (seq, payload, anchors, ratelimit, stale,
                         widgets, handlers, index) -> inst/js/irid.js
  src/widgets/plotly/*   plotly factory (pure + index) -> plotly-irid.js

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
  plotly.R              Reactive plotly chart via PlotlyOutput — named state
                        args (ranges/dragmode/visibility), snap-back, discrete
                        callbacks, onRelayout escape hatch, and identity-based
                        selection (selected_points via a translating
                        reactiveProxy keyed on names, surviving filtering)
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
  should be inserted. Per-slot config carried by `wire` (timing,
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
    stripped by the HTML parser. The binding's return is validated at
    mount (`coerce_text_child`): it must be a single text value (length-1
    atomic, coerced to character) or `NULL` — a returned tag, list, or
    multi-element vector errors, since the client coerces with
    `String(val)` and would otherwise render garbage (`"[object Object]"`).
    Wrap reactive *tags* in a control-flow primitive (`When`/`Match`/`Each`)
    rather than returning them as text.
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
  a config-only event (an `wire` with `dom_opts` but no subject) — the
  client attaches a listener for the DOM flags but never round-trips.
- **`control_flows`** — List of `{type, id, ...}` for each `When`, `Each`,
  or `Match` node.
- **`shiny_outputs`** — List of `{id, render_call}` for each `Output` node.
- **`widget_inits`** — List of `{id, name, prop_fns, static_props, deps}`
  for each `IridWidget` node. `prop_fns` is the named list of callable
  props (read with `isolate(fn())` at mount-time to seed the init
  payload); `static_props` is the named list of non-callable values
  shipped verbatim. See the *Widgets* section below.

**htmltools render hooks.** Before inspecting any node, the walker runs that
node's own deferred render machinery (`resolve_render_hooks`): a
`shiny.tag.function` is called, and a `shiny.tag` carrying `.renderHooks` has
its hooks run one level at a time. This materializes structure that
bslib/htmltools build only at render time — `layout_sidebar()`'s
`bslib-sidebar-layout` grid, `card()`'s fill plumbing — so the walker rebuilds
the *resolved* tree rather than silently dropping the wrapper. Unlike
`htmltools::as.tags()`, resolution is one level deep, not recursive: the walk
descends into children itself and resolves each as it arrives, which is what
lets irid's own children (reactive functions, `irid_output`, `irid_widget`,
control-flow nodes — none of which carry render hooks) survive intact. A
side-effect of resolving hooks is that a tag may end up with duplicate `class`
attributes (htmltools renders these space-joined; bslib stacks
`bslib-sidebar-layout` and `html-fill-item` this way), so the walker preserves
duplicate attribute names positionally rather than collapsing them to the last
value.

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

**Per-slot config (`wire`).** Timing, backpressure, and DOM listener
options ride the slot they configure. A bare callable (`onClick = \() …`,
`value = rv`) is sugar for `wire(callable)` with default config;
`wire(subject, timing, coalesce, dom_opts)` tunes it. The timing shapes
(`wire_immediate()`, `wire_throttle(ms, leading)`, `wire_debounce(ms)`) are
pure — they carry only mode-specific fields. `coalesce` is universal so it
lives on the carrier; when `NULL` it derives from the mode (`immediate →
FALSE`, rate-limited → `TRUE`). When a wire carries no `timing`, the
per-event default applies, keyed on the DOM event name: `input` →
`wire_debounce(200)`, the high-frequency continuous streams (`mousemove`,
`pointermove`, `touchmove`, `drag`, `dragover`, `scroll`, `wheel`,
`resize`) → `wire_throttle(100)` (whose derived `coalesce = TRUE` gates the
stream on server-idle), everything else → `wire_immediate()`. DOM listener
flags (`prevent_default`, `stop_propagation`, `capture`, `passive`) bundle
into `wire_dom_opts()` inside the wire; each defaults to `FALSE`.

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

## Reactive State: `reactiveStore`

`reactiveStore` (see `store.R`) is the hierarchical state container. Its
construction/read/write API is documented in the `reactiveStore` roxygen;
the architectural model is:

**Leaves are the source of truth; branches are stateless.** A bare named
list (length > 0) becomes a navigable branch node; everything else becomes a
plain `reactiveVal` leaf. Every node is callable (`node()` reads,
`node(value)` writes), but the distinction is internal:

- **Leaves** hold a `reactiveVal`. Reads and writes go through it directly.
- **Branches** are plain functions with no state of their own. A branch
  *read* calls each child and assembles the result — callers subscribe
  directly to the leaf `reactiveVal`s they touch, never to the branch. A
  branch *write* validates the incoming keys (unknown or missing keys both
  error — branch writes replace) and fans out synchronously to each child's
  write, recursing until every affected leaf `reactiveVal` is set.

```
Write branch → fans out to children → fans out to leaves (reactiveVal)
Read leaf    → reactiveVal
Read branch  → calls children → subscribes to their reactiveVals
```

**Why there is no circular invalidation:** a branch owns no state, so a
branch write touches only leaves — it never invalidates the branch's own
read path. Leaf `reactiveVal` identity is stable across branch writes
(leaves are written, never replaced), so a captured leaf reference
(`name <- state$user$name`) stays valid. This is the same acyclic
leaf-owns-state model that `make_mini_store` projects per-item for `Each`
and per-case for `Match`.

Branches also satisfy the standard R introspection generics (`names`,
`length`, `print`, `str`) and integer `[[`, so `lapply`/`purrr::imap`
iterate a branch directly, yielding child node callables (not resolved
values) so auto-bind works unchanged.

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
reactives and observers. `make_scope` **feature-detects**
[shiny#4372](https://github.com/rstudio/shiny/pull/4372) at runtime (on
`session$onDestroy`/`session$destroy`): on a shiny carrying it, the scope is
a child created via `session$makeScope(id)`, and reactives constructed under
its reactive domain (`with_scope`) auto-register a weak destroy handle, so
`scope$destroy()` reclaims observers **and** `reactiveVal`s in one cascade;
otherwise it falls back to a thin manual observer tracker (today's behavior
on any pre-#4372 shiny, including current CRAN). Every site that depends on
the seam is tagged `# shiny#4372:`.

Only the per-item / per-case **reactives** (mini-store and slot-accessor
leaves, the keyed `pos_rv`) and the **component-body evaluation** run under
the child domain (via `with_scope`). The inner `irid_mount_processed` call
deliberately stays on the **outer `session`**, not the child: `makeScope` is
a Shiny *module* scope that namespaces input/output IDs through `NS()`, which
would mangle irid's globally-unique element IDs that outputs and events bind
to by raw name. The mount's own binding/event observers are torn down
explicitly by `mount$destroy()`, so they never needed scoping — only the
leaves (which have no explicit destroy) did.

**Reactive-leak — resolved on a shiny#4372 runtime, present otherwise.** On
the fallback path, `scope$destroy()` tears down the observers it tracks but
cannot tear down the `reactiveVal`s held inside mini-store leaves and slot
accessors — pre-#4372 Shiny exposes no public API for destroying a
`reactiveVal` — so each unmounted `Each` item / `Match` case leaks its leaves
into the session's reactive graph. The leak is bounded per-session (it resets
when the session ends), harmless for short-lived sessions, but grows under
churn (a dashboard adding/removing rows). On a shiny#4372 runtime this is
fully reclaimed automatically: the leaves are constructed under the child
scope's domain, and `scope$destroy()` (→ `child$destroy()`) destroys them
along with the observers — no irid change required at upgrade time. A
destroyed leaf *throws* on access (it is actively destroyed, not lazily
GC'd), which is why teardown order is strictly mount → scope.

The same seam closes a second gap on a shiny#4372 runtime: **user**-created
observers. A bare `observe()` / `observeEvent()` written inside a component
body (e.g. an analytics tick in an `Each` item callback) would otherwise
attach to the session domain and keep firing after the item unmounts. Because
`with_scope` evaluates the component body under the child scope's domain,
those user observers auto-register against it and are torn down with the
item — no irid-specific scoping primitive needed.

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
`irid-attr`, `irid-swap`, `irid-mutate`, `irid-events`,
`irid-widget-init`, and `irid-ready`.

### `irid-attr`

```js
// target = "dom" — DOM property/attribute write. `sequence`+`channel` gate the
// echo against the channel that produced it (omitted for programmatic writes).
{id: "irid-3", target: "dom",  attr: "value", value: "hello",
 sequence: 12, channel: "irid_ev_irid-3_input"}

// target = "text" — text replacement in a comment-anchor range
{id: "irid-5", target: "text", value: "Count: 42"}

// target = "widget" — route a coalesced batch to a widget's update() hook.
// `values` is always a {attr -> value} map (one or more keys), built by
// coalescing every widget binding that fired in the same server flush.
// `value_meta` carries the per-key {seq, channel} for the stale-echo gate (only
// for keys that came from a client write; programmatic keys are omitted).
{id: "irid-7", target: "widget",
 values: {content: "...", cursor: {line: 1, ch: 1}},
 value_meta: {content: {seq: 12, channel: "irid_prop_irid-7_content"}}}
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
library-specific. The per-key stale-echo gate (via `value_meta`) drops any
stale key from the batch before the hook runs, so the hook never sees an
out-of-order value and doesn't need a sequence argument. See [Widgets](#widgets)
for the per-flush batching that builds `values`.

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
    kind: null,            // "prop" / "event" for widget channels; null for DOM
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
`clientOnly` entry (a config-only `wire` with `dom_opts` but no
handler) attaches a bare listener that applies the DOM flags and never
sends — no managed state, no round-trip. If `source = "widget"`, the
listener-attach step is skipped; the entry is also indexed in
`widgetStreams` under `{kind}:{id}:{event}`, and the widget JS pushes payloads
through `irid.sendWidgetEvent(id, event, payload)` / `setProp`, which resolve
their stream through that index. The index (rather than rebuilding the inputId
on the client) is what makes widget channels work under Shiny modules, where
the namespaced `inputId` is unknowable to a widget factory.

**Per-channel sequencing.** Every outbound send bumps a counter keyed by its
`inputId` (`sequences[channel]`), and each echo carries the `channel` (and seq)
it should be gated against. A channel is one client→server stream — a DOM
event, a widget event, or a widget prop write-back — so a sibling channel's send
can never gate another channel's echo. This matters for widgets, where one
element multiplexes many props/events: a box-select firing both
`setProp("selected_ids")` and a `relayout` notification, or a box-zoom writing
both `xaxis_range` and `yaxis_range`, no longer cross-gate. See
[Controlled Input: Optimistic Updates](#controlled-input-optimistic-updates).

When `coalesce` is true, the rate limiter also gates on server idle state
(via `Shiny.shinyapp.$idleTimeout`), so events never queue faster than
the server can process them.

#### Per-element ordering queue

Each `(element, event)` stream has its own rate-limit timer, so without
coordination an immediate event can overtake a still-debouncing one on the
same element and reach the server first. The canonical bug: a text input's
`value` autobind (debounced `input`, 200ms) plus an `onKeyDown` Enter handler
(immediate) that reads the bound value — pressing Enter right after typing
sends the keydown before the `input` flush, so the server acts on a stale
value.

To fix this each element gets a FIFO queue of *pending streams*. A stream
**joins** the moment it first buffers a payload (claim order). When any stream
becomes ready to send, `drainQueue` walks the queue head-first: a ready head
sends; a not-ready head that has a *later* ready stream behind it is
**preemptively flushed** (its timer cancelled, its buffered payload sent now),
then the later stream sends. Cutting a debounce short this way is correct — a
later event on the same element is exactly the signal that the user paused. A
slot claimed with no buffered payload is dropped, not sent empty.

Ordering beats backpressure: a preemptive flush sends even when the stream
would otherwise gate on `serverBusy`, while a stream's own steady-state sends
still respect `coalesce`. This relies on Shiny processing back-to-back
event-priority inputs in send order — each lands in its own flush, so the
later handler observes the earlier handler's reactive writes (verified against
Shiny 1.7.4; re-confirm on bump). The queue is per-element, not global, so
unrelated inputs never block each other.

### `irid-widget-init`

```js
{
  id:    "irid-7",
  name:  "codemirror",
  props: { content: "...", language: "r", theme: "dracula" }
}
```

Sent after the swap/mutate that introduces the widget's container into
the DOM. The message carries **no deps** — a widget's `<script>` / `<link>`
assets are delivered by `insertUI` at mount time (see [Lifecycle and
dependencies](#lifecycle-and-dependencies)), not this side channel. The
client:

1. Looks up the factory registered under `msg.name`. If none is
   registered yet (the insert hasn't delivered the factory script yet),
   buffers `{id, props}` under `pendingInits[name]` and drains it when
   `irid.defineWidget(name, ...)` eventually lands. (This handles the
   *factory-not-registered* race; the *library-global-not-loaded* race is
   the factory's own concern — see below.)
2. Once the factory is available, `mountWidget` reserves the id
   synchronously (so a duplicate init is idempotent and an `irid-attr`
   arriving mid-construction buffers rather than dropping), then calls
   `factory(el, props, sendEvent, setProp)`. A factory returns its
   `{update, destroy}` handle directly **or a Promise of it** (an async
   factory — see the JS-side API). irid awaits the result, then
   *commits*: stores the handle and flushes any buffered `update`. If the
   widget was torn down while an async factory was still constructing,
   the resolved handle is **disposed** (its `destroy` runs) instead of
   adopted, so no detached zombie survives. The init message is
   idempotent — a duplicate for an already-mounted id is dropped.

### `irid-ready`

```js
{id: "myOutput"}  // output name (renderIrid), or {} for a top-level iridApp mount
```

Signals that a mount is fully wired. The server (`irid_send_ready` in `R/app.R`)
sends it from the mount's `onFlushed`, i.e. **after** the flush in which every
control-flow body (`When`/`Each`/`Match`) has mounted and sent its own
`irid-events`. Because WebSocket messages are ordered and an event's
`observeEvent` is registered *before* its `irid-events` within
`irid_mount_processed`, a client that has seen `irid-ready` has every listener
attached *and* every server observer registered.

The handler surfaces it two ways:

- A public **`irid:ready` DOM event** dispatched on `document`, with
  `detail.id` = the output name (`renderIrid`/`iridOutput`) or `null`
  (`iridApp`). This is the lifecycle hook app authors use to run JS once the UI
  is interactive (focus an input, hide a loading splash, start a tour). It fires
  once per mount, so a multi-output page emits one per output.
- The **`window.__iridReady`** flag (set `true` on the first event) as the
  escape hatch for a listener attached too late to catch the event:
  `if (window.__iridReady) init(); else document.addEventListener("irid:ready", init)`.

This also closes a harness race: when `Page.navigate` returns the page is loaded
but not yet interactive (Shiny connects asynchronously and irid wires listeners
on the initial flush), so a first interaction dispatched too early can be
silently dropped. `e2e_app()` waits on `window.__iridReady` before handing back
the handle (see `helper-e2e.R`).

## Controlled Input: Optimistic Updates

When a user types into a focused input, the server echoes the value back through
the reactive binding. Without care, this echo can cause cursor jumping or
overwrite characters the user typed while the server was processing. Conversely,
programmatic updates (e.g. clearing an input after form submission) must always
apply, even while the element is focused.

**Per-channel sequence numbers** solve this. Each event payload includes an
incrementing `__irid_seq`, counted PER CHANNEL on the client (`sequences[channel]`,
keyed by the `inputId` the payload is sent on). A *channel* is one client→server
stream from an element: a DOM event, a widget event, or a widget prop write-back.
The R event observer records, for each binding attr the event declares it writes
(`write_targets`), the `{seq, channel}` a binding observer should stamp on its
echo — stored on `session$userData$irid_current_sequence` keyed by
`[[source_id]][[attr]]`, cleared via `session$onFlushed`. Binding observers stamp
both `sequence` and `channel`; the echo gate compares the echo's `sequence`
against `sequences[channel]`. On the client, `irid-attr` for `value` on a focused
element decides:

- **Stale echo** (sequence < the channel's latest sent) → skip.
- **Current echo, same value** (not stale, `el.value === msg.value`)
  → no-op skip (avoids cursor position reset).
- **Server transform** (not stale, different value) → apply (e.g.
  server uppercases input).
- **Programmatic update** (no sequence/channel) → always apply.

Keying by channel (not by element) is what lets a widget multiplex many
props/events through one element without a sibling channel's send gating another
channel's echo. A widget batch carries the gate per key (`value_meta:
{key -> {seq, channel}}`) since one batch can coalesce props from different
channels (e.g. `xaxis_range` + `yaxis_range` from a box zoom).

Key design points:

- **`onFlushed` for cleanup.** The map is stored as a plain (non-reactive)
  session variable so binding observers can read it without creating a reactive
  dependency. `session$onFlushed(once = TRUE)` clears it after the entire reactive
  chain settles — derived reactives and chained observers all see the entry
  within the same flush, but the next flush starts clean.

- **Gating is for irid-managed bindings only.** Only events with declared
  `write_targets` — autobind `value`/`checked`, `reactiveProxy` writes, widget
  two-way props — record sequence entries. A hand-rolled `on*` handler (opaque
  closure, no declared target) records nothing, so a binding it incidentally
  drives echoes ungated (applied as programmatic). This keeps the seq-stamp path
  consistent with the already-`write_targets`-scoped force-send, and the
  one-channel-per-event rule already steers controlled values onto the managed
  autobind path.

- **Cross-element updates.** Entries are keyed by source element id, so a binding
  on a *different* element finds no entry and omits the sequence. If a button
  click's handler clears a text input, the text input's binding is treated as
  programmatic and applies.

- **Sibling channels in one flush.** Two events on the same element in one flush
  write DISJOINT keys (each channel owns its `write_targets`), so neither steals
  the other's entry — each echo carries its own channel's seq.

- **`__irid_seq` is excluded** from the `event_obj` passed to user handlers, so
  it is an internal-only field.

- **Force-send on no-op.** After running the user's event handler, the event
  observer reads the source element's bindings whose attr is in `write_targets`
  with `isolate()` and sends `irid-attr` messages stamped with this event's
  sequence and channel. This covers the case where the handler sets a
  `reactiveVal` to the same value it already holds (a no-op that doesn't
  invalidate the binding observer). Without the force-send, the client would
  receive no echo and could not apply a server transform. For example, a handler
  that truncates `text(substr(event$value, 1, 10))` when `text()` is already 10
  characters — the reactive doesn't change, but the client still needs the
  truncated value to replace what the user typed. When the reactive *does*
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
event payloads, the optimistic-update sequence counter, the `wire`
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
API — pass a constant, no observer). Wrapping a prop in `wire` only
*tunes* its write-back timing; it never enables or disables two-way.

`events` carries genuine notifications that correspond to *no* prop. Keys
are lowercase kebab-case (web `CustomEvent` convention — `cursor-changed`,
`relayout`). No `on` prefix because there's no DOM event mediating — the
widget JS chooses what to fire via `sendEvent()`. Each value is a handler
or an `wire` (to tune timing); `NULL` (or a `merge()` resolving to a
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
where `factory` is `(el, props, sendEvent, setProp) -> { update, destroy }`
**or a Promise of that handle**. The factory runs once per mount:

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
  GC'd with detachment. Because an `async` factory's handle is committed
  *after* the await (and a teardown can race it), `destroy` must tolerate
  partially- or never-constructed state (guard on whatever the await was
  supposed to produce).

**Async construction (the load race, #26).** A factory may be `async` /
return a Promise, which is how a widget waits for something its
construction needs before building. irid awaits the return, **buffers**
any `update` that arrives during the wait (coalesced, delivered once the
handle commits), and **disposes** the handle if the widget was torn down
mid-construction. The motivating case is a **script-tag library global**:
the `insertUI` dep delivery injects the dep `<script>` but its execution is
not awaited — and the element's `load` event is unusable because Shiny injects
through jQuery, which runs `<script src>` via an AJAX `globalEval` (no
element load fires). So the factory polls for the global itself:

```js
irid.defineWidget("plotly", async function (el, props, sendEvent, setProp) {
  await whenPlotly();                 // poll until window.Plotly exists
  var graph = Plotly.react(el, /* ... */);
  return { update, destroy };
});
```

The poll lives in the widget, not the substrate — "wait for `window.Plotly`"
is a Plotly fact, and the transport stays generic (it only knows "the
factory may be async"). The same shape covers the other async cases without
any extra API: `await import("...")` for an ESM widget, `await engine.ready()`
for a WASM library, `await fetch(...)` for construction-time config. A widget
whose deps are already on the page (e.g. an ESM widget that imports at module
load, like the CodeMirror example) just returns its handle synchronously — no
`async`, identical to before.

This was chosen over the alternatives — awaiting the script `load` event,
self-injecting `<script>` tags to obtain a real load event, or a substrate-level
readiness gate keyed on a declared predicate — because each of those bets on a
Shiny dependency-injection internal, whereas polling for the global waits on the
dependency's *outcome* (the global appearing), which is agnostic to *how* Shiny
loads it. That distinction is not academic: the load-event approach is not merely
fragile but already broken, because Shiny's jQuery-`globalEval` injection path
(observed on Shiny 1.7.4 / jQuery 3.6.0) fires no element `load` at all. The
async-factory contract does not depend on that behavior — only a widget's own
poll does, and a poll survives any loading mechanism. irid deliberately ships no
`waitFor`/poll helper: the wait is library-specific (a CDN/ESM widget instead
`await`s its own `import`), so it stays in the widget, holding irid's public
surface to the contract alone.

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

**Deps travel one way: `insertUI` at mount time.** Every widget's deps are
delivered through Shiny's native render pipeline via one
`insertUI("body", "beforeEnd", tagList(deps))` per mount
(`deliver_widget_deps` in [mount.R](R/mount.R)), deduped by dependency name
on `session$userData`. Shiny's `processDeps` resolves and serves
`package`/file-backed deps as part of the insert (no manual registration);
the `irid-widget-init` message carries no deps.

This is the only delivery path shinylive serves: shinylive serves mid-session
resource paths **only** on the native pipeline (initial UI, `renderUI`,
outputs, `insertUI`); a bare `Shiny.renderDependencies` off a custom message
404s there. A spike confirmed `insertUI` serves a file-backed dep under
shinylive (the custom-message control 404s) — pinned to **shinylive web
assets 0.9.1**, re-confirm on a bump.

**Closes #34, uniformly.** `irid_mount_processed` is the chokepoint every
nested control-flow mount calls, so a widget appearing *only* inside
`When`/`Each`/`Match` delivers its deps the moment it mounts — no
static-preload workaround. Same path for every entry mode (`iridApp`,
`renderIrid`) and nesting depth.

**Ordering is a non-issue.** Deps arrive on the first flush — slightly later
than a `<head>` page-attach, but tolerated (the async-factory poll and
`pendingInits` cover it). The factory script always arrives *after* `irid.js`
(which stays in the initial `<head>` as `irid_dependency()`), so `window.irid`
always exists and factories call `irid.defineWidget` directly — no
`window.iridPendingFactories` parking.

> History: an earlier iteration used a hidden `renderUI` sink (`uiOutput` +
> `reactiveVal` + `outputOptions(suspendWhenHidden = FALSE)`); once the spike
> confirmed `insertUI` serves under shinylive, it collapsed to the one-liner
> above.

**Rejected: page-attaching static deps for faster load** (deps in the initial
`<head>` instead of one flush later). A spike (real Shiny `<head>`, 2026-06)
showed it can't be made clean: a page-attached factory script renders
*before* `irid.js`, and there's no lever to reorder them — `htmlDependency()`
has no priority, htmltools puts descendant-attached deps before root-attached
ones (`irid_dependency()` is root), and Shiny injects deps above `tags$head`
content (so an inline stub loses too). It would therefore require resurrecting
the `iridPendingFactories` parking this design deletes — and still wouldn't
reach control-flow-only widgets (#34). If the first-flush delay is ever
measured to matter, the only clean variant is page-attaching the heavy
*library* (ordering-agnostic) while delivering the *factory* script via
`insertUI` — needing an `IridWidget` API to mark which dep registers the
factory.

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
coordinated same-flush multi-write now redraws once. Non-goals: cross-flush
batching (would fight Shiny's flush model), DOM/text-target batching (no
analogous race — each attribute write is its own concern), and generic
feedback-loop prevention (wrappers break loops with their library's idioms;
the stale-echo gate only handles transient sequencing).

### PlotlyOutput

`PlotlyOutput` ([plotly.R](R/plotly.R), JS in
[plotly-irid.js](inst/widgets/plotly/plotly-irid.js)) is a thin `IridWidget`
wrapper over plotly.js — the flagship shipped widget. It carries no custom
wire-protocol message and no PlotlyOutput-specific `process_tags` path; it maps
its surface onto the substrate above:

- **Spec → a JSON-string prop.** The user's `plot_ly()`/`ggplotly()` builder is a
  callable prop serialized with plotly's own `to_JSON` (`to_plotly_spec`); the JS
  `JSON.parse`s it and applies it with **`Plotly.react()`** — incremental, so a
  data change preserves the user's zoom/pan/selection via plotly `uirevision`
  (unlike the `{plotly}` htmlwidget, which destroys and recreates).
- **Named state args → two-way props.** Axis ranges, `dragmode`, `hovermode`,
  `selected_ids`, `trace_visibility` (and subplot axes `xaxis<n>_range`, …) are a
  *translation table*: the R side only validates the names; the JS factory holds
  the authoritative mirror mapping each name to a spec path, an `apply`/
  `applyDeferred`/`matchesCurrent`, and a source plotly event. NULL-initialized
  args are shipped explicitly (`__irid_state_keys`) because R list semantics drop
  a `NULL` from the init props object.
- **Discrete events → widget events** (`onClick`, `onHover`, legend, …); the raw
  `plotly_relayout` payload is an `onRelayout` escape hatch for fields outside the
  table.

**Self-echo guard.** `Plotly.react()` is silent (no `plotly_relayout`), but our
own `Plotly.relayout()`/`restyle()` for apply/snap-back/reset re-fire
`plotly_relayout` *synchronously, before the promise resolves*. An `applying`
flag, raised around every programmatic mutation and cleared in `.then()`, makes
the listener early-return — the exact guard that lets a rejecting `reactiveProxy`
snap the plot back (the binding force-send echoes the canonical value) without
looping. `matchesCurrent` is a secondary idempotence backstop.

**NULL is two acts.** A binding *already* `NULL` across a data `react()` stays
out of the merge (uirevision preserves the view); a binding *transitioning* to
`NULL` triggers `applyDeferred` — a targeted `relayout({autorange:true})` (or the
spec's range) that genuinely resets.

**Identity-keyed "which" props.** `selected_ids` keys on per-point plotly `ids`
and `trace_visibility` on trace `name` — not position — so both survive a data
change that renumbers/recomposes traces (a filter dropping a whole group). Each
validates its key is present on the built spec.

**Selection is two-layer.** A box/lasso drag writes *both* `layout.selections`
(the outline rectangle) and per-trace `data[*].selectedpoints` (the dimming).
`selected_ids` is the dimming layer; clearing or setting must drop the outline
**first** (`relayout({selections:null})`) then `restyle` the dimming, because
while a drag is active plotly owns `selectedpoints` and a bare restyle is a
silent no-op. `matchesCurrent` keeps a user's own fresh marquee from being wiped
by its echo.

**Wire-boundary coercion.** Shiny decodes client messages with
`simplifyVector = FALSE`, so a range arrives as `list(40, 200)` and a
`setProp(key, null)` as `NA`; `coerce_plotly_value` normalizes each field back to
its documented R shape (numeric ranges → numeric, but a date-axis range stays
character since plotly reports it as ISO strings; the keyed maps → character;
`NA`/`null` → `NULL`). `coerce_state_prop` `force()`s its captured name/callable so proxies
built in a construction loop don't all resolve to the last one.

## Testing

See [TESTING.md](TESTING.md) for the test-suite layout, naming conventions, and
how to run the unit and e2e tests. The behavior spec itself lives in the test
files under `tests/testthat/`.
