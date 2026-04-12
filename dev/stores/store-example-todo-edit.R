# Todo with edit drawer — comparison of loose reactiveVals vs. reactiveStore.
#
# Extension of examples/todo.R: clicking a todo opens a drawer with a form
# over that item. The form has five fields (text, done, priority, notes,
# due). Saving writes back to the list; cancelling discards.
#
# This is the canonical edit-draft test case from §9 of the design doc.
# Only the edit-drawer machinery is shown — add/toggle/remove/filter are
# unchanged from examples/todo.R.
#
# Not runnable — read-only comparison.

library(irid)

initial_todos <- list(
  list(id = 1L, text = "Learn irid", done = FALSE,
       priority = "high", notes = "", due = NULL),
  list(id = 2L, text = "Build something cool", done = FALSE,
       priority = "normal", notes = "", due = NULL)
)


# =============================================================================
# WITHOUT STORE — five draft reactiveVals + a selected_id
# =============================================================================

TodoApp_loose <- function() {

  todos  <- reactiveVal(initial_todos)
  filter <- reactiveVal("all")

  # Drawer state. Six reactiveVals — one per draft field plus selected_id.
  # They are all stale between edit sessions; start_edit rewrites them.
  selected_id    <- reactiveVal(NULL)
  draft_text     <- reactiveVal("")
  draft_done     <- reactiveVal(FALSE)
  draft_priority <- reactiveVal("normal")
  draft_notes    <- reactiveVal("")
  draft_due      <- reactiveVal(NULL)

  start_edit <- function(id) {
    item <- Find(\(t) t$id == id, todos())
    draft_text(item$text)
    draft_done(item$done)
    draft_priority(item$priority)
    draft_notes(item$notes)
    draft_due(item$due)
    selected_id(id)
  }

  save_edit <- function() {
    id <- selected_id()
    edited <- list(
      id       = id,
      text     = draft_text(),
      done     = draft_done(),
      priority = draft_priority(),
      notes    = draft_notes(),
      due      = draft_due()
    )
    todos(lapply(todos(), \(t) if (t$id == id) edited else t))
    selected_id(NULL)
  }

  cancel_edit <- function() {
    selected_id(NULL)
    # The draft_* reactiveVals still hold the last edit's values. Harmless
    # because they'll be overwritten on the next start_edit, but it means
    # any observer that reads them outside the drawer sees stale state.
  }

  EditDrawer <- function() {
    When(
      \() !is.null(selected_id()),
      tags$aside(
        tags$input(
          value = draft_text,
          onInput = \(e) draft_text(e$value)
        ),
        tags$input(
          type = "checkbox",
          checked = draft_done,
          onClick = \(e) draft_done(e$checked)
        ),
        tags$select(
          value = draft_priority,
          onChange = \(e) draft_priority(e$value)
        ),
        tags$textarea(
          value = draft_notes,
          onInput = \(e) draft_notes(e$value)
        ),
        tags$input(
          type = "date",
          value = draft_due,
          onInput = \(e) draft_due(e$value)
        ),
        tags$button("Save",   onClick = \() save_edit()),
        tags$button("Cancel", onClick = \() cancel_edit())
      )
    )
  }

  page_fluid(
    # ... todo list rendering unchanged from examples/todo.R,
    # each item has onClick = \() start_edit(todo()$id)
    EditDrawer()
  )
}


# =============================================================================
# WITH STORE — a short-lived draft store per edit session
# =============================================================================

TodoApp_store <- function() {

  state <- reactiveStore(list(
    todos       = initial_todos,
    filter      = "all",
    selected_id = NULL
  ))

  # edit_draft is a plain variable that holds either NULL or a fresh
  # reactiveStore cloned from the selected item. Lives and dies with the
  # edit session — never wired into `state`.
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
    # Dropping the reference discards every draft leaf at once. No stale
    # state, no subscribers left behind.
  }

  EditDrawer <- function() {
    When(
      \() !is.null(state$selected_id()),
      tags$aside(
        tags$input(
          value = edit_draft$text,
          onInput = \(e) edit_draft$text(e$value)
        ),
        tags$input(
          type = "checkbox",
          checked = edit_draft$done,
          onClick = \(e) edit_draft$done(e$checked)
        ),
        tags$select(
          value = edit_draft$priority,
          onChange = \(e) edit_draft$priority(e$value)
        ),
        tags$textarea(
          value = edit_draft$notes,
          onInput = \(e) edit_draft$notes(e$value)
        ),
        tags$input(
          type = "date",
          value = edit_draft$due,
          onInput = \(e) edit_draft$due(e$value)
        ),
        tags$button("Save",   onClick = \() save_edit()),
        tags$button("Cancel", onClick = \() cancel_edit())
      )
    )
  }

  page_fluid(
    # ... todo list rendering unchanged from examples/todo.R,
    # each item has onClick = \() start_edit(todo()$id)
    EditDrawer()
  )
}
