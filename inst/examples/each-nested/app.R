# Nested Each with mini-store fields
#
# A question editor showing how the reactive system composes:
#
#   - Recursive mini-store decomposition. Each question has a nested
#     `author = list(name, role)` field. The outer Each projects each
#     question as a mini-store, and `question$author` is itself a
#     sub-mini-store. A write to `question$author$name` chains through
#     three synthetic setters (leaf → author → question →
#     questions(...)) and only the one focused input re-renders.
#
#   - Multi-level Each composition. The outer Each is keyed over
#     questions; each question's `options` is an atomic list of
#     strings, iterated positionally by an inner Each so each option
#     gets a scalar slot accessor that writes back through the
#     mini-store leaf to the parent collection.
#
# Try in the running app:
#   - Edit `question$author$name` — only that one leaf binding fires;
#     question text and option inputs stay stable.
#   - Edit a question's text — only the outer text input fires.
#   - Edit an option — only that option input fires.
#   - "Add option" / "Remove option" — positional reconciliation
#     appends or removes a trailing slot without disturbing siblings.
#   - "Add question" / "Remove question" — keyed outer reconciler;
#     kept questions keep their inner-Each state across sibling
#     adds/removes.

library(irid)
library(bslib)

App <- function() {
  next_qid <- 3L
  questions <- reactiveVal(list(
    list(
      id = 1L,
      text = "Favorite color?",
      author = list(name = "Alice", role = "Admin"),
      options = list("Red", "Blue")
    ),
    list(
      id = 2L,
      text = "Favorite food?",
      author = list(name = "Bob", role = "Editor"),
      options = list("Pizza", "Sushi")
    )
  ))

  add_question <- function() {
    q <- list(
      id = next_qid,
      text = "",
      author = list(name = "", role = "Editor"),
      options = list("")
    )
    next_qid <<- next_qid + 1L
    questions(c(questions(), list(q)))
  }
  remove_question <- function(id) {
    questions(Filter(\(q) q$id != id, questions()))
  }

  page_fluid(
    tags$h3("Questions"),
    Each(questions, by = \(q) q$id, \(question, pos) {
      card(
        class = "mb-2 p-2",
        tags$div(
          class = "d-flex align-items-center gap-2 mb-2",
          tags$strong(\() paste0("Q", pos(), ".")),
          tags$input(
            class = "form-control",
            placeholder = "Question text",
            value = question$text
          ),
          tags$button(
            class = "btn btn-sm btn-outline-danger",
            onClick = \() remove_question(question$id()),
            "Delete"
          )
        ),
        # Nested mini-store: question$author is a sub-store with its own
        # per-leaf accessors. Writes chain author → question → questions.
        tags$div(
          class = "d-flex align-items-center gap-2 mb-2 ms-3 small",
          tags$span(class = "text-muted", "by"),
          tags$input(
            class = "form-control form-control-sm",
            style = "max-width: 12rem;",
            placeholder = "Author name",
            value = question$author$name
          ),
          tags$select(
            class = "form-select form-select-sm",
            style = "max-width: 8rem;",
            value = question$author$role,
            tags$option(value = "Admin",  "Admin"),
            tags$option(value = "Editor", "Editor"),
            tags$option(value = "Viewer", "Viewer")
          )
        ),
        tags$div(
          class = "ms-3",
          tags$label(class = "form-label small text-muted", "Options:"),
          Each(question$options, \(option, opos) {
            tags$div(
              class = "input-group input-group-sm mb-1",
              tags$span(class = "input-group-text", \() paste0(opos(), ".")),
              tags$input(
                class = "form-control",
                placeholder = "Option text",
                value = option
              )
            )
          }),
          tags$div(
            class = "mt-2 d-flex gap-2",
            tags$button(
              class = "btn btn-sm btn-outline-secondary",
              onClick = \() question$options(
                c(question$options(), "")
              ),
              "+ option"
            ),
            tags$button(
              class = "btn btn-sm btn-outline-secondary",
              disabled = \() length(question$options()) <= 1L,
              onClick = \() {
                opts <- question$options()
                question$options(opts[seq_len(length(opts) - 1L)])
              },
              "− option"
            )
          )
        )
      )
    }),
    tags$button(
      class = "btn btn-primary mt-2",
      onClick = \() add_question(),
      "Add question"
    )
  )
}

iridApp(App)
