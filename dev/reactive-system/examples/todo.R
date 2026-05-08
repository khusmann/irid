# Todo app: reactiveStore, Each with mini-stores, auto-bind, When for filtering

library(irid)

matches_filter <- function(todo, filter) {
  switch(filter,
    all    = TRUE,
    active = !todo$done,
    done   =  todo$done
  )
}

TodoApp <- function() {
  state <- reactiveStore(list(
    todos = list(
      list(id = 1L, text = "Learn irid",    done = FALSE),
      list(id = 2L, text = "Build stores",  done = FALSE),
      list(id = 3L, text = "Install R",     done = TRUE)
    ),
    new_text = "",
    filter   = "all"
  ))
  next_id <- 4L

  add_todo <- function() {
    text <- trimws(state$new_text())
    if (nchar(text) == 0L) return()
    state$todos(c(state$todos(), list(list(
      id = next_id, text = text, done = FALSE
    ))))
    next_id <<- next_id + 1L
    state$new_text("")
  }

  remove_todo <- function(id) {
    state$todos(Filter(\(t) t$id != id, state$todos()))
  }

  page_fluid(
    tags$div(
      tags$input(
        value = state$new_text,
        placeholder = "New todo...",
        onKeyDown = \(e) if (e$key == "Enter") add_todo()
      ),
      tags$button("Add", onClick = \() add_todo())
    ),

    tags$select(
      selected = state$filter,
      tags$option(value = "all",    "All"),
      tags$option(value = "active", "Active"),
      tags$option(value = "done",   "Done")
    ),

    tags$ul(
      Each(state$todos, by = \(t) t$id, \(todo) {
        When(
          \() matches_filter(todo(), state$filter()),
          tags$li(
            tags$input(type = "checkbox", checked = todo$done),
            tags$span(\() todo$text()),
            tags$button(
              "\u00d7",
              onClick = \() remove_todo(todo()$id)
            )
          )
        )
      })
    ),

    tags$p(\() {
      n_done <- sum(vapply(state$todos(), \(t) t$done, logical(1)))
      sprintf("%d / %d complete", n_done, length(state$todos()))
    })
  )
}

iridApp(TodoApp)
