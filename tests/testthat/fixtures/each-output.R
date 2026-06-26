# Fixture for anchors.lookupAnchors() lazy re-scan (test-each-e2e.R).
#
# An Each delivered through iridOutput/renderIrid: its anchors arrive as a Shiny
# OUTPUT binding update (innerHTML), NOT a custom message, so they are absent
# from the client's anchor Map that was indexed at page load. The first
# irid-mutate (an add) therefore misses the container anchor and must trigger
# lookupAnchors' lazy indexAnchors(document.body) re-scan to find it — without
# which the insert would silently no-op. Returns a full shiny.appobj (the e2e
# boot helper runs it verbatim instead of wrapping in iridApp).

library(irid)
library(shiny)

EachList <- function(items, on_add) {
  tags$div(
    tags$button(id = "btn-add", onClick = on_add, "add"),
    tags$ul(
      id = "olist",
      Each(items, by = \(x) x$id, \(item) {
        tags$li("data-id" = isolate(item$id()), \() item$text())
      })
    )
  )
}

ui <- fluidPage(
  iridOutput("slot")
)

server <- function(input, output, session) {
  items <- reactiveVal(list(list(id = "x", text = "Ex")))
  n <- reactiveVal(0L)
  add <- function() {
    k <- n() + 1L
    n(k)
    items(c(items(), list(list(id = paste0("n", k), text = paste0("New", k)))))
  }
  output$slot <- renderIrid(EachList(items, on_add = add))
}

shinyApp(ui, server)
