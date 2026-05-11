#' Mount a pre-processed irid tag tree
#'
#' Takes the output of [process_tags()] and wires up Shiny observers for
#' reactive attribute bindings, event listeners, Shiny outputs, and
#' control-flow nodes (`When`, `Each`, `Match`).
#'
#' @param result A list returned by [process_tags()], containing `$tag`,
#'   `$bindings`, `$events`, `$control_flows`, and `$shiny_outputs`.
#' @param session A Shiny session object.
#' @return A mount handle with `$tag` (the processed HTML) and `$destroy()`
#'   (a function that tears down all observers).
#' @keywords internal
irid_mount_processed <- function(result, session) {
  counter <- result$counter
  observers <- list()

  # Index bindings by element ID so event handlers can force-send
  # the authoritative value even when the reactive is a no-op.
  bindings_by_id <- list()
  for (b in result$bindings) {
    bindings_by_id[[b$id]] <- c(bindings_by_id[[b$id]], list(b))
  }

  # Set up event listeners
  if (length(result$events) > 0L) {
    event_msgs <- lapply(result$events, function(ev) {
      input_id <- paste0("irid_ev_", ev$id, "_", ev$event)
      handler <- ev$handler
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
        source_id <- ev_data[["id"]]
        source_bindings <- bindings_by_id[[source_id]]
        if (!is.null(seq) && length(source_bindings) > 0L) {
          for (sb in source_bindings) {
            val <- isolate(sb$fn())
            msg <- list(id = sb$id, attr = sb$attr, value = val,
                        sequence = seq)
            session$sendCustomMessage("irid-attr", msg)
          }
        }
      }, ignoreInit = TRUE)
      observers[[length(observers) + 1L]] <<- obs

      list(
        id = ev$id,
        event = ev$event,
        inputId = session$ns(input_id),
        mode = ev$mode,
        ms = ev$ms,
        leading = ev$leading,
        coalesce = ev$coalesce,
        preventDefault = ev$prevent_default
      )
    })
    session$sendCustomMessage("irid-events", event_msgs)
  }

  # Set up reactive attribute bindings
  lapply(result$bindings, function(b) {
    obs <- observe({
      val <- b$fn()
      msg <- list(id = b$id, attr = b$attr, value = val)
      seq_info <- session$userData$irid_current_sequence
      if (!is.null(seq_info) && seq_info$source == b$id) {
        msg$sequence <- seq_info$seq
      }
      session$sendCustomMessage("irid-attr", msg)
    })
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
              processed, session
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
        #   processed (transient — cleared after mount).
        item_mounts <- list()
        current_keys <- character(0)
        shape_locked <- FALSE
        is_record_shape <- NULL
        env <- environment()

        # Build accessor + tag tree + mount entry for one item. `key_or_idx`
        # is the storage key in `item_mounts`; `slot_index` is the initial
        # 1-indexed position used to seed `pos_rv`. For positional mode
        # both are the same integer; for keyed mode the storage key is
        # the stringified `by(item)`.
        build_entry <- function(key_or_idx, slot_index) {
          wrapper_id <- counter()
          scope <- make_scope(session)

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

          accessor <- if (env$is_record_shape) {
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
            HTML(paste0("<!--irid:s:", wrapper_id, "-->")),
            child,
            HTML(paste0("<!--irid:e:", wrapper_id, "-->"))
          )
          processed <- process_tags(wrapped, counter = counter)

          list(
            scope = scope, mount = NULL, wrapper_id = wrapper_id,
            accessor = accessor, pos_rv = pos_rv,
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

          # Lock item shape (record vs scalar) on the first non-empty
          # observation. A slot's accessor is built around one shape and
          # cannot switch — mixed-shape lists are the caller's
          # responsibility (every item must match the first).
          if (!env$shape_locked && length(item_list) > 0L) {
            env$is_record_shape <- is_record(item_list[[1L]])
            env$shape_locked <- TRUE
          }

          if (keyed) {
            new_keys <- vapply(
              item_list,
              function(x) as.character(cf_by(x)),
              character(1L)
            )
            old_keys <- env$current_keys

            # Pure value-change short-circuit. The observer fires on any
            # change to the parent collection (including in-place value
            # edits), but the per-item mini-store / scalar-accessor
            # propagators handle in-place changes themselves. If the
            # keys are identical to the previous run, we have no DOM
            # work — and emitting an `irid-mutate` here detaches every
            # child range into a fragment client-side just to re-insert
            # it, which kills focus on any focused input inside.
            # Short-circuit first so unchanged keys also skip the
            # duplicate check (already validated on a prior reconcile).
            if (identical(new_keys, old_keys)) return()

            if (anyDuplicated(new_keys)) {
              stop("Each() requires unique keys from the `by` function",
                   call. = FALSE)
            }

            removed_keys <- setdiff(old_keys, new_keys)
            added_keys <- setdiff(new_keys, old_keys)
            kept_keys <- intersect(new_keys, old_keys)

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
              entry <- build_entry(k, idx)
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
              entry$mount <- irid_mount_processed(entry$processed, session)
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
            # append/destroy at the tail.
            new_len <- length(item_list)
            old_len <- length(env$item_mounts)

            if (new_len < old_len) {
              removes <- character(0)
              for (i in (new_len + 1L):old_len) {
                teardown_entry(env$item_mounts[[i]])
                removes <- c(removes, env$item_mounts[[i]]$wrapper_id)
              }
              env$item_mounts <- env$item_mounts[seq_len(new_len)]
              session$sendCustomMessage("irid-mutate", list(
                id = cf_id,
                removes = as.list(removes)
              ))
            } else if (new_len > old_len) {
              inserts <- list()
              for (i in (old_len + 1L):new_len) local({
                ii <- i
                entry <- build_entry(ii, ii)
                inserts[[length(inserts) + 1L]] <<- as.character(
                  entry$processed$tag
                )
                env$item_mounts[[ii]] <- entry
              })
              session$sendCustomMessage("irid-mutate", list(
                id = cf_id,
                inserts = inserts
              ))
              for (i in (old_len + 1L):new_len) {
                entry <- env$item_mounts[[i]]
                entry$mount <- irid_mount_processed(entry$processed, session)
                entry$processed <- NULL
                env$item_mounts[[i]] <- entry
              }
            }
            # Same length: nothing to do — slot accessors' internal
            # observers handle in-place value changes.
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
          env$current_mount <- irid_mount_processed(processed, session)
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
