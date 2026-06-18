# Widget deps through Shiny's native render pipeline (issue #34)

## Problem

Widget dependencies (a widget's `<script>`/`<link>` assets) currently reach the
browser two ways (see ARCHITECTURE.md *Widgets → Lifecycle and dependencies*):

1. **Per-mount**, on the `irid-widget-init` custom message — the client calls
   `Shiny.renderDependencies(msg.deps)`. Under **shinylive** this path **404s**
   for file-backed deps: shinylive's static serving is wired to Shiny's *native
   render pipeline*, not to a bare `renderDependencies` loaded off a custom
   message.
2. **Page-attached** at `process_tags` time — each widget's deps are
   `attachDependencies()`-ed onto its container so htmltools collects them into
   the page `<head>`. This rides the native pipeline, so it *is* served under
   shinylive — which is what makes file-backed widget deps load there today.

Page-attach has two costs:

- **Static-tree-only reach (the #34 known limitation).** `process_tags` only
  walks the static tree, so a widget that appears *only* inside `When` / `Each`
  / `Match` is behind a closure that isn't walked at render. Its deps are never
  page-attached, so under shinylive it loads **blank**. The current workaround
  is to render one static (hidden) instance to force the page-attach.
- **Script-ordering inversion.** Page-attach lands a widget's factory script
  (`<name>-irid.js`) in `<head>` *ahead of* `irid.js`, so `window.irid` may not
  exist when the factory runs. This forced the `window.iridPendingFactories`
  parking machinery (irid.js + the `defineIridWidget` helper in plotly-irid.js).

## Spike result (settles the premise)

`dev/spikes/renderui-deps-app/` — a plain-Shiny shinylive app that delivers the
**same file-backed dep two ways** mid-session and shows which script executed:

- **(A)** via `renderUI` (a uiOutput — native render pipeline)
- **(B)** via `sendCustomMessage` → `Shiny.renderDependencies` (the #34 side channel)

**Verdict: A green, B red** (run in a browser, 2026-06). A file-backed dep
delivered **mid-session through the native render pipeline (`renderUI`) loads
under shinylive**; the custom-message side channel 404s, as #34 says.

> Pinned: shinylive web assets **0.9.1**. This rides shinylive's runtime serving
> behavior — re-confirm with the spike on a shinylive bump.

**Why this unlocks a clean fix:** deps are *position-independent* — a
`<script>`/`<link>` lands in `<head>` regardless of where the widget's DOM goes.
So we can route deps through the native pipeline **without touching irid's
comment-anchor DOM model** (the expensive part of the "fundamental redesign" in
the issue). Only the dep delivery moves; widget content stays on the existing
`irid-mutate` / anchor path.

## Design

Deliver every widget's deps at **mount time** through the native render
pipeline, instead of page-attaching at render time. Mechanism: a **per-session
hidden `renderUI` sink** — the primitive the spike verified.

### The sink

Installed once per session, lazily, from `irid_mount_processed` (mount.R) —
guard on `session$userData` so the recursive control-flow mounts share one sink:

```r
install_widget_dep_sink <- function(session) {
  if (isTRUE(session$userData$irid_dep_sink)) return(invisible())
  session$userData$irid_dep_sink <- TRUE
  session$userData$irid_deps_seen <- shiny::reactiveVal(list())  # name -> html_dependency

  # Drop a hidden placeholder into the DOM. This insert carries a PLAIN element
  # (no file-backed dep), so it is shinylive-safe regardless of the side-channel
  # 404 — the deps themselves flow through the renderUI output below, which is
  # the verified native-pipeline path.
  shiny::insertUI("body", "beforeEnd",
    ui = shiny::tags$div(style = "display:none",
                         shiny::uiOutput("__irid_widget_deps__")),
    immediate = FALSE, session = session)

  session$output[["__irid_widget_deps__"]] <- shiny::renderUI(
    htmltools::tagList(unname(session$userData$irid_deps_seen()))
  )
}
```

> Note the split: `insertUI` is used only to place an empty placeholder element
> (plain HTML — its serving is not in question). The dependency `<script>`/
> `<link>` assets ride the `renderUI` output, which is exactly what the spike
> verified serves under shinylive. We are not betting on `insertUI` serving a
> file-backed dep.

### Feeding the sink

In `irid_mount_processed`, where widget init messages are sent, route each
widget's deps to the sink instead of page-attaching / shipping them on the init
message. Dedup by dep name so e.g. plotly.js is added once, not once per `Each`
item:

```r
install_widget_dep_sink(session)
seen <- session$userData$irid_deps_seen
cur  <- seen()
added <- FALSE
for (d in wi$deps) {
  if (is.null(cur[[d$name]])) { cur[[d$name]] <- d; added <- TRUE }
}
if (added) seen(cur)   # renderUI re-fires; Shiny ships only the new deps
```

- **Native pipeline → served under shinylive**, including for widgets that
  appear *only* inside `When`/`Each`/`Match`: `irid_mount_processed` is the same
  recursive chokepoint nested control-flow mounts call, so a dynamically mounted
  widget feeds its deps the moment it mounts. **This closes the #34 limitation.**
- **Uniform across entry modes** (`iridApp`, `iridOutput`/`renderIrid`) and
  nested mounts — the sink self-installs on first mount; no per-entry-point UI
  edits, no placeholder to thread through each entry point.
- The `reactiveVal` set *is* the dedup; Shiny additionally only sends deps it
  hasn't sent on the session, and the client dedups by name — so re-renders are
  cheap and idempotent.

### What this deletes

Because deps no longer page-attach, and the factory script now arrives via the
`renderUI` output **after** `irid.js` (which stays in the initial `<head>` as
`irid_dependency()`), the ordering inversion disappears and `window.irid` always
exists when a factory runs:

- **process_tags.R** — the page-attach block (the `attachDependencies(out,
  node$deps, append = TRUE)` at ~356-358) and its comment.
- **mount.R** — `deps` in the `irid-widget-init` message (no longer carried);
  the `register_widget_dep` call.
- **widget.R** — `register_widget_dep()` (the renderUI output pipeline does the
  resource registration). Drop if it has no other callers.
- **irid.js** — the `iridPendingFactories` drain block (~843-856) and the
  `Promise.resolve(Shiny.renderDependencies(msg.deps || [])).then(...)` wrapper
  in the `irid-widget-init` handler (deps no longer ride the init message);
  simplify to a direct `defined.get(name)` → mount / `pendingInits` park.
- **plotly-irid.js** — the `defineIridWidget` parking helper → call
  `irid.defineWidget("plotly", ...)` directly (CodeMirror already does).

The reverse race stays handled: an `irid-widget-init` arriving before its
factory script (now output-delivered) has executed still parks under
`pendingInits` and drains on `defineWidget`. The async-factory poll
(`await whenPlotly()`) still covers the library-global timing.

### Timing note (fold into ARCHITECTURE.md)

Deps now arrive on the **first flush** rather than in the initial HTML `<head>`,
and for a static widget that is slightly later than today. This is already
tolerated: the async-factory contract polls for its library global, and
`pendingInits` buffers an init that beats its factory. No new race.

## Alternatives considered

- **`insertUI` of the deps directly (cleaner, but unverified under shinylive).**
  `insertUI("body", "beforeEnd", tagList(deps))` at each mount needs no
  placeholder and no reactiveVal. The #34 note lists `insertUI` as native
  pipeline, but the spike only verified `renderUI`, and `insertUI` under
  shinylive could not be confirmed headlessly. A clean follow-up *once* a spike
  row confirms it serves a file-backed dep under shinylive: collapse the sink to
  a one-line `insertUI`. Not on the critical path — the `renderUI` sink ships on
  fully verified ground now.
- **Move widget *content* to the native pipeline (`insertUI`/outputs).** The
  issue's "fundamental redesign." Rejected: collides with irid's comment-anchor
  range model (ARCHITECTURE.md *Comment-Anchor Range Protocol*). Moving only the
  position-independent deps gets the shinylive win without that cost.

## Tests to update

- `tests/testthat/test-widget-deps.R` is built around `register_widget_dep`; if
  that function is removed, retarget these at the new sink delivery + the session
  dedup set (or delete what no longer applies).
- `tests/testthat/test-widget.R` covers the init message shape (deps field).
- Existing widget e2e (`test-widget-async-e2e.R`, `test-plotly-e2e.R`) should
  still pass — they run under plain Shiny, where both old and new paths serve.
  Add coverage for a widget mounted *only* inside control flow (the case #34
  could not serve), asserting its deps reach the page via the sink.

## Commit plan (one concept per commit, on a feature branch)

1. mount.R: install the per-session `renderUI` dep sink + feed it from
   `irid_mount_processed` with name-keyed dedup; stop carrying deps in the init
   message.
2. process_tags.R: drop page-attach.
3. irid.js + plotly-irid.js: drop `iridPendingFactories`; simplify the init
   handler; direct `defineWidget`.
4. widget.R: remove `register_widget_dep` if unused; update tests.
5. ARCHITECTURE.md: rewrite *Lifecycle and dependencies* (single native-pipeline
   delivery via the sink; first-flush timing note; 0.9.1 pin); drop the
   static-preload workaround and `plotly_dependency()` preload note.
