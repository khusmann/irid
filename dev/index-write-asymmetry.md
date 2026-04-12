# Finding: `Index` read/write asymmetry

**Status:** Captured, not triaged.
**Surfaced:** April 2026, during the state-primitive stress test
(`dev/stores/state-stress-test-plan.md`).

---

## The observation

`Index(listVal, \(item) ...)` passes each item to the callback as a
**reactive accessor** — calling `item()` reads the current value and
registers a dependency at the item level. This works as intended on
the read side: per-item observers only re-fire when their item
actually changes, even though the backing store is a single atomic
list `reactiveVal`.

The asymmetry is on the write side. The accessor is read-only. To
update a single item you have to go back to the parent `reactiveVal`,
copy the list, mutate by position (or by id), and write the whole
list back:

```r
Index(state$todos, \(todo) {
  tags$input(
    type = "checkbox",
    checked = \() todo()$done,
    onClick = \(e) {
      state$todos(modify_if(
        state$todos(),
        \(t) t$id == todo()$id,
        \(t) modifyList(t, list(done = e$checked))
      ))
    }
  )
})
```

The read side is surgical (`todo()`), the write side is a whole-list
rewrite threaded through `modify_if` / `modifyList`. A reader of this
code has to mentally translate "the item I'm looking at" into "find
it again by id in the parent list" on every write — and the child
component needs a reference to the *parent* `reactiveVal`, not just
the item accessor it was handed.

## Where it surfaced

Found in [dev/stores/state-example-survey.R](stores/state-example-survey.R)'s
`ChoiceEditor`, where editing one option in a choice question means
reading the whole options vector, mutating by index, and writing it
back. The executor's verbatim note from the stress test:

> `Index` in `ChoiceEditor` was awkward: the reactive accessor gives
> you the item to read, but to write one you still have to go back to
> the parent `reactiveVal`, copy the list, mutate by position, and
> set it. The symmetry I expected from the accessor wasn't there.

This was surfaced by a session that had no prior context about
irid's design goals and was only asked to write idiomatic code
against the existing primitives. The friction is real and
independent of the store design discussion happening in parallel.

## Why this is not a store problem

The store design (`dev/stores/irid-store-design.md`, §6) scopes
stores to record-like state and treats collections as atomic list
nodes — precisely so that `Each` and `Index` retain sole
responsibility for per-item reactivity. Shipping stores would not
change the write path for collection items; it would still be
read-transform-write on the backing list.

So this is an `Index` / `Each` ergonomics question, orthogonal to
whether stores exist.

## Sketches of directions (not decisions)

These are not recommendations. They are possible directions for a
later design pass to consider.

### 1. `Index` passes a writable accessor

If `Index` knew how to produce a writer that closes over the parent
`reactiveVal` and the item's identity (by position or by `by` key),
it could hand the callback a callable that reads *and* writes:

```r
Index(state$todos, \(todo) {
  tags$input(
    type = "checkbox",
    checked = \() todo()$done,
    onClick = \(e) todo(modifyList(todo(), list(done = e$checked)))
  )
})
```

This pushes the "find and splice" logic into `Index` itself. Open
questions: what happens if the item's `by` key changes on write? How
does this interact with adds/removes that happen concurrently? Does
`Each` get the same treatment even though it passes plain values
rather than accessors?

### 2. A helper: `modify_at(listVal, predicate, f)`

A thin helper that captures the read-transform-write idiom without
changing `Index`:

```r
modify_at <- function(listVal, predicate, f) {
  listVal(lapply(listVal(), \(x) if (predicate(x)) f(x) else x))
}

onClick = \(e) modify_at(
  state$todos,
  \(t) t$id == todo()$id,
  \(t) modifyList(t, list(done = e$checked))
)
```

Less ambitious — doesn't change any primitive, just names a pattern.
The caller still has to pass the parent `reactiveVal` into the child
component, which is part of the original friction.

### 3. Do nothing, document the pattern

The current code works and the idiom is discoverable once you know
it. The friction is real but maybe not big enough to justify a new
primitive. A prominent note in `ARCHITECTURE.md` explaining
read-transform-write as the canonical pattern, plus a worked example
in the vignette, might be enough.

## What to do now

Nothing. This doc exists so the finding isn't lost. When the store
work lands and attention returns to collection ergonomics, start
here.
