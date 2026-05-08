# Phase 1 — `reactiveStore` core

Spec: [`dev/reactive-system/final-design.md`](../reactive-system/final-design.md), section "`reactiveStore`".

## Goal

A callable hierarchical state container. Standalone — does not depend on
`process_tags` / `mount` / `irid.js`. A `reactiveStore` leaf is already a
callable, so it slots into the existing reactive-binding pipeline without
modification.

## Out of scope (later phases)

- `names()` / `length()` / `print()` / `str()` / `[[` — Phase 2.
- `reactiveProxy` — Phase 3.
- Auto-bind for `value` / `checked` / `selected` — Phase 4.
- Mini-stores in `Each` — Phase 6.
- Full updates to `ARCHITECTURE.md` and `TESTING.md` — Phases 8/9. Phase 1
  adds only a one-line File-Layout entry so the new file is not orphaned.

## Implementation

New file `R/store.R` exporting `reactiveStore()`. No changes to
`process_tags.R`, `mount.R`, or `inst/js/irid.js`.

### Constructor

`reactiveStore(initial)` walks `initial` and builds nodes bottom-up:

| Input shape                       | Node                              |
|-----------------------------------|-----------------------------------|
| Named list                        | branch — recurse into children    |
| Unnamed list at any position      | atomic leaf (single `reactiveVal` holding the whole list) |
| Anything else (scalar, vector, NULL, atomic vector) | leaf — single `reactiveVal` |
| `list()` (empty named list)       | degenerate branch with no children — accepted |

### Node shapes

**Leaf** — closure over a `reactiveVal` `rv`:

```r
function(...) if (missing(..1)) rv() else rv(..1)
```

`missing(..1)` (not `nargs() == 0`) distinguishes read from write so that
`node(NULL)` is a write of `NULL`, not a read.

**Branch** — closure over a named list `children` and a fixed `keys` vector:

- **Read** (`node()`): `setNames(lapply(keys, \(k) children[[k]]()), keys)`.
  Each child call subscribes at the leaves it touches; branches own no
  `reactiveVal` and create no extra subscription.
- **Write** (`node(patch)`): validate `is.list(patch)` and `names(patch)`
  against `keys`; on unknown names, `stop("Unknown keys in store node
  '<path>': <keys>", call. = FALSE)`; iterate `names(patch)` and call
  `children[[k]](patch[[k]])`. Recurses naturally — a child branch validates
  its own patch.

### `$` accessor

`$.reactiveBranch` returns the child node (callable). Children are stored
once at construction and reused, so `state$user$name` is identity-stable
across calls — `node <- state$user$name` keeps working after branch writes.

### Class tags

- Root and intermediate branches both class `c("reactiveBranch")`. Root
  additionally carries `"reactiveStore"` so it can be detected when needed.
  Phase 2 generics dispatch on `reactiveBranch` and apply uniformly.
- Leaves (scalar and atomic-list alike) carry `"reactiveLeaf"`. The
  underlying value being a list is data, not class.

### Path tracking

Pass a `path` argument through the constructor recursion (root: `""`;
children: `paste0(parent_path, if (nzchar(parent_path)) "$", key)`). Embed
in the closure so unknown-key errors name the offending node
(`'user'`, `'user$address'`).

### Synchronous fan-out

Branch writes call each child's write synchronously. Shiny's reactive
system batches invalidations; downstream observers run on the next flush.
This satisfies the spec's "all leaf writes complete before any observer
runs." No additional buffering needed.

## Bootstrapping testthat

`tests/` does not yet exist.

1. `usethis::use_testthat(3)` — creates `tests/testthat.R`, `tests/testthat/`,
   adds `testthat (>= 3.0.0)` to `Suggests` and `Config/testthat/edition: 3`
   to `DESCRIPTION`.
2. One trivial passing test in `tests/testthat/test-store.R` to confirm the
   harness runs (`expect_true(TRUE)`), removed once real tests land.

## Tests — `tests/testthat/test-store.R`

Use `test_that()`. Wrap reactive reads in `shiny::isolate()`. For
observer-driven tests, use `shiny::testServer()` or a `reactiveConsole(TRUE)`
+ `flushReact()` harness — pick whichever proves simpler against the existing
`Imports: shiny`.

### Construction & shape

- Scalar leaf: `state <- reactiveStore(list(x = 1)); isolate(state$x())` is `1`.
- Nested branch: `list(user = list(name = "A"))` → `state$user$name()` is `"A"`.
- Atomic list (unnamed): `list(todos = list(list(id = 1), list(id = 2)))` →
  `state$todos()` returns the original unnamed list, **not** recursed.
- Empty branch: `reactiveStore(list(group = list()))`; `state$group()` is `list()`.
- Mixed types at one level: `list(a = 1, b = "s", c = list(x = 1))` works.

### Leaf read/write

- `state$x(2); isolate(state$x())` is `2`.
- Writing `NULL`: `state$x(NULL); isolate(state$x())` is `NULL`. Verifies
  the `missing(..1)` read/write distinction.
- Type changes accepted: `state$user$name(42)` succeeds (no type enforcement
  per spec).

### Branch read assembles from children

- `isolate(state$user())` is `list(name = "A", email = "B")` after both leaves
  are populated.
- Root: `isolate(state())` returns the full nested list with the same shape
  as the constructor input.

### Branch write patches

- `state$user(list(name = "Bob"))` updates `name` only; `email` unchanged.
- `state(list(user = list(name = "Eve")))` from root patches deeply; sibling
  branches (e.g. `todos`) untouched.
- Empty patch `state$user(list())` is a no-op (no leaves fired).

### Unknown-key validation

- `state$user(list(name = "B", phone = "x"))` errors. Message contains the
  path `'user'` and the offending key `'phone'`.
- Root unknown: `state(list(unknown = 1))` errors with the root path.
- Non-list patch: `state$user("hello")` errors with a clear message
  ("expected a named list" or similar).

### Atomic list semantics

- `state$todos(new_list)` replaces the entire list.
- No `$` traversal into items: `state$todos$id` returns `NULL` (whatever
  falls out of `$.reactiveLeaf` — pick one and lock it down with a test).
- Deep `state(list(todos = ...))` patch replaces `todos` wholesale, even
  though the new value is a list.

### Identity stability

- `identical(state$user$name, state$user$name)` is `TRUE`.
- After `state$user(list(name = "X"))`, the previously-captured
  `node <- state$user$name` still reads/writes the same leaf.

### Reactive granularity

- An `observe` reading `state$user$name()` fires when
  `state$user$name("X")` runs, but **not** when `state$user$email("Y")` runs.
- An `observe` reading `state$user()` fires on either leaf change.
- An `observe` reading `state()` fires on any leaf change anywhere.
- A branch write that patches multiple leaves
  (`state$user(list(name = "X", email = "Y"))`) results in a **single**
  flush — observers run once even though two leaves changed. Verify by
  counting observer invocations.

### Path in error messages

- `state$user$address(list(street = "x", zip = "y"))` where `address` only
  has `street` errors with `'user$address'` in the message.

## Order of work

1. `use_testthat(3)` plus a trivial passing test, to confirm harness.
2. `R/store.R` with leaf + scalar branch only (no atomic list, no path
   tracking) and the corresponding subset of tests.
3. Add atomic-list handling and its tests.
4. Add path-tracking error messages and their tests.
5. Add reactive-granularity tests (most harness setup; doing them last
   avoids blocking on `testServer` plumbing).
6. `devtools::document()` to update `NAMESPACE`.
7. Add one line to `ARCHITECTURE.md` File Layout: `R/store.R — reactiveStore`.
