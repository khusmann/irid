# Survey Authoring Tool
#
# A three-pane form designer: question list on the left, edit form in the
# center, live preview on the right. The canonical question list lives in one
# reactiveVal of nested lists (logically atomic — a question is a bundle). The
# center pane edits a *draft* copy of the selected question held in separate
# reactiveVals, so unsaved changes never leak into the preview until Save.

library(irid)
library(bslib)

default_config <- function(type) {
  switch(
    type,
    text = list(placeholder = "", max_length = 100L),
    number = list(min = 0, max = 100, step = 1),
    choice = list(options = c("Option 1", "Option 2"), allow_multiple = FALSE)
  )
}

ChoiceEditor <- function(options, allow_multiple) {
  tags$div(
    tags$label(class = "form-label", "Options"),
    Index(
      options,
      \(opt, i) tags$div(
        class = "input-group mb-1",
        tags$input(
          type = "text",
          class = "form-control",
          value = opt,
          onInput = \(e) {
            current <- options()
            current[[i]] <- e$value
            options(current)
          }
        ),
        tags$button(
          class = "btn btn-outline-danger",
          disabled = \() length(options()) <= 1L,
          onClick = \() options(options()[-i]),
          "\u00d7"
        )
      )
    ),
    tags$button(
      class = "btn btn-sm btn-outline-secondary mt-1",
      onClick = \() options(c(options(), paste("Option", length(options()) + 1L))),
      "+ Add option"
    ),
    tags$div(
      class = "form-check mt-2",
      tags$input(
        type = "checkbox",
        class = "form-check-input",
        checked = allow_multiple,
        onClick = \() allow_multiple(!allow_multiple())
      ),
      tags$label(class = "form-check-label", "Allow multiple")
    )
  )
}

ChoicePreview <- function(question) {
  tags$div(
    When(
      \() question$config$allow_multiple,
      tags$div(
        lapply(question$config$options, \(opt) tags$div(
          class = "form-check",
          tags$input(type = "checkbox", class = "form-check-input"),
          tags$label(class = "form-check-label", opt)
        ))
      ),
      otherwise = tags$select(
        class = "form-select",
        lapply(question$config$options, \(opt) tags$option(value = opt, opt))
      )
    )
  )
}

QuestionPreview <- function(question) {
  tags$div(
    class = "mb-3",
    tags$label(
      class = "form-label fw-bold",
      question$label,
      When(
        \() question$required,
        tags$span(class = "text-danger", " *"),
        otherwise = NULL
      )
    ),
    Match(
      Case(\() question$type == "text", tags$input(
        type = "text",
        class = "form-control",
        placeholder = question$config$placeholder,
        maxlength = question$config$max_length
      )),
      Case(\() question$type == "number", tags$input(
        type = "number",
        class = "form-control",
        min = question$config$min,
        max = question$config$max,
        step = question$config$step
      )),
      Default(ChoicePreview(question))
    )
  )
}

SurveyApp <- function() {
  next_id <- 3L
  title <- reactiveVal("Untitled Survey")
  description <- reactiveVal("")
  questions <- reactiveVal(list(
    list(
      id = 1L, type = "text", label = "What is your name?", required = TRUE,
      config = list(placeholder = "Your name", max_length = 50L)
    ),
    list(
      id = 2L, type = "choice", label = "Favorite color?", required = FALSE,
      config = list(options = c("Red", "Green", "Blue"), allow_multiple = FALSE)
    )
  ))
  selected_id <- reactiveVal(NULL)

  # Draft state for the center pane. Populated from the selected question on
  # select_question; written back on save_edit.
  # NOTE: one draft reactiveVal per editable field means select_question and
  # save_edit each touch every field by name. A "draft = copy of question"
  # helper would collapse this, but that is the abstraction I am avoiding.
  draft_label <- reactiveVal("")
  draft_required <- reactiveVal(FALSE)
  draft_placeholder <- reactiveVal("")
  draft_max_length <- reactiveVal(100L)
  draft_min <- reactiveVal(0)
  draft_max <- reactiveVal(100)
  draft_step <- reactiveVal(1)
  draft_options <- reactiveVal(character(0))
  draft_allow_multiple <- reactiveVal(FALSE)

  find_question <- \(id) Find(\(q) q$id == id, questions())

  selected_question <- \() {
    id <- selected_id()
    if (is.null(id)) NULL else find_question(id)
  }

  add_question <- function(type) {
    q <- list(
      id = next_id,
      type = type,
      label = "New question",
      required = FALSE,
      config = default_config(type)
    )
    questions(c(questions(), list(q)))
    next_id <<- next_id + 1L
  }

  remove_question <- function(id) {
    questions(Filter(\(q) q$id != id, questions()))
    if (!is.null(selected_id()) && selected_id() == id) selected_id(NULL)
  }

  move_by <- function(id, delta) {
    qs <- questions()
    idx <- which(vapply(qs, \(q) q$id == id, logical(1)))
    if (length(idx) == 0) return()
    new_idx <- idx + delta
    if (new_idx < 1L || new_idx > length(qs)) return()
    qs[c(idx, new_idx)] <- qs[c(new_idx, idx)]
    questions(qs)
  }

  move_up <- \(id) move_by(id, -1L)
  move_down <- \(id) move_by(id, 1L)

  select_question <- function(id) {
    q <- find_question(id)
    if (is.null(q)) return()
    selected_id(id)
    draft_label(q$label)
    draft_required(q$required)
    if (q$type == "text") {
      draft_placeholder(q$config$placeholder)
      draft_max_length(q$config$max_length)
    } else if (q$type == "number") {
      draft_min(q$config$min)
      draft_max(q$config$max)
      draft_step(q$config$step)
    } else if (q$type == "choice") {
      draft_options(q$config$options)
      draft_allow_multiple(q$config$allow_multiple)
    }
  }

  save_edit <- function() {
    id <- selected_id()
    if (is.null(id)) return()
    questions(lapply(questions(), \(q) {
      if (q$id != id) return(q)
      q$label <- draft_label()
      q$required <- draft_required()
      q$config <- switch(
        q$type,
        text = list(
          placeholder = draft_placeholder(),
          max_length = draft_max_length()
        ),
        number = list(
          min = draft_min(),
          max = draft_max(),
          step = draft_step()
        ),
        choice = list(
          options = draft_options(),
          allow_multiple = draft_allow_multiple()
        )
      )
      q
    }))
    selected_id(NULL)
  }

  cancel_edit <- \() selected_id(NULL)

  # Left pane
  QuestionRow <- function(q) {
    tags$div(
      class = \() {
        base <- "d-flex align-items-center gap-1 p-2 border-bottom"
        if (!is.null(selected_id()) && selected_id() == q$id) paste(base, "bg-light")
        else base
      },
      tags$button(
        class = "btn btn-sm btn-link text-start flex-grow-1",
        onClick = \() select_question(q$id),
        q$label
      ),
      tags$button(
        class = "btn btn-sm btn-outline-secondary",
        onClick = \() move_up(q$id),
        "\u2191"
      ),
      tags$button(
        class = "btn btn-sm btn-outline-secondary",
        onClick = \() move_down(q$id),
        "\u2193"
      ),
      tags$button(
        class = "btn btn-sm btn-outline-danger",
        onClick = \() remove_question(q$id),
        "\u00d7"
      )
    )
  }

  add_type <- reactiveVal("text")

  LeftPane <- tags$div(
    class = "col-md-4",
    tags$h5("Questions"),
    card(
      card_body(
        class = "p-0",
        Each(
          questions,
          by = \(q) q$id,
          \(q) QuestionRow(q)
        )
      )
    ),
    tags$div(
      class = "input-group mt-2",
      tags$select(
        class = "form-select",
        value = add_type,
        onChange = \(e) add_type(e$value),
        tags$option(value = "text", "Text"),
        tags$option(value = "number", "Number"),
        tags$option(value = "choice", "Choice")
      ),
      tags$button(
        class = "btn btn-primary",
        onClick = \() add_question(add_type()),
        "+ Add"
      )
    )
  )

  # Center pane
  CenterPane <- tags$div(
    class = "col-md-4",
    tags$h5("Edit"),
    When(
      \() !is.null(selected_id()),
      card(
        card_body(
          tags$div(
            class = "mb-3",
            tags$label(class = "form-label", "Label"),
            tags$input(
              type = "text",
              class = "form-control",
              value = draft_label,
              onInput = \(e) draft_label(e$value)
            )
          ),
          tags$div(
            class = "form-check mb-3",
            tags$input(
              type = "checkbox",
              class = "form-check-input",
              checked = draft_required,
              onClick = \() draft_required(!draft_required())
            ),
            tags$label(class = "form-check-label", "Required")
          ),
          # Type-specific fields
          Match(
            Case(\() !is.null(selected_question()) && selected_question()$type == "text", tags$div(
              tags$div(
                class = "mb-3",
                tags$label(class = "form-label", "Placeholder"),
                tags$input(
                  type = "text",
                  class = "form-control",
                  value = draft_placeholder,
                  onInput = \(e) draft_placeholder(e$value)
                )
              ),
              tags$div(
                class = "mb-3",
                tags$label(class = "form-label", "Max length"),
                tags$input(
                  type = "number",
                  class = "form-control",
                  value = draft_max_length,
                  onInput = \(e) draft_max_length(as.integer(e$valueAsNumber))
                )
              )
            )),
            Case(\() !is.null(selected_question()) && selected_question()$type == "number", tags$div(
              tags$div(
                class = "mb-3",
                tags$label(class = "form-label", "Min"),
                tags$input(
                  type = "number",
                  class = "form-control",
                  value = draft_min,
                  onInput = \(e) draft_min(e$valueAsNumber)
                )
              ),
              tags$div(
                class = "mb-3",
                tags$label(class = "form-label", "Max"),
                tags$input(
                  type = "number",
                  class = "form-control",
                  value = draft_max,
                  onInput = \(e) draft_max(e$valueAsNumber)
                )
              ),
              tags$div(
                class = "mb-3",
                tags$label(class = "form-label", "Step"),
                tags$input(
                  type = "number",
                  class = "form-control",
                  value = draft_step,
                  onInput = \(e) draft_step(e$valueAsNumber)
                )
              )
            )),
            Default(ChoiceEditor(draft_options, draft_allow_multiple))
          ),
          tags$div(
            class = "d-flex gap-2",
            tags$button(
              class = "btn btn-primary",
              onClick = \() save_edit(),
              "Save"
            ),
            tags$button(
              class = "btn btn-outline-secondary",
              onClick = \() cancel_edit(),
              "Cancel"
            )
          )
        )
      ),
      otherwise = tags$p(class = "text-muted", "Select a question to edit.")
    )
  )

  # Right pane
  RightPane <- tags$div(
    class = "col-md-4",
    tags$h5("Preview"),
    card(
      card_body(
        tags$h3(title),
        tags$p(class = "text-muted", description),
        Each(
          questions,
          by = \(q) q$id,
          \(q) QuestionPreview(q)
        )
      )
    )
  )

  page_fluid(
    tags$div(
      class = "mb-3",
      tags$input(
        type = "text",
        class = "form-control form-control-lg mb-2",
        placeholder = "Survey title",
        value = title,
        onInput = \(e) title(e$value)
      ),
      tags$textarea(
        class = "form-control",
        placeholder = "Description",
        rows = 2,
        value = description,
        onInput = \(e) description(e$value)
      )
    ),
    tags$div(
      class = "row",
      LeftPane,
      CenterPane,
      RightPane
    )
  )
}

iridApp(SurveyApp)
