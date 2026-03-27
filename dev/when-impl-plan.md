# `When` Implementation Plan

## API

```r
When(condition, yes, otherwise = NULL)
```

- `condition` — a reactive function (e.g. `reactiveVal`, `reactive`, or `\() expr`)
- `yes` — tag tree to show when condition is truthy
- `otherwise` — tag tree to show when condition is falsy (or NULL to show nothing)

Both branches are constructed eagerly (at component setup time) but only the active branch is **mounted** (observers created). When the condition changes, the old branch's observers are destroyed and the new branch is mounted.

## Architecture Change

The current setup is one-shot: `process_tags` collects bindings/events, then `renderNacre` creates all observers at once. `When` requires dynamic mount/unmount. This means extracting observer setup into a reusable function.

### New function: `nacre_mount(tag_tree, session)`

Extracted from `renderNacre`'s `onFlushed` callback. Takes a processed-or-unprocessed tag tree, sets up all observers and event listeners, returns a handle with a `destroy()` method.

```r
nacre_mount(tag_tree, session)
# Returns:
#   $tag      — cleaned HTML (for sending to client)
#   $destroy  — function that destroys all observers created by this mount
```

`renderNacre` becomes a thin wrapper: process tags, mount, return HTML. `When`'s condition observer calls `nacre_mount` for the active branch and `$destroy()` on the old one.

### New marker: `nacre_when` object

`When()` returns a lightweight S3 object (not a tag):

```r
When <- function(condition, yes, otherwise = NULL) {
  structure(list(condition = condition, yes = yes, otherwise = otherwise),
            class = "nacre_when")
}
```

### `process_tags` changes

When `walk()` encounters a `nacre_when` object:
1. Emit a placeholder `<div id="nacre-N" style="display:contents"></div>`
2. Record a control flow entry: `{type = "when", id, condition, yes, otherwise}`
3. Do **not** walk into the branches — they'll be processed at mount time

Return value gains a `$control_flows` field alongside `$bindings` and `$events`.

### `nacre_mount` handles control flows

For each control flow entry, `nacre_mount` creates an `observe()` that:
1. Evaluates the condition
2. If changed: destroys the previous branch's mount, processes + mounts the new branch
3. Sends a `nacre-swap` message with the new branch's HTML
4. Sends `nacre-events` for the new branch's event listeners

Sub-mounts are tracked so `destroy()` tears down the entire tree (including nested `When`s).

## New JS Message Handler

### `nacre-swap`

```js
Shiny.addCustomMessageHandler('nacre-swap', function(msg) {
  // msg = { id, html }
  var el = document.getElementById(msg.id);
  if (!el) return;
  el.innerHTML = msg.html;
});
```

Need to also clean up the `defined` set for event listeners on elements that were inside the old content (they're gone from the DOM now). Simplest approach: scope the `defined` check to element existence rather than a set — or clear entries whose element no longer exists. Alternatively, since `nacre-events` re-registers listeners on the new elements (which have new IDs from the global counter), the old `defined` entries are inert and just accumulate. For now this is fine; the set can be pruned periodically or on swap if it becomes a concern.

## Files Changed

| File | Change |
|---|---|
| `R/when.R` | New — `When()` constructor |
| `R/mount.R` | New — `nacre_mount()` extracted from `renderNacre` |
| `R/process_tags.R` | Handle `nacre_when` nodes, return `$control_flows` |
| `R/nacre_output.R` | Simplify `renderNacre` to use `nacre_mount()` |
| `inst/js/nacre.js` | Add `nacre-swap` handler |
| `NAMESPACE` | Export `When` |

## Implementation Order

1. Add `nacre-swap` to JS
2. Create `R/when.R` — just the constructor
3. Update `R/process_tags.R` — handle `nacre_when`, emit placeholder + control flow entry
4. Create `R/mount.R` — extract `nacre_mount()` from `renderNacre`, add control flow observer logic
5. Simplify `R/nacre_output.R` — `renderNacre` calls `nacre_mount`
6. Update `NAMESPACE`

## Example

```r
library(shiny)
library(nacre)

ToggleApp <- function() {
  show <- reactiveVal(TRUE)

  tags$div(
    tags$button(
      onClick = \() show(!show()),
      "Toggle"
    ),
    When(show,
      tags$div(
        tags$h2("Visible!"),
        tags$p(style = "color:green", "This content is shown")
      ),
      otherwise = tags$p(style = "color:red", "Hidden — showing fallback")
    )
  )
}

nacreApp(ToggleApp)
```

## Key Considerations

- **Observer lifecycle**: Every observer created during a branch mount must be tracked and destroyed when the branch is swapped out. This includes observers from nested `When`s.
- **`display:contents`**: The placeholder div uses `display:contents` so it doesn't affect layout. The branch HTML goes inside it via `innerHTML`.
- **No lazy branches**: Both branches are constructed at component setup time (closures are cheap). Only mounting (observer creation) is deferred to when the branch becomes active.
- **Initial render**: The condition observer fires immediately on creation, so the active branch is mounted during the first flush. The placeholder div is briefly empty but this happens before the page is visible.
