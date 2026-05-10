# Auto-bind + `.event` element config

First merge into the `dev` branch toward landing the reactive-system
design. Combines what was originally drafted as two separate phases
because they share a code path and a migration step.

## Goal

State-binding props on a `shiny.tag` accept a callable and automatically
two-way bind: the callable's read populates the prop, and DOM events on
the element write back through the same callable. The user never has to
write an `onInput` handler just to keep state in sync. Explicit `on*`
handlers remain available for discrete actions and run orthogonally.

In the same PR, lift event timing and transport off per-handler wrappers
and onto the element: `.event` configures debounce/throttle/immediate for
**all** events on that element (auto-bind write-back + explicit handlers),
and `.prevent_default` controls `event.preventDefault()` on dispatch.

The two pieces ship together because (1) `.event` resolution depends on
knowing which events were synthesised by auto-bind so the right default
fires, and (2) examples migrate exactly once.

## Scope

In:
- `value`, `checked`, `selected` accept a callable in addition to a literal.
- Read path (server → client): emit `irid-attr` on reactive change.
- Write path (client → server): bind the corresponding DOM event, deliver
  the value to the server, call `fn(value)` automatically.
- Arity-based dispatch on the callable:
  - `length(formals(fn)) == 0` (e.g. `\() expr()`) → read-only; the server
    never writes back, the optimistic-update protocol snaps the input back.
  - `length(formals(fn)) >= 1` (`reactiveVal`, store leaf, `reactiveProxy`,
    branch) → both read and write.
- Orthogonality with `on*` handlers — providing `onInput` does not disable
  auto-bind. Both fire on the same DOM event.
- `.event` element prop, accepting either:
  - A single config struct (`event_debounce(ms)`, `event_throttle(ms, leading)`,
    or `event_immediate()`) — applies to every event on the element.
  - A named list keyed by DOM event name (e.g.
    `list(input = event_debounce(500), keydown = event_immediate())`) — per-event
    override. Events not in the list fall back to the per-event default rule.
- `.prevent_default` element prop, boolean.
- Per-event default rule (when no `.event` entry covers an event):
  - Auto-bind synthetic event → `event_debounce(200)`.
  - Everything else → `event_immediate()`.
- Breaking API change: `event_*()` constructors no longer wrap a handler.
  They return a plain config struct.

Out:
- Mini-stores from `Each` / `Switch` (later phases). Auto-bind here works
  with whatever callables `reactiveStore` and `reactiveProxy` already
  produce.
- Client-side event filtering (planned, separate PR).
- Checkbox groups. Multi-select via `selected` on a vector-valued callable
  is a different shape and defers to a follow-up.

## DOM event mapping

| Prop       | DOM event | Elements              |
|------------|-----------|-----------------------|
| `value`    | `input`   | text inputs, textarea |
| `checked`  | `change`  | checkbox              |
| `selected` | `change`  | select, radio         |

Radio is bound per-element with value-based equality (see "Radio binding"
under Implementation).

## API change

```r
# OLD — handler-wrapping
tags$input(value = field, onInput = event_debounce(\(e) ..., ms = 500))

# NEW — element-level config; auto-bind handles write-back
tags$input(value = field, .event = event_debounce(500))

# Per-event override (debounce write-back, keep keydown immediate)
tags$input(
  value = field,
  onKeyDown = \(e) if (e$key == "Enter") submit(),
  .event = list(input = event_debounce(500))
)

# Form preventDefault
tags$form(onSubmit = \(e) submit(), .prevent_default = TRUE)
```

`event_immediate()`, `event_throttle()`, `event_debounce()` now return:

```r
structure(list(mode = "...", ms = ..., leading = ..., coalesce = ...),
          class = "irid_event_config")
```

No handler argument. No `prevent_default` argument either — that moves to
`.prevent_default` on the element.

`.event` accepts a single config struct (applies to all events on the
element) or a named list keyed by DOM event name (per-event override).
Keys are lowercase DOM event names (`input`, `change`, `click`, `keydown`,
…), not prop names — they identify the listener, which is per-DOM-event
regardless of whether listeners came from auto-bind, an explicit `on*`
prop, or both. Events not covered by the list fall back to the per-event
default rule (auto-bind synthetic → `event_debounce(200)`, else
`event_immediate()`).

## Implementation

### `R/event.R`

Rewrite the three constructors to return config structs, not wrapped
handlers. Drop the `fn` and `prevent_default` arguments. Keep `coalesce`,
`ms`, `leading` arguments unchanged.

### `R/process_tags.R`

In the per-attribute loop ([process_tags.R:123-156](../../R/process_tags.R#L123-L156)):

1. Pull `.event` and `.prevent_default` out of `attribs` before the loop.
   Strip them from `kept_attribs` so they don't end up as HTML attributes.
2. Detect state-binding props before the existing event/binding split:
   if `name %in% c("value", "checked", "selected")` and
   `is_irid_reactive(val)`:
   - Emit a binding (current behaviour — `attr = name`, `fn = val`).
   - Always append a synthetic event entry — even for 0-arg callables.
     The handler dispatches on arity at runtime: if
     `length(formals(val)) >= 1L`, call `val(e$value)` (or `e$checked` for
     `checked`); otherwise no-op. This makes the 0-arg case behave like
     `reactiveProxy(set = NULL)` — the listener fires, the write is
     dropped server-side, and the existing force-send-on-no-op protocol
     echoes the current value back so the input snaps back. Tag the
     entry as auto-bind-origin for the timing-resolution step below.
3. After collecting `pending_events` (both auto-bind synthetic and
   explicit `on*`), apply timing — for each event entry, in priority order:
   - If `.event` is a named list and contains the entry's DOM event name,
     use that config.
   - Else if `.event` is a single config struct, use it.
   - Else (no covering `.event`), apply the per-event default:
     `event_debounce(200)` for auto-bind-origin entries, `event_immediate()`
     for everything else.
4. Apply `.prevent_default` to every event entry on the element.
5. Drop the existing per-handler wrapping at
   [process_tags.R:135-141](../../R/process_tags.R#L135-L141) — handlers no
   longer carry `irid_event` class or attributes after this PR.

### `R/mount.R`

No structural change. The mount path already reads `mode`, `ms`, `leading`,
`coalesce`, `prevent_default` per event entry
([mount.R:82-91](../../R/mount.R#L82-L91)) and forwards them to the
client. Source of those fields shifts from the handler's attributes to the
event entry built by `process_tags`. Auto-bind synthetic handlers run
through the same `observeEvent` path as user-written events
([mount.R:25-94](../../R/mount.R#L25-L94)); sequence-number tracking and
force-send on no-op already work.

### `inst/js/irid.js`

The client already supports arbitrary event names per entry and dispatches
on `mode`, `ms`, `leading`, `coalesce`, `preventDefault`. Verify that:
- `input` registers correctly for `<select>`.
- `change` registers correctly for `<input type="checkbox">` and
  `<input type="radio">`.
- `input` continues to work for `text`/`textarea`.
- Focused-element echo skip in `irid-attr` for `value` covers auto-bind.

`selected` becomes polymorphic on element type — see Radio binding below.
No new protocol.

### Radio binding

Radio groups are expressed as multiple `<input type="radio">` sharing a
`name`. Each radio independently binds the same callable via `selected`,
with value-based equality:

```r
tags$div(
  tags$input(type = "radio", name = "choice", value = "a", selected = state$choice),
  tags$input(type = "radio", name = "choice", value = "b", selected = state$choice),
  tags$input(type = "radio", name = "choice", value = "c", selected = state$choice)
)
```

Browser-native `name` grouping handles mutual exclusion. Generated radio
groups will compose with `Each` once it lands in a later phase.

R-side: no special case in `process_tags`. Emit a `selected` binding plus a
synthetic `change` event entry exactly like any other auto-bound prop.

JS-side: `selected` is polymorphic on element type. The dispatch lives in
the `irid-attr` handler and the auto-bind event listener registration:

| Element              | Read (`irid-attr`)                          | Write (DOM event)                                                  |
|----------------------|---------------------------------------------|--------------------------------------------------------------------|
| `<select>`           | `el.value = msg.value`                      | fire `binding(el.value)` on `change`                               |
| `<input type="radio">` | `el.checked = (msg.value === el.value)`   | fire `binding(el.value)` on `change`, only when `el.checked === true` |

The "only when checked" guard avoids a stray write from the radio that
loses selection. Browsers don't fire `change` on the deselected radio in
practice, so this should already be implicit, but pin it down with a test.

## Tests

Coverage is tracked in [`TESTING.md`](../../TESTING.md) — see the
"Auto-bind" and "`.event` element config" sections plus updates to
"`process_tags` extraction" and "Client-side message handling".

Manual smoke test in an example app — confirm the temperature converter
works without any `onInput` write handler:

```r
tags$input(type = "number", value = state$temp_c)
```

## Migration

Update in the same PR:

- `examples/temperature.R`, `examples/todo.R` — drop redundant
  `onInput = \(e) state$x(e$value)` handlers where auto-bind covers them.
- `examples/optimistic_updates.R` and any other consumers using
  `event_debounce(handler, ms = ...)` — switch to `.event = event_debounce(ms)`.
- `vignettes/` references to event wrappers.
- `NEWS.md` entry calling out the breaking change.

The `.` prefix is the migration signal — readers seeing `.event = ...`
know it's element config, not a DOM attribute.

## Decisions

1. **Radio binding** — per-radio `selected` with value-based equality,
   JS-side polymorphic dispatch on element type. See "Radio binding"
   under Implementation. No tag-tree introspection, no new mechanism on
   the R side.

2. **Component-boundary forwarding** — a component that takes `field` and
   forwards it as `value = field` gets auto-bind for free. Documentation
   note only; no code work.

3. **Per-event default rule** — `event_debounce(200)` for auto-bind-origin
   entries, `event_immediate()` for everything else. `.event` overrides
   per element (scalar) or per event (named list).

4. **`.event` named-list keys are lowercase DOM event names** (`input`,
   `change`, `click`, `keydown`), not prop names. Timing is decided
   per-listener, and a listener is per-DOM-event regardless of whether it
   came from auto-bind, an explicit `on*` prop, or both. Keying by DOM
   event identifies the listener unambiguously.

## Open questions

1. **Naming.** `.event` is singular but accepts both a single config and a
   named list of per-event configs. `.events` reads better for the named-list
   form. Keeping singular for now to match the design document; flag as a
   soft naming decision.
