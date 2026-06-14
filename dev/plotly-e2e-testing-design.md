# PlotlyOutput end-to-end testing — design

**Status:** Proposed
**Date:** June 2026

---

## 1. Why e2e at all

`PlotlyOutput` is almost entirely a *round-trip* component. Its R surface is
thin; its correctness lives in the loop:

```
user gesture → plotly.js event → setProp/sendEvent → managed-state wire →
  Shiny input → writeback handler → reactiveVal → binding/force-send →
  irid-attr → widget update() → Plotly.relayout/restyle → screen
```

Every bug found while building it was *invisible* to `process_tags` /
mount-level unit tests, because each was a property of that full loop:

| Bug | Where it lived | Unit test would miss it because… |
|-----|----------------|----------------------------------|
| NULL-init props dropped from the init `props` object, so the JS factory built no translation-table entries | R list semantics × JS factory | the prop list *looks* right in R; the loss is `props[[k]] <- NULL` deleting the key |
| `Plotly` global not loaded when the factory first runs | dep load ordering in the browser | no R/JS-unit visibility into async `<script>` execution order |
| Range vectors arrive as R *lists* (`list(40, 200)`) under Shiny's `simplifyVector = FALSE` | the wire decode boundary | the value is correct JSON; only a live Shiny decode reveals the shape |
| `coerce_state_prop` captured loop variables lazily — every proxy resolved to the *last* field | R promise semantics in a construction loop | the constructed object inspects fine; the bug only fires on a later write |
| `sendEvent("relayout")` bumped the shared sequence past the prop write, gating the snap-back echo as stale | the optimistic-update sequence counter, live | needs two real round-trips in order to observe the gate |
| `setProp(key, null)` arrives as `NA` (mount maps null→NA), breaking deselect / autorange-reset clears | the mount event-payload boundary | only a live `null` write through the wire produces the `NA` |
| `Plotly.restyle` array-wrapping for `selectedpoints` | plotly.js API contract | needs a real plotly graph to apply against |

The lesson: **PlotlyOutput needs a browser in the loop.** The harness below is
the one used to find and fix all seven; this doc makes it repeatable.

---

## 2. Harness: headless Chrome over the DevTools Protocol, zero deps

The constraint that shaped the approach: no `chromote`, `shinytest2`,
`puppeteer`, or `playwright` were installable, but a `google-chrome` binary and
Node 22 were present. Node 22 ships a global `WebSocket` and `fetch`, which is
all the Chrome DevTools Protocol (CDP) needs — so the harness is a single
dependency-free Node script driving headless Chrome directly.

### Moving parts

1. **App under test** — the example app booted headless:
   ```
   runApp(iridApp(App), port = <P>, launch.browser = FALSE, host = "127.0.0.1")
   ```
   Sourced from `examples/plotly.R` with the trailing `iridApp(App)` stripped,
   so the same file that ships as the demo is the fixture.

2. **Headless Chrome** with a remote debugging port and an isolated profile:
   ```
   google-chrome --headless=new --disable-gpu --no-sandbox \
     --remote-debugging-port=<D> --user-data-dir=<tmp> about:blank
   ```
   *Never* `pkill chrome` to clean up — a developer's own Chrome may be running.
   Track the spawned PID and kill only that.

3. **CDP client** — `fetch http://127.0.0.1:<D>/json` to find the page target,
   open its `webSocketDebuggerUrl`, then speak CDP: `Page.enable`,
   `Runtime.enable`, `Page.navigate`, and `Runtime.evaluate` with
   `awaitPromise: true, returnByValue: true` as the one workhorse.

### The two drive primitives

The whole suite is expressible with two ways of poking the page, mirroring the
two directions of the round-trip:

- **Server → client: click the real DOM controls.**
  ```js
  [...document.querySelectorAll('button')]
    .find(b => b.textContent.trim() === 'Hide 8-cyl trace').click();
  ```
  Drives the app's reactiveVals through the genuine event path, then asserts on
  `gd.layout` / `gd.data` and on the rendered readout text.

- **Client → server: synthesize the plotly gesture.**
  - `Plotly.relayout(gd, {'yaxis.range[0]': 100, 'yaxis.range[1]': 120})` fires a
    real `plotly_relayout` (split-key form, exactly what a drag emits) — this
    exercises `fromRelayout → setProp → writeback → snap-back`.
  - `gd.emit('plotly_selected', {points:[…]})` / `gd.emit('plotly_click', …)` /
    `gd.emit('plotly_deselect')` drive the discrete + selection listeners
    without needing pixel-accurate mouse choreography over the SVG.

  Emitting through plotly's own emitter is the key trick: it runs the factory's
  real listener (`el.on(...)`), so `slimPoints`, `pointsToFrame`, the
  `applying` guard, and the sequence plumbing are all genuinely exercised — only
  the *physical* mouse event is faked.

### Observability

- Subscribe to `Runtime.consoleAPICalled` and `Runtime.exceptionThrown` and
  echo them — page errors otherwise vanish silently.
- Tail the app's stderr log for R errors (`grep -c 'Error'`). The
  *count-before / count-after* pattern around a single gesture is how the
  `null → NA` and lazy-capture bugs were localized to an exact action.
- Read the app's own readout `<div>`s: they reflect the *server-side*
  reactiveVal, so comparing "what the plot shows" (`gd.layout`) against "what
  the server holds" (readout text) cleanly separates a client-apply bug from a
  server-write bug. This split was decisive — e.g. snap-back showed
  `hp: [50,160]` in the readout (server correct) while the plot showed the
  rejected `[100,118]` (client apply missing).

---

## 3. Coverage matrix

Each row is one assertion the harness should make. ✓ = verified during the
build; the rest are the same shape and should be filled in.

| # | Surface | Drive | Assertion |
|---|---------|-------|-----------|
| 1 | Spec renders, deps load | navigate | `window.Plotly && gd.data.length === <nTraces>` ✓ |
| 2 | Reactive spec + `uirevision` preserves view | move data slider after a zoom | range unchanged across the data update |
| 3 | `xaxis_range`/`yaxis_range` server→client | click "Zoom to economy cars" | `gd.layout.xaxis.range ≈ [20,35]`, `yaxis ≈ [50,130]` ✓ |
| 4 | `trace_visibility` server→client | click "Hide 8-cyl" | `gd.data[2].visible === 'legendonly'` ✓ |
| 5 | `dragmode` two-way | change `<select>` | `gd.layout.dragmode` follows; and a modebar pick writes the select back |
| 6 | `uirevision` reset | click "Reset view" | `gd.layout.xaxis.autorange` truthy; visibility back to default ✓ |
| 7 | `onRelayout` escape hatch | `Plotly.relayout(y)` | readout "last relayout" lists the gesture's keys ✓ |
| 8 | Accepted client zoom → server | `Plotly.relayout(y, wide)` | readout `hp: [lo,hi]` matches; plot keeps it ✓ |
| 9 | Snap-back, non-null canonical | accept wide, then reject narrow | plot reverts to the **prior accepted** range ✓ |
| 10 | Snap-back, null canonical (post-reset) | reset, then reject narrow | plot reverts to **autorange** ✓ |
| 11 | `reactiveProxy` gate | reject narrow zoom | server reactiveVal unchanged (readout `auto`/prior) ✓ |
| 12 | `onClick` (`slimPoints`) | `gd.emit('plotly_click', …)` | readout shows clicked point's `customdata`/`x`/`y` ✓ |
| 13 | `selected_points` (`pointsToFrame` → restyle) | `gd.emit('plotly_selected', …)` | readout point count + traces; `gd.data[i].selectedpoints` per-trace ✓ |
| 14 | Deselect clears | `gd.emit('plotly_deselect')` | readout "none"; `selectedpoints` unset ✓ |
| 15 | Autorange-reset null clear | `gd.emit('plotly_relayout', {'yaxis.autorange':true})` | readout `hp: auto`, no R error ✓ |
| 16 | Subplot axes (`xaxis2_range`, …) | a `subplot()` fixture | each axis routes independently |
| 17 | `ggplotly()` parity | a `ggplotly` fixture | renders + the same range bindings work |
| 18 | Per-flush coalescing (one redraw) | a button writing spec + range together | a single `Plotly.react` (no flash); count redraws via a `plotly_afterplot` counter |
| 19 | Destroy on `When`/`Match` flip | toggle a gate hiding the plot | `Plotly.purge` ran; widget id removed from the registry |

Rows 16–19 need small dedicated fixtures (a subplot app, a ggplotly app, a
gated app); the kitchen-sink `examples/plotly.R` covers 1–15.

---

## 4. Making it a suite

### Layout

```
dev/e2e/
  run.sh            orchestration: boot app (bg, tracked PID), launch headless
                    chrome (tracked PID), run the node driver, tear down PIDs
  driver.mjs        CDP client + the assertion list; exits non-zero on any fail
  fixtures/
    kitchen-sink.R  examples/plotly.R minus the iridApp() launch
    subplot.R       row 16
    ggplotly.R      row 17
    gated.R         rows 18–19
```

`driver.mjs` factors the connection boilerplate (`connectPage`, `evalJs`,
console/exception capture) used throughout §2 into reusable helpers, then runs
the §3 matrix as named cases, printing `PASS:`/`FAIL:` lines and a final count.

### Timing discipline

Round-trips are asynchronous, so each gesture is followed by a settle `sleep`
before asserting. Throttled props (ranges, `wire_throttle(100)`) plus the
server flush want ~1.5–2.5 s. Two robustness rules learned the hard way:

- **Poll, don't fixed-sleep, for the initial render** — wait in a loop for
  `gd.data.length === N` (up to ~30 s) rather than assuming a single delay.
- **One gesture per assertion window** — batching gestures lets a later one's
  sequence bump mask an earlier one's echo (exactly the snap-back gate bug).
  Settle and assert between gestures.

### CI gating

This is a heavyweight, browser-dependent suite — keep it out of the default
`devtools::test()` run (which must stay pure R). Gate it behind an env flag
(`IRID_E2E=1`) or a separate `make e2e` target, and skip cleanly when no
`google-chrome` binary is found, the same way DT-dependent tests skip when DT
is absent.

---

## 5. Migration path

The dependency-free CDP harness exists because nothing else was installable. If
the toolchain later gains one, port the *same matrix* onto it — the assertions
are the asset, not the transport:

- **`chromote`** — the natural R-native target. `b$Runtime$evaluate(...)`
  replaces `evalJs`; the app can run in-process via `shiny::runApp` in a
  background `callr` session. Keeps everything in R.
- **`shinytest2`** — gives app lifecycle + screenshot diffing for free, but its
  `get_value`/`set_inputs` model is DOM/input-centric; the plotly gestures still
  need raw `AppDriver$run_js(...)` calls equivalent to the `gd.emit` /
  `Plotly.relayout` primitives here. The §2 drive primitives transfer verbatim.

In all three, the two drive primitives (click-the-control; emit-the-plotly-event)
and the server-vs-client readout split are unchanged — they are the design, not
an artifact of CDP.

---

## 6. Open question — the dependency-load race

The factory guards `Plotly` availability with a `whenPlotly()` poll because
`plotly-main` and the factory script ship in the *same* `irid-widget-init`
message and `Shiny.renderDependencies` resolves synchronously (it injects
`<script>` tags but does not await their execution). That guard is a correct,
localized workaround, but it points at a substrate-level gap: a widget factory
can run before a sibling library dependency's global has executed. Whether the
widget-init path should *await actual script load* before calling the factory —
making the per-widget guard unnecessary for every future library widget — is
tracked separately from PlotlyOutput; the e2e harness is where any fix to it
must be regression-checked (row 1, hardened to assert the factory never touched
an undefined `Plotly`).
