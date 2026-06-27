# Wire encoder / decoder — see dev/protocol-types.md §9.
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

# Force a JSON array (unnamed list): `[]` when empty, `[x]` for a length-1 value
# (which would otherwise unbox to a scalar under `auto_unbox = TRUE`). Names are
# stripped so the list never serializes as an object.
wire_array <- function(x) {
  if (length(x) == 0L) return(list())
  as.list(unname(x))
}

# Force a JSON object (named list): `{}` when empty. jsonlite keys the `[]`-vs-`{}`
# choice off list NAMES, so an empty *map* must be a named list. Named atomic
# members are converted to named lists so an object-shaped value still serializes
# as an object (and without the deprecated keep_vec_names warning).
wire_map <- function(x) {
  if (length(x) == 0L) return(stats::setNames(list(), character(0)))
  irid_jsonify_names(as.list(x))
}

# Normalize a text value to a JSON string: empty / `NA` / `character(0)` -> `""`.
# `as.character(NULL)` is `character(0)` (serializes as `[]`) and `NA_character_`
# serializes as `null`, so without this the wire type would be `string | null | []`
# rather than the `string` the protocol declares.
wire_string <- function(x) {
  x <- as.character(x)
  if (length(x) == 0L || is.na(x)) return("")
  x
}

# An `EchoGate` `{seq, channel}`, or NULL (the key is OMITTED) when there's no
# gating context — a programmatic write. Contextual absence, not a `null` value.
wire_gate <- function(seq, channel) {
  if (is.null(seq)) return(NULL)
  list(seq = seq, channel = channel)
}

# Shiny's custom-message encoder serializes named atomic vectors with jsonlite's
# `keep_vec_names = TRUE`, which is deprecated (a future jsonlite will encode them
# as arrays, not objects) and warns. Recursively convert named atomic vectors to
# named lists so an object-shaped value like `c("8" = "legendonly")` (e.g. plotly's
# `trace_visibility`) still serializes as the `{ "8": "legendonly" }` object the
# client expects, without the warning. Unnamed vectors and scalars pass through.
irid_jsonify_names <- function(value) {
  if (is.list(value)) return(lapply(value, irid_jsonify_names))
  if (is.atomic(value) && !is.null(names(value))) return(as.list(value))
  value
}

# --- irid-attr message constructors ----------------------------------------

# DOM property/attribute write. `gate` is omitted for a programmatic write.
irid_encode_attr_dom <- function(id, attr, value, seq = NULL, channel = NULL) {
  msg <- list(id = id, target = "dom", attr = attr, value = value)
  gate <- wire_gate(seq, channel)
  if (!is.null(gate)) msg$gate <- gate
  msg
}

# Text replacement inside a comment-anchor range. No gate (text never gates), and
# `value` is normalized to a string so the wire type is `string`.
irid_encode_attr_text <- function(id, value) {
  list(id = id, target = "text", value = wire_string(value))
}

# Coalesced widget batch. `values` is a map (always >= 1 key); `gates` is the
# sparse per-key gate map, OMITTED entirely when no key is gated (all programmatic).
irid_encode_attr_widget <- function(id, values, gates) {
  msg <- list(id = id, target = "widget", values = wire_map(values))
  if (length(gates) > 0L) msg$valueGates <- wire_map(gates)
  msg
}

# --- Inbound: client -> server payload decode ------------------------------

# The structural mirror of the client's `attachPayloadMeta`. Splits the transport
# envelope (`id` + per-channel `seq`) from the foreign event data. It does NOT do
# value coercion (turning `list(40, 200)` into a numeric range, or `NA` back into
# `NULL`) — that is semantic and field-specific, so it stays per-widget
# (`coerce_plotly_value`). See §9 "Inbound decode".
irid_decode_payload <- function(payload) {
  meta <- list(id = payload[["id"]], seq = payload[["__irid_seq"]])
  event <- lapply(
    payload[setdiff(names(payload), c("id", "nonce", "__irid_seq"))],
    function(x) if (is.null(x)) NA else x
  )
  list(meta = meta, event = event)
}
