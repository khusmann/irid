# reactiveProxy for validation at a component boundary

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
  email_error <- reactiveVal(NULL)

  validated_email <- reactiveProxy(state$email,
    set = \(v) {
      if (is_valid_email(v)) {
        email_error(NULL)
        state$email(v)
      } else {
        email_error("Invalid email address")
      }
    }
  )

  page_fluid(
    tags$div(
      tags$label("Name"),
      tags$input(value = state$name)
    ),
    tags$div(
      tags$label("Email"),
      EmailInput(validated_email),
      When(
        \() !is.null(email_error()),
        tags$p(\() email_error(), style = "color: red")
      )
    ),
    tags$button(
      "Submit",
      onClick = \() submit_form(state())
    )
  )
}

iridApp(EmailApp)
