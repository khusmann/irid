# PlotlyOutput end-to-end testing — design

**Status:** Implemented — `chromote`/`callr` suite live in `tests/testthat/`
(`helper-e2e.R`, `test-plotly-e2e.R`, `fixtures/{kitchen-sink,subplot,ggplotly,gated}.R`),
covering all 26 §3 rows. Gated behind `skip_on_cran()` + prerequisite skips +
a local `IRID_E2E=1` opt-out; run with
`IRID_E2E=1 Rscript -e 'devtools::test(filter = "plotly-e2e")'`.
**Date:** June 2026

> **Implementation status / handoff.** Everything marked ✓ in the §3 matrix was
> verified *live* during development, but only through throwaway Node/CDP scripts
> that were not kept. **There is currently no automated e2e suite, and the
> package's 706 pure-R tests cover none of this round-trip behavior** — so every
> bug listed in §1 is, right now, protected by nothing. This document is the
> implementation spec for the suite that closes that gap. The intended transport
> is **`chromote`** (§2) — it installs and drives the local Chrome here, so the
> "nothing installable" constraint that forced the original Node harness no
> longer holds. The starting point is §4 (R-native layout, CI gating) building
> the §3 matrix as named cases; the kitchen-sink fixture (`examples/plotly.R`)
> already exercises rows 1–17 and 22–26. Treat the ✓ marks as "known-good
> behavior to assert," not "already under test."

> **Note — self-contained fixtures, and easy to skip.** Two hard rules for the
> suite, which **override** the "reuse `examples/plotly.R`" shortcut mentioned
> throughout this doc:
>
> 1. **The e2e tests own their fixtures — do not depend on files under
>    `examples/`.** `examples/*` exist to demo the package and will drift with the
>    docs; a test suite that sources them couples assertions to demo content and
>    breaks whenever an example is reworded. The fixtures live with the suite in
>    `tests/testthat/fixtures/` (testthat's documented home for static fixtures) —
>    **not** under `dev/`, which is for design/plan docs only. Make them dedicated,
>    test-owned apps that diverge from the examples on purpose (e.g. the
>    translating-`reactiveProxy` binding of row 24, the whole-group filter of rows
>    23/26). Where this doc says "the fixture is `examples/plotly.R` minus the
>    launch," read it as "a test-owned kitchen-sink fixture modeled on
>    `examples/plotly.R`."
> 2. **Make the suite trivial to not run — the idiomatic R way.** It is browser-
>    and process-heavy and must never run on CRAN. The primary gate is
>    `testthat::skip_on_cran()` (CRAN sets `NOT_CRAN`; testthat reads it), backed
>    by the prerequisite skips in §4 (`chromote`/`callr` installed, a browser
>    found). A separate `make e2e` tree is *not* used — the suite stays a
>    first-class `tests/testthat/` citizen and earns its keep by skipping.
>    Optionally layer a *local* opt-out (`skip_if(Sys.getenv("IRID_E2E") != "1")`)
>    so a routine `devtools::test()` on a laptop doesn't boot Chrome — but that's
>    convenience, not the CRAN guard.

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

## 2. Harness: `chromote` driving headless Chrome

The original harness was a dependency-free Node/CDP script, chosen because at the
time *nothing* R-native was installable — no `chromote`, `shinytest2`,
`puppeteer`, or `playwright`. That constraint is gone: **`chromote` installs from
CRAN and drives the local `google-chrome` here.** It *is* a CDP client, so it
speaks the exact protocol the Node script hand-rolled (`Page.navigate`,
`Runtime.evaluate`, `Input.dispatchMouseEvent`, `Network`, `Page.captureScreenshot`)
— but keeps the entire suite in R, with no Node dependency and no separate
process to orchestrate by hand. Everything below maps the §1/§3 work onto
`chromote`'s API; the *semantics* are identical to the Node harness that found
the bugs, only the transport changes.

### Moving parts

1. **App under test** — booted in a background R process via `callr::r_bg`, so
   the app's reactive loop runs in a real, separate Shiny session while the test
   process drives the browser:
   ```r
   app_proc <- callr::r_bg(function(path) {
     app <- source(path)$value
     shiny::runApp(irid::iridApp(app), port = port,
                   launch.browser = FALSE, host = "127.0.0.1")
   }, args = list(path = testthat::test_path("fixtures/kitchen-sink.R")))
   ```
   The fixture is a **test-owned** app modeled on `examples/plotly.R` (the
   trailing `iridApp(App)` stripped), living in `tests/testthat/fixtures/` — the
   suite never sources `examples/*` (see §4). `app_proc$is_alive()` and
   `app_proc$read_error()` give lifecycle + the stderr stream (R errors).

2. **Headless Chrome** — `chromote` finds and launches the browser itself
   (`chromote::find_chrome()`), on an isolated profile, and owns the process
   lifecycle. No manual `--remote-debugging-port`, no PID tracking, and crucially
   **no `pkill chrome`** — `b$close()` / `chromote::default_chromote_object()`
   tear down only the spawned instance, never a developer's own Chrome.

3. **CDP client** — a `chromote::ChromoteSession`. `b$Page$navigate(url)` and
   `b$Runtime$evaluate(js, awaitPromise = TRUE, returnByValue = TRUE)` are the
   one workhorse (returns the value into R directly); the `Input`, `Network`, and
   `Page` domains are all exposed as `b$Input$...`, `b$Network$...`, etc.

### The drive primitives

The whole suite is expressible with three ways of poking the page, mirroring the
directions of the round-trip — each is a `chromote` call:

- **Server → client: click the real DOM controls** (`b$Runtime$evaluate`).
  ```r
  b$Runtime$evaluate("
    [...document.querySelectorAll('button')]
      .find(b => b.textContent.trim() === 'Hide 8-cyl trace').click();
  ")
  ```
  Drives the app's reactiveVals through the genuine event path, then asserts on
  `gd.layout` / `gd.data` and on the rendered readout text.

- **Client → server: synthesize the plotly gesture** (`b$Runtime$evaluate`).
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

- **Client → server: a *real* mouse drag (when emit is not enough)**
  (`b$Input$dispatchMouseEvent`). `gd.emit('plotly_selected', …)` is a **trap for
  selection-clearing tests**: it fires the listener but does **not** create
  plotly's internal selection — no outline, nothing in `layout.selections`. So
  the "Clear selection leaves the outline rectangle" bug is *invisible* to emit
  and only surfaces under a genuine drag. `chromote` exposes the same
  `Input.dispatchMouseEvent` the Node harness used:
  ```r
  # dragmode must be a select tool; aim at gd's .nsewdrag rect
  b$Input$dispatchMouseEvent(type = "mousePressed",  x = x1, y = y1, button = "left")
  for (i in 1:6)
    b$Input$dispatchMouseEvent(type = "mouseMoved",
      x = lerp(x1, x2, i/6), y = lerp(y1, y2, i/6), button = "left")
  b$Input$dispatchMouseEvent(type = "mouseReleased", x = x2, y = y2, button = "left")
  ```
  A real drag populates **both** layers of selection state — `layout.selections`
  (the outline rectangle) and per-trace `data[*].selectedpoints` (the dimming) —
  which is exactly what the clear path must tear down (see §3.1). Use a real drag
  for any test that asserts on the outline; emit is fine only for the
  point→`setProp`→readout path.

### Observability

- Subscribe to console/exception events — `b$Runtime$consoleAPICalled` and
  `b$Runtime$exceptionThrown` (register a callback) and echo them — page errors
  otherwise vanish silently.
- Read the app's stderr for R errors via `app_proc$read_error()`. The
  *count-before / count-after* pattern (count `'Error'` lines around a single
  gesture) is how the `null → NA` and lazy-capture bugs were localized to an
  exact action.
- Read the app's own readout `<div>`s: they reflect the *server-side*
  reactiveVal, so comparing "what the plot shows" (`gd.layout`) against "what
  the server holds" (readout text) cleanly separates a client-apply bug from a
  server-write bug. This split was decisive — e.g. snap-back showed
  `hp: [50,160]` in the readout (server correct) while the plot showed the
  rejected `[100,118]` (client apply missing).
- **Capture the websocket frames** (`b$Network$enable()` +
  a `b$Network$webSocketFrameReceived` callback, filter for `irid-attr`) when the
  readout and the plot disagree and you can't tell whether the server even sent
  the update. This is what proved the clear *was* sent as
  `{values:{selected_points:null}}` — moving the hunt from "is the message sent?"
  to "why didn't the client apply it?", which localized the bug to the
  `relayout`/`restyle` order rather than the wire.
- **Screenshot** (`b$screenshot()` / `b$Page$captureScreenshot()`) for anything
  *layout*-shaped — the bslib sidebar (#27) rendered with all its content present
  in the DOM but at `0×0`, so only a screenshot (or a `getBoundingClientRect()`
  check) reveals it. State assertions on `gd.layout`/`gd.data` are blind to
  "present but invisible."

---

## 3. Coverage matrix

Each row is one assertion the harness should make. ✓ = verified during the
build; the rest are the same shape and should be filled in.

| # | Surface | Drive | Assertion |
|---|---------|-------|-----------|
| 1 | Spec renders, deps load | navigate | `window.Plotly && gd.data.length === <nTraces>` ✓ |
| 2 | Reactive spec + `uirevision` preserves view | move data slider after a zoom | range unchanged across the data update |
| 3 | `xaxis_range`/`yaxis_range` server→client | click "Zoom to economy cars" | `gd.layout.xaxis.range ≈ [20,35]`, `yaxis ≈ [50,130]` ✓ |
| 4 | `trace_visibility` (name-keyed) server→client | click "Hide 8-cyl" (sets `c("8"="legendonly")`) | the trace *named* `"8"` has `visible === 'legendonly'` (found by name, not index) ✓ |
| 5 | `dragmode` two-way | change `<select>` | `gd.layout.dragmode` follows; and a modebar pick writes the select back |
| 6 | `uirevision` reset | click "Reset view" | `gd.layout.xaxis.autorange` truthy; visibility back to default ✓ |
| 7 | `onRelayout` escape hatch | `Plotly.relayout(y)` | readout "last relayout" lists the gesture's keys ✓ |
| 8 | Accepted client zoom → server | `Plotly.relayout(y, wide)` | readout `hp: [lo,hi]` matches; plot keeps it ✓ |
| 9 | Snap-back, non-null canonical | accept wide, then reject narrow | plot reverts to the **prior accepted** range ✓ |
| 10 | Snap-back, null canonical (post-reset) | reset, then reject narrow | plot reverts to **autorange** ✓ |
| 11 | `reactiveProxy` gate | reject narrow zoom | server reactiveVal unchanged (readout `auto`/prior) ✓ |
| 12 | `onClick` (`slimPoints`) | `gd.emit('plotly_click', …)` | readout shows clicked point's `customdata`/`x`/`y` ✓ |
| 13 | `selected_ids` (`idsFromPoints` → restyle) | `gd.emit('plotly_selected', …)` with points at known indices | readout shows the *ids* (names); `gd.data[i].selectedpoints` per-trace resolves from ids ✓ |
| 14 | Deselect clears (emit path) | `gd.emit('plotly_deselect')` | readout "none"; `selectedpoints` unset (full opacity, not `[]`) ✓ |
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
| 26 | **Name-keyed visibility survives recomposition + round-trips** | hide `"8"`, filter so a `cyl` group drops (3→2 traces), unfilter; then a legend toggle | trace `"8"` stays `legendonly` across the recompose (keyed by name, not index); a legend toggle writes the full `{name → state}` map back ✓ |

Rows 18–21 need small dedicated fixtures (a subplot app, a ggplotly app, a
gated app); the kitchen-sink `examples/plotly.R` covers 1–17 and 22–26. **Rows
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

### 3.2 Both "which" props are identity-keyed — test recomposition

`selected_ids` (points, keyed by `ids`) and `trace_visibility` (traces, keyed by
trace `name`) are deliberately **identity-keyed, not positional**, so they
survive the data change that renumbers their target. The class of bug they guard
against only appears when the **trace composition changes** — a filter that
drops an entire group, so `gd.data` goes 3→2 traces and back. A positional value
would silently mis-target after the renumber; the identity-keyed value
re-resolves. So the load-bearing assertions (rows 23 and 26) must drive a filter
that *removes a whole group*, not just thins points within the existing traces —
the latter never exercises the renumber and a positional implementation would
pass it. Assert the key (names / id values) is unchanged across
filter→unfilter, and that the live `selectedpoints` / `visible` re-resolve to it
each time. Both also require their key on the spec (`ids` for points, `name` for
traces); a fixture missing it should hit the build-time validation error, which
is itself worth a row.

---

## 4. Making it a suite

### Layout

The suite lives in `tests/testthat/` like every other test — **nothing goes
under `dev/`, which holds design/plan docs only**:

```
tests/testthat/
  helper-e2e.R         e2e_app() (callr boot + port), e2e_session() (ChromoteSession),
                       eval_js(), drag(), console/exception + websocket capture,
                       teardown — the §2 boilerplate as reusable R helpers
  test-plotly-e2e.R    the §3 matrix as named testthat cases; expect_*() on the
                       readout/gd state; uses helper-e2e.R
  fixtures/
    kitchen-sink.R     test-owned app modeled on examples/plotly.R (rows 1–17, 22–26)
    subplot.R          row 18
    ggplotly.R         row 19
    gated.R            rows 20–21
```

`testthat::test_path("fixtures/...")` resolves the fixtures regardless of the
working directory, and `helper-*.R` files are auto-sourced by testthat before the
tests run. Everything is R now — no Node, no shell orchestration. `helper-e2e.R`
factors the §2 connection boilerplate (boot the app under `callr`, open a
`ChromoteSession`, `eval_js`, console/exception/websocket capture, drag) into
reusable helpers; `test-plotly-e2e.R` runs the §3 matrix as named `test_that()`
cases with ordinary
`expect_*()` assertions, so a failure reports the case name and the offending
value. The whole suite tears down its app and browser processes in a single
`withr::defer` / `on.exit` block.

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

This is a heavyweight, browser-dependent suite, but it stays a first-class
`tests/testthat/` citizen — the same place `shinytest2` and every other R e2e
suite lives — and earns its keep by **skipping**, not by hiding in a separate
tree. Each case opens with, in order:

```r
skip_on_cran()                                   # CRAN never boots a browser
skip_if_not_installed("chromote")
skip_if_not_installed("callr")
skip_if(is.null(chromote::find_chrome()))        # no browser present
```

`skip_on_cran()` is the load-bearing gate: CRAN sets `NOT_CRAN`, `testthat`
reads it, and the suite skips cleanly with nothing launched — the idiomatic R
mechanism, not a home-grown flag. The `skip_if_not_installed()` lines cover
machines without the browser stack; `chromote` and `callr` are `Suggests`, not
hard deps, so the default install stays lean. Optionally add a **local** opt-out
on top — `skip_if(Sys.getenv("IRID_E2E") != "1")` — so a routine
`devtools::test()` on a dev laptop doesn't spend ~30 s booting Chrome; this is a
convenience layer, not the CRAN guard (`skip_on_cran()` already is).

---

## 5. Why `chromote`, and the alternative

The original harness was a dependency-free Node/CDP script, written that way only
because nothing R-native was installable at the time. That is no longer true, so
the design above targets **`chromote`** directly. The reasoning, and the one
alternative still worth knowing:

- **`chromote`** *(chosen)* — R-native and a thin wrapper over the same CDP the
  Node script spoke, so the port is near-mechanical: `b$Runtime$evaluate(...)`
  replaces `evalJs`, `b$Input$dispatchMouseEvent` is the real-drag primitive
  verbatim, and the app runs in a background `callr` session. The whole suite
  stays in R with no Node toolchain — which is why it's the target.
- **`shinytest2`** *(alternative)* — gives app lifecycle + screenshot diffing for
  free, but its `get_value`/`set_inputs` model is DOM/input-centric; the plotly
  gestures still need raw `AppDriver$run_js(...)` calls equivalent to the
  `gd.emit` / `Plotly.relayout` primitives here, and the **real mouse drag** needs
  CDP `Input.dispatchMouseEvent` directly (`AppDriver` has no native drag) — which
  it can reach because it sits on `chromote` underneath. Reasonable if we later
  want its snapshot tooling; otherwise plain `chromote` is the smaller surface.

Across both, the three drive primitives (click-the-control; emit-the-plotly-event;
real mouse drag), the server-vs-client readout split, and the websocket-frame /
screenshot observability are unchanged — they are the design, not an artifact of
the transport. (The retired Node/CDP harness shared them too — the assertions in
§3 are the asset, not the client that runs them.) The one assertion that does
*not* port is screenshot **pixel-diffing** for plot content (SVG/canvas renders
vary by machine); keep plot assertions on `gd.layout`/`gd.data` state and reserve
screenshots for layout/visibility checks (row 22).

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
