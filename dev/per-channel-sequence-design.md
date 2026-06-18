# Per-channel stale-echo gate (#28)

## The bug

The optimistic-update **stale-echo gate** is keyed per *element*
(`sequences[id]`), but the outbound sequence counter it compares against is
bumped by *every* channel on that element (DOM events, widget events, widget
prop write-backs). When one user gesture produces two round-trips from the same
element — e.g. a widget prop write **and** an event notification — the later send
bumps the shared counter past the earlier one, and the earlier one's inbound
echo is dropped as "stale" even though both belong to the same gesture.

Concretely (PlotlyOutput box/lasso select): a single gesture fires
`setProp("selected_ids", …)` **and** `plotly_relayout {selections}` →
`sendEvent("relayout", …)` from the same element. The relayout `sendEvent`
bumps `sequences[id]` past the `selected_ids` setProp, so the server's
`selected_ids` echo (lower seq) is gated out and the client's `state.selected_ids`
never updates.

This is **not** the outbound-ordering problem the client event queue solves
(`dev/client-event-queue-design.md`); it is the *inbound* gate misclassifying a
same-gesture echo. The two are orthogonal.

## Root cause, precisely

Two things are keyed per-element that should be keyed per-channel:

1. **Client counter** `sequences[id]` (`inst/js/irid.js`) — bumped in
   `attachPayloadMeta` on *every* outbound payload from element `id`, regardless
   of which channel sent it.
2. **Client gate** in the `irid-attr` handler — compares the echo's `sequence`
   against `sequences[msg.id]` (per-element).

The server (`R/mount.R`) threads a single `irid_current_sequence` per session
(`{seq, source}`, keyed only by source element), and the binding observers /
force-send stamp that seq onto echoes for any binding whose `id` matches the
source.

A "channel" here = a distinct client→server input stream from one element:
- DOM event → `irid_ev_{id}_{event}`
- widget event → `irid_ev_{id}_{event}`
- widget two-way prop write-back → `irid_prop_{id}_{key}`

For a plain `<input>` one element ≈ one value binding ≈ one event stream, so
per-element ≈ per-channel and the bug is invisible. It only bites **widgets**,
where one element multiplexes many props/events through one `sequences[id]`.

## The fix: key the counter, the threading, and the gate per-channel

### Channel identity

The channel key is the **inputId the payload is sent on** — the namespaced
`session$ns(input_id)`, which the client already uses as its `managed[...]` key
and send target (`s.inputId`), and which the server computes when building the
event message (`msg$inputId`). Using the same string on both ends keeps the
counter bump and the gate comparison consistent.

### Client (`inst/js/irid.js`)

- `sequences` becomes `channel → latest sent seq` (was `id → …`).
- `attachPayloadMeta(payload, id, channel)` bumps `sequences[channel]`.
  - `buildPayload(e, el, id, channel)` threads the channel; `attachListener`
    passes `msg.inputId`.
  - `pushManaged` passes the resolved stream's `s.inputId` (widget path).
- The echo now carries a `channel` field. The gate compares the echo's
  `sequence` against `sequences[msg.channel]`:
  ```js
  msg.sequence != null && msg.channel != null &&
  sequences[msg.channel] !== undefined &&
  msg.sequence < sequences[msg.channel]   // → drop as stale
  ```
- **Widget batches gate per-key.** A widget `irid-attr` coalesces several props
  into one `values` map (one message per widget per flush). Different props can
  carry different channels/seqs, so a single message-level gate cannot
  distinguish them. The message carries a parallel `value_meta: {key → {seq,
  channel}}`; the handler filters `values` per key, dropping only the stale
  ones, and skips the message entirely if every key is gated out. Keys with no
  `value_meta` entry are programmatic and always apply.

### Server (`R/mount.R`)

`irid_current_sequence` becomes a map keyed by **source element + declared
write target**, so each binding reads *its own* triggering channel's seq+channel
rather than "whatever event fired last this flush":

```
irid_current_sequence[[source_id]][[write_target_attr]] = list(seq, channel)
```

Gating is keyed strictly by `write_targets` — the bindings irid *manages*
two-way (autobind `value`/`checked`, `reactiveProxy` side-effect writes, widget
props). A hand-rolled `on*` handler declares no `write_targets`, so it populates
no entry and the binding it happens to drive echoes with **no sequence** —
treated as a programmatic update, applied ungated. This is a deliberate
behaviour change from today's "any binding on the source element picks up the
seq" rule (see "Behaviour change" below); it makes the seq-stamp path consistent
with the already-`write_targets`-scoped force-send loop and the
one-channel-per-event contract.

- The **event observer** sets one entry per `write_targets` attr for its source
  element. Multiple events on the same element in one flush write **disjoint
  keys** (each channel owns its own targets), so there is no clobbering — a
  sibling channel's send can no longer steal another channel's entry. Events
  with no `write_targets` (notifications, hand-rolled handlers) set nothing.
- The **binding observer** for `(id, attr)` looks up `[[id]][[attr]]`; if absent
  (programmatic, or hand-rolled-driven), it sends no sequence. When present it
  stamps both `sequence` and `channel` onto the echo (or
  `irid_queue_widget_attr`).
- The **force-send loop** already iterates `write_targets`; it stamps the
  triggering event's seq + channel (both in scope).
- `channel <- session$ns(input_id)` is computed once per event in the
  `result$events` loop and closed over by the observer.

`irid_queue_widget_attr(session, id, attr, value, sequence, channel)` records
per-key `{seq, channel}` into `entry$value_meta` and emits it as the message's
`value_meta` (replacing the single batch-level `sequence`, which took the max
across contributing bindings — meaningless once channels differ per key).

### Why this fixes box-select

- `setProp("selected_ids", v)` → channel `C1 = …irid_prop_{id}_selected_ids`,
  seq `Na` (bumps `sequences[C1]`). Its event observer sets
  `cur[[id]][["selected_ids"]] = {Na, C1}`.
- `sendEvent("relayout", …)` → channel `C2 = …irid_ev_{id}_relayout`, seq `Nb`
  (bumps `sequences[C2]`, **not** `C1`). It declares no `write_targets`, so its
  observer sets no `irid_current_sequence` entry — never touches `selected_ids`.
- The `selected_ids` binding echoes with `{seq: Na, channel: C1}`. Client gate:
  `sequences[C1] > Na`? No (only selected_ids sends bump `C1`). **Applied.**

## Behaviour change: hand-rolled handlers no longer gate

Today an event observer stores `irid_current_sequence` for *any* event carrying
a seq, and any binding on the source element picks it up. This redesign gates
strictly by declared `write_targets`, so a binding driven only by a hand-rolled
`on*` handler (which declares no targets) echoes ungated.

This is a deliberate narrowing, justified by three existing facts:

- **The force-send half is already `write_targets`-scoped.** Hand-rolled
  handlers already get no force-send (`R/mount.R`); this makes the natural-echo
  seq-stamp consistent with that, rather than leaving the two halves split.
- **The one-channel-per-event rule already steers off the conflicting pattern.**
  `value = rv` + `onInput` (same event) errors today; the blessed way to run a
  synchronous side-effect on write is `value = reactiveProxy(get, set)` — an
  autobind with a declared target that stays fully gated.
- **`__default` never robustly protected the residual case anyway.** A
  hand-rolled handler on a non-autobind event (e.g. `onKeyDown` writing a
  co-bound `value`) would gate against the *keydown* channel, which newer typing
  does not bump — so the "protection" was illusory.

Net: managed two-way bindings (autobind `value`/`checked`, `reactiveProxy`,
widget props) keep full optimistic gating; hand-rolled `on*` handlers are
side-effect channels whose incidental echoes apply as programmatic.

## Cleanup unlocked (PlotlyOutput)

`inst/widgets/plotly/plotly-irid.js`, `plotly_relayout` listener — two
workarounds added solely to dodge the shared-counter pollution come out:

1. **"Emit the notification FIRST, then the prop writes"** — the ordering existed
   only so the relayout `sendEvent` didn't out-sequence the range/`dragmode`
   snap-back setProps. With per-channel sequencing, emit order no longer affects
   the gate; drop the comment + ordering constraint.
2. **"Skip selection-only relayouts"** — added so the selection-outline
   relayout's `sendEvent` didn't out-sequence the `selected_ids` setProp. No
   longer load-bearing for correctness. **Decision: keep it** as an
   optional/cosmetic guard so `onRelayout` isn't handed transient selection
   geometry, but rewrite the comment to drop the sequence justification (the
   `TODO(#28)` note already frames it as optional). *(Open question — see below.)*

The `TODO(#28)` markers in that file are removed as each site is resolved.

## Survey for other workarounds

Before closing, grep the codebase + widget factories for the same
shared-counter constraint shaping code elsewhere: `sequence`, `setProp`/
`sendEvent` emit-order comments, "stale", "echo", and `TODO(#28)`. Known sites
are the two plotly ones above; record any others here.

Survey results: _(to fill in during implementation)_

## Tests

- **R unit (`test-widget-batching.R`)** — replace the batch-level `sequence`
  assertions with `value_meta` per-key assertions:
  - per-key `{seq, channel}` recorded and emitted;
  - a purely programmatic batch carries no `value_meta`;
  - the `irid_current_sequence` integration test uses the new per-target
    structure (`cur[[id]][[attr]]`) and asserts the drained `value_meta`.
- **R unit (new, `test-mount-sequence.R` or fold into batching)** — the
  per-channel threading in `irid_mount_processed`:
  - a binding whose `(id, attr)` matches a write target stamps that target's
    seq+channel;
  - a sibling channel's event in the same flush does **not** overwrite another
    target's entry (the core regression);
  - a hand-rolled handler (no `write_targets`) stamps **no** sequence — its
    binding's echo applies as programmatic (the behaviour change above);
  - a cross-element binding (`source ≠ id`) still stamps nothing (programmatic).
- **JS / e2e** — extend the plotly e2e (`test-plotly-e2e.R`) to assert the
  box-select `selected_ids` echo is **applied** (state re-resolves on a
  subsequent data change), the regression the bug describes. Confirm the gate
  helper is exercised for the per-key widget drop path.

## Docs

- `ARCHITECTURE.md` — update the optimistic-update / sequence section to describe
  per-channel keying (counter, `irid_current_sequence` shape, `value_meta` on
  widget batches) instead of per-element.
- `TESTING.md` — the "Optimistic updates" checklist items that assert
  per-element behaviour need rewording, notably:
  - "Multiple events in one flush: later sequence overwrites earlier … all
    bindings tagged with the most recent sequence" — now **per-channel**: each
    binding is tagged with its own triggering channel's seq; a sibling channel
    does not clobber it.
  - "`sequences[id]` increments on every DOM event" → `sequences[channel]`.
  - "Binding observers attach `sequence` … only when `b$id` matches source" →
    only when a `write_targets` entry matches `(b$id, b$attr)`.
  - add a widget per-key gate item and a hand-rolled-handler-is-ungated item.

## Open questions for review

1. **Keep or drop the plotly "skip selection-only relayouts" guard?** It is no
   longer needed for correctness. Keeping it spares `onRelayout` the transient
   selection geometry; dropping it is less code. Plan currently keeps it
   (cosmetic) with a rewritten comment. — _Your call._
2. **Channel-key namespacing.** The widget `pushManaged` path already looks up
   `managed[...]` by the **un-namespaced** `irid_ev_{id}_{event}` while DOM uses
   the namespaced `msg.inputId`; widget events therefore appear to assume a
   top-level (identity-ns) session today. This design keys the counter by
   `s.inputId` (whatever the stream resolved under) and the server stamps
   `session$ns(input_id)` — consistent at top level, and no worse than today in a
   module. Out of scope to fix module support for widget channels here; flagging
   it. — _Confirm acceptable._

_Resolved during review:_ gate strictly by `write_targets` (no `__default`
catch-all); hand-rolled handlers echo ungated. See "Behaviour change" above.

## Re-confirm-on-bump caveats

- The outbound-ordering assumption (Shiny processes back-to-back event-priority
  inputs in send order) is unchanged by this work but still underpins the
  same-flush reasoning; pinned to the existing Shiny version note in
  `dev/client-event-queue-design.md`.
