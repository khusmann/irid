# Producer-side protocol codec: the `msg_irid_*` message constructors (`config` /
# `render` / `ready`), the `op_irid_*` op constructors (the ops carried inside an
# `irid-render` message), + the `coerce_value_as_number` inbound step, built on a
# handful of `json_*` shape helpers.
#
# Shiny owns the `toJSON` call in `sendCustomMessage` (`auto_unbox = TRUE`,
# hardcoded), so predictable serialization is a *producer-construction* concern,
# not a config knob. These helpers centralize the discipline so each field's
# protocol shape is a function of its declared protocol type, never the runtime
# value.
# The non-determinism under `auto_unbox` is
# narrow and enumerable: array-typed fields that are contingently length-1 unbox
# to a scalar, and empty/sentinel values encode by content (`NULL` -> `null` with
# the key kept, `character(0)` -> `[]`, `NA` -> `null`). The combinators below pin
# each.

# Each `json_*` helper pins one declared protocol type to its protocol shape, and the
# contract is uniform across the family:
#   - it ASSERTS the value already matches the declared type and errors on a
#     mismatch — a wrong type is an encoder bug, never silently coerced;
#   - it coerces ONLY to bridge an R serialization quirk under `auto_unbox`
#     (length-1 unboxing, name-keyed scalars/objects, the `[]`-vs-`{}` list-NAMES
#     rule), never a real type conversion;
#   - `null_ok = TRUE` marks a nullable field (`T | null`): NULL passes through as
#     the protocol `null`. By default NULL is an error — a required field must not
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
# as `{ "8": "legendonly" }`; unnamed vectors and scalars pass through unchanged.
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
  json_value(as.list(x))
}

# Recursively bridge the named-vector -> object quirk for an arbitrary value: a
# named atomic vector serializes as a one-key-per-name object only as a named
# *list* (jsonlite keys `[]`-vs-`{}` off list NAMES), so convert named atomics to
# named lists at every depth. Unnamed vectors and scalars pass through unchanged.
# Used by `json_map` (per member) and by `op_irid_attr` (a widget prop value can
# be a named atomic like plotly's `c("8" = "legendonly")`).
json_value <- function(v) {
  if (is.list(v)) return(lapply(v, json_value))
  if (is.atomic(v) && !is.null(names(v))) return(as.list(v))
  v
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

# A JSON number. Asserts a concrete length-1 numeric (`NA`/`NaN` would serialize
# as `null` — a required field must not silently vanish); strips names (a named
# scalar would serialize as a one-key object — the other quirk to bridge here).
json_number <- function(x, null_ok = FALSE) {
  if (is.null(x)) {
    if (null_ok) return(NULL)
    cli::cli_abort("A required JSON number field must not be NULL.")
  }
  if (!is.numeric(x) || length(x) != 1L || is.na(x)) {
    cli::cli_abort("A JSON number field must be a length-1 non-NA numeric.")
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
# codec; the `msg_irid_*` / `op_irid_*` constructors (below) are the message tier
# and call it on nested value objects. (Naming: `as_protocol` returns an R list —
# the protocol *shape* — not a JSON string, so it is deliberately NOT `to_json`.)
#' @keywords internal
#' @noRd
as_protocol <- function(x) UseMethod("as_protocol")

# Each method builds the protocol shape field-by-field, wrapping every field in the
# `json_*` coercer for its declared protocol type — even where `auto_unbox` would do the
# right thing anyway. The construction site, not a class strip, is the single place
# the protocol shape is pinned.

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
# (protocol). `filter` is `string | null` (NULL -> protocol null = "no filter").
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

# Optimistic-update echo gate (constructor `irid_echo_gate` lives in R/mount.R,
# the producer; this is its protocol-shape method, mirroring wire_timing/dom_opts).
#' @export
as_protocol.irid_echo_gate <- function(x) {
  list(seq = json_number(x$seq), channel = json_string(x$channel))
}

# --- session message constructors (config / ready) -------------------------

# irid-config: materialized stale-timeout (always present; `null` disables).
msg_irid_config <- function(stale_timeout) {
  list(staleTimeout = json_number(stale_timeout, null_ok = TRUE))
}

# irid-ready: `output` is the renderIrid/iridOutput output name, or `null` for a
# top-level iridApp mount (no output name exists). Always present — the client's
# public `irid:ready` event already exposes it as `id: name | null`.
msg_irid_ready <- function(output) {
  list(output = json_string(output, null_ok = TRUE))
}

# --- widget-init op constructor --------------------------------------------

# widget-init op: `props` is a materialized map (empty -> `{}`); NULL-valued
# props are kept as explicit `null` so the factory sees its full declared prop set.
op_irid_widget_init <- function(id, name, props) {
  list(
    kind = "widget-init",
    id = json_string(id), name = json_string(name), props = json_map(props)
  )
}

# --- attr / text op constructors -------------------------------------------

# A bound value pushed to its sink, discriminated on `target`:
#   "dom"    — a DOM property/attribute write on `getElementById(id)`.
#   "widget" — a single-key prop write; the client accumulates every `target =
#              "widget"` op for one id across the render and calls `update()` once.
# Both share the shape `{ id, attr, value, gate }`. `value` is arbitrary user data,
# passed through `json_value` to bridge the named-vector -> object quirk (a widget
# prop can be a named atomic like plotly's `c("8" = "legendonly")`; a scalar DOM
# value passes through untouched). `gate` is an `irid_echo_gate` value object, or
# NULL for a programmatic write (rendered as the protocol `null`). Always present.
op_irid_attr <- function(target, id, attr, value, gate = NULL) {
  list(
    kind = "attr",
    target = json_string(target),
    id = json_string(id),
    attr = json_string(attr),
    value = json_value(value),
    gate = if (is.null(gate)) NULL else as_protocol(gate)
  )
}

# Text replacement inside a comment-anchor range — its own op kind (no attr, no
# gate). `value` arrives already normalized to a string by `coerce_text_child`
# (empty/NA -> ""), so `json_string` just asserts it.
op_irid_text <- function(id, value) {
  list(kind = "text", id = json_string(id), value = json_string(value))
}

# --- irid-wire op constructor --------------------------------------------

# One `irid-wire` entry — the serialized per-slot `wire()` carrier for one channel.
# `channel` is the namespaced inputId. The protocol shape is a discriminated union on
# `source`: a dom event carries `domOpts` + `clientOnly`; the widget arm adds no
# extra fields (the client indexes widget streams by the `{id}:{event}` pair its
# setProp/sendEvent resolves against, both already present). The nested value
# objects (`timing`, `dom_opts`) ride the event row whole, rendered via `as_protocol()`.
op_irid_wire <- function(ev, channel, client_only) {
  msg <- list(
    kind = "wire",
    id = json_string(ev$id),
    event = json_string(ev$event),
    channel = json_string(channel),
    source = json_string(ev$source),
    timing = as_protocol(ev$timing),
    coalesce = json_bool(ev$coalesce)
  )
  if (!identical(ev$source, "widget")) {
    msg$domOpts <- as_protocol(ev$dom_opts)
    msg$clientOnly <- json_bool(client_only)
  }
  msg
}

# --- irid-mutate op constructor ----------------------------------------

# Granular comment-anchor range mutations: the sole structural message, driving
# Each (N keyed/positional children) AND When/Match (one child, keyed by active
# branch/case). removes/inserts/order are ALWAYS present: an absent command-part
# is an empty array, not an omitted field — the client iterates each, so `[]` is
# a no-op indistinguishable from omission, and a uniform shape beats a contextual
# one. Callers speak in empty collections (never NULL), so `json_array` stays
# strict (a NULL here is an encoder bug) and forces each to a JSON array.
op_irid_mutate <- function(id, removes = list(), inserts = list(), order = list()) {
  list(
    kind = "mutate",
    id = json_string(id),
    removes = json_array(removes),
    inserts = json_array(inserts),
    order = json_array(order)
  )
}

# --- irid-render message constructor ---------------------------------------

# One flush's render: an ordered op list applied by the client in one synchronous
# pass (one paint). `ops` is the list of already-constructed `op_irid_*` op
# payloads in EMISSION order (apply order) — a child's `mutate` precedes the
# `wire`/`widget-init`/`attr` that need its element, each op self-discriminated by
# its `kind`. Each op's wire shape was pinned at construction, so the payloads pass
# through unchanged. The drain only sends a non-empty render, so `ops` is >= 1.
msg_irid_render <- function(ops) {
  list(ops = json_array(ops))
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
