# --- Auto-bind handler arity dispatch ----------------------------------------
#
# `make_autobind_handler` decides whether a callable bound to a state-binding
# prop (value/checked) gets a write handler (`function(e) fn(e[[attr_name]])`)
# or a no-op handler (`function(e) NULL`). The dispatch is arity-based and
# must work consistently across every callable shape irid accepts.

# Walk a single `<input value = X>` through process_tags and return the
# synthetic event entry's handler.
autobind_handler_for <- function(callable) {
  result <- process_tags(tags$input(value = callable))
  expect_length(result$events, 1L)
  expect_equal(result$events[[1]]$event, "input")
  result$events[[1]]$handler
}

# Invoke an autobind handler with a synthetic DOM-event payload. Just a
# call — the surrounding test asserts the resulting state.
invoke_write <- function(handler, value) {
  shiny::isolate(handler(list(value = value)))
}

test_that("reactiveVal (1 formal) gets a write handler", {
  rv <- shiny::reactiveVal("init")
  h <- autobind_handler_for(rv)
  invoke_write(h, "typed")
  expect_equal(shiny::isolate(rv()), "typed")
})

test_that("reactive() (0 formals) gets a no-op handler", {
  rv <- shiny::reactiveVal("seed")
  r <- shiny::reactive(rv())
  h <- autobind_handler_for(r)
  # Calling with the DOM payload must not error and must not mutate
  # anything — the handler exists only to keep the listener live.
  expect_silent(h(list(value = "ignored")))
  expect_equal(shiny::isolate(rv()), "seed")
})

test_that("reactiveProxy(get, set) writes through `set`", {
  rv <- shiny::reactiveVal("a")
  p <- reactiveProxy(get = rv, set = function(v) rv(toupper(v)))
  h <- autobind_handler_for(p)
  shiny::isolate(h(list(value = "b")))
  expect_equal(shiny::isolate(rv()), "B")
})

test_that("reactiveProxy(get) (read-only) silently drops writes", {
  rv <- shiny::reactiveVal("x")
  p <- reactiveProxy(get = rv)
  h <- autobind_handler_for(p)
  expect_silent(shiny::isolate(h(list(value = "y"))))
  expect_equal(shiny::isolate(rv()), "x")
})

test_that("store leaf gets a write handler (end-to-end through process_tags)", {
  state <- reactiveStore(list(name = "Alice"))
  h <- autobind_handler_for(state$name)
  shiny::isolate(h(list(value = "Bob")))
  expect_equal(shiny::isolate(state$name()), "Bob")
})

test_that("0-arg lambda gets a no-op handler", {
  rv <- shiny::reactiveVal("seed")
  fn <- (\() rv())
  h <- autobind_handler_for(fn)
  expect_silent(h(list(value = "ignored")))
  expect_equal(shiny::isolate(rv()), "seed")
})

test_that("1-arg lambda gets a write handler", {
  captured <- NULL
  fn <- function(v) captured <<- v
  h <- autobind_handler_for(fn)
  h(list(value = "delivered"))
  expect_equal(captured, "delivered")
})

test_that("function(...) gets a write handler (dots accept the value)", {
  captured <- NULL
  fn <- function(...) captured <<- ..1
  h <- autobind_handler_for(fn)
  h(list(value = "via-dots"))
  expect_equal(captured, "via-dots")
})

test_that("primitive functions are treated as writable", {
  # `formals(sum)` is NULL, so the naive `length(formals(...)) >= 1` check
  # would mis-classify primitives as 0-arg no-ops. They do accept arguments,
  # so they must get a write handler. Binding `sum` to `value` is silly,
  # but the classification rule still has to be right.
  expect_true(can_accept_write(sum))
  expect_true(can_accept_write(`+`))
})

test_that("checked reads from e$checked, value reads from e$value", {
  # The synthetic handler reads the event field whose name matches the prop
  # — this is the DOM-IDL alignment the autobind table encodes.
  rv_checked <- shiny::reactiveVal(FALSE)
  res_checked <- process_tags(
    tags$input(type = "checkbox", checked = rv_checked)
  )
  expect_equal(res_checked$events[[1]]$event, "change")
  res_checked$events[[1]]$handler(list(checked = TRUE))
  expect_true(shiny::isolate(rv_checked()))

  rv_value <- shiny::reactiveVal("")
  res_value <- process_tags(tags$select(value = rv_value))
  expect_equal(res_value$events[[1]]$event, "input")
  res_value$events[[1]]$handler(list(value = "opt-2"))
  expect_equal(shiny::isolate(rv_value()), "opt-2")
})

test_that("autobind handler reads correct key when prop is not last", {
  # Regression: `make_autobind_handler` used to capture `attr_name` lazily,
  # so the closure resolved it via the for-loop's final `name` binding —
  # any non-reactive attribute after `value`/`checked` would silently
  # redirect the read to the wrong event field.
  rv_value <- shiny::reactiveVal("init")
  res_value <- process_tags(
    tags$input(value = rv_value, class = "form-control")
  )
  res_value$events[[1]]$handler(list(value = "typed", class = "irrelevant"))
  expect_equal(shiny::isolate(rv_value()), "typed")

  rv_checked <- shiny::reactiveVal(FALSE)
  res_checked <- process_tags(
    tags$input(type = "checkbox", checked = rv_checked, class = "x")
  )
  res_checked$events[[1]]$handler(list(checked = TRUE, class = "irrelevant"))
  expect_true(shiny::isolate(rv_checked()))
})

# --- Collision merge & handler ordering --------------------------------------
#
# When auto-bind synthetic and explicit `on*` collide on the same DOM event,
# process_tags merges them into one event entry (one observer, one JS
# listener). Auto-bind handlers run before explicit `on*` handlers; within
# each tier, source-attribute order is preserved.

test_that("value + onInput merges into one entry on `input`", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, onInput = function(e) NULL)
  )
  expect_length(result$events, 1L)
  expect_equal(result$events[[1]]$event, "input")
})

test_that("checked + onChange on a checkbox merges into one entry on `change`", {
  rv <- shiny::reactiveVal(FALSE)
  result <- process_tags(
    tags$input(type = "checkbox", checked = rv, onChange = function(e) NULL)
  )
  expect_length(result$events, 1L)
  expect_equal(result$events[[1]]$event, "change")
})

test_that("value + onChange on a <select> does NOT merge (different DOM events)", {
  # `value`'s synthetic event is `input`, the explicit handler is `change`,
  # so they stay as two separate event entries.
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$select(value = rv, onChange = function(e) NULL)
  )
  expect_length(result$events, 2L)
  events <- vapply(result$events, function(e) e$event, character(1L))
  expect_setequal(events, c("input", "change"))
})

test_that("value + onClick stays as two separate entries (no collision)", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, onClick = function() NULL)
  )
  expect_length(result$events, 2L)
  events <- vapply(result$events, function(e) e$event, character(1L))
  expect_setequal(events, c("input", "click"))
})

test_that("merged composed handler has 2 formals and is called as `(event, id)`", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, onInput = function(e, id) NULL)
  )
  expect_length(result$events, 1L)
  expect_equal(length(formals(result$events[[1]]$handler)), 2L)
})

test_that("auto-bind write lands before explicit `on*` regardless of source order", {
  # The explicit handler must observe the post-autobind state — cosmetic
  # attribute reordering can't change behavior.
  for (build in list(
    function(rv, h) tags$input(value = rv, onInput = h),
    function(rv, h) tags$input(onInput = h, value = rv)
  )) {
    rv <- shiny::reactiveVal("init")
    observed <- NULL
    h <- function(e) observed <<- shiny::isolate(rv())
    result <- process_tags(build(rv, h))
    expect_length(result$events, 1L)
    result$events[[1]]$handler(list(value = "typed"), "id")
    expect_equal(shiny::isolate(rv()), "typed")
    expect_equal(observed, "typed")
  }
})

test_that("two explicit handlers on the same DOM event compose in source order", {
  # Rare but supported — htmltools allows duplicate attribute names in a
  # single tag() call, so a user could attach two `onInput`s and both must
  # run. Source order is preserved within the explicit tier.
  calls <- character()
  h1 <- function(e) calls <<- c(calls, "h1")
  h2 <- function(e) calls <<- c(calls, "h2")
  result <- process_tags(
    htmltools::tag("input", list(onInput = h1, onInput = h2))
  )
  expect_length(result$events, 1L)
  result$events[[1]]$handler(list(value = "x"), "id")
  expect_equal(calls, c("h1", "h2"))
})

test_that("explicit-handler arity is preserved through composition", {
  rv <- shiny::reactiveVal("")
  saw_zero <- FALSE
  saw_one <- NULL
  saw_two <- NULL
  zero <- function() saw_zero <<- TRUE
  one  <- function(e) saw_one <<- e$value
  two  <- function(e, id) saw_two <<- id
  # Stack three explicit `onInput` handlers (different arities) plus a
  # `value = rv` autobind. The composed handler must dispatch each by its
  # own arity.
  result <- process_tags(
    htmltools::tag("input", list(
      value = rv, onInput = zero, onInput = one, onInput = two
    ))
  )
  expect_length(result$events, 1L)
  result$events[[1]]$handler(list(value = "typed"), "el-id")
  expect_equal(shiny::isolate(rv()), "typed")
  expect_true(saw_zero)
  expect_equal(saw_one, "typed")
  expect_equal(saw_two, "el-id")
})

# --- Per-event default timing ------------------------------------------------
#
# The default rule is keyed only on the DOM event name, so a standalone
# `onInput` and an auto-bind `value = rv` resolve to the same default —
# adding `value = rv` to an existing `onInput` doesn't shift its timing.

test_that("explicit onInput defaults to event_debounce(200)", {
  result <- process_tags(tags$input(onInput = function(e) NULL))
  expect_equal(result$events[[1]]$mode, "debounce")
  expect_equal(result$events[[1]]$ms, 200)
})

test_that("explicit onChange defaults to event_immediate()", {
  result <- process_tags(tags$input(onChange = function(e) NULL))
  expect_equal(result$events[[1]]$mode, "immediate")
})

test_that("explicit onClick defaults to event_immediate()", {
  result <- process_tags(tags$button(onClick = function() NULL))
  expect_equal(result$events[[1]]$mode, "immediate")
})

test_that("autobind value defaults to event_debounce(200) (input event)", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(tags$input(value = rv))
  expect_equal(result$events[[1]]$mode, "debounce")
  expect_equal(result$events[[1]]$ms, 200)
})

test_that("autobind checked defaults to event_immediate() (change event)", {
  rv <- shiny::reactiveVal(FALSE)
  result <- process_tags(tags$input(type = "checkbox", checked = rv))
  expect_equal(result$events[[1]]$mode, "immediate")
})

test_that("merged value + onInput inherits the input-event default (debounce 200)", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, onInput = function(e) NULL)
  )
  expect_equal(result$events[[1]]$mode, "debounce")
  expect_equal(result$events[[1]]$ms, 200)
})

test_that("merged checked + onChange resolves to immediate (change-event default)", {
  rv <- shiny::reactiveVal(FALSE)
  result <- process_tags(
    tags$input(type = "checkbox", checked = rv, onChange = function(e) NULL)
  )
  expect_equal(result$events[[1]]$mode, "immediate")
})

test_that("element-level .event overrides the per-event default", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, .event = event_immediate())
  )
  expect_equal(result$events[[1]]$mode, "immediate")
})

# --- Misuse: irid construct passed as an attribute value ---------------------
#
# Any value with an `irid_*` class falls into the "irid construct" bucket
# and is meaningful only in specific positions (`.event` prop, child slot).
# As an attribute value it would silently fall through to `kept_attribs` and
# get serialized as raw HTML; process_tags must reject this loudly.

test_that("event_immediate() on an `on*` prop errors with a tailored hint", {
  expect_error(
    process_tags(tags$button(onClick = event_immediate())),
    "irid_event_config"
  )
  # The hint names the offending prop and points at both halves of the
  # split: handler goes on `on*`, timing config goes on `.event`.
  expect_error(
    process_tags(tags$button(onClick = event_immediate())),
    "timing config, not a handler wrapper.*onClick.*\\.event"
  )
})

test_that("event config on a non-`on*` attribute uses a generic hint", {
  # `class = event_immediate()` is misuse but not a migration shape — the
  # `on*`-tailored hint would be misleading, so the generic message kicks in.
  expect_error(
    process_tags(tags$div(class = event_immediate())),
    "Event configs belong on the element-level `\\.event` prop"
  )
})

test_that("event_throttle() / event_debounce() on an `on*` prop also error", {
  expect_error(
    process_tags(tags$button(onClick = event_throttle(100))),
    "irid_event_config"
  )
  expect_error(
    process_tags(tags$input(onInput = event_debounce(200))),
    "irid_event_config"
  )
})

test_that("event_*() on a non-event attribute also errors", {
  # The check fires before the attribute name is interpreted, so it catches
  # the misuse anywhere — not just on `on*` props.
  expect_error(
    process_tags(tags$div(class = event_immediate())),
    "irid_event_config"
  )
})

test_that("control-flow nodes as attribute values error with a child-slot hint", {
  # Each / Index / When / Match are children, never attributes.
  expect_error(
    process_tags(tags$div(class = Each(\() 1:3, \(i) tags$span(i)))),
    "irid_each.*children"
  )
  expect_error(
    process_tags(tags$div(class = When(\() TRUE, "yes"))),
    "irid_when.*children"
  )
  expect_error(
    process_tags(tags$div(class = Match(Default("hi")))),
    "irid_match.*children"
  )
})

test_that("Output node as an attribute value errors", {
  expect_error(
    process_tags(tags$div(class = PlotOutput(\() plot(1)))),
    "irid_output.*children"
  )
})

test_that("error message mentions the offending attribute name", {
  expect_error(
    process_tags(tags$button(onClick = event_immediate())),
    "onClick"
  )
  expect_error(
    process_tags(tags$div(class = Each(\() 1:3, \(i) tags$span(i)))),
    "class"
  )
})

test_that("normalize_element_event(list()) errors with an emptiness hint", {
  # `htmltools::tag()` drops empty-list attribs before process_tags sees
  # them, so this branch is reachable only via a hand-built tag or a
  # direct call. Test via the helper so we still pin the message shape
  # for the defensive path.
  expect_error(normalize_element_event(list()), "empty")
})

test_that("`.event` with unnamed entries errors with a naming hint", {
  expect_error(
    process_tags(
      tags$input(
        value = shiny::reactiveVal(""),
        .event = list(event_debounce(100))
      )
    ),
    "fully named"
  )
})

test_that("event_*() is still valid as the `.event` element prop", {
  # `.event` is stripped before the per-attribute loop, so a config there
  # must NOT trigger the misuse error.
  expect_silent(
    process_tags(
      tags$button(
        "Save",
        onClick = function() NULL,
        .event = event_throttle(500)
      )
    )
  )
})

test_that("control-flow nodes are still valid as children", {
  # The misuse guard fires only inside the per-attribute loop. Children get
  # walked separately and continue to produce control_flow entries normally.
  result <- process_tags(
    tags$div(Each(\() 1:3, \(i) tags$span(i)))
  )
  expect_length(result$control_flows, 1L)
  expect_equal(result$control_flows[[1]]$type, "each")
})

# --- Element-level `.event` overrides ----------------------------------------
#
# `.event` accepts either a single config (broadcasts to every event entry on
# the element) or a named list keyed by lowercase DOM event name (or `on`-prop
# form) for per-event overrides. Events absent from the list fall back to the
# per-event default rule.

# Find an event entry by DOM event name. Order isn't guaranteed once entries
# are merged, so prefer name-based lookup over positional indexing.
event_by_name <- function(result, event_name) {
  matches <- Filter(function(e) e$event == event_name, result$events)
  if (length(matches) != 1L) {
    stop("expected exactly 1 event named '", event_name, "', got ",
         length(matches))
  }
  matches[[1]]
}

test_that("scalar .event applies to every event entry on the element", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(
      value = rv,
      onKeyDown = function(e) NULL,
      .event = event_throttle(500)
    )
  )
  for (e in result$events) {
    expect_equal(e$mode, "throttle")
    expect_equal(e$ms, 500)
  }
})

test_that("named .event overrides per event; unmapped events fall back to defaults", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(
      value = rv,
      onKeyDown = function(e) NULL,
      onClick = function(e) NULL,
      .event = list(
        input = event_throttle(500),
        keydown = event_immediate(coalesce = TRUE)
      )
    )
  )
  input_e <- event_by_name(result, "input")
  expect_equal(input_e$mode, "throttle")
  expect_equal(input_e$ms, 500)

  keydown_e <- event_by_name(result, "keydown")
  expect_equal(keydown_e$mode, "immediate")
  expect_true(keydown_e$coalesce)

  # `click` isn't in the .event list — falls back to the per-event default
  # (immediate for non-input events).
  click_e <- event_by_name(result, "click")
  expect_equal(click_e$mode, "immediate")
})

test_that(".event keys accept both DOM-event and on-prop form, both normalize", {
  # `onInput` and `input` should resolve to the same lookup entry.
  rv1 <- shiny::reactiveVal("")
  res_dom <- process_tags(
    tags$input(value = rv1, .event = list(input = event_throttle(300)))
  )
  expect_equal(res_dom$events[[1]]$mode, "throttle")
  expect_equal(res_dom$events[[1]]$ms, 300)

  rv2 <- shiny::reactiveVal("")
  res_on <- process_tags(
    tags$input(value = rv2, .event = list(onInput = event_throttle(300)))
  )
  expect_equal(res_on$events[[1]]$mode, "throttle")
  expect_equal(res_on$events[[1]]$ms, 300)
})

test_that(".event = scalar non-config errors with type hint", {
  # A bare value that's neither a config nor a list — caught up front.
  expect_error(
    process_tags(
      tags$input(value = shiny::reactiveVal(""), .event = 5)
    ),
    "must be an `irid_event_config`"
  )
})

test_that(".event list with a non-config entry errors with the offending key", {
  # The error message should name the original (pre-normalization) key so the
  # user can find it in their source.
  expect_error(
    process_tags(
      tags$input(
        value = shiny::reactiveVal(""),
        .event = list(input = event_immediate(), onClick = 5)
      )
    ),
    "\\.event\\$onClick.*irid_event_config"
  )
})

test_that(".event = irid construct errors with a children-belong hint", {
  # Control-flow nodes are lists, so without the up-front irid-class check
  # they'd reach the keyed-list path and surface a confusing
  # `.event$<internal-field>` error.
  expect_error(
    process_tags(
      tags$input(
        value = shiny::reactiveVal(""),
        .event = Each(\() 1:3, \(i) tags$span(i))
      )
    ),
    "irid_each.*children"
  )
})

test_that(".event with duplicate keys after normalization errors", {
  # `input` and `onInput` collapse to the same DOM event — must not silently
  # pick one. The error names the duplicate.
  expect_error(
    process_tags(
      tags$input(
        value = shiny::reactiveVal(""),
        .event = list(input = event_immediate(), onInput = event_throttle(100))
      )
    ),
    "duplicate event names.*input"
  )
})

# --- Element-level `.prevent_default` ----------------------------------------
#
# `.prevent_default` mirrors `.event`'s shape. A logical scalar broadcasts to
# every event entry; a named list keyed by DOM event (or `on`-prop) overrides
# per event. Unmapped events default to `FALSE`.

test_that("without .prevent_default, every event entry has prevent_default = FALSE", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, onKeyDown = function(e) NULL)
  )
  for (e in result$events) expect_false(e$prevent_default)
})

test_that(".prevent_default = TRUE propagates to every event entry", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(
      value = rv,
      onKeyDown = function(e) NULL,
      onClick = function(e) NULL,
      .prevent_default = TRUE
    )
  )
  for (e in result$events) expect_true(e$prevent_default)
})

test_that(".prevent_default = FALSE is accepted explicitly", {
  rv <- shiny::reactiveVal("")
  result <- process_tags(
    tags$input(value = rv, .prevent_default = FALSE)
  )
  expect_false(result$events[[1]]$prevent_default)
})

test_that("named .prevent_default overrides per event; unmapped events default to FALSE", {
  result <- process_tags(
    tags$form(
      onSubmit = function(e) NULL,
      onClick = function(e) NULL,
      .prevent_default = list(submit = TRUE)
    )
  )
  expect_true(event_by_name(result, "submit")$prevent_default)
  expect_false(event_by_name(result, "click")$prevent_default)
})

test_that(".prevent_default keys accept both DOM-event and on-prop form", {
  res_dom <- process_tags(
    tags$form(
      onSubmit = function(e) NULL,
      .prevent_default = list(submit = TRUE)
    )
  )
  expect_true(res_dom$events[[1]]$prevent_default)

  res_on <- process_tags(
    tags$form(
      onSubmit = function(e) NULL,
      .prevent_default = list(onSubmit = TRUE)
    )
  )
  expect_true(res_on$events[[1]]$prevent_default)
})

test_that(".prevent_default scalar must be logical (not coerced)", {
  # The pre-named-list code used `isTRUE()`, which would silently coerce
  # `1`/`"yes"` to FALSE. The named-list-aware normalize is strict —
  # non-logical scalars error rather than fall through.
  expect_error(
    process_tags(
      tags$input(value = shiny::reactiveVal(""), .prevent_default = 1)
    ),
    "`TRUE`/`FALSE` or a named list"
  )
  expect_error(
    process_tags(
      tags$input(value = shiny::reactiveVal(""), .prevent_default = "yes")
    ),
    "`TRUE`/`FALSE` or a named list"
  )
})

test_that(".prevent_default = NA errors", {
  # Single NA is logical but not a useful answer — error rather than guess.
  expect_error(
    process_tags(
      tags$input(value = shiny::reactiveVal(""), .prevent_default = NA)
    ),
    "`TRUE`/`FALSE` or a named list"
  )
})

test_that(".prevent_default list with a non-logical entry errors with the offending key", {
  expect_error(
    process_tags(
      tags$form(
        onSubmit = function(e) NULL,
        .prevent_default = list(submit = "yes")
      )
    ),
    "\\.prevent_default\\$submit.*`TRUE` or `FALSE`"
  )
})

test_that(".prevent_default with unnamed entries errors with a naming hint", {
  expect_error(
    process_tags(
      tags$form(
        onSubmit = function(e) NULL,
        .prevent_default = list(TRUE)
      )
    ),
    "fully named"
  )
})

test_that(".prevent_default = irid construct errors before the keyed-list path", {
  # Both irid_event_config (a wrong-type misuse) and control-flow nodes are
  # lists, so without the up-front irid-class check they'd surface confusing
  # `.prevent_default$<internal-field>` errors from the keyed-list branch.
  expect_error(
    process_tags(
      tags$input(
        value = shiny::reactiveVal(""),
        .prevent_default = event_immediate()
      )
    ),
    "irid_event_config.*TRUE.*FALSE"
  )
  expect_error(
    process_tags(
      tags$div(
        onClick = function(e) NULL,
        .prevent_default = Each(\() 1:3, \(i) tags$span(i))
      )
    ),
    "irid_each.*TRUE.*FALSE"
  )
})

test_that(".prevent_default with duplicate keys after normalization errors", {
  expect_error(
    process_tags(
      tags$form(
        onSubmit = function(e) NULL,
        .prevent_default = list(submit = TRUE, onSubmit = FALSE)
      )
    ),
    "duplicate event names.*submit"
  )
})

test_that("normalize_element_prevent_default(list()) errors with an emptiness hint", {
  # Same defensive-path note as the `.event` empty-list test: htmltools
  # drops empty-list attribs before process_tags sees them, so this branch
  # is reachable only via the helper or a hand-built tag.
  expect_error(normalize_element_prevent_default(list()), "empty")
})
