# Irid Widget Implementation Log

**Date:** May 2026  
**Spec:** [irid-widget-spec.md](irid-widget-spec.md)

---

## Summary

Implemented all four slices of the widget mechanism. The implementation went
smoothly for Slices 1–3 (unit-tested via mock Shiny sessions). Slice 4 (the
CodeMirror example) revealed two subtle runtime bugs that only manifest in a
live browser with dynamically-inserted scripts.

---

## What was built

### Slice 1 — `irid.sendEvent()` JS primitive

**Files:** `inst/js/irid.js`, `tests/testthat/test-sendEvent.R`

Added `irid.sendEvent(elementId, eventName, payload)` to `irid.js`. It shares
the `sequences` counter and `sendPayload()` path with DOM events, so sequence-
based optimistic-update tracking and the stale-indicator mechanism work
identically for programmatic events.

22 tests covering payload construction, sequence incrementing, R-side handler
dispatch, force-send, and edge cases (null payload, unknown input).

### Slice 2 — Client-side init, channel, destroy handlers

**Files:** `inst/js/irid.js`, `tests/testthat/test-widget-client.R`

Added to `irid.js`:

- `irid.widgets` registry and `irid.registerWidget(name, initFn)`
- `deepEqual()` helper for nested-object comparison
- `Shiny.addCustomMessageHandler('irid-widget-init', …)` — dispatches to
  registered init function, queues if not yet registered
- `Shiny.addCustomMessageHandler('irid-widget-channel', …)` — dispatches
  `CustomEvent('irid-widget-channel')` with `detail.channel`, `detail.value`,
  `detail.isRender`
- `Shiny.addCustomMessageHandler('irid-widget-destroy', …)` — dispatches
  `CustomEvent('irid-widget-destroy')`
- `irid.trackChannel(el)` — per-element tracker with `recordSent()` /
  `receiveChannel()` for snap-back correction

76 tests (JS syntax, deep_equal algorithm, message contract shapes, widget
lifecycle ordering, TrackChannel state machine).

### Slice 3 — `IridWidget()` R-side constructor and mount wiring

**Files:** `R/irid_widget.R`, `R/process_tags.R`, `R/mount.R`,
`tests/testthat/test-widget-mount.R`

- `IridWidget(dep, container, ..., .config, .event, .render, .widget_name)`
  constructor in `R/irid_widget.R`
- `irid_widget` branch in `process_tags` walk function — splits named args
  into channels (reactive), events (`on*`), and static config
- Widget lifecycle in `irid_mount_processed` — init message, one `observe()`
  per reactive channel (with `isRender` flag for the render channel), destroy
  message on unmount

74 tests covering constructor validation, process_tags extraction, mount
messages, channel observers, destroy lifecycle, and end-to-end counter widget.

### Slice 4 — CodeMirror example

**Files:** `examples/codemirror/` (codemirror.js, codemirror.R, app.R),
`tests/testthat/test-widget-example.R`

A complete working example demonstrating the full pattern: htmlDependency,
irid.registerWidget, irid.sendEvent, IridWidget, reactive channels, event
handlers, and composition inside `When`.

33 tests (component construction, channel/event splitting, init/channel message
shapes, event dispatch, When lifecycle, JS syntax, multi-instance).

---

## Bugs found and fixed during Slice 4

### Bug 1: `htmlDependency` scripts stripped by `as.character()`

**Symptom:** Widget div is empty in the browser. No CodeMirror scripts appear
in the DOM. The `irid-widget-init` message is queued but the widget JS never
loads, so `irid.registerWidget` is never called, and the init is never
flushed.

**Root cause:** `htmltools::as.character()` on a `shiny.tag` strips all
`html_dependency` metadata — the output HTML contains no `<script>` or
`<link>` tags. Dependencies are metadata that Shiny's output pipeline
(`renderUI`, etc.) acts on, but irid's control flow (`When`/`Each`/`Match`)
bypasses that pipeline by sending raw HTML over custom messages
(`irid-swap`, `irid-mutate`). The `as.character(processed$tag)` calls at all
four serialization sites were silently discarding every dependency.

**Fix:** Added `render_tag_html()` helper in `R/mount.R` that calls
`htmltools::findDependencies()` + `htmltools::renderDependencies()` to
generate proper `<script>` / `<link>` tags, then prepends them to the tag
HTML. Applied at all four serialization sites:
- When observer (`irid-swap`)
- Each keyed inserts (`irid-mutate`)
- Each positional inserts (`irid-mutate`)
- Match observer (`irid-swap`)

### Bug 2: `irid-widget-init` races with widget script loading

**Symptom:** Even with scripts in the HTML, the widget never initializes.
The init message finds `irid.widgets['codemirror']` undefined and is silently
skipped. The widget JS registers later but the init message is already lost.

**Root cause:** `irid-widget-init` fires synchronously in the same Shiny
message batch as `irid-swap`, before the browser has loaded the widget JS
script. The init was a one-shot with no retry mechanism.

**Fix:** Added a deferred init queue in `irid.js`. When `irid-widget-init`
fires and the widget isn't registered yet, the init message is stored in
`irid._pendingInits`. When `irid.registerWidget()` is called (after the
script loads), it flushes any queued inits for that widget name.

### Bug 3: Mode scripts crash because they load before `codemirror.min.js`

**Symptom:** ReferenceErrors for `CodeMirror is not defined` in every mode
script (`javascript.min.js`, `python.min.js`, etc.), followed by a secondary
TypeError in `codemirror.min.js` itself (`can't access property "split", e is
null` in `setValue`).

**Root cause:** Dynamically-inserted `<script src="...">` tags via
`createContextualFragment` load and execute in arbitrary order, not document
order. The mode scripts all do `CodeMirror.defineMode(...)` at the top level,
requiring the `CodeMirror` global to exist. When they load before
`codemirror.min.js`, `CodeMirror` is undefined and they crash. The main
library then crashes too, likely because the mode failures leave internal
state inconsistent.

**Fix:** Combined all scripts into a single request using jsdelivr's
`combine` endpoint. The server concatenates `codemirror.min.js` + all mode
scripts in order into one response. One `<script>` tag, guaranteed execution
order. Used the `head` field of `htmlDependency` (raw HTML) to avoid URL
encoding issues with `@` and `,` in the combine URL.

### Bug 4: Codemirror content echo causes cursor jumping (mitigated)

**Symptom:** When the user types, the content channel echoes the value back
from the server and calls `editor.setValue()`, snapping the cursor.

**Root cause:** The `content` reactive channel observer fires whenever the
`code` reactiveVal changes, including when the change was initiated by the
user's own typing (via `onChange` handler).

**Fix:** Added two guards in the `irid-widget-channel` listener:
- Skip content updates while `editor.hasFocus()` (user is actively editing)
- Skip content updates that match `lastSentContent` (echo from our own
  `irid.sendEvent` call)

### Bug 5: Mode read from `msg.config` instead of `msg.channels`

**Symptom:** Initial editor mode is always `'javascript'` regardless of the
`language` reactiveVal (defaults to `'python'`).

**Root cause:** `mode` is passed as a reactive channel (`mode = language`),
so it appears in `msg.channels.mode`, not `msg.config.mode`. The init code
read `msg.config.mode`.

**Fix:** Changed to `msg.channels.mode || msg.config.mode || 'javascript'`.

---

## Key architectural insight

`htmltools::as.character()` strips `html_dependency` metadata from tags.
This is by design — Shiny's output pipeline processes dependencies
separately. But irid's control flow sends raw HTML over custom messages,
bypassing that pipeline. Every tag rendered to a string for `irid-swap` or
`irid-mutate` must have its dependencies manually rendered via
`renderDependencies()`. The `render_tag_html()` helper in `mount.R` exists
for this reason.
