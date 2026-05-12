# Heterogeneous Each — mixed record shapes + in-place shape transitions
#
# A minimal block editor. The blocks list holds items with three
# different record shapes:
#
#   - heading:   list(id, type = "heading",   text)
#   - paragraph: list(id, type = "paragraph", text)
#   - todo:      list(id, type = "todo",      text, done)
#
# Per-entry shape is decided at build time from the block's own value —
# the headline + paragraph + todo each get a mini-store sized to its
# own keys. The Match inside the Each body dispatches on `type` and
# renders the right editor for each kind.
#
# Changing a block's kind via the dropdown reshapes the slot in the
# parent collection (the `blocks` reactiveVal). A direct write
# through the per-item mini-store would be rejected as a shape
# violation — mini-stores are strict about their leaf tree, same as
# `reactiveStore`. Shape changes are *parent-level* operations:
# write the new collection through `blocks(...)`. The Each reconciler
# observes the parent change, sees the entry's shape signature
# changed, tears down the old mini-store + scope + DOM, and rebuilds
# with a fresh mini-store of the new shape — emitted as a single
# irid-mutate carrying the new range plus `order`. Sibling blocks
# keep their state and focus.
#
# Try in the running app:
#   - Edit a block's text — only that one input re-renders; siblings
#     stay stable.
#   - Toggle a todo's checkbox — only the todo's `done` leaf fires.
#   - Change a block's kind via the dropdown — that block's range is
#     replaced in place. Add a few todos first, change one to a
#     paragraph while focused on a sibling — the sibling keeps focus.
#   - Reorder blocks with the up/down arrows — the keyed reconciler
#     moves existing DOM ranges (no rebuild) regardless of shape
#     mismatch between adjacent positions.
#   - Add and remove blocks of any kind.

library(irid)
library(bslib)

App <- function() {
  next_id <- 4L
  blocks <- reactiveVal(list(
    list(id = 1L, type = "heading",   text = "Heterogeneous blocks"),
    list(id = 2L, type = "paragraph", text = "Each block has its own record shape."),
    list(id = 3L, type = "todo",      text = "Switch this block's kind", done = FALSE)
  ))

  # Constructing a block by kind. Type changes don't patch in place —
  # different kinds have different fields, so the whole record is
  # rebuilt. The `text` carries across to preserve user content.
  block_for_type <- function(id, type, text = "") {
    switch(
      type,
      heading   = list(id = id, type = "heading",   text = text),
      paragraph = list(id = id, type = "paragraph", text = text),
      todo      = list(id = id, type = "todo",      text = text, done = FALSE),
      stop("Unknown block type: ", type)
    )
  }

  add_block <- function(type) {
    blocks(c(blocks(), list(block_for_type(next_id, type))))
    next_id <<- next_id + 1L
  }

  remove_block <- function(id) {
    blocks(Filter(\(b) b$id != id, blocks()))
  }

  move_block <- function(id, delta) {
    items <- blocks()
    idx <- which(vapply(items, \(b) b$id, integer(1L)) == id)
    if (length(idx) == 0L) return()
    new_idx <- idx + delta
    if (new_idx < 1L || new_idx > length(items)) return()
    items[c(idx, new_idx)] <- items[c(new_idx, idx)]
    blocks(items)
  }

  # A `reactiveProxy` over the block's current `type`. The read side
  # is just the `type` leaf accessor — subscribing only to type
  # changes, not the whole record. The write side reshapes the slot
  # in the parent collection (`blocks`), because the new kind has a
  # different leaf tree than the old (todo adds `done`); a write
  # through the mini-store would be rejected as a shape violation.
  # Writing through `blocks` makes the parent-mediated nature of the
  # operation explicit. The Each reconciler observes the parent
  # change, sees the entry's shape signature changed, tears down
  # this entry's mini-store + scope + DOM, and rebuilds — same flush.
  kind_proxy <- function(block) {
    reactiveProxy(
      get = block$type,
      set = function(new_type) {
        id <- shiny::isolate(block$id())
        text <- shiny::isolate(block$text())
        bs <- shiny::isolate(blocks())
        idx <- which(vapply(bs, function(b) b$id, integer(1L)) == id)
        bs[[idx]] <- block_for_type(id, new_type, text = text)
        blocks(bs)
      }
    )
  }

  # The Match inside the Each body is what makes heterogeneous lists
  # readable: dispatch on the per-item callable, render the right
  # editor for each shape. Each Case's body receives the mini-store
  # sized to that variant's leaf tree.
  BlockEditor <- function(block) {
    Match(
      block,
      Case(
        \(b) b$type == "heading",
        \(b) tags$input(
          class = "form-control fw-bold fs-4",
          placeholder = "Heading",
          value = b$text
        )
      ),
      Case(
        \(b) b$type == "paragraph",
        \(b) tags$textarea(
          class = "form-control",
          rows = 2,
          placeholder = "Paragraph text",
          value = b$text
        )
      ),
      Case(
        \(b) b$type == "todo",
        \(b) tags$div(
          class = "form-check d-flex align-items-center gap-2 m-0",
          tags$input(
            type = "checkbox",
            class = "form-check-input m-0",
            checked = b$done
          ),
          tags$input(
            class = "form-control",
            placeholder = "Todo text",
            value = b$text
          )
        )
      )
    )
  }

  page_fluid(
    tags$h3("Block editor"),
    tags$p(
      class = "text-muted small",
      "Heterogeneous list — heading, paragraph, and todo records share ",
      "the same Each. Change a block's kind to see the reconciler rebuild ",
      "only that entry."
    ),
    Each(
      blocks,
      by = \(b) b$id,
      \(block, pos) {
        card(
          class = "mb-2 p-2",
          tags$div(
            class = "d-flex align-items-center gap-2 mb-2",
            tags$span(class = "text-muted small", \() paste0("#", pos())),
            tags$select(
              class = "form-select form-select-sm",
              style = "max-width: 10rem;",
              value = kind_proxy(block),
              tags$option(value = "heading",   "Heading"),
              tags$option(value = "paragraph", "Paragraph"),
              tags$option(value = "todo",      "Todo")
            ),
            tags$div(class = "flex-grow-1"),
            tags$button(
              class = "btn btn-sm btn-outline-secondary",
              onClick = \() move_block(shiny::isolate(block$id()), -1L),
              "↑"
            ),
            tags$button(
              class = "btn btn-sm btn-outline-secondary",
              onClick = \() move_block(shiny::isolate(block$id()), +1L),
              "↓"
            ),
            tags$button(
              class = "btn btn-sm btn-outline-danger",
              onClick = \() remove_block(shiny::isolate(block$id())),
              "×"
            )
          ),
          BlockEditor(block)
        )
      }
    ),
    tags$div(
      class = "d-flex gap-2 mt-2",
      tags$button(
        class = "btn btn-sm btn-outline-primary",
        onClick = \() add_block("heading"),
        "+ heading"
      ),
      tags$button(
        class = "btn btn-sm btn-outline-primary",
        onClick = \() add_block("paragraph"),
        "+ paragraph"
      ),
      tags$button(
        class = "btn btn-sm btn-outline-primary",
        onClick = \() add_block("todo"),
        "+ todo"
      )
    )
  )
}

iridApp(App)
