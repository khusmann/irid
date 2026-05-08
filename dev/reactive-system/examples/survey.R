# Survey question editor: discriminated union via compound Each key
#
# Questions are a tagged union keyed on (id, qtype). Different variants carry
# different fields — choice questions have $options, text/scale do not.
# Changing qtype replaces the whole item so Each tears down the old mini-store
# and mounts a fresh one with the correct shape for the new variant.

library(irid)

QuestionTypeSelect <- function(qtype) {
  tags$select(
    selected = qtype,
    tags$option(value = "text",   "Text"),
    tags$option(value = "choice", "Multiple choice"),
    tags$option(value = "scale",  "Scale")
  )
}

ChoiceConfig <- function(question) {
  tags$div(
    tags$h4("Options"),
    Each(question$options, \(option, i) {
      tags$div(
        tags$input(value = option),
        tags$button(
          "\u00d7",
          onClick = \() question$options(question$options()[-i])
        )
      )
    }),
    tags$button(
      "Add option",
      onClick = \() question$options(c(question$options(), ""))
    )
  )
}

new_question <- function(id, qtype, text = "") switch(qtype,
  text   = list(id = id, text = text, qtype = "text"),
  scale  = list(id = id, text = text, qtype = "scale"),
  choice = list(id = id, text = text, qtype = "choice", options = list(""))
)

QuestionEditor <- function(question) {
  # Proxy replaces the whole item on qtype change so the incoming mini-store
  # always has the correct shape for its variant. The compound Each key
  # (id + qtype) ensures the old mini-store is torn down and a fresh one
  # mounted rather than patching a differently-shaped record.
  qtype_proxy <- reactiveProxy(question$qtype,
    set = \(v) question(new_question(question()$id, v, text = question()$text))
  )

  tags$div(
    class = "question",
    tags$input(value = question$text, placeholder = "Question text..."),
    QuestionTypeSelect(qtype_proxy),
    Match(
      Case(\() question$qtype() == "choice", ChoiceConfig(question))
    )
  )
}

SurveyApp <- function() {
  state <- reactiveStore(list(
    title = "My Survey",
    questions = list(
      list(
        id      = 1L,
        text    = "What is your favorite color?",
        qtype   = "choice",
        options = list("Red", "Blue", "Green")
      ),
      list(
        id    = 2L,
        text  = "How satisfied are you?",
        qtype = "scale"
      )
    )
  ))
  next_id <- 3L

  add_question <- function() {
    state$questions(c(state$questions(), list(new_question(next_id, "text"))))
    next_id <<- next_id + 1L
  }

  remove_question <- function(id) {
    state$questions(Filter(\(q) q$id != id, state$questions()))
  }

  page_fluid(
    tags$div(
      tags$label("Survey title"),
      tags$input(value = state$title)
    ),
    tags$div(
      # Key on (id, qtype): changing qtype destroys the old mini-store and
      # mounts a fresh one with the correct shape for the new variant.
      Each(state$questions, by = \(q) paste0(q$id, "_", q$qtype), \(question) {
        tags$div(
          QuestionEditor(question),
          tags$button(
            "Remove",
            onClick = \() remove_question(question()$id)
          )
        )
      })
    ),
    tags$button("Add question", onClick = \() add_question()),
    tags$button("Export",       onClick = \() export_survey(state()))
  )
}

iridApp(SurveyApp)
