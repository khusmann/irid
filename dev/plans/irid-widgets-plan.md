# irid widgets — implementation plan

Implementation plan for [`dev/irid-widget-design-v2.md`](../irid-widget-design-v2.md)
and its downstream consumer [`dev/plotly-output-design.md`](../plotly-output-design.md).

Three commits, in order:

1. **Framework** — `IridWidget`, helpers, wire protocol, JS runtime, tests.
2. **CodeMirror example** — first non-trivial consumer; vets the framework
   end-to-end against a real library.
3. **PlotlyOutput + plotly example** — second consumer; validates the
   substrate against a different shape of widget (data-driven render,
   multi-event fan-out, snap-back via `reactiveProxy`).

The CodeMirror commit is a separate landing because nothing in the framework
should be CodeMirror-specific — the split forces that contract. PlotlyOutput
is its own commit because it adds an exported R wrapper (`PlotlyOutput()`),
a new R-side file with a non-trivial translation table, and a `{plotly}`
suggested dependency; bundling it with the framework would muddy the
"framework knows nothing about specific libraries" boundary.

---

## Commit 1 — IridWidget framework

### R-side

**New file `R/widget.R`** — the constructor, the two helpers, and
`event_defaults()`.

- `IridWidget(name, props = list(), events = list(), deps = NULL,
  container = NULL, .event = NULL)` — returns an object with class
  `irid_widget` carrying everything the constructor needs to surrender to
  `process_tags`. The class tag is what `process_tags` dispatches on.
- `write_back(callable, field, then = NULL)` — handler factory exactly as
  specified in design §1 ("The two helpers"). Errors at construction if
  `callable` is not a function.
- `event_defaults(user, ...)` — caller `.event` > wrapper defaults > nothing.
  Three-tier resolution from design §1 ("Wrapper defaults"). Generic;
  plain-tag wrappers can use it too.
- `can_accept_write()` — already exists at [R/process_tags.R:44](../../R/process_tags.R#L44).
  Export it (add `@export` + roxygen) and move it to `R/widget.R` so the
  helpers and the framework predicate live next to one another. Anything
  in `process_tags.R` that still calls it picks up the export with no
  source change.

**Update `R/process_tags.R`**:

- Add an `irid_widget` branch in `walk()` (sibling of the existing
  `irid_output` / `irid_when` / `irid_each` / `irid_match` cases).
  The branch:
  1. Allocates a stable `id` (use `next_id()` if the user's container
     has none; honor user-supplied `id` like existing event paths do).
  2. Walks `node$props`: per-key dispatch on `is_irid_reactive()`
     (matches the existing rule — `is.function(x) && (identical(class(x),
     "function") || inherits(x, "reactive"))`). Callable → `bindings`
     with `attr = paste0("widget:", key)`, `fn = prop`. Non-callable →
     accumulated into `static_props`.
  3. Iterates `node$events`: each entry produces an `events` row with
     `source = "widget"`, the handler verbatim, the event name verbatim
     (lowercase kebab — no `on*` stripping). Timing comes from `.event`
     via the same lookup as DOM events, but the framework default for
     widget events is `event_immediate()` (no `input → debounce(200)`
     special case — that rule is DOM-tuned). Implementation: define
     `widget_default_for_event(event_name) { event_immediate() }` and
     call it from the widget branch where the DOM branch calls
     `default_for_event`. No threading needed — the branches already
     diverge on construct class.
  4. Appends one entry to a new top-level `widget_inits` list:
     `{id, name, prop_fns, static_props, deps}`. `prop_fns` is the
     named list of callable props (so mount can `isolate(fn())` them
     into the init message); `static_props` carries the literal
     non-callable values. **`static_props` shape contract:** these
     values are JSON-serialized into the init message, so widgets
     should accept scalars, vectors, lists, and named lists. Complex
     R objects (data frames, S4, environments) don't survive
     `jsonlite` cleanly — that's the wrapper author's problem to
     pre-serialize (e.g. PlotlyOutput's `to_plotly_spec` converts a
     plotly object to a JSON-clean list before it reaches the
     framework).
  5. Returns the user-supplied container (or `tags$div()`) with
     `attribs$id` set (honoring a user-supplied id, otherwise the
     auto-generated one — same posture as the existing event-element
     path) and `attribs[["data-irid-widget"]]` set to `name` (irid
     owns this attribute; if the user set it on the container, irid
     overwrites). Container children pass through unchanged.

- `process_tags`'s top-level return value gains a `$widget_inits` slot
  alongside `$bindings`, `$events`, `$control_flows`, `$shiny_outputs`,
  `$counter`.

- The existing `merge_pending_events` path is **not** touched —
  widget events live on their own per-element lookup keyed by event
  name, and the design explicitly calls out that name collisions
  between widget events and DOM events on the same container are
  author error.

- The "irid construct as attribute value" guard already errors on
  `irid_*` classes (line 414). `irid_widget` is a control-flow-class
  construct (lives as a child), so reaching that guard means the
  caller passed a widget as an attribute value — the existing error
  message handles it without modification.

**Update `R/mount.R`**:

- For each entry in `result$widget_inits`:
  1. Construct the init message by `isolate(fn())`-evaluating each
     entry in `prop_fns` and merging with `static_props` into one
     `props` object.
  2. Send `irid-widget-init` **after** the swap that introduced
     the container. For the top-level mount path (initial document)
     this is "right after the binding/event setup". For nested mounts
     inside `When` / `Each` / `Match`, the existing control-flow
     observer already sends `irid-swap` before recursing into
     `irid_mount_processed`, so the init message — sent from inside
     that recursive call — naturally arrives after the swap.
- The per-key `widget:<key>` observers fall out of the existing
  bindings path: a binding with `attr = "widget:content"` is
  observable identically to one with `attr = "value"`; the only
  change is `attr` is forwarded verbatim in the existing
  `irid-attr` message (no protocol change on the R side).
- Event entries with `source = "widget"` get `observeEvent` registered
  on the same `irid_ev_<id>_<event>` input pattern as DOM events;
  the only thing that changes is that the `irid-events` message
  forwards `source: "widget"` to the client so the client knows to
  skip `addEventListener`. Add `source = ev$source %||% "dom"` to
  the message-construction `lapply` so existing DOM events default
  cleanly.
- `irid-events` payload gains an optional `source` field.
- The force-send-on-no-op loop (`bindings_by_id[[source_id]]` echo
  in the event observer, [R/mount.R:86-94](../../R/mount.R#L86-L94)) is
  untouched and works for widget bindings out of the box — widget
  bindings join the same `bindings_by_id` table, snap-back is
  automatic per design §1 ("Read-only snap-back happens
  automatically").

**Deps hoisting**:

- `iridApp` and `renderIrid` already attach `irid_dependency()` to the
  top-level fragment. Extend that step to also collect deps from
  `widget_inits` discovered during `process_tags` and attach them
  alongside. Add a small helper `collect_widget_deps(processed)` in
  `R/widget.R` that flattens `processed$widget_inits[[i]]$deps`
  into a single list, drops `NULL` entries, and returns the result
  ready for `attachDependencies`. **Scope:** this only walks the
  top-level pass — control-flow bodies (`When` / `Each` / `Match`)
  aren't processed until their observer fires at mount time, so
  widgets that *only* appear inside those bodies have their deps
  shipped on the `irid-widget-init` message instead. That's by
  design; the init message always carries the deps anyway, so
  dynamic widgets are fully self-sufficient.
- For dynamic mounts (`When` / `Each` / `Match`), the client renders
  the message's deps via `Shiny.renderDependencies` (dedup is by
  name alone — a same-name dep with a different version is also
  skipped, which is harmless for the framework's use case).

**`NAMESPACE` updates** (regenerated via `devtools::document()`):
`IridWidget`, `write_back`, `event_defaults`, `can_accept_write`.

### JS-side

**Update `inst/js/irid.js`**:

- Expose a small `window.irid` object with two methods:
  - `defineWidget(name, factory)` — register, drain queue for `name`
    if any inits buffered.
  - `sendWidgetEvent(id, event, payload)` — look up `managed[inputId]`
    (where `inputId = "irid_ev_<id>_<event>"`); if absent, no-op
    (silent — design §3). If present, build a payload via the same
    path as DOM events (attach `id`, `nonce`, `__irid_seq` from
    `sequences[id]`) and call `s.maybeSend()` so throttle / debounce /
    coalesce / sequence / stale-indicator gating all apply uniformly.
    Factor `buildPayload`'s tail (id/nonce/seq attach) into a helper
    so widget and DOM paths share it without duplicating the
    sequence-counter logic.
- Add per-widget state map: `widgets = {}` — `id → {handle, name}`.
  `handle` is the `{update, destroy}` returned by the factory.
- Add `Shiny.addCustomMessageHandler('irid-widget-init', ...)`:
  1. If `widgets[id]` already exists, drop (idempotence — design §2
     "The init message is idempotent on the client").
  2. Load `msg.deps` via
     `Promise.resolve(Shiny.renderDependencies(msg.deps)).then(...)`.
     The probe (since deleted) showed the function returns
     `undefined` synchronously in current Shiny — `Promise.resolve`
     normalizes both that and the documented Promise-returning shape
     so the `.then` continuation works either way.
  3. After deps ready, look up `defined.get(msg.name)`. If absent,
     push `{id, props}` onto `pendingInits[msg.name]` keyed queue.
  4. If present, look up `document.getElementById(msg.id)`, call
     `factory(el, msg.props, send)` where `send = function (event,
     payload) { irid.sendWidgetEvent(msg.id, event, payload); }`.
     Store the returned `{update, destroy}` in `widgets[id]`.
- Update the `irid-attr` handler: if `msg.attr` starts with `widget:`,
  look up `widgets[msg.id]`, call `handle.update(key, msg.value,
  msg.sequence)` where `key = msg.attr.slice(7)`. Skip if no widget
  is registered (timing-dependent reorder where the update arrives
  before the init — buffer or drop; for now drop with no error,
  same posture as `document.getElementById(msg.id)` returning null).
- Update the `irid-events` handler: if `msg.source === "widget"`,
  initialize managed-state via the same `setupThrottle` / `setupDebounce` /
  `setupImmediate` paths but **skip the `el.addEventListener` step**.
  The cleanest implementation: lift the listener-attach call into a
  separate function `attachListener(el, msg, sendFn)`, and only call
  it from the DOM branch. The managed-state setup is identical.
- Update `detachRange` (and the swap handler's inline detach): walk
  the detached fragment for `[data-irid-widget]` elements; for each,
  look up `widgets[el.id]`, call `handle.destroy()` if present, and
  delete the entry. Do this **before** the existing
  `Shiny.unbindAll` call so `destroy()` runs while DOM ancestors
  are still intact.

**No changes to existing message types beyond additive fields** —
this is the entire wire-protocol delta. `irid-attr` gains the
`widget:*` attr shape (already structurally allowed); `irid-events`
gains an optional `source` field defaulting to `"dom"`; `irid-widget-init`
is the only new message.

### Tests

Add to `tests/testthat/`:

**`test-widget.R`** (new file, covers `process_tags` extraction):

- Widget node produces a `$widget_inits` entry with `{id, name,
  prop_fns, static_props, deps}`
- Callable prop keys become `$bindings` with `attr = "widget:<key>"`
- Non-callable prop keys produce no binding; their value rides in
  `static_props`
- Events become `$events` with `source = "widget"`
- Container `id` is auto-generated when not user-supplied; user `id`
  is honored
- `data-irid-widget = name` attribute is set on the output tag
- Mixed-shape `props` list (some callables, some not) is fully
  supported (per-key dispatch is independent)
- Container with DOM-event `on*` attrs (e.g. `tags$div(onClick = ...)`
  passed as `container`) still emits a `source = "dom"` event entry
  on the same element id — coexistence verified
- Widget event timing default is `event_immediate()` for every event
  name (no `input → debounce(200)` for widget surface)
- `.event` resolution: scalar broadcasts, named list overrides per
  event, wrapper-default tier passed via `event_defaults()` lands
  underneath the caller's tier
- Deps lifted off the widget node into `widget_inits` (and stripped
  from any `htmltools::attachDependencies` carrier on the node so
  they don't double-ship)

**`test-widget-helpers.R`** (new file, covers `can_accept_write`,
`write_back`, `event_defaults`):

- `can_accept_write` cases per design §6 ("Public helper")
- `write_back` cases per design §6 ("Public helper `write_back`"):
  writable + 1-arg `then`, writable + 0-arg `then`, writable + NULL
  `then`, read-only callable (write skipped, `then` still runs),
  non-callable in `callable` slot errors at construction, missing
  `field` in payload → `callable(NULL)`
- `event_defaults`: `user = NULL`, scalar config, named list merge,
  malformed `user` deferred to existing validation

**Manual / browser-tested** (no testthat — irid has no JS test
infrastructure today, by intent, so the client-side surface is
exercised through real-session browser checks. The checklist is
captured here):

- Widget inside `When` mounts on toggle (init message after swap;
  destroy via detach walker on toggle-off)
- Widget inside keyed `Each` survives reorder (no init re-send;
  `insertBefore` preserves identity)
- Widget inside positional `Each` survives same-length in-place
  updates (per-key updates via `irid-attr widget:*`)
- `irid-attr widget:<key>` routes to the widget's `update` hook
- `irid-events` with `source: "widget"` initializes managed state
  but skips `addEventListener`
- `irid.sendWidgetEvent` builds payload via the shared helper and
  pushes through `managed[inputId]`
- `detachRange` walks for `data-irid-widget` and invokes `destroy()`
  hooks before unbind
- `defineWidget` drains queued inits in arrival order
- Duplicate `irid-widget-init` for same id is a no-op

These need a real widget to drive — they get exercised by the
CodeMirror example in Commit 2 and the plotly example in Commit 3.

### Order of work within the commit

1. R-side: `write_back`, `event_defaults`, exported `can_accept_write`
   in `R/widget.R`. Tests for the helpers. No framework wiring yet.
2. R-side: `IridWidget` constructor stub (returns an `irid_widget`
   object). `process_tags` extension. Tests for `process_tags`
   extraction.
3. R-side: `irid_mount_processed` extension — `widget_inits` →
   `irid-widget-init` message, `widget:<key>` bindings, `source =
   "widget"` events. No client work yet; tests inspect message
   shape via a session stub.
4. R-side: deps hoisting into `iridApp` / `renderIrid`. Top-level
   `attachDependencies` collects from `widget_inits`.
5. JS-side: `defineWidget` / `sendWidgetEvent` / `irid-widget-init`
   handler / `widget:*` routing in `irid-attr` / `source: "widget"`
   in `irid-events` / detach walker for `data-irid-widget`.
6. `devtools::document()` to regenerate `NAMESPACE` for the new
   exports.

Commit message: `Widget impl: IridWidget framework — R + JS runtime`

---

## Commit 2 — CodeMirror example

The example proves the framework: a single library with init-only
options (`language`), live-updateable options (`theme`, `content`),
focus survival across keyed reorders, and assets shipped through
`deps`.

Per design §7 ("Built-in widgets shipped in the `irid` package —
out of scope. Widgets live in user packages or example dirs"), the
wrapper, JS factory, and demo all live in `examples/`.

### Single file: `examples/codemirror.R`

To keep the example self-contained — no vendored bundle, no
`inst/widgets/cm6/`, no separate JS file — the dependency is an
inline ES module that imports CodeMirror 6 from esm.sh and calls
`irid.defineWidget("codemirror", ...)` at module-load time. This
leans on `htmltools::htmlDependency`'s `head` arg to inject a
raw `<script type="module">` tag into `<head>`.

```r
# examples/codemirror.R

library(irid)

CodeMirrorDeps <- function() {
  htmltools::htmlDependency(
    name    = "codemirror",
    version = "6.0.1",
    src     = c(href = "https://esm.sh/"),
    head    = htmltools::HTML('
<script type="module">
  import {EditorView, basicSetup} from "https://esm.sh/codemirror@6";
  import {EditorState}            from "https://esm.sh/@codemirror/state@6";
  import {javascript}             from "https://esm.sh/@codemirror/lang-javascript@6";
  import {dracula}                from "https://esm.sh/thememirror@4";

  const LANGS = { javascript };  // r-lang is third-party; ship js for the demo

  window.irid.defineWidget("codemirror", function (el, props, send) {
    const view = new EditorView({
      parent: el,
      state: EditorState.create({
        doc: props.content,
        extensions: [
          basicSetup,
          (LANGS[props.language] || LANGS.javascript)(),
          props.theme === "dracula" ? dracula : [],
          EditorView.updateListener.of(function (u) {
            if (u.docChanged) {
              send("change", { content: u.state.doc.toString() });
            }
          })
        ]
      })
    });
    return {
      update: function (key, value, sequence) {
        if (key === "content") {
          const current = view.state.doc.toString();
          if (value === current) return;
          view.dispatch({
            changes: { from: 0, to: current.length, insert: value }
          });
        }
        // theme/language are init-only in this minimal demo — no branch
      },
      destroy: function () { view.destroy(); }
    };
  });
</script>')
  )
}

CodeMirror <- function(content, language = "javascript",
                       onChange = NULL, .event = NULL) {
  IridWidget(
    name   = "codemirror",
    props  = list(content = content, language = language),
    events = list(change = write_back(content, "content", then = onChange)),
    deps   = CodeMirrorDeps(),
    container = tags$div(
      class = "border rounded",
      style = "height: 300px; overflow: hidden;"
    ),
    .event = event_defaults(
      .event,
      change = event_debounce(200, coalesce = TRUE)
    )
  )
}

App <- function() {
  editor_open <- reactiveVal(TRUE)
  doc <- reactiveVal("// Hello, irid widgets!\nconsole.log('hi');\n")
  # ... toggle, label, When-gated editor, <pre> mirror, Reset button ...
}

iridApp(App)
```

The app body covers the round-trip surfaces enumerated in design §4
("What you should observe"):

- A toggle (`When`-gated editor) — exercises mount/teardown via the
  detach walker.
- A `<pre>` bound to `\() doc()` — visual confirmation that the
  round-trip lands.
- A character-count label fed by `\() nchar(doc())` — proves the
  reactive participates normally in the rest of the tree.
- A "Reset" button writing through `doc(...)` — programmatic update
  (no sequence) applies even with the editor focused.

### Notes on the CDN approach

- The registry queue (design §2 "Race answers") covers the order-of-
  events case where `irid-widget-init` arrives before the ES module
  finishes loading. The init buffers under `"codemirror"` and drains
  when the module's `irid.defineWidget("codemirror", ...)` call lands.
- `Shiny.renderDependencies` dedups by name, so re-firing
  `irid-widget-init` after a `When` toggle is a no-op for the deps
  step — the module script tag stays in `<head>` and the browser
  uses its module cache.
- Offline / air-gapped runs of the example won't work — fine for a
  demo, not viable for CI fixtures. If we later want a fixtured
  version, switch to a vendored bundle in `inst/widgets/cm6/`; the
  R-side wrapper signature stays the same.
- The R-string heredoc holds ~40 lines of JS. Readable but not
  beautiful; the trade is one file vs. three.

### Order of work within the commit

1. Write `examples/codemirror.R` end-to-end (deps fn with inline
   module script, wrapper, app).
2. Smoke-test in a real browser:
   - Load the app; the editor materializes after the ES module
     finishes loading.
   - Type — the `<pre>` updates after the 200ms debounce.
   - Toggle the editor off and on — the editor remounts with
     the preserved `doc()` content (cursor / undo gone, per design).
   - Click Reset — the editor's contents replace.
   - DevTools Network: one fetch per esm.sh import per session
     (browser module cache).

Commit message: `Widget example: CodeMirror via inline ES module from esm.sh`

---

## Commit 3 — PlotlyOutput + plotly example

PlotlyOutput is shipped from irid core (per `plotly-output-design.md`
§2 "Lives in irid core as a suggested dependency on `{plotly}`"),
which differs from CodeMirror's "user-package" status. It validates
the framework against:

- a wrapper whose `.event` defaults span several event names
  (`relayout` throttled, `click` immediate, etc.)
- multi-write event handlers (the relayout fan-out — design §6
  "Event handlers — the relayout fan-out")
- snap-back via `reactiveProxy` + force-send-on-no-op
- a deps source that comes from a *Suggested* package (`{plotly}`)
  rather than a vendored asset

### R-side

**New file `R/plotly.R`** containing:

- `plotly_dependency()` — pulls the htmlDependency from `{plotly}`
  (sources its bundled `plotly.js`). Errors at call time with a clear
  message if `{plotly}` is not installed (matches the design doc's
  "wrapper errors at construction time if `{plotly}` isn't installed").
- `PLOTLY_TRANSLATION_TABLE` — the named arg ↔ spec path ↔ source
  event table from design §7. Launch-scope entries only.
- `to_plotly_spec(x)` — converts a plotly object to the JSON spec the
  client expects. `plotly::plotly_build(x)$x[c("data", "layout")]`
  is the canonical path; wrap in a small adapter.
- `extract_from_payload(e, path)` — dot-notation lookup for the
  relayout fan-out (`e[["xaxis.range"]]` style).
- `build_event_handlers(state, ...)` — builds the `events` list for
  `IridWidget` per design §6.
- `PlotlyOutput(spec, ..., on* = NULL, onRelayout = NULL,
  .event = NULL)` — the exported wrapper.

Validations:
- Unknown names in `...` (not in `PLOTLY_TRANSLATION_TABLE`) error
  at construction with a list of valid names.
- `spec` must be a function (callable). Constant specs error at
  construction with "pass `\() plot_ly(...)` so the spec re-evaluates
  when its reactives change".

**`DESCRIPTION`**: add `plotly` to `Suggests`.

**`NAMESPACE`** (regenerated): export `PlotlyOutput`.

### JS-side

**New file `inst/widgets/plotly/plotly-irid.js`**:

- `irid.defineWidget("plotly", factory)` per design §6 ("JS side").
- The `settling` flag mechanism for user-vs-spec relayout
  distinction (design §5).
- Per-key `update` switch including the special-case for `key ===
  "spec"` (full `Plotly.react` re-render) and the `value == null →
  defer to spec` path.
- `destroy: Plotly.purge(el)`.

The plotly.js library itself is loaded via `plotly_dependency()`
(from `{plotly}`); only `plotly-irid.js` is irid-owned.

### Example

**`examples/plotly.R`** — covers the scenarios named in
`plotly-output-design.md`:

- Basic usage with reactive data (the `FilteredScatter` from §4
  "Basic usage"; slider controls point count, zoom stays).
- Bound `xaxis_range` + `yaxis_range` reactives with a `<pre>`
  display of the current range so the round-trip is visible.
- `onClick` callback that logs the clicked point's coordinates.
- A "Reset zoom" button that writes `NULL` into the range reactives
  (defer-to-spec path).
- A `reactiveProxy` gating zooms narrower than 1 unit (snap-back
  via force-send-on-no-op — design §6 "Snap-back is automatic").

### Tests

**`test-plotly.R`** (new file):

- `PlotlyOutput()` produces an `irid_widget` object with `name =
  "plotly"` (just checks the wrapper compiles, doesn't run plotly).
- Unknown named arg errors with the table-validity message.
- Constant `spec` errors with the "pass a function" message.
- `extract_from_payload` correctly resolves dot-notation
  (`"layout.xaxis.range"` → `e[["xaxis.range"]]`).
- `build_event_handlers` produces an `events` list whose `relayout`
  entry fans out to every named-arg writable callable.
- `event_defaults` integration: wrapper's per-event defaults
  (`relayout = throttle, click = immediate, ...`) land when caller
  passes nothing; caller scalar overrides everywhere; caller
  named-list overrides per event.

Heavy JS-side integration (`Plotly.react` settling, snap-back
correctness) is exercised manually via the example. The wrapper's
load-bearing assumptions on the framework are listed in
`plotly-output-design.md` §10 — that section is the regression
checklist if `IridWidget` changes later.

### Order of work within the commit

1. `R/plotly.R` — `PLOTLY_TRANSLATION_TABLE`, helpers, wrapper. Tests.
2. `inst/widgets/plotly/plotly-irid.js` — JS factory.
3. `examples/plotly.R` — the example app.
4. Manual smoke-test: drag-select for `selected_points`, zoom for
   `xaxis_range`, change data via slider (zoom preserved via
   `uirevision`), click "Reset zoom" (defer-to-spec re-evaluates
   the auto-fit), engage the gated proxy (snap-back observed).
5. `devtools::document()` for the `PlotlyOutput` export.

Commit message: `PlotlyOutput: plotly.js wrapper on IridWidget substrate, with example`

---

## Out of scope for this work

These are called out in the design docs and stay out of scope here:

- **Custom DOM event surface on `tags$*`** — see
  [`custom-dom-events-design.md`](../custom-dom-events-design.md).
  Independent project; widgets don't depend on it.
- **`shiny#4372` subdomain scope swap** — Each/Match scope teardown
  for widget mounts goes through the same `make_scope`-based shim
  every other irid mount uses today.
- **Built-in widgets in the `irid` package** other than
  `PlotlyOutput` (which is justified by being the dominant
  charting library and the regression check on `IridWidget`'s
  contract). CodeMirror lives in `examples/`.
- **Widget-to-widget client-side messaging.** Widgets compose via
  shared R-side reactives.
- **Server-side widget rendering** (htmlwidgets-style static
  knitr output). Always client-rendered.

## Risk notes

- **`Shiny.renderDependencies` availability.** Verified empirically:
  the JS function is callable from a custom message handler, accepts
  the JSON shape `htmltools::htmlDependency()` produces directly (no
  server-side preprocessing needed), and dedups by name so re-firing
  `irid-widget-init` on every remount is safe. The inline
  `<script type="module">` head-arg trick (CodeMirror example) also
  works through it. One quirk: dedup is by name alone, not
  name+version — a bumped version on the same name will be silently
  skipped. Widgets shouldn't version-bump mid-session, so this is
  fine.

- **Top-level mount and dynamic mount take different deps paths.**
  Top-level: deps attached to the HTML via `attachDependencies`,
  loaded by the browser as part of the initial document.
  Dynamic: deps ride the `irid-widget-init` message, loaded by
  `Shiny.renderDependencies`. The init message *always* ships the
  deps regardless of mount path — for top-level mounts this is a
  no-op (dedup), and it removes a special case from the client
  handler ("did this widget come from the initial HTML or a swap?
  doesn't matter — the deps are always in the init message").

- **Async `<script>` load order vs init message.** The registry
  queue (design §2 "Race answers") handles this; the test plan
  covers `defineWidget` draining the queue on arrival. The risk is
  bugs in the queue rather than the design.
