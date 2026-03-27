is_nacre_reactive <- function(x) {
  is.function(x) && (identical(class(x), "function") || inherits(x, "reactive"))
}

nacre_id_counter <- new.env(parent = emptyenv())
nacre_id_counter$value <- 0L

nacre_next_id <- function() {
  nacre_id_counter$value <- nacre_id_counter$value + 1L
  paste0("nacre-", nacre_id_counter$value)
}

process_tags <- function(tag) {
  bindings <- list()
  events <- list()
  control_flows <- list()
  shiny_outputs <- list()

  walk <- function(node) {
    if (is.null(node)) return(NULL)

    if (inherits(node, "shiny_output")) {
      shiny_outputs[[length(shiny_outputs) + 1L]] <<- list(
        id = node$id,
        render_call = node$render_call
      )
      return(node$output_tag)
    }

    if (inherits(node, "nacre_each") || inherits(node, "nacre_index")) {
      id <- nacre_next_id()
      type <- if (inherits(node, "nacre_each")) "each" else "index"
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = type, id = id,
        items = node$items, fn = node$fn
      )
      return(tags$div(id = id, style = "display:contents"))
    }

    if (inherits(node, "nacre_match")) {
      id <- nacre_next_id()
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = "match", id = id,
        cases = node$cases
      )
      return(tags$div(id = id, style = "display:contents"))
    }

    if (inherits(node, "nacre_when")) {
      id <- nacre_next_id()
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = "when", id = id,
        condition = node$condition,
        yes = node$yes,
        otherwise = node$otherwise
      )
      return(tags$div(id = id, style = "display:contents"))
    }

    if (is.function(node) && is_nacre_reactive(node)) {
      id <- nacre_next_id()
      bindings[[length(bindings) + 1L]] <<- list(
        id = id, attr = "textContent", fn = node
      )
      return(tags$span(id = id))
    }

    if (is.list(node) && !inherits(node, "shiny.tag") &&
        !inherits(node, "html_dependency")) {
      result <- lapply(node, walk)
      if (inherits(node, "shiny.tag.list")) {
        class(result) <- class(node)
      }
      return(result)
    }

    if (!inherits(node, "shiny.tag")) return(node)

    attribs <- node$attribs
    kept_attribs <- list()
    pending_bindings <- list()
    pending_events <- list()

    for (name in names(attribs)) {
      val <- attribs[[name]]
      if (!is_nacre_reactive(val)) {
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
      id <- if (!is.null(kept_attribs$id)) kept_attribs$id else nacre_next_id()
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
  list(tag = cleaned_tag, bindings = bindings, events = events,
       control_flows = control_flows, shiny_outputs = shiny_outputs)
}
