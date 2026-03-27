nacre_id_generator <- function() {
  counter <- 0L
  function() {
    counter <<- counter + 1L
    paste0("nacre-", counter)
  }
}

process_tags <- function(tag, next_id) {
  bindings <- list()
  events <- list()

  walk <- function(node) {
    if (is.function(node)) {
      id <- next_id()
      bindings[[length(bindings) + 1L]] <<- list(
        id = id, attr = "textContent", fn = node
      )
      return(tags$span(id = id))
    }

    if (!inherits(node, "shiny.tag")) return(node)

    attribs <- node$attribs
    kept_attribs <- list()
    pending_bindings <- list()
    pending_events <- list()

    for (name in names(attribs)) {
      val <- attribs[[name]]
      if (!is.function(val)) {
        kept_attribs[[name]] <- val
        next
      }

      is_event <- grepl("^on[A-Z]", name)

      if (is_event) {
        js_event <- tolower(sub("^on", "", name))
        pending_events[[length(pending_events) + 1L]] <- list(
          event = js_event, handler = val
        )
      } else {
        pending_bindings[[length(pending_bindings) + 1L]] <- list(
          attr = name, fn = val
        )
      }
    }

    if (length(pending_bindings) > 0L || length(pending_events) > 0L) {
      id <- if (!is.null(kept_attribs$id)) kept_attribs$id else next_id()
      kept_attribs$id <- id

      for (b in pending_bindings) {
        b$id <- id
        bindings[[length(bindings) + 1L]] <<- b
      }
      for (e in pending_events) {
        e$id <- id
        events[[length(events) + 1L]] <<- e
      }
    }

    new_children <- lapply(node$children, walk)

    node$attribs <- kept_attribs
    node$children <- new_children
    node
  }

  cleaned_tag <- walk(tag)
  list(tag = cleaned_tag, bindings = bindings, events = events)
}
