# Reactive system — finishing pass

Pairing the current codebase against [`dev/reactive-system/final-design.md`](../reactive-system/final-design.md).
`reactiveStore` and `reactiveProxy` are in (see [R/store.R](../../R/store.R),
[R/proxy.R](../../R/proxy.R)). What's left is the consumption side: `Each`,
`Match` (redesign), and `When` (small breaking change for body laziness).

## Adding

### `Each` — mini-store + scalar accessor projections
Current [Each](../../R/primitives.R) hands `fn` a plain item value and a
reactive index. Final design hands `fn` a callable per item:

- **Record items** → per-item **mini-store** projection. `item()` reads the
  whole record, `item(record)` writes it back through the parent collection,
  `item$field()` reads a leaf, `item$field(v)` is a synthetic setter that
  writes through the parent (one-way data flow — leaves never hold
  independent state).
- **Scalar items** → per-item **reactive accessor**. `item()` reads, `item(v)`
  writes back to the parent's slot.
- `by = NULL` (new default) → **positional** reconciliation. Slot *i* is
  slot *i*; list can grow/shrink at the end; in-place value changes fire
  per-slot without DOM recreation. (This is what current `Index` does.)
- `by = \(x) x$id` → **keyed** reconciliation, same diff/move semantics as
  today's `Each`. Kept items get patched (mini-store leaves diffed) instead
  of replaced.
- Callback `(item, pos)`: `pos` is **always a 0-arg reactive accessor** for
  the item's current 1-indexed slot. Constant signal under `by = NULL`
  (slot number is the identity), live under `by = fn` (fires on reorder).
  Uniform shape across modes — see final-design open Q4 (resolving it
  this way as part of this work).

### `Match` — redesign for bound-value dispatch with mini-store projection
Current [Match](../../R/primitives.R) is a predicate-only `Match(...Cases)`
form with tag-tree case bodies. Final design redesigns the signature:

```r
Match(callable,
  Case(predicate_or_literal, body_fn),
  Default(body_fn)
)
```

- The leading callable is the *bound value*. Records are projected as a
  mini-store for the active case; scalars are passed as the bare accessor.
- `Case`'s first arg is one of: `\(v) cond` (predicate of bound value),
  `\() cond` (cross-cutting predicate ignoring the bound value), or a
  literal (equality match against bound value via `identical`). The name
  `Match` is deliberate — leaves the door open for richer pattern forms
  (shape specs, destructuring binders, guards) under the same primitive.
- `Case`'s second arg and `Default`'s arg are **functions** (not tag trees),
  arity-polymorphic: `\(v) body` or `\() body`. Inactive cases are torn
  down with their reactives; activation must construct a fresh instance,
  hence the function form.
- Choice-fn pattern is automatic: any leading callable works, including
  `\() { if (loading()) list(tag="loading") else ... }`.
- Per-case mount/destroy on active-case change — the active case's
  mini-store has a fixed shape for its lifetime.

This is a breaking change to the current `Match`/`Case`/`Default` signatures.

### Keep `When`, frame it as a binary `Match`
`When` stays as ergonomic sugar for binary boolean dispatch. Conceptually
it's `Match(\() cond, Case(TRUE, …), Case(FALSE, …))` with a fixed
two-branch shape. Bodies become **functions** (`\() yes_tree`,
`\() otherwise_tree`) — same lazy-body rule as `Match` cases, for the
same reason: `When` mounts/unmounts the active branch on transition, so
each activation must construct a fresh tag tree (the previous branch's
closures were torn down with its reactives).

This is a breaking change to today's `When(condition, yes, otherwise)` —
the `yes` / `otherwise` args become 0-arg functions returning tag trees.

### Stress-test example for vertical composition
Final-design open Q3 calls out that the multi-level synthetic setter chain
(`Each` inside `Each` with record items) "needs prototype validation."
Build the questions-with-options example from final-design (§"Vertical
composition") into `examples/` as part of this work, exercise it
end-to-end (add/remove/reorder both levels, edit inner scalars and outer
record fields), and watch for redundant reconcile passes before more
code lands on top.

## Removing

- **`Index`** — subsumed by `Each(by = NULL)` with scalar slot accessors.
