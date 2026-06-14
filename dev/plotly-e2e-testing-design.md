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
| Clearing a selection needs **layout.selections cleared FIRST, then a `selectedpoints` restyle** — while a drag selection is active plotly owns `selectedpoints`, so restyle is a silent no-op, and clearing only the dimming leaves the outline rectangle on screen | plotly's two-layer selection state | only a **real drag** populates `layout.selections`; `gd.emit('plotly_selected')` does not, so the emit shortcut never reproduces the outline and the bug stays hidden |
| bslib `layout_sidebar`/`page_sidebar` render blank through irid — `process_tags` drops the tag's `.renderHooks`, so the sidebar grid wrapper never materializes (issue #27) | irid×bslib boundary, render-time hooks | a *layout* bug, not a round-trip one — the DOM exists but renders at 0×0; caught only by screenshot / bounding-box inspection |
| Selection listeners (`plotly_selected` / `plotly_selecting` / `plotly_deselect`) lacked the `applying` guard, so a data-change `react()` fired a deselect echo that wrote back and **wiped the bound selection on every filter** | the own-mutation echo path | **masked when the binding is a plain `reactiveVal`** (echo re-sets the same value, a harmless no-op); only a *translating* `reactiveProxy` (index↔key) turns the spurious echo into a destructive clear |
| Setting a selection programmatically over an **active drag selection** is a silent no-op — plotly owns `selectedpoints` until `layout.selections` is cleared; and the *clear-first* fix must NOT fire on the drag's own echo or it wipes the user's fresh marquee | plotly selection ownership + echo vs intent | needs a real drag, *then* a programmatic set, with `matchesCurrent` distinguishing "graph already shows this" (echo → skip) from "different selection" (intent → clear outline, apply) |

The lesson: **PlotlyOutput needs a browser in the loop** — and for selection,
**a real mouse drag, not an emitted event.** The harness below is the one used
to find and fix all of these; this doc makes it repeatable.

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
    `gd.emit('plotly_deselect')` drive the discrete + selection *listeners*
    without pixel-accurate mouse choreography over the SVG.

  Emitting through plotly's own emitter runs the factory's real listener
  (`el.on(...)`), so `slimPoints`, `pointsToFrame`, the `applying` guard, and the
  sequence plumbing are genuinely exercised — only the *physical* mouse event is
  faked.

- **Client → server: a *real* mouse drag (when emit is not enough).**
  `gd.emit('plotly_selected', …)` is a **trap for selection-clearing tests**: it
  fires the listener but does **not** create plotly's internal selection — no
  outline, nothing in `layout.selections`. So the "Clear selection leaves the
  outline rectangle" bug is *invisible* to emit and only surfaces under a genuine
  drag. Drive one via CDP `Input.dispatchMouseEvent`:
  ```js
  // dragmode must be a select tool; aim at gd's .nsewdrag rect
  await mouse('mousePressed',  x1, y1);
  for (let i = 1; i <= 6; i++) await mouse('mouseMoved', lerp(x1,x2,i/6), lerp(y1,y2,i/6));
  await mouse('mouseReleased', x2, y2);
  ```
  A real drag populates **both** layers of selection state — `layout.selections`
  (the outline rectangle) and per-trace `data[*].selectedpoints` (the dimming) —
  which is exactly what the clear path must tear down (see §3.1). Use a real drag
  for any test that asserts on the outline; emit is fine only for the
  point→`setProp`→readout path.

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
- **Capture the websocket frames** (`Network.enable` +
  `Network.webSocketFrameReceived`, filter for `irid-attr`) when the readout and
  the plot disagree and you can't tell whether the server even sent the update.
  This is what proved the clear *was* sent as
  `{values:{selected_points:null}}` — moving the hunt from "is the message sent?"
  to "why didn't the client apply it?", which localized the bug to the
  `relayout`/`restyle` order rather than the wire.
- **Screenshot** (`Page.captureScreenshot`) for anything *layout*-shaped — the
  bslib sidebar (#27) rendered with all its content present in the DOM but at
  `0×0`, so only a screenshot (or a `getBoundingClientRect()` check) reveals it.
  State assertions on `gd.layout`/`gd.data` are blind to "present but invisible."

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
| 14 | Deselect clears (emit path) | `gd.emit('plotly_deselect')` | readout "none"; `selectedpoints` unset ✓ |
| 15 | Autorange-reset null clear | `gd.emit('plotly_relayout', {'yaxis.autorange':true})` | readout `hp: auto`, no R error ✓ |
| 16 | **Real drag-select** populates both layers | `Input.dispatchMouseEvent` drag over `.nsewdrag` | readout shows N points; `gd.layout.selections.length === 1`; outline DOM present ✓ |
| 17 | **Clear selection (button) tears down both layers** | real drag, then click "Clear selection" | readout "none"; `gd.layout.selections.length === 0`; every `selectedpoints` unset; `.selectionlayer path` gone ✓ |
| 18 | Subplot axes (`xaxis2_range`, …) | a `subplot()` fixture | each axis routes independently |
| 19 | `ggplotly()` parity | a `ggplotly` fixture | renders + the same range bindings work |
| 20 | Per-flush coalescing (one redraw) | a button writing spec + range together | a single `Plotly.react` (no flash); count redraws via a `plotly_afterplot` counter |
| 21 | Destroy on `When`/`Match` flip | toggle a gate hiding the plot | `Plotly.purge` ran; widget id removed from the registry |
| 22 | Sidebar/layout renders (regression for #27) | navigate, screenshot | control panel has non-zero width; `getBoundingClientRect().width > 0` |
| 23 | **Identity-based selection survives filtering** | real drag, then filter (drops a `cyl` group → trace recompose 3→2), then unfilter | selected *names* unchanged across all three; `selectedpoints` re-resolves to survivors after filter and back to the full set after unfilter ✓ |
| 24 | **Own-mutation echo does not clobber the binding** | real drag (bound via a translating proxy), then filter | the filter's `react()` deselect echo is swallowed by the `applying` guard — selection NOT wiped ✓ |
| 25 | **Programmatic set over an active drag** | real drag, then click "Select sports cars" | new selection applies; stale `layout.selections` outline cleared (`length === 0`); a re-drag of the *same* points leaves its marquee intact (echo skipped by `matchesCurrent`) ✓ |

Rows 18–21 need small dedicated fixtures (a subplot app, a ggplotly app, a
gated app); the kitchen-sink `examples/plotly.R` covers 1–17 and 22–25. **Rows
13/14 use emit and are necessary but not sufficient — they must be paired with
the real-drag rows 16/17/23/25, or the outline-clearing and own-echo classes of
bug slip through.**

> **Test selection bound to a *translating* `reactiveProxy`, not a plain
> `reactiveVal`.** The own-mutation-echo bug (row 24) is *invisible* when the
> bound value is a plain `reactiveVal` — the spurious deselect echo just re-sets
> the same value, a harmless no-op. It only turns destructive when an index↔key
> proxy sits behind the binding, where the echo's `null` clears the underlying
> key set. The kitchen-sink fixture binds the proxy precisely so this class of
> bug is exercised; a fixture that binds a bare `reactiveVal` would pass while
> shipping the bug.

### 3.1 Selection is two-layer state — test (and clear) both

A box/lasso selection in plotly is **not one thing**. A real drag writes two
independent pieces of state:

| Layer | Where | What it is | Cleared by |
|-------|-------|-----------|------------|
| Outline | `layout.selections` (a `rect`/`path`) + `.selectionlayer path` in the DOM | the gray selection rectangle | `Plotly.relayout(gd, {selections: null})` |
| Dimming | `data[*].selectedpoints` (per-trace index arrays) | which points are highlighted; everything else dims | `Plotly.restyle(gd, {selectedpoints: [null, …]})` |

`PlotlyOutput`'s `selected_points` prop is the **dimming** layer (canonical
`(curve, point)`); the outline is treated as transient geometry that is not
persisted. The clear path (`selected_points → NULL`) must tear down **both**, in
this order, because of two plotly quirks the harness must encode as assertions:

1. **While a drag selection is active, plotly owns `selectedpoints`** — a
   `restyle` to clear it is a *silent no-op*. So `relayout({selections: null})`
   must run **first** to deactivate the selection, *then* the `restyle` clears
   the dimming.
2. **Clearing the outline alone leaves the points dimmed** — `relayout` does not
   touch `selectedpoints`. Clearing the points alone leaves the rectangle on
   screen (the user has to double-click the plot to dismiss it).

So a clear-selection test must assert on **all three** signals — readout `none`,
`layout.selections.length === 0`, *and* every trace's `selectedpoints` unset —
driven from a **real drag** (row 17). An emit-only test passes while the live
plot still shows a stuck rectangle.

**The same ownership quirk bites *setting*, not just clearing.** Quirk 1 above
means a programmatic selection set over an *active* drag is also a silent no-op
until `layout.selections` is cleared — so `apply` (set) and `applyDeferred`
(clear) both clear the outline first, then restyle (to the value or `null`).
That raises a second hazard: clearing the outline on *every* apply would wipe a
user's own fresh marquee, because the drag echoes its selection straight back
through the binding. The discriminator is `matchesCurrent` — it returns true
when the graph already shows exactly the incoming selection (the drag's own
echo → skip, marquee survives) and false for a genuinely different selection
(programmatic set → clear the stale outline, apply). Row 25 must therefore
assert *both* directions: a programmatic set clears the outline, and a re-drag
of the same points keeps its marquee.

---

## 4. Making it a suite

### Layout

```
dev/e2e/
  run.sh            orchestration: boot app (bg, tracked PID), launch headless
                    chrome (tracked PID), run the node driver, tear down PIDs
  driver.mjs        CDP client + the assertion list; exits non-zero on any fail
  fixtures/
    kitchen-sink.R  examples/plotly.R minus the iridApp() launch (rows 1–17, 22)
    subplot.R       row 18
    ggplotly.R      row 19
    gated.R         rows 20–21
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
- **A real drag needs intermediate `mouseMoved` steps**, not just press→release —
  plotly's select tool builds the outline from the move stream, so a single jump
  produces no selection. Step the cursor (~6 moves) between press and release,
  and aim at the `.nsewdrag` rect's interior (offset in from the edges) so the
  drag lands on the plot area, not an axis.

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
  `Plotly.relayout` primitives here. The §2 drive primitives transfer verbatim —
  except the **real mouse drag**, which needs CDP `Input.dispatchMouseEvent`
  directly (`AppDriver` has no native drag); both chromote and shinytest2 expose
  the underlying CDP session to send it.

In all three, the three drive primitives (click-the-control; emit-the-plotly-event;
real mouse drag), the server-vs-client readout split, and the websocket-frame /
screenshot observability are unchanged — they are the design, not an artifact of
CDP. The one assertion that does *not* port is screenshot **pixel-diffing** for
plot content (SVG/canvas renders vary by machine); keep plot assertions on
`gd.layout`/`gd.data` state and reserve screenshots for layout/visibility checks
(row 22).

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
