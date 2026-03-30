# Todo List
#
# A TodoMVC-style application demonstrating reactive list management with nacre.
# Items are stored as a `reactiveVal` holding a plain R list; adding, toggling,
# and removing items are ordinary functions that update that list. The filter
# tabs and item count derive reactively from the same source, so everything
# stays consistent without any manual synchronization.

library(nacre)
library(bslib)

TodoItem <- function(todo, on_toggle, on_remove) {
  tags$li(
    class = "list-group-item d-flex align-items-center gap-2",
    tags$input(
      type = "checkbox",
      class = "form-check-input mt-0",
      checked = \() todo()$done,
      onClick = \() on_toggle()
    ),
    tags$span(
      class = \() if (todo()$done) "flex-grow-1 text-decoration-line-through text-muted" else "flex-grow-1",
      \() todo()$text
    ),
    tags$button(
      class = "btn btn-sm btn-outline-danger",
      onClick = \() on_remove(),
      "\u00d7"
    )
  )
}

TodoApp <- function() {
  next_id <- 4L
  todos <- reactiveVal(list(
    list(id = 1L, text = "Learn nacre", done = FALSE),
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

  toggle_todo <- function(id) {
    todos(lapply(todos(), \(t) {
      if (t$id == id) { t$done <- !t$done }
      t
    }))
  }

  remove_todo <- function(id) {
    todos(Filter(\(t) t$id != id, todos()))
  }

  filtered <- reactive({
    switch(filter(),
      all = todos(),
      active = Filter(\(t) !t$done, todos()),
      completed = Filter(\(t) t$done, todos())
    )
  })

  remaining <- reactive(sum(!vapply(todos(), \(t) t$done, logical(1))))

  page_fluid(
    tags$div(
      class = "mx-auto",
      style = "max-width: 600px;",

      tags$h2(class = "mt-4 mb-3", "Todos"),

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
              value = new_text,
              onInput = \(event) new_text(event$value),
              onKeyDown = \(event) if (event$key == "Enter") add_todo()
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
          lapply(list(
            list(id = "all", label = "All"),
            list(id = "active", label = "Active"),
            list(id = "completed", label = "Done")
          ), \(f) {
            tags$button(
              class = \() if (filter() == f$id) "btn btn-primary" else "btn btn-outline-primary",
              onClick = \() filter(f$id),
              f$label
            )
          })
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
            \() length(filtered()) > 0,
            tags$ul(
              class = "list-group list-group-flush",
              Index(filtered, \(todo) {
                TodoItem(
                  todo,
                  on_toggle = \() toggle_todo(todo()$id),
                  on_remove = \() remove_todo(todo()$id)
                )
              })
            ),
            otherwise = tags$div(
              class = "text-center text-muted p-4",
              When(
                \() filter() == "all",
                "No todos yet. Add one above!",
                otherwise = "No matching todos."
              )
            )
          )
        )
      )
    )
  )
}

nacreApp(TodoApp)
