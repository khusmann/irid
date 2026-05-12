# Plan: switch `reactiveStore` / mini-store from patch to replace

**Status:** Not started. Follow-up to PR #9 (Match/Each redesign).
**Why now:** mini-store and reactiveStore both currently use patch
semantics at branch writes (only specified keys are written, omitted
keys keep their value). That gives two write contracts in the same
codebase — leaves replace, branches patch — and the mini-store has to
do an isolate-and-merge step on every branch write to keep the parent
collection consistent with the projection's read view. Replace-only
gets us one rule everywhere and deletes the merge step.

## The change

**Branch writes replace, not patch.** A branch write must include
every locked key for that branch. Missing keys are an error, same as
unknown keys are today. Per-field writes (`store$key(value)`) remain
the dedicated single-slot path and are unaffected.

Concretely:

```r
state <- reactiveStore(list(user = list(name = "A", email = "B")))

# Today (patch):
state$user(list(name = "X"))          # email kept as "B"

# After (replace):
state$user(list(name = "X"))          # error: missing key "email"
state$user(list(name = "X", email = "B"))  # explicit
state$user$name("X")                  # idiomatic single-slot write
```

Same rule at the root and at every nested branch level.

## What to touch

- `R/store.R` — `make_store`'s write path. Validate that the input's
  key set equals the locked key set (today only checks `unknown`).
  Iterate all keys (today iterates `names(patch)`).
- `R/mini_store.R` — `make_mini_branch_fn`. Delete the
  isolate-children-and-merge step added in commit 199f420. After the
  validator passes, `set_internal(v)` and `set_self(v)` can both
  receive `v` verbatim (it's now guaranteed complete).
- `R/store.R` — `validate_write`. Add the "missing keys" error
  alongside the existing "unknown keys" error. Keep both messages
  pointing at the same path label.
- Docstring on `reactiveStore` ("store nodes patch (only the keys
  present in the patch are updated)") — rewrite to describe replace
  semantics.
- Doc block on `make_mini_store` ("Patches like reactiveStore") —
  update to "Writes replace; missing keys are an error".

## Tests to migrate

The patch-shaped assertions in `tests/testthat/test-store.R` need to
flip to require complete records (or move to per-leaf writes):

- "branch write updates only specified keys" (lines 101–108) — either
  rewrite the test to use `state$user$name("Bob")`, or pass the full
  `list(name = "Bob", email = "B")`. The test name no longer
  describes the behavior.
- "root patch leaves sibling branches untouched" (lines 110–118) —
  the partial root write `state(list(user = list(name = "Eve")))`
  now errors. Replace with `state$user(list(name = "Eve"))` (still
  errors for the same reason — missing `name`'s siblings? no, `user`
  is a one-key branch in this fixture — confirm before changing) or
  rebuild via per-leaf writes.
- "empty patch is a no-op" (lines 120–127) — empty input is now an
  error (missing every key). Decide: keep no-op for `length == 0`, or
  remove the test. Recommendation: remove — empty input is
  meaningless under replace.
- "deep root patch replaces list leaf wholesale" (lines 208–216) — the
  outer write is a partial root patch (only `todos`). Rewrite as
  `state$todos(list(list(id = 9)))`.

Also flip in `tests/testthat/test-mini-store.R`:

- "partial root write patches (omitted keys preserved in parent)"
  (added in 199f420) — now an error case. Rewrite as a
  `expect_error("missing key.*b")` test.
- "nested partial branch write patches the sub-record" — same.
- Reuse the existing "synthetic setter routes through set_record"
  tests to cover the patch-via-leaf idiom.

## Examples / vignettes to audit

`grep -rn "store(list\|state(list" examples/ vignettes/` — any
branch-level partial write needs to migrate. Likely small (most
collection state already lives in a `reactiveVal`, not a store).

Worth re-reading once: the Match/Each redesign relies on mini-store
having the same write contract as reactiveStore. Confirm the body
functions in `examples/each_nested.R`,
`examples/each_heterogeneous.R`, and the `Match` callsites don't
do `item(list(some_key = v))`-style partial writes — they should all
be per-leaf already, but check.

## Open questions

- **Empty input.** Should `store(list())` be a no-op (today) or an
  error (every key missing)? Recommendation: error. "I want to write
  nothing" is not a real use case; "I forgot to include all the
  keys" is.
- **Bulk multi-field updates.** The replace requirement means
  `state$user(list(name = "X", email = "Y"))` is the natural form
  when you genuinely want both. No helper needed.
- **`modifyList`-style ergonomics.** If a callsite legitimately wants
  "patch over current", the idiom is
  `state$user(modifyList(state$user(), list(name = "X")))`. Verbose
  but explicit, and rare in practice.

## Sequencing

Land as one PR after #9 merges. The change is largely mechanical once
the validator rule changes — most of the diff is test rewrites and
doc updates.
