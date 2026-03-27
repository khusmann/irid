nacre_mount <- function(tag_tree, session) {
  result <- process_tags(tag_tree)
  nacre_mount_processed(result, session)
}

nacre_mount_processed <- function(result, session) {
  observers <- list()

  # Set up event listeners
  if (length(result$events) > 0L) {
    event_msgs <- lapply(result$events, function(ev) {
      input_id <- paste0("nacre_ev_", ev$id, "_", ev$event)
      handler <- ev$handler
      nformals <- length(formals(handler))

      obs <- observeEvent(session$input[[input_id]], {
        ev_data <- session$input[[input_id]]
        if (nformals == 0L) {
          handler()
        } else if (nformals == 1L) {
          handler(ev_data$value)
        } else {
          handler(ev_data$value, ev_data$id)
        }
      }, ignoreInit = TRUE)
      observers[[length(observers) + 1L]] <<- obs

      list(
        id = ev$id,
        event = ev$event,
        inputId = session$ns(input_id)
      )
    })
    session$sendCustomMessage("nacre-events", event_msgs)
  }

  # Set up reactive attribute bindings
  lapply(result$bindings, function(b) {
    obs <- observe({
      val <- b$fn()
      session$sendCustomMessage("nacre-attr", list(
        id = b$id,
        attr = b$attr,
        value = val
      ))
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
        cf_id <- cf$id
        cf_condition <- cf$condition
        cf_yes <- cf$yes
        cf_otherwise <- cf$otherwise
        env <- environment()

        obs <- observe({
          active <- isTRUE(cf_condition())
          branch <- if (active) cf_yes else cf_otherwise

          # Destroy previous branch
          if (!is.null(env$current_mount)) {
            env$current_mount$destroy()
            env$current_mount <- NULL
          }

          if (!is.null(branch)) {
            processed <- process_tags(branch)

            # Swap first so elements exist in DOM
            session$sendCustomMessage("nacre-swap", list(
              id = cf_id,
              html = as.character(processed$tag)
            ))

            # Then mount observers/events
            env$current_mount <- nacre_mount_processed(
              processed, session
            )
          } else {
            session$sendCustomMessage("nacre-swap", list(
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
        current_mount <- NULL
        cf_id <- cf$id
        cf_items <- cf$items
        cf_fn <- cf$fn
        env <- environment()

        obs <- observe({
          item_list <- cf_items()

          # Destroy previous render
          if (!is.null(env$current_mount)) {
            env$current_mount$destroy()
            env$current_mount <- NULL
          }

          if (length(item_list) > 0L) {
            # Build tag list by calling fn for each item
            children <- lapply(seq_along(item_list), function(i) {
              item_val <- item_list[[i]]
              item_fn <- function() item_val
              cf_fn(item_fn, i)
            })
            tag_list <- tagList(children)
            processed <- process_tags(tag_list)

            session$sendCustomMessage("nacre-swap", list(
              id = cf_id,
              html = as.character(processed$tag)
            ))
            env$current_mount <- nacre_mount_processed(processed, session)
          } else {
            session$sendCustomMessage("nacre-swap", list(
              id = cf_id,
              html = ""
            ))
          }
        })
        observers[[length(observers) + 1L]] <<- obs
        cf_envs[[length(cf_envs) + 1L]] <<- env
      })

    } else if (cf$type == "index") {
      local({
        current_mount <- NULL
        slots <- list()  # list of reactiveVal, one per position
        cf_id <- cf$id
        cf_items <- cf$items
        cf_fn <- cf$fn
        env <- environment()

        obs <- observe({
          item_list <- cf_items()
          new_len <- length(item_list)
          old_len <- length(env$slots)

          if (new_len != old_len) {
            # Length changed — rebuild entirely
            if (!is.null(env$current_mount)) {
              env$current_mount$destroy()
              env$current_mount <- NULL
            }

            env$slots <- lapply(seq_len(new_len), function(i) {
              reactiveVal(item_list[[i]])
            })

            if (new_len > 0L) {
              children <- lapply(seq_along(env$slots), function(i) {
                cf_fn(env$slots[[i]], i)
              })
              tag_list <- tagList(children)
              processed <- process_tags(tag_list)

              session$sendCustomMessage("nacre-swap", list(
                id = cf_id,
                html = as.character(processed$tag)
              ))
              env$current_mount <- nacre_mount_processed(processed, session)
            } else {
              session$sendCustomMessage("nacre-swap", list(
                id = cf_id,
                html = ""
              ))
            }
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

          # Destroy previous branch
          if (!is.null(env$current_mount)) {
            env$current_mount$destroy()
            env$current_mount <- NULL
          }

          if (!is.null(branch)) {
            processed <- process_tags(branch)
            session$sendCustomMessage("nacre-swap", list(
              id = cf_id,
              html = as.character(processed$tag)
            ))
            env$current_mount <- nacre_mount_processed(processed, session)
          } else {
            session$sendCustomMessage("nacre-swap", list(
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
        if (!is.null(env$current_mount)) env$current_mount$destroy()
      }
    }
  )
}
