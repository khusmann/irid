# Small internal list helpers for the predicate-filtering patterns that
# read worse in base R (boolean-index tricks, `Filter()`, intermediate
# logical vectors). Predicates are plain `\(x) ...` functions returning a
# length-1 logical. Only the helpers with real call sites live here — add
# more (keep/discard/some/...) when a use site actually appears.

# Drop `NULL` elements, preserving names.
compact <- function(x) {
  x[!vapply(x, is.null, logical(1L))]
}

# TRUE if `p` holds for every element (vacuously TRUE for an empty `x`).
every <- function(x, p) {
  all(vapply(x, p, logical(1L)))
}
