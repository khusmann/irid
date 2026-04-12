# Multi-Step Wizard Form
#
# A four-step signup form. Each field is its own reactiveVal, grouped only by
# convention via the step component that reads/writes it. A `step` reactiveVal
# tracks the current page; `next_step` / `prev_step` / `reset` / `submit` /
# `load_draft` all operate by touching the individual fields directly.

library(irid)
library(bslib)

Step1Account <- function(username, email, password, confirm_password) {
  tags$div(
    tags$h4("Account"),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Username"),
      tags$input(
        type = "text",
        class = "form-control",
        value = username,
        onInput = \(e) username(e$value)
      )
    ),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Email"),
      tags$input(
        type = "email",
        class = "form-control",
        value = email,
        onInput = \(e) email(e$value)
      )
    ),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Password"),
      tags$input(
        type = "password",
        class = "form-control",
        value = password,
        onInput = \(e) password(e$value)
      )
    ),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Confirm password"),
      tags$input(
        type = "password",
        class = "form-control",
        value = confirm_password,
        onInput = \(e) confirm_password(e$value)
      )
    )
  )
}

Step2Profile <- function(display_name, bio, avatar_url, timezone) {
  tags$div(
    tags$h4("Profile"),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Display name"),
      tags$input(
        type = "text",
        class = "form-control",
        value = display_name,
        onInput = \(e) display_name(e$value)
      )
    ),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Bio"),
      tags$textarea(
        class = "form-control",
        rows = 3,
        value = bio,
        onInput = \(e) bio(e$value)
      )
    ),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Avatar URL"),
      tags$input(
        type = "url",
        class = "form-control",
        value = avatar_url,
        onInput = \(e) avatar_url(e$value)
      )
    ),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Timezone"),
      tags$select(
        class = "form-select",
        value = timezone,
        onChange = \(e) timezone(e$value),
        Each(
          \() c("UTC", "America/New_York", "America/Los_Angeles", "Europe/London", "Asia/Tokyo"),
          \(tz) tags$option(value = tz, tz)
        )
      )
    )
  )
}

Step3Preferences <- function(theme, language, email_notifications, sms_notifications, newsletter) {
  tags$div(
    tags$h4("Preferences"),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Theme"),
      tags$select(
        class = "form-select",
        value = theme,
        onChange = \(e) theme(e$value),
        tags$option(value = "light", "Light"),
        tags$option(value = "dark", "Dark"),
        tags$option(value = "auto", "Auto")
      )
    ),
    tags$div(
      class = "mb-3",
      tags$label(class = "form-label", "Language"),
      tags$select(
        class = "form-select",
        value = language,
        onChange = \(e) language(e$value),
        tags$option(value = "en", "English"),
        tags$option(value = "es", "Spanish"),
        tags$option(value = "fr", "French"),
        tags$option(value = "de", "German")
      )
    ),
    tags$div(
      class = "form-check",
      tags$input(
        type = "checkbox",
        class = "form-check-input",
        checked = email_notifications,
        onClick = \() email_notifications(!email_notifications())
      ),
      tags$label(class = "form-check-label", "Email notifications")
    ),
    tags$div(
      class = "form-check",
      tags$input(
        type = "checkbox",
        class = "form-check-input",
        checked = sms_notifications,
        onClick = \() sms_notifications(!sms_notifications())
      ),
      tags$label(class = "form-check-label", "SMS notifications")
    ),
    tags$div(
      class = "form-check",
      tags$input(
        type = "checkbox",
        class = "form-check-input",
        checked = newsletter,
        onClick = \() newsletter(!newsletter())
      ),
      tags$label(class = "form-check-label", "Newsletter")
    )
  )
}

Step4Review <- function(
  username, email,
  display_name, bio, avatar_url, timezone,
  theme, language, email_notifications, sms_notifications, newsletter
) {
  review_row <- function(label, value_fn) {
    tags$div(
      class = "d-flex justify-content-between border-bottom py-2",
      tags$span(class = "text-muted", label),
      tags$span(value_fn)
    )
  }

  tags$div(
    tags$h4("Review"),
    tags$h5(class = "mt-3", "Account"),
    review_row("Username", username),
    review_row("Email", email),
    tags$h5(class = "mt-3", "Profile"),
    review_row("Display name", display_name),
    review_row("Bio", bio),
    review_row("Avatar URL", avatar_url),
    review_row("Timezone", timezone),
    tags$h5(class = "mt-3", "Preferences"),
    review_row("Theme", theme),
    review_row("Language", language),
    review_row("Email notifications", \() if (email_notifications()) "Yes" else "No"),
    review_row("SMS notifications", \() if (sms_notifications()) "Yes" else "No"),
    review_row("Newsletter", \() if (newsletter()) "Yes" else "No")
  )
}

post_to_server <- function(payload) {
  message("Submitting: ", toString(names(payload)))
}

WizardApp <- function() {
  step <- reactiveVal(1L)

  # Step 1
  username <- reactiveVal("")
  email <- reactiveVal("")
  password <- reactiveVal("")
  confirm_password <- reactiveVal("")

  # Step 2
  display_name <- reactiveVal("")
  bio <- reactiveVal("")
  avatar_url <- reactiveVal("")
  timezone <- reactiveVal("UTC")

  # Step 3
  theme <- reactiveVal("light")
  language <- reactiveVal("en")
  email_notifications <- reactiveVal(TRUE)
  sms_notifications <- reactiveVal(FALSE)
  newsletter <- reactiveVal(FALSE)

  next_step <- \() step(min(step() + 1L, 4L))
  prev_step <- \() step(max(step() - 1L, 1L))

  reset <- function() {
    step(1L)
    username(""); email(""); password(""); confirm_password("")
    display_name(""); bio(""); avatar_url(""); timezone("UTC")
    theme("light"); language("en")
    email_notifications(TRUE); sms_notifications(FALSE); newsletter(FALSE)
  }

  submit <- function() {
    payload <- list(
      account = list(
        username = username(),
        email = email(),
        password = password()
      ),
      profile = list(
        display_name = display_name(),
        bio = bio(),
        avatar_url = avatar_url(),
        timezone = timezone()
      ),
      preferences = list(
        theme = theme(),
        language = language(),
        email_notifications = email_notifications(),
        sms_notifications = sms_notifications(),
        newsletter = newsletter()
      )
    )
    post_to_server(payload)
  }

  # NOTE: load_draft below repeats the entire field list a third time (once to
  # declare, once to reset, once to load). I wanted something like a single
  # "form schema" that the three operations could walk, but doing so would mean
  # inventing a new abstraction.
  load_draft <- function(saved) {
    a <- saved$account %||% list()
    p <- saved$profile %||% list()
    r <- saved$preferences %||% list()
    if (!is.null(a$username)) username(a$username)
    if (!is.null(a$email)) email(a$email)
    if (!is.null(a$password)) password(a$password)
    if (!is.null(p$display_name)) display_name(p$display_name)
    if (!is.null(p$bio)) bio(p$bio)
    if (!is.null(p$avatar_url)) avatar_url(p$avatar_url)
    if (!is.null(p$timezone)) timezone(p$timezone)
    if (!is.null(r$theme)) theme(r$theme)
    if (!is.null(r$language)) language(r$language)
    if (!is.null(r$email_notifications)) email_notifications(r$email_notifications)
    if (!is.null(r$sms_notifications)) sms_notifications(r$sms_notifications)
    if (!is.null(r$newsletter)) newsletter(r$newsletter)
  }

  `%||%` <- function(a, b) if (is.null(a)) b else a

  page_fluid(
    card(
      card_body(
        # Progress indicator
        tags$div(
          class = "d-flex justify-content-between mb-4",
          lapply(
            list(
              list(n = 1L, label = "Account"),
              list(n = 2L, label = "Profile"),
              list(n = 3L, label = "Preferences"),
              list(n = 4L, label = "Review")
            ),
            \(s) tags$div(
              class = \() {
                base <- "flex-grow-1 text-center py-2 border-bottom border-3"
                if (step() == s$n) paste(base, "border-primary fw-bold")
                else if (step() > s$n) paste(base, "border-success text-muted")
                else paste(base, "border-light text-muted")
              },
              paste0(s$n, ". ", s$label)
            )
          )
        ),

        # Step body
        Match(
          Case(\() step() == 1L, Step1Account(username, email, password, confirm_password)),
          Case(\() step() == 2L, Step2Profile(display_name, bio, avatar_url, timezone)),
          Case(\() step() == 3L, Step3Preferences(theme, language, email_notifications, sms_notifications, newsletter)),
          Default(Step4Review(
            username, email,
            display_name, bio, avatar_url, timezone,
            theme, language, email_notifications, sms_notifications, newsletter
          ))
        ),

        # Nav buttons
        tags$div(
          class = "d-flex justify-content-between mt-4",
          tags$button(
            class = "btn btn-outline-secondary",
            disabled = \() step() == 1L,
            onClick = \() prev_step(),
            "Previous"
          ),
          tags$div(
            class = "d-flex gap-2",
            tags$button(
              class = "btn btn-outline-danger",
              onClick = \() reset(),
              "Reset"
            ),
            When(
              \() step() < 4L,
              tags$button(
                class = "btn btn-primary",
                onClick = \() next_step(),
                "Next"
              ),
              otherwise = tags$button(
                class = "btn btn-success",
                onClick = \() submit(),
                "Submit"
              )
            )
          )
        )
      )
    )
  )
}

iridApp(WizardApp)
