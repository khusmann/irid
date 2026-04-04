#' Mount a pre-processed irid tag tree
#'
#' Takes the output of [process_tags()] and wires up Shiny observers for
#' reactive attribute bindings, event listeners, Shiny outputs, and
#' control-flow nodes (`When`, `Each`, `Index`, `Match`).
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

          branch <- if (active) cf_yes else cf_otherwise

          # Destroy previous branch
          if (!is.null(env$current_mount)) {
            env$current_mount$destroy()
            env$current_mount <- NULL
          }

          if (!is.null(branch)) {
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
        # Per-item state: named list keyed by item key.
        # Each entry: list(mount, wrapper_id, index_rv)
        item_mounts <- list()
        current_keys <- character(0)
        cf_id <- cf$id
        cf_items <- cf$items
        cf_fn <- cf$fn
        cf_by <- cf$by
        cf_nformals <- length(formals(cf_fn))
        env <- environment()

        obs <- observe({
          item_list <- cf_items()
          new_keys <- vapply(item_list, function(x) as.character(cf_by(x)), character(1))
          if (anyDuplicated(new_keys)) {
            stop("Each() requires unique keys from the `by` function")
          }
          old_keys <- env$current_keys

          removed_keys <- setdiff(old_keys, new_keys)
          added_keys <- setdiff(new_keys, old_keys)
          kept_keys <- intersect(new_keys, old_keys)

          # Destroy removed items
          removes <- character(0)
          for (key in removed_keys) {
            env$item_mounts[[key]]$mount$destroy()
            removes <- c(removes, env$item_mounts[[key]]$wrapper_id)
            env$item_mounts[[key]] <- NULL
          }

          # Create new items (local() prevents for-loop closure capture)
          inserts <- list()
          for (key in added_keys) local({
            k <- key
            idx <- match(k, new_keys)
            item <- item_list[[idx]]
            wrapper_id <- counter()

            index_rv <- reactiveVal(idx)
            child <- if (cf_nformals >= 2L) cf_fn(item, index_rv) else cf_fn(item)
            wrapped <- tags$div(id = wrapper_id, style = "display:contents", child)
            processed <- process_tags(wrapped, counter = counter)

            inserts[[length(inserts) + 1L]] <<- as.character(processed$tag)
            env$item_mounts[[k]] <- list(
              mount = NULL, wrapper_id = wrapper_id,
              index_rv = index_rv, processed = processed
            )
          })

          # Build order array
          order <- vapply(new_keys, function(key) {
            env$item_mounts[[key]]$wrapper_id
          }, character(1), USE.NAMES = FALSE)

          # Send DOM mutation
          session$sendCustomMessage("irid-mutate", list(
            id = cf_id,
            removes = as.list(removes),
            inserts = inserts,
            order = as.list(order)
          ))

          # Mount new items (after DOM exists)
          for (key in added_keys) {
            entry <- env$item_mounts[[key]]
            entry$mount <- irid_mount_processed(entry$processed, session)
            entry$processed <- NULL
            env$item_mounts[[key]] <- entry
          }

          # Update index reactiveVals for kept items whose position changed
          for (key in kept_keys) {
            new_idx <- match(key, new_keys)
            env$item_mounts[[key]]$index_rv(new_idx)
          }

          env$current_keys <- new_keys
        })
        observers[[length(observers) + 1L]] <<- obs
        cf_envs[[length(cf_envs) + 1L]] <<- env
      })

    } else if (cf$type == "index") {
      local({
        # Per-slot state: parallel lists
        slots <- list()       # reactiveVal per position
        slot_mounts <- list() # mount handle per position
        slot_wrapper_ids <- character(0)
        cf_id <- cf$id
        cf_items <- cf$items
        cf_fn <- cf$fn
        cf_nformals <- length(formals(cf_fn))
        env <- environment()

        obs <- observe({
          item_list <- cf_items()
          new_len <- length(item_list)
          old_len <- length(env$slots)

          if (new_len > old_len) {
            # Grow — update existing slots, append new ones
            for (i in seq_len(old_len)) {
              env$slots[[i]](item_list[[i]])
            }

            # local() prevents for-loop closure capture
            inserts <- list()
            for (i in (old_len + 1L):new_len) local({
              ii <- i
              rv <- reactiveVal(item_list[[ii]])
              wrapper_id <- counter()

              child <- if (cf_nformals >= 2L) cf_fn(rv, ii) else cf_fn(rv)
              wrapped <- tags$div(id = wrapper_id, style = "display:contents", child)
              processed <- process_tags(wrapped, counter = counter)

              inserts[[length(inserts) + 1L]] <<- as.character(processed$tag)
              env$slots[[ii]] <- rv
              env$slot_wrapper_ids[[ii]] <- wrapper_id
              # Temporarily store processed for mounting after DOM update
              env$slot_mounts[[ii]] <- processed
            })

            session$sendCustomMessage("irid-mutate", list(
              id = cf_id,
              inserts = inserts
            ))

            # Mount new slots (after DOM exists)
            for (i in (old_len + 1L):new_len) {
              env$slot_mounts[[i]] <- irid_mount_processed(
                env$slot_mounts[[i]], session
              )
            }

          } else if (new_len < old_len) {
            # Shrink — update kept slots, destroy trailing ones
            for (i in seq_len(new_len)) {
              env$slots[[i]](item_list[[i]])
            }

            removes <- env$slot_wrapper_ids[(new_len + 1L):old_len]
            for (i in (new_len + 1L):old_len) {
              env$slot_mounts[[i]]$destroy()
            }

            session$sendCustomMessage("irid-mutate", list(
              id = cf_id,
              removes = as.list(removes)
            ))

            env$slots <- env$slots[seq_len(new_len)]
            env$slot_mounts <- env$slot_mounts[seq_len(new_len)]
            env$slot_wrapper_ids <- env$slot_wrapper_ids[seq_len(new_len)]

          } else {
            # Same length — update slots in place
            for (i in seq_len(new_len)) {
              env$slots[[i]](item_list[[i]])
            }
          }
        })
        observers[[length(observers) + 1L]] <<- obs
        cf_envs[[length(cf_envs) + 1L]] <<- env
      })

    } else if (cf$type == "match") {
      local({
        current_mount <- NULL
        last_branch <- NULL
        cf_id <- cf$id
        cf_cases <- cf$cases
        env <- environment()

        obs <- observe({
          # Find first matching case
          branch <- NULL
          for (case in cf_cases) {
            if (isTRUE(case$condition())) {
              branch <- case$content
              break
            }
          }

          # Short-circuit if the branch hasn't changed
          if (identical(branch, env$last_branch)) return()
          env$last_branch <- branch

          # Destroy previous branch
          if (!is.null(env$current_mount)) {
            env$current_mount$destroy()
            env$current_mount <- NULL
          }

          if (!is.null(branch)) {
            processed <- process_tags(branch, counter = counter)
            session$sendCustomMessage("irid-swap", list(
              id = cf_id,
              html = as.character(processed$tag)
            ))
            env$current_mount <- irid_mount_processed(processed, session)
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
    }
  }

  list(
    tag = result$tag,
    destroy = function() {
      for (obs in observers) obs$destroy()
      for (env in cf_envs) {
        # When/Match: single current_mount
        if (!is.null(env$current_mount)) env$current_mount$destroy()
        # Each: per-key mounts
        if (!is.null(env$item_mounts)) {
          for (m in env$item_mounts) m$mount$destroy()
        }
        # Index: per-slot mounts
        if (!is.null(env$slot_mounts)) {
          for (m in env$slot_mounts) m$destroy()
        }
      }
    }
  )
}
