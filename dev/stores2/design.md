# irid Stores, Iteration & Auto-Bind — Unified Design

**Status:** Draft, April 2026.
**Prior art:** `dev/stores1/` (store internals, edit-draft pattern,
theory doc, stress tests, iteration redesign).

---

## Summary

This doc proposes a unified state and rendering model for irid in
which every piece of state — whether a store branch, a store leaf,
a standalone `reactiveVal`, or a per-item accessor inside `Each` —
is a **unified callable**: `x()` reads, `x(value)` writes. DOM
elements auto-bind to these callables through state-binding props.
`onInput` disables auto-bind and takes over the write path when
you need validation, side effects, or custom logic.

The three key moves beyond `dev/stores1/`:

1. **Per-item mini-stores in `Each`.** When a collection's items
   are records, `Each` wraps each item in a `reactiveStore`,
   giving field-level reactivity and auto-bind without the
   edit-draft ceremony.

2. **Auto-bind for state-binding props.** Props like `value`,
   `checked`, and `selected` accept a unified callable and
   automatically read from it and write back to it on user input.
   No `onInput` handler needed for the common case. Providing
   `onInput` disables auto-bind write-back and gives the handler
   full control.

3. **Element-level props.** `.event` controls timing and transport
   via config constructors (`event_debounce()`, `event_throttle()`,
   `event_immediate()`). `.prevent_default` controls browser
   behavior. Both live on the element, not on handler wrappers.

---

## APIs at a glance

### `reactiveStore(initial)`

Unchanged from `dev/stores1/`. Creates a hierarchical store.
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

- `child_node` is a store node (a leaf or a nested branch). It is
  a unified callable — `child_node()` reads, `child_node(value)`
  writes. Writes propagate through the store's normal write path.
- `key` is the child's field name as a string.

Branches have static shape, so `Index` has no reconciliation — it
calls `fn` once per child at mount time. `Index` itself is not
reactive; the callback's DOM is reactive to the child nodes it
captured.

```r
Index(state$user, \(field, key) {
  tags$div(
    tags$label(key),
    tags$input(value = field)
  )
})
```

### `Each(collection, fn, by = NULL)`

Iterates a collection — an unnamed list held in a `reactiveVal`,
a `reactive`, or an atomic store leaf. Callback receives
`(item, index)`:

- When items are records (named lists), `item` is a
  **per-item mini-store** — a `reactiveStore` projection of
  that record. `item$done` and `item$text` are reactive leaves
  for fine-grained reads. Each leaf has a synthetic setter that
  routes writes through the parent collection (e.g.
  `todo$done(TRUE)` internally patches the item and writes it
  back to the parent). `item()` reads the full record,
  `item(new_record)` replaces it in the parent. See §"Per-item
  mini-stores."

- When items are scalars (strings, numbers), `item` is a
  **per-item reactive accessor**. `item()` reads, `item(value)`
  writes back to the parent collection at that slot.

- `index` is a plain integer (position) when `by = NULL`, or the
  key value when `by` is supplied.

`by = NULL` — positional reconciliation. Slot *i* is slot *i*. The
list can grow and shrink at the end; in-place value changes fire
per-slot accessors without DOM recreation.

`by = \(x) x$id` — keyed reconciliation. Items are tracked across
reorders, adds, and removes by their key. Value changes to kept
items patch the mini-store's leaves (for records) or fire the
per-item accessor (for scalars), updating only the affected DOM.

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = todo$text)
  )
})
```

Writes through items work only when the source is directly
writable (a `reactiveVal` or an atomic store leaf). When `Each`
iterates a derived reactive, items are read-only; write attempts
error with a clear message.

### Auto-bind

State-binding props — `value`, `checked`, `selected` — accept a
unified callable and automatically two-way bind:

```r
# Auto-bind: reads from field(), writes back on input
tags$input(value = field)
```

Event props — `onClick`, `onSubmit`, `onKeyDown`, etc. — remain
plain callbacks. They represent actions, not state. The split is:

- **State-binding props** (value, checked, selected): take a
  unified callable, auto-bind read and write.
- **Event props** (onClick, onInput, etc.): take a callback,
  fire on DOM events.

Providing `onInput` (or `onChange` for checkboxes/selects) disables
auto-bind write-back. The handler owns the write path:

```r
# Auto-bind (common case)
tags$input(value = field)

# Validation — onInput takes over the write
tags$input(
  value = field,
  onInput = \(e) if (is_valid_email(e$value)) field(e$value)
)

# Side effect + write
tags$input(
  value = field,
  onInput = \(e) { field(e$value); update_suggestions(e$value) }
)

# Read-only display
tags$input(value = \() toupper(field()))
```

### Element-level props

Element-level props (`.`-prefixed) configure the element's
behavior. They are not DOM attributes.

#### `.event` — event delivery config

Controls timing and transport for auto-bind write-back or explicit
event handlers. Set via the `event_debounce()`, `event_throttle()`,
and `event_immediate()` config constructors (same names as the
current API, but they return config objects instead of wrapping
handler functions):

```r
event_debounce(ms, coalesce = TRUE)
event_throttle(ms, leading = TRUE, coalesce = TRUE)
event_immediate(coalesce = FALSE)
```

Default for elements with auto-bound `value`: `event_debounce(200)`.
Default for all other events: `event_immediate()`.

```r
# Auto-bound value, default event_debounce(200)
tags$input(value = field)

# Custom debounce
tags$input(value = field, .event = event_debounce(500))

# Immediate (no debounce)
tags$input(value = field, .event = event_immediate())

# Validation handler with custom debounce
tags$input(
  value = field,
  onInput = \(e) if (is_valid(e$value)) field(e$value),
  .event = event_debounce(500)
)

# Throttled button
tags$button("Save", onClick = \() save(), .event = event_throttle(1000))
```

#### `.prevent_default`

Calls `event.preventDefault()` in the browser before dispatching.
Orthogonal to `.event`. Default: `FALSE`.

```r
tags$form(onSubmit = \(e) handle(e), .prevent_default = TRUE)
```

The `.` prefix signals "element config, not DOM attribute."
Handlers are plain functions — no wrapper classes, no struct
attributes. The element owns the transport policy.

---

## Worked examples

### Example 1 — Todo app

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
    tags$input(value = state$new_text),
    tags$button("Add", onClick = \() add_todo()),

    tags$ul(
      Each(state$todos, by = \(t) t$id, \(todo) {
        When(
          \() matches_filter(todo(), state$filter()),
          tags$li(
            tags$input(type = "checkbox", checked = todo$done),
            tags$span(\() todo$text())
          )
        )
      })
    )
  )
}
```

Key points:

- `tags$input(value = state$new_text)` — auto-bind, no `onInput`.
- `checked = todo$done` — auto-bind into a per-item mini-store
  field. Toggling the checkbox writes `todo$done(TRUE)`, which
  patches the item in the parent collection. No `modifyList`, no
  find-by-id predicate.
- `\() todo$text()` — reactive read of a single field. Only the
  span re-renders when `text` changes, not the whole item.
- Filtering via `When` inside the callback keeps the source
  collection mutable, so per-item writes work.

### Example 2 — Profile editor (recursive generic form)

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
      tags$input(value = node)
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
from it — it is a fully generic recursive form renderer. `is_store`
dispatches branch vs leaf; `Index` recurses into branches;
`tags$input(value = node)` auto-binds at leaves. Adding a new
section or field is a one-line change to `defaults`.

The recursive form handles heterogeneous siblings: a branch whose
children are a mix of scalar leaves and nested sub-branches (e.g.
`user = list(name = "", address = list(street = "", city = ""))`)
renders correctly without hand-coding which fields are groups.
A two-level `GroupComponent` / `ItemComponent` split can't express
this without knowing the shape at the call site.

Caveat: `RenderNode` assumes every leaf is scalar. An atomic-list
leaf (a collection) would need three-way dispatch — store (Index +
recurse), collection (Each), scalar (input). The profile schema has
no collection leaves so two-way suffices here.

### Example 3 — Filter panel with presets

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
          tags$input(value = field)
        )
      })
    )
  }

  PresetList <- function() {
    Each(state$presets, by = \(p) p$name, \(preset) {
      tags$div(
        tags$button(
          \() preset$name(),
          onClick = \() load_preset(preset$name())
        ),
        tags$button(
          "\u00d7",
          onClick = \() delete_preset(preset$name())
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

`FilterBar` uses `Index` over a branch with auto-bind — no
`onInput` handlers. `PresetList` uses `Each` with keyed
reconciliation; `preset$name()` reads a field from the per-item
mini-store.

### Example 4 — Survey question editor (per-field edit via Each)

This is where the old `Index` write asymmetry showed up — editing
a single choice option required `modify_if(options, by_index, f)`.
Under mini-stores, `option` is a scalar accessor and auto-bind
handles the write.

```r
ChoiceConfig <- function(config) {
  tags$div(
    Each(config$options, \(option, i) {
      tags$div(
        tags$input(value = option),
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
      checked = config$allow_multiple
    )
  )
}
```

`tags$input(value = option)` — auto-bind on a per-item scalar
accessor. Editing the option writes back to the parent list at
that position.

---

## Per-item mini-stores in `Each`

### Architecture: one-way data flow

Mini-stores are **projections** of collection items with synthetic
setters. Data flows in one direction: parent collection →
mini-store → DOM. Writes through mini-store leaves are routed
back through the parent — the leaf never holds independent state.

- `todo$done()`, `todo$text()` — fine-grained reactive reads
  directly from the mini-store's leaves.
- `todo()` — reads the full record as a plain list.
- `todo(new_record)` — writes the whole item back to the parent
  collection at the correct position.
- `todo$done(TRUE)` — synthetic setter. Internally does
  `todo(modifyList(todo(), list(done = TRUE)))`, routing the
  write through the parent. The leaf itself is a read-only
  projection; the setter is a convenience that writes through
  the parent.

Auto-bind on a mini-store field (e.g. `checked = todo$done`)
uses the same synthetic setter. From the user's perspective,
`checked = todo$done` and `todo$done(TRUE)` both just work.
Behind the scenes, writes always go through the parent collection,
which triggers a reconcile pass that diffs old vs new and patches
only the changed leaves in the mini-store. No circular flow — the
leaf never holds independent state; it's a projection with a
write-through convenience.

```r
# All three are equivalent — all write through the parent:
tags$input(type = "checkbox", checked = todo$done)    # auto-bind
todo$done(TRUE)                                        # synthetic setter
todo(modifyList(todo(), list(done = TRUE)))             # manual
```

### Why one-way

Two-way mini-stores where leaf writes go directly to the leaf
and then propagate to the parent create circular reactive flow:
leaf write → parent write → reconcile → leaf patch. Making that
settle without double-fire or infinite loops requires guard
flags or identity checks. One-way avoids the problem entirely:
the parent is the single source of truth, mini-store leaves are
projections with synthetic setters that route writes through the
parent, and the reactive graph is acyclic. The user experience
is the same — `todo$done(TRUE)` works — but the write goes
through the parent, not to the leaf directly.

### Why this is safe

`dev/stores1/irid-store-design-theory.md` §3.1 warned against the
"Solid-style array-recursion trap": recursive stores over arrays
create an unbounded tree of proxied state. That warning still holds
for the general case, but does not apply here because **irid's
store rule bounds the recursion by construction**.

`reactiveStore` treats unnamed lists as atomic. When `Each` wraps
an item record in a `reactiveStore`, the result is a flat branch
with scalar leaves — it cannot recurse further into arrays inside
the item. The pathological case (arrays of stores of arrays) is
structurally impossible.

### Reconcile mechanics

Each per-key entry in `Each`'s internal map holds:

- A read-only `reactiveStore(item)` (for record items) or a
  `reactiveVal(item)` (for scalar items).
- The mounted DOM fragment for that entry.

On each reconcile pass (when the parent collection changes):

1. **New keys** → create a new mini-store/accessor, call `fn`,
   mount the DOM.
2. **Removed keys** → destroy the mini-store/accessor, unmount the
   DOM.
3. **Kept keys with changed values** → patch the mini-store
   (`store(new_value)`, which diffs and fires only changed leaves)
   or replace the `reactiveVal`. The existing DOM reacts to the
   fine-grained leaf changes — no teardown/rebuild.
4. **Reordered keys** → move DOM nodes to match the new order.

The critical property: step 3 patches rather than replaces. A todo
whose `done` flips from `FALSE` to `TRUE` fires only `todo$done`'s
observers, not `todo$text`'s. This is the fine-grained reactivity
payoff that justified stores in the first place, now extended into
collections. And because mini-stores are read-only projections,
data always flows parent → mini-store — no circular writes.

### When mini-stores are not created

- **Scalar items** (character, numeric, logical vectors of length 1)
  get a per-item `reactiveVal`, not a `reactiveStore`. There are no
  fields to navigate.
- **Derived-reactive sources** produce read-only items. No
  mini-store is created; the item accessor is read-only and write
  attempts error.

### Vertical composition: `Each` inside `Each`

When a record item contains a sub-collection (e.g. a survey
question with an options list), the outer `Each` produces a
mini-store, and the inner `Each` iterates a leaf of that
mini-store:

```r
state <- reactiveStore(list(
  questions = list(
    list(id = 1L, text = "Favorite color?", options = list("Red", "Blue")),
    list(id = 2L, text = "Favorite food?",  options = list("Pizza", "Sushi"))
  )
))

Each(state$questions, by = \(q) q$id, \(question) {
  tags$div(
    tags$input(value = question$text),
    Each(question$options, \(option, i) {
      tags$input(value = option)
    }),
    tags$button(
      "Add option",
      onClick = \() question$options(c(question$options(), ""))
    )
  )
})
```

`question` is a mini-store (projection of the outer collection
item). `question$options` is a leaf of that mini-store holding an
unnamed list. The inner `Each` iterates it positionally, giving
each option a scalar accessor.

Writes flow through a two-level synthetic setter chain:

1. `option("Green")` — scalar accessor writes to
   `question$options` (replacing the list with the option
   spliced in at position `i`).
2. `question$options(new_list)` — mini-store leaf synthetic setter
   patches the question record and writes through to the parent:
   `question(modifyList(question(), list(options = new_list)))`.
3. `question(patched)` — outer mini-store synthetic setter writes
   the patched question back to `state$questions` at the correct
   position.
4. Outer `Each` reconciles — finds the same key with a changed
   value, patches `question`'s mini-store. Inner `Each` reconciles
   on `question$options` — positional diff updates the affected
   slot.

This composes from existing pieces — no new primitive needed. But
the multi-level synthetic setter chain needs prototype validation;
see open question 7.

---

## Auto-bind semantics

### Which props auto-bind

A prop auto-binds when:

1. It is a recognized state-binding prop (`value`, `checked`,
   `selected`), and
2. Its value is a unified callable (a function that reads when
   called with no args and writes when called with one arg), or
   a read-only mini-store leaf (see below).

When both conditions hold, the element:

- Reads the callable reactively for rendering (like any reactive
  expression).
- Writes back to the callable on the corresponding DOM event
  (`input` for `value`, `change` for `checked`/`selected`).

### Auto-bind on mini-store fields

Mini-store leaves (e.g. `todo$done` inside an `Each` callback)
have a synthetic setter that routes writes through the parent
item. Auto-bind uses this setter: it reads from the leaf for
fine-grained reactivity, and on write, the setter patches the
field and writes back through the parent collection. The user
writes `checked = todo$done` and gets the same experience as a
regular store leaf — but under the hood, the data flow is
strictly one-way (parent → mini-store).

### Opting out of auto-bind write-back

Two ways to disable auto-bind's write-back:

1. **Provide `onInput`/`onChange`.** The handler takes over the
   write path. Auto-bind still reads from the callable for
   rendering, but does not write back — the handler decides
   what to write and when.

2. **Pass a read-only reactive.** A zero-arg function or
   `reactive(...)` is not a unified callable (it has no write
   path), so auto-bind renders it but never attempts to write.

```r
# onInput takes over — validation before write
tags$input(
  value = field,
  onInput = \(e) if (nchar(e$value) <= 100) field(e$value)
)

# Read-only display — no write path exists
tags$input(value = \() toupper(state$user$name()))
```

---

## Design decisions

### Why unified callables instead of value/onChange

The alternative is the React model: pass `value` for reading and
`onChange` for writing as separate props. This gives the parent
full control over the write path but kills composability — every
component boundary needs both props threaded through, and recursive
patterns like `RenderNode` become verbose.

The unified callable inverts the control model: instead of the
parent intercepting every write by construction, the parent trusts
the child with the state. This is safe because:

- Writes go through a well-defined path (the store's write
  semantics), not ad-hoc observer chains.
- There is a single source of truth (the store), so coherence is
  maintained regardless of who writes.
- The Shiny failure mode — input-is-state with observer spaghetti
  — is prevented by the store's structured state tree, not by the
  component protocol.

`field(v)` always means "write v to this state." The write path is
transparent — no wrappers, no interception layers, no hidden
indirection. When a component needs write interception at a
specific boundary (validation, side effects), it uses `onInput` on
the element or accepts an optional `onChange` callback as a
component prop. Both are explicit and visible at the call site.
`observe(field, ...)` handles the case where side effects need to
react to state changes regardless of what triggered the write.

### Why per-item mini-stores instead of the edit-draft pattern

The edit-draft pattern (spin up a `reactiveStore(item)`, edit
through it, write back on save) is ceremony that's only justified
when you need cancel/discard semantics. For inline edits — toggling
a checkbox, editing text in place — the ceremony is pure overhead.
Mini-stores give field-level reactivity and auto-bind by default;
the edit-draft pattern remains available for modal workflows where
discarding changes is a real user action.

### Why one-way mini-stores

The alternative is two-way mini-stores where `todo$done(TRUE)`
writes directly to the leaf, then propagates the change back to
the parent collection. This creates circular reactive flow
(leaf → parent → reconcile → leaf) that needs guard flags or
identity checks to settle.

One-way mini-stores avoid this: the parent collection is the
single source of truth, and mini-store leaves are projections
with synthetic setters. `todo$done(TRUE)` writes through the
parent, not to the leaf. The reconcile pass flows parent →
mini-store and the reactive graph is acyclic. The user
experience is identical — `todo$done(TRUE)` just works — but
the data flow is clean.

### Why auto-bind instead of explicit onInput everywhere

Because the explicit form is almost always the same boilerplate:
`onInput = \(e) field(e$value)`. When that's all it does, the
boilerplate obscures the intent (this input is bound to this
state) without adding information. Auto-bind makes the common case
declarative; `onInput` disables auto-bind write-back and takes
over the write path when you need validation, side effects, or
custom logic.

### Why state-binding props vs event props as the split

State-binding props (`value`, `checked`, `selected`) represent a
synchronization relationship between DOM state and app state. Event
props (`onClick`, `onSubmit`) represent discrete actions. These are
genuinely different: binding is continuous and bidirectional;
events are discrete and unidirectional. Trying to unify them (e.g.
auto-binding `onClick` to a callable) would be confusing. The split
matches user intuition about "this input shows this value" vs "this
button does this thing."

### Why element-level `.event` instead of handler wrappers

The current API wraps handlers with `event_debounce(fn, ms)`,
bundling timing config into the handler function via struct
attributes. This conflates what the handler *does* with how the
element *delivers events*.

`.event` separates these. `event_debounce()`, `event_throttle()`,
and `event_immediate()` become config constructors — same names,
but they produce config objects instead of wrapping functions.
Handlers stay plain functions. The element owns the delivery
policy.

This also makes auto-bind work naturally. When `value = field`
auto-binds, there is no explicit handler to wrap — the timing has
to live somewhere else. `.event` gives it a home with a sensible
default (`event_debounce(200)` for auto-bound `value`). When
`onInput` takes over the write path, the same `.event` prop
controls the handler's timing — one mechanism for both modes.

### Record vs collection as the iteration axis

Unchanged from `dev/stores1/stores-and-iteration-design.md`. The
split by what-is-iterated (record vs collection) rather than by
diffing strategy (positional vs keyed) maps onto the store's own
named-vs-unnamed rule. One mental model for state shape and
iteration shape.

### Why `Each` defaults to positional (`by = NULL`)

Unchanged from `dev/stores1/`. Positional reconciliation is the
correct default for static homogeneous lists (options, series,
grids). Keyed reconciliation is opt-in for identity-tracked
collections (todos, chat messages, presets).

---

## Open questions

1. ~~**Observer races in mini-store write-back.**~~ Resolved:
   mini-stores are read-only projections. Writes route through the
   parent collection; data flows one-way (parent → mini-store).
   No circular reactive flow, no guard flags needed.

2. **Auto-bind detection.** How does the element know a prop value
   is a unified callable vs a plain function? Options: (a) check
   for a class/attribute on the callable, (b) callables from
   `reactiveVal`/`reactiveStore` are tagged, (c) any function
   accepting zero or one args is treated as a callable. Option (b)
   is safest; option (c) is most ergonomic but risks false
   positives.

3. ~~**Auto-bind and `onInput` coexistence.**~~ Resolved: `onInput`
   disables auto-bind write-back. The handler owns the write path.
   Auto-bind still reads from the callable for rendering.

4. **What does `Each(..., by)` pass as the second callback
   argument?** Proposal: `(item, i)` where `i` is a plain integer
   for `by = NULL` and the key value for `by = fn`. Key as the
   second argument is more useful than position for keyed
   iteration (you already have the key, you rarely need position).

5. **Read-only iteration of derived reactives.** `Each` on a
   derived reactive produces read-only items. Write attempts error
   with a clear message. Is a separate primitive needed, or is the
   error sufficient?

6. **`Index` naming.** "Index" reads like "numeric position" in
   most languages. `Fields`, `Record`, or `Children` may be
   clearer for "iterate the children of a record." Low priority
   but affects teachability.

7. **Multi-level synthetic setter chain.** When `Each` is nested
   inside `Each`, writes from the inner collection flow through
   two levels of synthetic setters (inner scalar accessor →
   mini-store leaf → outer mini-store → parent collection). Each
   link uses the same one-way mechanism, so it should compose, but
   the chain needs prototype validation. Concerns: (a) does each
   level's reconcile pass settle without redundant work — the inner
   `Each` fires on the mini-store leaf, the outer `Each` fires on
   the parent collection, both ultimately triggered by the same
   write; (b) does the outer reconcile's patch of the mini-store
   cause the inner `Each` to reconcile a second time (it shouldn't
   if the inner list hasn't changed, but needs verification);
   (c) performance with deeply nested collections — three or more
   levels of `Each` would chain three or more synthetic setters,
   each triggering a reconcile pass. Likely fine for realistic
   depths but worth stress-testing.

---

## Relationship to `dev/stores1/`

This design extends rather than contradicts `dev/stores1/`. The
store internals (§1-5, §7-8 of `irid-store-design.md`), the
theory doc, and the stress tests are still valid. What changes:

- **§6 (list nodes / Each semantics):** Replaced. `Each` now
  wraps record items in mini-stores. The "silent no-op on
  value change" footgun is fixed.
- **§9 (edit-draft pattern):** Demoted from "required for
  field-level edits" to "useful for cancel/discard workflows."
  Inline field-level edits go through mini-stores by default.
- **`stores-and-iteration-design.md`:** Superseded by this doc.
  The `Index`/`Each` split by record/collection carries forward;
  the per-item accessor design and callback signatures change.
- **Theory doc §3.1 (array-recursion trap):** Still valid in
  general, but the bounded-recursion argument (store rule prevents
  nested arrays in mini-stores) means the specific application to
  `Each` is safe.
- **`event_debounce` / `event_throttle` / `event_immediate`:**
  Repurposed from handler wrappers to config constructors, used
  via the element-level `.event` prop. Handlers become plain
  functions; timing and transport config moves to the element.

---

## What this design is not

- **Not a rewrite of reactive primitives.** `reactiveVal`,
  `reactive`, `observe`, `isolate` are unchanged.
- **Not a change to `When` / `Match` / `Case` / `Default`.**
- **Not a recursive-store-over-arrays proposal.** Collections are
  still atomic at the store level. Mini-stores inside `Each` are
  one level deep by construction.
- **Not a capability-passing / read-only-view system.** The
  earlier zeallot destructuring idea remains a separate future
  direction, compatible with this design but not included in it.
