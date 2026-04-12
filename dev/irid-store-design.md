# irid Store — Design Document

**Status:** Deferred — design is ready, but no concrete pain point justifies
shipping yet.
**Date:** March 2026 (design), deferred 2026-04.

---

This design is not being built yet. The todo example (`examples/todo.R`) —
the most state-heavy example in irid — handles all its state with three
loose `reactiveVal`s at the top of `TodoApp`, with no coordination pain.
Until a real example or app hits clear pain with loose `reactiveVal`s,
there is no concrete failure mode to design against, and shipping the wrong
shape in a 0.x API is more expensive than waiting.

**When to revisit:** if an example or real app shows one or more of the
following, this doc is the starting point — don't redesign from scratch.

- Many related `reactiveVal`s that want to be grouped and read as a single
  snapshot (form state, settings panels, multi-field edit drafts).
- Snapshot/restore round-trips where a data blob is pulled out of a
  collection, edited field-by-field with fine-grained reactivity, and
  written back (see the edit-draft pattern in §9).
- Manual coordination, excessive `isolate()` calls, or boilerplate for
  injecting initial values into a set of independent `reactiveVal`s.

A companion theory doc (`irid-store-design-theory.md`) captures the
reasoning behind the design choices, the alternatives considered, the
Solid comparison, and the py-irid port.

---

## 1. Motivation

irid's core primitive is `reactiveVal` — a single scalar reactive value. This works well for simple state but becomes awkward as apps grow. Developers end up with either many disconnected flat `reactiveVal`s, or a single `reactiveVal` holding a large nested list where any change invalidates everything.

A store provides fine-grained reactivity over structured, nested state — mirroring what Solid.js's `createStore` does, but in idiomatic R using irid's existing reactive primitives.

---

## 2. Goals

- Fine-grained reactivity at the leaf level — changing `user$name` should not invalidate `user$age`
- Reading a branch node returns the whole subtree and invalidates when any descendant changes
- Writing a branch node patches — only specified keys are updated, missing keys left unchanged
- Static shape — the structure of the store is fixed at construction time
- Shape validation on every write — unknown keys are an error
- Uniform interface — every node is callable, read/write mirrors `reactiveVal`
- Atomic list nodes — list-level reactivity is delegated to `Each`/`Index`, not the store
- No new concepts — builds entirely on `reactiveVal` and `reactive`

---

## 3. API

### Construction

The shape of the store is defined by the initial value and is fixed at construction time. The store does not grow dynamically.

```r
state <- reactiveStore(list(
  user = list(name = "Alice", age = 30),
  todos = list(
    list(id = 1, text = "Buy milk", done = FALSE),
    list(id = 2, text = "Walk dog", done = TRUE)
  )
))
```

### Reading

Every node is callable. Calling with no arguments reads the value and registers a reactive dependency.

```r
state$user$name()   # "Alice"   — leaf, tracked at leaf level
state$user()        # list(name = "Alice", age = 30) — branch, tracked at subtree level
state()             # entire store as a list
```

### Writing

Calling with an argument writes the value.

**Leaf write** — replaces the value:

```r
state$user$name("Bob")
state$user$age(31L)
```

**Branch write** — patches. Only the specified keys are updated; unspecified keys are left unchanged:

```r
# Only name is updated — age remains 30
state$user(list(name = "Charlie"))

# Both updated
state$user(list(name = "Dave", age = 25L))

# Patch from root — todos unchanged
state(list(user = list(name = "Eve")))
```

**Unknown keys always error**, regardless of write depth:

```r
state$user(list(name = "Bob", email = "bob@example.com"))
# Error: Unknown keys in store node 'user': email
```

### In irid tags

Store nodes are functions, so they work anywhere `reactiveVal` does — passed directly as reactive attributes.

```r
tags$span(state$user$name)
tags$span(\() paste(state$user$name(), "is", state$user$age(), "years old"))

tags$input(
  type = "text",
  value = state$user$name,
  onInput = \(e) state$user$name(e$value)
)
```

### Composability

Any store node — leaf or branch — can be passed to a component. The component doesn't know or care whether it received a leaf, a subtree, or the entire store. Reads and writes work the same way regardless, and writes propagate back to the original store since nodes are references, not copies.

A branch node acts as a mini-store:

```r
user_card <- function(user) {
  tags$div(
    tags$h2(user$name),
    tags$span(user$age),
    tags$button(
      "Birthday",
      onClick = \(e) user$age(user$age() + 1L)
    )
  )
}

user_card(state$user)
```

A leaf node is indistinguishable from a `reactiveVal` to the consumer:

```r
name_input <- function(value) {
  tags$input(
    type = "text",
    value = value,
    onInput = \(e) value(e$value)
  )
}

name_input(state$user$name)   # store leaf
name_input(reactiveVal("hi")) # plain reactiveVal — same interface
```

This means components can be written against `reactiveVal` and later wired to a store without any changes.

---

## 4. Internal Design

### Leaves are `reactiveVal`, branches read through `reactive`

Every node — leaf or branch — is externally a callable that accepts both
reads (no argument) and writes (one argument). The distinction is internal:

- **Leaves** hold a `reactiveVal`. Reads and writes both go through it directly.
- **Branches** hold a `reactive` for the *read* path only. The branch's
  read recomputes by calling each child in turn and reassembling the
  result. The branch's *write* path does not touch that `reactive` at all
  — it validates the incoming keys and then calls each child's node
  function with the corresponding new value, recursing down until every
  affected leaf's `reactiveVal` has been set.

The key insight is that **leaves are the source of truth**. Branches never
own state; their read is a derived view, and their write is a fan-out to
children. This gives us:

- Data flows in one direction only: writes fan down to leaves, reads compose up from leaves
- No circular invalidation — the branch's `reactive` is never a write target, so leaf updates cannot bounce back through it
- Writing to a branch is just syntactic sugar for patching its children, and patching composes to arbitrary depth

```
Write root → fans out to children → fans out to leaves (reactiveVal)
Read leaf  → reactiveVal
Read branch → reactive(children...)  → recomputes when any child changes
```

### Implementation sketch

```r
reactiveStore <- function(x, .name = "root") {
  # Unnamed lists are atomic — do not recurse
  is_named <- is.list(x) && !is.null(names(x))
  children <- if (is_named) lapply(x, reactiveStore) else list()

  val <- if (length(children) > 0) {
    reactive({
      result <- lapply(names(children), \(nm) children[[nm]]())
      names(result) <- names(children)
      result
    })
  } else {
    reactiveVal(x)
  }

  node <- function(new_val) {
    if (missing(new_val)) {
      val()
    } else {
      if (length(children) > 0) {
        # Branch write — validate shape then patch
        unknown <- setdiff(names(new_val), names(children))
        if (length(unknown) > 0) {
          stop("Unknown keys in store node '", .name, "': ",
               paste(unknown, collapse = ", "))
        }
        for (nm in names(new_val)) {
          children[[nm]](new_val[[nm]])
        }
      } else {
        # Leaf write — guard against accidental patch on atomic list
        if (is.list(x) && is.list(new_val) && !is.null(names(new_val))) {
          stop("'", .name, "' is an unnamed list node and must be replaced completely.")
        }
        val(new_val)
      }
    }
  }

  class(node) <- "store_node"
  attr(node, "children") <- children
  node
}

`$.store_node` <- function(x, name) {
  child <- attr(x, "children")[[name]]
  if (is.null(child)) stop("Unknown key: ", name)
  child
}

`[[.store_node` <- function(x, name) {
  child <- attr(x, "children")[[name]]
  if (is.null(child)) stop("Unknown key: ", name)
  child
}
```

Both `state$todos` and `state[["todos"]]` work identically. The `[[` form is useful when the key is stored in a variable.

### Why no circular invalidation

A naive implementation might give both branch and leaf nodes a `reactiveVal` and try to keep them in sync with observers — but that creates a cycle: leaf updates branch, branch write triggers leaf, and so on.

The solution is to never give branch nodes a `reactiveVal` at all. Branches are `reactive` (read-only, computed), so there is nothing to write to. Writing to a branch simply calls the write function on each child — it never touches the branch's reactive expression directly. The branch re-reads itself naturally the next time it is accessed.

### Deeply nested writes and intermediate states

Branch writes fan out recursively. A write like `state(list(user = list(name = "Eve")))` triggers a branch write on the root, which triggers a branch write on `user`, which triggers a leaf write on `name`. This works transitively to arbitrary depth.

However, each leaf `reactiveVal` fires independently as it is written. During a multi-leaf branch write, there is a brief window where some leaves have been updated and others have not. For example, `state$user(list(name = "Dave", age = 25L))` writes `name` first and `age` second — an observer reading both could see `name = "Dave"` with the old `age` before `age` is updated.

In practice this is a non-issue: irid's reactive system batches invalidations and defers re-execution to the next flush. As long as all leaf writes happen synchronously within the same branch write (which they do), observers will not run until the full write has completed. If irid ever moves to an eager evaluation model, this assumption would need to be revisited.

---

## 5. Shape Validation

The store's shape is fixed at construction time. Every write is validated against this shape.

### What is enforced

- Unknown keys on branch writes are always an error
- The store never grows new keys after construction

### What is not enforced

- Types of leaf values — `state$user$name(42)` is accepted even if the initial value was a string
- This is intentional: union types are common in practice (e.g. a field that can be `NULL` or a string), and type enforcement would require a separate schema declaration with no clear benefit over letting R's normal type errors surface downstream

If stricter type checking is needed, validator functions can be composed at the leaf level:

```r
validated <- function(init, check) {
  val <- reactiveVal(init)
  function(x) {
    if (missing(x)) val()
    else { check(x); val(x) }
  }
}
```

---

## 6. List Nodes

### Atomic lists

Unnamed lists (arrays) are stored atomically — as a single `reactiveVal` holding the whole R list. No recursion into list items.

```r
state$todos()          # returns plain R list
state$todos(new_list)  # replaces entire list, invalidates all readers
```

This is intentional. Fine-grained per-item reactivity for lists is the responsibility of `Each` and `Index`, not the store.

### Complete replacement only

Since the store has no visibility into the contents of an unnamed list, partial updates are not possible at the store level. Writes must replace the entire list. Attempting a named patch on an unnamed list node is an error:

```r
state$todos(list(done = TRUE))
# Error: 'todos' is an unnamed list node and must be replaced completely.
```

The idiomatic pattern for item-level updates is to read, transform with purrr, and write back:

```r
library(purrr)

# Update a single item by id
state$todos(modify_if(state$todos(), \(t) t$id == 1, \(t) modifyList(t, list(done = TRUE))))

# Toggle all items
state$todos(map(state$todos(), \(t) modifyList(t, list(done = TRUE))))

# Remove an item
state$todos(keep(state$todos(), \(t) t$id != 2))

# Append
state$todos(c(state$todos(), list(list(id = 3, text = "New", done = FALSE))))
```

### Why this is sufficient

irid's `Index` passes each item to its callback as a **reactive accessor**. When the list `reactiveVal` fires, `Index` diffs by position and only re-fires observers for items that actually changed — without recreating DOM nodes. Per-item surgical updates therefore work correctly even with an atomic list store.

irid's `Each` passes each item as a **plain value** and recreates all items when the list changes. The `by` parameter preserves DOM nodes on reorder but does not prevent recreation on value changes. `Each` is the right choice when add/remove/reorder are the common operations, not in-place value updates — and for those workflows complete list replacement is natural anyway.

### Usage with Index

```r
# Index handles per-item reactivity — atomic list is fine
Index(state$todos, \(item) {
  tags$li(
    \() item()$text,
    tags$input(
      type = "checkbox",
      checked = \() item()$done,
      onClick = \(e) {
        state$todos(modify_if(state$todos(), \(t) t$id == item()$id,
                              \(t) modifyList(t, list(done = e$checked))))
      }
    )
  )
})
```

### Usage with Each

```r
# Each recreates on list change — use for add/remove/reorder workflows
Each(state$todos, by = \(x) x$id, \(item) {
  tags$li(item$text)
})
```

---

## 7. Design Decisions

### Why patch semantics for branch writes?

A PUT-style branch write (requiring all keys) would force callers to reconstruct the entire subtree even when only one field is changing. This is particularly painful at the root level where the store may have many top-level keys. PATCH semantics — write only what you're changing — is more ergonomic and has no downside since unknown keys are still caught as errors.

### Why not `state$user$name <- "Bob"`?

Assignment syntax would be more idiomatic R, but it requires `$<-.store_node` to return a modified copy of the parent — which doesn't work for reference semantics. More importantly, consistency with `reactiveVal` is more valuable in a irid context. Users already know `val()` to read and `val(x)` to write; the store just extends that pattern recursively.

### Why not a single root `reactiveVal`?

One `reactiveVal` at the root holding the entire nested list is the simplest possible implementation. But it means `state$user$name()` invalidates when `state$todos` changes — defeating the entire purpose of fine-grained reactivity.

### Why not `makeActiveBinding`?

`makeActiveBinding` can make `state$user$name` behave like a reactive on read/write without the call syntax. But it only works one level deep on environments, and it obscures the fact that each node is a function — making it harder to pass nodes as reactive arguments to irid tags.

### Where does this live — companion package or in irid?

The store is closely related to irid's control flow primitives, particularly the interaction between atomic list nodes and `Each`/`Index`. The clean division of responsibility described in Section 6 only works because `Index` passes reactive accessors and `Each` handles its own diffing. If either of those changed, the store design would need to change too.

This suggests the store belongs inside irid eventually. A reasonable path is to develop it as a companion package first while the API stabilises, then merge it once both sides are proven.

---

## 8. Resolved Questions

### No `[[` for positional access

`state$todos()[[1]]` is sufficient. Adding `[[.store_node` would create ambiguity about whether the returned value is reactive or plain. Keeping the rule "call it to read" — at every level — is simpler to teach and consistent with the rest of the API.

### Serialisation via `load_store`

A `load_store(state, saved_list)` function should exist for session restore. It is just a recursive branch write from the root, so the existing machinery handles it. The implementation must validate that the saved snapshot's shape matches the current store shape — extra or missing keys should error, not silently diverge.

```r
load_store <- function(store, snapshot) {
  store(snapshot)
}
```

### `reactiveVal` identity is guaranteed

If a user holds a direct reference to a leaf node (`name_node <- state$user$name`) and the store is later updated via a branch write, the reference remains valid. Leaves are never replaced — only written to. Branch writes fan down to existing leaf `reactiveVal`s; they never create new ones. This is a guaranteed property of the store and should be documented as such.

---

## 9. Patterns

### Edit drafts over collection elements

The store is for record-like state; collections live as atomic list nodes.
The interesting boundary is what happens when the user wants to edit a
single element of a collection with fine-grained per-field reactivity —
a form over the currently selected todo, for example.

The pattern: **spin up a fresh store from the selected element when the
edit session begins, and write it back to the collection on save.** The
canonical list never knows the draft exists; the draft is a short-lived
record store with the same shape as the element it was cloned from.

```r
state <- reactiveStore(list(
  todos = list(
    list(id = 1L, text = "Learn irid", done = FALSE,
         meta = list(priority = "high", notes = "")),
    ...
  ),
  selected_id = NULL
))

edit_draft <- NULL

start_edit <- function(id) {
  item <- Find(\(t) t$id == id, state$todos())
  edit_draft <<- reactiveStore(item)
  state$selected_id(id)
}

save_edit <- function() {
  snapshot <- edit_draft()
  state$todos(lapply(
    state$todos(),
    \(t) if (t$id == snapshot$id) snapshot else t
  ))
  state$selected_id(NULL)
  edit_draft <<- NULL
}

cancel_edit <- function() {
  state$selected_id(NULL)
  edit_draft <<- NULL
}
```

Inside the edit form, every field binds to its own reactive leaf:

```r
tags$input(
  value = edit_draft$text,
  onInput = \(e) edit_draft$text(e$value)
)
tags$input(
  type = "checkbox",
  checked = edit_draft$done,
  onClick = \(e) edit_draft$done(e$checked)
)
tags$select(
  value = edit_draft$meta$priority,
  onChange = \(e) edit_draft$meta$priority(e$value)
)
```

Typing in the text box doesn't invalidate the priority dropdown; toggling
`done` doesn't invalidate the text field. The nested `meta` branch is a
mini-store by the standard recursion rules, so `edit_draft$meta$priority`
is its own leaf with its own subscribers.

**Why this is the right shape:**

- **No positional stores needed.** Items live as plain data in an atomic
  list; per-item render reactivity comes from `Index`; per-field edit
  reactivity comes from the short-lived draft store. Each layer handles
  the granularity it is built for, and the Solid-style array-recursion
  trap (§3.1 of the theory doc) is avoided.
- **Cancel is free.** Dropping the draft reference discards all its
  leaves with no stale subscribers — the draft was never wired into the
  canonical state tree, so nothing upstream depended on it.
- **Save is one write.** `edit_draft()` produces a plain nested list by
  the standard read rules; `lapply` places it back in the collection;
  `state$todos(...)` is a single whole-list replacement that the existing
  atomic-list machinery handles.
- **Nested structure falls out.** If the item has named sub-objects, the
  draft's branch recursion automatically gives you per-field reactivity
  inside them. No special handling for nesting depth.
- **Components compose.** Since branches behave as mini-stores, you can
  pass `edit_draft$meta` to a `MetaEditor(meta)` component without the
  component knowing whether it received a full store or a subtree — the
  same composability property described in §3 applies to drafts.

**When loose `reactiveVal`s are enough instead.** If the element has two
or three fields, constructing a store is ceremony without payoff —
`reactiveVal(item$text)` and `reactiveVal(item$done)` are just as clean.
The draft-store pattern earns its keep when the field count grows, when
there is nested structure, or when the draft is passed through multiple
components that would otherwise need a bag of `reactiveVal`s plumbed
through them.
