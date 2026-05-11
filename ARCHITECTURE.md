# Architecture

## File Layout

```
R/
  app.R           iridApp, iridOutput, renderIrid
  primitives.R    When, Each, Match/Case/Default, Output
  event.R         event_immediate, event_throttle, event_debounce
  process_tags.R  Tag tree walker — extracts reactive bindings, events, control flows
  mount.R         Mounts processed tags into a Shiny session (observers, lifecycle)
  store.R         reactiveStore — hierarchical reactive state container
  mini_store.R    make_mini_store / make_slot_accessor / is_record — per-item / per-case projections used by Each and Match
  scope.R         make_scope — per-item / per-case lifetime container; shim for shiny#4372 subdomain teardown
  proxy.R         reactiveProxy — callable built from a reader and optional writer
  irid-package.R Package-level imports

inst/js/
  irid.js        Client-side message handlers (vanilla JS, no build step)

examples/
  old_faithful.R       Old Faithful geyser histogram with PlotOutput
  composing.R          Two Counter instances showing closure-based isolation
  temperature.R        Bidirectional temperature converter (controlled inputs)
  todo.R               Todo app (Each positional, When, dynamic lists)
  optimistic_updates.R Controlled inputs with simulated server latency
  shiny_interop.R      irid components inside a standard Shiny module
  cards.R              Dynamic column cards (Each, keyed by column name)
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
  should be inserted. Element-level config (`.event`, `.prevent_default`)
  is stripped before HTML serialization.
- **`bindings`** — List of `{id, attr, fn}` for each reactive attribute.
- **`events`** — List of `{id, event, handler, mode, ms, leading, coalesce, prevent_default}`,
  one entry per `(id, DOM event)`. Auto-bind synthetic and explicit `on*`
  on the same DOM event are merged into one composed handler.
- **`control_flows`** — List of `{type, id, ...}` for each `When`, `Each`,
  or `Match` node.
- **`shiny_outputs`** — List of `{id, render_call}` for each `Output` node.

When a state-binding prop (`value`, `checked`) holds a callable, process_tags
emits both a binding (server → client read) and a synthetic event entry
(client → server write). The synthetic handler is arity-dispatched: 0-arg
callables get a no-op handler so the listener still fires and the
optimistic-update protocol echoes the current value back. 1-arg+ callables
receive the event field of the same name as the prop (`e$value` for `value`,
`e$checked` for `checked`) — irid stays close to the DOM IDL, so the prop
name and the event field name always match.

When the auto-bind synthetic event collides with an explicit `on*` handler
on the same DOM event (e.g. `value = rv` and `onInput = ...` on the same
`<input>`), process_tags merges the two into a single event entry whose
handler composes both source handlers. One DOM listener, one observer,
one force-send echo per event. **Auto-bind synthetic handlers always run
before explicit `on*` handlers**, so an explicit handler observes the
updated state and cosmetic attribute reordering can't change behavior;
within each tier, source-attribute order is preserved.

Event timing comes from the element-level `.event` prop. A single
`irid_event_config` applies to every event on the element; a named list
keyed by lowercase DOM event name overrides per event. With no covering
`.event`, the per-event default rule applies, keyed only on the DOM event
name: `input` → `event_debounce(200)`, everything else →
`event_immediate()`. The rule is the same whether the entry is an
auto-bind synthetic or an explicit `on*` handler, so adding `value = rv`
to an existing `onInput` doesn't silently shift its timing.
`.prevent_default` follows the same shape as `.event`: a logical scalar
broadcasts to every event entry; a named list keyed by lowercase DOM
event name overrides per event, with unmapped events defaulting to
`FALSE`.

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
([is_record][make_mini_store]), it is projected as a [mini-store][make_mini_store]
and passed to the case body, otherwise the bare callable is passed; the body
function is called and the result is mounted. Same-case value changes do not
remount — the active mini-store's internal observer auto-propagates value
changes to its leaves so only the bindings whose field actually changed
re-fire.

**Each** manages per-item mount handles and uses `irid-mutate` for granular DOM
mutations. Each item is bracketed by its own pair of comment anchors so the
client can insert, remove, and reorder individual children. The callback
receives a per-item callable plus an optional position accessor:

- **Record items** → per-item [mini-store][make_mini_store]. `item()` reads the
  whole record; `item(record)` writes it back; `item$field()` reads a leaf;
  `item$field(v)` is a synthetic setter that writes through the parent
  collection. Data flows one direction: parent → mini-store leaves → DOM,
  with synthetic setters routing writes back up. The reactive graph is
  acyclic — leaves never hold independent state.
- **Scalar items** → per-item [scalar slot accessor][make_slot_accessor]
  (a `reactiveProxy` over an internal `reactiveVal`). `item()` reads;
  `item(v)` writes back to the parent's slot.

The reconciliation strategy is selected by `by`:

- **Positional** (`by = NULL`, the default) — slot *i* is slot *i*. The list
  can grow or shrink at the end; in-place value changes propagate via each
  slot accessor's internal observer (no DOM work). Same-length value changes
  fire only the slots whose value actually changed.
- **Keyed** (`by = fn`) — items are tracked across reorders, adds, and
  removes by their `by(item)` key. Kept items have their existing
  mini-store / accessor reused (no remount, no new scope) and self-update
  via the propagating observer; new items are mounted; removed items are
  destroyed; reordered items have their DOM nodes moved via `irid-mutate`'s
  `order` mechanism.

The callback is arity-polymorphic — `\() body`, `\(item) body`, or
`\(item, pos) body`. `pos` is always a 0-arg reactive accessor for the
item's current 1-indexed slot: a constant signal under `by = NULL` (slot
number is the identity), live under `by = fn` (fires on reorder).

Each per-item / per-case mount creates its own `scope` (see
[make_scope][make_scope]) to bound the lifetime of the per-item / per-case
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

`irid.js` registers four Shiny custom message handlers:

### `irid-attr`

```js
{id: "irid-3", attr: "textContent", value: "Count: 42"}
```

Sets a DOM property or attribute. Special-cased properties: `value`, `disabled`,
`checked`, `textContent` are set as JS properties (not HTML attributes).
Skips the update if the target element has focus and the attribute is
`value` (optimistic update).

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
    mode: "throttle",
    ms: 100,
    leading: true,
    coalesce: true,
  },
];
```

For each entry, attaches a DOM event listener on the element. The listener reads
the element's `value` and sends it as a Shiny input via
`Shiny.setInputValue(inputId, {value, id}, {priority: "event"})`.

If `mode` is set, wraps the listener in a throttle or debounce. When `coalesce`
is true, the rate limiter also gates on server idle state (via
`Shiny.shinyapp.$idleTimeout`), so events never queue faster than the server can
process them.

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

Add a `filter` argument to the event-config constructors that accepts a JS
expression string. The expression is evaluated client-side with the DOM
event object as `e` — if falsy, the event is never sent to the server
(zero round-trips). This avoids flooding the server with events the
handler doesn't care about (e.g. `onKeyDown` that only handles Enter).

A `key_filter()` helper would generate the JS expression for common key
matching:

```r
tags$input(
  value = field,
  onKeyDown = \(e) submit(),
  .event = list(keydown = event_immediate(filter = key_filter("Enter")))
)
```

Once `filter` is available, the todo example's `onKeyDown = \(event) if (event$key == "Enter") add_todo()` can be restored. It was removed in the interim because without client-side filtering, every keydown is sent to the server — which, combined with the missing event queue ordering (see `dev/client-event-queue-design.md`), causes Enter to race ahead of the pending `onInput` debounce and submit an incomplete value.

### Testing

See [TESTING.md](TESTING.md) for the full test plan.
