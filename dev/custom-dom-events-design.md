# Custom DOM events — design

**Status:** Proposed
**Date:** May 2026

---

## 1. Motivation

irid currently maps `tags$*(on*)` event handlers to DOM event types by
lowercasing-no-separator: `onClick` → `click`, `onMouseDown` →
`mousedown`. The rule matches React's transformation for standard DOM
events and works perfectly for the platform's event vocabulary.

But the modern web increasingly uses **kebab-case** event names for
*custom* events:

- **Web Components** emit `new CustomEvent("value-changed", {detail: ...})`
  by convention. Examples: Shoelace's `sl-change` / `sl-input`,
  Material Web's various event names, Lit-based components, Spectrum.
- **Third-party JS libraries** (dialog libraries, drawer libraries,
  copy-to-clipboard libraries, modals, drag handles) often fire kebab
  events on their root element.
- `IridWidget` already uses a kebab convention for *widget* events
  (which travel through a separate `source: "widget"` channel — see
  [ARCHITECTURE.md](../ARCHITECTURE.md#widgets)). Standard DOM events
  on regular tags need to follow suit so the two surfaces are aligned.

Without a kebab-aware transformation, a user wanting to listen to
`<sl-select>` from irid has no clean way:

```r
# Today — broken. `slchange` doesn't fire; Shoelace emits `sl-change`.
tags$"sl-select"(
  onSlChange = \(e) selected(e$value)
)
```

This doc specifies a small addition to irid's DOM event surface that
keeps standard DOM event spelling intuitive while making custom events
reachable. The unlock is large: a huge swath of the Web Components
ecosystem becomes usable as "drop-in HTML" inside irid, with no
`IridWidget` ceremony.

---

## 2. Design

### Transformation rule — lookup-with-kebab-fallback

`tags$*` event arguments named `on*` are transformed to DOM event types
via:

1. Strip the leading `on`.
2. Lowercase the remainder.
3. **If the lowercased form matches a name in irid's static
   standard-DOM-events table (§3), use it verbatim.** *(No-separator form.)*
4. **Otherwise**, derive a kebab form from the *original camelCase*
   boundaries: split on each transition from lowercase to uppercase,
   lowercase each piece, join with `-`. *(Kebab fallback.)*

Worked examples:

| R-side arg | Lowercased | In table? | Wire name |
|---|---|---|---|
| `onClick` | `click` | yes | `click` |
| `onMouseDown` | `mousedown` | yes | `mousedown` |
| `onKeyDown` | `keydown` | yes | `keydown` |
| `onDoubleClick` | `doubleclick` | yes (special-case rename) | `dblclick` |
| `onScroll` | `scroll` | yes | `scroll` |
| `onCursorChanged` | `cursorchanged` | no | `cursor-changed` |
| `onSlChange` | `slchange` | no | `sl-change` |
| `onValueChanged` | `valuechanged` | no | `value-changed` |
| `onValueCommit` | `valuecommit` | no | `value-commit` |

Key property: **standard DOM events use React-intuitive camelCase
spelling, and custom events use the same camelCase spelling** — the
transformation chooses the right wire form automatically based on the
static table. The user never has to know which category an event falls
into; they just write `onWhatever` and the rule sorts it out.

### Acronym handling

Kebab fallback treats **consecutive uppercase letters as a single
word**:

| R-side arg | Wire name |
|---|---|
| `onURLChange` | `url-change` (not `u-r-l-change`) |
| `onAPICall` | `api-call` |
| `onHTMLParsed` | `html-parsed` |

This matches Lodash's `kebabCase`, Vue's prop transformation, and the
broad ecosystem of camelCase-to-kebab utilities.

### Escape hatch — raw event names via `on:`

For events whose names can't be expressed in camelCase (colons, dots,
vendor prefixes, library-namespaced events), users pass the literal
name with an `on:` prefix:

```r
tags$div(
  `on:webkit-fullscreen-change` = handler,
  `on:library:custom.event`     = handler2
)
```

The `on:` prefix signals "use the rest of this string verbatim as the
event type — don't transform." Handles:

- Vendor-prefixed events: `webkitfullscreenchange`, `MSPointerDown`
- Library-namespaced events with non-letter separators
- Custom events whose authors broke convention (`MyOddName`,
  `eventWith_underscore`)

The escape hatch is opt-in and explicit; the implicit camelCase mapping
covers the common cases. Backticks are required in R for any arg name
containing a colon, which doubles as a visual signal that the name is
not a normal `on*` arg.

---

## 3. The standard-DOM-events table

irid maintains a static list of standard DOM event types, derived from
W3C and WHATWG specs. **Only entries in this table get no-separator
form**; everything else falls back to kebab.

### Categories (illustrative — actual list maintained in code)

- **Mouse**: `click`, `dblclick`, `mousedown`, `mouseup`, `mouseover`,
  `mouseout`, `mousemove`, `mouseenter`, `mouseleave`, `contextmenu`,
  `wheel`
- **Keyboard**: `keydown`, `keyup`, `keypress`
- **Form**: `change`, `input`, `submit`, `reset`, `invalid`, `formdata`,
  `select`
- **Focus**: `focus`, `blur`, `focusin`, `focusout`
- **Window/document**: `load`, `unload`, `beforeunload`, `error`,
  `resize`, `scroll`, `hashchange`, `popstate`, `pageshow`, `pagehide`,
  `readystatechange`, `DOMContentLoaded`
- **Drag and drop**: `drag`, `dragstart`, `dragend`, `dragover`,
  `dragenter`, `dragleave`, `drop`
- **Touch**: `touchstart`, `touchend`, `touchmove`, `touchcancel`
- **Pointer**: `pointerdown`, `pointerup`, `pointermove`, `pointerover`,
  `pointerout`, `pointerenter`, `pointerleave`, `pointercancel`,
  `gotpointercapture`, `lostpointercapture`
- **CSS animations/transitions**: `animationstart`, `animationend`,
  `animationiteration`, `animationcancel`, `transitionstart`,
  `transitionend`, `transitionrun`, `transitioncancel`
- **Media**: `play`, `pause`, `ended`, `volumechange`, `loadeddata`,
  `loadedmetadata`, `canplay`, `canplaythrough`, `timeupdate`,
  `durationchange`, `playing`, `waiting`, `seeking`, `seeked`,
  `stalled`, `ratechange`, `progress`
- **Clipboard**: `copy`, `cut`, `paste`
- **Network**: `online`, `offline`
- **Storage**: `storage`

### Special-case renames

A handful of standard events don't follow a clean camelCase-to-lowercase
mirror. The table stores explicit mappings for these:

| R-side arg | Wire name |
|---|---|
| `onDoubleClick` | `dblclick` |

(Add as needed — keep the list short.)

### Adding to the table

When the DOM gains a new standard event:

- Adding the entry is backwards-compatible *if* no user had already been
  relying on the kebab fallback for that event name. (E.g. if some
  custom widget happened to dispatch `value-change` and a user wired
  `onValueChange`, that user was previously getting `value-change` via
  kebab. If `value-change` later becomes a standard W3C event and we
  add it to the table — now they get `valuechange` instead. This is a
  potential breakage that the release notes need to flag.)
- Document migrations in CHANGELOG when adding entries.

---

## 4. Implications and edge cases

### Conflict between standard and custom names

If a custom element dispatches `CustomEvent("click")` for some reason,
the `onClick` handler receives both the native click and the custom
click — same as raw `addEventListener("click", ...)`. This is a DOM-level
concern, not an irid concern.

### Listener attachment unchanged

irid's DOM-event mount path already calls `addEventListener(type, ...)`.
The only change is the *value of `type`* passed in — from "stripped
and lowercased" to "lookup-then-fallback." No change to throttle /
debounce / coalesce / sequence / stale-indicator gating, payload
shape, or the `event_obj` cleaning (`__irid_seq` / `id` / `nonce`
stripped).

### Symmetry with widget events

After this change, the wire convention is **uniform across both event
surfaces**:

| Surface | Single-word wire name | Multi-word wire name |
|---|---|---|
| Standard DOM event | platform form (e.g. `click`) | platform form (e.g. `mousedown`) |
| Custom DOM event | kebab (e.g. `change`) | kebab (e.g. `cursor-changed`) |
| Widget event | kebab (e.g. `change`) | kebab (e.g. `cursor-changed`) |

R-side users always write camelCase `on*`. The transformation picks the
right wire form. The only difference between "custom DOM event" and
"widget event" from the R-side author's perspective is whether the
event is registered via `tags$*(on* = ...)` (rides standard DOM
addEventListener) or via `IridWidget(events = list(...))` (rides irid's
managed `send()` channel).

### Mixed-case in arguments

Standard R names allow uppercase letters in arg names without
backticks. `onMouseDown`, `onCursorChanged`, `onURLChange` all work
unquoted. The escape hatch `on:foo` requires backticks because of the
colon — the friction is intentional (visually flags the verbatim path).

---

## 5. Relationship to Web Components

This change unlocks Web Components as "drop-in HTML" inside irid. A
Shoelace example:

```r
library(irid)

App <- function() {
  selected <- reactiveVal("apple")

  page_fluid(
    tags$"sl-select"(
      value      = selected,
      onSlChange = \(e) selected(e$value),
      onSlInput  = \(e) draft(e$value),
      tags$"sl-option"(value = "apple",  "Apple"),
      tags$"sl-option"(value = "banana", "Banana"),
      tags$"sl-option"(value = "cherry", "Cherry")
    ),
    tags$p(\() paste("Selected:", selected()))
  )
}
```

The `onSlChange` → `sl-change` mapping just works. No widget
registration, no JS factory, no `IridWidget` wrapper — the custom
element is just an HTML element that happens to dispatch kebab events.

### Two ceremony levels for JS interop

| Need | Use |
|---|---|
| Just listen to events from a Web Component or third-party JS root element | `tags$*(on* = ...)` — this design |
| Reactive props, init/update/destroy lifecycle, deps hoisting, focused-mount survival | `IridWidget` — see [ARCHITECTURE.md](../ARCHITECTURE.md#widgets) |

The two paths compose: a Web Component used inside an `IridWidget`
container's `container` slot is fine. Pick the lowest ceremony that
covers what you need.

### Web Component property binding — out of scope here

This doc covers *event listening*. Setting *properties* (vs *attributes*)
on a Web Component — many web component APIs require setting `value`,
`checked`, `selected`, or richer-typed properties as JS properties
rather than HTML attributes — is a separate concern not addressed here.
The current `tags$*` machinery serializes everything via attributes,
which is fine for many cases but not all. A property-binding mechanism
(e.g. `.prop` prefix or a small helper) may follow as a separate
design.

---

## 6. Non-goals

- **Property vs attribute binding** for Web Components — separate
  problem.
- **Web Component lifecycle hooks** (`connectedCallback` /
  `disconnectedCallback`) beyond what irid's `When`/`Each`/`Match`
  teardown already provides.
- **Slot management** — already supported by children passthrough in
  `tags$*`.
- **Form association** for Web Components participating in `<form>`
  via `ElementInternals` — not specifically supported by this change.
- **A reusable web-component helper wrapper.** Could come later;
  unnecessary for the event surface fix.
- **Built-in shorthand for popular component libraries** (Shoelace,
  Material). User packages can ship `Sl*` constructors if they want;
  irid stays library-neutral.

---

## 7. Test plan

- `onClick` → `click` (single-word standard)
- `onMouseDown` → `mousedown` (multi-word standard, lookup hit)
- `onDoubleClick` → `dblclick` (special-case rename in table)
- `onCursorChanged` → `cursor-changed` (multi-word, kebab fallback)
- `onSlChange` → `sl-change` (short-prefix custom)
- `onValueChanged` → `value-changed` (Web-Components-style)
- `onURLChange` → `url-change` (acronym handling — consecutive
  uppercase as one word)
- `` `on:webkit-fullscreen-change` `` → `webkit-fullscreen-change`
  (escape hatch)
- `` `on:library:custom.event` `` → `library:custom.event` (escape
  hatch with non-letter separators)
- Adding a new entry to the table preserves backwards compatibility
  for users who weren't relying on the kebab fallback for that name;
  CHANGELOG flags migrations otherwise.

---

## 8. Open questions

- **`onDoubleClick` as a special case.** React provides it as an
  alias for the platform's `dblclick`. Irid could either include it
  (one table entry) or require users to write `onDblClick` (which
  lowercases to `dblclick`, hits the table cleanly without a rename).
  Suggest: include `onDoubleClick` for React-familiar users; cost is
  one entry.
- **Vendor-prefixed events** (`webkit*`, `MS*`). Are any in
  common-enough modern use to warrant table entries, or is the escape
  hatch sufficient? Suggest: escape hatch only — vendor prefixes are
  dying.
- **Standard-events table format.** Pure data file generated from W3C
  lists, or a versioned R constant? Suggest: data file, regenerated
  per release with manual additions for special-case renames.
- **Should the escape hatch use `on:` or some other prefix?**
  Alternatives: `.on = list("event-name" = handler)`, `raw_on()`,
  attribute-style `data-on-event-name`. `on:` keeps the `on*` family
  visually together and uses a syntactically meaningful character to
  signal verbatim.
- **Aliasing.** Should we offer a small helper for "this `on*` arg
  binds the wire name X" so library authors can document their
  preferred camelCase spelling? Probably not — too much machinery for
  a one-off naming preference. The kebab fallback already gives
  authors latitude.
