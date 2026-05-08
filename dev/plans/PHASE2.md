# Phase 2 — Store introspection generics

Spec: [`dev/reactive-system/final-design.md`](../reactive-system/final-design.md),
section "R-idiomatic store methods".

Depends on Phase 1.

## Goal

Make a `reactiveBranch` feel like a regular named list for introspection
and iteration: `names()`, `length()`, `print()`, `str()`, and `[[` (with
both string and integer indexing). This unlocks branch iteration via base
R and purrr — `lapply(branch, fn)` and `imap(branch, fn)` — without adding
a separate primitive.

The callback receives **child node callables** (not resolved values), so
auto-bind continues to work unchanged when the user passes the callable
through to a tag attribute.

## Out of scope

- `as.list.reactiveBranch` — intentionally not supported (ambiguous: values
  or callables?). Add an explicit method that errors with a hint pointing
  at `branch()` (values) or `lapply(branch, identity)` (callables).
- `[[<-` assignment — branches are not directly mutable. Writes go through
  the callable. Add a `[[<-.reactiveBranch` that errors with a hint to use
  `branch$key(value)` or `branch(list(key = value))`.
- Iteration on atomic-list leaves (`Each`'s job, Phase 6).
- Generics on leaves beyond `print` (no `length`/`names`/`[[` — leaves are
  opaque scalars or atomic lists).

## Implementation

All in `R/store.R`. S3 methods on `reactiveBranch` (root and intermediate
branches; root carries both `reactiveStore` and `reactiveBranch`).

### `names.reactiveBranch(x)`

Return the static `keys` vector. Not reactive — branch shape is fixed at
construction.

### `length.reactiveBranch(x)`

`length(keys)`. Not reactive.

### `[[.reactiveBranch(x, i)`

Return the child node (callable). Supports:

- String: `branch[["name"]]` — equivalent to `branch$name`.
- Integer: `branch[[1L]]` — `children[[keys[i]]]`. Out-of-range errors.

Returning the callable (not the resolved value) is the contract that lets
`lapply`/`imap` produce something usable inside reactive bindings.

No reactive dependency is created by `[[`; the dependency is created when
the returned callable is invoked.

### `[[<-.reactiveBranch(x, i, value)`

Errors with a hint: use `branch$key(value)` or `branch(list(key = value))`.

### `as.list.reactiveBranch(x, ...)`

Errors with a hint: use `branch()` for values or `lapply(branch, identity)`
for callables.

### `print.reactiveBranch(x, ...)` / `print.reactiveLeaf(x, ...)`

Concise headers. Branch: `<reactiveStore branch> [N children: a, b, c]`.
Leaf: `<reactiveStore leaf> = <isolate-read of current value, abbreviated>`.
Keep output one-or-two lines; `str` is for full structure.

### `str.reactiveBranch(x, ...)`

Recursive — show keys and recurse into children. For leaves, show the
current value (read inside `isolate`). Cap depth via the standard
`utils::str` `max.level` arg.

### `format.reactiveBranch` (optional)

Useful if `print` delegates. Decide during implementation.

## Tests — `tests/testthat/test-store-generics.R`

### `names` / `length`

- `names(state)` returns top-level keys in construction order.
- `length(state)` matches.
- `names(state$user)` returns the user's keys.
- An `observe` that reads only `length(state)` does **not** fire when leaf
  values change (no reactive dependency on shape).

### `[[`

- `state[["user"]]` returns the user branch; `identical(state[["user"]], state$user)`.
- `state[[1L]]` returns the first child; matches `state[[names(state)[1]]]`.
- `state[[1.0]]` (numeric) coerces to integer and works.
- Out-of-range integer (`state[[99L]]`) errors.
- Unknown string (`state[["nope"]]`) errors or returns `NULL` — pick one
  consistent with the spec ("Unknown key" error preferred for symmetry
  with branch writes).
- A reactive leaf access via `[[` returns the leaf callable, not its value:
  `state$user[["name"]]` is a function, and calling it inside `isolate`
  produces `"A"`.

### `[[<-` and `as.list`

- `state$user[["name"]] <- "X"` errors with the hint about `branch$key(value)`.
- `as.list(state$user)` errors with the hint about `branch()` /
  `lapply(branch, identity)`.

### Iteration

- `lapply(state$user, identity)` returns a named list of callables matching
  `names(state$user)`. Each entry is identical to the corresponding `$`
  child (`identical(out$name, state$user$name)`).
- `lapply(state$user, \(f) isolate(f()))` produces the values list, equal
  to `isolate(state$user())`.
- `purrr::imap(state$user, fn)` (with `skip_if_not_installed("purrr")`)
  invokes `fn(field, key)` with `field` a callable and `key` a string.

### Reactivity inside iteration

- `lapply(state, fn)` where `fn` reads `field()` inside an `observe`
  subscribes only to the leaves actually touched. Verify with an observer
  that reads only `state$user$name()` via the iterated callable: writing
  `state$user$email("X")` does not fire it.

### Print / str (smoke tests)

- `capture.output(print(state))` is non-empty and contains every top-level
  key.
- `capture.output(str(state))` is non-empty and contains nested keys.
- These do not error on atomic-list leaves.

### Atomic-list leaves

- `state$todos[[1]]` errors (no iteration on leaves at this level — that
  is `Each`'s job). Test the error message points to `Each` or to
  `state$todos()[[1]]`.
- `length(state$todos)` and `names(state$todos)` either error or return
  the leaf-level (single) values — pick one and lock it down.

## Order of work

1. `names` and `length` plus tests (smallest, no surprises).
2. `[[` (string + integer) plus tests, including `lapply` round-trip.
3. `[[<-` and `as.list` errors plus tests.
4. `print` and `str` plus smoke tests.
5. Iteration / reactivity tests (depend on all of the above being in place).
6. `devtools::document()` if any roxygen exports change. Most generics are
   internal S3 methods; only `reactiveStore` itself needs to be exported.
