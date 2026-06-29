# Spike: across how many reactive flushes does an Each (todo-shaped) render?
# Each separate flush == a separate websocket frame == a separate browser paint.
# If items render across N flushes, the user sees them appear one-by-one.
#
# Run: Rscript dev/spikes/each_flush_timing.R   (from package root, after load_all)

pkgload::load_all(".", quiet = TRUE, helpers = FALSE, attach_testthat = FALSE)
library(shiny)

# A session that tags each custom message with the flush-cycle it was sent in.
s <- MockShinySession$new()
flush_no <- 0L
msgs <- list()
s$sendCustomMessage <- function(type, message) {
  msgs[[length(msgs) + 1L]] <<- list(flush = flush_no, type = type, id = message$id,
    inserts = length(message$inserts %||% list()),
    value = if (identical(type, "irid-attr")) message$value else NULL)
  invisible()
}

# Todo-shaped: Each over a list, each item body wrapped in a When, with a
# reactive text child inside (mirrors examples/todo.R structure minus bslib).
todos <- reactiveVal(lapply(1:5, function(i) list(id = i, text = paste("item", i), done = FALSE)))

ui <- tags$ul(
  Each(todos, by = function(t) t$id, function(todo) {
    When(function() TRUE, function() tags$li(
      tags$input(type = "checkbox", checked = todo$done),
      tags$span(function() todo$text()),
      tags$button("x")
    ))
  })
)

result <- process_tags(ui)
isolate(irid:::irid_mount_processed(result, s))

# Drive flush cycles one at a time until the system goes quiet, tagging messages
# with the cycle they landed in. flushReact() runs one reactive flush pass.
prev <- -1L
repeat {
  flush_no <- flush_no + 1L
  shiny:::flushReact()
  if (length(msgs) == prev) break
  prev <- length(msgs)
  if (flush_no > 50L) break
}

cat(sprintf("Total flush cycles with new messages: %d\n", max(vapply(msgs, `[[`, integer(1), "flush"))))
cat("Message-by-flush (flush | type | id | #inserts | text):\n")
for (m in msgs) {
  cat(sprintf("  f%-2d  %-12s id=%-4s inserts=%-2d %s\n",
    m$flush, m$type, m$id %||% "-", m$inserts, if (!is.null(m$value)) paste0("text=", m$value) else ""))
}
