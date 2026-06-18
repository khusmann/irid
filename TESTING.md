# Testing Plan

## `process_tags` extraction

Verify that `process_tags` correctly walks a tag tree and separates reactive
attributes, event handlers, control-flow nodes, and Shiny outputs from the
static HTML.

- [ ] Plain tag with no reactive attributes passes through unchanged
- [ ] `NULL` node returns `NULL`
- [ ] Reactive attribute is extracted into `$bindings` with correct `id`, `attr`, `fn`
- [ ] Event handler (`onInput`, `onClick`, etc.) is extracted into `$events`
- [ ] Event name conversion: `onInput` → `input`, `onClick` → `click` (strip `on`, lowercase)
- [ ] Bare function handlers follow the per-event default rule (`onInput` → debounce(200), everything else → immediate)
- [ ] `wire(subject, timing, coalesce, dom_opts)` on a slot supplies `mode`, `ms`, `leading`, `coalesce`, and the `dom_opts` flags to that event entry
- [ ] Element with existing `id` attribute keeps it (not overwritten by auto-ID)
- [ ] Element with both reactive attrs and events shares one ID
- [ ] Multiple event handlers on one element (e.g. both `onInput` and `onClick`)
- [ ] Reactive attributes are removed from the output tag (only static attrs remain)
- [ ] Event attributes are removed from the output tag
- [ ] Reactive text child becomes a `<span>` binding with `attr = "textContent"`
- [ ] `When` node produces a control-flow entry with `type = "when"`
- [ ] `Each` node produces a control-flow entry with `type = "each"` and `by`
- [ ] `Index` node produces a control-flow entry with `type = "index"`
- [ ] `Match`/`Case`/`Default` produces a control-flow entry with `type = "match"`
- [ ] Control-flow nodes emit a pair of `<!--irid:s:ID-->`/`<!--irid:e:ID-->`
      comment anchors in place of the node (no wrapper element)
- [ ] Anchor IDs match the `id` in the corresponding `$control_flows` entry
- [ ] `Output` node produces a `$shiny_outputs` entry
- [ ] `PlotOutput` / `TableOutput` produce correct render/output function pairs
- [ ] `DTOutput` errors when DT package is not installed
- [ ] Nested tags are walked recursively (children of children)
- [ ] `tagList` children are walked and class is preserved
- [ ] Counter is shared across recursive `process_tags` calls (via `counter` arg)
- [ ] Control-flow content is not recursively walked during process (deferred to mount)

## Observer lifecycle for control-flow primitives

Verify that control-flow nodes correctly create, destroy, and reuse child
mounts in response to reactive changes.

### Destroy / cleanup

- [ ] `$destroy()` on a mount handle tears down all observers
- [ ] When/Match: destroying the mount destroys the active branch's child mount
- [ ] Each: destroying the mount destroys all per-item child mounts
- [ ] Index: destroying the mount destroys all per-slot child mounts
- [ ] Nested control flows: destroy propagates recursively

### Empty list edge cases

- [ ] Each with empty initial list renders nothing
- [ ] Index with empty initial list renders nothing
- [ ] Each list going from non-empty to empty destroys all child mounts
- [ ] Index list going from non-empty to empty destroys all slots
- [ ] Each list going from empty to non-empty mounts new children
- [ ] Index list going from empty to non-empty creates new slots

### When

- [ ] Renders the `yes` branch when condition is `TRUE`
- [ ] Renders the `otherwise` branch when condition is `FALSE`
- [ ] Renders nothing when condition is `FALSE` and no `otherwise` provided
- [ ] Short-circuits: re-evaluating with same condition does not destroy/recreate
- [ ] Switching branches destroys the previous mount and creates a new one
- [ ] Inner reactive state survives when the condition re-evaluates but stays the same

### Each

- [ ] Renders one child per item in the list
- [ ] `by` function extracts unique keys; duplicate keys error
- [ ] Adding an item mounts a new child without destroying existing ones
- [ ] Removing an item destroys only that child's mount
- [ ] Reordering items reorders DOM nodes (no recreation)
- [ ] Kept items have their `index_rv` updated when position changes
- [ ] Callback receives item as plain value (not reactive)

### Index

- [ ] Renders one slot per item in the list
- [ ] Same-length update fires `reactiveVal` in place (no DOM recreation)
- [ ] Growing the list appends new slots
- [ ] Shrinking the list destroys trailing slots
- [ ] Callback receives item as `reactiveVal` accessor
- [ ] Fixed integer index arg does not change on reorder

### Match

- [ ] Renders the first case whose condition is `TRUE`
- [ ] Falls through to `Default` when no case matches
- [ ] Renders nothing when no case matches and no `Default`
- [ ] Short-circuits: same matching case does not recreate
- [ ] Switching cases destroys the previous mount

## Event handler dispatch

Verify that event observers correctly dispatch to handlers based on their
formal argument count, and that event data is properly cleaned.

- [ ] 0-arg handler: `handler()` is called with no arguments
- [ ] 1-arg handler: `handler(event)` receives the event object
- [ ] 2-arg handler: `handler(event, id)` receives event object and source element ID
- [ ] `NULL` values in event data are converted to `NA`
- [ ] `__irid_seq`, `id`, and `nonce` are excluded from the event object passed to handlers

## Rate-limiting metadata propagation

Verify that `wire_immediate`, `wire_throttle`, and `wire_debounce` metadata
(plus the carrier's resolved `coalesce`) is correctly propagated from R to
the client.

- [ ] `wire_immediate()` sends `mode = "immediate"`; `coalesce` derives to `FALSE`
- [ ] `wire_throttle()` sends `mode = "throttle"` with `ms`, `leading`; `coalesce` derives to `TRUE`
- [ ] `wire_debounce()` sends `mode = "debounce"` with `ms`; `coalesce` derives to `TRUE`
- [ ] An explicit `coalesce =` on `wire` overrides the mode-derived default
- [ ] `dom_opts$prevent_default = TRUE` is forwarded to the event entry on the client
- [ ] timing shapes (`irid_*()`) are pure structs (no `coalesce`, no handler argument)

## Auto-bind (state-binding props)

Verify that callable `value`/`checked` props produce both a read binding and
a write event entry, and that the corresponding DOM event fires the write
back through the callable. Auto-bind aligns to the DOM IDL: prop name and
event field name match (`value` ↔ `e$value`, `checked` ↔ `e$checked`).
`<select>` binds via `value` (its DOM IDL property) but writes back on
`change` rather than `input` — `change` is the canonical "user picked"
event for a select. Radios bind via `checked` per-element. (A `value` /
`checked` binding claims its event exclusively — an explicit `on*` for the
same event errors; see the one-channel checks below.)

### `process_tags` extraction

- [ ] `value = reactiveVal()` on text input produces both a binding (`attr = "value"`) and a synthetic `input` event entry with handler `\(e) val(e$value)`
- [ ] `value = reactiveVal()` on `<select>` produces both a binding and a synthetic `change` event entry (not `input` — selecting fires `change`)
- [ ] `checked = reactiveVal()` on checkbox produces both a binding and a synthetic `change` event entry with handler `\(e) val(e$checked)`
- [ ] `checked = reactiveVal()` on `<input type="radio">` produces both a binding and a synthetic `change` event entry
- [ ] 0-arg callable in `value` produces both a binding and a synthetic event entry with a no-op handler (write-attempt + force-send echoes current value back)
- [ ] Auto-bind synthetic event coexists with an explicit handler on a *different* event (e.g. `value = rv` + `onKeyDown`)

### Write-back

- [ ] `value = reactiveVal()` on text input — typing fires writes; `rv()` returns the typed value after flush
- [ ] `value = state$leaf` (store leaf) — typing fires writes
- [ ] `value = reactiveProxy(get = ..., set = ...)` — `set` is called on write
- [ ] `value = reactiveProxy(get = ...)` — writes silently dropped
- [ ] `value = \() expr()` (0-arg) — no write fires; client snaps back via the optimistic-update protocol
- [ ] `value = state$theme` on `<select>` — selection fires `rv(value)`
- [ ] `checked = reactiveVal(FALSE)` on checkbox — toggle fires `rv(TRUE/FALSE)`
- [ ] `checked = \() group() == "a"` on a radio (per-element boolean) — selecting fires through; deselected radio does not write (gated by `shouldSkip`)
- [ ] Focused-input echo skipping continues to work for auto-bind value updates

### One channel per event

A DOM event is bound *or* handled, never both; a single explicit handler
per event (no composition).

- [ ] `value = rv` + `onInput` on the same `<input>` errors (one channel)
- [ ] `checked = rv` + `onChange` on the same checkbox errors
- [ ] `value = rv` + `onChange` on a `<select>` errors (autobinds on `change`)
- [ ] `value = rv` + `onClick` coexist as two separate event entries
      (different events)
- [ ] `value = rv` + `onKeyDown` coexist (binding + unrelated event)
- [ ] Two explicit handlers on the same DOM event error (duplicate handler)
- [ ] `value = reactiveProxy(get, set)` bridges the both-case: the proxy's
      `set` runs on write, with one channel and no explicit `on*`

### Client-side state-binding application

- [ ] `value` on `<select>`: `irid-attr` sets `el.value = msg.value`, picking the matching option
- [ ] `checked` on `<input type="radio">`: `irid-attr` sets `el.checked = msg.value`
- [ ] `<select>` write-back listens on `change` (the `value` autobind event for selects)
- [ ] Radio write-back listens on `change`; only fires when `el.checked === true` (gated by `shouldSkip` to defend against deselect-change)

## `wire` per-slot config

Verify that `wire` on a slot configures timing, coalesce, and DOM
listener options for that event.

- [ ] A bare handler/reactive equals `wire(callable)` with default config
- [ ] No config props survive to the output HTML attributes
- [ ] `wire(h, wire_throttle(100))` sets `mode = "throttle"`, `ms = 100`
- [ ] `wire(h, dom_opts = wire_dom_opts(prevent_default = TRUE))` with no
      `timing` keeps the per-event default (no clobber)
- [ ] `wire_dom_opts` flags (`prevent_default`/`stop_propagation`/`capture`/
      `passive`) land on the event row and are applied client-side
- [ ] `wire_dom_opts(filter = ...)` carries a non-empty string; non-string /
      empty-string filters error at construction
- [ ] `filter` rides through `resolve_wire_config` to the event row and the
      client message (defaults to `NULL` when absent)
- [ ] e2e: a falsy `filter` predicate drops the DOM event client-side — no
      `prevent_default`/`stop_propagation`, no round-trip; a truthy one passes
- [ ] `wire(dom_opts = ...)` with no handler is client-only: a listener
      applies the flags, `clientOnly = TRUE`, no round-trip
- [ ] Without a `timing`, `input` events default to `wire_debounce(200)`;
      every other event to `wire_immediate()`
- [ ] `wire(rv, wire_immediate())` on a text input overrides the 200ms default
- [ ] `dom_opts` is per-slot, not broadcast across the element's other events
- [ ] A bare timing shape, `wire_dom_opts`, or `wire` in the wrong slot
      errors at process time with a tailored hint

## `iridApp` rendering

- [ ] `iridApp` calls `fn()` twice (UI pass and server pass) with shared counter
      so element IDs match between the static HTML and the reactive wiring
- [ ] Config message is sent synchronously in server function before mounting

## `iridOutput`/`renderIrid` integration

- [ ] `iridOutput` attaches the irid JS/CSS dependency
- [ ] `renderIrid` processes the tag tree and mounts after flush
- [ ] `renderIrid` uses `isolate()` on `func()` so the UI expression itself
      does not create a reactive dependency
- [ ] Reactive invalidation of `renderIrid` re-renders the content
- [ ] `irid_send_config` is called in the `onFlushed` callback

## Module scoping

- [ ] Event input IDs are correctly namespaced via `session$ns()`
- [ ] Bindings inside a module target the correct namespaced element IDs
- [ ] Nested modules (module inside module) produce unique IDs

## Optimistic updates

Verify the sequence-based optimistic update system for controlled inputs.

### Sequence tracking

- [ ] Each event payload includes an incrementing `__irid_seq`
- [ ] `__irid_seq` is excluded from the `event_obj` passed to user handlers
- [ ] Event observer stores `irid_current_sequence` on `session$userData`
- [ ] `onFlushed` clears `irid_current_sequence` after the flush completes
- [ ] Binding observers attach `sequence` to `irid-attr` only when `b$id` matches source

### Client-side echo handling

- [ ] **Stale echo** — `irid-attr` with `sequence < latest sent` is skipped
- [ ] **Current echo, same value** — `sequence >= latest sent` and `el.value === msg.value` is skipped (avoids cursor reset)
- [ ] **Server transform** — `sequence >= latest sent` and different value is applied (e.g. server truncates input)
- [ ] **Programmatic update** — `irid-attr` with no sequence always applies, even on focused element
- [ ] **Non-value attributes** — optimistic logic only gates `value` on focused
      elements; other attrs (`disabled`, `class`, etc.) always apply immediately
- [ ] **Element loses focus before response** — user types, tabs away, server
      responds: update applies normally (element no longer focused, no
      optimistic gating)
- [ ] **Sequence counter vs sent payloads** — with throttle/coalesce,
      `sequences[id]` increments on every DOM event (via `buildPayload`), but
      only some payloads are actually sent. A response to an early payload is
      correctly treated as stale relative to later unsent keystrokes

### Cross-element updates

- [ ] Button click handler that clears a text input: the text input's binding
      sends no sequence (different source), so the client treats it as
      programmatic and applies it
- [ ] Two inputs bound to the same `reactiveVal`: event on input A does not tag
      input B's binding with A's sequence

### Force-send on no-op

- [ ] Handler sets `reactiveVal` to the same value it already holds (no-op):
      force-send still delivers `irid-attr` with the sequence so the client
      can apply the server transform
- [ ] Handler sets `reactiveVal` to a new value: both force-send and binding
      observer fire; client handles the duplicate harmlessly (second is no-op)
- [ ] Force-send uses `isolate()` — does not create reactive dependencies in
      the event observer (event observer should only depend on its input)
- [ ] Server transform example: typing past `maxlength` in a truncating input
      with high latency — input snaps to truncated value when response arrives,
      even if `reactiveVal` was already at the truncated value

### Coalescing interactions

- [ ] With `coalesce = TRUE`, only one event is in flight at a time
- [ ] While server is busy, client accumulates the latest payload and sends it
      on `shiny:idle`
- [ ] With throttle (`leading = TRUE`): first event fires immediately, subsequent
      events are gated by both the throttle timer and server idle
- [ ] With debounce: events are held until the user pauses, then gated by server idle
- [ ] With `coalesce = FALSE` (default for `wire_immediate`): events fire on
      every input without waiting for server — events pile up under high latency
- [ ] Multiple events in one flush: later sequence overwrites earlier on
      `session$userData$irid_current_sequence`, so all bindings in that flush
      are tagged with the most recent sequence

## Stale UI indicator

Verify the stale indicator (grayscale dim + progress bar) appears and
disappears at the correct times.

### Basic show/hide

- [ ] Indicator does not appear on initial page load (server is busy rendering
      but no events have been sent)
- [ ] Indicator does not appear when server responds within `irid.stale_timeout`
- [ ] Indicator appears after `irid.stale_timeout` ms when server is slow
- [ ] Indicator clears when `shiny:idle` fires (after debounce delay)
- [ ] `irid.stale_timeout = NULL` disables the indicator entirely
- [ ] Custom timeout value (e.g. `500`) delays the indicator accordingly

### Debounced clear

- [ ] Rapid typing with moderate latency: indicator stays up continuously
      (clear debounce bridges the idle gaps between coalesced events)
- [ ] `shiny:busy` cancels any pending clear (multi-flush reactive chains
      don't cause a flash of undimmed state between flushes)
- [ ] New event sent shortly after `shiny:idle` cancels the pending clear

### Multi-flush chains

- [ ] Server processes event → reactive chain triggers follow-up flush →
      indicator stays up until the final flush completes
- [ ] `shiny:idle` → `shiny:busy` → `shiny:idle` sequence: indicator does not
      flicker off and on; it stays up throughout

### Config delivery

- [ ] `irid-config` message arrives before `irid-events` in the initial flush
- [ ] `iridApp` sends config synchronously in the server function
- [ ] `renderIrid` sends config in the `onFlushed` callback
- [ ] Repeated `irid-config` messages (e.g. `renderIrid` re-renders) update
      the client-side timeout without side effects
- [ ] App with no event handlers: stale indicator never appears

### Visual

- [ ] `irid-stale` class is added to `<html>`, not `<body>`
- [ ] CSS filter and progress bar activate when class is present
- [ ] `--irid-stale-color` CSS variable customizes the progress bar color
- [ ] Transition animates smoothly on both show and hide (0.15s)

## Client-side message handling

Verify that the JS message handlers correctly manipulate the DOM and
coordinate with Shiny's binding lifecycle.

### `irid-attr` property vs attribute dispatch

- [ ] `value`, `disabled`, `checked`, `innerHTML` are set as JS properties (not `setAttribute`)
- [ ] `textContent` is set via `.textContent` property
- [ ] Other attributes use `setAttribute()`
- [ ] `false`/`null` attribute values call `removeAttribute()`
- [ ] `innerHTML` content is trusted (author-controlled); verify user input cannot flow into `innerHTML` bindings unsanitized

### `irid-swap` binding lifecycle

- [ ] `Shiny.unbindAll` is called on each element between the start/end anchors
      before detachment
- [ ] Nested anchors in the detached range are deregistered from the anchor map
- [ ] New content is inserted immediately before the end anchor (start/end
      anchors themselves are preserved across swaps)
- [ ] Empty `msg.html` clears the range without inserting anything
- [ ] `Shiny.bindAll(parent)` is deferred via `setTimeout(0)` after replacement

### `irid-mutate` binding lifecycle

- [ ] `Shiny.unbindAll` is called on each element inside a removed child's range
- [ ] Nested anchors in each removed child range are deregistered
- [ ] Insert parses HTML in the container's parent context and registers
      nested anchors before insertion
- [ ] Reorder lifts each child's full `[start..end]` range and reinserts it,
      preserving element identity and anchor-map references
- [ ] `Shiny.bindAll(parent)` is deferred via `setTimeout(0)` after all
      mutations complete

### `irid-events` registration

- [ ] Duplicate registration for same `id:event` pair is prevented (no double listeners)
- [ ] `prevent_default` flag calls `event.preventDefault()` in the listener

### Payload construction

- [ ] Event payload includes all string/number/boolean properties from the JS event
- [ ] Element `value` and `checked` are included in the payload
- [ ] `valueAsNumber` is included when it is a number (not `NaN`)
- [ ] Property access errors are caught silently (some event properties throw)

## Comment-anchor range protocol

Verify that the client's anchor registry is correctly populated, maintained,
and used to locate control-flow ranges in the DOM — including inside
restricted-content parents where wrapper elements would be invalid.

### Registry population

- [ ] Initial page load walks `document.body` for `irid:s:ID`/`irid:e:ID`
      comment pairs and registers each in the anchor map
- [ ] `DOMContentLoaded` is used when document is still loading; immediate
      scan otherwise
- [ ] `lookupAnchors(id)` falls back to re-scanning `document.body` on cache
      miss (handles `renderIrid` output which arrives via Shiny output
      binding, not an irid message)
- [ ] Comment nodes with non-matching `data` (not `irid:s:`/`irid:e:`) are
      ignored by the walker
- [ ] Unpaired start anchor (no matching end) is not registered

### Registry maintenance

- [ ] Anchors inside inserted HTML are registered after `parseFragment`
- [ ] Anchors inside removed ranges are deregistered via `TreeWalker` over
      the detached fragment
- [ ] Reorder operations do NOT change anchor-map entries (same comment
      nodes, new positions)
- [ ] Nested control-flow anchors (e.g. `Each` inside `When`) are correctly
      registered and deregistered when the outer range is swapped out

### Restricted-content parents

Two representative cases are enough — the mechanism is parent-agnostic, but
`<select>` and table parsing exercise the strictest HTML parser rules.

- [ ] `Each`/`Index` over `<option>` children renders correctly inside
      `<select>` (no wrapper `<div>` injected by the parser)
- [ ] `Each` over `<tr>` children renders correctly inside `<tbody>`
- [ ] `parseFragment` uses the anchor's parent as parsing context so these
      fragments parse as their intended element (not stripped to text)

### Control-flow containers

- [ ] `process_tags` output contains `<!--irid:s:ID--><!--irid:e:ID-->`
      (no `<div style="display:contents">`) for `When`/`Each`/`Index`/`Match`
- [ ] Each per-item wrapper in `Each`/`Index` is itself bracketed by its own
      comment-anchor pair
- [ ] Container end anchor `a.end` is preserved across mutations — child
      ranges are inserted via `parent.insertBefore(..., a.end)`

## Debug latency

- [ ] `irid.debug.latency` option (in seconds) adds `Sys.sleep()` to every event handler
- [ ] Default value of `0` adds no delay

## End-to-end tests (browser)

Browser-driven round-trip tests live alongside the unit tests in
`tests/testthat/` and use the `chromote` + `callr` driver in
`helper-e2e.R` (+ `helper-e2e-plt.R` for the PlotlyOutput layer).

- **Naming convention (load-bearing):** every e2e test file is
  `test-<area>-e2e.R` (e.g. `test-plotly-e2e.R`). CI selects them with
  `devtools::test(filter = "e2e")`, so a new browser suite is picked up
  automatically by following the suffix — no list to maintain.
- **Gating** (`skip_unless_e2e()`): never on CRAN (`skip_on_cran()`); otherwise
  opt-in via the `IRID_E2E=1` env var (env vars, not `options()`, are the
  idiomatic test-gate mechanism). A bare `devtools::test()` skips e2e so it
  doesn't boot Chrome.
- **CI**: the main `R-CMD-check` job leaves `IRID_E2E` unset (e2e skips); a
  dedicated `e2e.yaml` job sets `IRID_E2E=1`, installs Chrome, and runs only the
  `*-e2e.R` files. Unit tests run once, in the check job.
- **Run locally:** `IRID_E2E=1 Rscript -e 'devtools::test(filter = "plotly-e2e")'`
  (one suite) or `filter = "e2e"` (all e2e).
