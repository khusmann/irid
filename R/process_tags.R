#' Test whether a value is a irid-reactive function
#'
#' Returns `TRUE` for any callable irid treats as reactive — plain
#' functions, Shiny reactives, store nodes/leaves, and `reactiveProxy`
#' wrappers. Used by [process_tags()] to decide which attributes participate
#' in auto-bind / event extraction.
#'
#' @param x An object to test.
#' @return Logical.
#' @keywords internal
is_irid_reactive <- function(x) {
  is.function(x) && (identical(class(x), "function") || inherits(x, "reactive"))
}

# DOM events synthesised for state-binding props
STATE_BIND_EVENT <- list(
  value = "input",
  checked = "change",
  selected = "change"
)

# The field on the event object the synthetic write-back reads from
STATE_BIND_FIELD <- list(
  value = "value",
  checked = "checked",
  selected = "value"
)

# Build the synthetic write-back handler for a state-binding prop. Arity
# of the user's callable selects between write (>= 1 formal — `reactiveVal`,
# store leaf, `reactiveProxy`, branch, `\(v) ...`) and no-op (0 formals —
# `\() expr()`, `reactive()`). Read-only callables still receive a listener
# so the value reaches the server, where the no-op write combined with the
# force-send-on-no-op protocol echoes the current value back, snapping the
# input to whatever the server holds.
make_autobind_handler <- function(fn, attr_name) {
  field <- STATE_BIND_FIELD[[attr_name]]
  if (length(formals(fn)) >= 1L) {
    function(e) fn(e[[field]])
  } else {
    function(e) NULL
  }
}

# Resolve the `irid_event_config` that applies to a single event entry.
# Element-level `.event` wins (named-list per-event > single config struct);
# otherwise fall back to the per-event default (auto-bind synthetic →
# debounce 200ms, anything else → immediate).
resolve_event_config <- function(event_name, autobind_origin, element_event) {
  if (!is.null(element_event)) {
    if (inherits(element_event, "irid_event_config")) {
      return(element_event)
    }
    if (is.list(element_event) && !is.null(names(element_event)) &&
        event_name %in% names(element_event)) {
      cfg <- element_event[[event_name]]
      if (inherits(cfg, "irid_event_config")) return(cfg)
    }
  }
  if (autobind_origin) event_debounce(200) else event_immediate()
}

#' Create a pair of HTML comment anchors bracketing a control-flow range
#'
#' Comment nodes are legal children of any element (including `<select>`,
#' `<table>`, `<tbody>`, etc.) so they serve as invisible range markers
#' that the client can use to locate and mutate content without needing a
#' wrapper element.
#'
#' @param id The control-flow node ID.
#' @return An [htmltools::HTML()] fragment containing the start/end markers.
#' @keywords internal
anchor_pair <- function(id) {
  htmltools::HTML(paste0("<!--irid:s:", id, "--><!--irid:e:", id, "-->"))
}

#' Create a local ID counter for use within a single `process_tags` call
#'
#' @return A function that returns the next ID each time it is called.
#' @keywords internal
irid_id_counter <- function(prefix = "irid") {
  value <- 0L
  function() {
    value <<- value + 1L
    paste0(prefix, "-", value)
  }
}

#' Walk a tag tree and extract reactive bindings
#'
#' Recursively walks an HTML tag tree, replacing reactive attributes and
#' event handlers with plain IDs. Returns the cleaned tag along with lists
#' of bindings, events, control-flow nodes, and Shiny outputs to be mounted
#' by [irid_mount_processed()].
#'
#' @param tag A Shiny tag, tag list, or irid control-flow node.
#' @return A list with elements `$tag`, `$bindings`, `$events`,
#'   `$control_flows`, and `$shiny_outputs`.
#' @keywords internal
process_tags <- function(tag, counter = irid_id_counter()) {
  next_id <- counter
  bindings <- list()
  events <- list()
  control_flows <- list()
  shiny_outputs <- list()

  walk <- function(node) {
    if (is.null(node)) return(NULL)

    if (inherits(node, "irid_output")) {
      id <- next_id()
      shiny_outputs[[length(shiny_outputs) + 1L]] <<- list(
        id = id,
        render_call = node$render_call
      )
      return(do.call(node$output_fn, c(list(id), node$output_fn_args)))
    }

    if (inherits(node, "irid_each") || inherits(node, "irid_index")) {
      id <- next_id()
      type <- if (inherits(node, "irid_each")) "each" else "index"
      cf_entry <- list(type = type, id = id, items = node$items, fn = node$fn)
      if (type == "each") cf_entry$by <- node$by
      control_flows[[length(control_flows) + 1L]] <<- cf_entry
      return(anchor_pair(id))
    }

    if (inherits(node, "irid_match")) {
      id <- next_id()
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = "match", id = id,
        cases = node$cases
      )
      return(anchor_pair(id))
    }

    if (inherits(node, "irid_when")) {
      id <- next_id()
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = "when", id = id,
        condition = node$condition,
        yes = node$yes,
        otherwise = node$otherwise
      )
      return(anchor_pair(id))
    }

    if (is.function(node) && is_irid_reactive(node)) {
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

    # Element-level event config and prevent_default — strip before the
    # per-attribute loop so they never reach the HTML output.
    element_event <- attribs[[".event"]]
    element_prevent_default <- isTRUE(attribs[[".prevent_default"]])
    attribs[[".event"]] <- NULL
    attribs[[".prevent_default"]] <- NULL

    kept_attribs <- list()
    pending_bindings <- list()
    pending_events <- list()

    for (name in names(attribs)) {
      val <- attribs[[name]]

      # Auto-bind: state-binding prop with a callable. Emit both a binding
      # (server → client read path) and a synthetic event entry (client →
      # server write path). The synthetic handler is arity-dispatched —
      # 0-arg callables get a no-op handler; the listener still fires so
      # the optimistic-update protocol can snap the input back.
      if (name %in% names(STATE_BIND_EVENT) && is_irid_reactive(val)) {
        pending_bindings[[length(pending_bindings) + 1L]] <- list(
          attr = name, fn = val
        )
        pending_events[[length(pending_events) + 1L]] <- list(
          event = STATE_BIND_EVENT[[name]],
          handler = make_autobind_handler(val, name),
          autobind = TRUE
        )
        next
      }

      if (!is_irid_reactive(val)) {
        kept_attribs[[name]] <- val
        next
      }

      is_event <- grepl("^on[A-Z]", name)

      if (is_event) {
        js_event <- tolower(sub("^on", "", name))
        pending_events[[length(pending_events) + 1L]] <- list(
          event = js_event, handler = val, autobind = FALSE
        )
      } else {
        pending_bindings[[length(pending_bindings) + 1L]] <- list(
          attr = name, fn = val
        )
      }
    }

    # Resolve timing per event entry (element-level .event > per-event
    # default rule) and propagate .prevent_default to every entry.
    for (i in seq_along(pending_events)) {
      e <- pending_events[[i]]
      cfg <- resolve_event_config(e$event, e$autobind, element_event)
      pending_events[[i]]$mode <- cfg$mode
      pending_events[[i]]$ms <- cfg$ms
      pending_events[[i]]$leading <- cfg$leading
      pending_events[[i]]$coalesce <- cfg$coalesce
      pending_events[[i]]$prevent_default <- element_prevent_default
      pending_events[[i]]$autobind <- NULL
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

#' irid JavaScript dependency
#'
#' Returns an [htmltools::htmlDependency()] for the client-side irid
#' runtime (`irid.js`).
#'
#' @return An `html_dependency` object.
#' @keywords internal
irid_dependency <- function() {
  htmltools::htmlDependency(
    name = "irid",
    version = "0.0.1",
    src = system.file("js", package = "irid"),
    script = "irid.js",
    stylesheet = "irid.css"
  )
}
