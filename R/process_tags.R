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

# DOM events synthesised for state-binding props. Prop name doubles as the
# field on the event object the synthetic write-back reads from — irid stays
# close to the DOM IDL, where `value` and `checked` are both the prop and
# the readable property.
STATE_BIND_EVENT <- list(
  value = "input",
  checked = "change"
)

# Can the callable accept a positional argument? Primitives have no
# explicit formals but accept arguments at the C level; closures with at
# least one formal (including `...`) can be called with the write value.
# A 0-formal closure would error if called with an argument.
can_accept_write <- function(fn) {
  is.primitive(fn) || length(formals(fn)) >= 1L
}

# Build the synthetic write-back handler for a state-binding prop.
# Writable callables (reactiveVal, store leaf, reactiveProxy, store node,
# `\(v) ...`, `\(...) ...`, primitives) get a handler that calls
# `fn(e$value/checked)`. Read-only callables (`\() expr()`, `reactive()`)
# get a no-op handler — the listener still fires so the optimistic-update
# protocol echoes the current server value back, snapping the input.
make_autobind_handler <- function(fn, attr_name) {
  force(fn)
  force(attr_name)
  if (can_accept_write(fn)) {
    function(e) fn(e[[attr_name]])
  } else {
    function(e) NULL
  }
}

# Shared validation for element-level keyed-list props (`.event`,
# `.prevent_default`). Checks emptiness, full naming, and duplicate-after-
# normalization, then returns the input list with names normalized to
# lowercase DOM-event form (`onInput` → `input`). Per-entry value
# validation is left to the caller, which has the type information.
normalize_event_keyed_list <- function(x, prop_name) {
  if (length(x) == 0L) {
    stop(
      "`", prop_name, "` list is empty; pass at least one entry, or omit ",
      "`", prop_name, "`",
      call. = FALSE
    )
  }
  nms <- names(x)
  if (is.null(nms) || any(!nzchar(nms))) {
    stop(
      "`", prop_name, "` list must be fully named, keyed by DOM event ",
      "(e.g. `input`, `keydown`) or `on`-prop (e.g. `onInput`)",
      call. = FALSE
    )
  }
  normalized <- tolower(sub("^on", "", nms, ignore.case = TRUE))
  dup <- duplicated(normalized)
  if (any(dup)) {
    stop(
      "`", prop_name, "` has duplicate event names after normalization: ",
      paste(unique(normalized[dup]), collapse = ", "),
      call. = FALSE
    )
  }
  names(x) <- normalized
  x
}

# Validate and normalize an element-level `.event` prop into a lookup
# function: takes a lowercase DOM event name, returns the matching
# `irid_event_config` or NULL. Keys accept either DOM-event form
# (`input`, `keydown`) or `on`-prop form (`onInput`, `onKeyDown`); both
# normalize to lowercase DOM-event names. Errors loudly on malformed
# input rather than silently falling back to defaults.
normalize_element_event <- function(element_event) {
  if (is.null(element_event)) {
    return(function(event_name) NULL)
  }
  if (inherits(element_event, "irid_event_config")) {
    return(function(event_name) element_event)
  }
  # Catch other irid constructs (control-flow nodes, outputs) up front —
  # they're lists too and would otherwise fail with a confusing
  # `.event$<key>` error from the keyed-list path below.
  irid_class <- grep("^irid_", class(element_event), value = TRUE)
  if (length(irid_class) > 0L) {
    stop(
      "`.event` got an irid construct (`",
      paste(irid_class, collapse = "/"),
      "`); these belong as children, not as `.event`",
      call. = FALSE
    )
  }
  if (!is.list(element_event)) {
    stop(
      "`.event` must be an `irid_event_config` (from `event_immediate()`, ",
      "`event_throttle()`, or `event_debounce()`) or a named list of them; ",
      "got ", paste(class(element_event), collapse = "/"),
      call. = FALSE
    )
  }
  orig_nms <- names(element_event)
  element_event <- normalize_event_keyed_list(element_event, ".event")
  for (i in seq_along(element_event)) {
    if (!inherits(element_event[[i]], "irid_event_config")) {
      stop(
        "`.event$", orig_nms[[i]], "` must be an `irid_event_config`; got ",
        paste(class(element_event[[i]]), collapse = "/"),
        call. = FALSE
      )
    }
  }
  function(event_name) element_event[[event_name]]
}

# Validate and normalize an element-level `.prevent_default` prop into a
# lookup function: takes a lowercase DOM event name, returns a logical
# scalar. A scalar `TRUE`/`FALSE` broadcasts to every event on the element;
# a named list (same key shape as `.event`) overrides per event with
# unmapped events defaulting to `FALSE`.
normalize_element_prevent_default <- function(prevent_default) {
  if (is.null(prevent_default)) {
    return(function(event_name) FALSE)
  }
  if (is.logical(prevent_default) && length(prevent_default) == 1L &&
      !is.na(prevent_default)) {
    val <- prevent_default
    return(function(event_name) val)
  }
  # Catch irid constructs up front — `irid_event_config`, control-flow nodes,
  # and outputs are all lists, so the generic keyed-list error below would be
  # misleading.
  irid_class <- grep("^irid_", class(prevent_default), value = TRUE)
  if (length(irid_class) > 0L) {
    stop(
      "`.prevent_default` got an irid construct (`",
      paste(irid_class, collapse = "/"),
      "`); pass `TRUE`/`FALSE` or a named list of logicals",
      call. = FALSE
    )
  }
  if (!is.list(prevent_default)) {
    stop(
      "`.prevent_default` must be `TRUE`/`FALSE` or a named list of ",
      "logicals keyed by DOM event; got ",
      paste(class(prevent_default), collapse = "/"),
      call. = FALSE
    )
  }
  orig_nms <- names(prevent_default)
  prevent_default <- normalize_event_keyed_list(
    prevent_default, ".prevent_default"
  )
  for (i in seq_along(prevent_default)) {
    v <- prevent_default[[i]]
    if (!is.logical(v) || length(v) != 1L || is.na(v)) {
      stop(
        "`.prevent_default$", orig_nms[[i]], "` must be `TRUE` or `FALSE`; ",
        "got ", paste(class(v), collapse = "/"),
        call. = FALSE
      )
    }
  }
  function(event_name) {
    v <- prevent_default[[event_name]]
    if (is.null(v)) FALSE else v
  }
}

# Per-event default timing — the same rule applies whether the event entry
# came from an auto-bind synthetic or an explicit `on*` handler, so adding
# `value = rv` to an existing `onInput` doesn't silently shift its timing.
# Typing produces a flood of `input` events so the bare default is debounce;
# everything else fires once per user action and goes immediate.
default_for_event <- function(event_name) {
  if (event_name == "input") event_debounce(200) else event_immediate()
}

# Resolve the `irid_event_config` for a single event entry. Element-level
# `.event` wins; otherwise fall back to the per-event default.
resolve_event_config <- function(event_name, lookup) {
  cfg <- lookup(event_name)
  if (!is.null(cfg)) return(cfg)
  default_for_event(event_name)
}

# Compose multiple event handlers into a single 2-arg function. Each source
# handler is dispatched by its own arity (0, 1, or 2 formals). Mount sees the
# wrapper as 2-arg and calls it with `(event_obj, id)`; the inner dispatch
# fans out per source handler.
compose_handlers <- function(handlers) {
  arities <- vapply(handlers, function(h) length(formals(h)), integer(1L))
  function(event, id) {
    for (i in seq_along(handlers)) {
      h <- handlers[[i]]
      a <- arities[[i]]
      if (a == 0L) h()
      else if (a == 1L) h(event)
      else h(event, id)
    }
  }
}

# Merge pending events that share a DOM event name (e.g. auto-bind synthetic
# `input` + explicit `onInput` on the same element). One merged entry per
# DOM event means one observer and one JS listener. Within a merged group,
# auto-bind synthetic handlers run before explicit `on*` handlers so an
# explicit handler always observes the new state — cosmetic attribute
# reordering can't change behavior. Within each tier, source order is
# preserved.
merge_pending_events <- function(pending_events) {
  by_event <- list()
  groups <- list()
  for (e in pending_events) {
    idx <- by_event[[e$event]]
    if (is.null(idx)) {
      idx <- length(groups) + 1L
      by_event[[e$event]] <- idx
      groups[[idx]] <- list(
        event = e$event,
        handlers = list(e$handler),
        autobinds = e$autobind
      )
    } else {
      groups[[idx]]$handlers <- c(groups[[idx]]$handlers, list(e$handler))
      groups[[idx]]$autobinds <- c(groups[[idx]]$autobinds, e$autobind)
    }
  }
  lapply(groups, function(g) {
    handlers <- c(g$handlers[g$autobinds], g$handlers[!g$autobinds])
    handler <- if (length(handlers) == 1L) {
      handlers[[1L]]
    } else {
      compose_handlers(handlers)
    }
    list(event = g$event, handler = handler)
  })
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
    # per-attribute loop so they never reach the HTML output. `.event` is
    # validated and normalized into a lookup function up front so any
    # malformed input fails before bindings/events are emitted.
    element_event_lookup <- normalize_element_event(attribs[[".event"]])
    element_prevent_default_lookup <- normalize_element_prevent_default(
      attribs[[".prevent_default"]]
    )
    attribs[[".event"]] <- NULL
    attribs[[".prevent_default"]] <- NULL

    kept_attribs <- list()
    pending_bindings <- list()
    pending_events <- list()

    # Iterate by position rather than `for (name in names(attribs))` —
    # htmltools allows duplicate attribute names (e.g. two `onInput`s on
    # one tag) and `attribs[[name]]` would collapse them all to the first
    # match. Position-indexed access preserves every entry so the merge
    # step can compose them in source order.
    attrib_names <- names(attribs)
    for (i in seq_along(attribs)) {
      name <- attrib_names[[i]]
      val <- attribs[[i]]

      # Catch misuse of irid constructs as attribute values. Without this
      # guard they fall through to `kept_attribs` and get serialized as
      # HTML attributes (or worse, silently coerced). Event configs belong
      # on the element-level `.event` prop; control-flow / output nodes
      # belong as children.
      irid_class <- grep("^irid_", class(val), value = TRUE)
      if (length(irid_class) > 0L) {
        hint <- if ("irid_event_config" %in% irid_class) {
          if (grepl("^on[A-Z]", name)) {
            paste0(
              "`event_*()` returns a timing config, not a handler wrapper. ",
              "Pass the handler directly to `", name, "` and put the config ",
              "on the element-level `.event` prop."
            )
          } else {
            "Event configs belong on the element-level `.event` prop."
          }
        } else {
          paste0(
            "Constructs of class `", irid_class[[1]],
            "` belong as children, not as attribute values."
          )
        }
        stop(
          "`", name, "` was set to an irid construct (`",
          paste(irid_class, collapse = "/"), "`). ", hint,
          call. = FALSE
        )
      }

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

    # Merge entries that share a DOM event (auto-bind synthetic + explicit
    # `on*`) into a single composed entry — one observer, one JS listener.
    pending_events <- merge_pending_events(pending_events)

    # Resolve timing per event entry (element-level .event > per-event
    # default rule) and resolve .prevent_default per event (scalar
    # broadcasts; named list overrides per event, unmapped → FALSE).
    for (i in seq_along(pending_events)) {
      e <- pending_events[[i]]
      cfg <- resolve_event_config(e$event, element_event_lookup)
      pending_events[[i]]$mode <- cfg$mode
      pending_events[[i]]$ms <- cfg$ms
      pending_events[[i]]$leading <- cfg$leading
      pending_events[[i]]$coalesce <- cfg$coalesce
      pending_events[[i]]$prevent_default <- element_prevent_default_lookup(
        e$event
      )
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
