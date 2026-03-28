#' Test whether a value is a nacre-reactive function
#'
#' Returns `TRUE` for plain functions, Shiny reactives, and rate-limited
#' handlers created by [event_throttle()] or [event_debounce()].
#'
#' @param x An object to test.
#' @return Logical.
#' @keywords internal
is_nacre_reactive <- function(x) {
  is.function(x) && (identical(class(x), "function") || inherits(x, "reactive") ||
    inherits(x, "nacre_event"))
}

#' Create a local ID counter for use within a single `process_tags` call
#'
#' @return A function that returns the next ID each time it is called.
#' @keywords internal
nacre_id_counter <- function() {
  value <- 0L
  function() {
    value <<- value + 1L
    paste0("nacre-", value)
  }
}

#' Walk a tag tree and extract reactive bindings
#'
#' Recursively walks an HTML tag tree, replacing reactive attributes and
#' event handlers with plain IDs. Returns the cleaned tag along with lists
#' of bindings, events, control-flow nodes, and Shiny outputs to be mounted
#' by [nacre_mount_processed()].
#'
#' @param tag A Shiny tag, tag list, or nacre control-flow node.
#' @return A list with elements `$tag`, `$bindings`, `$events`,
#'   `$control_flows`, and `$shiny_outputs`.
#' @keywords internal
process_tags <- function(tag, counter = nacre_id_counter()) {
  next_id <- counter
  bindings <- list()
  events <- list()
  control_flows <- list()
  shiny_outputs <- list()

  walk <- function(node) {
    if (is.null(node)) return(NULL)

    if (inherits(node, "nacre_output")) {
      id <- next_id()
      shiny_outputs[[length(shiny_outputs) + 1L]] <<- list(
        id = id,
        render_call = node$render_call
      )
      return(do.call(node$output_fn, c(list(id), node$output_fn_args)))
    }

    if (inherits(node, "nacre_each") || inherits(node, "nacre_index")) {
      id <- next_id()
      type <- if (inherits(node, "nacre_each")) "each" else "index"
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = type, id = id,
        items = node$items, fn = node$fn
      )
      return(tags$div(id = id, style = "display:contents"))
    }

    if (inherits(node, "nacre_match")) {
      id <- next_id()
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = "match", id = id,
        cases = node$cases
      )
      return(tags$div(id = id, style = "display:contents"))
    }

    if (inherits(node, "nacre_when")) {
      id <- next_id()
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = "when", id = id,
        condition = node$condition,
        yes = node$yes,
        otherwise = node$otherwise
      )
      return(tags$div(id = id, style = "display:contents"))
    }

    if (is.function(node) && is_nacre_reactive(node)) {
      id <- next_id()
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
        # Wrap bare functions in event_immediate()
        if (!inherits(val, "nacre_event")) {
          val <- event_immediate(val)
        }
        handler <- structure(val, class = "function",
                             mode = NULL, ms = NULL, leading = NULL,
                             coalesce = NULL, prevent_default = NULL)
        pending_events[[length(pending_events) + 1L]] <- list(
          event = js_event, handler = handler,
          mode = attr(val, "mode"), ms = attr(val, "ms"),
          leading = attr(val, "leading"), coalesce = attr(val, "coalesce"),
          prevent_default = attr(val, "prevent_default")
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
  list(tag = cleaned_tag, bindings = bindings, events = events,
       control_flows = control_flows, shiny_outputs = shiny_outputs,
       counter = counter)
}

#' nacre JavaScript dependency
#'
#' Returns an [htmltools::htmlDependency()] for the client-side nacre
#' runtime (`nacre.js`).
#'
#' @return An `html_dependency` object.
#' @keywords internal
nacre_dependency <- function() {
  htmltools::htmlDependency(
    name = "nacre",
    version = "0.0.1",
    src = system.file("js", package = "nacre"),
    script = "nacre.js"
  )
}
