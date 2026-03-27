# nacre MVP Implementation Plan

## Context

nacre is a thin rendering layer on top of Shiny that replaces `renderUI` with Solid-style fine-grained DOM bindings. The project currently has only a design doc — no implementation code. The goal is to build the bare minimum to validate the concept by running two examples: a counter/slider app and 3 synced textboxes.

## Target Examples

Both examples use `nacreOutput`/`renderNacre` inside a standard Shiny app.

**Counter app:**
```r
library(shiny)
library(nacre)

CounterApp <- function() {
  count <- reactiveVal(0)
  color <- reactiveVal("black")

  tags$div(
    tags$h1(
      style = \() paste0("color:", color()),
      \() paste("Count:", count())
    ),
    tags$input(
      type = "range", min = 0, max = 100,
      value = count,
      onInput = \(value) count(as.numeric(value))
    ),
    tags$button(
      disabled = \() count() == 0,
      onClick = \() count(0),
      "Reset"
    )
  )
}

ui <- fluidPage(
  nacreOutput("app")
)

server <- function(input, output, session) {
  output$app <- renderNacre({
    CounterApp()
  })
}

shinyApp(ui, server)
```

**Synced textboxes:**
```r
library(shiny)
library(nacre)

SyncedInputs <- function() {
  name <- reactiveVal("")

  tags$div(
    tags$input(type = "text", value = name,
      onInput = \(value) name(value)),
    tags$input(type = "text", value = name,
      onInput = \(value) name(value)),
    tags$input(type = "text", value = name,
      onInput = \(value) name(value))
  )
}

ui <- fluidPage(
  nacreOutput("sync")
)

server <- function(input, output, session) {
  output$sync <- renderNacre({
    SyncedInputs()
  })
}

shinyApp(ui, server)
```

## Architecture

Built on top of Shiny's existing output system:

1. **`nacreOutput(id)`** — returns a `uiOutput(id)` placeholder (Shiny renders this as a div) plus the nacre JS dependency
2. **`renderNacre(expr)`** — uses `renderUI` internally for the one-time initial HTML mount. The expression builds a tag tree with reactive closures but no reactive reads during construction, so `renderUI` sees no dependencies and runs once. After the HTML is flushed to the client, observers are set up for reactive bindings and event listeners are registered.

### Message Protocol

**Server → Client:**
- `nacre-attr` — `{id, attr, value}` — update a DOM property/attribute
- `nacre-events` — `[{id, event, inputId}, ...]` — tell client which elements need event listeners

**Client → Server:**
- `Shiny.setInputValue(inputId, {value, id, nonce}, {priority: "event"})` — forward DOM events

### Tag Tree Processing

Walk the tag tree recursively. For each `shiny.tag`:
- Assign a nacre ID (e.g. `nacre-1`) if the element has reactive attrs, events, or reactive children
- **Static attributes**: keep in HTML as-is
- **Reactive attributes** (non-`on*` functions): strip from HTML, record `{id, attr, fn}` binding
- **Event handlers** (`on*` functions): strip from HTML, record `{id, event, handler}` event
- **Reactive text children** (functions in children list): replace with `<span id="nacre-N">` placeholder, record `{id, attr: "textContent", fn}` binding

For reactive attribute initial values: each `observe()` fires immediately on creation, so the client will receive the initial value as soon as the session starts. No need to pre-compute initial values into the HTML.

### Key Design Decisions

1. **`disabled` and boolean attrs**: In JS, `el.disabled = false` removes the disabled state. The nacre-attr handler uses property assignment (`el[attr] = value`) for `value`, `disabled`, `checked`, `selected`; `setAttribute`/`removeAttribute` for others.

2. **Optimistic updates**: Client skips `value` updates on the focused element to avoid fighting the user's typing.

3. **Event → R mapping**: `onInput` maps to JS `input` event, `onClick` maps to `click` event. The JS event name is derived by lowercasing and stripping "on" prefix (e.g., `onInput` → `input`).

4. **Event callback arity**: Use `length(formals(handler))` to determine whether to pass `(value, id)`, `(value)`, or `()`.

5. **One-time mount via renderUI**: The `renderNacre` expression builds a tag tree with closures (no reactive reads during construction), so `renderUI` evaluates once. Observer setup is deferred via `session$onFlushed()` so the DOM exists before we start sending updates.

## Files to Create

### `DESCRIPTION`
Standard R package metadata. Depends on `shiny`, `htmltools`.

### `NAMESPACE`
```
export(nacreOutput)
export(renderNacre)
import(shiny)
import(htmltools)
```

### `R/process_tags.R` (~80 lines)
- `nacre_id_generator()` — returns a closure that generates `nacre-1`, `nacre-2`, etc.
- `process_tags(tag, next_id)` — recursive tag tree walker. Returns a list with:
  - `$tag` — the cleaned tag tree (functions stripped, IDs added, reactive children replaced with `<span>` placeholders)
  - `$bindings` — list of `{id, attr, fn}` for reactive attributes and text
  - `$events` — list of `{id, event, handler}` for event callbacks

### `R/nacre_output.R` (~50 lines)
- `nacreOutput(id)` — returns `tagList(uiOutput(id), nacre_dependency())`
- `renderNacre(expr)` — wraps `renderUI`, processes tag tree, defers observer setup via `session$onFlushed()`

### `R/nacre_deps.R` (~10 lines)
- `nacre_dependency()` — returns `htmltools::htmlDependency` pointing to `inst/js/nacre.js`

### `inst/js/nacre.js` (~40 lines)
- `Shiny.addCustomMessageHandler('nacre-attr', ...)` — update DOM property, skip if focused + value
- `Shiny.addCustomMessageHandler('nacre-events', ...)` — attach event listeners that call `Shiny.setInputValue`

## Implementation Order

1. `DESCRIPTION` + `NAMESPACE`
2. `inst/js/nacre.js` — client-side handlers
3. `R/nacre_deps.R` — JS dependency
4. `R/process_tags.R` — tag tree processing
5. `R/nacre_output.R` — `nacreOutput` + `renderNacre`

## Verification

1. `devtools::load_all()` the package
2. Run the counter app — verify slider moves, h1 text updates, style changes, disabled/reset works
3. Run the synced textboxes — type in one input, verify the other two update
