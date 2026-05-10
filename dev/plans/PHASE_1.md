# Phase 1 — Auto-bind on `value`/`checked`/`selected`

## Goal

State-binding props on a `shiny.tag` accept a callable and automatically
two-way bind: the callable's read populates the prop, and DOM events on the
element write back through the same callable. The user never has to write
an `onInput` handler just to keep state in sync — that's what auto-bind is
for. Explicit `on*` handlers remain available for discrete actions and run
orthogonally.

This phase does **not** introduce element-level `.event` config; auto-bound
write-back inherits the same default-timing rule the existing event system
applies (debounce 200ms for `input`, immediate otherwise). Phase 2 cleans
that up.

## Scope

In:
- `value`, `checked`, `selected` accept a callable in addition to a literal.
- Read path (server → client): emit `irid-attr` on reactive change. (Already
  works for these props because [process_tags.R:151-156](../../R/process_tags.R#L151-L156)
  treats any reactive attribute as a binding.)
- Write path (client → server): bind the corresponding DOM event, deliver
  the value to the server, call `fn(value)` automatically.
- Arity-based dispatch on the callable:
  - `length(formals(fn)) == 0` (e.g. `\() expr()`) → read-only; the server
    never writes back, the optimistic-update protocol snaps the input back.
  - `length(formals(fn)) >= 1` (`reactiveVal`, store leaf, `reactiveProxy`,
    branch) → both read and write.
- Orthogonality with `on*` handlers — providing `onInput` does not disable
  auto-bind. Both fire on the same DOM event.

Out:
- Element-level `.event` and `.prevent_default` (Phase 2).
- Mini-stores from `Each` / `Switch` (Phase 3+). Auto-bind here works with
  whatever callables `reactiveStore` and `reactiveProxy` already produce.
- Client-side event filtering (separate planned work).

## DOM event mapping

| Prop       | DOM event | Elements              |
|------------|-----------|-----------------------|
| `value`    | `input`   | text inputs, textarea |
| `checked`  | `change`  | checkbox              |
| `selected` | `change`  | select                |

Radio binding semantics are deferred — the design table lists `selected` on
radio, but group-level vs. per-radio binding deserves its own decision. Open
question below.

## Implementation

### `R/process_tags.R`

In the per-attribute loop ([process_tags.R:123-156](../../R/process_tags.R#L123-L156)),
detect state-binding props before the existing event/binding split:

1. If `name %in% c("value", "checked", "selected")` and `is_irid_reactive(val)`:
   - Emit a binding (current behaviour — `attr = name`, `fn = val`).
   - If `length(formals(val)) >= 1L`, emit a synthetic event entry whose
     handler is `\(e) val(e$value)` (or `e$checked` for `checked`). Tag the
     entry as auto-bind-origin so phase 2 can drive default `.event`
     selection from the same source of truth.
   - If 0-arg, no write entry — snap-back via the existing optimistic-update
     protocol handles it.

2. Otherwise, current behaviour unchanged.

The event entry is queued through the same `pending_events` machinery so the
existing event default rules (`onInput` → `event_debounce(200)`, others →
`event_immediate()`) cover the auto-bound `input`/`change` cases without
new code in this phase.

### `R/mount.R`

No structural changes required — auto-bind synthetic handlers run through
the same `observeEvent` path as user-written events
([mount.R:25-94](../../R/mount.R#L25-L94)). Sequence-number tracking and
force-send on no-op already work.

### `inst/js/irid.js`

The client already supports arbitrary event names per entry. Verify that:
- `change` registers correctly for `checkbox` and `select`.
- `input` continues to work for `text`/`textarea`.
- Focused-element echo skip in `irid-attr` for `value` covers auto-bind.

No protocol changes.

## Test plan

Add R tests under `tests/testthat/`:

- `value = reactiveVal("a")` on `tags$input` — typing fires writes; `rv()`
  returns the typed value after flush.
- `value = state$user$name` (store leaf) — same.
- `value = reactiveProxy(state$x, set = \(v) if (nchar(v) <= 5) state$x(v))`
  — gated writes accept short strings, drop long ones.
- `value = reactiveProxy(state$x, set = NULL)` — read-only; client snaps back.
- `value = \() toupper(state$x())` — 0-arg read-only; snap-back.
- `checked = state$done` on checkbox — toggle fires `state$done(TRUE/FALSE)`.
- `selected = state$theme` on `<select>` — selection fires write.
- Both `value = fn` AND `onInput = handler` — both run on input.
- Focused-input echo skipping continues to work for auto-bind value updates.

Manual smoke test in an example app — confirm the temperature converter
works without any `onInput` write handler:

```r
tags$input(type = "number", value = state$temp_c)
```

## Migration

After this phase lands, `examples/temperature.R` and `examples/todo.R` can
drop redundant `onInput = \(e) state$x(e$value)` handlers. Do that in a
follow-up commit on the same PR or a chained PR — the phase doesn't break
the explicit form, so it isn't urgent.

## Open questions

1. **Radio binding.** The design lists `selected` on radio, but a radio group
   is typically expressed as multiple `<input type="radio">` sharing a `name`,
   each with its own `checked`. Two reasonable mappings: (a) `selected` on a
   container, write the chosen value; (b) `checked` per radio, derived from
   equality with the group's reactive. Defer to a follow-up — out of scope
   for this PR. Test radio with `checked` only for now.

2. **`change` vs `input` on `<select>`.** `change` fires on commit; `input`
   fires on each change in modern browsers. Design says `change`. Confirm
   that's what we want for consistency with checkboxes; revisit if user
   feedback prefers `input`.

3. **Component-boundary forwarding.** A component that takes `field` and
   passes it as `value = field` gets auto-bind for free without doing
   anything. Worth a sentence in the documentation but no code work.

4. **Default timing for the synthetic event entry.** The auto-bind `input`
   event will get `event_debounce(200)` from the existing default rule.
   That's the right end state per the design. Confirm no surprises arise
   from the synthetic origin (e.g. interaction with phase 2's `.event`
   override resolution).
