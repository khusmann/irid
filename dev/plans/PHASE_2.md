# Phase 2 — `.event` element config + `.prevent_default`

## Goal

Move event timing and transport off per-handler wrappers and onto the
element. `.event` controls timing (debounce / throttle / immediate) for
**all** events on that element — including auto-bind write-back from
phase 1 — and `.prevent_default` controls `event.preventDefault()` on
dispatch. Handlers stay plain functions; timing is element config, not
handler decoration.

## Scope

In:
- `.event` element prop, accepting one of `event_debounce(ms)`,
  `event_throttle(ms, leading)`, `event_immediate()`.
- `.prevent_default` element prop, boolean.
- Defaults:
  - Auto-bound `value` → `event_debounce(200)`.
  - Everything else → `event_immediate()`.
- Breaking API change: `event_*()` constructors no longer wrap a handler.
  They return a plain config struct.

Out:
- Per-event timing on the same element. Design picks one config per element;
  if a real use case forces per-event, that's a separate decision.
- Client-side event filtering (planned, separate PR).

## API change

```r
# OLD — handler-wrapping
tags$input(value = field, onInput = event_debounce(\(e) ..., ms = 500))

# NEW — element-level config
tags$input(value = field, onInput = \(e) ..., .event = event_debounce(500))

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

In the tag-processing path ([process_tags.R:117-170](../../R/process_tags.R#L117-L170)):

1. Pull `.event` and `.prevent_default` out of `attribs` before the
   existing loop. Strip them from `kept_attribs` so they don't end up as
   HTML attributes.
2. After collecting `pending_events` (both auto-bind synthetic and
   explicit `on*`), apply timing:
   - If `.event` is set on the tag, use it for every event entry on that
     element.
   - Else, use the auto-bind default (`event_debounce(200)`) for any event
     marked auto-bind-origin from phase 1; `event_immediate()` for the rest.
3. Apply `.prevent_default` to every event entry on the element.

Drop the existing per-handler wrapping at
[process_tags.R:135-141](../../R/process_tags.R#L135-L141) — handlers no
longer carry `irid_event` class or attributes after this phase.

### `R/mount.R`

No structural change. The mount path already reads `mode`, `ms`, `leading`,
`coalesce`, `prevent_default` per event entry
([mount.R:82-91](../../R/mount.R#L82-L91)) and forwards them to the
client. Source of those fields shifts from the handler's attributes to the
event entry built by `process_tags`.

### `inst/js/irid.js`

No protocol change. Existing dispatch already accepts `mode`, `ms`,
`leading`, `coalesce`, `preventDefault` per event entry.

## Test plan

- `tags$input(value = field, .event = event_debounce(500))` — write-back
  debounces at 500ms (override the 200ms auto-bind default).
- `tags$button(onClick = \() ..., .event = event_throttle(1000))` — clicks
  throttle at 1s.
- `tags$form(onSubmit = handler, .prevent_default = TRUE)` — form does not
  navigate.
- No `.event` on auto-bound text input — defaults to `event_debounce(200)`.
- No `.event` on a button with `onClick` — defaults to `event_immediate()`.
- Multiple events on the same element (e.g. `onInput` + `onKeyDown`) share
  the element's `.event` config.
- Confirm `.event` and `.prevent_default` do not appear in rendered HTML
  attributes.

## Migration

This phase changes the public API. Update in the same PR:

- `examples/optimistic_updates.R` and any other examples using
  `event_debounce(handler, ms = ...)` syntax.
- `vignettes/` references to event wrappers.
- `NEWS.md` entry calling out the breaking change.

The `.` prefix is the migration signal — readers seeing `.event = ...` know
it's element config, not a DOM attribute.

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

3. **Interaction with phase 1's auto-bind-origin tag.** Phase 1 marks the
   auto-bind synthetic event so phase 2 can apply the right default. Verify
   in implementation that `.event` overrides the auto-bind default cleanly
   — i.e. an explicit `.event = event_immediate()` on an auto-bound input
   genuinely produces immediate write-back, not the 200ms default.
