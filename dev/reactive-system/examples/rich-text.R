# Third-party component write interception via reactiveProxy

library(irid)

# RichTextEditor is from a third-party package — not our code.
# It accepts a single callable and calls it with new HTML on edits.
# No onChange prop, no onInput support.
#
# RichTextEditor <- function(content) { ... }

MAX_CHARS <- 10000L

char_count <- function(html) {
  # Strip HTML tags to count visible characters
  nchar(gsub("<[^>]+>", "", html))
}

RichTextApp <- function() {
  state <- reactiveStore(list(
    content = "<p>Start typing...</p>",
    title   = "My Document"
  ))
  content_error <- reactiveVal(NULL)

  constrained_content <- reactiveProxy(state$content,
    set = \(v) {
      n <- char_count(v)
      if (n <= MAX_CHARS) {
        content_error(NULL)
        state$content(v)
      } else {
        content_error(sprintf(
          "Content too long: %d / %d characters",
          n,
          MAX_CHARS
        ))
      }
    }
  )

  page_fluid(
    tags$div(
      tags$label("Title"),
      tags$input(value = state$title)
    ),
    tags$div(
      RichTextEditor(constrained_content),
      When(
        \() !is.null(content_error()),
        tags$p(\() content_error(), style = "color: red")
      ),
      tags$p(\() sprintf(
        "%d / %d characters",
        char_count(state$content()),
        MAX_CHARS
      ))
    ),
    tags$button(
      "Save",
      onClick = \() save_document(state())
    )
  )
}

iridApp(RichTextApp)
