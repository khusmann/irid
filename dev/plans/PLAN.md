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
- Callback is arity-polymorphic — 0, 1, or 2 args: `\() body`, `\(item) body`,
  or `\(item, pos) body`. `pos` is **always a 0-arg reactive accessor** for
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

## Removing

- **`Index`** — subsumed by `Each(by = NULL)` with scalar slot accessors.

---

## Phased implementation

Each phase is a commit-shaped unit: shippable, testable in isolation, and
sequenced so the next phase has a stable foundation under it.

### Phase 1 — Mini-store projection helper (internal)
**Goal:** factor out the projection mechanism that `Each` (record items)
and `Match` (record bound value) will share.

- New internal in [R/store.R](../../R/store.R) (or a new
  `R/mini_store.R`) — `make_mini_store(get_record, set_record)` returns a
  callable-tree shaped like a `reactiveStore`:
  - `mini()` → `get_record()`
  - `mini(record)` → `set_record(record)`
  - `mini$field()` → reads the corresponding leaf from `get_record()`
  - `mini$field(v)` → synthetic setter: `set_record(modifyList(get_record(), list(field = v)))`
  - Fixed shape — derived from the record at construction; the projection
    fails on a write with unknown keys, same rule as `reactiveStore`.
- Shape introspection (`names`, `length`, `[[`, `print`) reuses the
  `reactiveStore` generics where possible.
- Tests in `tests/testthat/test-mini-store.R`:
  - Read/write round-trips through `get_record` / `set_record`.
  - Synthetic setter routes through `set_record`, doesn't bypass it.
  - Fine-grained reactivity: writing one field invalidates only its leaf's
    observers (this depends on the parent only firing changed leaves —
    see Risks).
  - Fixed-shape rejection of unknown-key writes.

### Phase 2 — `Match` redesign
**Goal:** the new bound-value dispatch + mini-store projection + lazy
function bodies.

- [R/primitives.R](../../R/primitives.R): rewrite `Match(callable, ...)`,
  `Case(predicate_or_literal, body_fn)`, `Default(body_fn)`. The Match
  node stores `list(callable, cases)` where each case is
  `list(predicate, body)` and the predicate is normalised into a function
  (literal `x` → `\(v) identical(v, x)`).
- [R/mount.R](../../R/mount.R): rewrite the `cf$type == "match"` branch:
  - One outer `observe` reads `cf$callable()` and walks the case
    predicates to find the first true one. Predicate arity dictates whether
    it's called as `pred(bound)` or `pred()`.
  - On active-case change: destroy old mount, project a mini-store from the
    bound value (records) or pass the bare callable (scalars), call
    `body_fn(projection)` or `body_fn()` based on body arity, mount fresh.
  - Patch on same-case, value-changed: route the new record through the
    existing mini-store's `set_record` (no remount).
- [R/process_tags.R](../../R/process_tags.R): the Match descriptor in
  `control_flows` carries `callable` + `cases` instead of just `cases`.
- Tests: `tests/testthat/test-match.R` covering predicate / literal /
  cross-cutting Cases, scalar dispatch, record dispatch with mini-store
  field reads, mount/destroy on case transition, patch-without-remount
  on same-case changes.

### Phase 3 — `When` body laziness
**Goal:** small, mechanical change — `yes` / `otherwise` become 0-arg
functions.

- [R/primitives.R](../../R/primitives.R): `When(condition, yes, otherwise = NULL)`
  with the docstring updated; no signature change beyond the body
  semantics. Roxygen mentions the binary-`Match` framing.
- [R/mount.R](../../R/mount.R): `cf$type == "when"` branch calls
  `cf_yes()` / `cf_otherwise()` at mount time (not before).
- Update any usage in examples/tests.

### Phase 4 — `Each` redesign
**Goal:** the big one. Per-item callables, positional + keyed
reconciliation, write-through-parent.

- [R/primitives.R](../../R/primitives.R): `Each(items, fn, by = NULL)`.
  The Each node carries `items` (a callable), `fn`, and `by` (NULL or
  function).
- [R/mount.R](../../R/mount.R): rewrite the `cf$type == "each"` branch
  with two reconciliation modes selected by `is.null(by)`:
  - **Positional (`by = NULL`):** parallel arrays of slot state. Each
    slot holds a per-item callable (mini-store or scalar accessor) plus
    its DOM mount and `pos_rv`. Slot accessors close over the slot index
    and write back via `items(replace_at(items(), i, v))`. Length changes
    append/destroy trailing slots; in-place changes patch each slot's
    accessor (mini-stores via `set_record`, scalars via the underlying
    `reactiveVal`).
  - **Keyed (`by = fn`):** keyed by `by(item)`. Mini-stores route writes
    by *resolving the slot by key at write time*, not by capturing an
    index — slots can reorder. Kept items have their mini-store patched
    (single `mini(new_record)` call); new mounted; removed destroyed;
    reordered moved via the existing `irid-mutate` `order` mechanism.
- Callback dispatched by arity (0 / 1 / 2 args) — same pattern as today's
  event handlers in [R/mount.R](../../R/mount.R). 2-arg form receives
  `(item_accessor, pos_rv)` where `pos_rv` is a 0-arg accessor for the
  current 1-indexed slot. Stable identity across reconciles so observers
  don't recreate.
- Detect record vs scalar items by inspecting the first item at first
  mount; lock the shape for the lifetime of that accessor (a slot's
  shape is fixed; a key's mini-store shape is fixed).
- Tests: `tests/testthat/test-each.R` covering scalar & record items in
  both modes, write-through-parent (round-trip), patch fires only changed
  leaves on keyed update, reorder doesn't remount, `pos_rv` updates on
  reorder under `by = fn`.

### Phase 5 — Delete `Index`
**Goal:** remove the now-redundant primitive.

- Drop `Index` from [R/primitives.R](../../R/primitives.R).
- Drop the `cf$type == "index"` branch from [R/mount.R](../../R/mount.R).
- Drop `index` handling from [R/process_tags.R](../../R/process_tags.R).
- Migrate `examples/todo.R` (the one remaining caller) to `Each(by = NULL)`.
- `devtools::document()` to drop the export.

### Phase 6 — Vertical-composition stress example
**Goal:** validate the multi-level synthetic setter chain
(final-design open Q3) before more code lands on top.

- Port the questions+options example from final-design (§"Vertical
  composition: `Each` inside `Each`") into `examples/each_nested.R`.
- Exercise manually in a Shiny session: add/remove/reorder both levels,
  edit inner scalars (`option`) and outer record fields (`question$text`),
  watch for redundant reconcile passes or stale leaves.
- If problems surface, log them at the bottom of this plan under "Risks"
  and resolve before merging.

### Phase 7 — Docs & re-document
- Update [ARCHITECTURE.md](../../ARCHITECTURE.md) — file layout note,
  control flow lifecycle section (drop Index, rewrite Each, rewrite Match,
  reframe When).
- Roxygen pass — all four primitives.
- `devtools::document()` to refresh `man/` and `NAMESPACE`.
- `devtools::build_readme()` if any README example references the changed
  signatures.

---

## Risks & decisions to revisit

### Per-leaf observer firing on store patch
Mini-store decomposition only delivers its "only changed fields fire"
promise if the underlying `reactiveStore` doesn't fire leaves that were
written with their existing value. Current `make_store` in
[store.R](../../R/store.R) writes every key in the patch unconditionally
— a `reactiveVal` set to its existing value still notifies. Two options:

1. **Diff at the call site.** When `Each`/`Match` patches a mini-store on
   a kept item / same-case change, compute the changed-keys subset first
   and pass only that as the patch.
2. **Equality short-circuit inside `reactiveVal` writes** at the store
   layer (`if (identical(old, new)) return()`).

(2) is cheaper for callers and benefits any caller of `reactiveStore`, but
changes the semantics of writes-to-same-value (which today fire the
binding once for the force-send echo path — see
[ARCHITECTURE.md](../../ARCHITECTURE.md) §"Optimistic Updates"). Pick the
approach in Phase 1 and document the choice.

### Slot accessor capture under `by = NULL`
Positional accessors close over a slot index. The index is stable while
the slot is alive, but when the list shrinks past it, the slot's accessor
must hard-error on read/write (don't silently write out-of-bounds).
Decide whether destroyed accessors throw or no-op — phase 4.

### Mini-store identity under keyed reconciliation
For `by = fn`, the mini-store for a kept key should *not* be recreated
across reconciles (callers may have stashed `item$field` references in
their tag tree's closures). The reconciler must patch the same mini-store
object, not swap it for a new one. Cover this with a test in phase 4.
