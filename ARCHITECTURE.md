# Architecture

## File Layout

```
R/
  app.R           nacreApp, nacreOutput, renderNacre
  primitives.R    When, Each, Index, Match/Case/Default, Output
  event.R         event_immediate, event_throttle, event_debounce
  process_tags.R  Tag tree walker — extracts reactive bindings, events, control flows
  mount.R         Mounts processed tags into a Shiny session (observers, lifecycle)
  nacre-package.R Package-level imports

inst/js/
  nacre.js        Client-side message handlers (vanilla JS, no build step)

examples/
  old_faithful.R       Old Faithful geyser histogram with PlotOutput
  todo.R               Todo app (Each, Index, When, dynamic lists)
  temperature.R        Bidirectional temperature converter (controlled inputs)
  module.R             Shiny module integration
```

## Two-Phase Rendering

nacre splits rendering into two phases: **process** and **mount**.

### Phase 1: `process_tags`

Walks the tag tree recursively and produces:

- **`tag`** — A clean HTML tag tree with all functions removed. Reactive
  attributes are replaced by stable auto-generated element IDs. Control-flow
  nodes become `<div style="display:contents">` placeholders.
- **`bindings`** — List of `{id, attr, fn}` for each reactive attribute.
- **`events`** — List of `{id, event, handler, mode, ms, leading, coalesce}` for
  each event callback.
- **`control_flows`** — List of `{type, id, ...}` for each `When`, `Each`,
  `Index`, or `Match` node.
- **`shiny_outputs`** — List of `{id, render_call}` for each `Output` node.

Bare functions are wrapped with a default event mode: `onInput` uses
`event_debounce(ms = 200)` (since intermediate values during typing are
noise), all other events use `event_immediate()`. Explicit wrappers
(`event_immediate()`, `event_throttle()`, `event_debounce()`) override the
default.

The tag tree is now plain HTML that can be sent to the client. All reactive
wiring is deferred to mount.

### Phase 2: `nacre_mount_processed`

Takes the output of `process_tags` and a Shiny `session`, then wires up:

1. **Reactive bindings** — Each binding gets an `observe()` that sends
   `nacre-attr` messages when the reactive value changes.
2. **Event handlers** — Each event gets an `observeEvent()` on a namespaced
   input ID (`nacre_ev_{id}_{event}`). The handler is dispatched based on its
   formal argument count (0, 1, or 2 args). Event registration is sent to the
   client as a `nacre-events` message.
3. **Shiny outputs** — Each output's render call is assigned to
   `session$output[[id]]`.
4. **Control-flow nodes** — Each node gets an `observe()` that manages its
   lifecycle (see below).

Returns a mount handle with `$tag` (the processed HTML) and `$destroy()` (tears
down all observers).

## Control Flow Lifecycle

**When** and **Match** each manage a single `current_mount` — a mount handle from
a recursive `nacre_mount_processed` call. Both short-circuit: the observer
re-evaluates the condition on every reactive invalidation but only destroys and
recreates the branch when the active branch actually changes. This is critical
when wrapping `Each` or `Index` — without the short-circuit, any change to a
reactive dependency shared with the condition would destroy the inner mount and
lose per-item state. Match iterates cases to find the first truthy condition.

**Each** and **Index** manage per-item mount handles and use `nacre-mutate` for
granular DOM mutations. Each item/slot is wrapped in a
`<div style="display:contents">` with a stable ID so the client can insert,
remove, and reorder individual children.

The two primitives are symmetric: **Each** keys by identity (item is stable,
index moves), **Index** keys by position (index is stable, item moves).

**Each** — Like Solid's `For`. The callback receives each item as a **plain
value** and an optional index: `fn(item)` or `fn(item, i)` where `i` is a
`reactiveVal` that tracks the item's current position (updated on reorder). The
`by` argument extracts a comparable key from each item (defaults to `identity`,
must be unique). On list change, keys are diffed: kept items have their DOM nodes
reordered (no recreation), new items are mounted, removed items are destroyed.

**Index** — Like Solid's `Index`. The callback receives each item as a
**reactive accessor** (`reactiveVal`) and an optional index: `fn(item)` or
`fn(item, i)` where `i` is a fixed integer. If the length is stable, each slot's
`reactiveVal` is updated in place so existing observers fire with the new values
without DOM recreation. When the list grows, new slots are appended; when it
shrinks, trailing slots are destroyed.

## Client-Side Protocol

`nacre.js` registers four Shiny custom message handlers:

### `nacre-attr`

```js
{id: "nacre-3", attr: "textContent", value: "Count: 42"}
```

Sets a DOM property or attribute. Special-cased properties: `value`, `disabled`,
`checked`, `selected`, `textContent` are set as JS properties (not HTML
attributes). Skips the update if the target element has focus and the attribute
is `value` (optimistic update).

### `nacre-swap`

```js
{id: "nacre-5", html: "<li>new content</li>"}
```

Calls `Shiny.unbindAll` on the element, replaces `innerHTML`, then calls
`Shiny.bindAll` to initialize any Shiny outputs in the new content.

### `nacre-mutate`

```js
{
  id: "nacre-5",
  removes: ["nacre-7", "nacre-9"],
  inserts: ["<div id='nacre-12' ...>...</div>"],
  order: ["nacre-6", "nacre-12", "nacre-8"]
}
```

Performs granular child-node mutations on the container element. Used by `Each`
and `Index` instead of `nacre-swap` to avoid destroying and recreating all
children on every list change.

1. **Removes** — Calls `Shiny.unbindAll` on each child, then removes it from the
   DOM.
2. **Inserts** — Appends new HTML fragments as children of the container.
3. **Order** (optional) — Reorders children by calling `appendChild` in sequence,
   which moves existing DOM nodes without cloning.

After all mutations, `Shiny.bindAll` is deferred via `setTimeout(0)` to
initialize any new Shiny outputs.

### `nacre-events`

```js
[
  {
    id: "nacre-2",
    event: "input",
    inputId: "nacre_ev_nacre-2_input",
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
`__nacre_seq`. The R event observer stores it on
`session$userData$nacre_current_sequence` and registers `session$onFlushed` to
clear it after the flush completes. Binding observers attach the sequence to
`nacre-attr` messages when present. On the client, `nacre-attr` for `value` on a
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

- **`__nacre_seq` is excluded** from the `event_obj` passed to user handlers, so
  it is an internal-only field.

- **Force-send on no-op.** After running the user's event handler, the event
  observer reads all bindings for the source element with `isolate()` and sends
  `nacre-attr` messages tagged with the sequence. This covers the case where the
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

**Option:** `nacre.stale_timeout` — milliseconds to wait before showing the
indicator. Default `200`. Set to `NULL` to disable.

**Flow:**

1. The session entry points (`nacreApp` server, `renderNacre` `onFlushed`) send
   a `nacre-config` message with the timeout from `getOption("nacre.stale_timeout")`.
2. On the client, every `sendPayload` call starts a show timer (if not already
   running). It also cancels any pending clear, keeping the indicator up if a
   new event fires shortly after the server goes idle.
3. If `shiny:idle` fires before the show timer, the timer is reset.
4. If the show timer fires first, `nacre-stale` is added to `<html>`, which
   shows an animated progress bar fixed at the top of the viewport via
   `nacre.css`. The progress bar color is customizable with the
   `--nacre-stale-color` CSS variable (defaults to Bootstrap gray).
5. When `shiny:idle` fires, a debounced clear is scheduled (100ms). If
   `shiny:busy` fires before the clear executes (e.g. a reactive chain
   triggers a follow-up flush), the clear is cancelled. The indicator only
   removes once the server is truly idle for the full debounce window.

**Debug:** `nacre.debug.latency` (seconds) adds a `Sys.sleep` to every event
handler. The `optimistic_updates` example exposes this as a slider.

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

Add a `filter` argument to `event_immediate()`, `event_throttle()`, and
`event_debounce()` that accepts a JS expression string. The expression is
evaluated client-side with the DOM event object as `e` — if falsy, the event is
never sent to the server (zero round-trips). This avoids flooding the server
with events the handler doesn't care about (e.g. `onKeyDown` that only handles
Enter).

A `key_filter()` helper would generate the JS expression for common key
matching:

```r
onKeyDown = event_immediate(\(e) submit(), filter = key_filter("Enter"))
```

Once `filter` is available, the todo example's `onKeyDown = \(event) if (event$key == "Enter") add_todo()` can be restored. It was removed in the interim because without client-side filtering, every keydown is sent to the server — which, combined with the missing event queue ordering (see `dev/client-event-queue-design.md`), causes Enter to race ahead of the pending `onInput` debounce and submit an incomplete value.

### Testing

See [TESTING.md](TESTING.md) for the full test plan.
