#' Validate and coerce a reactive text child's return value
#'
#' A reactive text child renders as a single text node (`target = "text"`).
#' The client coerces with `String(val)`, so a non-text return silently
#' produces garbage — an HTML tag becomes `"[object Object]"`, a vector
#' becomes a comma-joined blob. Catch it here with a clear error instead.
#'
#' Accepts `NULL` and length-1 atomics (coerced to character); rejects tags,
#' lists, and multi-element vectors. Wrap reactive tags in a control-flow
#' primitive (`When`/`Match`/`Each`) rather than returning them as text.
#'
#' @keywords internal
#' @noRd
coerce_text_child <- function(val) {
  if (is.null(val) || (is.atomic(val) && length(val) <= 1L)) {
    val <- as.character(val)
    # NULL / NA / character(0) all mean "empty" -> "" (the wire's "clear the range"
    # signal), so the text wire type is exactly `string` — never `[]` or `null`.
    if (length(val) == 0L || is.na(val)) return("")
    return(val)
  }
  what <- if (inherits(val, c("shiny.tag", "shiny.tag.list"))) {
    "an HTML tag - wrap reactive tags in When/Match/Each instead"
  } else if (length(val) > 1L) {
    paste0("a length-", length(val), " ", class(val)[1], " vector")
  } else {
    paste0("a ", class(val)[1])
  }
  stop(
    "A reactive text child must return a single text value (or NULL), not ",
    what, ".",
    call. = FALSE
  )
}

#' Coalesce per-widget `irid-attr` updates within a Shiny flush
#'
#' A widget can expose several bound props whose binding observers fire in
#' the same flush. Sending one `irid-attr` per binding races them on the
#' wire — for atomic-render libraries (Plotly, Mapbox) each message triggers
#' a full re-render, so two messages mean two redraws and a visible flash.
#'
#' Instead of sending immediately, each `(attr, value)` is accumulated into a
#' per-widget pending map on `session$userData$irid_widget_pending`, and a
#' one-shot `session$onFlushed` handler drains every widget's map at flush
#' end into a single `irid-attr target="widget"` carrying a
#' `values: {attr -> value}` object.
#'
#' The stale-echo gate is keyed PER CHANNEL, and a batch can mix props from
#' different channels (e.g. `xaxis_range` + `yaxis_range` from one box zoom),
#' so the gate travels per key: `valueGates: {attr -> {seq, channel}}`.
#' A key contributed without a gate (purely programmatic) gets no
#' `valueGates` entry and the client applies it unconditionally; a batch with
#' no gated keys carries an empty `valueGates` (`{}`).
#'
#' Batching is intra-flush only: a prop updating in one flush and another in
#' a later flush still produces two messages.
#'
#' @keywords internal
#' @noRd
irid_queue_widget_attr <- function(session, id, attr, value, gate = NULL) {
  pending <- session$userData$irid_widget_pending
  if (is.null(pending)) {
    pending <- new.env(parent = emptyenv())
    # `.order` tracks first-seen widget order so the drain preserves the
    # order observers fired in (rather than `ls()`'s alphabetical sort,
    # which puts "irid-10" before "irid-2"). The dot prefix hides it from
    # `ls()`. Widget ids never start with a dot.
    pending$.order <- character(0)
    session$userData$irid_widget_pending <- pending
    session$onFlushed(function() {
      ids <- pending$.order
      session$userData$irid_widget_pending <- NULL
      for (wid in ids) {
        entry <- pending[[wid]]
        session$sendCustomMessage("irid-attr",
          msg_irid_attr_widget(wid, entry$values, entry$value_gates))
      }
    }, once = TRUE)
  }
  entry <- pending[[id]]
  if (is.null(entry)) {
    entry <- list(values = list(), value_gates = list())
    pending$.order <- c(pending$.order, id)
  }
  # Single-bracket assignment so a legitimate NULL value keeps its key in
  # the map rather than being dropped (`[[<-` with NULL removes the entry).
  # The encoder (`json_map`) applies the named-vector -> object discipline at
  # drain time, so the raw R value is stored here.
  entry$values[attr] <- list(value)
  if (!is.null(gate)) {
    # Store the raw gate value object; the drain (`msg_irid_attr_widget`)
    # renders the whole map to its wire shape via `as_protocol`.
    entry$value_gates[[attr]] <- gate
  }
  pending[[id]] <- entry
  invisible()
}

# Optimistic-update echo gate value object: the classed `{seq, channel}` an
# irid-managed binding stamps on its echo so the client can drop it if a newer
# local edit has superseded it. NULL when there is no gating context (a
# programmatic write — nothing to gate against); the message constructor renders
# that absence as the wire's `null`/omitted gate. The `as_protocol` method lives
# in the codec (R/encode.R), mirroring wire_timing/dom_opts.
irid_echo_gate <- function(seq, channel) {
  if (is.null(seq)) return(NULL)
  structure(list(seq = seq, channel = channel), class = "irid_echo_gate")
}

# Pure reconciliation planner for `Each`. Decides *what* changes between two
# renders of the item list — which entries to remove, add, keep, or rebuild —
# and returns that decision as plain data. It performs no effects: constructing
# entries (scopes, wrapper ids), tearing down, mounting, and sending
# `irid-mutate` all live in `run_reconcile_plan()` below, which consumes the
# returned plan. Inputs are shape *signatures* (from `shape_signature()`) named
# by id, so the planner is testable without a Shiny session.
#
# Both `Each` modes funnel through here because **positional `Each` is keyed
# `Each` whose id is the row position**: positional ids are
# `as.character(seq_len(n))` (always dense `"1".."n"`), keyed ids are the
# stringified `by(item)`. Every mode difference then collapses to set algebra
# over `old_ids` / `new_ids`.
#
# `old_sigs`/`new_sigs` are named lists of shape signatures keyed by id. A kept
# id whose shape changed is promoted to remove + add so the entry is rebuilt
# against its new shape.
#
# Returns:
#   noop           - ids identical and no kept entry changed shape (no DOM work)
#   has_duplicates - `new_ids` has duplicates (caller raises; keyed only in
#                    practice — positional ids never collide)
#   removed/added  - ids to tear down / build (each = set-diff ++ shape-changed)
#   kept           - surviving ids that only moved (in `new_ids` order)
#   order          - full display sequence, or NULL when the client's
#                    natural insert order already matches (see below)
#   build_index    - named int: position of each added id in `new_ids`, used to
#                    seed `pos_rv` and index the live item list
plan_reconcile <- function(old_ids, new_ids, old_sigs, new_sigs) {
  # Surviving ids in `new_ids` order (intersect preserves first-arg order).
  surviving <- intersect(new_ids, old_ids)
  shape_changed <- surviving[!vapply(
    surviving,
    function(id) identical(new_sigs[[id]], old_sigs[[id]]),
    logical(1L)
  )]

  removed <- c(setdiff(old_ids, new_ids), shape_changed)
  added   <- c(setdiff(new_ids, old_ids), shape_changed)

  # `order` policy, derived from the client contract (see the `irid-mutate`
  # handler in inst/js/irid.js): given only `removes` + tail-`inserts`, the
  # client produces this DOM sequence —
  #   natural = (old_ids without `removed`, in old order) ++ (added, insert order)
  # `added` here is exactly the insert order `run_reconcile_plan` uses. `order`
  # is required precisely when that differs from the desired `new_ids`. This one
  # rule reproduces both modes' historical behaviour (positional append / trim
  # omit it; mid-list rebuild and keyed reorder send it) with no mode flag, and
  # additionally omits it on keyed tail-appends — a correct payload improvement.
  natural_order <- c(setdiff(old_ids, removed), added)

  list(
    noop = identical(new_ids, old_ids) && length(shape_changed) == 0L,
    has_duplicates = anyDuplicated(new_ids) > 0L,
    removed = removed,
    added   = added,
    kept    = setdiff(surviving, shape_changed),
    order   = if (!identical(new_ids, natural_order)) new_ids else NULL,
    build_index = stats::setNames(match(added, new_ids), added)
  )
}

# Mode-agnostic executor. Runs a `plan_reconcile()` plan against the per-item
# state held in `env` (`item_mounts`, a named map of entries by string id, and
# `current_ids`, the ordered id vector). Order of effects mirrors the client's
# `irid-mutate` handling and the framework's mount/teardown invariants:
# teardown removed → build added (DOM string) → send mutate → mount added
# (after the DOM exists) → reposition kept. `build_entry` stays mode-aware (it
# builds genuinely different value-access closures per mode); the executor only
# calls it.
run_reconcile_plan <- function(plan, new_ids, item_list, env, build_entry,
                               teardown_entry, session, cf_id, depth) {
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

  # `order` maps planner ids to their wrapper ids; the encoder forces each field
  # to a JSON array (the array-typed-field discipline lives in `json_array`).
  order_ids <- if (!is.null(plan$order)) {
    vapply(
      plan$order,
      function(id) env$item_mounts[[id]]$wrapper_id,
      character(1L)
    )
  } else NULL
  session$sendCustomMessage("irid-mutate", msg_irid_mutate(
    cf_id, removes = removes, inserts = inserts, order = order_ids
  ))

  # Mount new entries after their DOM exists.
  for (id in plan$added) {
    entry <- env$item_mounts[[id]]
    entry$mount <- irid_mount_processed(
      entry$processed, session, depth = depth + 1L
    )
    entry$processed <- NULL
    env$item_mounts[[id]] <- entry
  }

  # Live position for kept ids whose slot moved. `pos_rv` is keyed-only;
  # positional entries hold `pos_rv = NULL` (their slot is their identity and
  # never permutes), so the guard makes this a no-op for them.
  for (id in plan$kept) {
    entry <- env$item_mounts[[id]]
    if (!is.null(entry$pos_rv)) entry$pos_rv(match(id, new_ids))
  }

  env$current_ids <- new_ids
  invisible()
}

# Single-slot keyed reconciliation for `When`/`Match`: one child slot keyed by
# the active branch/case. The body is given its own child-anchor pair (a named
# child range inside the container `cf_id`), so a flip is
# `mutate {removes:[old], inserts:[new]}` and an empty branch `mutate {removes:[old]}`.
#
# `body_tag` is the already-evaluated tag tree, or NULL for an empty branch.
# `old_child_id` is the previous body's wrapper id (NULL on first render). Returns
# `list(child_id, mount)` — the caller stores both for the next flip and teardown.
# The mount runs AFTER the DOM insert (mutate first).
cf_render_child <- function(session, cf_id, old_child_id, body_tag,
                            counter, depth) {
  removes <- if (!is.null(old_child_id)) old_child_id else NULL
  if (is.null(body_tag)) {
    if (!is.null(removes)) {
      session$sendCustomMessage("irid-mutate",
        msg_irid_mutate(cf_id, removes = removes))
    }
    return(list(child_id = NULL, mount = NULL))
  }
  child_id <- counter()
  wrapped <- tagList(
    htmltools::HTML(paste0("<!--irid:s:", child_id, "-->")),
    body_tag,
    htmltools::HTML(paste0("<!--irid:e:", child_id, "-->"))
  )
  processed <- process_tags(wrapped, counter = counter)
  session$sendCustomMessage("irid-mutate", msg_irid_mutate(
    cf_id, removes = removes, inserts = list(as.character(processed$tag))
  ))
  mount <- irid_mount_processed(processed, session, depth = depth + 1L)
  list(child_id = child_id, mount = mount)
}

# Deliver a widget's dependencies at mount time through Shiny's *native render
# pipeline*, via `insertUI` — the only dep-delivery path shinylive serves (a bare
# `Shiny.renderDependencies` off the `irid-widget-init` custom message 404s
# there; see ARCHITECTURE.md "Widgets -> Lifecycle and dependencies"). Verified:
# an `insertUI`-delivered file-backed dep loads under shinylive (spike, web
# assets 0.9.1 — re-confirm on bump).
#
# Delivering here (rather than page-attaching at render) reaches widgets that
# appear *only* inside `When`/`Each`/`Match` — `irid_mount_processed` is the
# recursive chokepoint every nested mount calls — and keeps the factory script
# arriving *after* `irid.js` (which stays in the initial <head> as
# `irid_dependency()`), so `window.irid` always exists when a factory runs.
#
# Deduped by dependency name across the session so a shared library (e.g.
# plotly.js across many `Each` items) is inserted once, not once per item.
# `package`- / file-backed deps need no manual resource registration — the
# native pipeline resolves and serves them (the reason `register_widget_dep` is
# gone). The insert is `immediate = FALSE`, so deps arrive on the first flush.
deliver_widget_deps <- function(session, deps) {
  if (length(deps) == 0L) return(invisible())
  seen <- session$userData$irid_deps_seen
  if (is.null(seen)) seen <- character()
  new <- Filter(function(d) !(d$name %in% seen), deps)
  if (length(new) == 0L) return(invisible())
  session$userData$irid_deps_seen <- c(
    seen, vapply(new, function(d) d$name, character(1L))
  )
  shiny::insertUI(
    selector = "body",
    where = "beforeEnd",
    ui = htmltools::tagList(new),
    immediate = FALSE,
    session = session
  )
  invisible()
}

#' Mount a pre-processed irid tag tree
#'
#' Takes the output of [process_tags()] and wires up Shiny observers for
#' reactive attribute bindings, event listeners, Shiny outputs, and
#' control-flow nodes (`When`, `Each`, `Match`).
#'
#' Binding observers run at `priority = -100 + depth`, so deeper-nested
#' bindings fire before shallower ones in the same flush. Control flow
#' observers stay at the default priority 0 and always fire first. This
#' guarantees that on initial mount (and on any cascading re-render),
#' content inserted by a control flow is fully populated by its inner
#' bindings before any parent attribute binding observes it. The motivating
#' case is `<select value=rv>` whose options come from `Each` — the parent's
#' `value` binding must fire *after* the options exist and have their
#' `value` attributes set, otherwise the browser silently sets
#' `selectedIndex = -1` and the select renders blank.
#'
#' @param result A list returned by [process_tags()], containing `$tag`,
#'   `$bindings`, `$events`, `$control_flows`, and `$shiny_outputs`.
#' @param session A Shiny session object.
#' @param depth Nesting depth used to compute binding priority. Top-level
#'   mounts (`iridApp`, `renderIrid`) use the default `0`; recursive calls
#'   from inside `When`/`Each`/`Match` increment it so nested bindings fire
#'   before their parent's.
#' @return A mount handle with `$tag` (the processed HTML) and `$destroy()`
#'   (a function that tears down all observers).
#' @keywords internal
irid_mount_processed <- function(result, session, depth = 0L) {
  counter <- result$counter
  observers <- list()
  binding_priority <- -100L + depth

  # Index bindings by element ID so event handlers can force-send
  # the authoritative value even when the reactive is a no-op.
  bindings_by_id <- list()
  for (b in result$bindings) {
    bindings_by_id[[b$id]] <- c(bindings_by_id[[b$id]], list(b))
  }

  # Send widget init messages. Build the merged `props` object by
  # `isolate(fn())`-evaluating each callable prop and merging with the
  # static props. Ordering is naturally correct: top-level mounts send
  # this with the container already in the static HTML; nested mounts
  # are invoked from inside the control-flow observer *after* the swap/
  # mutate that introduced the container, so the init message arrives
  # at the client after the DOM change.
  #
  # Dependencies do NOT ride this message — they are delivered via `insertUI`
  # through the native render pipeline (served under shinylive). The init message
  # arrives before that insert has delivered the factory script, so the client
  # parks it under `pendingInits` and drains it when the factory's `defineWidget`
  # lands.
  for (wi in result$widget_inits) {
    props <- wi$static_props
    for (key in names(wi$prop_fns)) {
      # Single-bracket assignment so a NULL-initialized reactive prop keeps its
      # key as explicit `null` (the encoder emits `"k":null`), giving the factory
      # its full declared prop set. (`[[<-` with NULL would drop the key.)
      props[key] <- list(isolate(wi$prop_fns[[key]]()))
    }
    deliver_widget_deps(session, wi$deps)
    session$sendCustomMessage("irid-widget-init",
      msg_irid_widget_init(wi$id, wi$name, props))
  }

  # Set up event listeners
  if (length(result$events) > 0L) {
    wire_msgs <- lapply(result$events, function(ev) {
      # Every inbound channel — DOM events, widget events, and widget prop
      # write-backs (client's `setProp`) — shares one input namespace,
      # `irid_input_{id}_{event}`. A prop and event can't share a name (enforced in
      # `IridWidget`), so `(id, event)` is unique.
      input_id <- paste0("irid_input_", ev$id, "_", ev$event)
      handler <- ev$handler

      # The channel = the namespaced inputId the client sends on. It is the
      # client's per-channel sequence-counter key and the stale-echo gate key,
      # so echoes stamped with it (below) gate only against newer sends on the
      # SAME channel.
      channel <- session$ns(input_id)

      # The encoder builds the discriminated wire shape (nested timing/domOpts,
      # domOpts/clientOnly on dom rows; the widget arm adds nothing). `clientOnly`
      # is a config-only dom wire — `dom_opts` with no server handler.
      msg <- msg_irid_wire(ev, channel, client_only = is.null(handler))

      # A config-only event (e.g. `dom_opts` with no handler) attaches a
      # client-side listener for its DOM flags but never round-trips, so
      # there is no server observer to register.
      if (is.null(handler)) return(msg)

      nformals <- length(formals(handler))

      obs <- observeEvent(session$input[[input_id]], {
        latency <- getOption("irid.debug.latency", 0)
        if (latency > 0) Sys.sleep(latency)
        # Inbound envelope (flat mirror of the client's `attachPayloadMeta`):
        # `{ id, seq, data }`, foreign event fields under `data`, read directly.
        payload <- session$input[[input_id]]
        source_id <- payload$id
        write_targets <- ev$write_targets

        # DOM-only: empty number inputs arrive with `valueAsNumber` null; map it
        # to NA_real_. Widget event data is left verbatim (a widget's null stays
        # null).
        event_obj <- payload$data
        if (identical(ev$source, "dom")) event_obj <- coerce_value_as_number(event_obj)

        # Thread the event sequence for optimistic-update tracking, keyed PER
        # CHANNEL. `irid_current_sequence[[source_id]][[attr]] = {seq, channel}`
        # records, for each binding attr this event declares it writes
        # (`write_targets`), the seq+channel a binding observer should stamp on
        # its echo. Keying by write target (not just the source element) means
        # a sibling channel firing in the same flush writes DISJOINT keys and
        # cannot steal another channel's entry. An event with no declared
        # targets — a hand-rolled `on*` handler or a `sendEvent` notification —
        # records nothing, so any binding it incidentally drives echoes ungated
        # (treated as programmatic). Gating is a property of irid-MANAGED
        # bindings (autobind `value`/`checked`, `reactiveProxy`, widget props).
        seq <- payload$seq
        if (!is.null(seq) && !is.null(write_targets)) {
          cur <- session$userData$irid_current_sequence
          if (is.null(cur)) cur <- list()
          entry <- cur[[source_id]]
          if (is.null(entry)) entry <- list()
          gate <- irid_echo_gate(seq, channel)
          for (tgt in write_targets) entry[[tgt]] <- gate
          cur[[source_id]] <- entry
          session$userData$irid_current_sequence <- cur
          session$onFlushed(function() {
            session$userData$irid_current_sequence <- NULL
          }, once = TRUE)
        }

        if (nformals == 0L) {
          handler()
        } else if (nformals == 1L) {
          handler(event_obj)
        } else {
          handler(event_obj, source_id)
        }

        # Force-send current binding values for the source element.
        # If the handler set a reactive to the same value (no-op), the
        # binding observer won't fire and the client gets no echo. This
        # ensures the client always receives the authoritative value so
        # it can apply server transforms even on no-op updates.
        #
        # Scoped per-binding via `write_targets` — only echo the bindings
        # this event's handler is registered to write through (the DOM
        # autobind or the widget two-way-prop write-back). Hand-rolled
        # handlers declare no targets and get no force-send: their bindings
        # either fire naturally on change or the wrapper handles the echo
        # itself.
        # Without this filtering, an event whose handler doesn't write a
        # particular binding's reactiveVal would still force-send that
        # binding's current value — and if the binding's write is
        # debounced and hasn't delivered yet, the server's stale value
        # would overwrite in-flight client state.
        source_bindings <- bindings_by_id[[source_id]]
        if (!is.null(seq) && length(source_bindings) > 0L &&
            !is.null(write_targets)) {
          gate <- irid_echo_gate(seq, channel)
          for (sb in source_bindings) {
            if (!(sb$attr %in% write_targets)) next
            val <- isolate(sb$fn())
            if (sb$target == "widget") {
              # Same per-widget batch as the binding observers — the
              # force-send echo coalesces with them in this flush. Stamps
              # this event's channel so the client gates per channel.
              irid_queue_widget_attr(session, sb$id, sb$attr, val, gate)
            } else {
              msg <- if (sb$target == "text") {
                msg_irid_attr_text(sb$id, coerce_text_child(val))
              } else {
                msg_irid_attr_dom(sb$id, sb$attr, val, gate)
              }
              session$sendCustomMessage("irid-attr", msg)
            }
          }
        }
      }, ignoreInit = TRUE)
      observers[[length(observers) + 1L]] <<- obs

      msg
    })
    session$sendCustomMessage("irid-wire", wire_msgs)
  }

  # Set up reactive attribute bindings. Lower priority than control flows
  # so this mount's bindings fire after all control-flow content has been
  # inserted. Priority decreases with depth so deeper bindings fire before
  # shallower ones — see the function-level docs for the motivating case.
  #
  # All bindings ride `irid-attr` with a `target` field. `target = "dom"`
  # is a real DOM attribute / property write on `getElementById(b$id)`;
  # `target = "text"` replaces the content between the comment-anchor
  # pair `b$id`. Dispatch happens client-side on `msg.target`.
  lapply(result$bindings, function(b) {
    obs <- observe({
      val <- b$fn()
      # Look up this binding's own gate: the entry keyed by (source, attr)
      # that an event in this flush recorded for the target `b$attr`. Absent
      # for a programmatic update, a cross-element write, or a binding driven
      # only by a hand-rolled handler — all of which echo ungated.
      cur <- session$userData$irid_current_sequence
      gate <- if (!is.null(cur) && !is.null(cur[[b$id]])) cur[[b$id]][[b$attr]] else NULL
      if (b$target == "widget") {
        # Coalesced per-widget; drained as one `values` map at flush end.
        irid_queue_widget_attr(session, b$id, b$attr, val, gate)
      } else {
        msg <- if (b$target == "text") {
          # Text never gates (it is never an event write_target), so `gate` is
          # always NULL here — the encoder carries no gate for it.
          msg_irid_attr_text(b$id, coerce_text_child(val))
        } else {
          msg_irid_attr_dom(b$id, b$attr, val, gate)
        }
        session$sendCustomMessage("irid-attr", msg)
      }
    }, priority = binding_priority)
    observers[[length(observers) + 1L]] <<- obs
  })

  # Set up Shiny outputs
  for (so in result$shiny_outputs) {
    session$output[[so$id]] <- so$render_call
  }

  # Set up control flow nodes
  cf_envs <- list()

  for (cf in result$control_flows) {
    if (cf$type == "when") {
      local({
        current_mount <- NULL
        current_child <- NULL
        last_active <- NULL
        cf_id <- cf$id
        cf_condition <- cf$condition
        cf_yes <- cf$yes
        cf_otherwise <- cf$otherwise
        env <- environment()

        obs <- observe({
          active <- isTRUE(cf_condition())

          # Short-circuit if the branch hasn't changed
          if (identical(active, env$last_active)) return()
          env$last_active <- active

          branch_fn <- if (active) cf_yes else cf_otherwise

          # Destroy previous branch's observers (the DOM child range is removed by
          # the mutate below). Call the body fresh on each activation — the
          # previous branch's closures were torn down here.
          if (!is.null(env$current_mount)) {
            env$current_mount$destroy()
            env$current_mount <- NULL
          }

          body_tag <- if (!is.null(branch_fn)) branch_fn() else NULL
          rendered <- cf_render_child(
            session, cf_id, env$current_child, body_tag, counter, depth
          )
          env$current_child <- rendered$child_id
          env$current_mount <- rendered$mount
        })
        observers[[length(observers) + 1L]] <<- obs
        cf_envs[[length(cf_envs) + 1L]] <<- env
      })
    } else if (cf$type == "each") {
      local({
        cf_id <- cf$id
        cf_items <- cf$items
        cf_fn <- cf$fn
        cf_by <- cf$by
        cf_nformals <- length(formals(cf_fn))
        keyed <- !is.null(cf_by)

        # Per-item state, unified across modes (see `plan_reconcile`).
        # `item_mounts` is always a named map keyed by string id — keyed
        # ids are the stringified `by(item)`; positional ids are
        # `as.character(seq_len(n))` (always dense `"1".."n"`, since
        # positional only grows/trims at the tail and rebuilds in place),
        # so the map stays equivalent to the old dense list. Each entry
        # holds:
        #   scope, mount, wrapper_id, accessor, pos_rv (keyed only),
        #   is_record_shape (per-entry — the list may be heterogeneous),
        #   processed (transient — cleared after mount).
        # `current_ids` is the ordered id vector — the source of truth for
        # display sequence and for the next render's `old_ids` (a named
        # map's key order does not track display order after removals).
        #
        # Shape is decided per-entry at build time from the item's
        # current value, not once for the whole list. A slot whose
        # value changes shape (scalar↔record, or partial-named anomaly)
        # is torn down and rebuilt with the right accessor type — same
        # path as add/remove. This lets `Each(items, \(x) Match(x, ...))`
        # work over heterogeneous lists.
        item_mounts <- list()
        current_ids <- character(0)
        env <- environment()

        # Build accessor + tag tree + mount entry for one item.
        # `id` is the storage key in `item_mounts` (stringified `by(item)`
        # in keyed mode, `as.character(slot)` in positional mode).
        # `slot_index` is the 1-indexed position in the current item list —
        # it seeds `pos_rv` (keyed) and is the captured slot (positional).
        # `item_value` is the current value at build time, used to pick the
        # accessor shape and seed the entry's structural signature without
        # re-reading `cf_items()` (so heterogeneous lists build each slot
        # against its own item, not the first one).
        build_entry <- function(id, slot_index, item_value) {
          wrapper_id <- counter()
          scope <- make_scope(session, id = wrapper_id)
          shape_sig <- shape_signature(item_value)
          is_record_shape <- !is.null(shape_sig)

          if (keyed) {
            # Resolve slot by key at *write* time so reorders work — the
            # slot's positional index is never captured. `isolate` so the
            # write path doesn't subscribe to the parent collection.
            # Returns NA if the key has been removed from the parent
            # collection since this entry was built (e.g. an event
            # observer fires after the item was removed but before
            # teardown completes).
            current_index <- function() {
              items_now <- shiny::isolate(cf_items())
              keys_now <- vapply(
                items_now,
                function(x) as.character(cf_by(x)),
                character(1L)
              )
              match(id, keys_now)
            }
            get_value <- function() {
              idx <- current_index()
              # nocov start: keyed read/write during a teardown race
              if (is.na(idx)) return(NULL)
              # nocov end
              cf_items()[[idx]]
            }
            set_value <- function(v) {
              idx <- current_index()
              # nocov start
              if (is.na(idx)) return(invisible())
              # nocov end
              new_items <- shiny::isolate(cf_items())
              new_items[[idx]] <- v
              cf_items(new_items)
            }
            # shiny#4372: scope the keyed position rv for destroy.
            pos_rv <- scope$with_scope(shiny::reactiveVal(slot_index))
            pos_accessor <- reactiveProxy(get = function() pos_rv())
          } else {
            # Positional mode: slot index is captured (slots are stable).
            ii <- slot_index
            get_value <- function() cf_items()[[ii]]
            set_value <- function(v) {
              new_items <- shiny::isolate(cf_items())
              new_items[[ii]] <- v
              cf_items(new_items)
            }
            pos_rv <- NULL
            # Constant signal — slot number is the identity, never changes.
            pos_accessor <- reactiveProxy(get = function() ii)
          }

          accessor <- if (is_record_shape) {
            make_mini_store(get_value, set_value, scope)
          } else {
            make_slot_accessor(get_value, set_value, scope)
          }

          # shiny#4372: evaluate the item body under the scope's domain so any
          # user-authored observe()/reactiveVal in the callback attaches to the
          # item scope and is torn down on unmount (no-op wrap pre-#4372).
          child <- scope$with_scope(if (cf_nformals == 0L) {
            cf_fn()
          } else if (cf_nformals == 1L) {
            cf_fn(accessor)
          } else {
            cf_fn(accessor, pos_accessor)
          })
          wrapped <- tagList(
            htmltools::HTML(paste0("<!--irid:s:", wrapper_id, "-->")),
            child,
            htmltools::HTML(paste0("<!--irid:e:", wrapper_id, "-->"))
          )
          processed <- process_tags(wrapped, counter = counter)

          list(
            scope = scope, mount = NULL, wrapper_id = wrapper_id,
            accessor = accessor, pos_rv = pos_rv,
            shape_sig = shape_sig,
            processed = processed
          )
        }

        # Tear down one item entry. Order: mount → scope. See
        # `make_scope`'s "Teardown ordering" note.
        teardown_entry <- function(entry) {
          if (!is.null(entry$mount)) entry$mount$destroy()
          if (!is.null(entry$scope)) entry$scope$destroy()
          invisible()
        }

        obs <- observe({
          item_list <- cf_items()
          validate_each_kinds(item_list)

          # The only per-mode difference is how ids are produced: keyed ids
          # are the stringified `by(item)`; positional ids are the slot
          # numbers. Everything after is shared (see `plan_reconcile`).
          # `USE.NAMES = FALSE` keeps `new_ids` unnamed so it compares
          # cleanly against the planner's freshly built `natural_order`.
          new_ids <- if (keyed) {
            vapply(
              item_list,
              function(x) as.character(cf_by(x)),
              character(1L),
              USE.NAMES = FALSE
            )
          } else {
            as.character(seq_along(item_list))
          }
          old_ids <- env$current_ids

          # Decide the diff from shape signatures (pure — see
          # `plan_reconcile`). A kept id whose shape changed is promoted to
          # remove+add: the mini-store's leaf tree is derived from the item
          # at mount time, so any structural change (scalar↔record, or a
          # record with different keys at any depth) needs a fresh entry
          # with the new shape.
          new_sigs <- stats::setNames(
            lapply(item_list, shape_signature), new_ids
          )
          old_sigs <- stats::setNames(
            lapply(old_ids, function(id) env$item_mounts[[id]]$shape_sig),
            old_ids
          )
          plan <- plan_reconcile(old_ids, new_ids, old_sigs, new_sigs)

          # Pure value-change short-circuit. The observer fires on any
          # change to the parent collection (including in-place value
          # edits), but the per-item mini-store / scalar-accessor
          # propagators handle in-place changes themselves. No id or shape
          # change means no DOM work — and emitting an `irid-mutate` here
          # detaches every child range into a fragment client-side just to
          # re-insert it, which kills focus on any focused input inside.
          if (plan$noop) return()

          if (plan$has_duplicates) {
            # nocov start: raised from an async observer; the detection is
            # unit-tested via plan_reconcile()$has_duplicates
            cli::cli_abort("{.fn Each} requires unique keys from the {.arg by} function.")
            # nocov end
          }

          run_reconcile_plan(
            plan, new_ids, item_list, env, build_entry, teardown_entry,
            session, cf_id, depth
          )
        })
        observers[[length(observers) + 1L]] <<- obs
        cf_envs[[length(cf_envs) + 1L]] <<- env
      })

    } else if (cf$type == "match") {
      local({
        current_mount <- NULL
        current_child <- NULL
        current_scope <- NULL
        last_active <- NULL
        cf_id <- cf$id
        cf_callable <- cf$callable
        cf_cases <- cf$cases
        env <- environment()

        obs <- observe({
          value <- cf_callable()

          # Walk cases — predicate arity dictates whether the bound value
          # is passed in. 0-arg predicates are cross-cutting (debug
          # overrides, auth checks) and ignore the bound value; 1-arg
          # predicates inspect it.
          active_idx <- NA_integer_
          for (i in seq_along(cf_cases)) {
            pred <- cf_cases[[i]]$predicate
            n_pred <- length(formals(pred))
            result <- if (n_pred == 0L) pred() else pred(value)
            if (isTRUE(result)) {
              active_idx <- i
              break
            }
          }

          # Short-circuit on same active case — the existing mini-store's
          # internal observer auto-propagates value changes to its leaves
          # (only changed fields fire), so the mounted body's observers
          # update without a remount.
          if (identical(active_idx, env$last_active)) return()
          env$last_active <- active_idx

          # Tear down old case. Order: mount → scope. See
          # `make_scope`'s "Teardown ordering" note.
          if (!is.null(env$current_mount)) {
            env$current_mount$destroy()
            env$current_mount <- NULL
          }
          if (!is.null(env$current_scope)) {
            env$current_scope$destroy()
            env$current_scope <- NULL
          }

          if (is.na(active_idx)) {
            # Empty case — remove the current child range, mount nothing.
            rendered <- cf_render_child(
              session, cf_id, env$current_child, NULL, counter, depth
            )
            env$current_child <- rendered$child_id
            return()
          }

          case <- cf_cases[[active_idx]]
          body <- case$body
          n_body <- length(formals(body))

          scope <- make_scope(session, id = counter())
          env$current_scope <- scope

          # Records → mini-store projection (fine-grained leaf reads,
          # synthetic setters write through the leading callable).
          # Scalars → pass the bare callable (it already has the right
          # read/write shape).
          binding <- if (is_record(value)) {
            make_mini_store(
              get_record = cf_callable,
              set_record = cf_callable,
              scope = scope
            )
          } else {
            cf_callable
          }

          # shiny#4372: evaluate the case body under the scope's domain (see
          # the Each build_entry note) — scopes user reactives to the case.
          tag_tree <- scope$with_scope(if (n_body == 0L) body() else body(binding))

          rendered <- cf_render_child(
            session, cf_id, env$current_child, tag_tree, counter, depth
          )
          env$current_child <- rendered$child_id
          env$current_mount <- rendered$mount
        })
        observers[[length(observers) + 1L]] <<- obs
        cf_envs[[length(cf_envs) + 1L]] <<- env
      })
    }
  }

  list(
    tag = result$tag,
    destroy = function() {
      for (obs in observers) obs$destroy()
      for (env in cf_envs) {
        # When/Match: single current_mount + (Match only) per-case scope
        if (!is.null(env$current_mount)) env$current_mount$destroy()
        # shiny#4372: per-case scope teardown — child scope cascade reclaims
        # observers + reactiveVals when running on a #4372 shiny.
        if (!is.null(env$current_scope)) env$current_scope$destroy()
        # Each: per-item mounts + per-item scopes (mini-store / slot
        # accessor propagating observers, plus shiny#4372 reactives).
        if (!is.null(env$item_mounts)) {
          for (m in env$item_mounts) {
            if (!is.null(m$mount)) m$mount$destroy()
            if (!is.null(m$scope)) m$scope$destroy()
          }
        }
      }
    }
  )
}
