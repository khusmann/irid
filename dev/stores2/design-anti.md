# Devil's advocate: against unified callables

**Context:** This is a counterargument to `design.md` §"Why unified
callables instead of value/onChange." It argues for separate
read/write semantics (getter/setter pairs) even in irid's R/Shiny
context.

---

## The argument

### 1. "R closures defeat capability control" is an argument against all API design

Yes, R lets any function capture anything from its enclosing scope.
By that logic, no API boundary matters — you could always just reach
into the parent environment and mutate whatever you want. But we
still design APIs with restricted surfaces because **convention is
enforcement enough in practice.** Nobody reaches into a package's
internal environment even though R lets them. A getter/setter split
at the prop level creates a convention that communicates intent —
"this component should not write" — even if R can't enforce it at
the language level. Convention-as-enforcement is how the entire R
ecosystem works.

### 2. The composability cost is overstated

The `RenderNode` example is the strongest case for unified callables,
but it's also a rare pattern — most apps don't have recursive generic
form renderers. For the common case (a component that takes some state
and renders it), the difference is:

```r
# Unified
MyInput <- function(field) {
  tags$input(value = field)
}

# Separate
MyInput <- function(value, onChange) {
  tags$input(value = value, onInput = \(e) onChange(e$value))
}
```

One extra prop and one extra line. This is not "dramatically
simplified" — it's one line of boilerplate that makes the write path
explicit at every boundary. The explicitness has value: you can read
any component signature and immediately know whether it writes.

### 3. Implicit write capability is a footgun for teams

When you pass a unified callable to a child component, you're
granting write access by default. The child might not even know it
has write access — it just calls `field()` to read, and if someone
later refactors to `field(transformed)` thinking it's a pure
function call, they've introduced a write. With separate
getter/setter, writes require the setter — you can't accidentally
write through a getter.

This matters more as codebases grow and multiple developers touch
the same components. The failure mode isn't "a developer
intentionally circumvents the API" — it's "a developer doesn't
realize they're holding a writable reference."

### 4. Auto-bind's magic detection problem

Open question 2 in the design doc is more serious than it appears.
The element needs to distinguish "this is a unified callable, auto-
bind it" from "this is a plain function that happens to take zero
args." The proposed solutions:

- **(a) Class/attribute on the callable:** Now callables aren't just
  functions — they're tagged objects. This is a hidden type system
  layered on top of R's untyped function model.
- **(b) Tagged callables from reactiveVal/reactiveStore:** Works for
  store-originated state, but what about user-created unified
  callables? Either they need to tag their functions too (leaky
  abstraction) or auto-bind only works with store primitives (magic
  limited to blessed objects).
- **(c) Any function with 0-or-1 args:** False positives everywhere.
  `\() Sys.time()` would auto-bind.

With separate value/onChange, there's no detection problem. `value`
is always a reactive expression (read). `onChange` is always a
callback (write). The types are unambiguous.

### 5. The Solid analogy cuts both ways

The design doc notes that Solid's signal is "fundamentally unified"
and the getter/setter split is just capability passing. But Solid
*chose* to surface that split as its primary API despite having a
unified primitive underneath. The Solid team could have exposed
`signal()` / `signal(value)` — they explicitly didn't. Their
reasoning: making the read/write distinction visible in the API
prevents a class of bugs where developers treat signals as plain
values. If the framework closest to irid's reactive model chose
separate semantics after considering unified ones, that's evidence
worth weighing.

### 6. `onInput` as the write-interception mechanism is weaker than it looks

With unified callables, write interception happens at the element
level via `onInput`. But what about writes that don't come from DOM
events? If component A and component B both hold a reference to the
same unified callable, A can write through it and B has no way to
intercept or even know. With separate getter/setter, the parent
controls who gets the setter — structural interception at the
component boundary, not just at the DOM element.

The design doc says `observe(field, ...)` handles side effects on
state changes regardless of source. True, but observation is
after-the-fact — you can react to a write, but you can't prevent or
validate it before it lands. With a setter function, you can wrap
it: `validated_setter <- \(v) if (is_valid(v)) setter(v)`. The
validation runs before the write, not after.

### 7. "Match the existing reactiveVal idiom" is matching a known weakness

`reactiveVal`'s unified callable API is widely considered one of
Shiny's less ergonomic choices. It's why `reactiveValues` exists as
an alternative — named access (`rv$x`) is clearer than positional
overloading (`rv()` vs `rv(value)`). Extending the `rv()` / `rv(v)`
pattern to the entire store and auto-bind system doubles down on an
idiom that even Shiny's own evolution moved away from.

### 8. The readonly() escape hatch acknowledges the gap

The design doc says:

> "Not a capability-passing / read-only-view system. The earlier
> zeallot destructuring idea remains a separate future direction."

If the anticipated next step is adding `readonly()` wrappers, that's
an admission that unified callables don't fully cover the design
space. Starting with separate read/write and adding a convenience
`bind(getter, setter)` for auto-bind is arguably simpler than
starting unified and retrofitting `readonly()`. The convenience
wrapper is additive; the restriction wrapper is a patch.

---

## What this position recommends

If you took this argument seriously, the API would look like:

```r
# Store nodes expose separate read/write
state$user$name()          # read
state$user$name$set("Bob") # write (or set(state$user$name, "Bob"))

# Auto-bind takes a binding object (or just value + onChange)
tags$input(value = state$user$name, onChange = state$user$name$set)

# Or: a bind() helper that packages getter+setter for auto-bind
tags$input(value = bind(state$user$name))

# Components declare their contract explicitly
MyInput <- function(value, onChange = NULL) {
  tags$input(value = value, onInput = \(e) onChange(e$value))
}

# Read-only by default — no setter, no accidental writes
DisplayField <- function(value) {
  tags$span(\() value())
}
```

The `bind()` helper gives you auto-bind ergonomics without making
every callable implicitly writable. Components that need write access
ask for it explicitly; components that don't, can't accidentally get
it.

---

## Honest assessment of this position's weaknesses

1. **`bind()` is isomorphic to unified callables with extra steps.**
   If most call sites end up writing `bind(field)` anyway, you've
   added a wrapper without changing the semantics.

2. **The `RenderNode` recursive case genuinely suffers.** Threading
   getter/setter pairs through recursive iteration is verbose and
   error-prone. `Fields(node, \(getter, setter, key) ...)` is worse
   than `Fields(node, \(node, key) ...)`.

3. **R's lack of a type system means the "convention as enforcement"
   argument is weaker than in TypeScript/Solid.** There's no compiler
   to catch "you passed a setter where a getter was expected."

4. **The Shiny precedent cuts both ways.** Yes, `reactiveVal`'s
   unified callable is a known weakness — but it's also the idiom
   irid users already know. Breaking from it has a learning cost.

5. **The accidental-write footgun (point 3) may be theoretical.**
   In practice, `field(value)` is visually distinct from `field()`.
   A developer who writes `field(transformed)` probably knows they're
   writing. The more realistic mistake is passing a writable callable
   to a component that shouldn't write — but that's a design-time
   error, not a runtime accident, and code review catches it.
