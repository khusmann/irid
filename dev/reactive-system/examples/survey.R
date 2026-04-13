# Survey question editor: Each inside Each (vertical composition), scalar accessor writes

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

QuestionEditor <- function(question) {
  tags$div(
    class = "question",
    tags$input(
      value = question$text,
      placeholder = "Question text..."
    ),
    QuestionTypeSelect(question$qtype),
    When(
      \() question$qtype() == "choice",
      ChoiceConfig(question)
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
        id      = 2L,
        text    = "How satisfied are you?",
        qtype   = "scale",
        options = list()
      )
    )
  ))
  next_id <- 3L

  add_question <- function() {
    state$questions(c(state$questions(), list(list(
      id      = next_id,
      text    = "",
      qtype   = "text",
      options = list()
    ))))
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
      Each(state$questions, by = \(q) q$id, \(question) {
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
