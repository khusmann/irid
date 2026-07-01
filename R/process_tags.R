#' Test whether a value is a irid-reactive function
#'
#' Returns `TRUE` for any callable irid treats as reactive — plain
#' functions, Shiny reactives, `reactiveStore` nodes, and `reactiveProxy`
#' wrappers. Used by [process_tags()] to decide which attributes participate
#' in auto-bind / event extraction.
#'
#' @param x An object to test.
#' @return Logical.
#' @keywords internal
is_irid_reactive <- function(x) {
  is.function(x) && (identical(class(x), "function") || inherits(x, "reactive"))
}

# State-binding attribute → DOM event name. The prop name doubles as the
# field on the event object the synthetic write-back reads from (irid
# stays close to the DOM IDL — `value` and `checked` are both the prop
# and the readable property), but the DOM event used to write back is
# element-dependent.
#
# `<select value=rv>` synthesises on `change`, not `input`. `change` is
# the canonical "user picked something" event for a select; `input` also
# fires but is the wrong one to autobind because the per-event default is
# `wire_debounce(200)`, so the write to `rv` would lag.
# Text inputs stay on `input` (keystroke-by-keystroke).
STATE_BIND_ATTRS <- c("value", "checked")
state_bind_event <- function(attr_name, tag_name) {
  if (attr_name == "checked") return("change")
  if (identical(tag_name, "select")) return("change")
  "input"
}

# Build the synthetic write-back handler for a state-binding prop.
# Writable callables (reactiveVal, reactiveProxy, reactiveStore node,
# `\(v) ...`, `\(...) ...`, primitives) get a handler that calls
# `fn(e$value/checked)`. Read-only callables (`\() expr()`, `reactive()`)
# get a no-op handler — the listener still fires so the optimistic-update
# protocol echoes the current server value back, snapping the input.
make_autobind_handler <- function(fn, attr_name) {
  force(fn)
  force(attr_name)
  h <- if (can_accept_write(fn)) {
    function(e) fn(e[[attr_name]])
  } else {
    function(e) NULL
  }
  # Declare the write target for the framework's force-send-on-no-op
  # loop. Both writable and read-only autobind handlers declare it —
  # read-only specifically NEEDS force-send to snap the input back to
  # the canonical value.
  attr(h, "irid_write_targets") <- attr_name
  h
}

# Build the synthesized write-back handler for a two-way-capable widget
# prop. `setProp(key, value)` on the client delivers the value under the
# `value` payload field (uniform across props since each rides its own
# `irid_input_{id}_{key}` input). Writable subjects get `fn(e$value)`;
# read-only subjects get a no-op whose force-send snaps the canonical value
# back through the prop's `target = "widget"` binding.
make_widget_writeback <- function(fn, key) {
  force(fn)
  force(key)
  h <- if (can_accept_write(fn)) {
    function(e) fn(e$value)
  } else {
    function(e) NULL
  }
  attr(h, "irid_write_targets") <- key
  h
}

# Known high-frequency continuous event streams. Left on `wire_immediate()`
# these are a firehose: every move/scroll fires `Shiny.setInputValue` with
# no rate limiting and no server-idle backpressure, so the server falls
# behind processing stale positions and latency grows unbounded. They
# default to `wire_throttle(100)` instead, whose derived `coalesce = TRUE`
# adds the server-idle gate — a paced "latest position" stream the server
# can keep up with. Discrete events (`click`, `keydown`, …) stay immediate.
HIGH_FREQ_EVENTS <- c(
  "mousemove", "pointermove", "touchmove",
  "drag", "dragover",
  "scroll", "wheel",
  "resize"
)

# Per-event default timing, consulted only when the carrier leaves `timing`
# NULL. Three classes: typing (`input`) floods intermediate values →
# debounce for the settled value; high-frequency streams → throttle (+
# derived coalesce) for a paced continuous stream; everything else fires
# once per discrete user action → immediate. Explicit timing always wins.
default_for_event <- function(event_name) {
  if (event_name == "input") {
    wire_debounce(200)
  } else if (event_name %in% HIGH_FREQ_EVENTS) {
    wire_throttle(100)
  } else {
    wire_immediate()
  }
}

# `coalesce` derives from the timing mode when the carrier leaves it NULL:
# immediate streams shouldn't gate on idle, rate-limited ones should.
derive_coalesce <- function(mode) !identical(mode, "immediate")

# Resolve a `wire`'s dispatch config for one event into the flat row
# the event message carries. Carrier `timing` wins, else the per-event
# default; carrier `coalesce` wins, else derive from the mode; `dom_opts`
# flags default FALSE when absent.
resolve_wire_config <- function(wire, event_name, default_timing = NULL) {
  timing <- wire$timing %||% default_timing %||% default_for_event(event_name)
  # Carry the value objects whole — the encoder renders them via `as_protocol()`.
  # `dom_opts` is always materialized (default all-FALSE / filter NULL) so its
  # `as_protocol` yields the complete wire record even when the slot set no opts.
  list(
    timing = timing,
    coalesce = wire$coalesce %||% derive_coalesce(timing$mode),
    dom_opts = wire$dom_opts %||% wire_dom_opts()
  )
}

# Enforce one channel per DOM event (see ARCHITECTURE.md, "One channel per
# event"): a given event is driven
# by a value binding OR an explicit `on*` handler, never both; and a single
# explicit handler per event (no composition). `pending_events` entries
# carry `event` (DOM name) and `autobind` (logical).
enforce_one_channel_per_event <- function(pending_events) {
  ev_names <- vapply(pending_events, function(e) e$event, character(1L))
  autobind <- vapply(pending_events, function(e) isTRUE(e$autobind), logical(1L))
  for (nm in unique(ev_names)) {
    idx <- which(ev_names == nm)
    has_autobind <- any(autobind[idx])
    n_explicit <- sum(!autobind[idx])
    if (has_autobind && n_explicit > 0L) {
      cli::cli_abort(c(
        "{.field {nm}} is claimed by both a value binding \\
         ({.arg value}/{.arg checked}) and an explicit {.code on*} handler \\
         on the same element.",
        "i" = "A DOM event is bound {.emph or} handled, never both.",
        "*" = "To run a synchronous side-effect on write, use \\
               {.code value = reactiveProxy(get, set)}.",
        "*" = "To react asynchronously, observe the bound reactive."
      ))
    }
    if (n_explicit > 1L) {
      cli::cli_abort(c(
        "Duplicate handler for event {.field {nm}} on one element.",
        "i" = "Attach a single handler per event."
      ))
    }
  }
  invisible(pending_events)
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

#' Materialize a node's own htmltools render hooks / tag function
#'
#' bslib (and htmltools generally) defer structure to **render time**: a
#' `shiny.tag` can carry `.renderHooks` that build its final DOM
#' (`layout_sidebar()`'s grid wrapper, `card()`'s fill plumbing, ...), and
#' a `shiny.tag.function` produces its tags only when called. [process_tags()]
#' rebuilds each tag from `name`/`attribs`/`children`, so without running
#' these first the deferred wrapper is silently dropped (see GH #27).
#'
#' This runs only the node's *own* hooks (one level), looping until the node
#' is a resolved tag / non-tag. Unlike [htmltools::as.tags()] it does **not**
#' recurse into children — `process_tags`' walker descends into them itself
#' and resolves each child's hooks as it arrives. That separation is what
#' lets irid's own children (reactive functions, `irid_output`,
#' `irid_widget`, control-flow nodes) survive: they never carry render hooks,
#' so they pass straight through, while a child hook that *moved* them into a
#' new wrapper still gets walked.
#'
#' @param node A node from the tag tree.
#' @return The node with its top-level render hooks / tag function resolved.
#' @keywords internal
resolve_render_hooks <- function(node) {
  repeat {
    if (inherits(node, "shiny.tag.function")) {
      node <- node()
      next
    }
    if (inherits(node, "shiny.tag") && length(node$.renderHooks) > 0L) {
      hook <- node$.renderHooks[[1L]]
      node$.renderHooks[[1L]] <- NULL
      node <- hook(node)
      next
    }
    break
  }
  node
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
  widget_inits <- list()

  walk <- function(node) {
    if (is.null(node)) return(NULL)

    # Run any deferred htmltools render hooks / tag functions before
    # inspecting the node, so the materialized structure (bslib layout
    # wrappers, card fill plumbing, ...) is what we walk and rebuild.
    node <- resolve_render_hooks(node)
    if (is.null(node)) return(NULL)

    if (inherits(node, "irid_output")) {
      id <- next_id()
      shiny_outputs[[length(shiny_outputs) + 1L]] <<- list(
        id = id,
        render_call = node$render_call
      )
      return(do.call(node$output_fn, c(list(id), node$output_fn_args)))
    }

    if (inherits(node, "irid_widget")) {
      container <- node$container
      if (is.null(container)) container <- htmltools::tags$div()

      # Honor user-supplied id on the container, otherwise allocate.
      user_id <- container$attribs$id
      id <- if (!is.null(user_id)) user_id else next_id()

      # Per-key prop dispatch. A callable (bare, or the subject of a
      # `wire` used to tune timing) becomes a **two-way-capable** prop:
      # a `target = "widget"` binding (server → client, one observer per
      # key) PLUS a synthesized write-back event row (client → server via
      # `setProp`). A non-callable rides in the init
      # message as a constant. `static_props[key] <- list(val)`
      # (single-bracket) preserves NULL entries — `[[<-` would drop them via
      # R's NULL-removes-key quirk; Shiny's `null = "null"` JSON option then
      # serializes them to JS `null`, giving the factory a complete props
      # object.
      prop_fns <- list()
      static_props <- list()
      for (key in names(node$props)) {
        val <- node$props[[key]]
        w <- if (inherits(val, "irid_wire")) val else NULL
        if (!is.null(w) && !is.null(w$dom_opts)) {
          cli::cli_abort(c(
            "{.arg dom_opts} is not allowed on the widget prop {.field {key}}.",
            "i" = "A prop is delivered through {.code setProp()}, not a DOM listener."
          ))
        }
        subj <- if (!is.null(w)) w$subject else if (is_irid_reactive(val)) val else NULL
        if (!is.null(subj) && is_irid_reactive(subj)) {
          prop_fns[[key]] <- subj
          bindings[[length(bindings) + 1L]] <<- list(
            id = id, target = "widget", attr = key, fn = subj
          )
          cfg <- resolve_wire_config(w %||% wire(), key,
                                     default_timing = wire_immediate())
          # Widget rows carry no `dom_opts` — the encoder omits domOpts on the
          # widget arm (no DOM listener is attached).
          events[[length(events) + 1L]] <<- list(
            id = id, event = key, handler = make_widget_writeback(subj, key),
            write_targets = key,
            timing = cfg$timing, coalesce = cfg$coalesce,
            source = "widget"
          )
        } else {
          # A wire with a NULL subject (optional prop the caller omitted)
          # collapses to a NULL constant; otherwise the bare value rides.
          static_props[key] <- list(if (!is.null(w)) NULL else val)
        }
      }

      # Widget events are genuine notifications, configured with `wire`
      # (already normalized + subject-guaranteed by `IridWidget`). Timing /
      # coalesce come from the carrier, defaulting per the event-name rule
      # (which is `wire_immediate()` for any non-`input` widget event name).
      for (key in names(node$events)) {
        w <- node$events[[key]]
        handler <- w$subject
        cfg <- resolve_wire_config(w, key, default_timing = wire_immediate())
        events[[length(events) + 1L]] <<- list(
          id = id, event = key, handler = handler,
          write_targets = attr(handler, "irid_write_targets"),
          timing = cfg$timing, coalesce = cfg$coalesce,
          source = "widget"
        )
      }

      widget_inits[[length(widget_inits) + 1L]] <<- list(
        id = id, name = node$name,
        prop_fns = prop_fns, static_props = static_props,
        deps = node$deps
      )

      # Set the id (so the walker reuses it for any container DOM events)
      # and the `data-irid-widget` marker the client's detach walker
      # looks for. irid owns this attribute — if the user set it on the
      # container, irid overwrites.
      container$attribs$id <- id
      container$attribs[["data-irid-widget"]] <- node$name

      # Deps are NOT page-attached here. They are delivered at mount time via
      # `insertUI` (see `deliver_widget_deps` in mount.R), riding Shiny's native
      # render pipeline — the only dep-delivery path shinylive serves, and one
      # that reaches widgets appearing *only* inside `When`/`Each`/`Match` too.
      # `node$deps` is carried on the `widget_inits` entry above and consumed by
      # mount.
      return(walk(container))
    }

    if (inherits(node, "irid_each")) {
      id <- next_id()
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = "each", id = id,
        items = node$items, fn = node$fn, by = node$by
      )
      return(anchor_pair(id))
    }

    if (inherits(node, "irid_match")) {
      id <- next_id()
      control_flows[[length(control_flows) + 1L]] <<- list(
        type = "match", id = id,
        callable = node$callable,
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
      # Reactive text child → comment-anchor pair, not a `<span>` wrapper.
      # A wrapper element would be silently stripped by the HTML parser
      # inside restricted-content parents (`<option>`, `<textarea>`, etc.),
      # which use insertion modes that drop unrecognised start tags. Comment
      # nodes are valid children of any element, so the same shape works
      # everywhere. The binding's `target = "text"` tells mount to emit a
      # `text` op that replaces the range with a single text node.
      id <- next_id()
      bindings[[length(bindings) + 1L]] <<- list(
        id = id, target = "text", fn = node
      )
      return(anchor_pair(id))
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

    # Iterate by position rather than `for (name in names(attribs))` —
    # htmltools allows duplicate attribute names (e.g. two `onInput`s on
    # one tag) and `attribs[[name]]` would collapse them all to the first
    # match. Position-indexed access preserves every entry so the
    # one-channel check sees each one.
    attrib_names <- names(attribs)
    for (i in seq_along(attribs)) {
      name <- attrib_names[[i]]
      val <- attribs[[i]]

      is_wire <- inherits(val, "irid_wire")
      is_state <- name %in% STATE_BIND_ATTRS
      is_event <- grepl("^on[A-Z]", name)

      # Catch misuse of irid constructs as attribute values. `irid_wire` is
      # the one valid construct in an event / value / checked slot; every
      # other `irid_*` class (bare timing shape, `irid_dom_opts`,
      # control-flow node, output) is meaningful only elsewhere and would
      # otherwise serialize as raw HTML.
      if (!is_wire) {
        irid_class <- grep("^irid_", class(val), value = TRUE)
        if (length(irid_class) > 0L) {
          hint <- if ("irid_wire_timing" %in% irid_class) {
            if (is_event || is_state) {
              cli::format_inline(
                "Timing shapes pair with a subject inside {.fn wire}, \\
                 e.g. {.code {name} = wire(subject, wire_debounce(200))}."
              )
            } else {
              cli::format_inline("Timing shapes belong inside {.code wire(timing = ...)}.")
            }
          } else if ("irid_dom_opts" %in% irid_class) {
            cli::format_inline("{.fn wire_dom_opts} belongs inside {.code wire(dom_opts = ...)}.")
          } else {
            cli::format_inline(
              "Constructs of class {.cls {irid_class[[1]]}} belong as children, \\
               not as attribute values."
            )
          }
          cli::cli_abort(c(
            "{.field {name}} was set to an irid construct ({.cls {irid_class}}).",
            "i" = hint
          ))
        }
      }

      # Auto-bind: state-binding prop with a callable or a wire wrapping
      # one. Emit a binding (server → client read) and the sole synthetic
      # event entry (client → server write) for that event.
      if (is_state && (is_wire || is_irid_reactive(val))) {
        w <- as_wire(val)
        subj <- w$subject
        if (is.null(subj) || !is_irid_reactive(subj)) {
          cli::cli_abort(c(
            "{.field {name}} needs a reactive subject.",
            "i" = "{.fn wire} with no subject configures timing only and has \\
                   nothing to bind."
          ))
        }
        pending_bindings[[length(pending_bindings) + 1L]] <- list(
          attr = name, fn = subj
        )
        pending_events[[length(pending_events) + 1L]] <- list(
          event = state_bind_event(name, node$name),
          handler = make_autobind_handler(subj, name),
          autobind = TRUE, wire = w
        )
        next
      }

      if (is_event && (is_wire || is_irid_reactive(val))) {
        w <- as_wire(val)
        js_event <- tolower(sub("^on", "", name))
        # A config-only wire (e.g. `dom_opts` with no handler) attaches a
        # client-side listener but never round-trips — handler stays NULL.
        pending_events[[length(pending_events) + 1L]] <- list(
          event = js_event, handler = w$subject, autobind = FALSE, wire = w
        )
        next
      }

      if (is_wire) {
        cli::cli_abort(
          "{.field {name}}: {.fn wire} configures event ({.code on*}) and \\
           {.arg value}/{.arg checked} slots, not plain attribute bindings."
        )
      }

      if (!is_irid_reactive(val)) {
        # Append positionally rather than `kept_attribs[[name]] <- val`:
        # htmltools allows duplicate attribute names and renders them
        # joined (a tag can carry two `class` attribs — bslib's render
        # hooks emit exactly that, stacking `bslib-sidebar-layout` and
        # `html-fill-item`). Name-keyed assignment would collapse the pair
        # to the last value and silently drop the layout wrapper.
        # `list(val)` named via `names<-` keeps NULL values intact (a bare
        # `[[<-` of NULL would extend nothing).
        kept_attribs <- c(kept_attribs, `names<-`(list(val), name))
        next
      }

      # Plain reactive attribute binding (one-way, no event).
      pending_bindings[[length(pending_bindings) + 1L]] <- list(
        attr = name, fn = val
      )
    }

    # One channel per event (§4): no autobind/explicit overlap, no
    # duplicate explicit handlers.
    enforce_one_channel_per_event(pending_events)

    # Resolve timing / coalesce / dom_opts per event entry from its wire. The
    # value objects (`timing`, `dom_opts`) ride the row whole — the encoder renders
    # them via `as_protocol()`.
    for (i in seq_along(pending_events)) {
      e <- pending_events[[i]]
      cfg <- resolve_wire_config(e$wire, e$event)
      pending_events[[i]]$timing <- cfg$timing
      pending_events[[i]]$coalesce <- cfg$coalesce
      pending_events[[i]]$dom_opts <- cfg$dom_opts
      pending_events[[i]]$wire <- NULL
    }

    if (length(pending_bindings) > 0L || length(pending_events) > 0L) {
      id <- if (!is.null(kept_attribs$id)) kept_attribs$id else next_id()
      kept_attribs$id <- id

      for (b in pending_bindings) {
        b$id <- id
        b$target <- "dom"
        bindings[[length(bindings) + 1L]] <<- b
      }
      for (e in pending_events) {
        e$id <- id
        e$source <- "dom"
        e$write_targets <- attr(e$handler, "irid_write_targets")
        e$autobind <- NULL
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
       widget_inits = widget_inits,
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
