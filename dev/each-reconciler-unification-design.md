# Each reconciler unification — design

**Status:** Implemented. The two planners (`plan_reconcile_keyed` /
`plan_reconcile_positional`) are now a single `plan_reconcile` run by a
mode-agnostic `run_reconcile_plan` executor in `R/mount.R`; tests in
`tests/testthat/test-each.R`.
**Date:** June 2026

---

## 1. Motivation

`Each` reconciles two renders of a reactive list into a DOM mutation. It
runs in two modes that today have **two separate planners and two separate
effect paths** in the `Each` observer in `R/mount.R`:

- **Keyed** (`by = \(x) x$id`): items tracked by key across reorders,
  adds, removes.
- **Positional** (`by = NULL`): slot *i* is slot *i*; the list grows/shrinks
  at the tail and in-place values update through slot accessors.

The decision logic was already factored into pure planners. What remains
duplicated is the **execution**: teardown → build → `sendCustomMessage` →
mount, written twice with mode-specific bookkeeping. This doc asks whether
both planners can emit a **single plan type** run by a **single executor**.

The answer is yes, and it rests on one insight.

## 2. The core insight

> **Positional `Each` is keyed `Each` whose id is the row position.**

If the per-slot identity is a stable string id — the key for keyed mode,
`as.character(index)` for positional mode — then *every* mode difference is
either (a) absent because the ids never collide/reorder, or (b) derivable
from the id sequences. Concretely, with `old_ids` / `new_ids`:

| difference (today) | collapses to |
|---|---|
| keyed sparse `[[key]] <- NULL` vs positional tail-truncation | one map: remove by id (trim *is* "remove tail ids") |
| `noop`: keyed `identical(keys)` vs positional `same length` | `identical(new_ids, old_ids)` (same for positional, since `new_ids = 1..n`) |
| duplicate-key check (keyed only) | `anyDuplicated(new_ids)` — never fires for positional ids |
| kept reposition (keyed only) | reposition kept ids whose position changed — positional positions never change, so it no-ops |
| shape-change rebuild | remove+add of the same id, identical in both modes |
| `order` always (keyed) vs conditional (positional) | **derived** — see §4 |

So the mode knowledge concentrates into one pure planner; the executor
becomes mode-agnostic.

## 3. The unified plan type

```r
plan_reconcile(old_ids, new_ids, old_sigs, new_sigs) -> list(
  noop           = <lgl>,                    # no DOM work
  has_duplicates = <lgl>,                    # caller raises (keyed only in practice)
  removed        = <chr>,                    # ids to tear down (set-diff ++ shape-changed)
  added          = <chr>,                    # ids to build   (set-diff ++ shape-changed)
  kept           = <chr>,                    # surviving, only-moved ids (new order)
  order          = <chr|NULL>,               # full display sequence, or NULL to skip
  build_index    = stats::setNames(<int>, added)  # position of each added id in new_ids
)
```

`old_sigs` / `new_sigs` are shape signatures (`shape_signature()`) named by
id. `build_index[[id]]` is the slot position passed to `build_entry`, and
the source item is `item_list[[build_index[[id]]]]` (the planner needs only
the indices; the executor holds `item_list`).

`kept` may also carry the new position for reposition (`new pos = match(id,
new_ids)`), computed by the executor from `new_ids` to keep the plan minimal.

## 4. The `order` policy — derived from the client contract (the crux)

This was the open risk. Reading the `irid-mutate` handler in
`inst/js/irid.js` settles it:

1. **`removes`** detach ranges by id — order-independent.
2. **`inserts`** are parsed and appended **at the container tail** (before
   the end anchor), in the order given.
3. **`order`**, when present, lifts each listed child to the tail in
   sequence — so a *full* `order` list yields the correct final sequence.

Therefore the client, given only `removes` + `inserts`, produces this DOM
order:

```
natural_order = (old_ids without `removed`, in old order) ++ (added, in insert order)
```

`order` is required **exactly when** that differs from the desired order:

```r
order_needed <- !identical(new_ids, natural_order)
order        <- if (order_needed) new_ids else NULL
```

This single rule **derives both modes' current behavior** — no mode flag:

- **Positional append** (1,2,3 → 1,2,3,4): `natural = [1,2,3] ++ [4] =
  [1,2,3,4] = new_ids` → no `order`. (Matches today.)
- **Positional mid-list shape rebuild** (rebuild slot 2 of 3):
  `removed={2}`, `added={2}`, `natural = [1,3] ++ [2] = [1,3,2] ≠ [1,2,3]`
  → `order` sent. (Matches today's `shape_changed` rule — now *derived*.)
- **Keyed reorder** (a,b,c → c,a,b): `natural = [a,b,c] ≠ [c,a,b]` →
  `order` sent. (Matches keyed "always".)
- **Keyed tail append, no reorder** (a,b,c → a,b,c,d): `natural =
  [a,b,c,d] = new_ids` → `order` *omitted*. This is a **payload
  improvement** over today's keyed (which always sends `order`), and it is
  client-correct because the insert lands at the tail where it belongs.

**No client change is required** — the existing contract already supports
the unified model. (The keyed tail-append optimization is a free, correct
side effect; if we want to be conservative we can keep "always send order
when not noop," at a small positional-append payload cost. Recommend the
derived rule.)

## 5. The unified executor

Mode-agnostic. Operates on a single container `env$item_mounts` (named map
by id) and `env$current_ids` (ordered id vector):

```r
run_reconcile_plan <- function(plan, item_list, env, build_entry,
                                teardown_entry, session, cf_id, depth) {
  if (plan$noop) return(invisible())
  if (plan$has_duplicates) cli::cli_abort("...unique keys...")

  removes <- character(0)
  for (id in plan$removed) {
    teardown_entry(env$item_mounts[[id]])
    removes <- c(removes, env$item_mounts[[id]]$wrapper_id)
    env$item_mounts[[id]] <- NULL
  }

  inserts <- list()
  for (id in plan$added) {
    slot <- plan$build_index[[id]]
    entry <- build_entry(id, slot, item_list[[slot]])
    inserts[[length(inserts) + 1L]] <- as.character(entry$processed$tag)
    env$item_mounts[[id]] <- entry
  }

  msg <- list(id = cf_id)
  if (length(removes) > 0L) msg$removes <- as.list(removes)
  if (length(inserts) > 0L) msg$inserts <- inserts
  if (!is.null(plan$order)) {
    msg$order <- as.list(vapply(
      plan$order, function(id) env$item_mounts[[id]]$wrapper_id,
      character(1L)
    ))
  }
  session$sendCustomMessage("irid-mutate", msg)

  for (id in plan$added) {                       # mount after DOM exists
    entry <- env$item_mounts[[id]]
    entry$mount <- irid_mount_processed(entry$processed, session, depth = depth + 1L)
    entry$processed <- NULL
    env$item_mounts[[id]] <- entry
  }

  for (id in plan$kept) {                         # live position (keyed only in effect)
    entry <- env$item_mounts[[id]]
    if (!is.null(entry$pos_rv)) entry$pos_rv(match(id, plan$order %||% new_ids))
  }

  env$current_ids <- new_ids
}
```

The `pos_rv` guard makes the kept-reposition a no-op for positional entries
(which have `pos_rv = NULL`); equivalently, positional `kept` ids never
change position, so the planner can simply emit no repositions for them.

## 6. What stays mode-specific (and why)

`build_entry` (`R/mount.R`) builds **genuinely different entries** per mode,
and this is *not* duplication — it is the identity model itself:

- **Keyed**: value access is **late-bound by key** — `current_index()`
  re-resolves the key against the live list on every read/write, so an
  item's accessor follows it across reorders. `pos_rv` is a live
  `reactiveVal`.
- **Positional**: value access is **early-bound to a captured index** `ii`
  (`cf_items()[[ii]]`); cheaper, valid because positional slots never
  permute. `pos_accessor` is a constant; no `pos_rv`.

`build_entry` already branches on `keyed`, and it should **keep** doing so.
The executor stays oblivious: it calls `build_entry(id, slot, item)` and the
branch inside handles value-access/position. Forcing positional onto
late-binding would regress value-access perf (a full key scan per read) for
no benefit. **Unify the reconciliation; keep entry construction
mode-aware.**

## 7. Container & state representation changes

- `env$item_mounts`: today a sparse named map (keyed) **or** a dense
  positional list (positional). Unify to **always a named map by string
  id**. Positional ids are `as.character(seq_len(n))`, always dense
  `"1".."n"` (positional only grows/trims at the tail and rebuilds in
  place), so the map stays equivalent to the old list.
- `env$current_keys` → `env$current_ids` (ordered id vector). Initial state
  `character(0)` (unchanged shape). Needed because a named map's insertion
  order does not track display order after sparse removals — the ordered
  vector is the source of truth for sequence and for next-render `old_ids`.
- Next-render inputs derive uniformly:
  `old_ids <- env$current_ids`,
  `old_sigs <- setNames(lapply(old_ids, \(id) item_mounts[[id]]$shape_sig), old_ids)`.

Observer top, per mode, only differs in how `new_ids` is produced:
`new_ids <- vapply(item_list, \(x) as.character(cf_by(x)), "")` (keyed) vs
`new_ids <- as.character(seq_along(item_list))` (positional). Everything
after is shared.

## 8. Edge cases / correctness checklist

- **Initial render**: `old_ids = character(0)` → everything `added`,
  `natural_order = added = new_ids` → no `order` for keyed-at-mount too
  (today keyed sends it; harmless to omit). ✓
- **Pure value change**: `new_ids == old_ids`, no sig change → `noop`. ✓
- **Duplicate keys**: `anyDuplicated(new_ids)` → raise. Positional ids never
  collide. ✓ (Compute `has_duplicates` *before* shape work, raise *after*
  the `noop` short-circuit — matches current ordering.)
- **Shape rebuild = remove+add of same id**: container does
  `[[id]] <- NULL` then `[[id]] <- entry`; `natural_order` places the rebuild
  at the tail → `order` sent. ✓
- **`build_index` for keyed**: `match(id, new_ids)` — the slot position seeds
  `pos_rv` and indexes `item_list`. ✓
- **Reposition only on change**: positional kept ids keep their position →
  no `pos_rv` writes; the `pos_rv = NULL` guard is belt-and-suspenders. ✓

## 9. Risks

1. **It is the framework's most delicate code.** Mitigation: the
   `test-each.R` mount-based integration tests assert `removes` / `inserts`
   / `order` *counts* across grow / trim / reorder / shape-change / mixed —
   a strong guardrail. Keep them green throughout.
2. **Container representation change** (dense list → named map) for
   positional ripples into `old_len`/`old_sigs` computation. Contained: both
   now derive from `current_ids`.
3. **Keyed `order` omission on tail-appends** is a behavior change (smaller
   payloads). Believed correct from the client contract (§4) but is the one
   thing to validate live. Fallback: "always send order when not noop"
   keeps keyed byte-identical at a tiny positional cost.
4. **`pos_rv` on positional**: must not be written (it is `NULL`). Guarded.

## 10. Migration & testing

1. Replace the two planners with one `plan_reconcile(old_ids, new_ids,
   old_sigs, new_sigs)`. Port the existing planner unit tests to ids; add
   tests for the derived `order` rule (append-no-order, reorder-order,
   mid-rebuild-order, keyed-tail-append-no-order).
2. Introduce `run_reconcile_plan()` and switch both observer branches to:
   compute `new_ids` → `plan_reconcile()` → `run_reconcile_plan()`. The
   `keyed`/positional fork shrinks to just the `new_ids` line.
3. Unify the container to a named map + `current_ids`.
4. Keep `build_entry` mode-aware (its `keyed` branch is unchanged).
5. Gate on the full `test-each.R` suite; spot-check a focused-input reorder
   in the browser (the `order`-on-reorder path is what preserves focus).

## 11. Recommendation

Do it — it is the *right* model: it removes a real fork, derives the
`order` policy from first principles instead of hard-coding it per mode, and
expresses positional as the degenerate case of keyed that it actually is. It
needs no client/wire change. Scope it as its own branch/PR with the
integration tests as the guardrail, and treat the keyed tail-append `order`
omission (§9.3) as the one item to confirm in the browser before merging.

The line that stays forked — `build_entry`'s late-bound-key vs
captured-index value access — *should* stay forked; that fork is the
identity model, not incidental duplication.

## 12. Should the client change to make this cleaner?

Considered, because the wire allowance was open. Conclusion: **keep the
client as-is for the unification, and treat reorder efficiency as a
separate, client-only optimization.**

**Cleanliness — no.** The current `irid-mutate` contract is *declarative
ordering*: the server sends the full desired `order` plus dumb
`removes` / tail-`inserts`, and the client makes the DOM match. That is
exactly what keeps the unified server model clean — the planner derives
`order_needed` in one line (§4) and emits `new_ids`. A position-aware
protocol (`insert-before-X`, `move-before-Y`) would *move* complexity onto
the server (computing insertion anchors and minimal move sets) to make the
client dumber — a trade, not a simplification, and added risk on the most
delicate path. So the unification needs no protocol change.

**Performance — a real, separable issue.** `order` is applied by lifting
*every* listed child to the tail in sequence:

```js
msg.order.forEach(function (childId) { /* lift child range, insertBefore(frag, end) */ });
```

So a reorder that moves one item still does **O(n) DOM moves**. The clean
fix needs **no protocol or server change**: the client already has the full
target `order` and the current child sequence, so it can move only
out-of-place ranges (the keyed-reconciler / longest-increasing-subsequence
trick), giving O(moved) reorders while preserving the declarative contract.

**Recommendation:** do the unification against the current client. Track the
client-only minimal-`order`-apply optimization as a separate item, gated on
whether large reorderable lists are a real use case — it is safely shippable
on its own and must not be coupled to this change.
