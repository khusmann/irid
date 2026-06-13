# Per-event default timing table — design

**Status:** Proposed
**Date:** June 2026

---

## 1. Motivation

When an `irid_wire` carries no explicit `timing`, irid picks a default
keyed on the DOM event name ([process_tags.R](../R/process_tags.R)):

```r
default_for_event <- function(event_name) {
  if (event_name == "input") irid_debounce(200) else irid_immediate()
}
```

Only `input` is special-cased. Every other event — including the
**high-frequency continuous streams** (`mousemove`, `pointermove`,
`scroll`, `wheel`, `drag`/`dragover`, `resize`, `touchmove`) — falls
through to `irid_immediate()`, which derives `coalesce = FALSE`
([process_tags.R](../R/process_tags.R), `derive_coalesce`).

That combination is a firehose: every event fires `Shiny.setInputValue`
with no rate limiting and no server-idle backpressure. A naive

```r
tags$div(onMouseMove = \(e) hover(e))
```

floods the server with hundreds of events per second. They queue in
Shiny's input pipeline faster than the server can drain them, so the
server falls behind processing stale positions and end-to-end latency
grows unbounded — with no warning to the wrapper author.

### Why this isn't a problem with the `coalesce` default for `immediate`

`coalesce`'s default for `immediate` is correctly `FALSE` — see the
analysis in [events.md](events.md). `immediate` is the default for the
*discrete* events (`click`, `change`, `submit`, `keydown`, …) where each
event is semantically distinct, and `coalesce = TRUE` would silently
collapse distinct events to the latest one under load (two fast clicks →
one; three keydowns → only the last). For those events `FALSE` is right,
and when the server keeps up `TRUE` vs `FALSE` are indistinguishable
anyway (coalesce only changes behavior while the server is busy).

So flipping `immediate`'s `coalesce` default is the wrong fix — it would
pessimize the discrete-event majority to protect the firehose minority.
The right place to intervene is the **per-event default table**, exactly
where `input → debounce(200)` already lives. Explicit
`irid_immediate()` stays `FALSE`: if the author asked for raw immediate,
respect it.

---

## 2. Design

### 2.1 Extend `default_for_event`

Add a class of known high-frequency events that default to a
rate-limited + coalesced shape, alongside the existing `input` case:

```r
# Per-event default timing. Events fall into three classes:
#   - typing (`input`): a flood of intermediate values → debounce
#   - high-frequency streams (pointer/scroll/resize/…): continuous →
#     throttle + coalesce, so the server sees a paced "latest position"
#     stream it can actually keep up with
#   - everything else: one event per discrete user action → immediate
HIGH_FREQ_EVENTS <- c(
  "mousemove", "pointermove", "touchmove",
  "drag", "dragover",
  "scroll", "wheel",
  "resize"
)

default_for_event <- function(event_name) {
  if (event_name == "input") {
    irid_debounce(200)
  } else if (event_name %in% HIGH_FREQ_EVENTS) {
    irid_throttle(100)
  } else {
    irid_immediate()
  }
}
```

`coalesce` is *not* set here. It continues to derive from the timing
mode via `derive_coalesce()`: `throttle` → `TRUE`. So the high-frequency
default is throttle(100) **with** server-idle backpressure, for free,
through the existing derivation path — no change to `resolve_wire_config`
or the wire carrier.

### 2.2 Throttle, not debounce, for streams

`input` debounces because the user pauses and you want the *settled*
value once typing stops — intermediate keystrokes are noise.

Pointer/scroll/resize streams are different: the consumer usually wants
*continuous* feedback (a drag handle that tracks the cursor, a scroll
position readout). Debounce would make those update only after the user
*stops* moving — wrong feel. Throttle delivers a steady paced stream
during the motion, and the `coalesce = TRUE` derived from throttle adds
the server-idle gate so the stream never outruns the server: at most one
event in flight, always the latest.

Throttle interval `100ms` is a starting proposal (≈10 updates/sec —
smooth enough for hover/drag UI, slow enough to never back up a
fast-enough server; coalesce covers the case where the server is
slower). See open questions on tuning.

### 2.3 What stays the same

- **Explicit timing always wins.** `onMouseMove = irid_wire(h,
  irid_immediate())` is honored verbatim — the table is only consulted
  when `wire$timing` is `NULL` ([process_tags.R](../R/process_tags.R),
  `resolve_wire_config`).
- **`coalesce` derivation is unchanged.** No new field, no carrier
  change. The high-frequency default rides the existing `throttle →
  coalesce TRUE` rule.
- **`immediate`'s `coalesce = FALSE` default is unchanged.** Discrete
  events keep firing every event with no collapse.
- **DOM / text / widget targets** are unaffected — this is purely the
  client→server event-dispatch default.

---

## 3. Event list rationale

| Event | Default | Why |
|---|---|---|
| `input` | `debounce(200)` | typing flood; want settled value (unchanged) |
| `mousemove`, `pointermove`, `touchmove` | `throttle(100)` + coalesce | continuous pointer tracking |
| `drag`, `dragover` | `throttle(100)` + coalesce | fire continuously during a drag |
| `scroll`, `wheel` | `throttle(100)` + coalesce | continuous scroll position stream |
| `resize` | `throttle(100)` + coalesce | resize fires rapidly during a window/element drag-resize |
| `click`, `change`, `submit`, `keydown`, `keyup`, `focus`, `blur`, … | `immediate` (coalesce FALSE) | discrete; each event is meaningful, must not collapse (unchanged) |

Deliberately **excluded** from the high-frequency class:

- `keydown` / `keyup` — can repeat under key-hold, but each is usually a
  distinct semantic key (arrows, shortcuts). Collapsing them loses keys.
  Stays immediate; authors who want auto-repeat rate-limited opt in.
- `mouseenter` / `mouseleave` / `mouseover` / `mouseout` — discrete
  enter/leave transitions, low frequency in practice. Immediate.
- `pointerdown` / `pointerup` / `mousedown` / `mouseup` — discrete.

---

## 4. Non-goals

- **A configurable default table.** The table is internal. Authors tune
  per-slot via `irid_wire(timing = …)`; a global option to remap
  defaults is out of scope (and would make app behavior depend on
  invisible global state).
- **Client-side event filtering.** Dropping events that don't match a
  predicate before they're sent (e.g. `onKeyDown` that only cares about
  Enter) is a separate, already-planned feature
  ([ARCHITECTURE.md](../ARCHITECTURE.md) → *Client-side event
  filtering*). Orthogonal to default timing.
- **Per-element frequency adaptation.** No runtime measurement of actual
  event rate to auto-pick timing. Static name-keyed defaults only.

---

## 5. Open questions

- **Throttle interval.** `100ms` is a guess. `16ms` (~60fps) feels
  smoother for drag but leans harder on coalesce to avoid backup;
  `100ms` is safer as a default for a round-tripping server. Could the
  default differ per event (pointer faster than scroll)? Lean toward one
  uniform value for predictability unless there's evidence otherwise.
- **`leading` for the throttle default.** `irid_throttle(100)` defaults
  `leading = TRUE`, so the first move fires instantly then the stream
  paces. That's the right feel for drag/hover (immediate response, then
  paced). Confirm.
- **`touchmove` + `passive`.** A throttled `touchmove` listener that
  never calls `preventDefault` should ideally register `passive: true`
  for scroll performance. The default table sets timing, not
  `dom_opts` — should the high-frequency default also imply
  `passive = TRUE` for touch/wheel events, or leave that to the author?
  Leaning: leave it (don't silently change `preventDefault`
  semantics via a timing default).
- **Discoverability.** Should the default be documented at the wrapper
  author's eye level (roxygen on `irid_wire` / the event list) so it's
  not a surprise that `onScroll` is throttled? Yes — update the
  `@section` in [event.R](../R/event.R) and the
  [ARCHITECTURE.md](../ARCHITECTURE.md) per-slot config note.

---

## 6. Test plan

- **`mousemove` with no timing** → resolved config is
  `mode = "throttle"`, `ms = 100`, `coalesce = TRUE`.
- **`scroll` / `wheel` / `resize` / `pointermove` / `touchmove` /
  `drag` / `dragover` with no timing** → same throttle+coalesce shape.
- **`click` / `change` / `keydown` with no timing** → unchanged
  `mode = "immediate"`, `coalesce = FALSE`.
- **`input` with no timing** → unchanged `debounce(200)`.
- **Explicit override wins** — `onMouseMove = irid_wire(h,
  irid_immediate())` resolves to immediate, `coalesce = FALSE`;
  `onMouseMove = irid_wire(h, coalesce = FALSE)` keeps the throttle
  timing but disables coalesce (carrier `coalesce` wins over derivation).
- **Per-event default precedence** — a `default_timing` argument passed
  to `resolve_wire_config` (if any caller supplies one) still overrides
  the table, matching current precedence order.

---

## 7. Implementation sketch

Single-function change in [process_tags.R](../R/process_tags.R):

1. Add the `HIGH_FREQ_EVENTS` vector.
2. Extend `default_for_event` with the middle branch.

No changes to `resolve_wire_config`, `derive_coalesce`, the `irid_wire`
carrier, `irid-events` wire shape, or `irid.js` — the throttle+coalesce
path already exists and is exercised by `input`-style and explicitly
rate-limited events. This is a defaults-only change that routes more
events down an already-tested path.

Docs to update alongside the code:

- The `@section Timing shapes` paragraph in [event.R](../R/event.R) that
  currently says "`input` → `irid_debounce(200)`, every other event →
  `irid_immediate()`".
- The per-slot config note in [ARCHITECTURE.md](../ARCHITECTURE.md).
