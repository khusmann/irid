# Producer-side wire codec: the `msg_irid_*` message constructors + the
# `coerce_value_as_number` inbound step, built on a handful of `json_*` shape helpers.
#
# Shiny owns the `toJSON` call in `sendCustomMessage` (`auto_unbox = TRUE`,
# hardcoded), so predictable serialization is a *producer-construction* concern,
# not a config knob. These helpers centralize the discipline so each field's wire
# shape is a function of its declared protocol type, never the runtime value —
# absorbing the `as.list`/`USE.NAMES`/named-list tricks that used to be scattered
# across every `sendCustomMessage` site. The non-determinism under `auto_unbox` is
# narrow and enumerable: array-typed fields that are contingently length-1 unbox
# to a scalar, and empty/sentinel values encode by content (`NULL` dropped,
# `character(0)` -> `[]`, `NA` -> `null`). The combinators below pin each.

# Each `json_*` helper pins one declared protocol type to its wire shape, and the
# contract is uniform across the family:
#   - it ASSERTS the value already matches the declared type and errors on a
#     mismatch — a wrong type is an encoder bug, never silently coerced;
#   - it coerces ONLY to bridge an R serialization quirk under `auto_unbox`
#     (length-1 unboxing, name-keyed scalars/objects, the `[]`-vs-`{}` list-NAMES
#     rule), never a real type conversion;
#   - `null_ok = TRUE` marks a nullable field (`T | null`): NULL passes through as
#     the wire `null`. By default NULL is an error — a required field must not
#     silently vanish. Empty is distinct from NULL: a length-0 array/map is a
#     legal `[]`/`{}`, not a null.

# A JSON array (unnamed list): `[]` when empty, `[x]` for a length-1 value (which
# would otherwise unbox to a scalar). Names are stripped — they ride in as an
# artifact of how the vector was built (e.g. `vapply`'s USE.NAMES), not protocol
# data, so the array never serializes as an object.
json_array <- function(x, null_ok = FALSE) {
  if (is.null(x)) {
    if (null_ok) return(NULL)
    cli::cli_abort("A required JSON array field must not be NULL.")
  }
  if (length(x) == 0L) return(list())
  if (!is.atomic(x) && !is.list(x)) {
    cli::cli_abort("A JSON array field must be an atomic vector or list.")
  }
  as.list(unname(x))
}

# A JSON object (named list): `{}` when empty; a non-empty map must be fully named.
# jsonlite keys the `[]`-vs-`{}` choice off list NAMES, so an unnamed map would
# wrongly serialize as an array — the strict check rejects it. Member VALUES are
# recursively converted from named atomic vectors to named lists, so an object-
# shaped value like `c("8" = "legendonly")` (plotly's trace_visibility) serializes
# as `{ "8": "legendonly" }` and not via jsonlite's deprecated keep_vec_names;
# unnamed vectors and scalars pass through as arrays/scalars.
json_map <- function(x, null_ok = FALSE) {
  if (is.null(x)) {
    if (null_ok) return(NULL)
    cli::cli_abort("A required JSON map field must not be NULL.")
  }
  if (length(x) == 0L) return(stats::setNames(list(), character(0)))
  nms <- names(x)
  if (is.null(nms) || any(!nzchar(nms))) {
    cli::cli_abort("A JSON map field must be fully named.")
  }
  jsonify <- function(v) {
    if (is.list(v)) return(lapply(v, jsonify))
    if (is.atomic(v) && !is.null(names(v))) return(as.list(v))
    v
  }
  jsonify(as.list(x))
}

# A JSON string: asserts a length-1, non-NA character; strips names. Strict — an
# empty/NA value is an error here, NOT silently bridged to `""` (that is the text
# *value* field's semantics, handled upstream in `coerce_text_child`, not a property
# of every string field).
json_string <- function(x, null_ok = FALSE) {
  if (is.null(x)) {
    if (null_ok) return(NULL)
    cli::cli_abort("A required JSON string field must not be NULL.")
  }
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    cli::cli_abort("A JSON string field must be a length-1 non-NA character.")
  }
  unname(x)
}

# A JSON number. Asserts a length-1 numeric; strips names (a named scalar would
# serialize as a one-key object — the only quirk to bridge here).
json_number <- function(x, null_ok = FALSE) {
  if (is.null(x)) {
    if (null_ok) return(NULL)
    cli::cli_abort("A required JSON number field must not be NULL.")
  }
  if (!is.numeric(x) || length(x) != 1L) {
    cli::cli_abort("A JSON number field must be a length-1 numeric.")
  }
  unname(x)
}

# A JSON boolean. Asserts a concrete length-1 logical (the materialized records
# carry only TRUE/FALSE — `NA` would serialize as `null`); strips names.
json_bool <- function(x, null_ok = FALSE) {
  if (is.null(x)) {
    if (null_ok) return(NULL)
    cli::cli_abort("A required JSON boolean field must not be NULL.")
  }
  if (!is.logical(x) || length(x) != 1L || is.na(x)) {
    cli::cli_abort("A JSON boolean field must be TRUE or FALSE.")
  }
  unname(x)
}

# --- value objects -> protocol shape ---------------------------------------
#
# `as_protocol()` renders an irid value object (a classed config/value type) into
# the plain-list protocol shape jsonlite serializes. It is the value tier of the
# codec; `msg_irid_*` (below) is the message tier and calls it on nested value
# objects. (Naming: `as_protocol` returns an R list — the protocol *shape* — not a
# JSON string, so it is deliberately NOT `to_json`.)
#' @keywords internal
#' @noRd
as_protocol <- function(x) UseMethod("as_protocol")

# Each method builds the protocol shape field-by-field, wrapping every field in the
# `json_*` coercer for its declared wire type — even where `auto_unbox` would do the
# right thing anyway. The construction site, not a class strip, is the single place
# the wire shape is pinned.

# Rate-limit timing, discriminated on `mode`: ms/leading exist only where the
# variant gives them meaning.
#' @export
as_protocol.irid_wire_timing <- function(x) {
  switch(x$mode,
    immediate = list(mode = json_string(x$mode)),
    throttle  = list(mode = json_string(x$mode),
                     ms = json_number(x$ms), leading = json_bool(x$leading)),
    debounce  = list(mode = json_string(x$mode), ms = json_number(x$ms))
  )
}

# DOM listener record. Field names are also translated snake_case (R) -> camelCase
# (wire). `filter` is `string | null` (NULL -> wire null = "no filter").
#' @export
as_protocol.irid_dom_opts <- function(x) {
  list(
    preventDefault = json_bool(x$prevent_default),
    stopPropagation = json_bool(x$stop_propagation),
    capture = json_bool(x$capture),
    passive = json_bool(x$passive),
    filter = json_string(x$filter, null_ok = TRUE)
  )
}

# Optimistic-update echo gate.
#' @export
as_protocol.irid_echo_gate <- function(x) {
  list(seq = json_number(x$seq), channel = json_string(x$channel))
}

# Constructor for the echo gate value object: the classed `{seq, channel}`, or NULL
# (the field is OMITTED) when there's no gating context — a programmatic write.
# Contextual absence, not a `null` value.
irid_echo_gate <- function(seq, channel) {
  if (is.null(seq)) return(NULL)
  structure(list(seq = seq, channel = channel), class = "irid_echo_gate")
}

# --- lifecycle message constructors ----------------------------------------

# irid-config: materialized stale-timeout (always present; `null` disables).
msg_irid_config <- function(stale_timeout) {
  list(staleTimeout = json_number(stale_timeout, null_ok = TRUE))
}

# irid-ready: `output` is present only for a renderIrid/iridOutput mount; it is
# OMITTED for a top-level iridApp mount (no output name exists), never sent as null.
msg_irid_ready <- function(output) {
  msg <- list()
  if (!is.null(output)) msg$output <- json_string(output)
  msg
}

# irid-widget-init: `props` is a materialized map (empty -> `{}`); NULL-valued
# props are kept as explicit `null` so the factory sees its full declared prop set
# (the root-cause fix that deletes `__irid_state_keys`).
msg_irid_widget_init <- function(id, name, props) {
  list(id = json_string(id), name = json_string(name), props = json_map(props))
}

# --- irid-attr message constructors ----------------------------------------

# DOM property/attribute write. `value` is arbitrary user data (left as-is); `gate`
# is omitted for a programmatic write.
msg_irid_attr_dom <- function(id, attr, value, seq = NULL, channel = NULL) {
  msg <- list(
    id = json_string(id), target = "dom", attr = json_string(attr), value = value
  )
  gate <- irid_echo_gate(seq, channel)
  if (!is.null(gate)) msg$gate <- as_protocol(gate)
  msg
}

# Text replacement inside a comment-anchor range. No gate (text never gates).
# `value` arrives already normalized to a string by `coerce_text_child` (empty/NA
# -> ""), so `json_string` just asserts it.
msg_irid_attr_text <- function(id, value) {
  list(id = json_string(id), target = "text", value = json_string(value))
}

# Coalesced widget batch. `values` is a map (always >= 1 key); `gates` is the
# sparse per-key gate map, OMITTED entirely when no key is gated (all programmatic).
msg_irid_attr_widget <- function(id, values, gates) {
  msg <- list(id = json_string(id), target = "widget", values = json_map(values))
  if (length(gates) > 0L) msg$valueGates <- json_map(gates)
  msg
}

# --- irid-wire message constructor -----------------------------------------

# One `irid-wire` entry — the serialized per-slot `wire()` carrier for one channel.
# `channel` is the namespaced inputId. The wire shape is a discriminated union on
# `source`: a dom event carries `domOpts` + `clientOnly`, a widget event carries
# `kind` (each field omitted on the other arm). The nested value objects (`timing`,
# `dom_opts`) ride the event row whole and are rendered via `as_protocol()`.
msg_irid_wire <- function(ev, channel, client_only) {
  msg <- list(
    id = json_string(ev$id),
    event = json_string(ev$event),
    channel = json_string(channel),
    source = json_string(ev$source),
    timing = as_protocol(ev$timing),
    coalesce = json_bool(ev$coalesce)
  )
  if (identical(ev$source, "widget")) {
    # `kind` ("prop"/"event") lets the client index widget streams by the
    # `{kind}:{id}:{event}` triple its setProp/sendEvent resolves against.
    msg$kind <- json_string(ev$kind)
  } else {
    msg$domOpts <- as_protocol(ev$dom_opts)
    msg$clientOnly <- json_bool(client_only)
  }
  msg
}

# --- irid-mutate message constructor ---------------------------------------

# Granular comment-anchor range mutations: the sole structural message, driving
# Each (N keyed/positional children) AND When/Match (one child, keyed by active
# branch/case). removes/inserts/order are contextual command-parts, each OMITTED
# when this mutation doesn't do it. `json_array` forces each to a JSON array (an
# unnamed list), centralizing the length-1-unbox / named-vector-as-object discipline
# that used to live at every send site.
msg_irid_mutate <- function(id, removes = NULL, inserts = NULL, order = NULL) {
  msg <- list(id = json_string(id))
  if (length(removes) > 0L) msg$removes <- json_array(removes)
  if (length(inserts) > 0L) msg$inserts <- json_array(inserts)
  if (length(order) > 0L) msg$order <- json_array(order)
  msg
}

# --- Inbound: client -> server payload coercion ----------------------------
#
# The inbound envelope is the flat mirror of the client's `attachPayloadMeta`:
# `{ id, seq, data }`, with the foreign event fields under `data`. The observer
# reads those three fields directly (no decode/reshape step) and keeps every
# value verbatim — nulls included — EXCEPT for the one normalization below.
# Value coercion is otherwise semantic and field-specific, so it stays per source
# (widgets via `coerce_plotly_value`).

# The one inbound normalization irid owns, applied to DOM events ONLY (gated on
# `ev$source` at the observer). A number/range/date input reports
# `valueAsNumber = NaN` when empty, and JSON serializes NaN as null, landing here
# as R NULL. Re-key just that field to a typed `NA_real_` so a handler reads an
# empty input as a missing *value* (`is.na()`, matching base Shiny's numericInput)
# rather than a `NULL`. Scoped to `valueAsNumber`: it is the only field
# `buildPayload` can send as null, and knowing it is numeric lets us type the NA.
coerce_value_as_number <- function(event) {
  if ("valueAsNumber" %in% names(event) && is.null(event$valueAsNumber)) {
    event$valueAsNumber <- NA_real_
  }
  event
}
