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
elements auto-bind to these callables through state-binding props,
and `withSetter` is the single interception mechanism for
validation, transformation, or side effects at any level.

The four key moves beyond `dev/stores1/`:

1. **Per-item mini-stores in `Each`.** When a collection's items
   are records, `Each` wraps each item in a `reactiveStore`,
   giving field-level reactivity and auto-bind without the
   edit-draft ceremony.

2. **Auto-bind for state-binding props.** Props like `value`,
   `checked`, and `selected` accept a unified callable and
   automatically read from it and write back to it on user input.
   No `onInput` handler needed for the common case.

3. **`withSetter` as the universal write-interception point.**
   Works identically on store nodes, `reactiveVal`s, and per-item
   accessors — one pattern for validation or side effects at any
   component boundary.

4. **Element-level auto-bind props.** Timing (`.debounce`,
   `.throttle`) controls how fast auto-bind writes back to the
   server. Browser behavior (`.prevent_default`, `.coalesce`) stays
   element-level. Explicit event handlers (`onInput`, `onClick`)
   still use `event_debounce()` / `event_throttle()` when they
   need their own timing.

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
  **per-item mini-store** — a `reactiveStore` wrapping that record.
  `item$done` is a leaf, `item$text` is a leaf, auto-bind works
  on each field directly. Writes to any leaf propagate back to the
  parent collection automatically.

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
items patch the per-item mini-store (for records) or fire the
per-item accessor (for scalars), updating only the affected DOM.

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = todo$text)
  )
})
```

Writes through item fields work only when the source is directly
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

Auto-bind and explicit handlers coexist — both fire independently
(see §"Auto-bind semantics"). To customize write logic, use
`withSetter`. To take full manual control, pass a read-only
reactive for `value` and handle the write in `onInput`:

```r
# Custom write logic via withSetter (auto-bind still active)
tags$input(value = withSetter(field, \(v, node) {
  if (is_valid(v)) node(v)
}))

# Full manual control (read-only value, no auto-bind write-back)
tags$input(
  value = \() field(),
  onInput = \(e) field(e$value)
)
```

### `withSetter(node, fn)`

Wraps any unified callable with a custom write function.
Reading passes through unchanged; writes go through `fn`.

```r
withSetter <- function(node, fn) {
  function(value) {
    if (missing(value)) return(node())
    fn(value, node)
  }
}
```

Works on any unified callable — store leaves, store branches,
standalone `reactiveVal`s, per-item accessors from `Each`:

```r
# Validation
tags$input(value = withSetter(state$user$email, \(v, node) {
  if (is_valid_email(v)) node(v)
}))

# Side effect on write
tags$input(value = withSetter(state$filters$search, \(v, node) {
  node(v)
  state$filters$page(1L)
}))
```

`withSetter` on a leaf returns a plain callable (no `$`
navigation). If you need to intercept an entire branch, wrap the
individual leaves you care about. This is almost always what you
want — interception is on specific fields, not subtrees.

### Element-level props

Element-level props (`.`-prefixed) configure the element's
behavior. They are not DOM attributes.

Auto-bind timing:

- `.debounce = ms` — wait until the user pauses for `ms`
  milliseconds before auto-bind writes back. Default for
  auto-bound `value` props: `200`.
- `.throttle = ms` — auto-bind writes back at most every `ms`
  milliseconds while the user is active.
- `.leading = TRUE/FALSE` — modifier on `.throttle`. If `TRUE`
  (default), fire immediately on the first event.

These only control auto-bind write-back timing. Explicit event
handlers manage their own timing via `event_debounce()` /
`event_throttle()` / `event_immediate()` (unchanged from the
current API).

Element-wide behavior:

- `.coalesce = TRUE/FALSE` — gate on server idle so events never
  queue faster than the server can process them. Default: `TRUE`
  for debounced/throttled, `FALSE` otherwise.
- `.prevent_default = TRUE/FALSE` — call `event.preventDefault()`
  in the browser before dispatching. Default: `FALSE`.

```r
# Auto-bound value, default 200ms debounce
tags$input(value = field)

# Custom auto-bind debounce
tags$input(value = field, .debounce = 500)

# No auto-bind debounce
tags$input(value = field, .debounce = 0)

# Auto-bind plus a side-effect handler with its own timing
tags$input(
  value = field,
  .debounce = 500,
  onInput = event_debounce(\(e) update_suggestions(e$value), ms = 300)
)

# Explicit handler with timing, no auto-bind involved
tags$button(
  "Save",
  onClick = event_throttle(\() save(), ms = 1000)
)

# Prevent default on form submit
tags$form(onSubmit = \(e) handle(e), .prevent_default = TRUE)
```

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

- A `reactiveStore(item)` (for record items) or a `reactiveVal(item)`
  (for scalar items).
- The mounted DOM fragment for that entry.

On each reconcile pass (when the source collection changes):

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
collections.

### Write-back from mini-stores

When a callback writes to a mini-store leaf (`todo$done(TRUE)`),
`Each` must propagate that write back to the parent collection:

1. Snapshot the mini-store: `new_item <- store()`.
2. Splice into the parent list at the correct position.
3. Write the new list to the parent source: `source(new_list)`.

This triggers a reconcile pass on the parent, which finds the same
key with a changed value and reaches step 3 above — but the
mini-store already holds the new value, so the patch is a no-op.
No observer double-fire.

### When mini-stores are not created

- **Scalar items** (character, numeric, logical vectors of length 1)
  get a per-item `reactiveVal`, not a `reactiveStore`. There are no
  fields to navigate.
- **Derived-reactive sources** produce read-only items. No
  mini-store is created; the item accessor is read-only and write
  attempts error.

---

## Auto-bind semantics

### Which props auto-bind

A prop auto-binds when:

1. It is a recognized state-binding prop (`value`, `checked`,
   `selected`), and
2. Its value is a unified callable (a function that reads when
   called with no args and writes when called with one arg).

When both conditions hold, the element:

- Reads the callable reactively for rendering (like any reactive
  expression).
- Writes back to the callable on the corresponding DOM event
  (`input` for `value`, `change` for `checked`/`selected`).

### Opting out

Pass a plain value or a zero-arg reactive to get read-only binding:

```r
# Read-only — no write-back
tags$input(value = \() toupper(state$user$name()))
```

### Coexistence with explicit handlers

Auto-bind and explicit event handlers fire independently. Auto-bind
handles state sync; the handler observes the event for side effects:

```r
# Auto-bind writes the value, onInput logs it
tags$input(
  value = field,
  onInput = \(e) log_keystroke(e)
)
```

### Interaction with `withSetter`

`withSetter` returns a unified callable, so auto-bind works
transparently:

```r
tags$input(value = withSetter(field, \(v, node) {
  if (nchar(v) <= 100) node(v)
}))
```

The element reads from the original `field` and writes through the
wrapper. From the element's perspective, it's just a callable.

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
the child with the state and intercepts only where needed via
`withSetter`. This is safe because:

- Writes go through a well-defined path (the store's write
  semantics), not ad-hoc observer chains.
- There is a single source of truth (the store), so coherence is
  maintained regardless of who writes.
- The Shiny failure mode — input-is-state with observer spaghetti
  — is prevented by the store's structured state tree, not by the
  component protocol.

### Why `withSetter` instead of store-level middleware

Store-level middleware (`reactiveStore(data, onChange = ...)`) would
be global — every write to any node in the store goes through the
same hook. `withSetter` is local: you wrap exactly the node you
hand to exactly the child that needs interception. Different
children can see different write policies for the same underlying
state. Local is almost always what you want for validation and
UI-level side effects.

### Why per-item mini-stores instead of the edit-draft pattern

The edit-draft pattern (spin up a `reactiveStore(item)`, edit
through it, write back on save) is ceremony that's only justified
when you need cancel/discard semantics. For inline edits — toggling
a checkbox, editing text in place — the ceremony is pure overhead.
Mini-stores give field-level reactivity and auto-bind by default;
the edit-draft pattern remains available for modal workflows where
discarding changes is a real user action.

### Why auto-bind instead of explicit onInput everywhere

Because the explicit form is almost always the same boilerplate:
`onInput = \(e) field(e$value)`. When that's all it does, the
boilerplate obscures the intent (this input is bound to this
state) without adding information. Auto-bind makes the common case
declarative; `onInput` remains available for the uncommon case
where you need the raw event.

### Why state-binding props vs event props as the split

State-binding props (`value`, `checked`, `selected`) represent a
synchronization relationship between DOM state and app state. Event
props (`onClick`, `onSubmit`) represent discrete actions. These are
genuinely different: binding is continuous and bidirectional;
events are discrete and unidirectional. Trying to unify them (e.g.
auto-binding `onClick` to a callable) would be confusing. The split
matches user intuition about "this input shows this value" vs "this
button does this thing."

### Why element-level props for auto-bind timing

When `value = field` auto-binds, there is no explicit handler to
wrap — the timing has to live somewhere other than a handler
wrapper. Element-level `.debounce` / `.throttle` give it a home
without requiring the user to drop out of auto-bind.

Explicit event handlers (`onInput`, `onClick`, etc.) keep using
`event_debounce()` / `event_throttle()` for their own timing.
This avoids ambiguity when an element has both auto-bind and an
explicit handler — `.debounce` controls the auto-bind write-back,
`event_debounce()` on the handler controls the handler. Each
timing mechanism has exactly one job.

`.prevent_default` and `.coalesce` stay element-level because they
apply to the DOM event itself, not to any specific handler or
auto-bind write-back.

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

1. **Observer races in mini-store write-back.** When a mini-store
   leaf write triggers a parent-collection write, which triggers a
   reconcile pass that patches the mini-store — the patch should
   be a no-op because the store already holds the new value. Needs
   prototype confirmation that the reactive graph settles without
   double-fire or infinite loops.

2. **Auto-bind detection.** How does the element know a prop value
   is a unified callable vs a plain function? Options: (a) check
   for a class/attribute on the callable, (b) callables from
   `reactiveVal`/`reactiveStore` are tagged, (c) any function
   accepting zero or one args is treated as a callable. Option (b)
   is safest; option (c) is most ergonomic but risks false
   positives.

3. ~~**Auto-bind and `onInput` coexistence.**~~ Resolved: both
   fire. Auto-bind writes the value; `onInput` runs independently
   as a side-effect listener. They are orthogonal — auto-bind is
   state sync, `onInput` is event observation.

4. **`withSetter` on branches.** Current proposal: leaf-only.
   `withSetter` on a branch returns a plain callable that loses
   `$` navigation. Is there a real use case for intercepting an
   entire branch while preserving navigation? If so, the wrapper
   needs to be a proxy object with `$` dispatch.

5. **What does `Each(..., by)` pass as the second callback
   argument?** Proposal: `(item, i)` where `i` is a plain integer
   for `by = NULL` and the key value for `by = fn`. Key as the
   second argument is more useful than position for keyed
   iteration (you already have the key, you rarely need position).

6. **Read-only iteration of derived reactives.** `Each` on a
   derived reactive produces read-only items. Write attempts error
   with a clear message. Is a separate primitive needed, or is the
   error sufficient?

7. **`Index` naming.** "Index" reads like "numeric position" in
   most languages. `Fields`, `Record`, or `Children` may be
   clearer for "iterate the children of a record." Low priority
   but affects teachability.

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
  Kept for explicit event handlers. Element-level `.debounce` /
  `.throttle` are new and control auto-bind timing only.

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
