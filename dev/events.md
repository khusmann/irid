# Events & bindings — `irid_wire`

**Status:** Proposed (supersedes `dom-events-design.md` and `listener-opts-design.md`)
**Date:** June 2026

A single per-slot config carrier, `irid_wire`, replaces the family of
element-level keyed lists (`.event`, `.timing`, `.listener`,
`.prevent_default`, `.filter`) and unifies how event handlers and value
bindings are configured across plain tags and widgets. One governing
rule keeps it simple: **a given event is bound *or* handled, never both**
(§4).

The DOM-event side (`irid_wire` on tags) is the firm, low-risk core. The
widget round-trip rework in §7 is the same model carried to widgets; it's
directionally settled but has only been reasoned against CodeMirror — see
§8.2.

Extending the vocabulary *beyond* standard HTML — the `on:` verbatim-event
escape and `custom_tag()` for Web Components — is a downstream follow-on,
specified separately in
[custom-elements-design.md](custom-elements-design.md).

---

## 1. The problem: parallel keyed lists per event

Today an event's configuration is spread across up to four surfaces on an
element — three of them **named lists re-keyed by the event name** (shown
with the current `event_*` / `.event` names):

```r
tags$div(
  onClick          = handler,                            # handler (slot)
  .event           = list(click = event_throttle(100)),  # timing       (keyed list)
  .prevent_default = list(click = TRUE),                 # listener flag (keyed list)
  .filter          = list(click = key_filter("Enter"))   # filter       (keyed list, proposed)
)
```

The handler registers once, under `onClick`; then the same event is
re-spelled three more times to attach timing, a listener flag, and a
filter. The two prior designs each patched one symptom — `dom-events`
flipped the timing list's keys to `on*`; `listener-opts` collapsed four
flat listener-flag props into one `.listener` keyed list. Both accept the
parallel-keyed-list structure. This design removes it: **config rides the
slot it configures, and the element-level keyed lists are deleted.**

---

## 2. `irid_wire` — the per-slot carrier

```r
irid_wire(
  subject  = NULL,   # handler OR reactive; the slot decides which (§3)
  timing   = NULL,   # an irid_* timing shape; NULL → per-event default
  coalesce = NULL,   # universal backpressure flag; NULL → derive from timing mode
  dom_opts = NULL    # irid_dom_opts(...), DOM-only (§6)
)
```

The timing constructors are renamed from `event_*` to `irid_*` and reduced
to **pure shapes** — `coalesce` is hoisted onto the carrier (it's
universal; the rest are mode-specific):

```r
irid_immediate()             # a marker — no args
irid_debounce(ms)
irid_throttle(ms, leading = TRUE)
```

The DOM-only listener flags + filter bundle into one constructor whose
name *is* their validation boundary:

```r
irid_dom_opts(
  prevent_default  = FALSE,
  stop_propagation = FALSE,
  capture          = FALSE,
  passive          = FALSE,
  filter           = NULL      # irid_key_filter("Enter") or a JS expression
)
```

Used across the four slots:

```r
tags$button(onClick = \() count(count() + 1))               # bare — default config (sugar)
tags$input(value    = irid_wire(query, irid_debounce(300))) # reactive subject, custom timing
tags$form(onSubmit  = irid_wire(submit, dom_opts = irid_dom_opts(prevent_default = TRUE)))
tags$input(
  value     = field,
  onKeyDown = irid_wire(\() add_todo(), dom_opts = irid_dom_opts(filter = irid_key_filter("Enter")))
)
```

Notes that drove the shape:

- **`coalesce` is hoisted, not in the shapes.** `ms`/`leading` are
  mode-specific and stay in `irid_throttle`/`irid_debounce`; `coalesce`
  applies to every mode, so it lives on the carrier. Its default derives
  from the timing mode (immediate→`FALSE`, throttle/debounce→`TRUE`), so
  `irid_wire(query, irid_debounce(200))` still coalesces by default.
- **`filter` lives inside `irid_dom_opts`, not next to `timing`.** It's
  DOM-only (needs an event object), so grouping by applicability keeps
  `irid_dom_opts` a single clean validation unit.
- **No element-level config props survive.** `.event`/`.timing`/
  `.listener`/`.prevent_default`/`.filter` are all gone.

---

## 3. Why one carrier serves handlers *and* bindings

A `reactiveVal` and a handler are both just R functions — you cannot tell
them apart by inspection. That is *already* why irid uses the **slot** to
assign meaning: bare `foo` means "bind" in `value =` and "handle" in
`onClick =`. So `irid_wire(foo, …)` is just "bare `foo` plus dispatch
config"; the slot does the same interpretation it already does for a bare
value. Handler-vs-reactive and one-way-vs-two-way are the slot's job, not
fields on the carrier.

The config (`timing`, `coalesce`, `dom_opts`) is *identical* for a handler
and a value binding — that's what justifies one type. The extra leg a
value binding has (server→client display) is handled by the binding
system, not the carrier.

This is also why the carrier takes the subject as a **plain first
argument** rather than a pipe target: a first arg accepts an inline lambda
(`irid_wire(\() submit(), …)`) and a reactive (`irid_wire(query, …)`)
uniformly. A pipe (`subject |> irid_debounce(300)`) reads well for bare
reactive names but breaks for inline-lambda handlers — `\() f() |> g()`
binds the pipe *inside* the lambda body, silently piping `f()`'s result
instead of the handler.

---

## 4. One channel per event — bound *or* handled

**A given DOM event is driven by a value binding *or* an explicit `on*`
handler, never both.** `value = rv` and `onInput = handler` on the same
`<input>` is an error, not a merge.

This is per-event, not per-element: `value = rv` claims the value
binding's events (`input` + `change`); other events on the same element
(`onKeyDown`, `onFocus`, …) are unaffected and coexist freely. The check
is "each DOM event is claimed by at most one of {autobind, explicit `on*`}."

### Why this loses nothing

Reacting to a change is normally done by **observing the bound reactive**,
not by an explicit handler. The only case that genuinely wants both is a
*synchronous* side-effect or validation on write — which is exactly what
`reactiveProxy(get, set)` is for: the `set` closure *is* a handler that
runs on the bound value's write. So three patterns cover the whole space,
and none needs both channels:

| need | use |
|---|---|
| controlled value, async reaction | `value = rv` + observe `rv()` |
| controlled value, sync side-effect / validation on write | `value = reactiveProxy(\() rv(), \(v) { …; rv(v) })` |
| raw event + custom logic | `on*` (write the reactive yourself in the handler) |

`reactiveProxy` is the bridge: a bound value whose write is a handler.

### Why it matters

This single rule deletes the most complex part of the event machinery:

- The autobind-vs-explicit **merge** on tags disappears (so `merge` no
  longer composes handlers — see §5).
- The "auto-bind synthetic runs before explicit `on*`" **ordering rule**
  disappears — no two handlers meet on one event.
- The **timing-collision** that would otherwise arise from two `irid_wire`
  on one listener cannot occur by construction.
- The per-binding force-send scoping is left doing real work only on the
  widget multi-event case it was designed for (§7), not on tags.

It's also the same principle §7 applies to widgets (a bound prop isn't
*also* handled — observe it or proxy it), so tags and widgets follow one
rule.

The cost, stated plainly: `value = rv` + `onInput = …` is supported today
(ARCHITECTURE.md). Callers of that pattern migrate to `reactiveProxy` —
wordier, but the semantically exact tool, and it removes the two-timings /
ordering footguns.

---

## 5. `merge` — override overlay (widget defaults)

With §4 in place, two handlers never meet, so `merge` is **not**
composition — it is a plain override-wins overlay, used only where a
widget wrapper layers a caller's input over its defaults (§7):

```r
merge(default, override)
```

- **override-wins per field** — `override`'s `subject` / `timing` /
  `coalesce` / `dom_opts` win when present; otherwise the default carries
  through. (The default carries only config, never a handler, so there is
  nothing to compose.)
- **`NULL` / bare-function override** normalizes first, so
  `merge(default, NULL)` is identity and `merge(default, \() …)` just
  fills in the handler.

`merge` extends the base S3 generic via `merge.irid_wire` — decided over
`irid_wire_merge` (which stutters with the `irid_wire()` it wraps) and
over `combine`/`overlay` (neither is a base generic, so each would force
irid to export a new generic and risk masking dplyr/Bioconductor).

A wrapper uses `merge` for any prop or event where it wants the caller to
be able to override its default timing — the CodeMirror example (§7) does
this for both `content` and `cursor-changed`: each merges the caller's
subject (the reactive / handler) over a wrapper-supplied default shape. A
wrapper that wants to *hardcode* timing can skip it and write
`irid_wire(subject, default_shape)` directly.

---

## 6. Validation: one type, container-checked

DOM-only-ness is a property of the **placement**, not the record: the same
`irid_wire(dom_opts = …)` is legal on a `<form>`, legal on a custom
element emitting cancelable events, and illegal on a widget `sendEvent()`
event — and whether `preventDefault` even works depends on the event
being cancelable, a runtime fact. The constructor can't know which, so a
second type couldn't soundly move the check earlier.

So: **one `irid_wire`, legality checked in the container** where
DOM-backed-ness is known.

- `process_tags` allows the full surface on tags, and enforces §4
  (one channel per event).
- `IridWidget()` errors if a `sendEvent()`-backed event carries `dom_opts`
  ("`prevent_default` needs a DOM listener").

`timing`/`coalesce` are universal (valid on widget-emitted events too), so
only `dom_opts` is gated.

---

## 7. Widgets — two-way props, uniform with DOM

The carrier is the same on widgets; the change is in how round-trips are
expressed, and it follows the §4 rule.

**Today** `IridWidget` props are one-way-in only, so a value round-trip
has to masquerade as an event — `write_back(content, "content")` builds a
handler that writes the `change` event's payload back through a reactive.
That conflates "the prop changed" (a *value*) with "an event fired."

**Proposed:** widget props are **two-way-capable by default, exactly like
DOM `value`/`checked`.** R always sets up the inbound-accept + snap-back
for a prop holding a reactive; whether it's *actually* two-way is decided
by whether the widget JS pushes through the prop channel (the client→server
partner of the existing `irid-attr target="widget"` update hook). So:

- `content = content` is two-way-capable (symmetric with `value = foo`).
- `content = irid_wire(content, irid_debounce(200))` wraps **only to
  tune** — never to "enable" — same meaning as on a DOM input.
- A bound prop is not *also* handled (§4); to react to its changes, the
  caller observes the reactive or passes a `reactiveProxy`.
- `events` carries only genuine notifications (a `cursor-changed` that
  corresponds to no prop), still configured with `irid_wire`.

```r
CodeMirror <- function(content, language = "javascript", theme = "dracula",
                       onCursorChanged = NULL) {
  IridWidget(
    name  = "codemirror",
    props = list(
      content  = merge(irid_wire(timing = irid_debounce(200)), content),  # two-way, caller-overridable timing
      language = language,                                                 # one-way in practice
      theme    = theme
    ),
    events = list(
      `cursor-changed` = merge(irid_wire(timing = irid_throttle(100)), onCursorChanged)
    ),
    deps = CodeMirrorDeps()
  )
}
```

### Client side

The factory contract grows a `setProp` callback, and `send` is renamed
`sendEvent` for symmetry — events are *sent*, props are *set*:

```js
irid.defineWidget("codemirror", function (el, props, sendEvent, setProp) {
  const view = new EditorView({ /* … */
    extensions: [ /* … */
      EditorView.updateListener.of(function (u) {
        if (u.docChanged)   setProp("content", u.state.doc.toString());  // two-way prop out
        if (u.selectionSet) sendEvent("cursor-changed", { line, ch });    // notification out
      })
    ]
  });
  return {
    update: function (key, value) {                           // prop in
      if (key === "content" && value !== view.state.doc.toString()) view.dispatch(/* … */);
    },
    destroy: function () { view.destroy(); }
  };
});
```

`setProp("content", …)` replaces the old `send("change", { content: … })`
— the round-trip is a prop now, not a fake event. `setProp` pushes through
the **same managed-state / sequence transport as `sendEvent`** (so
optimistic-update gating and echo-sequencing still apply), but to a
per-prop input `irid_prop_{id}_{key}`; irid auto-synthesizes the write-back
observer for each two-way-capable prop (gated by `can_accept_write`). This
`setProp` + `irid_prop_*` path is the **one genuinely new primitive** the
model adds — the symmetric partner of the existing server→client
`irid-attr target="widget"` → `update` hook. The old model avoided it by
routing round-trips through `send` + a wrapper-authored `write_back`; this
trades that per-widget boilerplate for one framework primitive.

This retires `write_back`, `widget_event`, `event_pick`, the `then`
argument, and the widget `onChange` callback. `can_accept_write` stays
internal (the synthesized write-back still gates on it). Read-only
snap-back is unchanged: a read-only reactive's write is dropped and the
force-send echoes the canonical value.

**Cost:** latent snap-back machinery on every prop even if the JS never
pushes it. It never fires unless pushed — cheap, and it buys full
DOM↔widget symmetry (no per-prop two-way marker, no overload of the
config carrier to mean "direction").

---

## 8. Decisions & open items

### Decided (with the alternatives rejected)

- **One channel per event** (§4) — bound *or* handled, never both;
  `reactiveProxy` bridges the rare both-case. Rejected: keeping the
  autobind+explicit merge (its ordering rule, timing-collision, and
  force-send scoping cost more than the convenience).
- **One carrier, not separate `irid_event` + `irid_bind`** — they'd share
  all config and differ only in subject/leg-count, which the slot already
  determines.
- **`irid_wire`, not `irid_event`/`irid_bind`/`irid_wire_opts`** — the
  first two lean one slot; `_opts` misreads the subject-carrying call as a
  bag (`irid_dom_opts` keeps `_opts` because it *is* a bag).
- **`irid_` is the config-family prefix; timing shapes are
  `irid_debounce`/`irid_throttle`/`irid_immediate`.** Bare
  `debounce`/`throttle` are generic (collision), so a prefix is earned;
  `irid_` is chosen over `event_` (overclaims — they're pure timing now
  that `coalesce` is hoisted, and they configure value bindings too) and
  over `timing_` (redundant — the mode words already self-describe — and
  it stutters with the `timing =` arg). This unifies
  `irid_wire`/`irid_debounce`/`irid_dom_opts` as one family. It's not a
  double-prefix (cf. the rejected `irid_event_throttle`); it *replaces*
  the group-prefix.
- **snake_case, not `iridWire`** — slot-config constructors are
  snake_case (the camelCase convention is for app functions like
  `iridApp`/`renderIrid`).
- **First-arg subject, not a `|> ` pipeline** — the pipe breaks on
  inline-lambda handlers (§3).
- **Timing is a *shape* passed to the carrier, not the carrier itself** —
  folding the subject into `irid_debounce(subject, …)` makes "default
  timing + `dom_opts`" inexpressible without clobbering the per-event
  default.
- **Two-way is a prop property, not an event/`write_back`** (§7).
- **`merge`, extending the base generic** (§5) — over `irid_wire_merge`
  (stutter) and `combine`/`overlay` (not base generics).
- **`irid_key_filter`, not `key_filter`** — the `filter`-expression
  generator joins the `irid_` config family; `key_filter` is a generic
  word, so the prefix is earned.
- **Widget JS: `sendEvent` + `setProp` (was `send`)** — two client→server
  callbacks named for what they push (events are *sent*, props are *set*).
  `setProp` + the per-prop `irid_prop_*` input is the one new framework
  primitive the two-way-prop model adds (§7).

### Open

1. **Two-way-prop cost** — latent snap-back on every prop (§7). Confirm
   acceptable vs. an explicit opt-in, ideally measured.
2. **Scope / validation.** The §7 widget rework has only been reasoned
   against CodeMirror. Validate against a second widget — ideally an
   atomic-render one (Plotly-class) — before locking, since its
   update/echo semantics differ.

---

## 9. Migration (0.3.0)

Greenfield — single breaking migration, one CHANGELOG entry.

**Tag side (firm):**

- [R/event.R](../R/event.R) — rename `event_*()` → `irid_*()` and drop
  `coalesce` from them (now pure timing shapes); add `irid_wire()`,
  `irid_dom_opts()`, `merge.irid_wire()` (override overlay).
- [R/process_tags.R](../R/process_tags.R) — remove `.event` /
  `.prevent_default` element-prop normalization; read config from the slot
  via `irid_wire`; **enforce one-channel-per-event** (error on
  `value`+`onInput`/`onChange` overlap) and **delete** the
  autobind/explicit merge path; lift `timing`/`coalesce`/`dom_opts` onto
  each event row.
- [R/mount.R](../R/mount.R) — carry the `dom_opts` flags + filter in the
  per-event `irid-events` payload.
- `inst/js/irid.js` — apply `stopPropagation`/`capture`/`passive`
  alongside `preventDefault`; evaluate `filter`, drop on falsy.

**Widget side (per §7, wants §8 open-item 2 validation first):**

- [R/widget.R](../R/widget.R) — retire `widget_event`; make props
  two-way-capable; auto-synthesize the per-prop write-back observer on the
  new `irid_prop_{id}_{key}` input; `IridWidget` validates `dom_opts` on
  `sendEvent()` events; keep `can_accept_write` internal; remove
  `write_back`/`then`.
- `inst/js/irid.js` — rename the factory's `send` → `sendEvent`; add a
  `setProp(key, value)` callback (4th factory arg) that pushes through the
  existing managed-state transport to the `irid_prop_*` input.
- [examples/codemirror.R](../examples/codemirror.R) — drop `event_pick`,
  `write_back`, `onChange`; the inline JS factory switches
  `send("change", …)` → `setProp("content", …)` and `send` → `sendEvent`.

**Docs:**

- [ARCHITECTURE.md](../ARCHITECTURE.md) — replace the `.event` /
  `.prevent_default` element-prop section and the autobind-merge
  paragraph; document the one-channel-per-event rule.
- [TESTING.md](../TESTING.md), [NEWS.md](../NEWS.md).

---

## 10. Test plan

**Tag side:**

- `onClick = \() …` (bare) ≡ `irid_wire(\() …)` with default config.
- `irid_wire(submit, dom_opts = irid_dom_opts(prevent_default = TRUE))`
  with no `timing` preserves the per-event default (no clobber).
- `irid_wire(dom_opts = irid_dom_opts(prevent_default = TRUE))` with no
  handler: client-only `preventDefault`, no round-trip.
- **`value = rv` + `onInput`/`onChange` on the same element errors;
  `value = rv` + `onKeyDown` is fine** (§4, per-event).
- `value = reactiveProxy(get, set)` runs `set` on each write (the
  both-case bridge), with timing/`dom_opts` honored.
- `dom_opts` on a widget `sendEvent()` event errors at the container.
- `filter = irid_key_filter("Enter")` drops non-Enter keydowns client-side.
- `merge`: override-wins per field; `merge(default, NULL)` identity;
  `merge(default, \() …)` fills in the handler.

**Widget side:**

- Prop two-way-capable by default; snap-back echoes via force-send when
  the JS pushes a server-rejected value; no echo cost when never pushed.
- `setProp(key, value)` writes the bound reactive via the `irid_prop_*`
  input (`can_accept_write`-gated); `sendEvent(event, payload)` routes to
  the event handler — both sequenced by the shared managed-state transport.
- `irid_wire(content, irid_debounce(200))` tunes the round-trip timing
  without enabling/disabling two-way.
- Read-only reactive on a two-way prop: write dropped, canonical value
  snapped back.
