# Profile editor: branch iteration with lapply/names, RenderGroup/RenderField, reset/save

library(irid)

RenderField <- function(field, key) {
  tags$div(
    tags$label(key),
    tags$input(value = field)
  )
}

RenderGroup <- function(group) {
  tags$fieldset(
    tags$legend(\() group$name()),
    lapply(names(group$fields), \(k) RenderField(group$fields[[k]], k))
  )
}

ProfileApp <- function() {
  defaults <- list(
    user = list(
      name   = "User",
      fields = list(name = "", email = "")
    ),
    address = list(
      name   = "Address",
      fields = list(street = "", city = "", zip = "", country = "US")
    ),
    preferences = list(
      name   = "Preferences",
      fields = list(theme = "light", language = "en")
    )
  )
  state <- reactiveStore(defaults)

  page_fluid(
    tags$h2("Profile"),
    lapply(names(state), \(k) RenderGroup(state[[k]])),
    tags$div(
      tags$button("Reset", onClick = \() state(defaults)),
      tags$button("Save",  onClick = \() post_to_server(state()))
    )
  )
}

iridApp(ProfileApp)
