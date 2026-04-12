# irid Store — Design Theory

Companion to `irid-store-design.md`. This document captures the reasoning behind the store design, the alternatives considered, and how the design would translate to a Python port.

---

## 1. The store as optics

The store maps cleanly onto optics (lenses and traversals).

### Lenses

Every store node is a **lens** — a composable (get, set) pair focused on a part of the state:

- `state$user$name()` — getter
- `state$user$name("Bob")` — setter
- `state$user$name` — the lens itself, passed as a value

`$` chaining is **lens composition**: `state$user$name` composes root → user → name. `[[` path expressions are the same composition done dynamically rather than statically.

Branch nodes are **compound lenses with patch semantics**. The setter only requires the fields being updated, which makes them closer to affine / partial setters than to total lenses.

### Traversals (and where they live)

A **traversal** is an optic that focuses on multiple elements — e.g. "every done todo's text field." Traversals need both get (collect) and set (update-each) operations.

irid deliberately does not provide traversals *inside* the store. The atomic list boundary is where the optics stop. Per-item iteration lives in `Index` / `Each`, and per-item writes are handled by the read-transform-write pattern on the atomic list `reactiveVal`.

Importantly, `Index` and `Each` are **folds** (read-only iteration), not true traversals. `Index` gives you a reactive accessor per position; `Each` gives you a bare value. Neither provides a writable reference to an individual item's field. Write-side traversal in irid is ad-hoc R code (`modify_if`, `map`, etc.), not a first-class optic.

### Why this split is the right cut point

Lenses compose trivially (chain getters and setters). Traversals introduce multiplicity and identity tracking (which items matched? how do references survive splices?). Keeping those concerns separate is what keeps the store design small and principled. The moment you put traversals inside the store, you need dynamic reactive nodes, key-based identity, and machinery that overlaps with what `Index`/`Each` already do.

---

## 2. Comparison with Solid

Solid's `createStore` solves the same problem but with a very different factoring.

### Solid's approach

Solid's store recursively wraps objects *and* arrays in proxies. Every field at every level — including array items — becomes its own reactive node. Reads look like plain property access (`store.todos[0].text`); the proxy tracks them invisibly. Writes go through a separate `setStore` function that accepts path expressions:

```js
setStore("user", "name", "Bob")                            // lens
setStore("todos", 0, "text", "Buy eggs")                   // lens into array
setStore("todos", t => t.done, "text", "completed")        // traversal (predicate)
setStore("groups", 0, "members", m => m.active, "role", "admin")  // nested
```

The path syntax is an optics DSL expressed as variadic arguments: strings are lenses, predicates are traversals, indices are array lenses, and `setStore` composes them left to right.

### Read traversals in Solid

Interestingly, Solid does not provide a first-class "collect" operation for read-side traversals. You just write normal JS on the proxy:

```js
const doneTexts = () => store.todos.filter(t => t.done).map(t => t.text)
```

Because every property read is proxy-tracked, this expression is automatically reactive at field-level granularity. Read traversals are implicit; write traversals are explicit.

### Solid's factoring in a table

|           | Read                                               | Write                                     |
|-----------|----------------------------------------------------|-------------------------------------------|
| Lens      | `store.user.name` (proxy, transparent)             | `setStore("user", "name", x)`             |
| Traversal | `store.todos.filter(...).map(...)` (proxy, transparent) | `setStore("todos", pred, ...)`         |

### Why Solid can do what it does

JS proxies make transparent reactive reads free at every level. You can recurse into arrays without any syntactic cost — `store.todos[0].text` just works. The read/write split into proxy + `setStore` is a capability boundary: you can pass the read-only proxy to a child component without granting write access.

### Why irid factors differently

R has no proxies, so transparent reactive reads are not available. Reads require call syntax at every level. This makes recursing into arrays expensive both syntactically and semantically — dynamic reactive nodes would need to be created and destroyed as items are added and removed, and `$` chains cannot express predicate paths at all. Atomic list nodes + external iteration (`Index`/`Each`) avoids all of this, at the cost of a composability gap for per-item field references.

Solid also has a visible redundancy: traversals exist both in the store (via `setStore` paths) and in rendering (`For` / `Index`). This is because proxies make both sides cheap and they serve different roles. irid's cleaner factoring — one traversal system, outside the store — is a consequence of needing to pick one place to pay the cost.

---

## 3. Alternatives considered and rejected

### Fine-grained reactivity on arrays (Solid-style)

Could irid recursively wrap arrays, creating a reactive node per item per field? Technically yes. We chose not to because:

- It fights R's copy-on-modify semantics
- Dynamic shape breaks the static-shape invariant
- It duplicates `Index`/`Each`
- The problems it solves (per-field granularity within items, writable references into items) are rare in practice

The current architecture — store owns structure, `Index`/`Each` own per-item reactivity — is clean and simple. Adding array recursion would be a 3-5× complexity jump to solve problems that typically don't bite.

### A full lens/traversal store API

Could we add a richer API with explicit `focus`, `where`, `update`, `collect`, `modify` verbs that handles lenses and traversals uniformly?

Sketch:

```r
done_texts <- state$todos |> where(\(t) t$done) |> focus("text")
collect(done_texts)                # reactive read
update(done_texts, "completed")    # write all
modify(done_texts, toupper)        # functional update
```

This reaches Solid's expressive power, but at significant cost: a second API in parallel with the callable-node API, two shapes of focus objects (lens = callable, traversal = not), dynamic keyed arrays for identity tracking, and observer lifetime management.

We rejected this for v1 on YAGNI grounds. The original design covers ~90% of use cases. The gap is real but narrow, and can be closed additively later without breaking anything.

### A `focus` helper for writable field references

A narrower version of the above: one helper that creates a writable reactive reference to any path, including through predicates into atomic lists.

```r
done_1 <- focus(state$todos, \(t) t$id == 1, "done")
done_1()           # read — distinct until changed
done_1(TRUE)       # write — read-transform-write under the hood
```

Implementation: route reads through an `observe` + `reactiveVal` pair (so `reactiveVal`'s equality check gates propagation), and route writes through a recursive path-update function.

This closes the composability gap without introducing a second API — the returned object is still a callable node. But it introduces observer-lifetime concerns and a new concept ("focused reactive") that users would need to learn alongside store nodes.

**Decision: defer.** Wait for real user code to hit the gap before shipping this. If it happens, we will also know whether users want predicate paths, key-based paths, or something else — easier to design once the use cases are concrete.

### A general `distinct()` primitive

Separately from lenses, distinct-until-changed is broadly useful in reactive code — not just for stores. Shiny's `reactive()` does NOT provide this: when a `reactive()`'s dependencies invalidate, it propagates invalidation to its dependents immediately, even if re-running would produce the same value. `reactiveVal` *does* have the equality check on writes, which is how you build distinct-until-changed in Shiny:

```r
distinct <- function(expr) {
  out <- reactiveVal(NULL)
  observe(out(expr()))
  out
}
```

**Decision: consider shipping as a general helper.** It is small, has broad value, and is independent of the store design. It unlocks fine-grained downstream behavior when users need it, without pulling any lens/focus machinery along with it.

### Traversals: just read-transform-write with purrr

The store deliberately does not ship a traversal vocabulary. Item-level updates on atomic lists are expressed directly with purrr, calling the node to read and calling it with the result to write:

```r
# Update matching items
state$todos(modify_if(state$todos(), \(t) t$id == 1, \(t) modifyList(t, list(done = TRUE))))

# Filter
state$todos(keep(state$todos(), \(t) !t$done))

# Map over all
state$todos(map(state$todos(), \(t) modifyList(t, list(touched = TRUE))))
```

Read traversals are even simpler — just call the node and pipe the result through purrr:

```r
done_texts <- state$todos() |> keep(\(t) t$done) |> map_chr("text")
```

This is already reactive (the call registers a dependency) and purely idiomatic purrr.

**Why no helpers:**

- **Explicit beats clever.** `state$todos(modify_if(state$todos(), ...))` tells the reader exactly what happens: read the node, transform, write the node. A helper like `update(node, f)` or a `%<>S%` operator saves a few characters but hides the read/write pair behind a new concept the reader has to learn.
- **No new vocabulary.** purrr verbs already cover the lens and traversal shapes we'd want (`modify_if`, `modify_at`, `modify_in`, `keep`, `map`, `pluck`, `assign_in`, `detect`). They operate on nested R lists — which *is* the store's data model. Users who know purrr already know how to traverse the store.
- **No API proliferation.** No `store_modify_if` / `store_keep` / etc. namespace. No single `update()` helper either. The store surface stays exactly at "call the node to read, call it with an argument to write."
- **The boilerplate is tolerable.** Repeating `state$todos` once per update is small friction, and it makes the reactivity boundary visible at both ends of the operation — you can see where the read happens and where the write happens.
- **Composable with plain purrr.** Store reads and regular purrr pipelines share a data model, so they mix freely with no glue code.

**Why dplyr verbs are a worse fit than purrr:** dplyr's vocabulary assumes tabular data — tibbles and data.frames. A store holding a list of records could be coerced back and forth, but (a) it requires NSE and tibble machinery, and (b) many store nodes won't be rectangular (e.g. a `user` branch with mixed scalar fields), so dplyr verbs would only apply to a subset of the store. purrr verbs work on any nested list, which matches the store's model exactly.

**Decision: no traversal helpers.** Use the read-transform-write pattern directly with purrr. Document the idiom clearly; do not wrap it.

### Why this pattern is so clean in R: value semantics

The read-transform-write idiom is only safe and obvious because R lists are copy-on-write. When a caller writes:

```r
xs <- state$todos()       # logically a copy (COW defers the actual copy)
ys <- modify_if(xs, ...)  # ys is a new list; xs and store are unchanged
state$todos(ys)           # explicit write — the only way store state changes
```

...nothing the caller does to `xs` or `ys` can affect the store. The store only ever sees new state through an explicit write call. There is no aliasing, no defensive copying, no "did I just mutate the store by accident?" class of bug. R's COW also means `state$todos()` can hand out the real underlying list at zero cost — the copy only materialises if the caller actually modifies it.

This is a language-level gift. The entire atomic-list design leans on it: the store can expose its internal list wholesale because the language guarantees mutation isolation.

### Implications for py-irid

Python lists and dicts are mutable reference types, so the naive port of this pattern is unsafe:

```python
xs = state.todos()        # reference to the store's internal list
xs.append(new_item)       # silently mutates the store — no write, no invalidation
```

py-irid has to restore the invariant "the store only changes through explicit writes" at the language boundary. Options:

1. **Persistent data structures (pyrsistent or similar).** `PMap` / `PVector` throughout. Cleanest semantics — matches R's COW directly. `state.todos()` returns a persistent structure that's immutable *and* has ergonomic update methods (`.set`, `.transform`, `.evolver`). Cost: a dependency, users learning PMap/PVector, and persistent structures are slower than native dicts/lists for read-heavy workloads.
2. **Immutable views at the boundary.** `tuple` instead of `list`, `types.MappingProxyType` instead of `dict`. Mutation attempts fail loudly. No new dependency. But every item update requires a "convert to mutable, modify, convert back" ritual:
   ```python
   todos = list(state.todos())
   todos[0] = {**todos[0], "done": True}
   state.todos(tuple(todos))
   ```
   The ceremony breaks the read-transform-write flow that is so clean in R — exactly where the atomic-list design is already at its weakest.
3. **Defensive copies on every read.** Safe, expensive, breaks identity comparisons. Only viable for small stores.
4. **Document "treat the return value as immutable" and trust the user.** Cheapest, least safe. Most reactive Python libraries do this.

**Recommendation: option 1, pyrsistent.** It is the closest we can get in Python to R's value semantics, and the whole atomic-list design depends on those semantics to stay clean. Option 2 looks cheaper on paper but the list-item update path is the weakest point of the design, and saddling it with a mutable/immutable conversion ritual damages the idiom more than a well-known dependency does.

With pyrsistent, updates read similarly to the R form:

```python
# Whole-list replacement
state.todos(state.todos().set(0, state.todos()[0].set("done", True)))

# Or with evolver for multiple edits
todos = state.todos().evolver()
todos[0] = todos[0].set("done", True)
state.todos(todos.persistent())
```

Still more verbose than Solid, but internally consistent with the rest of py-irid and free of the "convert back and forth" clerical work. pyrsistent is mature and widely used in typed Python codebases, so it is not an exotic dependency.

---

## 4. Python port

The architecture transfers well. The syntax requires a choice.

### What transfers cleanly

- Static shape at construction time (and Python's type system — dataclasses, TypedDict, pydantic — makes this *better* than in R, with IDE support and static checking)
- Atomic list boundary (same tradeoff applies)
- Lens/traversal distinction (language-independent)
- Leaves-as-source-of-truth, branches-as-derived, one-way data flow

### What the language enables

Python has `__getattr__`, `__setattr__`, `__getitem__`, `__call__`, and descriptors. You can intercept attribute access the way JS proxies do. So the natural idiomatic Python design could look like Solid:

```python
state.user.name             # read (tracked reactively)
state.user.name = "Bob"     # write
state.user = {"name": "Eve"}  # patch write
```

This is shorter and more "Pythonic" than callable nodes.

### Why we should keep callable nodes anyway

Despite Python not needing them, we recommend keeping the callable-node convention in py-irid:

```python
state.user.name()           # read
state.user.name("Bob")      # write
```

**Reasons, in priority order:**

1. **Reactive reads are syntactically visible.** The `()` is a marker that you're crossing a reactivity boundary. At a glance, a reader can tell which lines participate in the reactive graph. With transparent property access, `x = state.user.name` and `x = some_dict["user"]["name"]` look identical but behave completely differently. This is the same class of bug that Solid's docs constantly warn about — destructuring or assigning out of reactive scope accidentally freezes values. Callable nodes make that mistake hard to make silently.

2. **Cross-language parity.** Users moving between r-irid and py-irid learn one mental model. The core primitives read and write the same way.

3. **Matches Shiny for Python's existing reactive idiom.** Shiny for Python already uses callable syntax for reactives (`input.x()`, reactive values). py-irid would extend a convention users in that ecosystem already know — not invent a new one.

4. **Writable handles are trivial.** Just pass the node. No `Signal` / `bind` wrapper needed to give a component a get-and-set reference.

5. **Unified rule.** "Call it to read, call it with an arg to write" works everywhere — leaves, branches, substores. No special cases.

### What we pay in Python

- **Type ergonomics.** `state.user.name` has type `Node[str]`, not `str`. Chained value methods don't work: `state.user.name.upper()` fails; you need `state.user.name().upper()`. Recoverable with a metaclass or codegen that generates typed `Node[T]` subclasses from a schema, if the pain becomes real.
- **Assignment writes are not supported.** `state.user.name = "Bob"` would be the natural Python spelling, and we're choosing not to offer it. Supporting both forms would muddy the "call syntax = reactive boundary" signal.
- **Persistent data structures for list nodes.** List-item updates go through pyrsistent's API (`.set`, `.evolver`) rather than native list mutation. A second small idiom to learn on top of callable nodes.
- **Unusual for generic Python code.** Users not coming from Shiny for Python will need to learn the idiom.

We accept these costs in exchange for visibility, parity, and consistency.

### Accumulated friction — an honest acknowledgment

Individually each cost is defensible. Together, py-irid starts to feel like R idioms forced through a Python-shaped hole: callable reads instead of property access, no assignment writes, `Node[T]` wrappers instead of bare values, pyrsistent structures instead of native dicts/lists. A Python developer coming in fresh may reasonably ask: "why all this ceremony instead of a Solid-style proxy store?"

The case for paying the cost rests on three things:

1. **Cross-language parity is a real goal.** Users who move between r-irid and py-irid genuinely benefit from one mental model.
2. **Shiny for Python already normalized callable reactives.** py-irid is not inventing a new convention — it is extending one this ecosystem already uses.
3. **Reactive-boundary visibility is genuinely useful.** The `()` marker at every reactive read is not a consolation prize; it is a substantive advantage over transparent proxy reads.

If any of those three premises weakens — if most py-irid users never touch R, if Shiny for Python's conventions shift, or if a team decides visibility matters less than ergonomics — then the case for the unified design gets thinner, and diverging becomes reasonable.

### Path not taken: a Solid-style py-irid

Worth naming for completeness. An alternative py-irid would keep the conceptual model (static shape, atomic-list boundary or not, lens/traversal split, one-way flow) but use Python's `__getattr__` / `__setattr__` / `__getitem__` / descriptor machinery for the surface:

```python
state.user.name             # transparent reactive read
state.user.name = "Bob"     # __setattr__-intercepted write
update(state.todos, where=lambda t: t["done"], text="completed")  # traversal write
```

This would feel native to Python, lose the visibility benefit, and diverge from r-irid on the surface. It is the right choice if Python users are the overwhelming majority and cross-language parity stops mattering. It is the wrong choice if parity is load-bearing — at that point you may as well pick an existing Solid-inspired reactive library and stop trying to share a design with R.

We do not recommend this path, but we record it so future maintainers know it was considered and why.

### Predicate writes in Python

`state.todos[lambda t: t.done].text = "X"` is technically expressible via `__getitem__` proxies, but it is not idiomatic Python. If py-irid eventually adds traversal writes, they should use a function-call form matching Solid's `setStore`:

```python
update(state.todos, where=lambda t: t["done"], text="completed")
```

Same deferral applies: ship without it, add later if needed.

---

## 5. Design rule of thumb

When deciding whether to add something to the store, ask:

> Does this need to know the store's structure to work, or is it just reactive code that happens to be using the store?

- **Needs store structure** → belongs in the store. Lens composition, shape validation, branch patches, static paths.
- **Just uses the store** → lives outside. Traversals, `distinct`, filters, `Index`/`Each`, helpers built on top of the public node API.

This keeps the store core small and principled. Things *around* the store can grow freely without making the core more complex.

---

## 6. What to ship

**v1 — both languages:**

- Callable-node store: `$` / `.` chaining, `[[` / `[]` dynamic paths, patch semantics, atomic lists, shape validation
- `load_store` for snapshot restore
- Clean interop with `Index` / `Each`
- Callable-node syntax as the unified convention across R and Python

**Consider as a small independent primitive:**

- `distinct()` — general distinct-until-changed wrapper. Valuable everywhere, not just with stores. Cheap to ship.

**Explicitly not shipping:**

- Traversal helpers (`update(node, f)`, `%<>S%`, `store_modify_if`, etc.). Use the read-transform-write pattern directly with purrr — explicit is clearer than clever.
- A dedicated optics vocabulary (`collect`, `modify`, `where`, etc.). purrr already covers this shape.

**Defer until real use cases demand it:**

- `focus` / writable predicate references (focus objects, distinct-until-changed through paths)
- Solid-style recursive arrays with per-item fine-grained reactivity

---

## 7. Tradeoffs we are explicitly accepting

- **No writable references into list items.** Components inside `Index` either take the whole item or do read-transform-write on the list. Real gap vs Solid; worth it for a minimal store.
- **O(N) writes on atomic lists.** Every item update rebuilds the whole list. Fine at typical sizes; not fine at 100k+. Document it.
- **No capability boundary.** Any code with a node reference can write to it. Solid's read-only proxy + separate setter gives better encapsulation. We trade that for the unified callable-node ergonomic.
- **Python loses some native type ergonomics.** We prioritize reactive-boundary visibility and cross-language parity over `.`-chaining through value methods.
- **py-irid takes a pyrsistent dependency.** Persistent data structures restore R-like value semantics at the language boundary. The alternative — tuple/MappingProxyType views with a mutable-working-copy ritual — would damage the read-transform-write idiom more than the dependency does.

---

## 8. One-line version

Ship the current store design — in both R and Python — with callable-node syntax as the unified convention. Add `distinct()` as a small general helper. Leave lenses, traversals, and focus on the shelf until real use cases force the question.
