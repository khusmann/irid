# Alternatives Considered

Orthogonal ideas evaluated during the reactive system design. Each entry covers
what it is, why it was considered, why it was rejected or deferred, and where
the discussion lives.

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

**Discussion:** `dev/stores1/irid-store-design-theory.md` §3.1.

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

**Discussion:** `dev/stores1/irid-store-design-theory.md` §3.

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

**Discussion:** `dev/stores1/irid-store-design-theory.md` §3.

---

### A4. Single root `reactiveVal` holding entire state

**What:** One `reactiveVal` at the root containing the entire nested list. Reads
access `state()$user$name`; writes replace the whole tree.

**Why considered:** Simplest possible implementation. No internal structure.

**Why rejected:** `state()$user$name` registers a dependency on the entire state
tree. Changing `todos` invalidates components reading `user$name` — the entire
purpose of fine-grained reactivity is defeated.

**Discussion:** `dev/stores1/irid-store-design.md` §7.

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

**Discussion:** `dev/stores1/irid-store-design.md` §7.

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

**Discussion:** `dev/stores1/irid-store-design.md` §7.

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

**Discussion:** `dev/stores1/stores-and-iteration-design.md` §"Design
decisions".

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

**Discussion:** `dev/stores1/stores-and-iteration-design.md` §"Design
decisions".

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

**Discussion:** `dev/stores2/design.md`, `dev/stores3/design.md` §"Design
decisions".

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

**Discussion:** `dev/stores2/design.md`, `dev/stores3/design.md` §"Why one-way
mini-stores".

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

**Discussion:** `dev/stores2/design-anti.md`,
`dev/stores2/with-setter-validate/verdict.md` pattern (b).

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

**Discussion:** `dev/stores2/with-setter-validate/verdict.md` pattern (c).

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

**Discussion:** `dev/stores3/design.md` §"Why `reactiveProxy` instead of
`onInput`", `dev/stores2/with-setter-validate/verdict.md`.

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

**Discussion:** `dev/stores2/design-anti.md`, `dev/stores2/design.md` §"What
this design is not".

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

**Discussion:** `dev/stores1/irid-store-design-theory.md` §3.

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

**Discussion:** `dev/stores1/irid-store-design-theory.md` §3.
