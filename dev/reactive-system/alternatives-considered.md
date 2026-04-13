# Alternatives Considered

Orthogonal ideas evaluated during the reactive system design. Each entry covers
what it is, why it was considered, why it was rejected or deferred, and the key
points from the design discussion.

---

## A. Store architecture alternatives

### A1. Fine-grained reactivity on arrays (Solid-style recursive proxies)

**What:** Treat arrays as part of the reactive graph — each item in a list gets
its own reactive node, changes to individual items fire only that item's
observers, and writes are intercepted via Proxy-style transparent mutation.

**Why considered:** Solid.js does this and it's ergonomically clean for deeply
nested state.

**Why rejected:** Fights R's copy-on-write semantics. Solid's approach depends
on mutable objects and JavaScript's `Proxy` — both unavailable in R without
significant ceremony. It would also duplicate `Each`/`Fields` without adding
expressivity, and the recursion has no natural bound: arrays of objects of
arrays create unbounded reactive trees.

**Key discussion points:** Dynamic shape breaks the static-shape invariant
central to the store design. The problems array-recursion solves (per-field
granularity within items, writable references into items) are rare in
practice — the current architecture (store owns structure, `Each`/`Fields` own
per-item reactivity) is clean and small. Adding array recursion would be a
3–5× complexity jump for edge cases. Solid can do this because JS `Proxy`
makes transparent reactive reads free at every level; R has no equivalent.
Note: one-way mini-stores inside `Each` (the chosen design) avoid this trap by
bounding recursion at the store's own rule — unnamed lists stay atomic, so
mini-stores are one level deep by construction.

---

### A2. Full lens/traversal store API (`focus`, `where`, `collect`, `modify`)

**What:** A Haskell-style lens API over stores: `focus(state, "user.name")`
returns a read-write lens; `where(state$todos, \(t) t$id == 1)` returns a
filtered traversal; `collect` reads all; `modify` writes all.

**Why considered:** Lenses are a principled abstraction for operating on deeply
nested immutable data. They compose cleanly for bulk updates.

**Why rejected:** This is a second parallel API alongside the callable model —
not a complement to it. Every store would expose two interaction models. The
callable model already handles everything lenses do, without introducing a new
concept for users to learn. YAGNI.

**Key discussion points:** Implementing traversals inside the store requires
dynamic reactive nodes, key-based identity tracking, and observer lifetime
management — all machinery that overlaps with what `Each`/`Fields` already do.
purrr already covers the read-traversal shapes (`modify_if`, `keep`, `map`,
`pluck`, `assign_in`, `detect`) on nested R lists, which is exactly the store's
data model. The gap between lenses and the callable model is real but narrow;
it can be closed additively later without breaking anything. Rejected for v1 on
YAGNI grounds — the current design covers ~90% of use cases.

---

### A3. `focus` helper for writable field references into collections

**What:** A focused reference: `f <- focus(state$todos, \(t) t$id == 1)` returns
a callable that reads/writes the matching item. Similar to a reactive selector.

**Why considered:** Cleaner than read-transform-write for common per-item
mutations. Would eliminate the `modify_if(state$todos(), ...)` pattern.

**Why deferred:** Observer lifetime is unclear when the matching predicate no
longer matches any item — the focus would return `NULL` or error, and anything
downstream would need to handle that. Deferred until real use cases surface the
right semantics.

**Key discussion points:** A plausible implementation routes reads through an
`observe` + `reactiveVal` pair (so `reactiveVal`'s equality check gates
propagation) and routes writes through a recursive path-update function. The
result is still a callable node — no second API shape. But it introduces
observer-lifetime concerns and a new concept ("focused reactive") that users
would need to learn alongside store nodes. Real user code hitting the gap is
needed before the right semantics (predicate paths vs key-based paths) become
clear.

---

### A4. Single root `reactiveVal` holding entire state

**What:** One `reactiveVal` at the root containing the entire nested list. Reads
access `state()$user$name`; writes replace the whole tree.

**Why considered:** Simplest possible implementation. No internal structure.

**Why rejected:** `state()$user$name` registers a dependency on the entire state
tree. Changing `todos` invalidates components reading `user$name` — the entire
purpose of fine-grained reactivity is defeated.

**Key discussion points:** The store's leaf-`reactiveVal` + branch-`reactive`
split is specifically designed to avoid this: leaves are the source of truth,
branches are derived views. Any change invalidates only the observers of the
affected leaf plus any branch nodes above it — not the whole tree.

---

### A5. `makeActiveBinding` for transparent read/write

**What:** Use R's `makeActiveBinding` to make `state$user$name` behave as a
reactive on read/write without call syntax — so `state$user$name` reads
reactively and `state$user$name <- "Bob"` writes.

**Why considered:** More idiomatic R syntax. Closer to how data frames work.

**Why rejected:** `makeActiveBinding` only works one level deep on environments.
More importantly, it obscures the fact that each node is a function — nodes
can't be passed as reactive arguments to irid tags without extra wrapping. The
consistency of "call it to read, call it with a value to write" is more valuable
than saving a pair of parentheses.

**Key discussion points:** The unified callable model's real value is
passability: a store leaf, a branch, a standalone `reactiveVal`, and a
per-item accessor inside `Each` are all the same shape — zero args reads, one
arg writes — so components never need to know what kind of reactive they
received. `makeActiveBinding` breaks this: a bare binding can't be passed as a
value without triggering the active binding's read path.

---

### A6. Assignment syntax (`state$x <- "Bob"`)

**What:** Implement `$<-.store_node` so that `state$user$name <- "Bob"` writes
the leaf.

**Why considered:** Idiomatic R. What users from Shiny's `reactiveValues` would
expect.

**Why rejected:** `$<-.store_node` must return a _modified copy_ of the parent —
this is how R's copy-on-write replacement works. For reference semantics (all
observers sharing the same store object), this doesn't work. The store is a
reference, not a value; assignment semantics would silently create a copy rather
than mutating in place. Consistency with `reactiveVal` (call to read, call with
value to write) is more valuable.

**Key discussion points:** The `state$user$name("Bob")` callable form is also
more important for composability (see A5 above). R's `$<-` replacement operator
is fundamentally a value-copy operation; making it work on a reference type
requires non-obvious tricks and produces confusing behavior when the result isn't
reassigned to the parent.

---

## B. Iteration design alternatives

### B1. Single `For` primitive for both records and collections

**What:** One primitive — `For(x, fn)` — that handles both records (field
iteration) and collections (item iteration), detecting which case applies at
runtime.

**Why considered:** One concept instead of two (`Fields` and `Each`).

**Why rejected:** Records and collections have fundamentally different callback
shapes. Record iteration passes `(node, key)` — the node is a callable, the key
is a string, and the shape is static (no reconciliation). Collection iteration
passes `(item, index)` — the item is a mini-store or accessor, and
reconciliation is needed for add/remove/reorder. A single primitive would need
to overload or dispatch on the data type, conflating two operations with
different semantics under one name.

**Key discussion points:** The record-vs-collection distinction also mirrors the
store's own named-vs-unnamed rule — named lists recurse into branches (records),
unnamed lists stay atomic (collections). Splitting iteration the same way means
one mental model covers both state shape and iteration shape. A unified `For`
would force dispatch on the argument type and pass different callback shapes with
different key semantics (string vs position/by-key): possible but a complicated
dispatch rule that most users would need to learn. Two primitives with crisp names
is cleaner.

---

### B2. Split by diffing strategy instead of by data shape

**What:** Two primitives distinguished by how they reconcile: one for positional
reconciliation, one for keyed reconciliation.

**Why considered:** Positional vs keyed is the technical axis that matters for
implementation.

**Why rejected:** This is an implementation axis, not a user-facing one. Users
think "I'm iterating a record" or "I'm iterating a collection" — not "I want
positional reconciliation." The data-shape axis (`Fields` for records, `Each`
for collections) maps onto the store's own named-vs-unnamed rule and gives users
one mental model for state shape and iteration shape. Keyed reconciliation is
opt-in via `by` within `Each`.

**Key discussion points:** In practice, users already choose between the old
`Index` (positional) and `Each` (keyed) based on data shape — a fixed set of
slots where values change vs a dynamic list where items come and go. That is a
"what is iterated" distinction dressed up as a "diffing strategy" distinction.
Making the split explicit by record vs collection surfaces the real distinction.
It also frees up `Fields` to take on its correct role (iterate the children of a
store branch — a structurally different thing from iterating a collection that
deserves its own name) and frees `Each` to handle all collection cases with an
optional `by` argument.

---

### B3. No per-item mini-stores in `Each` (edit-draft only)

**What:** Keep `Each` items as plain values or read-only accessors. For
field-level edits, always use the edit-draft pattern (spin up a store, edit
through it, write back on save).

**Why considered:** Simpler `Each` implementation. The edit-draft pattern from
`stores1` already worked for field-level edits.

**Why rejected:** Edit-draft is ceremony that's only justified when you need
cancel/discard semantics. For inline edits — toggling a checkbox, editing text
in place — the ceremony is pure overhead with no payoff. Mini-stores give
field-level reactivity and auto-bind by default; edit-draft remains available
for modal workflows.

**Key discussion points:** The old `Each` had a footgun: it silently ignored
value changes for kept items (items whose key matched across reconcile passes
had their DOM left unchanged even if their data changed). Gaining per-item
accessors in `Each` fixed this. The edit-draft pattern (spin up
`reactiveStore(item)` on edit start, write the snapshot back on save) is still
the right shape for modal workflows with cancel/discard — it just isn't the
default for every collection item.

---

### B4. Two-way mini-stores (leaf writes propagate bidirectionally)

**What:** Mini-store leaves hold independent reactive state. `todo$done(TRUE)`
writes directly to the leaf, then propagates back to the parent collection via
an observer or similar mechanism.

**Why considered:** More intuitive write semantics — the leaf "feels" like a
real reactive value.

**Why rejected:** Creates circular reactive flow: leaf write → parent write →
reconcile → leaf patch. Settling this requires guard flags (`is_propagating`) or
identity checks to prevent infinite loops. One-way mini-stores avoid the problem
entirely: the parent is the single source of truth, mini-store leaves are
projections with synthetic setters, and the reactive graph is acyclic. The user
experience is identical.

**Key discussion points:** One-way mini-stores are projections of collection
items. Each per-key entry in `Each`'s internal map holds a read-only
`reactiveStore(item)` (for records) or a `reactiveVal` (for scalars). Writes
through a mini-store leaf (e.g. `todo$done(TRUE)`) use a synthetic setter that
internally does `todo(modifyList(todo(), list(done = TRUE)))` — routing the write
through the parent collection. The reconcile pass that follows flows strictly
parent → mini-store, patching only changed leaves. No circular flow, no guard
flags. From the user's perspective `todo$done(TRUE)`, `todo(modifyList(...))`,
and `checked = todo$done` (auto-bind) are all equivalent — the data-flow
direction is invisible.

---

## C. Write-control alternatives

### C1. React-style `value`/`onChange` pairs everywhere

**What:** Components accept separate `value` (reactive) and `onChange`
(callback) props. The parent always provides both and can intercept writes by
providing a custom `onChange`.

**Why considered:** This is the React model. It gives the parent explicit
control over every write.

**Why rejected:** Kills composability. Every component boundary needs both props
threaded through. Recursive patterns like `RenderNode` / `Fields` become verbose
— `Fields` would need to thread `onFieldChange` callbacks alongside nodes. The
value/callback pair also splits bidirectional transforms across two props (read
transform in `value`, write transform in `onChange`), and callers must keep them
in sync manually. The common case (just bind to state) requires the full pair
even when no interception is needed.

**Key discussion points:** The scorecard in the write-control pattern evaluation
gave this pattern (b) a `--` on composability and a `--` on third-party
support (it only works if the third-party component happens to use
value/onChange convention — irid ecosystem components accept a single callable,
so pattern (b) has no answer at all). Branch-passing (`ColorPicker(state$color)`,
`Fields(state$user, RenderNode)`) is impossible — components would need four
props for two fields, and the recursive `RenderNode` case becomes `\(getter,
setter, key)` with explicit plumbing at every level. The counterargument
(one extra prop makes write paths visible everywhere) doesn't outweigh these
costs in an R context where convention-as-enforcement is the norm.

---

### C2. Auto-bind + optional `onChange` on components

**What:** Components accept a state callable for auto-bind, plus an optional
`onChange` callback that, if provided, overrides the write path on that specific
element. Component author decides which fields are interceptable by exposing
optional `onChange` params.

**Why considered:** Common case is clean (just pass the callable). Validated
case adds one prop without breaking the component API.

**Why rejected:** Component author burden — every component that might need
write interception must pre-emptively expose an `onChange` param and collapse it
internally. Fields not exposed can't be intercepted, even if the parent needs
to. The component author decides at definition time which fields are
interceptable — a decision that should belong to the call site.

**Key discussion points:** The write-control pattern evaluation scored this
pattern (c) as adequate for common-case simplicity and validated-case ceremony,
but weak on composability and third-party support. A component author must
collapse internally: `onInput = \(e) if (!is.null(onChange)) onChange(e$value)
else field(e$value)` — boilerplate on every component that wants to be
constrainable. Adding a constrainable field means changing the component
signature at every intermediate level. For components you don't control
(third-party packages), this pattern has no answer. `reactiveProxy` supersedes
it: the parent wraps the callable before passing it, so no component author
coordination is needed.

---

### C3. `onInput` as auto-bind write-control override

**What:** Providing `onInput` on an auto-bound element disables auto-bind's
write path and gives the handler full control. The component sees only the
element-level event.

**Why considered:** Simpler than `reactiveProxy`. No new concept — just an
interaction rule between two existing mechanisms.

**Why rejected:** DOM-level only — can't intercept writes through a component
you don't control. Write-only — bidirectional transforms require split-prop
approach (read in `value`, write in `onInput`). And "providing `onInput`
disables auto-bind" is a non-obvious special case interaction. `reactiveProxy`
replaces this mechanism entirely: it wraps the callable (not the element), so it
works at any boundary and handles both read and write transforms.

**Key discussion points:** Three concrete limitations drove the replacement:
(1) `onInput` only works at the DOM element level — it cannot intercept writes
through a component you don't control; (2) bidirectional transforms (temperature
conversion, currency formatting) required a read-only closure on `value` and a
write handler on `onInput`, split across two different props and requiring manual
synchronization; (3) "providing `onInput` disables auto-bind" is a surprising
special-case interaction between two concepts — not obvious without reading the
docs. `reactiveProxy` solves all three: it wraps the callable itself, so it
works at any boundary (including components that accept a single callable without
exposing any `onInput`), it holds `get` and `set` in one place, and it
introduces no special-case interactions with auto-bind (a proxy is just another
callable).

---

### C4. Separate getter/setter API (Solid-style `c(x, set_x) %<-% ...`)

**What:** A destructuring assignment that returns a getter/setter pair:
`c(x, set_x) %<-% reactiveVal(0)`. Callers pass the getter and setter
separately, making the write path explicit everywhere.

**Why considered:** Explicit write paths. The "who can write" question is
answered by whether you received the setter.

**Why deferred:** The unified callable model already covers all the cases this
addresses. `reactiveProxy` covers write control. The getter/setter split adds
ceremony to the common case for a benefit (`set_x` can be withheld to enforce
read-only) that `\() x()` already provides at lower cost. Deferred as a valid
future direction, not needed now.

**Key discussion points:** The counterargument from the design-anti analysis:
R closures defeat capability control regardless — any function can capture
anything from its enclosing scope, so withholding a setter provides convention,
not enforcement, in the same way `\() x()` does. The composability case is
stronger: branch-passing and recursive iteration (`Fields(node, \(node, key)
...)`) are clean with unified callables; they become verbose with getter/setter
pairs (`Fields(node, \(getter, setter, key) ...)`) with explicit plumbing at
every level. The read-only passing pattern (`MyDisplay(value = \() x())`) is
available without adding a new primitive. Deferred rather than rejected because
zeallot-style destructuring remains a valid future direction compatible with the
unified callable model.

---

## D. Traversal / helper alternatives

### D1. Traversal helpers (`store_modify_if`, `update(node, f)`, `%<>S%`)

**What:** A family of store-aware helpers for common update patterns:
`store_modify_if(state$todos, \(t) t$id == 1, \(t) modifyList(t, list(done = TRUE)))`;
a pipe-style `%<>S%` operator that reads, transforms, and writes back.

**Why considered:** The read-transform-write pattern for atomic list nodes is
verbose. Helpers would DRY it up.

**Why rejected:** purrr already covers these shapes (`modify_if`, `keep`,
`map`). Adding store-specific versions would duplicate purrr for marginal
ergonomic benefit, and explicit read-transform-write is already clear. The
boilerplate cost is real but bounded — it only shows up for collection-level
mutations, not per-field ones (which `Each` mini-stores handle).

**Key discussion points:** R's copy-on-write semantics make the read-transform-
write idiom safe and obvious: `state$todos(modify_if(state$todos(), ...))` tells
the reader exactly what happens — read the node, transform, write the node.
purrr verbs (`modify_if`, `modify_at`, `modify_in`, `keep`, `map`, `pluck`,
`assign_in`, `detect`) already operate on nested R lists, which is the store's
data model. Users who know purrr already know how to traverse the store. A
helper like `update(node, f)` or `%<>S%` saves a few characters but hides the
read/write pair behind a new concept. Also, R's COW means `state$todos()` can
hand out the real underlying list at zero cost — the copy only materialises if
the caller actually modifies it — so there's no performance reason to wrap the
pattern either.

---

### D2. `distinct()` as a general primitive

**What:** A `distinct(reactive_expr)` wrapper that only fires downstream
observers when the value actually changes (by reference or by value), filtering
out no-op updates.

**Why considered:** Small, independent utility with broad value. Prevents
unnecessary re-renders when a reactive expression happens to produce the same
value on consecutive evaluations.

**Status:** Still open. Not rejected — independent of the store design and could
ship separately. No decision made.

**Key discussion points:** `reactiveVal` already provides distinct-until-changed
on writes (it checks equality before firing), so the pattern is expressible
today:

```r
distinct <- function(expr) {
  out <- reactiveVal(NULL)
  observe(out(expr()))
  out
}
```

The question is whether to surface this as a first-class helper. The case for:
it has broad value everywhere in reactive code, not just with stores; it's small
and independent; and it unlocks fine-grained downstream behavior without pulling
any lens/focus machinery. The case against: the workaround above is already
idiomatic and not much to write. Decision deferred alongside the rest of the
lens/focus work.
