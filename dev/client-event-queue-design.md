# Client-Side Event Queue — Design Document

**Status:** Proposed
**Date:** March 2026

---

## 1. Motivation

irid attaches independent event listeners to DOM elements — one per `(element, event)` pair. Each listener has its own rate-limiting state: an `onInput` listener might be mid-debounce while an `onKeyDown` listener fires immediately. Because these streams are independent, an immediate event can overtake a pending debounced one and reach the server first.

**Concrete bug:** In the todo example, typing quickly then pressing Enter sends the `onKeyDown` (Enter → `add_todo()`) before the debounced `onInput` (→ `new_text(...)`) has flushed. The server calls `add_todo()` while `new_text()` still holds an outdated value, producing an incomplete or empty todo item.

The root cause is that events on the same element have no shared ordering guarantee.

---

## 2. Design

### 2.1 Per-Element Slot Queue

Each element gets a FIFO slot queue. When any DOM event fires on an element, it **immediately claims a slot** — before any debounce or throttle timer starts. Slots send in claim order.

```
t=0ms    onInput fires   → claims slot 1, debounce timer starts (200ms)
t=50ms   onKeyDown fires → claims slot 2, immediately ready to send
```

Slot 2 is ready first, but must wait for slot 1.

### 2.2 Preemptive Flush

Rather than waiting out a pending timer, a ready slot triggers a **preemptive flush** of any head slot still waiting on a timer:

1. Slot 2 becomes ready.
2. Head of queue is slot 1 — its debounce timer is still running.
3. Cancel slot 1's timer. Send slot 1's buffered payload immediately.
4. Send slot 2's payload.

This is semantically correct for debounce: the debounce waits for the user to pause, and a keydown is exactly the signal that they have paused typing. Cutting it short is the right behavior, not a workaround.

For throttle, the leading edge has already fired; the pending trailing slot holds the most-recent-since-then. Preemptive flush applies the same way.

**Null payload guard:** If a slot was claimed but has no payload yet (e.g. the input was empty), it is skipped rather than sending an empty event.

### 2.3 Sending

Shiny's `setInputValue` with `priority: 'event'` preserves call order within a session. Because of this, slots do not need to wait for a server round-trip between them — sending slot 1 then slot 2 back-to-back is sufficient for the server to process them in order. The existing `coalesce`/`serverBusy` machinery remains in effect per-slot for server-idle gating.

### 2.4 Scope

The queue is **per-element**, not global. Cross-element ordering rarely matters, and a global queue would cause unrelated inputs to block each other.

---

## 3. Revised Debounce Semantics

This changes the effective semantics of debounce from:

> Wait N ms after the last event before sending.

to:

> Wait N ms after the last event before sending, *or* send immediately when a later event on the same element demands ordering.

This is the correct semantics for a UI event system and should be documented explicitly.

---

## 4. Implementation Sketch

In `irid.js`, alongside the existing `managed` map (keyed by `inputId`), add:

```js
var elementQueues = {};  // elementId -> [{payload, flush}]
```

Each slot is `{payload: null, flush: fn}` where `flush` cancels any pending timer and marks the slot ready with its current payload.

**Drain function** (called whenever a slot becomes ready):

```js
function drainQueue(elementId) {
  var queue = elementQueues[elementId];
  while (queue.length > 0) {
    var head = queue[0];
    if (!head.ready) {
      // Check if a later slot is ready — if so, preemptively flush the head
      var laterReady = queue.slice(1).some(function(s) { return s.ready; });
      if (!laterReady) break;  // nothing to unblock, stop draining
      head.flush();            // cancels timer, sets head.ready = true
    }
    queue.shift();
    if (head.payload !== null) sendPayload(head.inputId, head.payload);
  }
}
```

Each `setup*` function claims a slot at DOM event time and calls `drainQueue` when the slot becomes ready (immediately for `setupImmediate`, on timer expiry for `setupDebounce`/`setupThrottle`, or via `flush` for preemptive sends).

---

## 5. Alternatives Considered

**Global queue:** All irid events share one queue. Rejected — unrelated elements would block each other, degrading responsiveness.

**Flush-only (no slots):** When an immediate event fires, cancel pending timers for the same element and send their payloads, then send the immediate. Simpler, but doesn't handle cases where two debounced events on the same element need ordering, or where the immediate event was registered before the debounce fired.

**Server-side coalesce only:** The existing `coalesce` mechanism gates events on server idle, but only per-stream. It cannot enforce cross-stream ordering on the client.
