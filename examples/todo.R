# Todo List
#
# A TodoMVC-style application demonstrating reactive list management with irid.
# Items are stored as a `reactiveVal` holding a plain R list; adding and
# removing items are ordinary functions that update that list. Toggling
# happens through the per-item mini-store autobind — `checked = todo$done`
# writes back through the slot accessor into `todos`, no explicit handler
# needed.
#
# `Each(todos, by = \(t) t$id, ...)` iterates the live, writable source so
# autobind writes have somewhere to go. Filtering is per-item: each entry
# wraps its body in `When(\() matches_filter(...), ...)`, so hidden items
# yield nothing while their slot identity (and any DOM state) is preserved
# across filter changes.

library(irid)
library(bslib)

TodoItem <- function(todo, on_remove) {
  tags$li(
    class = "list-group-item d-flex align-items-center gap-2",
    tags$input(
      type = "checkbox",
      class = "form-check-input mt-0",
      checked = todo$done
    ),
    tags$span(
      class = \() if (todo$done()) "flex-grow-1 text-decoration-line-through text-muted" else "flex-grow-1",
      \() todo$text()
    ),
    tags$button(
      class = "btn btn-sm btn-outline-danger",
      onClick = \() on_remove(),
      "×"
    )
  )
}

TodoApp <- function() {
  next_id <- 4L
  todos <- reactiveVal(list(
    list(id = 1L, text = "Learn irid", done = FALSE),
    list(id = 2L, text = "Build something cool", done = FALSE),
    list(id = 3L, text = "Install R", done = TRUE)
  ))
  new_text <- reactiveVal("")
  filter <- reactiveVal("all")

  add_todo <- function() {
    if (nchar(trimws(new_text())) > 0) {
      todos(c(todos(), list(list(id = next_id, text = trimws(new_text()), done = FALSE))))
      next_id <<- next_id + 1L
      new_text("")
    }
  }

  remove_todo <- function(id) {
    todos(Filter(\(t) t$id != id, todos()))
  }

  matches_filter <- function(done, f) {
    switch(f, all = TRUE, active = !done, completed = done)
  }

  remaining <- \() sum(!vapply(todos(), \(t) t$done, logical(1)))
  visible_count <- \() {
    sum(vapply(
      todos(),
      \(t) matches_filter(t$done, filter()),
      logical(1)
    ))
  }

  page_fluid(
    # Add form
    card(
      card_body(
        class = "p-2",
        tags$div(
          class = "input-group",
          tags$input(
            type = "text",
            class = "form-control",
            placeholder = "What needs to be done?",
            value = new_text
          ),
          tags$button(
            class = "btn btn-primary",
            disabled = \() nchar(trimws(new_text())) == 0,
            onClick = \() add_todo(),
            "Add"
          )
        )
      )
    ),

    # Filter tabs and count
    tags$div(
      class = "d-flex justify-content-between align-items-center my-3",
      tags$span(
        class = "text-muted",
        \() paste(remaining(), "items left")
      ),
      tags$div(
        class = "btn-group btn-group-sm",
        lapply(
          list(
            list(id = "all", label = "All"),
            list(id = "active", label = "Active"),
            list(id = "completed", label = "Done")
          ),
          \(f) tags$button(
            class = \() if (filter() == f$id) "btn btn-primary" else "btn btn-outline-primary",
            onClick = \() filter(f$id),
            f$label
          )
        )
      ),
      tags$button(
        class = "btn btn-sm btn-outline-danger",
        disabled = \() remaining() == length(todos()),
        onClick = \() todos(Filter(\(t) !t$done, todos())),
        "Clear done"
      )
    ),

    # Todo list
    card(
      card_body(
        class = "p-0",
        When(
          \() visible_count() > 0,
          \() tags$ul(
            class = "list-group list-group-flush",
            Each(todos, by = \(t) t$id, \(todo) {
              When(
                \() matches_filter(todo$done(), filter()),
                \() TodoItem(todo, on_remove = \() remove_todo(todo$id()))
              )
            })
          ),
          otherwise = \() tags$div(
            class = "text-center text-muted p-4",
            When(
              \() length(todos()) == 0,
              \() "No todos yet. Add one above!",
              otherwise = \() "No matching todos."
            )
          )
        )
      )
    )
  )
}

iridApp(TodoApp)
