# Write-control pattern examples

Seven examples, four patterns each. For each example:
**(1)** component author's code, **(2)** parent's code (common case,
no validation), **(3)** parent's code (validated/constrained case).

---

## 1. Validated leaf — EmailInput

Single field, single event. Parent wants only valid emails written.

### (a) Current design (unified callables + `onInput`)

**Component author:**

```r
EmailInput <- function(email) {
  tags$input(type = "email", value = email)
}
```

**Parent — common case:**

```r
EmailInput(state$email)
```

**Parent — validated:**

No component-boundary mechanism. The parent cannot intercept writes
through `EmailInput` without modifying it. Options:

Option 1 — hand-roll a validating callable:

```r
validated <- function(v) {
  if (missing(v)) state$email()
  else if (is_valid_email(v)) state$email(v)
}
EmailInput(validated)
```

Option 2 — bypass the component and use `onInput` at the element:

```r
tags$input(
  type = "email",
  value = state$email,
  onInput = \(e) if (is_valid_email(e$value)) state$email(e$value)
)
```

> Hand-rolled callable works but is ad-hoc — not a framework-supported
> pattern. Bypassing the component defeats the purpose of having one.

### (b) `onChange` only (React-style)

**Component author:**

```r
EmailInput <- function(value, onChange) {
  tags$input(
    type = "email",
    value = value,
    onInput = \(e) onChange(e$value)
  )
}
```

**Parent — common case:**

```r
EmailInput(
  value = \() state$email(),
  onChange = \(v) state$email(v)
)
```

**Parent — validated:**

```r
EmailInput(
  value = \() state$email(),
  onChange = \(v) if (is_valid_email(v)) state$email(v)
)
```

> Validated case is a one-line change in the callback. But the common
> case always requires the boilerplate pair.

### (c) Auto-bind + optional `onChange`

**Component author:**

```r
EmailInput <- function(email, onChange = NULL) {
  write <- onChange %||% \(v) email(v)
  tags$input(
    type = "email",
    value = email,
    onInput = \(e) write(e$value)
  )
}
```

**Parent — common case:**

```r
EmailInput(state$email)
```

**Parent — validated:**

```r
EmailInput(
  state$email,
  onChange = \(v) if (is_valid_email(v)) state$email(v)
)
```

> Common case is clean. Validated case adds one prop. Component author
> pays the cost: must collapse `onChange` with the callable internally
> and always provide `onInput` (auto-bind never writes).

### (d) Auto-bind + `reactiveView`

**Component author:**

```r
EmailInput <- function(email) {
  tags$input(type = "email", value = email)
}
```

**Parent — common case:**

```r
EmailInput(state$email)
```

**Parent — validated:**

```r
validated_email <- reactiveView(
  state$email,
  set = \(v) if (is_valid_email(v)) state$email(v)
)
EmailInput(validated_email)
```

> Component author's code is identical to (a). Validation is at the
> call site via `reactiveView`. The view is a callable — the component
> doesn't know or care.

---

## 2. Bidirectional transform — TemperatureInput

Store holds Celsius. Component displays and edits in Fahrenheit.

### (a) Current design (unified callables + `onInput`)

**Component author:**

```r
TemperatureInput <- function(temp, label = "Temperature") {
  tags$div(
    tags$label(label),
    tags$input(type = "number", value = temp)
  )
}
```

**Parent — common case (no transform, Celsius in/out):**

```r
TemperatureInput(state$temp_c, label = "Celsius")
```

**Parent — Fahrenheit display with Celsius store:**

No component-boundary mechanism for bidirectional transforms. Options:

Option 1 — hand-roll a converting callable:

```r
temp_f <- function(v) {
  if (missing(v)) state$temp_c() * 9/5 + 32
  else state$temp_c((v - 32) * 5/9)
}
TemperatureInput(temp_f, label = "Fahrenheit")
```

Option 2 — bypass the component, transform in `onInput`:

```r
tags$input(
  type = "number",
  value = \() state$temp_c() * 9/5 + 32,
  onInput = \(e) state$temp_c((as.numeric(e$value) - 32) * 5/9)
)
```

> Both require the parent to manually implement both directions of
> the transform. The hand-rolled callable duplicates the conversion
> logic across read and write.

### (b) `onChange` only (React-style)

**Component author:**

```r
TemperatureInput <- function(value, onChange, label = "Temperature") {
  tags$div(
    tags$label(label),
    tags$input(
      type = "number",
      value = value,
      onInput = \(e) onChange(as.numeric(e$value))
    )
  )
}
```

**Parent — common case:**

```r
TemperatureInput(
  value = \() state$temp_c(),
  onChange = \(v) state$temp_c(v),
  label = "Celsius"
)
```

**Parent — Fahrenheit:**

```r
TemperatureInput(
  value = \() state$temp_c() * 9/5 + 32,
  onChange = \(v) state$temp_c((v - 32) * 5/9),
  label = "Fahrenheit"
)
```

> The read/write pair naturally holds the two directions. But the
> common case (no transform) still requires the full pair.

### (c) Auto-bind + optional `onChange`

**Component author:**

```r
TemperatureInput <- function(temp, onChange = NULL, label = "Temperature") {
  write <- onChange %||% \(v) temp(v)
  tags$div(
    tags$label(label),
    tags$input(
      type = "number",
      value = temp,
      onInput = \(e) write(as.numeric(e$value))
    )
  )
}
```

**Parent — common case:**

```r
TemperatureInput(state$temp_c, label = "Celsius")
```

**Parent — Fahrenheit:**

```r
TemperatureInput(
  \() state$temp_c() * 9/5 + 32,
  onChange = \(v) state$temp_c((v - 32) * 5/9),
  label = "Fahrenheit"
)
```

> The read transform is in the callable; the write transform is in
> `onChange`. The two directions are split across different arguments.
> The parent must keep them in sync manually.

### (d) Auto-bind + `reactiveView`

**Component author:**

```r
TemperatureInput <- function(temp, label = "Temperature") {
  tags$div(
    tags$label(label),
    tags$input(type = "number", value = temp)
  )
}
```

**Parent — common case:**

```r
TemperatureInput(state$temp_c, label = "Celsius")
```

**Parent — Fahrenheit:**

```r
temp_f <- reactiveView(
  state$temp_c,
  get = \(c) c * 9/5 + 32,
  set = \(f) state$temp_c((f - 32) * 5/9)
)
TemperatureInput(temp_f, label = "Fahrenheit")
```

> Both directions of the transform live in one place. The component
> is unchanged — it receives a callable. The `reactiveView` is a
> self-contained bidirectional adapter.

---

## 3. Nested components — ColorPicker

`ColorPicker` contains `HueSlider` and `SaturationSlider`. Parent
wants to constrain hue to warm range (0.0–0.15).

### (a) Current design (unified callables + `onInput`)

**Component authors:**

```r
HueSlider <- function(hue) {
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = hue
  )
}

SaturationSlider <- function(saturation) {
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = saturation
  )
}

ColorPicker <- function(color) {
  tags$div(
    HueSlider(color$hue),
    SaturationSlider(color$saturation)
  )
}
```

**Parent — common case:**

```r
state <- reactiveStore(list(color = list(hue = 0.5, saturation = 0.8)))
ColorPicker(state$color)
```

**Parent — constrained hue:**

No component-boundary mechanism. Options:

Option 1 — hand-roll a validating callable for `color$hue`:

```r
constrained_hue <- function(v) {
  if (missing(v)) state$color$hue()
  else if (v >= 0 && v <= 0.15) state$color$hue(v)
}
```

But the parent passes `state$color` (a branch) to `ColorPicker`,
not the individual fields. The parent cannot intercept a single
field's write path through the branch. The parent would need to
either modify `ColorPicker` or bypass it entirely.

Option 2 — bypass `ColorPicker`:

```r
tags$div(
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = state$color$hue,
    onInput = \(e) {
      v <- as.numeric(e$value)
      if (v >= 0 && v <= 0.15) state$color$hue(v)
    }
  ),
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = state$color$saturation
  )
)
```

> The branch-passing pattern (`ColorPicker(state$color)`) is
> compositional for the common case but opaque for the constrained
> case. The parent can't reach into the branch to constrain one field
> without restructuring.

### (b) `onChange` only (React-style)

**Component authors:**

```r
HueSlider <- function(value, onChange) {
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = value,
    onInput = \(e) onChange(as.numeric(e$value))
  )
}

SaturationSlider <- function(value, onChange) {
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = value,
    onInput = \(e) onChange(as.numeric(e$value))
  )
}

ColorPicker <- function(hue, onHueChange, saturation, onSaturationChange) {
  tags$div(
    HueSlider(hue, onHueChange),
    SaturationSlider(saturation, onSaturationChange)
  )
}
```

**Parent — common case:**

```r
ColorPicker(
  hue = \() state$color$hue(),
  onHueChange = \(v) state$color$hue(v),
  saturation = \() state$color$saturation(),
  onSaturationChange = \(v) state$color$saturation(v)
)
```

**Parent — constrained hue:**

```r
ColorPicker(
  hue = \() state$color$hue(),
  onHueChange = \(v) if (v >= 0 && v <= 0.15) state$color$hue(v),
  saturation = \() state$color$saturation(),
  onSaturationChange = \(v) state$color$saturation(v)
)
```

> The constraint is visible at the call site. But every field needs a
> value/onChange pair threaded through every component boundary.
> `ColorPicker` must expose individual fields — it can't accept a
> single branch. Four props for two fields. The intermediate
> `ColorPicker` threads every pair; adding a field means adding two
> props at every level.

### (c) Auto-bind + optional `onChange`

**Component authors:**

```r
HueSlider <- function(hue, onChange = NULL) {
  write <- onChange %||% \(v) hue(v)
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = hue,
    onInput = \(e) write(as.numeric(e$value))
  )
}

SaturationSlider <- function(saturation, onChange = NULL) {
  write <- onChange %||% \(v) saturation(v)
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = saturation,
    onInput = \(e) write(as.numeric(e$value))
  )
}

ColorPicker <- function(color, onHueChange = NULL, onSaturationChange = NULL) {
  tags$div(
    HueSlider(color$hue, onChange = onHueChange),
    SaturationSlider(color$saturation, onChange = onSaturationChange)
  )
}
```

**Parent — common case:**

```r
ColorPicker(state$color)
```

**Parent — constrained hue:**

```r
ColorPicker(
  state$color,
  onHueChange = \(v) if (v >= 0 && v <= 0.15) state$color$hue(v)
)
```

> Common case is clean — branch passing works. Constrained case adds
> one prop. But the intermediate `ColorPicker` must forward optional
> `onChange` props for every inner component it wants to be
> constrainable. The component author decides which fields are
> interceptable — if `onSaturationChange` wasn't exposed, the parent
> couldn't constrain it.

### (d) Auto-bind + `reactiveView`

**Component authors:**

```r
HueSlider <- function(hue) {
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = hue
  )
}

SaturationSlider <- function(saturation) {
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = saturation
  )
}

ColorPicker <- function(color) {
  tags$div(
    HueSlider(color$hue),
    SaturationSlider(color$saturation)
  )
}
```

**Parent — common case:**

```r
ColorPicker(state$color)
```

**Parent — constrained hue:**

```r
constrained_hue <- reactiveView(
  state$color$hue,
  set = \(v) if (v >= 0 && v <= 0.15) state$color$hue(v)
)
```

But the parent passes `state$color` (a branch) to `ColorPicker`.
The view wraps a leaf, not the branch. Two approaches:

Option 1 — pass the view as a separate prop (requires component change):

```r
ColorPicker <- function(color, hue_override = NULL) {
  tags$div(
    HueSlider(hue_override %||% color$hue),
    SaturationSlider(color$saturation)
  )
}

ColorPicker(state$color, hue_override = constrained_hue)
```

Option 2 — bypass `ColorPicker` and pass the view directly:

```r
tags$div(
  HueSlider(constrained_hue),
  SaturationSlider(state$color$saturation)
)
```

> The view works at the leaf level but the component accepts a branch.
> The parent can't inject a view into a branch's child without either
> modifying the component or bypassing it. Same structural limitation
> as (a) — branch-passing is opaque to per-field interception. The
> view itself is clean; the problem is threading it through the
> intermediate component.

---

## 4. `Each` with custom item components — TodoItem

Todo list. Each item rendered by `TodoItem`. Parent wants non-empty
text validation. `done` and `text` are written by independent DOM
events.

### (a) Current design (unified callables + `onInput`)

**Component author:**

```r
TodoItem <- function(todo) {
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = todo$text)
  )
}
```

**Parent — common case:**

```r
state <- reactiveStore(list(
  todos = list(
    list(id = 1L, text = "Learn irid", done = FALSE),
    list(id = 2L, text = "Ship stores", done = FALSE)
  )
))

tags$ul(
  Each(state$todos, by = \(t) t$id, \(todo) {
    TodoItem(todo)
  })
)
```

**Parent — validated text:**

No component-boundary mechanism for per-field interception on a
mini-store. The parent passes `todo` (a mini-store) to `TodoItem`.
Same problem as example 3: can't constrain one field without
modifying the component or bypassing it.

Option 1 — hand-roll a validating callable for `todo$text`:

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  validated_text <- function(v) {
    if (missing(v)) todo$text()
    else if (nchar(trimws(v)) > 0) todo$text(v)
  }
  # Can't pass to TodoItem without modifying it
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = validated_text)
  )
})
```

> Parent must bypass `TodoItem` to intercept `text` writes.
> `done` is unaffected — no cross-field leak in the bypass
> approach. But the component is unused.

### (b) `onChange` only (React-style)

**Component author:**

```r
TodoItem <- function(
  text, onTextChange,
  done, onDoneChange
) {
  tags$li(
    tags$input(
      type = "checkbox",
      value = done,
      onInput = \(e) onDoneChange(e$value)
    ),
    tags$input(
      value = text,
      onInput = \(e) onTextChange(e$value)
    )
  )
}
```

**Parent — common case:**

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  TodoItem(
    text = \() todo$text(),
    onTextChange = \(v) todo$text(v),
    done = \() todo$done(),
    onDoneChange = \(v) todo$done(v)
  )
})
```

**Parent — validated text:**

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  TodoItem(
    text = \() todo$text(),
    onTextChange = \(v) if (nchar(trimws(v)) > 0) todo$text(v),
    done = \() todo$done(),
    onDoneChange = \(v) todo$done(v)
  )
})
```

> No cross-field leak — `onDoneChange` is independent. But four
> props per item, all threaded explicitly. The mini-store's
> fine-grained fields are decomposed into value/onChange pairs and
> then reassembled inside the component.

### (c) Auto-bind + optional `onChange`

**Component author:**

```r
TodoItem <- function(todo, onTextChange = NULL, onDoneChange = NULL) {
  write_text <- onTextChange %||% \(v) todo$text(v)
  write_done <- onDoneChange %||% \(v) todo$done(v)
  tags$li(
    tags$input(
      type = "checkbox",
      checked = todo$done,
      onInput = \(e) write_done(e$value)
    ),
    tags$input(
      value = todo$text,
      onInput = \(e) write_text(e$value)
    )
  )
}
```

**Parent — common case:**

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  TodoItem(todo)
})
```

**Parent — validated text:**

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  TodoItem(
    todo,
    onTextChange = \(v) if (nchar(trimws(v)) > 0) todo$text(v)
  )
})
```

> Clean common case. Validated case adds one prop without affecting
> `done`. Component author must expose optional `onChange` per field
> and collapse each one internally.

### (d) Auto-bind + `reactiveView`

**Component author:**

```r
TodoItem <- function(todo) {
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = todo$text)
  )
}
```

**Parent — common case:**

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  TodoItem(todo)
})
```

**Parent — validated text:**

```r
Each(state$todos, by = \(t) t$id, \(todo) {
  validated_text <- reactiveView(
    todo$text,
    set = \(v) if (nchar(trimws(v)) > 0) todo$text(v)
  )
  # Can't pass to TodoItem without modifying it — same problem as (a)
  tags$li(
    tags$input(type = "checkbox", checked = todo$done),
    tags$input(value = validated_text)
  )
})
```

Alternatively, `TodoItem` could accept individual callables instead
of a mini-store:

```r
TodoItem <- function(done, text) {
  tags$li(
    tags$input(type = "checkbox", checked = done),
    tags$input(value = text)
  )
}

# Common case
Each(state$todos, by = \(t) t$id, \(todo) {
  TodoItem(done = todo$done, text = todo$text)
})

# Validated
Each(state$todos, by = \(t) t$id, \(todo) {
  validated_text <- reactiveView(
    todo$text,
    set = \(v) if (nchar(trimws(v)) > 0) todo$text(v)
  )
  TodoItem(done = todo$done, text = validated_text)
})
```

> If the component accepts a mini-store (branch), the parent can't
> inject a view into one field without bypassing the component. If
> the component accepts individual callables, the view threads
> through cleanly. The trade-off: branch-passing is simpler for the
> common case; individual callables enable per-field interception.
> No cross-field leak in either variant — `done` is untouched.

---

## 5. Third-party component — RichTextEditor

A `RichTextEditor` from a package that accepts a single callable
and writes to it. Can't modify. Parent needs max length.

### (a) Current design (unified callables + `onInput`)

**Component (third-party, unmodifiable):**

```r
# From a package — not our code
RichTextEditor <- function(content) {
  # ... internally does content(new_html) on edits
  # No onInput support, no onChange callback
}
```

**Parent — common case:**

```r
RichTextEditor(state$content)
```

**Parent — max length:**

Hand-roll a validating callable:

```r
constrained_content <- function(v) {
  if (missing(v)) state$content()
  else if (nchar(v) <= 10000) state$content(v)
}
RichTextEditor(constrained_content)
```

> Works but is ad-hoc. The parent manually implements the callable
> protocol (missing-arg dispatch) to intercept writes.

### (b) `onChange` only (React-style)

**Component (third-party, unmodifiable):**

```r
# Hypothetical: the package uses the value/onChange convention
RichTextEditor <- function(value, onChange) {
  # ... internally calls onChange(new_html) on edits
}
```

**Parent — common case:**

```r
RichTextEditor(
  value = \() state$content(),
  onChange = \(v) state$content(v)
)
```

**Parent — max length:**

```r
RichTextEditor(
  value = \() state$content(),
  onChange = \(v) if (nchar(v) <= 10000) state$content(v)
)
```

> Clean — but only if the third-party component follows the
> value/onChange convention. If it uses a different convention
> (single callable, different prop name), you're stuck.

### (c) Auto-bind + optional `onChange`

**Component (third-party, unmodifiable):**

```r
# If the package accepts a callable but not onChange:
RichTextEditor <- function(content) {
  # ... internally does content(new_html) on edits
}
```

**Parent — common case:**

```r
RichTextEditor(state$content)
```

**Parent — max length:**

Same as (a) — the component doesn't accept `onChange`, so the
parent must hand-roll a validating callable:

```r
constrained_content <- function(v) {
  if (missing(v)) state$content()
  else if (nchar(v) <= 10000) state$content(v)
}
RichTextEditor(constrained_content)
```

> `onChange` only helps when the component supports it. Third-party
> components that take a callable without `onChange` fall back to
> ad-hoc wrapping.

### (d) Auto-bind + `reactiveView`

**Component (third-party, unmodifiable):**

```r
RichTextEditor <- function(content) {
  # ... internally does content(new_html) on edits
}
```

**Parent — common case:**

```r
RichTextEditor(state$content)
```

**Parent — max length:**

```r
constrained_content <- reactiveView(
  state$content,
  set = \(v) if (nchar(v) <= 10000) state$content(v)
)
RichTextEditor(constrained_content)
```

> The view is a callable — it passes through unchanged. The
> third-party component doesn't need to support any interception
> protocol. This is the only pattern that provides a framework-
> supported mechanism for intercepting writes through components
> you don't control.

---

## 6. Atomic multi-field — PlotlyOutput

PlotlyOutput with relayout state (`xaxis_range`, `yaxis_range`,
`dragmode`) arriving atomically in one event, plus `selected` in
a separate event. Parent wants to constrain x-axis zoom range.

### (a) Current design (unified callables + `onInput`)

**Component (irid primitive):**

PlotlyOutput accepts a spec function, reactive state attributes,
and event callbacks. It writes to state via callbacks, not
auto-bind.

**Parent — common case (unconstrained):**

```r
ps <- plotly_state()

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  !!!ps,
  !!!plotly_sync(ps)
)
```

**Parent — constrained x-axis:**

Override the `onRelayout` callback:

```r
PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  !!!ps,
  !!!plotly_sync(ps,
    onRelayout = \(e) {
      xr <- e$xaxis_range
      if (!is.null(xr) && xr[1] >= 0 && xr[2] <= 100) {
        ps$xaxis_range(xr)
      }
      ps$yaxis_range(e$yaxis_range)
      ps$dragmode(e$dragmode)
    }
  )
)
```

> The callback intercepts the atomic event and validates before
> writing each field. `selected` (separate event) is unaffected.
> The parent must manually re-sync all fields in the overridden
> callback — only `xaxis_range` is constrained, but `yaxis_range`
> and `dragmode` must be explicitly passed through.

### (b) `onChange` only (React-style)

**Parent — common case:**

Without auto-bind, there's no `plotly_sync` convenience. Every
field is wired manually:

```r
PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  xaxis_range = \() ps$xaxis_range(),
  yaxis_range = \() ps$yaxis_range(),
  dragmode = \() ps$dragmode(),
  selected = \() ps$selected(),
  onRelayout = \(e) {
    ps$xaxis_range(e$xaxis_range)
    ps$yaxis_range(e$yaxis_range)
    ps$dragmode(e$dragmode)
  },
  onSelected = \(e) ps$selected(e$points)
)
```

**Parent — constrained x-axis:**

```r
PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  xaxis_range = \() ps$xaxis_range(),
  yaxis_range = \() ps$yaxis_range(),
  dragmode = \() ps$dragmode(),
  selected = \() ps$selected(),
  onRelayout = \(e) {
    xr <- e$xaxis_range
    if (!is.null(xr) && xr[1] >= 0 && xr[2] <= 100) {
      ps$xaxis_range(xr)
    }
    ps$yaxis_range(e$yaxis_range)
    ps$dragmode(e$dragmode)
  },
  onSelected = \(e) ps$selected(e$points)
)
```

> Validated case is nearly identical to common case — one
> conditional added. But the common case is already verbose. No
> splice convenience, every field wired explicitly.

### (c) Auto-bind + optional `onChange`

The `plotly_sync` approach already works like an optional
`onChange` — the sync helper generates callbacks, and you can
override individual ones. Pattern (c) is structurally identical
to pattern (a) for PlotlyOutput since the component uses
callbacks rather than auto-bind for write-back.

```r
# Identical to (a) — plotly_sync is pattern (c) applied to a
# component that uses callbacks
PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  !!!ps,
  !!!plotly_sync(ps,
    onRelayout = \(e) {
      xr <- e$xaxis_range
      if (!is.null(xr) && xr[1] >= 0 && xr[2] <= 100) {
        ps$xaxis_range(xr)
      }
      ps$yaxis_range(e$yaxis_range)
      ps$dragmode(e$dragmode)
    }
  )
)
```

> `plotly_sync` is effectively the "optional onChange" pattern at
> the event level. Overriding one callback still requires manually
> re-syncing all fields in that event.

### (d) Auto-bind + `reactiveView`

**Parent — common case:**

Same as (a):

```r
ps <- plotly_state()

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  !!!ps,
  !!!plotly_sync(ps)
)
```

**Parent — constrained x-axis:**

Wrap the single field in a view:

```r
constrained_xrange <- reactiveView(
  ps$xaxis_range,
  set = \(v) if (!is.null(v) && v[1] >= 0 && v[2] <= 100) ps$xaxis_range(v)
)

PlotlyOutput(
  \() plot_ly(df(), x = ~mpg, y = ~hp, type = "scatter"),
  xaxis_range = constrained_xrange,
  yaxis_range = ps$yaxis_range,
  dragmode = ps$dragmode,
  selected = ps$selected,
  onRelayout = \(e) {
    constrained_xrange(e$xaxis_range)
    ps$yaxis_range(e$yaxis_range)
    ps$dragmode(e$dragmode)
  },
  onSelected = \(e) ps$selected(e$points)
)
```

> The validation logic lives in the view, but the parent still
> writes a manual callback because the atomic event bundles
> multiple fields. The view prevents the validation from leaking
> into the callback body — `constrained_xrange(e$xaxis_range)`
> encapsulates the gate. But you lose the `plotly_sync` convenience
> since the view is outside the store.
>
> Alternative: if `plotly_sync` could accept views in place of
> store nodes, the constrained case would be:
>
> ```r
> !!!plotly_sync(ps, xaxis_range = constrained_xrange)
> ```
>
> This would let the sync helper route `xaxis_range` writes
> through the view while auto-syncing everything else. Worth
> considering as a `plotly_sync` enhancement.

---

## 7. Formatted display — CurrencyInput

Store holds a numeric cents value. Input displays formatted
dollars (e.g. "$12.34"). Edits parse back to cents.

### (a) Current design (unified callables + `onInput`)

**Component author:**

```r
CurrencyInput <- function(amount, label = "Amount") {
  tags$div(
    tags$label(label),
    tags$input(value = amount)
  )
}
```

**Parent — common case (no formatting, raw cents):**

```r
CurrencyInput(state$price_cents)
```

**Parent — formatted dollars:**

Hand-roll a converting callable:

```r
price_dollars <- function(v) {
  if (missing(v)) sprintf("$%.2f", state$price_cents() / 100)
  else state$price_cents(round(as.numeric(gsub("[$,]", "", v)) * 100))
}
CurrencyInput(price_dollars, label = "Price")
```

Or bypass the component and use `onInput`:

```r
tags$input(
  value = \() sprintf("$%.2f", state$price_cents() / 100),
  onInput = \(e) {
    cents <- round(as.numeric(gsub("[$,]", "", e$value)) * 100)
    state$price_cents(cents)
  }
)
```

> Same issue as example 2 — bidirectional transform requires
> manual implementation of both directions.

### (b) `onChange` only (React-style)

**Component author:**

```r
CurrencyInput <- function(value, onChange, label = "Amount") {
  tags$div(
    tags$label(label),
    tags$input(
      value = value,
      onInput = \(e) onChange(e$value)
    )
  )
}
```

**Parent — common case:**

```r
CurrencyInput(
  value = \() state$price_cents(),
  onChange = \(v) state$price_cents(as.numeric(v)),
  label = "Price"
)
```

**Parent — formatted dollars:**

```r
CurrencyInput(
  value = \() sprintf("$%.2f", state$price_cents() / 100),
  onChange = \(v) {
    cents <- round(as.numeric(gsub("[$,]", "", v)) * 100)
    state$price_cents(cents)
  },
  label = "Price"
)
```

> Read/write pair naturally holds both directions. Same verbosity
> cost as always.

### (c) Auto-bind + optional `onChange`

**Component author:**

```r
CurrencyInput <- function(amount, onChange = NULL, label = "Amount") {
  write <- onChange %||% \(v) amount(v)
  tags$div(
    tags$label(label),
    tags$input(
      value = amount,
      onInput = \(e) write(e$value)
    )
  )
}
```

**Parent — common case:**

```r
CurrencyInput(state$price_cents, label = "Price")
```

**Parent — formatted dollars:**

```r
CurrencyInput(
  \() sprintf("$%.2f", state$price_cents() / 100),
  onChange = \(v) {
    cents <- round(as.numeric(gsub("[$,]", "", v)) * 100)
    state$price_cents(cents)
  },
  label = "Price"
)
```

> Read transform is in the callable, write transform is in
> `onChange`. The two directions are split across arguments.

### (d) Auto-bind + `reactiveView`

**Component author:**

```r
CurrencyInput <- function(amount, label = "Amount") {
  tags$div(
    tags$label(label),
    tags$input(value = amount)
  )
}
```

**Parent — common case:**

```r
CurrencyInput(state$price_cents, label = "Price")
```

**Parent — formatted dollars:**

```r
price_display <- reactiveView(
  state$price_cents,
  get = \(cents) sprintf("$%.2f", cents / 100),
  set = \(v) state$price_cents(round(as.numeric(gsub("[$,]", "", v)) * 100))
)
CurrencyInput(price_display, label = "Price")
```

> Both directions in one place. Component unchanged. Same
> structural advantage as example 2.
