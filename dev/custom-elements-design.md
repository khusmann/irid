# Custom elements & non-standard events

**Status:** Proposed follow-on to the `wire` events model
([ARCHITECTURE.md](../ARCHITECTURE.md#two-phase-rendering)) — optional, undated
**Date:** June 2026

irid maps `on*` handler args to DOM events by stripping `on` and
lowercasing (`onCursorChanged` → `cursorchanged`), and hardcodes two-way
autobind for the `value`/`checked` IDL properties on standard form
elements. Both rules cover **standard events on standard HTML elements**.
Two gaps remain, both about reaching *beyond* that vocabulary:

- **Non-standard events on standard elements** — jQuery-plugin events,
  Stimulus, bubbled `CustomEvent`s, vendor-prefixed events. The
  strip-`on`/lowercase rule can't spell these.
- **Custom elements (Web Components)** — hyphen-named elements with their
  own event names, property-only rich values, and no universal autobind
  convention.

Both build on the `wire` events model ([ARCHITECTURE.md](../ARCHITECTURE.md)
— per-slot `wire` config, two-way-capable bound props); this doc adds
*vocabulary*, not new config machinery.

---

## 1. `on:` — verbatim event names

An `on:` prefix means "use the rest of this string verbatim as the event
name," bypassing the strip-`on`/lowercase rule:

```r
tags$div(
  `on:webkit-fullscreen-change` = handler,
  `on:library:custom.event`     = wire(handler2, wire_debounce(50))
)
```

Backticks are required for the colon (and any hyphen), which doubles as a
visual signal that the name is the literal wire form. The slot is an
ordinary `on*` slot, so it takes a bare handler or an `wire` exactly
like any other event.

This is strictly cleaner than the original sketch, which needed a parallel
`.timing = list(\`on:…\` = …)` keyed list to configure these — re-spelling
the verbatim name in a second place. Under the `wire` model, config rides
the slot, so the verbatim name appears exactly once.

`on:` is handler-only — it names an event to listen to. Two-way binding on
a standard element is the hardcoded `value`/`checked` autobind; *declared*
autobind on a custom element is `custom_tag()`'s job (§2).

---

## 2. `custom_tag()` — declaring a Web Component's vocabulary

Custom elements come from outside the platform's standard vocabulary:
their event names aren't derivable by camelCase transformation, they often
need rich values set as JS *properties* rather than HTML attributes, and
they have no universal autobind convention. Rather than guess,
`custom_tag()` asks the author to declare the element's vocabulary once:

```r
SlInput <- custom_tag(
  "sl-input",
  events     = c(onInput = "sl-input", onChange = "sl-change"),  # on*-arg → wire event name
  properties = c("value"),                                       # set as JS property, not attribute
  bind       = c(value = "onInput")                              # two-way: value, signaled by onInput
)

# Callers get plain-tag ergonomics with the element's vocabulary baked in:
SlInput(value = my_reactive, onChange = handle)
```

`custom_tag()` returns a function that behaves like a `tags$*`
constructor with the element's name, events, properties, and autobind
baked in. Three concerns:

### Event-name mapping (`events =`)

Maps each R `on*` arg to the element's real (non-standard) wire event
name. `onInput = "sl-input"` means an `onInput` arg registers a listener
for the `sl-input` `CustomEvent`. Handlers still take a bare function or
an `wire` per the `wire` model — including `dom_opts`, since a custom
element emits real (often cancelable) `CustomEvent`s, so `prevent_default`
/ `stop_propagation` / `capture` apply.

### Attribute vs. property (`properties =`)

Many Web Components can't accept rich values (arrays, objects) as HTML
attributes — they need JS properties set directly. `properties =`
declares which names are set as properties rather than attributes. (irid
already special-cases `value`/`disabled`/`checked`/`innerHTML` as
properties on the client; this extends that set per custom element.)

**Open:** the original sketch also proposed a per-instance `.prop` /
`.value` dot-prefix for ad-hoc property marking. That conflicts with
the `wire` model's removal of *all* dot-prefix element props. So per-instance
property marking wants a non-dot mechanism — likely a small wrapper
(`irid_prop(value)`) rather than a `.`-arg. Left open; the
element-type-level `properties =` declaration covers the common case.

### Declared autobind (`bind =`)

`bind = c(value = "onInput")` declares the **(prop, event) autobind
triple** that the platform hardcodes for `<input>`'s `value` ↔
`input`/`change`. Under the `wire` model, `value` becomes a two-way-capable
bound prop: the framework shows the reactive inbound and, on the declared
event (`onInput` → `sl-input`), reads the element's `value` property and
writes it back — with the same read-only snap-back and timing semantics as
DOM autobind.

So `custom_tag` is exactly **"DOM autobind, but you declare the triple the
platform doesn't know."** There is no synthesized `write_back` handler
(the original framing) — just a declared two-way prop, consistent with
the two-way widget props in ARCHITECTURE.md. A caller tunes its timing the
same way as any bound prop:
`SlInput(value = wire(my_reactive, wire_debounce(200)))`.

---

## 3. Ceremony levels

Three ways to reach non-trivial JS, by need:

| Need | Use |
|---|---|
| One-off non-standard event on a standard element | `` tags$div(`on:foo-bar` = handler) `` |
| Web Component — events + properties + autobind, no JS lifecycle | `custom_tag()` |
| Reactive props with init / update / destroy lifecycle | `IridWidget` (ARCHITECTURE.md) |

`custom_tag()` sits between the one-off escape and the full widget: it
bakes an element's vocabulary into a reusable constructor but owns no JS
lifecycle — the element's own implementation does that. When a component
needs irid-managed init/update/destroy, it's an `IridWidget` instead.

---

## 4. Open items

- **Per-instance property marking** (§2) — `irid_prop()` wrapper vs. some
  other non-dot mechanism, now that dot-prefix props are gone.
- **`bind` with a mismatched property name** — `bind = c(value =
  "onInput")` assumes the new value is read from the element's `value`
  property on that event. An element exposing it under a different
  property needs a richer declaration (e.g. `bind = list(value =
  list(on = "onInput", prop = "currentValue"))`). Defer until a real case.
- **Validation** — like the two-way widget-prop rework, vet against a real
  Web Component (e.g. a Shoelace input) before locking.
