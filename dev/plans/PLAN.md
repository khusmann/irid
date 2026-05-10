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
- `.event` element prop, accepting one of `event_debounce(ms)`,
  `event_throttle(ms, leading)`, `event_immediate()`.
- `.prevent_default` element prop, boolean.
- Defaults:
  - Auto-bound `value` → `event_debounce(200)`.
  - Everything else → `event_immediate()`.
- Breaking API change: `event_*()` constructors no longer wrap a handler.
  They return a plain config struct.

Out:
- Mini-stores from `Each` / `Switch` (later phases). Auto-bind here works
  with whatever callables `reactiveStore` and `reactiveProxy` already
  produce.
- Client-side event filtering (planned, separate PR).
- Per-event timing on the same element. `.event` is element-scoped; if a
  real use case forces per-event override, that's a separate decision.
- Checkbox groups. Multi-select via `selected` on a vector-valued callable
  is a different shape and defers to a follow-up.

## DOM event mapping

| Prop       | DOM event | Elements              |
|------------|-----------|-----------------------|
| `value`    | `input`   | text inputs, textarea |
| `checked`  | `change`  | checkbox              |
| `selected` | `input`   | select                |
| `selected` | `change`  | radio                 |

Radio is bound per-element with value-based equality (see "Radio binding"
under Implementation).

## API change

```r
# OLD — handler-wrapping
tags$input(value = field, onInput = event_debounce(\(e) ..., ms = 500))

# NEW — element-level config; auto-bind handles write-back
tags$input(value = field, .event = event_debounce(500))

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
   - If `length(formals(val)) >= 1L`, append a synthetic event entry whose
     handler is `\(e) val(e$value)` (or `e$checked` for `checked`). Tag the
     entry as auto-bind-origin for the timing-resolution step below.
   - If 0-arg, no write entry — snap-back via the existing optimistic-update
     protocol handles it.
3. After collecting `pending_events` (both auto-bind synthetic and
   explicit `on*`), apply timing:
   - If `.event` is set on the tag, use it for every event entry on that
     element.
   - Else, use `event_debounce(200)` for any event marked
     auto-bind-origin; `event_immediate()` for the rest.
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
| `<select>`           | `el.value = msg.value`                      | fire `binding(el.value)` on `input`                                |
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

2. **`<select>` event** — `input`, not `change`. Modern browsers fire
   `input` on selection; using it everywhere `value` semantics apply
   keeps the table coherent (`change` reserved for checkbox/radio).

3. **Component-boundary forwarding** — a component that takes `field` and
   forwards it as `value = field` gets auto-bind for free. Documentation
   note only; no code work.

4. **Default timing for the synthetic event entry** — auto-bound `value`
   gets `event_debounce(200)`; everything else gets `event_immediate()`.
   `.event` overrides per element. Confirm in implementation that
   `.event = event_immediate()` on an auto-bound input genuinely produces
   immediate write-back, not the 200ms default.

## Open questions

1. **Per-event override.** A reasonable user request will eventually be:
   debounce `onInput` 500ms but keep `onKeyDown` immediate on the same
   `<input>`. Not solved here. The cleanest extension is allowing per-event
   override via a named-list form on `.event` (e.g.
   `.event = list(input = event_debounce(500), keydown = event_immediate())`),
   but that's an additive future change and explicitly out of scope.

2. **Naming.** `.event` is singular for an element-level scope that covers
   all events. Plural (`.events`) reads better when more than one event
   exists on the element. Keeping singular for now to match the design
   document; flag as a soft naming decision.
