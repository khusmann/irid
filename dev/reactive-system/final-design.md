# irid Reactive System — Final Design

**Status:** Final, April 2026.

---

## Summary

irid's state and rendering model is built on six concepts:

1. **`reactiveStore`** — hierarchical reactive state.
2. **Auto-bind** — state-binding props (`value`, `checked`, `selected`)
   accept a callable and automatically two-way bind.
3. **`reactiveProxy`** — wraps a callable with custom read/write behavior.
   The single mechanism for validation, transforms, side effects, and
   read-only views at component boundaries.
4. **`Each`** — collection iteration with per-item mini-stores.
5. **`Fields`** — record (branch) iteration.
6. **`.event` config** — element-level timing and transport.

Every piece of state — store branch, store leaf, standalone `reactiveVal`,
per-item accessor inside `Each` — is a **unified callable**: `x()` reads,
`x(value)` writes. Auto-bind and `reactiveProxy` work with any callable
without knowing which kind it is.

---

## `reactiveStore`

### Construction

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

Named lists recurse into branches; unnamed lists at leaf positions stay
atomic (held as a single `reactiveVal`).

- `state$user` — branch (navigable record).
- `state$user$name` — leaf (`reactiveVal`-backed).
- `state$todos` — atomic leaf holding an unnamed list (collection).

Every node is callable. `node()` reads, `node(value)` writes.
Leaves replace; branches patch.

### Reading

```r
state$user$name()   # "Alice" — leaf, tracked at leaf level
state$user()        # list(name = "Alice", email = "alice@example.com")
state()             # entire store as a list
```

Reading a branch registers a dependency on the whole subtree; it
recomputes when any descendant changes. Reading a leaf registers a
dependency on that leaf only.

### Writing

**Leaf write** — replaces the value:

```r
state$user$name("Bob")
```

**Branch write** — patches. Only the specified keys are updated; unspecified
keys are left unchanged:

```r
# Only name is updated — email is unchanged
state$user(list(name = "Charlie"))

# Patch from root — todos unchanged
state(list(user = list(name = "Eve")))
```

**Unknown keys always error:**

```r
state$user(list(name = "Bob", phone = "555-0100"))
# Error: Unknown keys in store node 'user': phone
```

### Shape validation

The store's shape is fixed at construction time. The store never grows new
keys after construction.

Unknown keys on branch writes are always an error. Types are not enforced
— `state$user$name(42)` is accepted even if the initial value was a string.
Type errors surface downstream, as usual in R. If stricter typing is needed,
use `reactiveProxy` at the leaf.

### Atomic list nodes

Unnamed lists are stored atomically as a single `reactiveVal`. No recursion
into list items. Partial updates are not possible at the store level — writes
must replace the entire list:

```r
state$todos()          # returns plain R list
state$todos(new_list)  # replaces entire list
```

The idiomatic pattern for item-level updates is read-transform-write:

```r
library(purrr)

# Toggle a single item by id
state$todos(
  modify_if(state$todos(), \(t) t$id == 1L, \(t) modifyList(t, list(done = TRUE)))
)

# Remove an item
state$todos(keep(state$todos(), \(t) t$id != 2L))

# Append
state$todos(c(state$todos(), list(list(id = 3L, text = "New", done = FALSE))))
```

Fine-grained per-item reactivity is the responsibility of `Each`, not the store.

### Internal design

**Leaves are `reactiveVal`, branches are plain functions.**

Every node is externally callable with reads (no argument) and writes (one
argument). The distinction is internal:

- **Leaves** hold a `reactiveVal`. Reads and writes both go through it directly.
- **Branches** are plain functions for the *read* path. Reading a branch calls
  each child and assembles the result — callers subscribe directly to the leaf
  `reactiveVal`s they touch. The branch's *write* path validates the incoming
  keys and calls each child's write function, recursing down until every
  affected leaf's `reactiveVal` has been set.

The key insight: **leaves are the source of truth**. Branches never own state;
their read is a direct assembly from children, and their write is a fan-out to
children.

```
Write root → fans out to children → fans out to leaves (reactiveVal)
Read leaf  → reactiveVal
Read branch → calls children → subscribes to their reactiveVals
```

Why no circular invalidation: branches are plain functions with no state of
their own — there is nothing to write to. Writing to a branch calls the write
function on each child; it never invalidates or touches the branch's read path
directly.

Branch writes fan out synchronously. irid's reactive system batches
invalidations and defers re-execution to the next flush, so all leaf writes
complete before any observer runs.

`reactiveVal` identity is guaranteed: leaf references (`node <- state$user$name`)
remain valid after branch writes. Leaves are never replaced — only written to.

---

## Auto-bind

State-binding props — `value`, `checked`, `selected` — accept a callable and
automatically two-way bind:

```r
tags$input(value = field)
tags$input(type = "checkbox", checked = todo$done)
tags$select(selected = state$sort)
```

### Detection by arity

A prop auto-binds when:

1. It is a recognized state-binding prop (`value`, `checked`, `selected`), and
2. Its value is a function.

Auto-bind reads (`f()`) for rendering and writes (`f(value)`) on the
corresponding DOM event. If the callable is 0-arg (no write path), auto-bind
still sends the value to the server, where the write is silently dropped and
the server echoes back the current value — the optimistic update protocol snaps
the input back. This is the same behavior as `reactiveProxy(x, set = NULL)`.

No tagging or class checks needed. `reactiveVal` is 0-or-1 by construction;
store leaves are the same; `\() expr()` is effectively read-only with snap-back.

### Corresponding DOM events

| Prop       | DOM event | Elements              |
|------------|-----------|-----------------------|
| `value`    | `input`   | text inputs, textarea |
| `checked`  | `change`  | checkboxes            |
| `selected` | `change`  | select, radio         |

Auto-bind always reads and writes through the callable. Write behavior is
controlled by what the callable does, not by providing competing event handlers.

### Event props are separate

Event props (`onClick`, `onSubmit`, `onKeyDown`, `onInput`, `onChange`, etc.)
are plain callbacks that fire on DOM events. They represent discrete actions,
not state synchronization. They are orthogonal to auto-bind — providing
`onInput` on an auto-bound element fires the callback on input events but does
not affect auto-bind's read/write behavior.

```r
# Auto-bind writes; onKeyDown handles a discrete action
tags$input(
  value = state$new_text,
  onKeyDown = \(e) if (e$key == "Enter") add_todo()
)
```

### Read-only display

A zero-arg function or a proxy with `set = NULL` — both behave the same.
Auto-bind sends the value, the write is dropped, the input snaps back:

```r
tags$input(value = \() toupper(state$user$name()))
tags$input(value = reactiveProxy(state$email, set = NULL))
```

To prevent user interaction entirely, disable the element:

```r
tags$input(value = \() state$email(), disabled = TRUE)
```

---

## `reactiveProxy`

Wraps a callable with custom `get` (read transform) and `set` (write handler).
The result is a callable — `proxy()` reads through `get`, `proxy(value)` calls
`set`. Auto-bind works unchanged because a proxy is just another callable.

```r
reactiveProxy(target, get = identity, set = \(v) target(v))
```

`set` is a side-effectful handler, not a pure transform. It receives the
incoming value and decides what to do — write to the target, write a transformed
value, set an error flag, trigger a side effect, or drop the write entirely.
Because `set` is a closure, it can read sibling state for cross-field validation.

### Use cases

**Validation gate:**

```r
reactiveProxy(state$email,
  set = \(v) if (is_valid_email(v)) state$email(v)
)
```

**Bidirectional transform:**

```r
reactiveProxy(state$temp_c,
  get = \(c) c * 9/5 + 32,
  set = \(f) state$temp_c((f - 32) * 5/9)
)
```

**Read-only (writes dropped, input snaps back):**

```r
reactiveProxy(state$email, set = NULL)
```

**Side effect on write:**

```r
reactiveProxy(state$search,
  set = \(v) { state$search(v); log_search(v) }
)
```

**Validation with error feedback:**

```r
email_error <- reactiveVal(NULL)
reactiveProxy(state$email,
  set = \(v) {
    if (is_valid_email(v)) { email_error(NULL); state$email(v) }
    else email_error("Invalid email address")
  }
)
```

**Cross-field validation (closure reads sibling):**

```r
reactiveProxy(state$date_range$end,
  set = \(v) if (v > state$date_range$start()) state$date_range$end(v)
)
```

**Formatting:**

```r
reactiveProxy(state$price_cents,
  get = \(v) sprintf("$%.2f", v / 100),
  set = \(v) state$price_cents(round(as.numeric(gsub("[$,]", "", v)) * 100))
)
```

### Why `reactiveProxy` instead of `onInput`

The `onInput`/`onChange` override pattern (used in earlier designs) disabled
auto-bind's write path when provided, giving the handler full control. This had
three limitations:

1. **DOM-level only.** `onInput` works on the element, not at component
   boundaries — it can't intercept writes through a component you don't control.

2. **Write-only.** Bidirectional transforms (temperature, currency) required
   separate read closures for `value` and write handlers for `onInput`, split
   across different props.

3. **Special-case semantics.** "Providing `onInput` disables auto-bind" is a
   non-obvious interaction.

`reactiveProxy` solves all three: it works at any boundary (wraps the callable,
not the element), handles both read and write transforms, and introduces no
special-case interactions with auto-bind.

| `onInput` pattern                               | `reactiveProxy` equivalent                       |
|-------------------------------------------------|--------------------------------------------------|
| `onInput = \(e) if (ok(e$value)) x(e$value)`   | `reactiveProxy(x, set = \(v) if (ok(v)) x(v))`  |
| `onInput = \(e) x(parse(e$value))`              | `reactiveProxy(x, set = \(v) x(parse(v)))`       |
| `onInput = \(e) { x(e$value); log(e$value) }`  | `reactiveProxy(x, set = \(v) { x(v); log(v) })` |
| `value = \() format(x())` + `onInput` for parse | `reactiveProxy(x, get = format, set = parse)`    |

### Composability

A proxy is a callable. Another proxy can wrap it:

```r
# Currency formatting
price_dollars <- reactiveProxy(state$price_cents,
  get = \(v) sprintf("$%.2f", v / 100),
  set = \(v) state$price_cents(round(as.numeric(gsub("[$,]", "", v)) * 100))
)

# Max-value gate on top
capped_price <- reactiveProxy(price_dollars,
  set = \(v) if (as.numeric(gsub("[$,]", "", v)) <= 10000) price_dollars(v)
)
```

### Component boundary patterns

**Common case — full access:**

```r
MyEditor(field = state$user$name)
```

**Validated:**

```r
validated <- reactiveProxy(state$user$name,
  set = \(v) if (nchar(v) <= 100) state$user$name(v)
)
MyEditor(field = validated)
```

**Read-only (writes dropped, snaps back):**

```r
MyEditor(field = reactiveProxy(state$user$name, set = NULL))
# Or equivalently:
MyEditor(field = \() state$user$name())
```

**Third-party component (can't modify):**

```r
# The component accepts a callable and writes to it.
# Proxy intercepts without the component knowing.
constrained <- reactiveProxy(state$content,
  set = \(v) if (nchar(v) <= 10000) state$content(v)
)
RichTextEditor(constrained)
```

---

## `Each`

Iterates a collection — an unnamed list held in a `reactiveVal`, a `reactive`,
or an atomic store leaf. Callback receives `(item, index)`.

```r
Each(collection, fn, by = NULL)
```

### Scalar items

When items are scalars (strings, numbers), `item` is a per-item reactive
accessor. `item()` reads, `item(value)` writes back to the parent collection
at that slot.

```r
Each(state$options, \(option, i) {
  tags$input(value = option)
})
```

### Record items (mini-stores)

When items are records (named lists), `item` is a per-item mini-store — a
read-only `reactiveStore` projection with synthetic setters that route writes
through the parent collection.

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$span(\() todo$text())
  )
})
```

- `todo$done()`, `todo$text()` — fine-grained reactive reads.
- `todo()` — reads the full record.
- `todo(new_record)` — writes the whole item back to the parent.
- `todo$done(TRUE)` — synthetic setter, internally does
  `todo(modifyList(todo(), list(done = TRUE)))`.

Auto-bind on mini-store fields uses the synthetic setter: `checked = todo$done`
reads from the leaf and writes through the parent on user input.

### `by` argument

`by = NULL` — positional reconciliation. Slot *i* is slot *i*. The list can
grow and shrink at the end; in-place value changes fire per-slot accessors
without DOM recreation.

`by = \(x) x$id` — keyed reconciliation. Items are tracked across reorders,
adds, and removes by their key. Kept items are patched (mini-store leaves
diffed, only changed fields fire); new items are mounted; removed items are
destroyed; reordered items have their DOM nodes moved.

### Callback second argument

`(item, i)` where `i` is a plain integer for `by = NULL` and the key value
for `by = fn`.

### One-way data flow

Mini-stores are projections. Data flows one direction: parent collection →
mini-store → DOM. Writes through mini-store leaves route back through the
parent. The leaf never holds independent state. The reactive graph is acyclic.

```r
# All three are equivalent — all write through the parent:
tags$input(type = "checkbox", checked = todo$done)   # auto-bind
todo$done(TRUE)                                       # synthetic setter
todo(modifyList(todo(), list(done = TRUE)))            # manual
```

Two-way mini-stores (leaf writes go directly to the leaf then propagate to the
parent) create circular reactive flow. One-way avoids it: the parent is the
single source of truth, mini-store leaves are projections with synthetic
setters, and the reactive graph is acyclic.

### Reconcile mechanics

On each reconcile pass (when the parent collection changes):

1. **New keys** → create a new mini-store/accessor, call `fn`, mount the DOM.
2. **Removed keys** → destroy the mini-store/accessor, unmount the DOM.
3. **Kept keys with changed values** → patch the mini-store (`store(new_value)`,
   which diffs and fires only changed leaves) or replace the `reactiveVal`.
   The existing DOM reacts to the fine-grained leaf changes — no teardown/rebuild.
4. **Reordered keys** → move DOM nodes to match the new order.

Step 3 patches rather than replaces. A todo whose `done` flips from `FALSE`
to `TRUE` fires only `todo$done`'s observers, not `todo$text`'s.

### `reactiveProxy` on mini-store fields

A proxy can wrap a mini-store field for per-field write control:

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  validated_text <- reactiveProxy(todo$text,
    set = \(v) if (nchar(trimws(v)) > 0) todo$text(v)
  )
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = validated_text)
  )
})
```

`done` is unaffected — no cross-field leak. The proxy wraps the individual
leaf, not the whole mini-store.

### Vertical composition: `Each` inside `Each`

When a record item contains a sub-collection, the outer `Each` produces a
mini-store, and the inner `Each` iterates a leaf of that mini-store:

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

Writes flow through a two-level synthetic setter chain: inner scalar accessor
→ mini-store leaf → outer mini-store → parent collection. Each level uses the
same one-way mechanism.

### Read-only iteration

`Each` on a derived reactive wraps it in a `reactiveProxy(set = <error>)`
before iterating. Write attempts hit the proxy and error with a clear message.
No special case in `Each` — it sees a callable either way.

### When mini-stores are not created

- **Scalar items** get a per-item `reactiveVal`, not a store.

---

## `Fields`

Iterates the children of a store branch. Callback receives
`(child_node, key)`:

```r
Fields(branch, fn)
```

- `child_node` is a store node (leaf or nested branch). It is a callable —
  `child_node()` reads, `child_node(value)` writes.
- `key` is the child's field name as a string.

Branches have static shape, so `Fields` has no reconciliation — it calls `fn`
once per child at mount time. `Fields` itself is not reactive; the callback's
DOM is reactive to the child nodes it captured.

```r
Fields(state$user, \(field, key) {
  tags$div(
    tags$label(key),
    tags$input(value = field)
  )
})
```

### Recursive generic forms

`Fields` composes with two-level rendering — `RenderGroup` for branches,
`RenderField` for leaves:

```r
RenderField <- function(field, key) {
  tags$div(
    tags$label(key),
    tags$input(value = field)
  )
}

RenderGroup <- function(group) {
  tags$fieldset(
    tags$legend(\() group$name()),
    Fields(group$fields, RenderField)
  )
}

Fields(state, \(group, key) RenderGroup(group))
```

The store shape encodes the group label alongside the fields:

```r
state <- reactiveStore(list(
  user = list(
    name   = "User",
    fields = list(name = "", email = "")
  ),
  address = list(
    name   = "Address",
    fields = list(street = "", city = "", zip = "", country = "US")
  )
))
```

`RenderField` and `RenderGroup` capture nothing from the call site — they can
live outside any app function.

---

## `.event` config

Element-level prop controlling timing and transport for auto-bind write-back
and explicit event handlers. Set via config constructors:

```r
event_debounce(ms, coalesce = TRUE)
event_throttle(ms, leading = TRUE, coalesce = TRUE)
event_immediate(coalesce = FALSE)
```

Default for elements with auto-bound `value`: `event_debounce(200)`.
Default for all other events: `event_immediate()`.

```r
# Auto-bound value, default debounce
tags$input(value = field)

# Custom debounce
tags$input(value = field, .event = event_debounce(500))

# Immediate (no debounce)
tags$input(value = field, .event = event_immediate())

# Throttled button
tags$button("Save", onClick = \() save(), .event = event_throttle(1000))
```

### `.prevent_default`

Calls `event.preventDefault()` in the browser before dispatching. Orthogonal
to `.event`. Default: `FALSE`.

```r
tags$form(onSubmit = \(e) handle(e), .prevent_default = TRUE)
```

The `.` prefix signals "element config, not DOM attribute." Handlers are plain
functions — timing and transport config lives on the element, not wrapped
around the handler.

---

## `PlotlyOutput`

`PlotlyOutput` is a planned first-class output primitive for rendering
interactive Plotly charts with reactive state integration. The design is
documented separately at `dev/plotly-output-design.md` and is pending
rewrite to align with the reactive system idioms described here.

The key idiom: each Plotly event type (relayout, select, restyle) gets its
own store as the unit of update. `PlotlyOutput` accepts these stores as named
arguments. Auto-sync is implicit — passing a store means `PlotlyOutput` reads
its fields for rendering and writes them back when the corresponding event
fires. `reactiveProxy` wraps individual fields for constrained cases.

---

## Conventions

### Inherent vs policy constraints

Two kinds of validation belong in different places:

- **Inherent constraints** define what the component *is*. A `PortInput` that
  only accepts 1–65535 isn't enforcing a business rule — it's defining "port
  number." This validation belongs inside the component.

- **Policy constraints** vary by context. "Only valid emails" might be required
  in a registration form but not in a search box. These belong in a
  `reactiveProxy` at the call site.

They compose naturally through the callable:

```r
# Component defines "is a port number" (inherent)
PortInput <- function(port) {
  validated <- reactiveProxy(port,
    set = \(v) {
      n <- as.integer(v)
      if (!is.na(n) && n >= 1L && n <= 65535L) port(n)
    }
  )
  tags$input(type = "number", value = validated)
}

# Parent defines "must be above 1024" (policy)
safe_port <- reactiveProxy(state$port,
  set = \(v) if (as.integer(v) > 1024L) state$port(v)
)
PortInput(safe_port)
```

Neither knows about the other — they compose through the callable. The parent's
proxy runs first, then the component's internal proxy runs on whatever got through.

### Keep policy proxies close to the leaf

Policy proxies should be created as close to the point of use as possible —
typically in the parent's call site, right before passing the callable to a
component or binding it to an element.

Chaining proxies at the *same* call site is fine — it's functional composition.
The antipattern is *policy* proxies layered at *different* component boundaries,
where write behavior becomes scattered and hard to reason about.

Inherent + policy layering across boundaries is fine — those are separate
concerns owned by separate parties (component author vs parent), each
understandable independently.

### `reactiveProxy` intercepts before the write; `observe` reacts after

A proxy's `set` runs *before* the value reaches state — it can validate,
transform, or reject the write entirely. Bad state never exists, even for a
single reactive flush cycle.

`observe` runs *after* state changes. If an observer tries to "fix" invalid
state by writing corrected state, that triggers another flush cycle with its
own cascading effects. This is a major source of observer spaghetti in Shiny:
using `observe` to enforce invariants creates chains of post-hoc corrections
that are hard to debug and prone to glitchy intermediate states.

```r
# BAD — observe reacts after the write. Invalid state briefly exists.
observe({
  if (!is_valid_email(state$email())) state$email("")
})

# GOOD — proxy rejects the write. Invalid state never exists.
validated_email <- reactiveProxy(state$email,
  set = \(v) if (is_valid_email(v)) state$email(v)
)
```

**Rule of thumb:** if you're using `observe` to enforce a constraint on state,
you almost certainly want a `reactiveProxy` instead.

### When to use `observe`

`observe` is for synchronizing with the outside world — things that aren't
reactive state. This is analogous to React's `useEffect`.

Legitimate uses:

- **External I/O.** Writing to a database, sending an API request, saving to
  a file when state changes.
- **Logging and analytics.** Recording state changes for debugging or telemetry.
- **Non-irid UI updates.** Updating a Shiny output, triggering a notification,
  or interacting with a JavaScript library not managed by irid.
- **Session lifecycle.** Setup and teardown on reactive condition changes.

Not legitimate uses:

- **Enforcing invariants on state.** Use `reactiveProxy`.
- **Derived state.** Use `reactive()`.
- **Responding to user input.** Use auto-bind, event callbacks, or `reactiveProxy`.

---

## How the concepts work together

### Summary table

| Concern                              | Mechanism                                         |
|--------------------------------------|---------------------------------------------------|
| Hierarchical reactive state          | `reactiveStore`                                   |
| Single reactive value                | `reactiveVal`                                     |
| Derived state                        | `reactive()`                                      |
| Two-way DOM binding                  | Auto-bind (`value`, `checked`, `selected`)        |
| Write-path control                   | `reactiveProxy`                                   |
| Sync with outside world              | `observe`                                         |
| Discrete user actions                | Event callbacks (`onClick`, `onSubmit`, ...)      |
| Collection iteration (fine-grained)  | `Each` with mini-stores                           |
| Record/branch iteration              | `Fields`                                          |
| Event timing                         | `.event` (element-level config)                   |

### The common case

A component accepts a callable, auto-bind handles reads and writes. No ceremony:

```r
EmailInput <- function(email) {
  tags$input(type = "email", value = email)
}

EmailInput(state$email)
```

### Adding validation at a component boundary

The parent wraps the callable in a proxy. The component is unchanged:

```r
validated_email <- reactiveProxy(state$email,
  set = \(v) if (is_valid_email(v)) state$email(v)
)
EmailInput(validated_email)
```

### Adding a bidirectional transform

```r
temp_f <- reactiveProxy(state$temp_c,
  get = \(c) c * 9/5 + 32,
  set = \(f) state$temp_c((f - 32) * 5/9)
)
TemperatureInput(temp_f, label = "Fahrenheit")
```

### Iterating a collection with per-field validation

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  validated_text <- reactiveProxy(todo$text,
    set = \(v) if (nchar(trimws(v)) > 0) todo$text(v)
  )
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = validated_text)
  )
})
```

### Recursive form with auto-bind

```r
ProfileApp <- function() {
  defaults <- list(
    user = list(
      name   = "User",
      fields = list(name = "", email = "")
    ),
    address = list(
      name   = "Address",
      fields = list(street = "", city = "", zip = "")
    )
  )
  state <- reactiveStore(defaults)

  page_fluid(
    Fields(state, \(group, key) RenderGroup(group)),
    tags$button("Reset", onClick = \() state(defaults))
  )
}
```

### Third-party component interception

```r
constrained <- reactiveProxy(state$content,
  set = \(v) if (nchar(v) <= 10000) state$content(v)
)
RichTextEditor(constrained)  # can't modify, don't need to
```

---

## Open questions

1. ~~**Callback second argument for keyed `Each`.**~~ Resolved: `(item, i)`
   where `i` is a plain integer for `by = NULL` and the key value for `by = fn`.

2. ~~**Read-only `Each` on derived reactives.**~~ Resolved: wrap in
   `reactiveProxy(set = <error>)` before iterating. No separate primitive needed.

3. **Multi-level synthetic setter chain.** When `Each` is nested inside `Each`,
   writes flow through two levels of synthetic setters. Each link uses the same
   one-way mechanism so it should compose, but needs prototype validation.
   Concerns: redundant reconcile passes, performance at three or more levels.
