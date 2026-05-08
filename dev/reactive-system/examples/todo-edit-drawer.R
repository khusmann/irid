# Edit-draft pattern: reactiveStore item clone, auto-bind in drawer, save/cancel

library(irid)

initial_todos <- list(
  list(
    id       = 1L,
    text     = "Learn irid",
    done     = FALSE,
    priority = "normal",
    notes    = "",
    due      = NULL
  ),
  list(
    id       = 2L,
    text     = "Build something cool",
    done     = FALSE,
    priority = "high",
    notes    = "Check the docs first",
    due      = NULL
  )
)

TodoApp <- function() {
  state <- reactiveStore(list(
    todos       = initial_todos,
    filter      = "all",
    selected_id = NULL
  ))
  next_id <- 3L

  # edit_draft is NULL or a short-lived reactiveStore cloned from the selected
  # item. Never wired into state — lives and dies with the edit session.
  edit_draft <- NULL

  start_edit <- function(id) {
    item <- Find(\(t) t$id == id, state$todos())
    edit_draft <<- reactiveStore(item)
    state$selected_id(id)
  }

  save_edit <- function() {
    edited <- edit_draft()
    state$todos(lapply(
      state$todos(),
      \(t) if (t$id == edited$id) edited else t
    ))
    state$selected_id(NULL)
    edit_draft <<- NULL
  }

  cancel_edit <- function() {
    state$selected_id(NULL)
    edit_draft <<- NULL
  }

  add_todo <- function() {
    state$todos(c(state$todos(), list(list(
      id       = next_id,
      text     = "New todo",
      done     = FALSE,
      priority = "normal",
      notes    = "",
      due      = NULL
    ))))
    next_id <<- next_id + 1L
  }

  TodoList <- function() {
    tags$ul(
      Each(state$todos, by = \(t) t$id, \(todo) {
        tags$li(
          tags$input(type = "checkbox", checked = todo$done),
          tags$span(
            \() todo$text(),
            onClick = \() start_edit(todo()$id),
            style = "cursor: pointer"
          )
        )
      })
    )
  }

  EditDrawer <- function() {
    When(
      \() !is.null(state$selected_id()),
      tags$aside(
        tags$h3("Edit todo"),
        tags$div(
          tags$label("Text"),
          tags$input(value = edit_draft$text)
        ),
        tags$div(
          tags$label("Done"),
          tags$input(type = "checkbox", checked = edit_draft$done)
        ),
        tags$div(
          tags$label("Priority"),
          tags$select(
            selected = edit_draft$priority,
            tags$option(value = "low",    "Low"),
            tags$option(value = "normal", "Normal"),
            tags$option(value = "high",   "High")
          )
        ),
        tags$div(
          tags$label("Notes"),
          tags$textarea(value = edit_draft$notes)
        ),
        tags$div(
          tags$label("Due date"),
          tags$input(type = "date", value = edit_draft$due)
        ),
        tags$div(
          tags$button("Save",   onClick = \() save_edit()),
          tags$button("Cancel", onClick = \() cancel_edit())
        )
      )
    )
  }

  page_fluid(
    tags$h2("Todos"),
    TodoList(),
    tags$button("Add todo", onClick = \() add_todo()),
    EditDrawer()
  )
}

iridApp(TodoApp)
