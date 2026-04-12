# Write-control pattern verdict (v2)

Evaluation of patterns (a)–(d) against the criteria in `plan.md`,
based on the worked examples in `examples.md`.

**Key revision from v1:** Pattern (d) goes all-in on `reactiveView`
as the replacement for `onInput`'s write-control role. Because
`set` is a side-effectful handler (not a pure transform), it
subsumes every use case that `onInput` served on state-bound
elements: validation gates, bidirectional transforms, side effects
on write, and read-only views. `onInput` is no longer needed as
an escape hatch for state-binding props.

---

## Scorecard

| Criterion                      | (a) Current | (b) onChange | (c) Auto+onChange | (d) reactiveView |
|--------------------------------|:-----------:|:------------:|:-----------------:|:-----------------:|
| 1. Common-case simplicity      | ++          | -            | +                 | ++                |
| 2. Validated-case ceremony     | --          | +            | +                 | +                 |
| 3. Composability               | ++          | --           | -                 | ++                |
| 4. Fine-grained reactivity     | ++          | ++           | ++                | ++                |
| 5. Cross-field validation leak | ++          | ++           | ++                | ++                |
| 6. Atomic cross-field          | +           | +            | +                 | +                 |
| 7. Third-party support         | -           | --           | -                 | ++                |
| 8. Bidirectional transforms    | --          | +            | ~                 | ++                |
| 9. Visibility of write policy  | -           | ++           | +                 | +                 |
| 10. Conceptual weight          | +           | +            | -                 | ++                |

`++` strong, `+` adequate, `~` mixed, `-` weak, `--` poor.

---

## Criterion-by-criterion analysis

### 1. Common-case simplicity

**(a) and (d)** are identical: `EmailInput(state$email)` at the
call site, `tags$input(value = email)` in the component. Minimal
on both sides. **(c)** matches the parent-side simplicity but
the component author always pays a tax: collapse logic
(`onChange %||% \(v) field(v)`) and an explicit `onInput` handler
even when no validation is needed. **(b)** is worst — the parent
must always provide a value/onChange pair:
`EmailInput(value = \() x(), onChange = \(v) x(v))`.

### 2. Validated-case ceremony

**(a)** has no framework mechanism. The parent must hand-roll a
validating callable with `missing()`-dispatch (ad-hoc, error-prone)
or bypass the component entirely. Every other pattern has a clean
answer. **(b)** changes one line in the `onChange` callback.
**(c)** adds one prop at the call site. **(d)** creates a view
and passes it — two lines, but the validation is encapsulated and
nameable. Slight edge to (b)/(c) for fewer lines, but (d) is more
reusable — the same view can be passed to multiple consumers.

### 3. Composability

**(a) and (d)** support branch-passing: `ColorPicker(state$color)`,
`Fields(state$user, RenderNode)`. Components compose over the store
tree without decomposing it. **(b)** requires pair-threading at
every boundary — `ColorPicker` needs four props for two fields,
and the recursive `RenderNode` case becomes
`\(getter, setter, key)` with explicit plumbing. **(c)** is
between: branch-passing works for the common case, but the
component author must pre-declare which fields are interceptable
via optional `onChange` props. Adding a constrainable field means
changing the component signature at every intermediate level.

### 4. Fine-grained reactivity

All patterns preserve field-level reactivity equally. The
write-control mechanism is orthogonal to the reactive graph
structure. Store leaves, mini-store fields, and `reactiveView`
outputs are all reactive at the same granularity.

### 5. Cross-field validation leak

All patterns isolate by construction when applied at the
leaf/field level. Validating `text` never gates `done`. In
**(b)**, isolation is structural (separate callbacks). In
**(c)**, separate optional `onChange` per field. In **(d)**,
the view wraps a single leaf. In **(a)**, `onInput` is per-
element. No pattern showed leakage in any example.

### 6. Atomic cross-field validation

All patterns converge on the same approach for PlotlyOutput:
intercept the atomic event callback and validate before writing
individual fields. No pattern has a structural advantage. The
`reactiveView` in (d) encapsulates the validation logic for
`xaxis_range`, but the parent still writes a manual callback to
dispatch the atomic event across fields.

### 7. Third-party support

The sharpest differentiator. **(d)** is the only pattern with a
framework-supported mechanism for intercepting writes through
components you don't control. `reactiveView` wraps the callable —
the third-party component sees a normal callable and doesn't need
to support any interception protocol.

**(a)** and **(c)** fall back to hand-rolled callables with
`missing()`-dispatch. **(b)** only works if the third-party
component happens to use the value/onChange convention — if it
accepts a single callable (which it will in irid's ecosystem),
(b) has no answer at all.

### 8. Bidirectional transforms

The second sharp differentiator. **(d)** expresses both directions
in one place: `reactiveView(x, get = ..., set = ...)`. The view
is a self-contained bidirectional adapter. **(b)** handles it via
the read/write pair, which naturally holds both directions but
at the cost of always requiring the pair. **(c)** splits the
transform: read direction in the callable, write direction in
`onChange` — the two halves are in different arguments and must be
kept in sync manually. **(a)** requires hand-rolled callables
with `missing()`-dispatch, duplicating the transform logic.

### 9. Visibility of write policy

**(b)** is strongest: the `onChange` callback IS the write policy,
always present, always visible at the call site. **(c)** is
visible when `onChange` is provided, invisible when it falls
through to auto-bind (which is the point — the common case
shouldn't need to show policy). **(d)** is visible at the point
where the view is created (`reactiveView(set = ...)`) and at the
call site if the view is well-named (`validated_email`), but
requires looking at the view definition to understand the policy.
**(a)** is weakest for the validated case: hand-rolled callables
hide the policy inside a closure with no framework convention for
where to look.

### 10. Conceptual weight

**(a)** is the baseline: unified callables + auto-bind + `onInput`
overriding auto-bind. Three concepts.

**(d)** replaces `onInput`'s write-control role with
`reactiveView`, which is a net simplification. The mental model
becomes: auto-bind handles reads and writes through a callable,
and `reactiveView` lets you put a filter or transform in front of
a callable. Two concepts rather than three — the "onInput disables
auto-bind" special case is gone. `reactiveView` also subsumes the
ad-hoc `\() x()` read-only pattern and hand-rolled
`missing()`-dispatch callables, so the total number of patterns
a developer encounters goes down.

**(b)** is conceptually simple in isolation (value + onChange) but
breaks from the callable model, creating a mismatch with the rest
of irid's API.

**(c)** is heaviest: callables + auto-bind + optional onChange +
collapse pattern. Four moving parts for every component that wants
to be constrainable.

---

## Recommendation

**Pattern (d): auto-bind + `reactiveView`, with `onInput` removed
from state-binding prop semantics.**

### The case

Three pillars:

1. **Zero cost for the common case.** Component author code and
   parent call-site code are identical to pattern (a). Adding
   `reactiveView` to the framework doesn't change anything about
   the no-validation path.

2. **The only pattern that handles third-party components.** In an
   ecosystem where components accept callables (irid's fundamental
   protocol), `reactiveView` is the only framework-supported way
   to intercept writes through a component you can't modify. Every
   other pattern falls back to ad-hoc callable construction or
   doesn't work at all.

3. **Bidirectional transforms as a first-class concern.** Two of
   the seven examples (temperature, currency) are bidirectional
   transforms. Without `reactiveView`, these require hand-rolled
   callables with `missing()`-dispatch — a pattern that's bug-prone
   and not discoverable. `reactiveView(get, set)` makes transforms
   a named, documented concept.

### Dropping `onInput` as write-control for state-binding props

In the current design (pattern a), `onInput` serves a dual role:

1. DOM event handler — fires on the `input` event
2. Auto-bind override — its presence disables auto-bind write-back

`reactiveView` fully replaces role 2. Because `set` is a
side-effectful handler, it covers every case `onInput` was used
for on state-bound elements:

| `onInput` use case              | `reactiveView` equivalent                                  |
|---------------------------------|------------------------------------------------------------|
| Validation gate                 | `set = \(v) if (valid(v)) x(v)`                            |
| Transform on write              | `set = \(v) x(parse(v))`                                   |
| Side effect + write             | `set = \(v) { x(v); log(v) }`                              |
| Side effect, conditional write  | `set = \(v) { log(v); if (valid(v)) x(v) }`                |
| Read-only (suppress all writes) | `set = NULL`                                                |

This means `onInput` no longer needs the special "disables
auto-bind" behavior. If `onInput` is kept at all on state-bound
elements, it should be a plain DOM event handler — orthogonal to
auto-bind, not overriding it. This is a cleaner separation:

- **Auto-bind** reads and writes through the callable. Always.
- **`reactiveView`** controls what happens on read and write.
- **Event props** (`onInput`, `onClick`, etc.) are plain DOM
  event handlers. They don't affect auto-bind.

The "onInput disables auto-bind" special case was a pragmatic
shortcut that let the current design handle validation without
a new primitive. `reactiveView` is that primitive, and it's
more general.

### What to keep from other patterns

**(c)'s optional `onChange`** is a reasonable component-author
convention for specific cases where the component wants to
explicitly advertise "you can intercept this field." But it
should not be the primary mechanism — it shifts burden to
component authors and doesn't compose through boundaries
the author didn't anticipate.

### What to drop

- **`onInput` as auto-bind override** — replaced by
  `reactiveView`. `onInput` can remain as a plain event prop
  if needed, but without special auto-bind semantics.

- **(b)** is not viable for irid. It kills composability (the
  `RenderNode` case, branch-passing, `Fields`) and forces
  boilerplate on every call site. The consistency benefit
  (visible write policy everywhere) doesn't outweigh the costs
  in an R/Shiny context where convention-as-enforcement is the
  norm.

---

## Flags

### Scenarios the examples missed

1. **Async validation.** What happens when validation requires a
   server round-trip (e.g., checking email uniqueness against a
   database)? `reactiveView`'s `set` is synchronous — it either
   writes or doesn't. Async validation would need a different
   mechanism: write optimistically then revert, or debounce and
   validate in an `observe()`. This is outside `reactiveView`'s
   scope but worth documenting.

2. **Error display.** None of the examples show how to communicate
   "write rejected" to the user. A validation gate that silently
   drops writes is poor UX. The parent needs a way to show feedback
   (e.g. "Invalid email"). This is orthogonal to the write-control
   pattern — any pattern can pair with an error reactive — but it's
   worth noting that `reactiveView`'s `set` is a natural place to
   set an error flag as a side effect:

   ```r
   email_error <- reactiveVal(NULL)
   validated_email <- reactiveView(
     state$email,
     set = \(v) {
       if (is_valid_email(v)) { email_error(NULL); state$email(v) }
       else email_error("Invalid email address")
     }
   )
   ```

3. **Chained views.** Can you compose `reactiveView` on top of
   another `reactiveView`? E.g., a currency view composed with a
   max-value gate. If a view is a callable, another view should be
   able to wrap it. Worth verifying.

4. **Debounce interaction.** When `.event = event_debounce(200)` is
   active, the validation gate in `set` runs after the debounce
   settles. This is correct — you don't want to validate mid-
   keystroke. But it's worth documenting that `reactiveView`
   validation is server-side and post-debounce.

### Is leaf-only `reactiveView` sufficient?

**Yes.** The branch-passing problem (examples 3 and 4) is real,
but a branch-level `reactiveView` is the wrong solution. The
problem is that branch-passing is opaque to per-field interception
by design — the branch is a unit. The right response:

- When a component needs to be constrainable per-field, accept
  individual callables (not a branch). This is the component
  author explicitly supporting per-field interception.
- When a component accepts a branch, the parent trusts it with
  the whole branch. Per-field constraints require restructuring
  the call (passing fields individually) or the component
  (accepting override callables).

A branch-level view (e.g., `reactiveView(state$color, hue = list(
set = ...))`) would add significant complexity (branch-aware
routing, per-field overrides) for a case that's better solved by
component design. The examples show that leaf-only views handle
every case where the component accepts individual callables.

### Does `reactiveView` add too much conceptual weight?

**No — it reduces net conceptual weight.** The concept itself is
simple: a view is a callable that transforms reads and/or gates
writes. `get` transforms on read, `set` handles writes. Both
default to pass-through.

What it replaces:

| Without `reactiveView`                          | With `reactiveView`                     |
|-------------------------------------------------|-----------------------------------------|
| Hand-rolled validating callable (missing-dispatch) | `reactiveView(x, set = \(v) ...)`     |
| Hand-rolled converting callable (missing-dispatch) | `reactiveView(x, get = ..., set = ...)` |
| `\() x()` for read-only passing                | `reactiveView(x, set = NULL)`           |
| `onInput` disables auto-bind (special case)     | (removed — auto-bind always writes)     |
| Side-effect `onInput` handlers                  | `set = \(v) { x(v); side_effect() }`   |

Five ad-hoc patterns collapse into one primitive. The `\() x()`
read-only idiom remains valid as shorthand, but `reactiveView`
gives it a named counterpart.

The concept is a lens — a well-known functional abstraction — but
it doesn't need to be taught that way. "A view lets you put a
filter or transform in front of a piece of state" is sufficient.
