# Write-control pattern evaluation plan

## Goal

Compare patterns for how parents control writes through component
boundaries in irid's reactive store system. Produce worked examples,
then hand to an independent judge for evaluation.

## Background

Read these files for context (in order):

1. `dev/stores2/design.md` — the current store/auto-bind design
2. `dev/plotly-output-design.md` — PlotlyOutput as a complex
   component case study
3. `dev/stores2/design-anti.md` — devil's advocate arguments
   against unified callables

### Core concepts the executor needs to understand

- **Unified callables.** Every piece of state is a function:
  `x()` reads, `x(value)` writes. Store leaves, `reactiveVal`s,
  and per-item accessors inside `Each` all follow this protocol.

- **Auto-bind.** State-binding props (`value`, `checked`,
  `selected`) accept a callable and automatically read from it
  and write back to it on the corresponding DOM event. No
  explicit `onInput` handler needed for the common case.

- **`onInput` disabling auto-bind.** When `onInput` is provided
  on a DOM element, it takes over the write path. Auto-bind still
  reads from the callable for rendering but does not write back.

- **Mini-stores in `Each`.** When `Each` iterates a collection of
  records, each item is wrapped in a per-item mini-store — a
  read-only projection with synthetic setters that route writes
  through the parent collection.

- **`.event` config.** Element-level prop controlling timing
  (debounce, throttle, immediate). Default for auto-bound
  `value`: `event_debounce(200)`.

## Patterns to compare

### (a) Current design (unified callables + `onInput`)

The baseline from `design.md`. No component-boundary write
control. Validation happens at the DOM element via `onInput`.
Components take a callable. Read-only via `\() field()`.

### (b) `onChange` only (React-style)

No auto-bind. Components always receive a read-only value +
`onChange` callback. Every write is explicit. Pairs thread through
every boundary.

### (c) Auto-bind + optional `onChange`

Components accept a callable (auto-bind by default) and an
optional `onChange` that takes over the write path when provided.
Component authors collapse the pair internally:
`write <- onChange %||% \(v) field(v)`.

### (d) Auto-bind + `reactiveView`

A `reactiveView` wraps a single callable with custom `get`
(read transform) and `set` (write handler). The result is a
callable — `view()` reads through `get`, `view(value)` calls
`set`. Auto-bind works unchanged.

The `set` function writes directly to state — it is a side-
effectful handler, not a pure transform. Because `set` is a
closure, it can read sibling state for cross-field validation
without needing a branch-level view. Convention: keep view
`get`/`set` simple (transforms, validation gates). Complex side
effects belong in `observe()`.

```r
# Bidirectional transform
temp_f <- reactiveView(state$temp_c,
  get = \(c) c * 9/5 + 32,
  set = \(f) state$temp_c((f - 32) * 5/9)
)

# Validation gate
reactiveView(state$email,
  set = \(v) if (is_valid_email(v)) state$email(v)
)

# Read-only
reactiveView(state$email, set = NULL)

# Cross-field validation (closure reads sibling)
reactiveView(state$date_range$end,
  set = \(v) if (v > state$date_range$start()) state$date_range$end(v)
)

# Formatting
reactiveView(state$price,
  get = \(v) format_currency(v),
  set = \(v) state$price(parse_currency(v))
)
```

Subsumes write-only interception (just `get = identity`), read-
only views (`set = NULL`), and bidirectional transforms under one
primitive.

## Examples to write

Each example should be written in all four patterns (a–d). The
examples are chosen to stress different boundary concerns. For
each example, show: (1) the component author's code, (2) the
parent's code for the common case (no validation), and (3) the
parent's code for the validated/constrained case.

### 1. Validated leaf — EmailInput

Single field, single event. Parent wants only valid emails written.

Stresses: basic write interception at a component boundary.

### 2. Bidirectional transform — TemperatureInput

Store holds Celsius. Component displays and edits in Fahrenheit.

Stresses: read AND write transforms. Only (d) has a natural
answer; the others must improvise. This example discriminates
`reactiveView` from the rest.

### 3. Nested components — ColorPicker

`ColorPicker` contains `HueSlider` and `SaturationSlider`. Parent
wants to constrain hue to a warm range (0.0–0.15). Hue and
saturation are written by independent slider events.

Stresses: write control threading through intermediate components.
Does the pattern require the intermediate (`ColorPicker`) to know
about the constraint?

### 4. `Each` with custom item components — TodoItem

Todo list. Each item rendered by `TodoItem`. Parent wants non-empty
text validation. `done` and `text` are written by independent DOM
events (checkbox vs text input).

Stresses: per-field validation without cross-field leak. In
pattern (d), wrap the leaf (`text`), not the record.

### 5. Third-party component — RichTextEditor

A `RichTextEditor` from a package that accepts a single callable
and writes to it. Can't modify. Parent needs max length.

Stresses: write interception on a component you don't control.

### 6. Atomic multi-field — PlotlyOutput

PlotlyOutput with relayout state (`xaxis_range`, `yaxis_range`,
`dragmode`) that arrives atomically in one event, plus `selected`
that arrives in a separate event. Parent wants to constrain x-axis
zoom range.

Stresses: atomic cross-field validation. The parent intercepts
the atomic event and validates before writing to the store —
no branch-level view needed.

Show both the unconstrained (common) and constrained cases.

### 7. Formatted display — CurrencyInput

Store holds a numeric cents value. Input displays formatted
dollars (e.g. "$12.34"). Edits parse back to cents.

Stresses: display formatting + parse on write. Another
discriminator for `reactiveView`.

## Evaluation criteria for the judge

After the examples are written, an independent judge should
evaluate each pattern on:

1. **Common-case simplicity.** How much code for the no-validation
   case? Component author burden?

2. **Validated-case ceremony.** How much extra code for the
   constrained case? Is the constraint visible at the call site?

3. **Composability.** Does the pattern thread through component
   boundaries without pair-threading or tree duplication?

4. **Fine-grained reactivity.** Does the pattern preserve field-
   level reactivity from stores/mini-stores?

5. **Cross-field validation leak.** When validating one field,
   does the pattern accidentally gate unrelated fields?

6. **Atomic cross-field validation.** Can you validate multiple
   fields that arrive in one event as a unit?

7. **Third-party support.** Can the parent constrain writes
   through a component it can't modify?

8. **Bidirectional transforms.** Can the pattern express read+write
   transforms (temperature, currency) naturally?

9. **Visibility of write policy.** Can a developer read the code
   locally and understand what happens on write? Or is write
   behavior hidden in closures created elsewhere?

10. **Conceptual weight.** How many concepts does a new developer
    need to learn? Is the pattern a natural extension of existing
    concepts or a new paradigm?

The judge should also flag:
- Scenarios the examples missed
- Whether `onInput` is still needed as an escape hatch in pattern
  (d), or if it can be dropped entirely
- Whether leaf-only `reactiveView` is sufficient, or if a
  branch-level variant is needed for any example
- Whether `reactiveView` adds too much conceptual weight vs the
  problems it solves

## Process

1. **Executor** writes all examples (7 examples x 4 patterns =
   28 code blocks) in `examples.md` in this directory. Include
   brief annotations per block noting what works and what doesn't.
   Do not editorialize on which pattern is best.

2. **Judge** reads `examples.md`, evaluates against the criteria
   above, and writes a recommendation in `verdict.md` in this
   directory.
