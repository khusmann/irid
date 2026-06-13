# Small internal list helpers for the predicate-filtering patterns that read
# worse in base R (boolean-index tricks, `Filter()`, intermediate logical
# vectors). Behaviour matches the same-named purrr functions so the names
# don't mislead — they're honest, drop-in-compatible reimplementations, not
# look-alikes. Predicates are plain `\(x) ...` functions (no purrr `~`
# formula shorthand). Only helpers with a real call site live here — add more
# (keep/discard/some/...) when a use site appears, matching purrr semantics.

# Drop zero-length elements (`NULL`, `character(0)`, ...), preserving names.
# Matches `purrr::compact()`.
compact <- function(x) {
  x[as.logical(lengths(x))]
}

# TRUE if `p` holds for every element (vacuously TRUE for empty `x`).
# Matches `purrr::every()`: NA / non-`TRUE` predicate results count as FALSE,
# and it short-circuits on the first non-`TRUE`.
every <- function(x, p) {
  for (el in x) if (!isTRUE(p(el))) return(FALSE)
  TRUE
}
