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
#' `values: {attr -> value}` object. The batch sequence is the highest
#' contributed by any binding (or `NULL` for a purely programmatic update).
#'
#' Batching is intra-flush only: a prop updating in one flush and another in
#' a later flush still produces two messages.
#'
#' @keywords internal
#' @noRd
irid_queue_widget_attr <- function(session, id, attr, value, sequence = NULL) {
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
        msg <- list(id = wid, target = "widget", values = entry$values)
        if (!is.null(entry$sequence)) msg$sequence <- entry$sequence
        session$sendCustomMessage("irid-attr", msg)
      }
    }, once = TRUE)
  }
  entry <- pending[[id]]
  if (is.null(entry)) {
    entry <- list(values = list(), sequence = NULL)
    pending$.order <- c(pending$.order, id)
  }
  # Single-bracket assignment so a legitimate NULL value keeps its key in
  # the map rather than being dropped (`[[<-` with NULL removes the entry).
  entry$values[attr] <- list(value)
  if (!is.null(sequence)) {
    entry$sequence <- if (is.null(entry$sequence)) {
      sequence
    } else {
      max(entry$sequence, sequence)
    }
  }
  pending[[id]] <- entry
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
  for (wi in result$widget_inits) {
    props <- wi$static_props
    for (key in names(wi$prop_fns)) {
      props[[key]] <- isolate(wi$prop_fns[[key]]())
    }
    deps <- lapply(wi$deps, register_widget_dep)
    session$sendCustomMessage("irid-widget-init", list(
      id = wi$id,
      name = wi$name,
      props = props,
      deps = deps
    ))
  }

  # Set up event listeners
  if (length(result$events) > 0L) {
    event_msgs <- lapply(result$events, function(ev) {
      # Two-way widget props ride a distinct input namespace
      # (`irid_prop_{id}_{key}`, written by the client's `setProp`); DOM and
      # widget events use `irid_ev_{id}_{event}`.
      input_id <- if (identical(ev$kind, "prop")) {
        paste0("irid_prop_", ev$id, "_", ev$event)
      } else {
        paste0("irid_ev_", ev$id, "_", ev$event)
      }
      handler <- ev$handler

      msg <- list(
        id = ev$id,
        event = ev$event,
        inputId = session$ns(input_id),
        mode = ev$mode,
        ms = ev$ms,
        leading = ev$leading,
        coalesce = ev$coalesce,
        preventDefault = ev$prevent_default,
        stopPropagation = ev$stop_propagation,
        capture = ev$capture,
        passive = ev$passive,
        clientOnly = is.null(handler),
        source = ev$source
      )

      # A config-only event (e.g. `dom_opts` with no handler) attaches a
      # client-side listener for its DOM flags but never round-trips, so
      # there is no server observer to register.
      if (is.null(handler)) return(msg)

      nformals <- length(formals(handler))

      obs <- observeEvent(session$input[[input_id]], {
        latency <- getOption("irid.debug.latency", 0)
        if (latency > 0) Sys.sleep(latency)
        ev_data <- session$input[[input_id]]

        # Thread event sequence number for optimistic update tracking.
        # Store both the sequence and the source element ID so binding
        # observers only attach the sequence when the binding target
        # matches the event source (same element). Cross-element updates
        # (e.g. button click clearing a text input) arrive with no
        # sequence and are treated as programmatic by the client.
        seq <- ev_data[["__irid_seq"]]
        if (!is.null(seq)) {
          session$userData$irid_current_sequence <- list(
            seq = seq, source = ev_data[["id"]]
          )
          session$onFlushed(function() {
            session$userData$irid_current_sequence <- NULL
          }, once = TRUE)
        }

        event_obj <- lapply(
          ev_data[setdiff(names(ev_data), c("id", "nonce", "__irid_seq"))],
          function(x) if (is.null(x)) NA else x
        )
        if (nformals == 0L) {
          handler()
        } else if (nformals == 1L) {
          handler(event_obj)
        } else {
          handler(event_obj, ev_data$id)
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
        source_id <- ev_data[["id"]]
        source_bindings <- bindings_by_id[[source_id]]
        write_targets <- ev$write_targets
        if (!is.null(seq) && length(source_bindings) > 0L &&
            !is.null(write_targets)) {
          for (sb in source_bindings) {
            if (!(sb$attr %in% write_targets)) next
            val <- isolate(sb$fn())
            if (sb$target == "widget") {
              # Same per-widget batch as the binding observers — the
              # force-send echo coalesces with them in this flush.
              irid_queue_widget_attr(session, sb$id, sb$attr, val, seq)
            } else {
              msg <- switch(sb$target,
                dom  = list(id = sb$id, target = "dom",  attr = sb$attr,
                            value = val, sequence = seq),
                text = list(id = sb$id, target = "text",
                            value = val, sequence = seq)
              )
              session$sendCustomMessage("irid-attr", msg)
            }
          }
        }
      }, ignoreInit = TRUE)
      observers[[length(observers) + 1L]] <<- obs

      msg
    })
    session$sendCustomMessage("irid-events", event_msgs)
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
      seq_info <- session$userData$irid_current_sequence
      seq <- if (!is.null(seq_info) && seq_info$source == b$id) {
        seq_info$seq
      } else {
        NULL
      }
      if (b$target == "widget") {
        # Coalesced per-widget; drained as one `values` map at flush end.
        irid_queue_widget_attr(session, b$id, b$attr, val, seq)
      } else {
        msg <- switch(b$target,
          dom  = list(id = b$id, target = "dom",  attr = b$attr, value = val),
          text = list(id = b$id, target = "text",                value = val)
        )
        if (!is.null(seq)) msg$sequence <- seq
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

          # Destroy previous branch
          if (!is.null(env$current_mount)) {
            env$current_mount$destroy()
            env$current_mount <- NULL
          }

          if (!is.null(branch_fn)) {
            # Call the body fresh on each activation — the previous
            # branch's closures were torn down above.
            branch <- branch_fn()
            processed <- process_tags(branch, counter = counter)

            # Swap first so elements exist in DOM
            session$sendCustomMessage("irid-swap", list(
              id = cf_id,
              html = as.character(processed$tag)
            ))

            # Then mount observers/events
            env$current_mount <- irid_mount_processed(
              processed, session, depth = depth + 1L
            )
          } else {
            session$sendCustomMessage("irid-swap", list(
              id = cf_id,
              html = ""
            ))
          }
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

        # Per-item state. Positional mode uses an unnamed list indexed by
        # slot position; keyed mode uses a named list keyed by stringified
        # `by(item)`. Each entry holds:
        #   scope, mount, wrapper_id, accessor, pos_rv (keyed only),
        #   is_record_shape (per-entry — the list may be heterogeneous),
        #   processed (transient — cleared after mount).
        #
        # Shape is decided per-entry at build time from the item's
        # current value, not once for the whole list. A slot whose
        # value changes shape (scalar↔record, or partial-named anomaly)
        # is torn down and rebuilt with the right accessor type — same
        # path as add/remove. This lets `Each(items, \(x) Match(x, ...))`
        # work over heterogeneous lists.
        item_mounts <- list()
        current_keys <- character(0)
        env <- environment()

        # Build accessor + tag tree + mount entry for one item.
        # `key_or_idx` is the storage key in `item_mounts`; `slot_index`
        # is the initial 1-indexed position used to seed `pos_rv`. For
        # positional mode both are the same integer; for keyed mode the
        # storage key is the stringified `by(item)`. `item_value` is the
        # current value at build time — used to pick the accessor shape
        # and seed the entry's structural signature without re-reading
        # `cf_items()` (and so heterogeneous lists build each slot
        # against its own item, not the first one).
        build_entry <- function(key_or_idx, slot_index, item_value) {
          wrapper_id <- counter()
          scope <- make_scope(session)
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
              match(key_or_idx, keys_now)
            }
            get_value <- function() {
              idx <- current_index()
              if (is.na(idx)) return(NULL)
              cf_items()[[idx]]
            }
            set_value <- function(v) {
              idx <- current_index()
              if (is.na(idx)) return(invisible())
              new_items <- shiny::isolate(cf_items())
              new_items[[idx]] <- v
              cf_items(new_items)
            }
            pos_rv <- shiny::reactiveVal(slot_index)
            pos_accessor <- reactiveProxy(get = function() pos_rv())
          } else {
            # Positional mode: slot index is captured (slots are stable).
            ii <- key_or_idx
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

          child <- if (cf_nformals == 0L) {
            cf_fn()
          } else if (cf_nformals == 1L) {
            cf_fn(accessor)
          } else {
            cf_fn(accessor, pos_accessor)
          }
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

          if (keyed) {
            new_keys <- vapply(
              item_list,
              function(x) as.character(cf_by(x)),
              character(1L)
            )
            old_keys <- env$current_keys

            # Detect shape changes among the keys that survive (i.e.
            # would otherwise be "kept"). A shape transition for a kept
            # key forces a remove+rebuild for that one entry — the
            # mini-store's leaf tree is derived from the item at mount
            # time, so any structural change (scalar↔record, or a
            # record with different keys at any depth) needs a fresh
            # entry with the new shape.
            shape_changed_keys <- character(0)
            for (i in seq_along(new_keys)) {
              key <- new_keys[i]
              if (key %in% old_keys) {
                new_sig <- shape_signature(item_list[[i]])
                if (!identical(
                  new_sig, env$item_mounts[[key]]$shape_sig
                )) {
                  shape_changed_keys <- c(shape_changed_keys, key)
                }
              }
            }

            # Pure value-change short-circuit. The observer fires on any
            # change to the parent collection (including in-place value
            # edits), but the per-item mini-store / scalar-accessor
            # propagators handle in-place changes themselves. If the
            # keys are identical to the previous run AND no kept entry
            # changed shape, we have no DOM work — and emitting an
            # `irid-mutate` here detaches every child range into a
            # fragment client-side just to re-insert it, which kills
            # focus on any focused input inside.
            if (identical(new_keys, old_keys) &&
                length(shape_changed_keys) == 0L) {
              return()
            }

            if (anyDuplicated(new_keys)) {
              stop("Each() requires unique keys from the `by` function",
                   call. = FALSE)
            }

            # Shape-changed kept keys are promoted to remove + add so
            # the entry gets a fresh scope, accessor, and DOM range
            # built against its new shape.
            removed_keys <- c(setdiff(old_keys, new_keys), shape_changed_keys)
            added_keys <- c(setdiff(new_keys, old_keys), shape_changed_keys)
            kept_keys <- setdiff(
              intersect(new_keys, old_keys), shape_changed_keys
            )

            removes <- character(0)
            for (key in removed_keys) {
              teardown_entry(env$item_mounts[[key]])
              removes <- c(removes, env$item_mounts[[key]]$wrapper_id)
              env$item_mounts[[key]] <- NULL
            }

            inserts <- list()
            for (key in added_keys) local({
              k <- key
              idx <- match(k, new_keys)
              entry <- build_entry(k, idx, item_list[[idx]])
              inserts[[length(inserts) + 1L]] <<- as.character(
                entry$processed$tag
              )
              env$item_mounts[[k]] <- entry
            })

            order <- vapply(new_keys, function(key) {
              env$item_mounts[[key]]$wrapper_id
            }, character(1L), USE.NAMES = FALSE)

            session$sendCustomMessage("irid-mutate", list(
              id = cf_id,
              removes = as.list(removes),
              inserts = inserts,
              order = as.list(order)
            ))

            for (key in added_keys) {
              entry <- env$item_mounts[[key]]
              entry$mount <- irid_mount_processed(
                entry$processed, session, depth = depth + 1L
              )
              entry$processed <- NULL
              env$item_mounts[[key]] <- entry
            }

            # Live position fires for any kept item whose slot moved.
            for (key in kept_keys) {
              new_idx <- match(key, new_keys)
              env$item_mounts[[key]]$pos_rv(new_idx)
            }

            env$current_keys <- new_keys

          } else {
            # Positional mode. Slot i is slot i for as long as it lives;
            # in-place value changes propagate via each slot accessor's
            # internal observer (no DOM work here). Length changes
            # append/destroy at the tail. A surviving slot whose value
            # changed shape is torn down and rebuilt in place — same
            # DOM mutate as length changes, but with `order` so the
            # client knows where the new range belongs.
            new_len <- length(item_list)
            old_len <- length(env$item_mounts)
            common_len <- min(new_len, old_len)

            shape_changed <- integer(0)
            for (i in seq_len(common_len)) {
              new_sig <- shape_signature(item_list[[i]])
              if (!identical(
                new_sig, env$item_mounts[[i]]$shape_sig
              )) {
                shape_changed <- c(shape_changed, i)
              }
            }

            if (new_len == old_len && length(shape_changed) == 0L) {
              # Pure value-change — slot accessors handle it. No DOM work.
              return()
            }

            # Tear down: trailing trim (if shrunk) + shape-changed slots.
            trim_indices <- if (new_len < old_len) {
              (new_len + 1L):old_len
            } else {
              integer(0)
            }
            removes <- character(0)
            for (i in c(trim_indices, shape_changed)) {
              teardown_entry(env$item_mounts[[i]])
              removes <- c(removes, env$item_mounts[[i]]$wrapper_id)
            }
            # Drop trimmed entries; shape-changed slots are overwritten
            # below by their rebuilt entries (same index).
            if (length(trim_indices) > 0L) {
              env$item_mounts <- env$item_mounts[seq_len(new_len)]
            }

            # Build: new tail appends + shape-changed replacements.
            grow_indices <- if (new_len > old_len) {
              (old_len + 1L):new_len
            } else {
              integer(0)
            }
            build_indices <- c(grow_indices, shape_changed)
            inserts <- list()
            for (i in build_indices) local({
              ii <- i
              entry <- build_entry(ii, ii, item_list[[ii]])
              inserts[[length(inserts) + 1L]] <<- as.character(
                entry$processed$tag
              )
              env$item_mounts[[ii]] <- entry
            })

            msg <- list(id = cf_id)
            if (length(removes) > 0L) msg$removes <- as.list(removes)
            if (length(inserts) > 0L) msg$inserts <- inserts
            # `order` is required when shape changes happen mid-list —
            # tail appends and trims are positional by construction, but
            # a rebuilt mid-slot has a new wrapper_id that the client
            # needs to position. Send the full ordering whenever any
            # shape change occurred; tail-only changes still don't need
            # it (and skipping keeps the wire payload minimal).
            if (length(shape_changed) > 0L) {
              msg$order <- as.list(vapply(
                seq_len(new_len),
                function(i) env$item_mounts[[i]]$wrapper_id,
                character(1L)
              ))
            }
            session$sendCustomMessage("irid-mutate", msg)

            # Mount new entries (after DOM exists).
            for (i in build_indices) {
              entry <- env$item_mounts[[i]]
              entry$mount <- irid_mount_processed(
                entry$processed, session, depth = depth + 1L
              )
              entry$processed <- NULL
              env$item_mounts[[i]] <- entry
            }
          }
        })
        observers[[length(observers) + 1L]] <<- obs
        cf_envs[[length(cf_envs) + 1L]] <<- env
      })

    } else if (cf$type == "match") {
      local({
        current_mount <- NULL
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
            session$sendCustomMessage("irid-swap", list(
              id = cf_id, html = ""
            ))
            return()
          }

          case <- cf_cases[[active_idx]]
          body <- case$body
          n_body <- length(formals(body))

          scope <- make_scope(session)
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

          tag_tree <- if (n_body == 0L) body() else body(binding)

          processed <- process_tags(tag_tree, counter = counter)
          session$sendCustomMessage("irid-swap", list(
            id = cf_id,
            html = as.character(processed$tag)
          ))
          env$current_mount <- irid_mount_processed(
            processed, session, depth = depth + 1L
          )
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
        # shiny#4372: per-case scope teardown — replaced by subdomain cascade.
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
