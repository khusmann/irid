# Dynamic Column Cards
#
# Re-creates the scenario from:
# https://www.kylehusmann.com/posts/2025/shiny-dynamic-observers/
#
# The user picks a dataset, then picks columns from it, and each selected
# column becomes a card with a close button. Removing a card puts the
# column back in the dropdown. In Shiny this required nested observers,
# ghost-input workarounds, and a memory leak fix. Here the parent owns a
# reactiveVal and the dropdown and close buttons both read and write it
# directly.

library(irid)
library(bslib)

all_datasets <- sort(ls("package:datasets")) |>
  (\(v) v[order(tolower(v), v)])() |> # Case insensitive ordering
  sapply(get, pos = "package:datasets", simplify = FALSE) |>
  Filter(is.data.frame, x = _)

Card <- function(col, col_class, on_close) {
  tags$div(
    class = paste(
      "card border-2 border-secondary mb-2 p-2 d-flex flex-row",
      "justify-content-between align-items-center"
    ),
    tags$div(
      tags$strong(col),
      tags$span(
        class = "text-muted ms-2",
        \() paste0("(", col_class(), ")")
      )
    ),
    tags$button(
      class = "btn btn-sm btn-outline-danger",
      onClick = on_close,
      "\u00d7"
    )
  )
}

App <- function() {
  dataset_name <- reactiveVal(names(all_datasets)[1])
  selected_columns <- reactiveVal(character(0))
  choice <- reactiveVal("")

  dataset <- \() all_datasets[[dataset_name()]]
  available <- \() setdiff(names(dataset()), selected_columns())

  # Clear selections when dataset changes
  observe({
    dataset_name()
    selected_columns(character(0))
    choice("")
  })

  page_fluid(
    tags$h3("Column Cards"),

    tags$label(class = "form-label", "Select a dataset:"),
    tags$select(
      class = "form-select mb-3",
      value = dataset_name,
      onChange = \(event) dataset_name(event$value),
      Each(\() names(all_datasets), \(name) tags$option(value = name, name))
    ),

    tags$label(class = "form-label", "Add a column:"),
    tags$select(
      class = "form-select mb-3",
      value = choice,
      onChange = \(event) {
        if (nzchar(event$value)) {
          selected_columns(c(selected_columns(), event$value))
          choice("")
        }
      },
      tags$option(value = "", "Select a column..."),
      Each(available, \(col) tags$option(value = col, col))
    ),

    Each(selected_columns, \(col) {
      Card(
        col,
        col_class = \() class(dataset()[[col]])[1],
        on_close = \() selected_columns(setdiff(selected_columns(), col))
      )
    })
  )
}

iridApp(App)
