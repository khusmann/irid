# Internal argument checks.
#
# rlang 1.2.0 exports `check_bool()`, `check_string()`, and the
# `check_number_*()` family, which we import and call unqualified.
# `check_function()` is the one we need that rlang keeps standalone-only
# (unexported), so we provide a minimal equivalent here. It mirrors the
# rlang `check_*` contract — `allow_null`, lazy `arg`/`call` defaults — and
# renders the same cli style (`{.arg}` + `{.obj_type_friendly}`) the rest of
# the package's errors use.
check_function <- function(x,
                           ...,
                           allow_null = FALSE,
                           arg = rlang::caller_arg(x),
                           call = rlang::caller_env()) {
  if (!missing(x)) {
    if (is_function(x)) return(invisible(NULL))
    if (allow_null && is.null(x)) return(invisible(NULL))
  }
  msg <- if (allow_null) {
    "{.arg {arg}} must be a function or {.code NULL}, not {.obj_type_friendly {x}}."
  } else {
    "{.arg {arg}} must be a function, not {.obj_type_friendly {x}}."
  }
  cli::cli_abort(msg, ..., arg = arg, call = call)
}
