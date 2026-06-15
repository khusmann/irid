# Widget async loading — the dependency-load race (#26)

## Problem

A widget factory can run **before a sibling library dependency's global has
executed**. Deps shipped via `irid-widget-init` are injected by
`Shiny.renderDependencies`, which adds `<script>` tags but does **not** await
their execution, and the old init path resolved synchronously and called the
factory immediately. Two distinct ordering concerns:

- **(a) factory-not-yet-registered** — handled by the `pendingInits` buffer: the
  init is queued and drained when `irid.defineWidget(name, …)` lands.
- **(b) factory registered, but a sibling library global isn't loaded** — *not*
  handled. The factory ran and immediately used a global (`Plotly`) provided by
  a different script dep in the same init message.

CodeMirror dodged (b) by importing via ES modules (its `defineWidget` is deferred
until the module graph loads). Any plain script-tag library (Plotly, Leaflet, …)
hit it. The interim fix was a per-widget `whenPlotly()` poll inside the factory;
the goal here was to stop every script-tag widget re-implementing that.

## What the spikes settled

Pinned: **Shiny 1.7.4 / jQuery 3.6.0** — re-run these on a Shiny/jQuery bump.
Spikes are build-ignored under `dev/spikes/`.

1. **`renderDependencies` does not await execution.**
   (`dev/spikes/render-deps-timing.R`) It returns `undefined` synchronously; on a
   cold load the dep's global is absent at the sync, microtask, *and* macrotask
   boundaries (a slow-server variant made this deterministic — the warm/HTTP-cache
   path can resolve synchronously, which is exactly why the bug is intermittent).
   So the existing `Promise.resolve(renderDependencies(...))` wrap can't help —
   there is no load signal in the return.

2. **Awaiting the `<script>` `load` event is unviable here.**
   (`dev/spikes/dep-await-contract.R`) Shiny injects deps via jQuery `$head.append`,
   and jQuery executes `<script src>` through an AJAX `globalEval` (`_evalUrl`),
   **not** a real script-tag fetch. Observed: two duplicate `<script src>` nodes
   per dep, **neither fires `load`/`error`**, yet the script executes exactly once
   (the global appears). The spike's tripwire (`A1_capturedSync`) correctly
   *failed*, demonstrating that a Shiny-injection-behavior change can be caught by
   an e2e assertion — but also that this approach is already broken on the current
   version. A generic dep-layer fix would therefore require **self-injecting**
   scripts (replicating Shiny's URL join + dedup + attribute handling) to get a
   real load event — the heavy, dep-shape-coupled path.

3. **jQuery preserves dep script execution order.**
   (`dev/spikes/dep-notifier-order.R`) Even when a notifier script's response
   beats a slow library's by 300ms, execution order is preserved intra-dep and
   inter-dep. So a "append a notifier script and poll its side effect" approach is
   *mechanically viable* — but it still needs dep-list machinery plus a (now
   confirmed, stable, testable) bet on script ordering.

## Options weighed

| option | author writes | substrate machinery | Shiny-internal coupling |
|---|---|---|---|
| §1a await `load` event | nothing | observe + await | **broken** (jQuery AJAX, finding 2) |
| §1b self-inject scripts | nothing | replicate URL/dedup/attrs | injection internals |
| notifier-wrap | nothing | append notifier dep + poll | script execution order |
| `ready` predicate (opts/arg) | one line | poll + gate | none |
| **async factory** (chosen) | one `await` line | await return + buffer + dispose | **none** |

The deciding lens was the spikes' own lesson: a "surely-stable" Shiny assumption
(the script `load` event) died on jQuery-AJAX. Every option except the last places
*some* bet on Shiny internals. The async factory places none — it waits on the
dependency's **outcome** (the global appears), which is the dep's whole public
reason to exist and is agnostic to *how* Shiny loads it.

"Robust if the library inits async after its script" (WASM/loader libs like
Google Maps, Perspective) was initially an axis for the predicate over the
notifier, but it is **not a discriminator**: any approach ends in author code, so
an author can always do their own wait — and the async factory expresses it most
naturally (`await engine.ready()`).

## Decision — the async-factory contract

`defineWidget(name, factory)` is unchanged in arity. The factory returns its
`{update, destroy}` handle **or a Promise of it**. The substrate:

- reserves the widget id synchronously (idempotent re-init; an `irid-attr` that
  lands mid-construction **buffers**, coalesced, rather than dropping);
- awaits the factory's return; on resolve **commits** — stores the handle and
  flushes the buffer;
- if the widget was torn down while an async factory was still constructing,
  **disposes** the resolved handle (runs its `destroy`) instead of adopting a
  detached zombie.

The wait itself lives in the widget, because *what* to wait for is
library-specific — "wait for `window.Plotly`" is a Plotly fact, and the transport
stays generic ("the factory may be async"). One idiom covers every case:

```js
irid.defineWidget("plotly", async function (el, props, sendEvent, setProp) {
  await whenPlotly();                 // poll window.Plotly (script-tag global)
  return { update, destroy };
});
// await import("...")        — ESM widget
// await engine.ready()       — WASM / async-init library
// (return synchronously)     — deps already on the page, e.g. ESM CodeMirror
```

**No `irid.waitFor` shipped.** The poll is ~8 lines a script-tag widget owns
(Plotly keeps its `whenPlotly`); CDN/ESM widgets `await import`/`$.getScript`
directly and need no helper. Keeping it out holds irid's public surface to the
one contract. A centralized helper (with timeout/diagnostics) can be added later
if the ecosystem wants it.

## Verification

- Existing `tests/testthat/test-plotly-e2e.R` (138 assertions) passes unchanged —
  including row 1, the "factory never touches undefined `Plotly`" guard, and the
  gate-flip destroy test. This is the regression gate the issue points to.
- `tests/testthat/test-widget-async-e2e.R` + `fixtures/widget-async.R` — a
  synthetic widget whose factory blocks on a test-flipped global, making the
  construction window deterministic. Asserts the two new substrate paths:
  updates-buffered-during-construction (then flushed in order) and
  teardown-during-construction disposes the handle.

## Re-confirm on bump

Findings 2 and 3 depend on jQuery's script-injection behavior. On a Shiny or
jQuery upgrade, re-run `dev/spikes/dep-await-contract.R` and
`dev/spikes/dep-notifier-order.R`. The chosen design (async factory) does **not**
depend on either — but if a future Shiny exposes a real load promise, the
`whenPlotly`-style polls could be simplified to await it.
