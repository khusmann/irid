# irid State & Iteration — Unified Design

**Status:** Draft, April 2026.
**Supersedes:** §6 of `irid-store-design.md` (list nodes); current
`Index` and `Each` semantics in `R/primitives.R` and `R/mount.R`.
**Companion:** `irid-store-design.md` (store internals §4, edit-draft
pattern §9), `irid-store-design-theory.md`, `../index-write-asymmetry.md`.

---

## Why this doc exists

The store design in `irid-store-design.md` treats `Index` and `Each`
as given primitives that stores cooperate with. The stress test
(`state-example-*.R`) validated the store thesis but surfaced a
separate finding: the split between `Index` and `Each` cuts along
the wrong axis. Both primitives iterate *collections* with
different diffing strategies (positional vs keyed), but the real
structural distinction in irid's state layer is not diffing
strategy — it is **records vs collections**. Records have static
heterogeneous shape; collections have dynamic homogeneous shape.
Once stores land, a record is a store branch and a collection is
an atomic list node, and iteration should split along that same
axis.

This doc proposes a unified design for `reactiveStore`, `Index`,
and `Each` in which:

- **`Index` iterates *store branches*** — the children of a record,
  with each child handed to the callback as a store node (read/write
  unified callable) keyed by its field name.
- **`Each` iterates *collections*** — unnamed lists held in
  `reactiveVal`s or in atomic store leaves, with each item handed to
  the callback as a reactive accessor (read/write unified callable)
  keyed by position or by a user-supplied `by` function.

Under this split:

- The `Index` read/write asymmetry finding dissolves, because
  `Index`'s children are already store nodes.
- The "named collection" / dict gap dissolves, because a branch is
  navigable *and* iterable.
- `Each` subsumes the old `Index`-over-`reactiveVal` case by gaining
  per-item reactive accessors — in-place updates now work under both
  primitives, without DOM recreation.
- The split by "what is being iterated" is more intuitive than the
  split by "diffing strategy" and maps directly onto the store's own
  record-vs-collection rule, so there is one mental model, not two.

irid is greenfield (0.1.0.9000), so this is proposed as a breaking
redesign with no deprecation cycle.

---

## APIs at a glance

### `reactiveStore(initial)`

Unchanged from `irid-store-design.md`. Creates a hierarchical store.
Named lists recurse into branches; unnamed lists at leaf positions
stay atomic (held as a single `reactiveVal`).

```r
state <- reactiveStore(list(
  user = list(name = "Alice", email = "alice@example.com"),
  filters = list(category = "", sort = "date", page = 1L),
  todos = list(
    list(id = 1L, text = "Learn irid", done = FALSE),
    list(id = 2L, text = "Ship stores", done = FALSE)
  )
))
```

- `state$user` — branch (navigable record)
- `state$user$name` — leaf (`reactiveVal`-backed)
- `state$todos` — atomic leaf holding an unnamed list (collection)

Every node is callable. `node()` reads, `node(value)` writes.
Leaves replace; branches patch.

### `Index(branch, fn)`

Iterates the children of a store branch. Callback receives
`(child_node, key)`:

- `child_node` is a store node (a leaf or a nested branch). It is a
  read/write callable — `child_node()` reads, `child_node(value)`
  writes. Writes propagate through the store's normal write path, so
  they fire fine-grained per-leaf observers exactly as if the user
  had navigated to the child by name.
- `key` is the child's field name as a string.

Branches have static shape, so `Index` has no reconciliation — it
calls `fn` once per child at mount time, and each callback's DOM is
reactive to the child node it captured. When a leaf value changes,
only the parts of the DOM reading that leaf re-evaluate.

```r
Index(state$user, \(field, key) {
  tags$label(key),
  tags$input(
    value = field,
    onInput = \(e) field(e$value)
  )
})
```

### `Each(collection, fn, by = NULL)`

Iterates a collection — an unnamed list held in a `reactiveVal`, a
`reactive`, or an atomic store leaf. Callback receives `(item, index)`:

- `item` is a per-position reactive accessor. `item()` reads the
  current value at that position; `item(value)` writes back — Each
  closes over the parent `reactiveVal` (if writable) and splices the
  new value into the correct slot before firing.
- `index` is either the position (integer, when `by` is `NULL`) or
  the `by` key (the result of calling `by(item)`).

`by = NULL` → positional reconciliation. Slot *i* is slot *i*. The
list can grow and shrink at the end; in-place value changes fire
per-slot accessors without DOM recreation. Equivalent to the current
`Index` primitive.

`by = \(x) x$id` → keyed reconciliation. Items are tracked across
reorders, adds, and removes by their key. In-place value changes to
kept items also fire the per-item accessor — this is the critical
difference from current `Each`, which silently ignores value changes
to kept items (see §6 of `irid-store-design.md` and the mount-time
code at `R/mount.R:246-249`).

```r
# Positional — grows/shrinks at the end, in-place updates
Each(state$todos, \(todo, i) {
  tags$li(
    \() paste0(i, ". ", todo()$text)
  )
})

# Keyed — add/remove/reorder/in-place-edit
Each(state$todos, by = \(t) t$id, \(todo) {
  tags$li(
    tags$input(
      type = "checkbox",
      checked = \() todo()$done,
      onClick = \(e) todo(modifyList(todo(), list(done = e$checked)))
    ),
    tags$span(\() todo()$text)
  )
})
```

Writes through `item` work only when the source is directly
writable — i.e. a `reactiveVal` or an atomic store leaf. See §5.1
for the derived-reactive case.

---

## Worked examples

### Example 1 — Todo app

State in one place, list iteration via `Each` with a key, in-place
toggles via the writable item accessor.

```r
TodoApp <- function() {
  state <- reactiveStore(list(
    todos = list(
      list(id = 1L, text = "Learn irid", done = FALSE),
      list(id = 2L, text = "Build stores", done = FALSE),
      list(id = 3L, text = "Install R",    done = TRUE)
    ),
    new_text = "",
    filter   = "all"
  ))
  next_id <- 4L

  add_todo <- function() {
    text <- trimws(state$new_text())
    if (nchar(text) == 0L) return()
    state$todos(c(state$todos(), list(list(
      id = next_id, text = text, done = FALSE
    ))))
    next_id <<- next_id + 1L
    state$new_text("")
  }

  page_fluid(
    tags$input(
      value = state$new_text,
      onInput = \(e) state$new_text(e$value)
    ),
    tags$button("Add", onClick = \() add_todo()),

    tags$ul(
      Each(state$todos, by = \(t) t$id, \(todo) {
        When(
          \() matches_filter(todo(), state$filter()),
          tags$li(
            tags$input(
              type = "checkbox",
              checked = \() todo()$done,
              onClick = \(e) todo(modifyList(todo(), list(done = e$checked)))
            ),
            tags$span(\() todo()$text)
          )
        )
      })
    )
  )
}
```

Key changes from the current `examples/todo.R`:

- `todos`, `new_text`, and `filter` live in one `reactiveStore`
  rather than three loose `reactiveVal`s. Not strictly necessary —
  loose `reactiveVal`s would work too — but the store form lets the
  state travel as a unit if it ever needs to.
- `Each(..., by = id)` replaces the old `Index(filtered, ...)`, and
  filtering moves inside the callback via `When`. The source stays
  mutable (`state$todos`), so per-item writes work.
- Toggling `done` is now `todo(modifyList(todo(), list(done = e$checked)))`
  — no more `modify_if` threaded through `state$todos()` with a
  find-by-id predicate. The item accessor closes over the parent
  list and splices by key.

### Example 2 — Profile editor (generic via `Index` over branches)

The generic `FieldGroup` component iterates any store branch. It
doesn't know the field names ahead of time — the branch's shape is
its input.

```r
RenderNode <- function(node, key) {
  if (is_store(node)) {
    tags$fieldset(
      tags$legend(key),
      Index(node, RenderNode)
    )
  } else {
    tags$div(
      tags$label(key),
      tags$input(
        value = node,
        onInput = \(e) node(e$value)
      )
    )
  }
}

ProfileApp <- function() {
  defaults <- list(
    user = list(name = "", email = ""),
    address = list(street = "", city = "", zip = "", country = "US"),
    preferences = list(theme = "light", newsletter = FALSE, language = "en")
  )
  state <- reactiveStore(defaults)

  page_fluid(
    tags$h2("Profile"),
    Index(state, RenderNode),
    tags$button("Reset", onClick = \() state(defaults)),
    tags$button("Save",  onClick = \() post_to_server(state()))
  )
}
```

`RenderNode` lives outside `ProfileApp` because it captures nothing
from it — it's a fully generic recursive form renderer that any
store could use. Compared to the stress-test wizard implementation:

- **Declaration is one line.** `reactiveStore(defaults)` — the shape
  lives in `defaults` and nowhere else.
- **Reset is one line.** `state(defaults)` patches the root. No
  enumeration of fields.
- **Submit is one line.** `state()` produces the whole nested list.
- **Rendering is one line.** `Index(state, RenderNode)` discovers
  the top-level sections from the store, and `RenderNode` dispatches
  on store-vs-leaf and recurses. Adding a new section, or a new
  field inside a section, is a one-line change to `defaults`; both
  the form and the submit payload pick it up automatically, at any
  depth.

The real reason for the recursive form over a two-level
`GroupComponent` / `ItemComponent` split is **heterogeneous siblings**:
a branch can contain a mix of scalar leaves and nested sub-branches
at the same level, and `RenderNode` handles each child independently
based on its own type. A two-level split forces every child of a
group to be an item, which can't express e.g.
`user = list(name = "", email = "", address = list(street = "", city = ""))`
without hand-coding which fields are groups. Arbitrary depth is a
nice side effect; the main payoff is that the form structure
follows the data structure with no coordination.

`RenderNode` assumes an `is_store()` predicate — true for branches
(navigable store nodes), false for leaves (plain reactive accessors).
Recursion terminates at leaves, where `value = node` and
`node(e$value)` give fine-grained per-leaf reactivity and write-back.
Per-section customization, when needed, is a dispatch on `key`
inside the callback rather than hand-unrolling the common case.

Caveat: `RenderNode` assumes every leaf is scalar. An atomic-list
leaf (a collection held in a single `reactiveVal`, like `state$todos`
from §"APIs at a glance") is `is_store() == FALSE` and would fall
into the input arm, which is wrong. A fully general renderer would
need three-way dispatch — store (Index + recurse), collection leaf
(Each), scalar leaf (input) — but the profile schema has no
collection leaves so the two-way form suffices here.

### Example 3 — Filter panel with presets (both primitives)

Filter fields are a record (branch); presets are a collection
(unnamed list). Each half uses the right primitive.

```r
FilterApp <- function() {
  defaults <- list(
    date_from = "", date_to = "",
    category = "", search = "",
    sort_by = "date", sort_dir = "asc",
    page = 1L
  )
  state <- reactiveStore(list(
    filters = defaults,
    presets = list()
  ))

  save_preset <- function(name) {
    state$presets(c(state$presets(), list(list(
      name = name, filters = state$filters()
    ))))
  }

  load_preset <- function(name) {
    p <- Find(\(x) x$name == name, state$presets())
    if (!is.null(p)) state$filters(p$filters)
  }

  delete_preset <- function(name) {
    state$presets(Filter(\(x) x$name != name, state$presets()))
  }

  FilterBar <- function(filters) {
    tags$div(
      Index(filters, \(field, key) {
        tags$div(
          tags$label(key),
          tags$input(
            value = field,
            onInput = \(e) field(e$value)
          )
        )
      })
    )
  }

  PresetList <- function() {
    Each(state$presets, by = \(p) p$name, \(preset) {
      tags$div(
        tags$button(
          \() preset()$name,
          onClick = \() load_preset(preset()$name)
        ),
        tags$button(
          "\u00d7",
          onClick = \() delete_preset(preset()$name)
        )
      )
    })
  }

  page_fluid(
    FilterBar(state$filters),
    PresetList(),
    tags$button("Reset", onClick = \() state$filters(defaults)),
    tags$button("Share", onClick = \() share_url(state$filters()))
  )
}
```

Notice how `FilterBar` is exactly the leaf-rendering case of
`RenderNode` from the profile example — a single-level `Index` over
a branch that emits labeled inputs. If the filter schema ever grew
nested sections, `FilterBar` could drop straight into the recursive
`RenderNode` form. `PresetList` uses `Each` with `by = name` because
presets are a dynamic keyed collection.

`current_filters`, `reset_filters`, `share_url`, and `load_preset`
all collapse to one-liners against the store. The "four places the
shape existed" finding from the stress test goes away: defaults
live in one place, and `state$filters(defaults)` is the only
enumeration.

### Example 4 — Survey authoring (with per-scalar edit via Each writer)

This is where the old `Index` write asymmetry showed up —
`ChoiceEditor` had to do `modify_if(options, by_index, f)` to edit a
single string. Under the new design, `Each` passes a writable
scalar accessor and `option(new_value)` writes through.

Abbreviated — only the parts that differ from the stress-test
version.

```r
ChoiceConfig <- function(config) {
  tags$div(
    Each(config$options, \(option, i) {
      tags$div(
        tags$input(
          value = option,
          onInput = \(e) option(e$value)
        ),
        tags$button(
          "\u00d7",
          onClick = \() config$options(
            config$options()[-i]
          )
        )
      )
    }),
    tags$button(
      "Add option",
      onClick = \() config$options(c(config$options(), ""))
    ),
    tags$input(
      type = "checkbox",
      checked = config$allow_multiple,
      onClick = \(e) config$allow_multiple(e$checked)
    )
  )
}
```

`option(e$value)` is the clean write that was missing before. For
add/remove of the whole options list, the code still goes through
the parent `config$options(...)` — that's the atomic-list machinery
and it stays unchanged. The ergonomic win is that *per-item value
edits* no longer need to reach back to the parent.

For the nested edit form over the selected question, the §9
edit-draft pattern from `irid-store-design.md` still applies — spin
up a `reactiveStore(selected_question)` on `select_question()`, write
it back to `state$questions` on save, drop it on cancel. Index over
the draft branch gives you fine-grained per-field reactivity inside
the draft form, and the outer `Each(state$questions, by = id, ...)`
renders the question list with keyed diffing.

---

## Semantics in detail

### 5.1 `Each` and derived reactives

`Each` accepts any zero-argument callable that returns a list:
`reactiveVal`, atomic store leaf, or `reactive(...)`. The item
accessor it passes to the callback is *always readable*. It is
*writable* only when `Each` can identify a direct writable source —
i.e. when the `items` argument is a `reactiveVal` or atomic store
leaf. When `items` is a derived reactive, the accessor's write
method is either absent or errors with a clear message.

Practically: if you want to render a filtered view of a collection
and still edit items in place, iterate the *source* collection and
filter inside the callback via `When`, as the todo example does
above. The source is writable, the filter is a render-time concern,
and writes through items go back to the source unambiguously.
Alternatively: iterate the derived reactive with `Each` and accept
read-only items, then route writes through a separate channel.

### 5.2 `Index` and branch recursion

`Index`'s callback receives each child as its natural store-node
shape:

- If the child is a leaf, `child_node` is a leaf — `child_node()`
  returns a scalar (or an atomic list for unnamed-list leaves),
  `child_node(v)` replaces it.
- If the child is a branch, `child_node` is a branch — `child_node()`
  returns the subtree as a named list, `child_node(patch)` applies
  a patch. You can further navigate into it with `child_node$foo`
  and recursively iterate it with another `Index(child_node, ...)`.

`Index` has no reconciliation because branch shape is static. The
set of children is fixed at `reactiveStore` construction; you
cannot add or remove a child from a branch after the fact.

### 5.3 Iteration of atomic leaves with `Each`, not `Index`

An atomic leaf inside a store (e.g. `state$todos` for an
unnamed-list-valued field) is still a collection. It does not have
navigable children — it is a single `reactiveVal` holding a plain R
list. To iterate it, use `Each`, not `Index`. `Index` on an atomic
leaf is an error.

### 5.4 No per-item "mini-stores" inside `Each`

When a collection's items are records (e.g. each todo has `id`,
`text`, `done`), `Each`'s item accessor reads and writes the record
as a whole value — not as a nested store. Writing
`todo$done(TRUE)` is **not** supported. To edit an item's fields
with fine-grained reactivity, use the §9 edit-draft pattern: spin
up a `reactiveStore(item)` when the edit begins, edit through the
draft's leaves, and write the snapshot back to the collection on
save.

This is the deliberate scoping decision from `irid-store-design.md`
§6 — the "Solid-style array-recursion trap" (see
`irid-store-design-theory.md` §3.1). Keeping `Each`'s item accessor
flat avoids the need to re-seed per-item stores on every list
change, which is the implementation bog that makes recursive
stores over arrays expensive.

### 5.5 Relationship to the §9 edit-draft pattern

The edit-draft pattern is unchanged by this redesign. `Each`
renders the collection, read-only or read/write at the item level;
when the user wants field-level reactivity inside an item, start a
`reactiveStore(item)` and edit through that. `Index` over the draft
branch gives you generic form rendering for free. Save writes the
whole draft snapshot back to the collection via
`state$items(<new_list>)`.

---

## Design decisions

### Why split iteration by "what is iterated," not by diffing?

The current split (`Index` = positional, `Each` = keyed) is an
implementation axis, not a user-facing one. In practice, the user
chooses between them based on the *data shape*: a fixed set of
slots where values change (use `Index`) vs a dynamic list where
items come and go (use `Each`). That is already a "what is
iterated" distinction dressed up as a "diffing strategy"
distinction.

Splitting explicitly by record vs collection makes the mental model
match the data shape. It also mirrors the store's own named-vs-
unnamed rule, so the state layer and the iteration layer share one
vocabulary.

### Why merge the old `Index` into `Each`?

In practice, the only reason the old `Index` existed separately was
to support in-place value updates via per-slot reactive accessors —
a capability the old `Each` lacked entirely (see §6 of
`irid-store-design.md`, corrected by this doc, and
`R/mount.R:246-249`). Once `Each` gains per-item accessors, `Index`'s
original role over collections is subsumed. Keeping two primitives
for "iterate a collection with subtly different reconciliation
strategies" is a distinction most users will not internalize.

Freeing up the `Index` name lets it take on the new role of
"iterate a store branch," which *is* a different thing from
iterating a collection and deserves its own name.

### Why not a single `For` primitive that iterates everything?

Considered briefly. A unified `For` that handles branches and
collections would have to dispatch on the argument type and pass
different callback shapes (child-node vs item-accessor) with
different key semantics (string vs position/by-key). That is
possible but conflates two operations that users reach for in
different situations and should reason about separately. Two
primitives with crisp names beat one primitive with a complicated
dispatch rule.

### Why does `Each` default to positional (`by = NULL`)?

Simplicity and default correctness. When iterating a homogeneous
list where you don't care about identity-across-reorders —
rendering a static set of options, a plot series, a positional
grid — positional reconciliation does exactly what you want with no
configuration. When you *do* care about identity (todos, presets,
chat messages), you opt in with `by`. Defaulting to `NULL` means
"the data doesn't tell me how to diff; use position."

### Why can't `Each`'s writer work on derived reactives?

Because a derived reactive is a function of its inputs, not a
storage location — there is no "slot" to write back to. Writes have
to go to something mutable. Rather than silently ignoring writes on
derived reactives, the API errors or returns a read-only accessor.
Users can still iterate derived reactives; they just get read-only
items.

### Why doesn't `Index` reconcile?

Because branch shape is static — the set of children is determined
at `reactiveStore` construction and cannot change afterward. There
is nothing to diff. `Index` is effectively `lapply(children, fn)`
with slightly nicer callback arguments.

This has an interesting consequence: `Index` is not a reactive
primitive in the same sense `Each` is. `Index`'s callback is
invoked once per child at mount time; the *callback's DOM* is
reactive to the child node it captured (because the child node is
itself a reactive store leaf or branch), but `Index` itself does
not observe any reactive source. If you need the set of children
to be dynamic, you have a collection, not a record — use `Each`.

### Why allow branch `Index` to recurse?

So that generic components like `FieldGroup` can take a branch and
render it without knowing the shape, and inside that rendering, a
nested branch can itself be rendered by nested `Index`. This is the
same recursive composability story as §3 of
`irid-store-design.md` — a component that handles branches handles
all branches uniformly, regardless of depth.

---

## Open questions

1. **What does `Each(..., by)` do for kept items with changed
   values?** The proposal says per-item accessors fire on value
   changes. This is implementable — it means Each's per-key entry
   holds a `reactiveVal` for the item value and writes the new
   value into it on each reconcile pass — but it is more
   bookkeeping than the current `Each` does. Prototype needs to
   confirm the reconcile loop handles both key reshuffling and
   per-slot value updates cleanly without observer races.

2. **Do we keep the `index` argument in `Each`'s callback?**
   Current `Index` passes `(item, index)` where `index` is an
   integer. Current `Each` passes `(item, index_rv)` where
   `index_rv` is a reactiveVal that tracks the position across
   reorders. Under the new design, `Each` without `by` could pass
   `(item, i)` with `i` a plain integer (positions are stable); with
   `by`, `i` could be the key or the current position
   reactiveVal. Needs a decision on whether to unify or keep two
   modes.

3. **Read-only iteration primitive for derived reactives.** If
   `Each` errors on write for derived reactives, the user-facing
   experience is "call `Each` with a derived reactive, get a
   runtime error when you try to write." That is discoverable but
   not graceful. Alternatives: a separate `ForEach(derived, fn)`
   that explicitly takes a read-only collection, or a read-only
   accessor that no-ops writes with a warning. Probably the
   right answer is "Each is fine on derived reactives, items are
   read-only, write attempts error with a clear message." Needs
   confirmation on what "clear message" looks like in the API.

4. **Does `Index` over a branch need to observe the branch's
   read path?** A branch has a `reactive(...)` that composes its
   children. Does `Index` subscribe to it? Proposal: no.
   `Index` walks the static child list at mount and hands each
   child node to the callback; the callback's DOM subscribes
   through the child node directly. The branch's read path is
   relevant for `state$user()` calls but not for iteration.

5. **`Index` callback naming.** `\(field, key)` vs `\(child, name)`
   vs `\(node, key)`. Bikeshed; pick one for consistency.

6. **What happens to `Match` / `When` / `Case` / `Default`?**
   Unaffected by this redesign. They operate on reactive
   conditions, which do not change shape. Called out explicitly so
   the scope is clear.

---

## Migration from current code

irid is 0.1.0.9000 (greenfield), so this is a hard replacement.

1. **`Index(reactiveVal_or_reactive, fn)` → `Each(items, fn)`.**
   No `by`, positional reconciliation, same in-place update
   semantics. The callback receives the same reactive accessor it
   gets today from `Index`. One-line change per call site.

2. **`Each(items, fn, by = ...)` → `Each(items, fn, by = ...)`.**
   Signature unchanged, but the callback now receives a reactive
   accessor instead of a plain value, and in-place value changes to
   kept items now fire that accessor. Callbacks that read `item`
   directly need to become `item()`; callbacks that wrote their
   own fine-grained access patterns may simplify.

3. **`Index(branch, fn)` is new** — no current code uses it.

4. **`Each`'s silent-no-op-on-value-change footgun is fixed.**
   Current `Each` ignores value changes for kept items (see
   `R/mount.R:246-249`). Under the new design, those fire per-item
   accessors. This is a behavior change, but in the direction of
   "do the obviously-correct thing the docs claimed was already
   happening."

5. **`examples/todo.R` migrates** — from `Index(filtered, ...)` to
   `Each(state$todos, by = id, ...)` with per-item filter checks
   via `When`. See Example 1 above.

6. **The store design doc's §6 needs updating.** The text "Each
   passes each item as a plain value and recreates all items when
   the list changes" is both out of date with current code (it
   does not recreate) and incompatible with the new design (it
   will pass accessors, not plain values). The §6 List Nodes
   section should be rewritten to point at this doc as the current
   source of truth, with a brief restatement of the
   records-vs-collections scoping rule.

7. **The `index-write-asymmetry.md` finding resolves** — the
   asymmetry existed because the old `Index` callback got a
   read-only accessor and the parent `reactiveVal` was not
   accessible. Under the new design, `Each` passes a read/write
   accessor that closes over the parent, and `Index` only operates
   on store branches where children are already read/write. The
   finding can be marked resolved when this design ships.

---

## What this design is not

- **Not a rewrite of reactive primitives.** `reactiveVal`,
  `reactive`, `observe`, `isolate` are unchanged.
- **Not a change to `When` / `Match` / `Case` / `Default`.**
- **Not a recursive-store-over-arrays proposal.** Collections are
  still atomic at the store level per §6 of
  `irid-store-design.md`; the theory-doc array-recursion argument
  still holds. Per-item record editing still goes through the §9
  edit-draft pattern.
- **Not a capability-passing / read-only-view system.** The user's
  earlier idea about zeallot destructuring (`c(x, set_x) %<-% ...`)
  remains a separate future direction, compatible with this design
  but not included in it. Destructuring is an opt-in on top of the
  unified callable; this doc defines the unified callables first.
