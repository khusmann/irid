# Filter panel with presets: lapply/names for filter bar, Each for presets,
# branch snapshot/restore

library(irid)

FilterApp <- function() {
  filter_defaults <- list(
    date_from = "",
    date_to   = "",
    category  = "",
    search    = "",
    sort_by   = "date",
    sort_dir  = "asc",
    page      = 1L
  )

  state <- reactiveStore(list(
    filters = filter_defaults,
    presets = list()
  ))

  save_preset <- function(name) {
    state$presets(c(state$presets(), list(list(
      name    = name,
      filters = state$filters()
    ))))
  }

  load_preset <- function(name) {
    p <- Find(\(x) x$name == name, state$presets())
    if (!is.null(p)) state$filters(p$filters)
  }

  delete_preset <- function(name) {
    state$presets(Filter(\(x) x$name != name, state$presets()))
  }

  FilterBar <- function(filters) {
    tags$div(
      lapply(names(filters), \(k) {
        tags$div(
          tags$label(k),
          tags$input(value = filters[[k]])
        )
      })
    )
  }

  PresetList <- function() {
    Each(state$presets, by = \(p) p$name, \(preset) {
      tags$div(
        tags$button(
          \() preset$name(),
          onClick = \() load_preset(preset$name())
        ),
        tags$button(
          "\u00d7",
          onClick = \() delete_preset(preset$name())
        )
      )
    })
  }

  preset_name <- reactiveVal("")

  page_fluid(
    FilterBar(state$filters),
    tags$div(
      tags$input(value = preset_name, placeholder = "Preset name..."),
      tags$button(
        "Save preset",
        onClick = \() {
          name <- trimws(preset_name())
          if (nchar(name) > 0L) {
            save_preset(name)
            preset_name("")
          }
        }
      )
    ),
    PresetList(),
    tags$div(
      tags$button("Reset",  onClick = \() state$filters(filter_defaults)),
      tags$button("Search", onClick = \() run_search(state$filters()))
    )
  )
}

iridApp(FilterApp)
