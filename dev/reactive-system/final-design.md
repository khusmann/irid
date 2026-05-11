# irid Reactive System — Final Design

**Status:** Final, April 2026.

---

## Summary

irid's state and rendering model is built on six concepts:

1. **`reactiveStore`** — hierarchical reactive state.
2. **Auto-bind** — state-binding props (`value`, `checked`) accept a
   callable and automatically two-way bind.
3. **`reactiveProxy`** — builds a callable from a reader and optional writer.
   The single mechanism for validation, transforms, side effects, and
   read-only views at component boundaries.
4. **`Each`** — collection iteration with per-item mini-stores.
5. **`Match`** — variant dispatch with mini-store decomposition. Pattern-
   matching primitive (predicate Cases today, structurally extensible later).
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
  modify_if(state$todos(), \(t) t$id == 1L, \(t) { t$done <- TRUE; t })
)

# Remove an item
state$todos(keep(state$todos(), \(t) t$id != 2L))

# Append
state$todos(c(state$todos(), list(list(id = 3L, text = "New", done = FALSE))))
```

(`{ t$done <- TRUE; t }` rather than `modifyList(t, list(done = TRUE))`
even though both work here — the latter recurses into list-shaped
fields, so reaching for it as a general pattern bites the moment a
field is itself a list. See "One-way data flow" under `Each` below.)

Fine-grained per-item reactivity is the responsibility of `Each`, not the store.

### Variant leaves

A bare named list at a leaf position auto-classifies as a *branch* — fixed
shape at construction. To store a single record whose shape depends on a
discriminator field (a tagged union), wrap it in `I()`. `I()` is the
construction-time opt-out from branch classification; the named list is held
as the leaf's value verbatim:

```r
state <- reactiveStore(list(
  result = I(list(success = TRUE))
))
```

The leaf accepts any value on write, including a different variant shape.
Subsequent writes do not need `I()` — the leaf has already been classified
and accepts records directly:

```r
state$result(list(success = FALSE, reasons = list("Email required")))
state$result()  # list(success = FALSE, reasons = list("Email required"))
```

Reads return the record verbatim, with no automatic decomposition. The leaf is
a single `reactiveVal` — any change fires every observer of the leaf. To get
fine-grained per-field reactivity *and* shape-dependent rendering, consume the
leaf with `Match` in dispatch mode, which projects it as a mini-store over the
current variant. See **`Match`** for the consumption mechanics.

This is the storage half of the variant pattern. Without `Match`, the leaf
behaves as an opaque structured value — useful in its own right when you want
to treat the record atomically (config blobs, third-party objects), but it
gives you no decomposition.

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

### R-idiomatic store methods

Store branches support the standard R introspection generics: `names`,
`length`, `print`, and `str`. These make a branch feel like a regular named
list and pay off in contexts that have nothing to do with iteration.

Crucially, `[[` supports **integer indexing** in addition to string indexing.
Together with `length` and `names`, this means standard R and purrr iteration
works directly on a branch:

```r
# Single-arg callback — field only
lapply(state$user, \(field) tags$input(value = field))

# Two-arg callback — field and key (purrr)
imap(state$user, \(field, key) tags$div(tags$label(key), tags$input(value = field)))
```

`lapply` uses `seq_along(X)` (via `length`) and `X[[i]]` (integer `[[`) under
the hood. `imap` additionally reads `names(X)`. Both receive the child node
callables — not resolved values — so auto-bind works unchanged.

---

## Auto-bind

State-binding props — `value`, `checked` — accept a callable and
automatically two-way bind:

```r
tags$input(value = field)
tags$input(type = "checkbox", checked = todo$done)
```

### Detection by arity

A prop auto-binds when:

1. It is a recognized state-binding prop (`value`, `checked`), and
2. Its value is a function.

Auto-bind reads (`f()`) for rendering and writes (`f(value)`) on the
corresponding DOM event. If the callable is 0-arg (no write path), auto-bind
still sends the value to the server, where the write is silently dropped and
the server echoes back the current value — the optimistic update protocol snaps
the input back. This is the same behavior as `reactiveProxy(get = x)`.

No tagging or class checks needed. `reactiveVal` is 0-or-1 by construction;
store leaves are the same; `\() expr()` is effectively read-only with snap-back.

### Corresponding DOM events

| Prop       | DOM event | Elements              |
|------------|-----------|-----------------------|
| `value`    | `input`   | text inputs, textarea, select, radio |
| `checked`  | `change`  | checkboxes            |

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
tags$input(value = reactiveProxy(get = state$email))
```

To prevent user interaction entirely, disable the element:

```r
tags$input(value = \() state$email(), disabled = TRUE)
```

---

## `reactiveProxy`

Builds a callable from a 0-arg `get` reader and an optional 1-arg `set` writer.
The result is a callable — `proxy()` invokes `get()`, `proxy(value)` invokes
`set(value)`. Auto-bind works unchanged because a proxy is just another callable.

```r
reactiveProxy(get, set = NULL)
```

`get` is required: any 0-arg callable (a `reactiveVal`, a `reactiveStore` leaf,
another `reactiveProxy`, or a closure like `\() transform(rv())`).

`set` is a side-effectful handler, not a pure transform. It receives the
incoming value and decides what to do — write to a target, write a transformed
value, set an error flag, trigger a side effect, or drop the write entirely.
Because `set` is a closure, it can read sibling state for cross-field validation.
Omit `set` (or pass `NULL`) for a read-only proxy.

### Use cases

**Validation gate:**

```r
reactiveProxy(
  get = state$username,
  set = \(v) if (nchar(v) <= 20L) state$username(v)
)
```

**Bidirectional transform:**

```r
reactiveProxy(
  get = \() state$temp_c() * 9/5 + 32,
  set = \(f) state$temp_c((f - 32) * 5/9)
)
```

**Read-only (writes dropped, input snaps back):**

```r
reactiveProxy(get = state$email)
```

**Side effect on write:**

```r
reactiveProxy(
  get = state$search,
  set = \(v) { state$search(v); log_search(v) }
)
```

**Validation with error feedback:**

```r
username_error <- reactiveVal(NULL)
reactiveProxy(
  get = state$username,
  set = \(v) {
    if (nchar(v) <= 20L) { username_error(NULL); state$username(v) }
    else username_error("Username must be 20 characters or less")
  }
)
```

**Cross-field validation (closure reads sibling):**

```r
reactiveProxy(
  get = state$date_range$end,
  set = \(v) if (v > state$date_range$start()) state$date_range$end(v)
)
```

**Formatting:**

```r
reactiveProxy(
  get = \() sprintf("$%.2f", state$price_cents() / 100),
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

| `onInput` pattern                               | `reactiveProxy` equivalent                                     |
|-------------------------------------------------|----------------------------------------------------------------|
| `onInput = \(e) if (ok(e$value)) x(e$value)`   | `reactiveProxy(get = x, set = \(v) if (ok(v)) x(v))`          |
| `onInput = \(e) x(parse(e$value))`              | `reactiveProxy(get = x, set = \(v) x(parse(v)))`              |
| `onInput = \(e) { x(e$value); log(e$value) }`  | `reactiveProxy(get = x, set = \(v) { x(v); log(v) })`         |
| `value = \() format(x())` + `onInput` for parse | `reactiveProxy(get = \() format(x()), set = \(v) x(parse(v)))` |

### Composability

A proxy is a callable. Another proxy can wrap it:

```r
# Currency formatting
price_dollars <- reactiveProxy(
  get = \() sprintf("$%.2f", state$price_cents() / 100),
  set = \(v) state$price_cents(round(as.numeric(gsub("[$,]", "", v)) * 100))
)

# Max-value gate on top
capped_price <- reactiveProxy(
  get = price_dollars,
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
validated <- reactiveProxy(
  get = state$user$name,
  set = \(v) if (nchar(v) <= 100) state$user$name(v)
)
MyEditor(field = validated)
```

**Read-only (writes dropped, snaps back):**

```r
MyEditor(field = reactiveProxy(get = state$user$name))
# Or equivalently:
MyEditor(field = \() state$user$name())
```

**Third-party component (can't modify):**

```r
# The component accepts a callable and writes to it.
# Proxy intercepts without the component knowing.
constrained <- reactiveProxy(
  get = state$content,
  set = \(v) if (nchar(v) <= 10000) state$content(v)
)
RichTextEditor(constrained)
```

---

## `Each`

Iterates a collection — an unnamed list held in a `reactiveVal`, a `reactive`,
or an atomic store leaf. Callback is arity-polymorphic (0, 1, or 2 args).

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
- `todo$done(TRUE)` — synthetic setter, internally copies the current
  record, replaces `done` via `[[<-`, and hands the result to the
  parent. (Not `modifyList`: it recurses into list-shaped fields, which
  silently keeps original entries when the new value is shorter or
  unnamed.)

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

### Callback arity

The callback is dispatched by formal-argument count — `\() body`,
`\(item) body`, or `\(item, pos) body`. Drop the args you don't use.

- `item` — per-item callable (mini-store for records, reactive accessor
  for scalars), as described above.
- `pos` — **always a 0-arg reactive accessor** returning the item's
  current 1-indexed slot. Under `by = NULL` it is a constant signal
  (slot number is the identity, never changes). Under `by = fn` it is
  live and fires on reorder with the item's new slot.

The always-reactive shape keeps the callback uniform across modes and
covers patterns like live "Item #3 of 10" numbering, queue-position
indicators, or alternating row styles that follow reorders. Users who
need the stable key value in the `by = fn` case read it from the item
(`item$id()`) or re-apply `by` — a dedicated `key` arg was considered
and rejected as redundant for the common case where the key is derived
from the item itself.

### One-way data flow

Mini-stores are projections. Data flows one direction: parent collection →
mini-store → DOM. Writes through mini-store leaves route back through the
parent. The leaf never holds independent state. The reactive graph is acyclic.

```r
# All three are equivalent — all write through the parent:
tags$input(type = "checkbox", checked = todo$done)   # auto-bind
todo$done(TRUE)                                       # synthetic setter
todo({ r <- todo(); r$done <- TRUE; r })              # manual
```

Avoid `modifyList(todo(), list(done = TRUE))` for the manual form,
even though it works for scalar fields. `modifyList` recurses when both
sides of a key are list-shaped, so reaching for it as a general
"replace this slot" pattern bites the moment a field is itself a list
(e.g. `options = list(...)`). The explicit `[[<-` is shape-agnostic.

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
  validated_text <- reactiveProxy(
    get = todo$text,
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

### Discriminated unions in collections

When *collection items* follow a tagged union — different shapes for different
variants — use a compound `by` key that includes the discriminator. (For a
*single* variant-shaped value, store it as an `I()`-leaf and dispatch with
`Match` instead — see **`Match`**. The mechanics below are for collections
only.)

```r
Each(state$questions, by = \(q) paste0(q$id, "_", q$qtype), \(question) {
  tags$div(
    # ... common fields ...
    Match(question,
      Case(\(q) q$qtype == "text",   \(q) TextQuestion(q)),
      Case(\(q) q$qtype == "scale",  \(q) ScaleQuestion(q)),
      Case(\(q) q$qtype == "choice", \(q) ChoiceQuestion(q))
    )
  )
})
```

Mini-stores have fixed shape (derived from the item at mount time). The
compound key ensures a type change is treated as a remove + add rather than
a patch: the old mini-store (and its DOM) is torn down; a new one of the
correct shape is mounted. The fixed-shape constraint applies within a variant,
not across the union.

The write path replaces the whole item rather than just updating the
discriminator field. A `reactiveProxy` on the discriminator handles this,
delegating to a constructor that centralises variant shapes:

```r
new_question <- function(id, qtype, text = "") switch(qtype,
  text   = list(id = id, text = text, qtype = "text"),
  scale  = list(id = id, text = text, qtype = "scale"),
  choice = list(id = id, text = text, qtype = "choice", options = list(""))
)

qtype_proxy <- reactiveProxy(
  get = question$qtype,
  set = \(v) question(new_question(question()$id, v, text = question()$text))
)
```

`question(new_item)` routes through the mini-store's synthetic setter and
replaces the slot in the parent collection atomically. The reconciler then
sees the old compound key gone and the new one appearing — full teardown and
fresh mount with the correct shape for the new variant.

Because the component is remounted on type change, each `Case`'s predicate is
stable for the lifetime of its mini-store — it never flips. `Match` is still
required to evaluate the predicate in a reactive context and to mount the
correct branch:

```r
Match(question,
  Case(\(q) q$qtype == "choice", \(q) ChoiceConfig(q))
)
# $options is always present here — the mini-store shape guarantees it
```

### Read-only iteration

`Each` on a derived reactive wraps it in a `reactiveProxy(get = ..., set = <error>)`
before iterating. Write attempts hit the proxy and error with a clear message.
No special case in `Each` — it sees a callable either way.

### When mini-stores are not created

- **Scalar items** get a per-item `reactiveVal`, not a store.

---

## `Match`

Renders one of several alternatives based on a reactive value. The leading
callable's value is projected as a mini-store and made available to each
`Case`; Cases match the bound value via predicate or literal; the first true
Case's body mounts. Active cases are mounted; inactive cases are destroyed.

```r
Match(state$result,
  Case(\(r) r$success,  \() tags$p("Submitted")),
  Case(\(r) !r$success, \(r) tags$ul(
    Each(r$reasons, \(reason, i) tags$li(\() reason()))
  )),
  Default(\() tags$p("Unknown"))
)
```

- The leading argument is any callable — most commonly an `I()`-leaf, a
  `reactive()`, a `reactiveVal`, a mini-store handed in from outside, or an
  inline choice fn (see below).
- `Case(predicate, body)` — both `predicate` and `body` are independently
  arity-polymorphic, picked by the user based on whether they reference the
  bound value. See the predicate and body forms below.
- `Default(body)` matches when no `Case` does. Sugar for
  `Case(\() TRUE, body)` placed at the position of `Default`. `body` follows
  the same arity rule as Case.

#### Predicate forms

| Predicate | Means |
|---|---|
| `\(v) cond` | Function of the bound value, evaluated reactively |
| `\() cond` | Function ignoring the binding, evaluated reactively (cross-cutting predicate) |
| literal value | Equality match against bound value via `identical` |

The two callable forms are both reactive — any reactive read inside the
predicate (the bound value via `v$field`, an external reactive like
`debug_mode()`, anything) becomes a dependency, and the predicate chain
re-evaluates when any dependency changes. The arity (`\()` vs `\(v)`) is
purely about whether the predicate references the bound value as a parameter,
not whether it is reactive. A literal `Case("dark", ...)` enters the reactive
graph only via the bound value — nothing inside the literal is reactive.

#### Body forms

| Body | Means |
|---|---|
| `\(v) body` | Function of the bound mini-store / leaf accessor |
| `\() body` | Function ignoring the binding |

Bodies are functions, not tag trees, because `Match` uses mount-and-destroy
semantics on case transitions: inactive cases are torn down with their
reactives, and reactivation must construct a fresh instance. There is no tag
tree to remount — the closures it referenced are gone. The function form is
what the runtime calls each time the case activates.

#### Cross-cutting predicates

The `\()` predicate form covers cases that ignore the bound value and
short-circuit on external state — a debug override, an auth check, a feature
flag — alongside record-shape Cases:

```r
Match(state$result,
  Case(\() debug_mode(),  \(r) DebugView(r)),
  Case(\() !auth$ok(),    \() LoginPrompt()),
  Case(\(r) r$success,    \() Submitted()),
  Case(\(r) !r$success,   \(r) ErrorView(r$reasons))
)
```

The first two cases match on reactive reads outside `state$result` and
short-circuit before any record-shape predicate runs. Both `debug_mode()`
and `auth$ok()` become dependencies of the Match — flipping either causes
re-evaluation.

For record dispatch — variants identified by a discriminator field — predicates
are the natural form (they can inspect fields). Literal Cases are occasionally
useful for whole-record presets, but more commonly drive *scalar* dispatch
(see below).

On active-case change, the old case's mini-store and DOM are torn down and
the new case is mounted with a fresh mini-store over the current shape — the
same reconcile mechanism `Each(by = ...)` uses for keyed items, applied to a
single record. Because the case is remounted on transition, the mini-store's
shape is fixed for its lifetime: every field referenced inside a `Case` body
is guaranteed present while that case is active.

### Scalar dispatch

A leading callable that returns a scalar works the same way — bodies receive
the bare leaf accessor instead of a mini-store. With literal Cases, scalar
dispatch reads cleanly:

```r
Match(state$theme,
  Case("dark",  \() DarkUI()),
  Case("light", \() LightUI())
)
```

Bodies are zero-arg here because the literal already selected the variant —
nothing to bind. Predicate Cases work too when the rule is more than equality:

```r
Match(state$score,
  Case(\(s) s >= 90, \() tags$p("A")),
  Case(\(s) s >= 80, \() tags$p("B")),
  Default(\() tags$p("Try again"))
)
```

### Multi-branch over unrelated state — choice fn

Cases dispatch on a *single* bound value, but the bound value can itself be
a synthesized record. Use a choice function as the leading callable to fold
unrelated reactive conditions into a tagged variant on the fly:

```r
Match(\() {
  if (state$loading()) list(tag = "loading")
  else if (state$error() != "") list(tag = "error", error = state$error())
  else list(tag = "data", items = state$data())
},
  Case(\(r) r$tag == "loading", \() Spinner()),
  Case(\(r) r$tag == "error",   \(r) ErrorMsg(r$error)),
  Case(\(r) r$tag == "data",    \(r) ItemList(r$items))
)
```

Two things to note. First, this is the same dispatch-mode machinery — there
is no separate "predicate mode" in `Match`. Second, once you've written the
choice fn you've effectively defined a variant; whenever the synthesized
record is worth keeping as actual state, lift it to an `I()`-leaf and let the
store hold it. The choice-fn pattern is the bridge between unstructured
reactive state and the variant-leaf shape.

A predicate-only mode (a `Match(...Cases)` form without a leading callable)
is intentionally absent — the choice-fn pattern covers it more cleanly. Adding
it later would be a pure additive extension, no breaking change.

---

## `When`

Sugar for binary boolean dispatch. Conceptually a fixed-shape specialization
of `Match`:

```r
When(\() cond, \() yes_tree, \() otherwise_tree)
# ≡ Match(\() cond, Case(TRUE, \() yes_tree), Case(FALSE, \() otherwise_tree))
```

The third argument is optional; with it omitted, nothing mounts when the
condition is `FALSE`.

Bodies are **functions returning tag trees**, not tag trees directly — same
lazy-body rule as `Match` cases. `When` mounts/unmounts the active branch
on transition, so each activation must construct a fresh tag tree (the
previous branch's closures were torn down with its reactives).

`When` has no bound-value projection — the condition is just a reactive
boolean — so bodies are zero-arg only. Reach for `Match` whenever the
branch needs to consume the dispatching value.

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
  validated <- reactiveProxy(
    get = port,
    set = \(v) {
      n <- as.integer(v)
      if (!is.na(n) && n >= 1L && n <= 65535L) port(n)
    }
  )
  tags$input(type = "number", value = validated)
}

# Parent defines "must be above 1024" (policy)
safe_port <- reactiveProxy(
  get = state$port,
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
  if (nchar(state$username()) > 20L)
    state$username(substr(state$username(), 1L, 20L))
})

# GOOD — proxy rejects the write. Invalid state never exists.
validated_username <- reactiveProxy(
  get = state$username,
  set = \(v) if (nchar(v) <= 20L) state$username(v)
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
| Variant-shaped leaf (storage)        | `I()`-wrapped named list at a leaf position       |
| Derived state                        | `reactive()`                                      |
| Two-way DOM binding                  | Auto-bind (`value`, `checked`)                    |
| Write-path control                   | `reactiveProxy`                                   |
| Sync with outside world              | `observe`                                         |
| Discrete user actions                | Event callbacks (`onClick`, `onSubmit`, ...)      |
| Collection iteration (fine-grained)  | `Each` with mini-stores                           |
| Branch iteration (static shape)      | `lapply(branch, fn)` / `imap(branch, fn)`        |
| Predicate / variant dispatch         | `Match` with `Case` / `Default`                   |
| Binary boolean dispatch              | `When` (sugar for two-branch `Match`)            |
| Event timing                         | `.event` (element-level config)                   |

### The common case

A component accepts a callable, auto-bind handles reads and writes. No ceremony:

```r
NameInput <- function(name) {
  tags$input(value = name)
}

NameInput(state$name)
```

### Adding validation at a component boundary

The parent wraps the callable in a proxy. The component is unchanged:

```r
validated_name <- reactiveProxy(
  get = state$name,
  set = \(v) if (nchar(v) <= 100L) state$name(v)
)
NameInput(validated_name)
```

### Adding a bidirectional transform

```r
temp_f <- reactiveProxy(
  get = \() state$temp_c() * 9/5 + 32,
  set = \(f) state$temp_c((f - 32) * 5/9)
)
TemperatureInput(temp_f, label = "Fahrenheit")
```

### Iterating a collection with per-field validation

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  validated_text <- reactiveProxy(
    get = todo$text,
    set = \(v) if (nchar(trimws(v)) > 0) todo$text(v)
  )
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = validated_text)
  )
})
```

### Branch iteration with auto-bind

```r
RenderField <- function(field, key) {
  tags$div(
    tags$label(key),
    tags$input(value = field)
  )
}

ProfileApp <- function() {
  state <- reactiveStore(list(
    name  = "",
    email = ""
  ))

  page_fluid(
    imap(state, RenderField)
  )
}
```

`imap` receives each child node as a callable and its key as a string.
Auto-bind subscribes inside each `tags$input` — the iteration itself is not
reactive. Without purrr, the base R equivalent is
`lapply(names(state), \(k) RenderField(state[[k]], k))`.

### Third-party component interception

```r
constrained <- reactiveProxy(
  get = state$content,
  set = \(v) if (nchar(v) <= 10000) state$content(v)
)
RichTextEditor(constrained)  # can't modify, don't need to
```

---

## Open questions

1. ~~**Callback second argument for keyed `Each`.**~~ Resolved: see
   "Callback arity" — `(item, pos)` with `pos` always a 0-arg reactive
   accessor for the current 1-indexed slot.

2. ~~**Read-only `Each` on derived reactives.**~~ Resolved: wrap in
   `reactiveProxy(get = ..., set = <error>)` before iterating. No separate primitive needed.

3. **Multi-level synthetic setter chain.** When `Each` is nested inside `Each`,
   writes flow through two levels of synthetic setters. Each link uses the same
   one-way mechanism so it should compose, but needs prototype validation.
   Concerns: redundant reconcile passes, performance at three or more levels.

4. ~~**Reactive position accessor.**~~ Resolved: adopt `(item, pos)` with
   `pos` as an always-reactive 0-arg accessor — constant under `by = NULL`,
   live under `by = fn`. See "Callback arity" above.

5. ~~**`Fields` vs `names()` + `lapply` + `[[`.**~~ Resolved: drop `Fields`.
   `Fields` has no reconciliation machinery and no reactive semantics of its
   own — it is not a primitive. With `length.reactiveStore`, integer
   `[[.reactiveStore`, and `names.reactiveStore`, standard R and purrr
   iteration works directly on a branch: `lapply(branch, fn)` for single-arg
   callbacks, `imap(branch, fn)` when the key is also needed. These generics
   are worth supporting for R-idiomatic introspection regardless — the branch
   iteration use case comes for free. `as.list` is intentionally not supported:
   it is ambiguous (values or callables?) and both interpretations are already
   covered (`branch()` for values, `lapply(branch, fn)` for callable iteration).
