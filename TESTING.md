# Testing Plan

## `process_tags` extraction

Verify that `process_tags` correctly walks a tag tree and separates reactive
attributes, event handlers, control-flow nodes, and Shiny outputs from the
static HTML.

- [ ] Plain tag with no reactive attributes passes through unchanged
- [ ] Reactive attribute is extracted into `$bindings` with correct `id`, `attr`, `fn`
- [ ] Event handler (`onInput`, `onClick`, etc.) is extracted into `$events`
- [ ] Bare function handlers are wrapped in `event_immediate()`
- [ ] `event_throttle`/`event_debounce` handlers preserve `mode`, `ms`, `leading`, `coalesce`
- [ ] Element with existing `id` attribute keeps it (not overwritten by auto-ID)
- [ ] Element with both reactive attrs and events shares one ID
- [ ] Reactive text child becomes a `<span>` binding with `attr = "textContent"`
- [ ] `When` node produces a control-flow entry with `type = "when"`
- [ ] `Each` node produces a control-flow entry with `type = "each"` and `by`
- [ ] `Index` node produces a control-flow entry with `type = "index"`
- [ ] `Match`/`Case`/`Default` produces a control-flow entry with `type = "match"`
- [ ] `Output` node produces a `$shiny_outputs` entry
- [ ] Nested tags are walked recursively (children of children)
- [ ] `tagList` children are walked and class is preserved
- [ ] Counter is shared across recursive `process_tags` calls (via `counter` arg)

## Observer lifecycle for control-flow primitives

Verify that control-flow nodes correctly create, destroy, and reuse child
mounts in response to reactive changes.

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

## Rate-limiting metadata propagation

Verify that `event_immediate`, `event_throttle`, and `event_debounce` metadata
is correctly propagated from R to the client.

- [ ] `event_immediate()` sends `mode = "immediate"` with `coalesce` flag
- [ ] `event_throttle()` sends `mode = "throttle"` with `ms`, `leading`, `coalesce`
- [ ] `event_debounce()` sends `mode = "debounce"` with `ms`, `coalesce`
- [ ] `prevent_default` flag is forwarded to the client
- [ ] Bare function defaults to `event_immediate(coalesce = FALSE)`

## `nacreOutput`/`renderNacre` integration

- [ ] `nacreOutput` attaches the nacre JS/CSS dependency
- [ ] `renderNacre` processes the tag tree and mounts after flush
- [ ] Reactive invalidation of `renderNacre` re-renders the content
- [ ] `nacre_send_config` is called in the `onFlushed` callback

## Module scoping

- [ ] Event input IDs are correctly namespaced via `session$ns()`
- [ ] Bindings inside a module target the correct namespaced element IDs
- [ ] Nested modules (module inside module) produce unique IDs

## Optimistic updates

Verify the sequence-based optimistic update system for controlled inputs.

### Sequence tracking

- [ ] Each event payload includes an incrementing `__nacre_seq`
- [ ] `__nacre_seq` is excluded from the `event_obj` passed to user handlers
- [ ] Event observer stores `nacre_current_sequence` on `session$userData`
- [ ] `onFlushed` clears `nacre_current_sequence` after the flush completes
- [ ] Binding observers attach `sequence` to `nacre-attr` only when `b$id` matches source

### Client-side echo handling

- [ ] **Stale echo** — `nacre-attr` with `sequence < latest sent` is skipped
- [ ] **Current echo, same value** — `sequence >= latest sent` and `el.value === msg.value` is skipped (avoids cursor reset)
- [ ] **Server transform** — `sequence >= latest sent` and different value is applied (e.g. server truncates input)
- [ ] **Programmatic update** — `nacre-attr` with no sequence always applies, even on focused element

### Cross-element updates

- [ ] Button click handler that clears a text input: the text input's binding
      sends no sequence (different source), so the client treats it as
      programmatic and applies it
- [ ] Two inputs bound to the same `reactiveVal`: event on input A does not tag
      input B's binding with A's sequence

### Force-send on no-op

- [ ] Handler sets `reactiveVal` to the same value it already holds (no-op):
      force-send still delivers `nacre-attr` with the sequence so the client
      can apply the server transform
- [ ] Handler sets `reactiveVal` to a new value: both force-send and binding
      observer fire; client handles the duplicate harmlessly (second is no-op)
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

## Stale UI indicator

Verify the stale indicator (grayscale dim + progress bar) appears and
disappears at the correct times.

### Basic show/hide

- [ ] Indicator does not appear when server responds within `nacre.stale_timeout`
- [ ] Indicator appears after `nacre.stale_timeout` ms when server is slow
- [ ] Indicator clears when `shiny:idle` fires (after debounce delay)
- [ ] `nacre.stale_timeout = NULL` disables the indicator entirely
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

- [ ] `nacre-config` message arrives before `nacre-events` in the initial flush
- [ ] `nacreApp` sends config synchronously in the server function
- [ ] `renderNacre` sends config in the `onFlushed` callback

### Visual

- [ ] `nacre-stale` class is added to `<html>`, not `<body>`
- [ ] CSS filter and progress bar activate when class is present
- [ ] `--nacre-stale-color` CSS variable customizes the progress bar color
- [ ] Transition animates smoothly on both show and hide
