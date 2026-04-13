# Form validation: proxy gate vs. draft + commit
#
# A proxy gate (dropping invalid writes) only works when partial input is still
# meaningful — e.g. max-length or numeric range. Email format validation needs
# a different approach: let the user type freely into draft state, validate on
# submit. state$email only ever holds a valid (or empty) value.

library(irid)

is_valid_email <- function(v) {
  grepl("^[^@]+@[^@]+\\.[^@]+$", v, perl = TRUE)
}

EmailInput <- function(email) {
  tags$input(type = "email", value = email)
}

EmailApp <- function() {
  state <- reactiveStore(list(
    email = "",
    name  = ""
  ))

  email_draft <- reactiveVal("")
  email_error <- reactiveVal(NULL)

  submit_form <- function() {
    v <- email_draft()
    if (!is_valid_email(v)) {
      email_error("Invalid email address")
      return()
    }
    email_error(NULL)
    state$email(v)
    save_profile(state())
  }

  page_fluid(
    tags$div(
      tags$label("Name"),
      tags$input(value = state$name)
    ),
    tags$div(
      tags$label("Email"),
      EmailInput(email_draft),
      When(
        \() !is.null(email_error()),
        tags$p(\() email_error(), style = "color: red")
      )
    ),
    tags$button("Submit", onClick = \() submit_form())
  )
}

iridApp(EmailApp)
