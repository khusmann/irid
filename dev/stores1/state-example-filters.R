# Dashboard Filter Panel with Saved Presets
#
# A filter bar driving a fake results view, with named preset support. Each
# filter field is its own reactiveVal. Presets are stored as a list in a
# single reactiveVal — a preset is a snapshot, logically atomic, so the
# whole-list-in-one-reactiveVal pattern from todo.R fits.

library(irid)
library(bslib)

default_filters <- list(
  date_from = "",
  date_to = "",
  category = character(0),
  search = "",
  sort_by = "date",
  sort_dir = "asc",
  page = 1L
)

all_categories <- c("news", "sports", "tech", "business", "entertainment")

FilterBar <- function(
  date_from, date_to, category, search, sort_by, sort_dir, page,
  on_reset
) {
  tags$div(
    class = "card p-3 mb-3",
    tags$div(
      class = "row g-2",
      tags$div(
        class = "col-md-3",
        tags$label(class = "form-label", "Search"),
        tags$input(
          type = "text",
          class = "form-control",
          value = search,
          onInput = \(e) { search(e$value); page(1L) }
        )
      ),
      tags$div(
        class = "col-md-2",
        tags$label(class = "form-label", "From"),
        tags$input(
          type = "date",
          class = "form-control",
          value = date_from,
          onInput = \(e) { date_from(e$value); page(1L) }
        )
      ),
      tags$div(
        class = "col-md-2",
        tags$label(class = "form-label", "To"),
        tags$input(
          type = "date",
          class = "form-control",
          value = date_to,
          onInput = \(e) { date_to(e$value); page(1L) }
        )
      ),
      tags$div(
        class = "col-md-2",
        tags$label(class = "form-label", "Sort by"),
        tags$select(
          class = "form-select",
          value = sort_by,
          onChange = \(e) sort_by(e$value),
          tags$option(value = "date", "Date"),
          tags$option(value = "name", "Name"),
          tags$option(value = "priority", "Priority")
        )
      ),
      tags$div(
        class = "col-md-2",
        tags$label(class = "form-label", "Direction"),
        tags$select(
          class = "form-select",
          value = sort_dir,
          onChange = \(e) sort_dir(e$value),
          tags$option(value = "asc", "Ascending"),
          tags$option(value = "desc", "Descending")
        )
      )
    ),
    tags$div(
      class = "mt-3",
      tags$label(class = "form-label", "Categories"),
      tags$div(
        class = "d-flex flex-wrap gap-2",
        lapply(all_categories, \(cat) tags$div(
          class = "form-check",
          tags$input(
            type = "checkbox",
            class = "form-check-input",
            checked = \() cat %in% category(),
            onClick = \() {
              current <- category()
              if (cat %in% current) category(setdiff(current, cat))
              else category(c(current, cat))
              page(1L)
            }
          ),
          tags$label(class = "form-check-label", cat)
        ))
      )
    ),
    tags$div(
      class = "d-flex justify-content-between align-items-center mt-3",
      tags$div(
        class = "btn-group btn-group-sm",
        tags$button(
          class = "btn btn-outline-secondary",
          disabled = \() page() <= 1L,
          onClick = \() page(page() - 1L),
          "\u2190 Prev"
        ),
        tags$button(
          class = "btn btn-outline-secondary",
          disabled = TRUE,
          \() paste("Page", page())
        ),
        tags$button(
          class = "btn btn-outline-secondary",
          onClick = \() page(page() + 1L),
          "Next \u2192"
        )
      ),
      tags$button(
        class = "btn btn-outline-danger btn-sm",
        onClick = \() on_reset(),
        "Reset filters"
      )
    )
  )
}

PresetList <- function(presets, on_load, on_delete, on_save, current_name) {
  tags$div(
    class = "card p-3 mb-3",
    tags$h5("Presets"),
    When(
      \() length(presets()) > 0,
      tags$div(
        class = "d-flex flex-wrap gap-2 mb-3",
        Each(
          presets,
          by = \(p) p$name,
          \(p) tags$div(
            class = "btn-group btn-group-sm",
            tags$button(
              class = "btn btn-outline-primary",
              onClick = \() on_load(p$name),
              p$name
            ),
            tags$button(
              class = "btn btn-outline-danger",
              onClick = \() on_delete(p$name),
              "\u00d7"
            )
          )
        )
      ),
      otherwise = tags$p(class = "text-muted", "No presets saved yet.")
    ),
    tags$div(
      class = "input-group",
      tags$input(
        type = "text",
        class = "form-control",
        placeholder = "Preset name...",
        value = current_name,
        onInput = \(e) current_name(e$value)
      ),
      tags$button(
        class = "btn btn-primary",
        disabled = \() nchar(trimws(current_name())) == 0,
        onClick = \() {
          on_save(trimws(current_name()))
          current_name("")
        },
        "Save current"
      )
    )
  )
}

FiltersApp <- function() {
  date_from <- reactiveVal(default_filters$date_from)
  date_to <- reactiveVal(default_filters$date_to)
  category <- reactiveVal(default_filters$category)
  search <- reactiveVal(default_filters$search)
  sort_by <- reactiveVal(default_filters$sort_by)
  sort_dir <- reactiveVal(default_filters$sort_dir)
  page <- reactiveVal(default_filters$page)

  presets <- reactiveVal(list())
  preset_name_draft <- reactiveVal("")

  # NOTE: current_filters/reset_filters/load_preset each spell out every field
  # name. A way to declare the filter field set once and have snapshot/restore
  # follow from it would eliminate this.
  current_filters <- function() {
    list(
      date_from = date_from(),
      date_to = date_to(),
      category = category(),
      search = search(),
      sort_by = sort_by(),
      sort_dir = sort_dir(),
      page = page()
    )
  }

  reset_filters <- function() {
    date_from(default_filters$date_from)
    date_to(default_filters$date_to)
    category(default_filters$category)
    search(default_filters$search)
    sort_by(default_filters$sort_by)
    sort_dir(default_filters$sort_dir)
    page(default_filters$page)
  }

  apply_filters <- function(f) {
    date_from(f$date_from)
    date_to(f$date_to)
    category(f$category)
    search(f$search)
    sort_by(f$sort_by)
    sort_dir(f$sort_dir)
    page(f$page)
  }

  save_preset <- function(name) {
    existing <- Filter(\(p) p$name != name, presets())
    presets(c(existing, list(list(name = name, filters = current_filters()))))
  }

  load_preset <- function(name) {
    p <- Find(\(p) p$name == name, presets())
    if (!is.null(p)) apply_filters(p$filters)
  }

  delete_preset <- function(name) {
    presets(Filter(\(p) p$name != name, presets()))
  }

  share_url <- function() {
    f <- current_filters()
    parts <- c(
      paste0("date_from=", f$date_from),
      paste0("date_to=", f$date_to),
      paste0("category=", paste(f$category, collapse = ",")),
      paste0("search=", f$search),
      paste0("sort_by=", f$sort_by),
      paste0("sort_dir=", f$sort_dir),
      paste0("page=", f$page)
    )
    paste0("?", paste(parts, collapse = "&"))
  }

  results_count <- \() length(category()) * 10L + page()

  page_fluid(
    tags$h3("Dashboard"),
    FilterBar(
      date_from, date_to, category, search, sort_by, sort_dir, page,
      on_reset = reset_filters
    ),
    PresetList(
      presets,
      on_load = load_preset,
      on_delete = delete_preset,
      on_save = save_preset,
      current_name = preset_name_draft
    ),
    card(
      card_header("Results"),
      card_body(
        tags$p(
          class = "text-muted",
          \() paste("Showing", results_count(), "results")
        ),
        tags$pre(\() {
          f <- current_filters()
          paste(
            paste("search:", f$search),
            paste("from:", f$date_from),
            paste("to:", f$date_to),
            paste("category:", paste(f$category, collapse = ", ")),
            paste("sort:", f$sort_by, f$sort_dir),
            paste("page:", f$page),
            sep = "\n"
          )
        }),
        tags$div(
          class = "mt-2 text-muted small",
          \() paste("Share:", share_url())
        )
      )
    )
  )
}

iridApp(FiltersApp)
