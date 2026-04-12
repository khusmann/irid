# Profile editor — comparison of loose reactiveVals vs. reactiveStore.
#
# Shape under test:
#   { user:        { name, email },
#     address:     { street, city, zip, country },
#     preferences: { theme, newsletter, language } }
#
# 9 fields, 3 nested groups. The operations we care about are reset,
# snapshot (for send-to-server), load (from server), and component
# composition — passing a subtree to a child component without the child
# knowing where it came from.
#
# Not runnable — read-only comparison.

library(irid)


# =============================================================================
# WITHOUT STORE — 9 loose reactiveVals
# =============================================================================

ProfileApp_loose <- function() {

  defaults <- list(
    user        = list(name = "", email = ""),
    address     = list(street = "", city = "", zip = "", country = "US"),
    preferences = list(theme = "light", newsletter = FALSE, language = "en")
  )

  user_name       <- reactiveVal(defaults$user$name)
  user_email      <- reactiveVal(defaults$user$email)
  address_street  <- reactiveVal(defaults$address$street)
  address_city    <- reactiveVal(defaults$address$city)
  address_zip     <- reactiveVal(defaults$address$zip)
  address_country <- reactiveVal(defaults$address$country)
  pref_theme      <- reactiveVal(defaults$preferences$theme)
  pref_newsletter <- reactiveVal(defaults$preferences$newsletter)
  pref_language   <- reactiveVal(defaults$preferences$language)

  reset <- function() {
    user_name(defaults$user$name)
    user_email(defaults$user$email)
    address_street(defaults$address$street)
    address_city(defaults$address$city)
    address_zip(defaults$address$zip)
    address_country(defaults$address$country)
    pref_theme(defaults$preferences$theme)
    pref_newsletter(defaults$preferences$newsletter)
    pref_language(defaults$preferences$language)
  }

  snapshot <- function() {
    list(
      user = list(
        name  = user_name(),
        email = user_email()
      ),
      address = list(
        street  = address_street(),
        city    = address_city(),
        zip     = address_zip(),
        country = address_country()
      ),
      preferences = list(
        theme      = pref_theme(),
        newsletter = pref_newsletter(),
        language   = pref_language()
      )
    )
  }

  load <- function(data) {
    user_name(data$user$name)
    user_email(data$user$email)
    address_street(data$address$street)
    address_city(data$address$city)
    address_zip(data$address$zip)
    address_country(data$address$country)
    pref_theme(data$preferences$theme)
    pref_newsletter(data$preferences$newsletter)
    pref_language(data$preferences$language)
  }

  save <- function() post_to_server(snapshot())

  # Child components receive a bag of reactiveVals. Each field the child
  # touches is a separate parameter — adding a field to the shape means
  # updating the callsite AND the component signature.
  AddressFields <- function(street, city, zip, country) {
    tags$fieldset(
      tags$input(
        value = street,
        onInput = \(e) street(e$value)
      ),
      tags$input(
        value = city,
        onInput = \(e) city(e$value)
      ),
      tags$input(
        value = zip,
        onInput = \(e) zip(e$value)
      ),
      tags$select(
        value = country,
        onChange = \(e) country(e$value)
      )
    )
  }

  PreferencesFields <- function(theme, newsletter, language) {
    tags$fieldset(
      tags$select(
        value = theme,
        onChange = \(e) theme(e$value)
      ),
      tags$input(
        type = "checkbox",
        checked = newsletter,
        onClick = \(e) newsletter(e$checked)
      ),
      tags$select(
        value = language,
        onChange = \(e) language(e$value)
      )
    )
  }

  page_fluid(
    tags$h2("Profile"),
    tags$input(
      value = user_name,
      onInput = \(e) user_name(e$value)
    ),
    tags$input(
      value = user_email,
      onInput = \(e) user_email(e$value)
    ),
    AddressFields(address_street, address_city, address_zip, address_country),
    PreferencesFields(pref_theme, pref_newsletter, pref_language),
    tags$button("Reset", onClick = \() reset()),
    tags$button("Save",  onClick = \() save())
  )
}


# =============================================================================
# WITH STORE — one reactiveStore
# =============================================================================

ProfileApp_store <- function() {

  defaults <- list(
    user        = list(name = "", email = ""),
    address     = list(street = "", city = "", zip = "", country = "US"),
    preferences = list(theme = "light", newsletter = FALSE, language = "en")
  )

  state <- reactiveStore(defaults)

  reset    <- function()     state(defaults)
  snapshot <- function()     state()
  load     <- function(data) state(data)
  save     <- function()     post_to_server(state())

  # Child components receive a subtree. The component doesn't know or care
  # that it's a subtree rather than a root store. Adding a field to the
  # shape is a one-line change to defaults — no callsite or signature churn.
  AddressFields <- function(address) {
    tags$fieldset(
      tags$input(
        value = address$street,
        onInput = \(e) address$street(e$value)
      ),
      tags$input(
        value = address$city,
        onInput = \(e) address$city(e$value)
      ),
      tags$input(
        value = address$zip,
        onInput = \(e) address$zip(e$value)
      ),
      tags$select(
        value = address$country,
        onChange = \(e) address$country(e$value)
      )
    )
  }

  PreferencesFields <- function(prefs) {
    tags$fieldset(
      tags$select(
        value = prefs$theme,
        onChange = \(e) prefs$theme(e$value)
      ),
      tags$input(
        type = "checkbox",
        checked = prefs$newsletter,
        onClick = \(e) prefs$newsletter(e$checked)
      ),
      tags$select(
        value = prefs$language,
        onChange = \(e) prefs$language(e$value)
      )
    )
  }

  page_fluid(
    tags$h2("Profile"),
    tags$input(
      value = state$user$name,
      onInput = \(e) state$user$name(e$value)
    ),
    tags$input(
      value = state$user$email,
      onInput = \(e) state$user$email(e$value)
    ),
    AddressFields(state$address),
    PreferencesFields(state$preferences),
    tags$button("Reset", onClick = \() reset()),
    tags$button("Save",  onClick = \() save())
  )
}
