# irid Stores, Iteration, Auto-Bind & Reactive Proxies

**Status:** Draft, April 2026.
**Prior art:** `dev/stores1/` (store internals, theory),
`dev/stores2/` (unified callables, auto-bind, mini-stores,
write-control pattern evaluation).

---

## Summary

This doc describes irid's unified state and rendering model. Every
piece of state — store branch, store leaf, standalone `reactiveVal`,
per-item accessor inside `Each` — is a **unified callable**:
`x()` reads, `x(value)` writes.

Six concepts make up the system:

1. **`reactiveStore`** — hierarchical reactive state.
2. **Auto-bind** — state-binding props (`value`, `checked`,
   `selected`) accept a callable and automatically two-way bind.
3. **`reactiveProxy`** — wraps a callable with custom read/write
   behavior. The single mechanism for validation, transforms,
   side effects, and read-only views at component boundaries.
4. **`Each`** — collection iteration with per-item mini-stores.
5. **`Fields`** — record (branch) iteration.
6. **`.event` config** — element-level timing and transport.

---

## `reactiveStore`

Creates a hierarchical reactive store. Named lists recurse into
branches; unnamed lists at leaf positions stay atomic (held as a
single `reactiveVal`).

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

- `state$user` — branch (navigable record).
- `state$user$name` — leaf (`reactiveVal`-backed).
- `state$todos` — atomic leaf holding an unnamed list (collection).

Every node is callable. `node()` reads, `node(value)` writes.
Leaves replace; branches patch.

---

## Auto-bind

State-binding props — `value`, `checked`, `selected` — accept a
callable and automatically two-way bind:

```r
# Auto-bind: reads from field(), writes back on user input
tags$input(value = field)
tags$input(type = "checkbox", checked = todo$done)
tags$select(selected = state$sort)
```

### Detection by arity

A prop auto-binds when:

1. It is a recognized state-binding prop (`value`, `checked`,
   `selected`), and
2. Its value is a function.

Auto-bind reads (`f()`) for rendering and writes (`f(value)`) on
the corresponding DOM event. If the callable is 0-arg (no write
path), auto-bind still sends the value to the server, where the
write is silently dropped and the server echoes back the current
value — the optimistic update protocol snaps the input back. This
is the same behavior as `reactiveProxy(x, set = NULL)`.

No tagging or class checks needed. `reactiveVal` is 0-or-1 by
construction; store leaves are the same; `\() expr()` is
effectively read-only with snap-back.

### Corresponding DOM events

Each state-binding prop has a corresponding DOM event that
triggers write-back:

| Prop       | DOM event | Elements              |
|------------|-----------|-----------------------|
| `value`    | `input`   | text inputs, textarea |
| `checked`  | `change`  | checkboxes            |
| `selected` | `change`  | select, radio         |

Auto-bind always reads and writes through the callable. There is
no special-case override mechanism — write behavior is controlled
by what the callable does, not by providing competing event
handlers.

### Event props are separate

Event props (`onClick`, `onSubmit`, `onKeyDown`, `onInput`,
`onChange`, etc.) are plain callbacks that fire on DOM events.
They represent discrete actions, not state synchronization. They
are orthogonal to auto-bind — providing `onInput` on an auto-bound
element fires the callback on input events but does not affect
auto-bind's read/write behavior.

```r
# Auto-bind writes, onKeyDown handles a discrete action
tags$input(
  value = state$new_text,
  onKeyDown = \(e) if (e$key == "Enter") add_todo()
)
```

### Read-only display

A zero-arg function or a proxy with `set = NULL` — both behave
the same. Auto-bind sends the value, the write is dropped, the
input snaps back to the server-side value:

```r
tags$input(value = \() toupper(state$user$name()))
tags$input(value = reactiveProxy(state$email, set = NULL))
```

To prevent user interaction entirely, disable the element — that's
the dev's choice, not the framework's:

```r
tags$input(value = \() state$email(), disabled = TRUE)
```

---

## `reactiveProxy`

Wraps a callable with custom `get` (read transform) and `set`
(write handler). The result is a callable — `proxy()` reads
through `get`, `proxy(value)` calls `set`. Auto-bind works
unchanged because a proxy is just another callable.

```r
reactiveProxy(target, get = identity, set = \(v) target(v))
```

`set` is a side-effectful handler, not a pure transform. It
receives the incoming value and decides what to do — write to the
target, write a transformed value, set an error flag, trigger a
side effect, or drop the write entirely. Because `set` is a
closure, it can read sibling state for cross-field validation.

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

Auto-bind sends the value, `set = NULL` drops it, the server
echoes back the current value, and the input snaps back. This is
the same behavior as a 0-arg function (`\() state$email()`). The
proxy controls the write path, not the element's editability. To
prevent interaction entirely, disable the element separately.

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

The prior design (stores2) used `onInput` / `onChange` to override
auto-bind write-back on state-bound elements. Providing `onInput`
disabled auto-bind's write path and gave the handler full control.

`reactiveProxy` replaces this mechanism entirely:

| `onInput` pattern                               | `reactiveProxy` equivalent                       |
|-------------------------------------------------|--------------------------------------------------|
| `onInput = \(e) if (ok(e$value)) x(e$value)`   | `reactiveProxy(x, set = \(v) if (ok(v)) x(v))`  |
| `onInput = \(e) x(parse(e$value))`              | `reactiveProxy(x, set = \(v) x(parse(v)))`       |
| `onInput = \(e) { x(e$value); log(e$value) }`  | `reactiveProxy(x, set = \(v) { x(v); log(v) })` |
| `value = \() format(x())` + `onInput` for parse | `reactiveProxy(x, get = format, set = parse)`    |

The advantages:

- **Works at component boundaries.** `onInput` only works at the
  DOM element level — it can't intercept writes through a component
  you don't control. A proxy wraps the callable itself, so it works
  regardless of what the component does internally.

- **Fewer concepts.** The "onInput disables auto-bind" special case
  is removed. Auto-bind always reads and writes through the
  callable. Write behavior is controlled by what the callable does
  (which a proxy can customize), not by providing competing handlers.

- **Bidirectional transforms.** `onInput` could only intercept
  writes. Transforms that affect both reads and writes (temperature,
  currency formatting) required separate read-only closures for
  `value` and write handlers for `onInput`, split across different
  props. A proxy holds both directions in one place.

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

The component doesn't need to support any interception protocol.
A proxy is transparent — it's just a callable.

---

## `Each`

Iterates a collection — an unnamed list held in a `reactiveVal`,
a `reactive`, or an atomic store leaf. Callback receives
`(item, index)`.

```r
Each(collection, fn, by = NULL)
```

### Scalar items

When items are scalars (strings, numbers), `item` is a per-item
reactive accessor. `item()` reads, `item(value)` writes back to
the parent collection at that slot.

```r
Each(state$options, \(option, i) {
  tags$input(value = option)
})
```

### Record items (mini-stores)

When items are records (named lists), `item` is a per-item
mini-store — a read-only `reactiveStore` projection with synthetic
setters that route writes through the parent collection.

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

Auto-bind on mini-store fields uses the synthetic setter:
`checked = todo$done` reads from the leaf and writes through
the parent on user input.

### `by` argument

`by = NULL` — positional reconciliation. Slot *i* is slot *i*.
The list can grow and shrink at the end; in-place value changes
fire per-slot accessors without DOM recreation.

`by = \(x) x$id` — keyed reconciliation. Items are tracked across
reorders, adds, and removes by their key. Kept items are patched
(mini-store leaves diffed, only changed fields fire); new items
are mounted; removed items are destroyed; reordered items have
their DOM nodes moved.

### Callback second argument

`(item, i)` where `i` is a plain integer for `by = NULL` and the
key value for `by = fn`.

### One-way data flow

Mini-stores are projections. Data flows one direction: parent
collection -> mini-store -> DOM. Writes through mini-store leaves
route back through the parent. The leaf never holds independent
state. The reactive graph is acyclic.

```r
# All three are equivalent — all write through the parent:
tags$input(type = "checkbox", checked = todo$done)   # auto-bind
todo$done(TRUE)                                       # synthetic setter
todo(modifyList(todo(), list(done = TRUE)))            # manual
```

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

`done` is unaffected — no cross-field leak. The proxy wraps the
individual leaf, not the whole mini-store.

### Vertical composition: `Each` inside `Each`

When a record item contains a sub-collection, the outer `Each`
produces a mini-store, and the inner `Each` iterates a leaf of
that mini-store:

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

Writes flow through a two-level synthetic setter chain: inner
scalar accessor -> mini-store leaf -> outer mini-store -> parent
collection. Each level uses the same one-way mechanism.

### Read-only iteration

`Each` on a derived reactive produces read-only items. Write
attempts error with a clear message.

### When mini-stores are not created

- **Scalar items** get a per-item `reactiveVal`, not a store.
- **Derived-reactive sources** produce read-only items.

---

## `Fields`

Iterates the children of a store branch. Callback receives
`(child_node, key)`:

```r
Fields(branch, fn)
```

- `child_node` is a store node (leaf or nested branch). It is a
  callable — `child_node()` reads, `child_node(value)` writes.
- `key` is the child's field name as a string.

Branches have static shape, so `Fields` has no reconciliation —
it calls `fn` once per child at mount time. `Fields` itself is
not reactive; the callback's DOM is reactive to the child nodes
it captured.

```r
Fields(state$user, \(field, key) {
  tags$div(
    tags$label(key),
    tags$input(value = field)
  )
})
```

### Recursive generic forms

`Fields` composes with `is_store` dispatch for recursive rendering:

```r
RenderNode <- function(node, key) {
  if (is_store(node)) {
    tags$fieldset(
      tags$legend(key),
      Fields(node, RenderNode)
    )
  } else {
    tags$div(
      tags$label(key),
      tags$input(value = node)
    )
  }
}

Fields(state, RenderNode)
```

This handles heterogeneous siblings: a branch whose children mix
scalar leaves and nested sub-branches renders correctly without
hand-coding which fields are groups.

---

## `.event` config

Element-level prop controlling timing and transport for auto-bind
write-back and explicit event handlers. Set via config constructors:

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

Calls `event.preventDefault()` in the browser before dispatching.
Orthogonal to `.event`. Default: `FALSE`.

```r
tags$form(onSubmit = \(e) handle(e), .prevent_default = TRUE)
```

The `.` prefix signals "element config, not DOM attribute."

---

## How the concepts work together

### The common case

A component accepts a callable, auto-bind handles reads and
writes. No ceremony:

```r
EmailInput <- function(email) {
  tags$input(type = "email", value = email)
}

# Parent
EmailInput(state$email)
```

### Adding validation at a component boundary

The parent wraps the callable in a proxy. The component is
unchanged:

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
    user = list(name = "", email = ""),
    address = list(street = "", city = "", zip = "")
  )
  state <- reactiveStore(defaults)

  page_fluid(
    Fields(state, RenderNode),
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

## Conventions and scoping

### Inherent vs policy constraints

There are two kinds of validation, and they belong in different
places:

- **Inherent constraints** define what the component *is*. A
  `PortInput` that only accepts 1–65535 isn't enforcing a business
  rule — it's defining "port number." This validation belongs
  inside the component because every caller wants it. Removing it
  would make the component nonsensical.

- **Policy constraints** vary by context. "Only valid emails" might
  be required in a registration form but not in a search box. These
  belong in a `reactiveProxy` at the call site, where the parent
  decides.

They compose naturally. The parent's proxy runs first (filtering
what reaches the component), then the component's internal proxy
runs on whatever got through:

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

Neither knows about the other — they compose through the callable.

### Keep policy proxies close to the leaf

Policy proxies should be created as close to the point of use as
possible — typically in the parent's call site, right before
passing the callable to a component or binding it to an element.

**Do this:**

```r
# Parent creates the proxy and passes it directly
validated_email <- reactiveProxy(state$email,
  set = \(v) if (is_valid_email(v)) state$email(v)
)
EmailInput(validated_email)
```

**Don't do this:**

```r
# Grandparent creates a policy proxy, parent wraps another
# policy proxy — ad-hoc policy scattered across boundaries
proxy1 <- reactiveProxy(state$email,
  set = \(v) if (is_valid_email(v)) state$email(v)
)
# ... passed through intermediate component ...
proxy2 <- reactiveProxy(proxy1,
  set = \(v) if (nchar(v) <= 100) proxy1(v)
)
SomeInput(proxy2)
```

Chaining proxies at the *same* call site is fine — it's just
functional composition:

```r
# Both policy constraints applied in one place
formatted <- reactiveProxy(state$price_cents,
  get = \(v) sprintf("$%.2f", v / 100),
  set = \(v) state$price_cents(round(as.numeric(gsub("[$,]", "", v)) * 100))
)
capped <- reactiveProxy(formatted,
  set = \(v) if (as.numeric(gsub("[$,]", "", v)) <= 10000) formatted(v)
)
CurrencyInput(capped)
```

The antipattern is *policy* proxies layered at *different*
component boundaries. When multiple levels of the tree each add
their own ad-hoc policy proxy, the write behavior is scattered
across files and hard to reason about. Keep policy in one place.

Inherent + policy layering across boundaries is fine — those are
separate concerns owned by separate parties (component author vs
parent), and each can be understood independently.

### `reactiveProxy` intercepts before the write; `observe` reacts after

This distinction matters. A proxy's `set` runs *before* the value
reaches state — it can validate, transform, or reject the write
entirely. Bad state never exists, even for a single reactive
flush cycle.

`observe` runs *after* state changes. It sees the new value and
reacts — but the invalid state existed, downstream reactives saw
it, and if the observer tries to "fix" it by writing corrected
state, that triggers another flush cycle with its own cascading
effects.

This is a major source of Shiny's observer spaghetti: using
`observe` to enforce invariants creates chains of post-hoc
corrections that are hard to reason about, hard to debug, and
prone to infinite loops or glitchy intermediate states.

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

**Rule of thumb:** if you're using `observe` to enforce a
constraint on state, you almost certainly want a `reactiveProxy`
instead.

### When to use `observe`

`observe` is for synchronizing with the outside world — things
that aren't reactive state. This is analogous to React's
`useEffect`: it's the boundary between the reactive system and
everything else.

Legitimate uses of `observe`:

- **External I/O.** Writing to a database, sending an API request,
  saving to a file when state changes.
- **Logging and analytics.** Recording state changes for debugging
  or telemetry.
- **Non-irid UI updates.** Updating a Shiny output, triggering a
  notification, or interacting with a JavaScript library that
  isn't managed by irid.
- **Session lifecycle.** Setup and teardown that needs to happen
  when reactive conditions change.

Not legitimate uses of `observe`:

- **Enforcing invariants on state.** Use `reactiveProxy`.
- **Derived state.** Use `reactive()`.
- **Responding to user input.** Use auto-bind, event callbacks,
  or `reactiveProxy`.

The scoping is clean:

| Concern               | Mechanism        |
|-----------------------|------------------|
| Read/write state      | `reactiveStore`, `reactiveVal` |
| Derived state         | `reactive()`     |
| Write-path control    | `reactiveProxy`  |
| Sync with outside     | `observe`        |
| Discrete user actions | Event callbacks (`onClick`, `onSubmit`, ...) |

---

## Design decisions

### Why unified callables

The alternative is the React model: separate `value` and
`onChange` props. This gives the parent full control over the
write path but kills composability — every component boundary
needs both props threaded through, and recursive patterns like
`RenderNode` become verbose.

The unified callable inverts the control model: the parent trusts
the child with the state by default. Writes go through a
well-defined path (the store's write semantics). When the parent
needs write interception, it wraps the callable in a
`reactiveProxy` — the component never knows. This avoids the
pair-threading tax while preserving the ability to constrain.

### Why `reactiveProxy` instead of `onInput` overriding auto-bind

The prior design used `onInput`/`onChange` to override auto-bind
write-back. This had three limitations:

1. **DOM-level only.** `onInput` works on the element, not at
   component boundaries. It can't intercept writes through a
   component you don't control.

2. **Write-only.** Bidirectional transforms (temperature, currency)
   required separate read closures for `value` and write handlers
   for `onInput`, split across props.

3. **Special-case semantics.** "Providing `onInput` disables
   auto-bind" is a non-obvious interaction between two concepts.

`reactiveProxy` solves all three: it works at any boundary (it
wraps the callable, not the element), it handles both read and
write transforms, and it introduces no special-case interactions
with auto-bind (a proxy is just a callable — auto-bind treats it
like any other).

### Why per-item mini-stores instead of edit-draft

The edit-draft pattern (spin up a store, edit through it, write
back on save) is ceremony only justified for cancel/discard
workflows. For inline edits — toggling a checkbox, editing text
in place — mini-stores give field-level reactivity and auto-bind
by default. Edit-draft remains available for modal workflows.

### Why one-way mini-stores

Two-way mini-stores where leaf writes go directly to the leaf and
then propagate to the parent create circular reactive flow. One-way
avoids it: the parent collection is the single source of truth,
mini-store leaves are projections with synthetic setters. The
reactive graph is acyclic.

### Why `Each` defaults to positional

Positional reconciliation (`by = NULL`) is correct for static
homogeneous lists (options, grid rows). Keyed reconciliation is
opt-in for identity-tracked collections (todos, chat messages).

### Why element-level `.event` instead of handler wrappers

Timing config (`event_debounce`, `event_throttle`,
`event_immediate`) belongs on the element, not on the handler.
When auto-bind is active there is no explicit handler to wrap —
the timing has to live somewhere else. `.event` gives it a home
with a sensible default.

---

## Open questions

1. **Callback second argument for keyed `Each`.** Proposal:
   `(item, key)` where key is the value returned by `by`. Key as
   the second argument is more useful than position for keyed
   iteration.

2. **Read-only `Each` on derived reactives.** Write attempts error
   with a clear message. Is a separate primitive needed, or is the
   error sufficient?

3. **Multi-level synthetic setter chain.** When `Each` is nested
   inside `Each`, writes flow through two levels of synthetic
   setters. Each link uses the same one-way mechanism so it should
   compose, but needs prototype validation. Concerns: redundant
   reconcile passes, performance at three or more levels.

4. **Chained `reactiveProxy` semantics.** A proxy wrapping another
   proxy should compose naturally (outer `get` after inner `get`,
   outer `set` before inner `set`). Needs verification.

5. ~~**`reactiveProxy(x, set = NULL)` arity.**~~ Resolved: a
   read-only proxy presents as 0-or-1 args (same as any callable).
   Auto-bind attempts writes, but `set = NULL` drops them. The
   optimistic update protocol echoes back the server value, so the
   input snaps back. This is correct — the proxy controls the write
   path, not the element's editability. To prevent interaction, add
   `disabled = TRUE` on the element. The `\() x()` shorthand
   remains for the case where no write should be attempted at all
   (0-arg, auto-bind never writes).

---

## Relationship to prior design docs

- **`dev/stores1/`** — Store internals, theory doc, and stress
  tests remain valid. The edit-draft pattern is demoted from
  "required for field-level edits" to "useful for cancel/discard."

- **`dev/stores2/design.md`** — Superseded by this doc. The
  unified callable model, auto-bind, mini-stores, `Each`, `Fields`,
  and `.event` config carry forward. The `onInput`-overrides-
  auto-bind mechanism is replaced by `reactiveProxy`.

- **`dev/stores2/with-setter-validate/`** — Pattern evaluation
  that led to this design. Pattern (d) won; `reactiveProxy` is
  the renamed `reactiveView`.

---

## What this design is not

- **Not a rewrite of reactive primitives.** `reactiveVal`,
  `reactive`, `observe`, `isolate` are unchanged.
- **Not a change to `When` / `Match` / `Case` / `Default`.**
- **Not a recursive-store-over-arrays proposal.** Collections are
  still atomic at the store level. Mini-stores inside `Each` are
  one level deep by construction.
