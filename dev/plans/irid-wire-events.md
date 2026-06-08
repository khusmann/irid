# Implementation plan — `irid_wire` events & bindings

**Design:** [dev/events.md](../events.md)
**Branch:** `irid-wire`
**Shape:** one plan, two stages. Stage 1 (tag side, §1–6) is the firm,
low-risk core and lands first. Stage 2 (widget two-way-prop rework, §7) is
gated behind the §8 open-item-2 validation (a second, atomic-render widget).
Client-side `filter` / `irid_key_filter` (§2 `dom_opts$filter`) is **deferred**
to a separate follow-up — `irid_dom_opts` is built extensible but ships
without the `filter` field for now.

Scope explicitly excluded: `on:` verbatim events and `custom_tag()` — those
live in [custom-elements-design.md](../custom-elements-design.md) as a
downstream follow-on.

---

## Stage 0 — shared groundwork (lands with Stage 1)

The whole codebase moves off the `event_*` names in one mechanical pass so
nothing is half-renamed between stages.

- **Rename** `event_immediate` / `event_throttle` / `event_debounce` →
  `irid_immediate` / `irid_throttle` / `irid_debounce` everywhere
  ([R/event.R](../../R/event.R), [R/process_tags.R](../../R/process_tags.R),
  [R/widget.R](../../R/widget.R), examples, vignette, tests).
- **Drop `coalesce` from the timing shapes** — they become pure shapes. The
  carrier owns `coalesce` (§2). Until Stage 2, the widget event-row builder
  derives the default `coalesce` from the timing mode itself (the same rule
  the carrier will use: `immediate→FALSE`, `throttle`/`debounce→TRUE`) so
  `widget_event` keeps coalescing through the rename without yet depending on
  the carrier. **This is the deliberate staging seam** — Stage 2 deletes it
  when widget events move to `irid_wire`.

---

## Stage 1 — tag side (§1–6)

### 1.1 `R/event.R` — new constructors

- `irid_immediate()`, `irid_debounce(ms)`, `irid_throttle(ms, leading = TRUE)`
  — pure timing shapes, class `irid_timing` (renamed from
  `irid_event_config`; the new class name avoids implying they're a full
  event config now that `coalesce`/`dom_opts` live elsewhere). Each carries
  only `mode` + its mode-specific args.
- `irid_wire(subject = NULL, timing = NULL, coalesce = NULL, dom_opts = NULL)`
  — class `irid_wire`. Validates: `subject` NULL-or-function; `timing`
  NULL-or-`irid_timing`; `coalesce` NULL-or-logical-scalar; `dom_opts`
  NULL-or-`irid_dom_opts`.
- `irid_dom_opts(prevent_default = FALSE, stop_propagation = FALSE,
  capture = FALSE, passive = FALSE)` — class `irid_dom_opts`. **No `filter`
  arg yet** (deferred); struct is a plain record so adding `filter` later is
  additive.
- `merge.irid_wire(x, y, ...)` — override-wins overlay (§5). Normalize a
  `NULL` or bare-function `y` to an `irid_wire` first
  (`merge(default, NULL)` is identity; `merge(default, \() …)` fills only
  `subject`). Per-field: `y`'s non-`NULL` `subject`/`timing`/`coalesce`/
  `dom_opts` win, else `x`'s carry through. Export as an S3 method on the
  base `merge` generic (`@exportS3Method base::merge` via roxygen) — do **not**
  define a new `merge` generic (avoids masking dplyr/Bioconductor; decided
  in §8).
- Roxygen rewrite for the whole family; one `@name` page.

### 1.2 `R/process_tags.R` — slot-driven config, one channel per event

**Delete** (the element-level keyed-list machinery, §1/§2):
- `normalize_event_keyed_list`, `normalize_element_event`,
  `normalize_element_prevent_default`
- the `.event` / `.prevent_default` strip + lookup block (lines ~457–463,
  552–562)
- `merge_pending_events` and `compose_handlers` (the autobind↔explicit merge
  path, §4) — see the duplicate-handler note below.

**Add / change:**
- A helper `unwrap_wire(val)` that returns `list(subject, timing, coalesce,
  dom_opts)`: for a bare callable → subject only (rest `NULL`); for an
  `irid_wire` → its fields. Used uniformly in the value/checked autobind
  branch and the `on*` branch.
- The `irid_class` slot guard (lines ~484–507) must now **allow `irid_wire`**
  in event and `value`/`checked` slots (unwrap it). A bare `irid_timing`
  passed directly to a slot stays an error, with a hint: "pass timing inside
  `irid_wire(subject, timing)`".
- Per-event timing resolution: when the carrier's `timing` is `NULL`, fall
  back to the per-event default (`default_for_event`: `input` →
  `irid_debounce(200)`, else `irid_immediate()`) — unchanged rule, now keyed
  off the carrier instead of `.event`.
- `coalesce` resolution: carrier `coalesce` if non-`NULL`, else derive from
  the resolved timing mode (`immediate→FALSE`, else `TRUE`).
- `dom_opts` resolution: lift `prevent_default` / `stop_propagation` /
  `capture` / `passive` onto each event row (default all `FALSE` when no
  `dom_opts`).
- **Enforce one channel per event (§4):** after collecting pending events,
  if a `value`/`checked` autobind event name (`input`/`change`) collides
  with an explicit `on*` for the *same* DOM event, **error** — clear message
  pointing at `reactiveProxy` for the sync-write case. This replaces the
  merge. Per-event, not per-element: `value = rv` + `onKeyDown` is fine.
- **Duplicate explicit handlers on one event** (e.g. two `onInput` via
  `htmltools::tag`): with `compose_handlers` gone, **error** ("duplicate
  handler for event `input`") for consistency with the one-channel rule. The
  current test suite asserts these compose; that assertion is replaced with
  an error assertion under the new model.
- Event row fields become `{id, event, handler, write_targets, mode, ms,
  leading, coalesce, prevent_default, stop_propagation, capture, passive,
  source}`.

`make_autobind_handler` / `STATE_BIND_ATTRS` / `state_bind_event` stay as-is
(autobind still emits a binding + a synthetic handler — now simply the sole
channel for that event).

### 1.3 `R/mount.R` — carry the new dom_opts flags

- In the `irid-events` payload builder (lines ~139–149) add
  `stopPropagation`, `capture`, `passive` alongside `preventDefault`. No
  other mount change on the tag side.

### 1.4 `inst/js/irid.js` — apply the new listener flags

- `attachListener` (lines ~437–443): call `e.stopPropagation()` when
  `msg.stopPropagation`; pass `{capture: msg.capture, passive: msg.passive}`
  as the `addEventListener` options arg. `preventDefault` already handled.
- Mirror the same in the direct-send branch of `setupImmediate`
  (lines ~573–579).
- *(No `filter` eval — deferred.)*

### 1.5 Stage-1 examples / vignette / tests

- [examples/temperature.R](../../examples/temperature.R): `.event =
  event_throttle(100)` → fold into the slot:
  `value = irid_wire(reactiveProxy(get, set), irid_throttle(100))`.
- [vignettes/irid.Rmd](../../vignettes/irid.Rmd): rewrite the `.event` /
  `.prevent_default` section (lines ~173–205) to the carrier model; rewrite
  the `value = rv` + `onInput` paragraph (lines ~245) to the
  one-channel-per-event rule + `reactiveProxy` bridge.
- [tests/testthat/test-process_tags.R](../../tests/testthat/test-process_tags.R):
  - Drop the `value + onInput merges` family (lines ~157–290) and the
    duplicate-`onInput`-compose tests; replace with **error** assertions
    (one-channel-per-event; duplicate-handler).
  - Keep/retarget the default-timing tests (`input` → `irid_debounce(200)`).
  - New: bare `onClick` ≡ `irid_wire(handler)`; `irid_wire(submit,
    dom_opts = irid_dom_opts(prevent_default = TRUE))` with no `timing`
    preserves the per-event default; `irid_wire(dom_opts = …)` with no
    handler → client-only preventDefault, no round-trip;
    `value = reactiveProxy(get, set)` runs `set` on write; `merge` override
    semantics (per §10).

---

## Stage 2 — widget two-way-prop rework (§7)

**Gate:** §8 open-item 2 — validate the model against a second,
atomic-render widget (Plotly-class; see
[dev/plotly-output-design.md](../plotly-output-design.md)) before this stage
merges. Stage 1 ships independently of this gate.

### 2.1 The one new primitive — `setProp` + `irid_prop_{id}_{key}`

Props become **two-way-capable by default**, symmetric with DOM
`value`/`checked`. The framework always sets up inbound-accept + snap-back
for a prop holding a reactive; whether it's *actually* two-way depends on
whether the widget JS calls `setProp`.

- **`R/process_tags.R`** (widget branch, lines ~350–384): for each
  callable prop, in addition to the existing `target = "widget"` binding
  (server→client), register a **two-way-prop record** carrying the prop's
  resolved timing/coalesce (from its `irid_wire`, default `irid_immediate`).
  Events come from `irid_wire` carriers in the `events =` list (not
  `widget_event`).
- **`R/mount.R`**: for each two-way-capable prop, synthesize a write-back
  `observeEvent` on `session$input[[irid_prop_{id}_{key}]]` that writes the
  bound reactive iff `can_accept_write`, gated by the shared managed-state
  sequence transport, with read-only snap-back via force-send. Register a
  managed-state entry for each prop input in the `irid-events` message (so
  prop timing/coalesce works) — extend the event message with a
  `kind: "prop" | "event"` discriminator so the client knows a prop input is
  driven by `setProp`, not a DOM listener. (Reuses the existing channel
  rather than adding a new one.)
- **`inst/js/irid.js`**:
  - Rename the factory's 3rd arg `send` → `sendEvent`; add a 4th arg
    `setProp(key, value)` that pushes through the existing managed-state
    pipeline (`attachPayloadMeta` + `s.dispatch`) to
    `irid_prop_{id}_{key}`. Factor `sendWidgetEvent` so both `sendEvent`
    and `setProp` share it (different input-id suffix).
    `mountWidget` passes 4 args.

### 2.2 Retire the wrapper helpers (§7)

- **`R/widget.R`**: delete `write_back`, `widget_event`, the `then` arg, and
  the widget `onChange` callback. Keep `can_accept_write` **internal**
  (drop `@export`) — the synthesized write-back gates on it.
  `IridWidget(events = …)` now takes `irid_wire` carriers keyed by wire
  event-name; validate that a `sendEvent`-backed event carrying `dom_opts`
  **errors** at the container ("`prevent_default` needs a DOM listener",
  §6). `props` accept bare callables or `irid_wire` (tune-only).
- Remove the Stage-0 coalesce-derivation seam from the widget event-row
  builder (carriers own it now).

### 2.3 `examples/codemirror.R`

- Drop the local `event_pick`, `write_back`, `onChange`.
- `props`: `content = merge(irid_wire(timing = irid_debounce(200)), content)`;
  `events`: `` `cursor-changed` = merge(irid_wire(timing = irid_throttle(100)),
  onCursorChanged) ``.
- Inline JS factory: `function (el, props, sendEvent, setProp)`;
  `send("change", {content})` → `setProp("content", …)`;
  `send("cursor-changed", …)` → `sendEvent("cursor-changed", …)`.

### 2.4 Stage-2 tests (§10 widget side)

- Prop two-way-capable by default; snap-back echoes via force-send on a
  server-rejected value; no echo cost when never pushed.
- `setProp` writes the bound reactive via `irid_prop_*` (`can_accept_write`
  gated); `sendEvent` routes to the handler; both sequenced by the shared
  transport.
- `irid_wire(content, irid_debounce(200))` tunes round-trip timing without
  enabling/disabling two-way.
- Read-only reactive on a two-way prop: write dropped, canonical value
  snapped back.
- `dom_opts` on a `sendEvent` event errors at the container.
- Rewrite [tests/testthat/test-widget-helpers.R](../../tests/testthat/test-widget-helpers.R)
  and [tests/testthat/test-widget.R](../../tests/testthat/test-widget.R)
  (drop `write_back`/`widget_event`; keep `can_accept_write` as internal
  tests).

### 2.5 §8 open items to resolve in Stage 2

1. **Two-way-prop cost** — latent snap-back on every prop. Design leans
   default-on ("never fires unless pushed — cheap"); confirm/measure vs. an
   explicit opt-in before locking.
2. **Validation** (the gate above) — second atomic-render widget.

---

## Docs (split across both stages)

- [ARCHITECTURE.md](../../ARCHITECTURE.md): Stage 1 — replace the `.event` /
  `.prevent_default` element-prop section and the autobind-merge paragraphs
  (lines ~79–123, ~511–581); document the one-channel-per-event rule and the
  `irid_wire` carrier. Stage 2 — rewrite the *Widgets* round-trip /
  `write_back` sections for two-way props + `setProp`/`irid_prop_*`.
- [TESTING.md](../../TESTING.md): update the event/widget test plan.
- [NEWS.md](../../NEWS.md): one breaking-change entry per §9 (greenfield —
  single migration; can be one entry spanning both stages or one per stage).
- Run `devtools::document()` after export changes (new `irid_*` exports,
  removed `write_back`/`widget_event`, `merge.irid_wire` S3 registration,
  `can_accept_write` un-export).

---

## Sequencing & risk

Both stages land on the `irid-wire` branch as **separate commits** (not
separate PRs):

1. **Stage 0+1 — one commit** — mechanical rename + tag-side carrier rework +
   one-channel enforcement. Self-contained, no widget-contract break beyond
   the rename. Verify `devtools::document()`, `R CMD check`, all examples
   before committing.
2. **Stage 2 — second commit** — gated on the second-widget validation.
   Breaking widget-contract change (`send`→`sendEvent`, new `setProp`,
   `write_back`/`widget_event` removed).

**Resolved sub-decisions:**
- Duplicate explicit handlers on one event → **error** (§1.2).
- Timing-shape class is **`irid_timing`** (§1.1).
- Stage 2's prop-input registration **reuses the `irid-events` message** with
  a `kind` discriminator (§2.1).
</content>
</invoke>
