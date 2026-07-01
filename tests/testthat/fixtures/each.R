# Fixture for the Each / irid-mutate granular-DOM protocol (test-each-e2e.R).
#
# A keyed Each (`by = id`) over records renders <li> into a <ul>, exercising the
# whole client mutate surface: inserts (append), removes (middle), and reorder
# (the `order` array) — plus anchors.detachRange / unregisterAnchorsIn /
# parseFragment. The <ul> parent is restricted-content (a wrapper <div> would be
# hoisted by the parser), so it also asserts parseFragment parses each item in
# the <ul> context. Each <li> stamps its key as a static data-id so the test can
# track element identity across a reorder. A second positional (by = NULL) Each
# covers append/truncate without an `order`.

library(irid)

App <- function() {
  items <- reactiveVal(list(
    list(id = "a", text = "Alpha"),
    list(id = "b", text = "Beta"),
    list(id = "c", text = "Gamma")
  ))
  nums <- reactiveVal(c("one", "two"))

  append_item <- function() {
    items(c(items(), list(list(id = "d", text = "Delta"))))
  }
  remove_mid <- function() {
    items(Filter(\(x) x$id != "b", items()))
  }
  reverse_items <- function() {
    items(rev(items()))
  }
  rename_a <- function() {
    cur <- items()
    i <- which(vapply(cur, \(x) x$id, character(1)) == "a")
    if (length(i)) cur[[i]]$text <- "Alpha2"
    items(cur)
  }

  ids <- \() paste(vapply(items(), \(x) x$id, character(1)), collapse = ",")

  tags$div(
    tags$button(id = "btn-append", onClick = append_item, "append"),
    tags$button(id = "btn-remove", onClick = remove_mid, "remove"),
    tags$button(id = "btn-reverse", onClick = reverse_items, "reverse"),
    tags$button(id = "btn-rename", onClick = rename_a, "rename"),
    tags$button(id = "btn-grow", onClick = \() nums(c(nums(), "three")), "grow"),
    tags$button(id = "btn-shrink", onClick = \() nums(utils::head(nums(), 1L)), "shrink"),

    # Keyed Each in a restricted-content parent (<ul> accepts only <li>). The
    # reactive text child (`\() item$text()`) lives inside each <li>, so an
    # in-place rename round-trips through a `text` op.
    tags$ul(
      id = "klist",
      Each(items, by = \(x) x$id, \(item) {
        tags$li(
          "data-id" = isolate(item$id()),
          \() item$text()
        )
      })
    ),

    # Positional scalar Each (by = NULL): grow appends, shrink truncates.
    tags$ul(
      id = "plist",
      Each(nums, \(n) tags$li(class = "num", \() n()))
    ),

    tags$span(id = "ro-ids", ids)
  )
}

App
