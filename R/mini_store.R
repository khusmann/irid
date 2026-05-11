#' Mini-store projection over a record
#'
#' Builds a `reactiveStore`-shaped callable tree that projects a single
#' record out of a parent collection. Reads route through `get_record()`;
#' writes (whole-record or per-field synthetic setters) route through
#' `set_record()`. The mini-store never owns the record's state — the
#' parent collection is the single source of truth.
#'
#' Used by `Each` (record items) and `Match` (record bound value) to
#' project fine-grained leaf reactivity out of a coarse-grained parent.
#'
#' Recursive — nested named lists in the initial record become sub-mini-stores
#' (so `mini$user$name(v)` writes through the same chain as
#' `mini$user(<patched-user>)` would).
#' Each level threads a sub-`get`/`set` pair down the tree; writes at any
#' depth fan out through the chain of synthetic setters until they reach
#' the user-supplied `set_record`. Shape uses the same shared
#' branch-vs-leaf rules as [reactiveStore()] (`is_branch`, `is_bare_list`,
#' `strip_asis` are reused), and the same recursive [validate_write()]
#' enforces "no unknown keys" at every level on whole-record writes.
#'
#' **Shape is strict.** Writes are validated against the keys captured
#' at construction — same contract as a [reactiveStore()] branch.
#' Callers that need to change a slot's shape reshape the *parent
#' collection* directly (e.g. for `Each(items, ...)`, write the new
#' `items()` with the slot already replaced); the outer reconciler
#' observes the parent change and rebuilds this mini-store with a
#' fresh leaf tree of the new shape on the same flush.
#'
#' **Replace, not patch.** Unlike [reactiveStore()] branch writes,
#' mini-store branch writes pass the value verbatim to `set_record`
#' (and, for sub-branches, replace the slot via `[[<-` in the parent's
#' synthetic setter chain). A partial branch write *drops* the omitted
#' fields from the parent record — `mini$user(list(name = "X"))` on a
#' `user = list(name, email)` subrecord makes the parent's `user`
#' become `list(name = "X")`. Callers wanting patch semantics must use
#' per-field synthetic setters (`mini$user$name("X")`) or merge before
#' writing. The asymmetry exists because the mini-store is a
#' projection: it never owns the record, so it has no business
#' deciding how to merge a partial write into the source of truth.
#'
#' Internally, every leaf holds a `reactiveVal` kept in sync with the
#' parent by a single root-level propagating observer. The observer
#' walks the tree top-down via each branch's internal `set_internal`,
#' which recurses to children's `set_internal`; only at leaves does an
#' actual `reactiveVal` write occur, gated by `identical(old, new)`.
#' This is what delivers the "only changed fields fire" promise — the
#' diff happens inside the projection rather than at the call site, so
#' callers can't get it wrong.
#'
#' @param get_record A 0-arg reactive callable that returns the current
#'   record (a fully named list).
#' @param set_record A 1-arg function called with the new record on
#'   whole-record write or after a per-field synthetic setter has built
#'   the patched record.
#' @param scope A scope from [make_scope()]. The propagating observer is
#'   created against `scope$session` and registered for cleanup so
#'   `scope$destroy()` tears it down.
#' @return A callable with class `c("reactiveStore", "reactive", "function")`,
#'   shaped like a `reactiveStore` branch — `mini()` reads the record,
#'   `mini(record)` writes it, `mini$field()` reads a leaf or sub-branch,
#'   and `mini$field(v)` writes through the parent.
#' @keywords internal
make_mini_store <- function(get_record, set_record, scope) {
  initial <- shiny::isolate(get_record())
  # Permissive check first — `is_branch` errors on partially-named
  # lists with a store-construction message that's misleading when the
  # caller is `Each` / `Match`. `is_record` returns FALSE for both
  # unnamed and partial-named, so we can issue the mini-store-specific
  # message before `build_mini_node` calls `is_branch` internally.
  if (!is_record(initial)) {
    stop(
      "make_mini_store: initial record must be a fully named list",
      call. = FALSE
    )
  }

  node <- build_mini_node(
    initial = initial,
    get_self = get_record,
    set_self = set_record,
    scope = scope,
    path = ""
  )

  # Single root-level propagator — pushes parent changes down through
  # the tree via `set_internal`. Only leaves whose value actually
  # changed fire their observers (each leaf's `set_internal` short-
  # circuits on `identical`). One observer rather than one-per-leaf
  # so deep trees don't fan out the dependency on `get_record()`.
  #
  # Permissive `is_record` guard (not `is_branch`): if the parent's
  # value transiently isn't a record (shape change to a scalar, or a
  # malformed list with missing names), we silently skip rather than
  # crash inside the observer. The outer `Each` / `Match` reconciler
  # owns shape transitions and will tear this mini-store down on the
  # same flush; we just need to not blow up before it gets there.
  obs <- shiny::observe({
    new_record <- get_record()
    if (is_record(new_record)) {
      node$set_internal(new_record)
    }
  }, domain = scope$session)
  scope$register_observer(obs)

  node$fn
}

# Recursive constructor for a mini-store node. Returns a list with:
#   - fn:           the user-facing callable (reactiveStore-classed for
#                   branches, reactiveProxy-classed for leaves)
#   - set_internal: pushes a value into the node's internal state
#                   without going through `set_self`. Branches recurse
#                   into children; leaves write to their `reactiveVal`
#                   only if the value actually changed.
#
# `get_self` / `set_self` are the chained projections of the parent's
# get/set, narrowed to this node's slice of the record.
build_mini_node <- function(initial, get_self, set_self, scope, path) {
  if (is_branch(initial, path)) {
    keys <- names(initial)

    child_nodes <- stats::setNames(
      lapply(keys, function(k) {
        force(k)
        # Sub-projection — narrow get/set to this child's slice. `isolate`
        # so the synthetic setter never subscribes to the parent record.
        # `[[<-` rather than `modifyList` because `modifyList` recurses
        # into matching list-shaped values (replacing a length-2 list
        # with a length-3 list silently keeps the original two entries).
        sub_get <- function() get_self()[[k]]
        sub_set <- function(v) {
          patched <- shiny::isolate(get_self())
          patched[[k]] <- v
          set_self(patched)
        }
        child_path <- if (nzchar(path)) paste0(path, "$", k) else k
        build_mini_node(initial[[k]], sub_get, sub_set, scope, child_path)
      }),
      keys
    )

    set_internal <- function(record) {
      for (k in keys) {
        if (k %in% names(record)) {
          child_nodes[[k]]$set_internal(record[[k]])
        }
      }
      invisible()
    }

    fn_children <- stats::setNames(
      lapply(keys, function(k) child_nodes[[k]]$fn),
      keys
    )
    fn <- make_mini_branch_fn(
      fn_children, keys, path, set_self, set_internal
    )

    list(fn = fn, set_internal = set_internal)

  } else {
    rv <- shiny::reactiveVal(strip_asis(initial))

    set_internal <- function(v) {
      old_v <- shiny::isolate(rv())
      if (!identical(old_v, v)) rv(v)
      invisible()
    }

    # User-write path: update the local `rv` synchronously *and* chain
    # the write up through `set_self`. Without the synchronous local
    # write, the event observer's force-send echo (which runs before
    # the next flush propagates the parent change back down) reads the
    # stale `rv` and sends the OLD value to the client tagged with the
    # current sequence — the client treats it as a server transform and
    # overwrites the user's typed value. The propagator that fires on
    # the next flush short-circuits via `identical()` and doesn't
    # re-invalidate.
    fn <- reactiveProxy(
      get = function() rv(),
      set = function(v) {
        if (!identical(shiny::isolate(rv()), v)) rv(v)
        set_self(v)
      }
    )

    list(fn = fn, set_internal = set_internal)
  }
}

# Builds a `reactiveStore`-classed branch callable. Reads recursively
# call each child's `fn` (subscribing to all descendant leaves); writes
# validate against the locked shape and route through `set_self`.
# Factored out of `build_mini_node` so the closure environment cleanly
# binds `children` (the named list of child callables) to `fn_children`
# — this matches `make_store`'s shape so [validate_write()] and
# `$.reactiveStore` work uniformly across both store kinds.
#
# Writes are shape-strict — the same contract as `reactiveStore`
# branches. Both classes carry the same `reactiveStore` class, so a
# component receiving "a store-like thing" sees one write contract
# regardless of whether it's a real store or a per-item projection.
# Shape transitions are reshaping operations on the *parent
# collection*, not on the projection — callers express them by
# writing the new collection through `items` (or, for Match, the
# leading callable). The outer reconciler observes the parent change
# and rebuilds this entry with a fresh mini-store of the new shape.
make_mini_branch_fn <- function(children, keys, path, set_self, set_internal) {
  label <- if (nzchar(path)) sprintf("'%s'", path) else "mini-store"
  fn <- function(...) {
    if (missing(..1)) {
      stats::setNames(lapply(keys, function(k) children[[k]]()), keys)
    } else {
      v <- ..1
      validate_write(fn, v)
      # Push the record into descendant leaves' local `rv`s synchronously
      # (set_internal recurses; only changed leaves invalidate). Then
      # chain the write up through `set_self` so the parent collection
      # sees it. Same reason as the leaf branch: the event-observer
      # force-send echo runs before the parent-change propagator can
      # fire on the next flush.
      set_internal(v)
      set_self(v)
      invisible(NULL)
    }
  }
  e <- environment(fn)
  e$keys <- keys
  e$children <- children
  e$label <- label
  class(fn) <- c("reactiveStore", "reactive", "function")
  fn
}

#' Scalar slot accessor for `Each` (positional and keyed)
#'
#' Builds the scalar-item analogue of [make_mini_store()] — a callable
#' (`reactiveProxy`) over a single value held in the parent collection.
#' Reads route through an internal `reactiveVal` that is kept in sync with
#' `get_value()` by a propagating observer; writes route through
#' `set_value()` to the parent. The internal `reactiveVal` is what gives
#' fine-grained reactivity: when the parent list is patched somewhere
#' else, an unchanged slot's observers don't fire.
#'
#' @param get_value 0-arg callable returning the slot's current value.
#' @param set_value 1-arg function called with the new value on write.
#' @param scope Scope from [make_scope()]; the propagating observer is
#'   registered here for cleanup.
#' @return A `reactiveProxy` that reads from the internal leaf and writes
#'   through `set_value`.
#' @keywords internal
make_slot_accessor <- function(get_value, set_value, scope) {
  rv <- shiny::reactiveVal(shiny::isolate(get_value()))
  # Shape-change guard: if the parent's slot transiently becomes a
  # record (e.g. heterogeneous list where a slot's shape flips), don't
  # stuff the record into the scalar `rv`. The outer `Each` reconciler
  # detects the shape change and rebuilds this slot as a mini-store on
  # the same flush; we just need to not poison the rv before teardown.
  obs <- shiny::observe({
    new_v <- get_value()
    if (is_record(new_v)) return()
    if (!identical(shiny::isolate(rv()), new_v)) {
      rv(new_v)
    }
  }, domain = scope$session)
  scope$register_observer(obs)
  # See `make_mini_store`'s leaf branch for why the local `rv` must be
  # written synchronously before chaining up through `set_value`.
  reactiveProxy(
    get = function() rv(),
    set = function(v) {
      if (!identical(shiny::isolate(rv()), v)) rv(v)
      set_value(v)
    }
  )
}

# Decide between mini-store projection (records) and bare-callable
# pass-through (scalars). Same shape as `is_branch` in spirit (fully
# named bare list with at least one element) but with permissive
# semantics — partial-naming returns FALSE rather than erroring.
# `is_branch` errors on construction-time misuse of `reactiveStore`;
# `is_record` is a runtime inspection on item values where erroring
# would mean crashing a user's app over an accidentally malformed item.
is_record <- function(value) {
  if (!is.list(value)) return(FALSE)
  if (length(value) == 0L) return(FALSE)
  nm <- names(value)
  if (is.null(nm)) return(FALSE)
  all(nzchar(nm))
}

# Disallow mixing records and scalars in one `Each` snapshot. Per-entry
# shape is decided from each item's own value, so the reconciler
# *could* mount records and scalars side by side — but a list like
# `c(records..., "footer-string")` is almost always a data-modeling
# slip (a scalar where a `list(...)` was intended). Allowing it would
# silently hand the body function an `item` that is sometimes a
# mini-store and sometimes a bare callable; bindings written against
# one shape would break the other. Heterogeneous *records* (different
# leaf trees) remain supported — that's the variant pattern, handled
# by `Match` inside the body. Errors with a wrap-in-record hint.
validate_each_kinds <- function(item_list) {
  if (length(item_list) == 0L) return(invisible())
  record_flags <- vapply(item_list, is_record, logical(1L))
  if (any(record_flags) && !all(record_flags)) {
    stop(
      "Each() items must be either all records (fully named lists) ",
      "or all scalars/atomics. Mixed-shape lists are usually a ",
      "data-modeling mistake — wrap scalars in a record like ",
      "`list(value = ...)` to mix.",
      call. = FALSE
    )
  }
  invisible()
}

# Recursive structural signature for `Each` shape-change detection.
# Mirrors `make_mini_node`'s branch-vs-leaf decision: bare named lists
# (no `AsIs`, no S3 class) are branches; everything else is a leaf.
# Returns a nested-list of NULL leaves under the same key tree the
# mini-store would build, or NULL for a leaf value.
#
# Comparison is by `identical()` — two items have the same signature iff
# the mini-store they'd build has the same set of leaves at the same
# paths. Scalars all share the NULL signature; only structural changes
# (key added/removed at any depth, scalar↔record transition, list-shape
# field becoming a record or vice versa) flip the signature.
shape_signature <- function(value) {
  if (inherits(value, "AsIs")) return(NULL)
  if (!is.list(value) || is.object(value)) return(NULL)
  if (length(value) == 0L) return(NULL)
  nm <- names(value)
  if (is.null(nm) || !all(nzchar(nm))) return(NULL)
  stats::setNames(lapply(value, shape_signature), nm)
}
