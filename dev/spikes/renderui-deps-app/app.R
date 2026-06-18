# Spike for issue #34 — deliver widget deps through Shiny's native render
# pipeline so they load under shinylive, WITHOUT page-attaching at process_tags.
#
# Premise under test: a *file-backed* html_dependency delivered MID-SESSION via
# `renderUI` (a uiOutput, i.e. Shiny's native render pipeline) is served by
# shinylive — whereas the same dep shipped on a custom-message side channel
# (`Shiny.renderDependencies` from `sendCustomMessage`) 404s. If the premise
# holds, irid can route widget deps through a hidden uiOutput at mount time
# instead of page-attaching them, which would also reach widgets that appear
# only inside When/Each/Match (the current static-tree-only limitation).
#
# This is a plain Shiny app (no irid) so the only thing under test is the stock
# Shiny dep-delivery surface under shinylive. Click the button and the app
# delivers the SAME file-backed dep two ways; each row turns green only if its
# script actually executed (a 404'd <script> never runs). Both deps' scripts
# live in NON-www subdirs (libA/, libB/), so shinylive will not serve them as
# plain static assets — the only way a row goes green is if that dep's serving
# path resolved.
#
#   Expected if premise holds:  A green, B red.
#   (B) is the control — it reproduces the known #34 404 and proves a red row
#   means "not served", so a green A is not a false positive.
#
# ── Run it (open in a real browser — that is how shinylive is verified) ──────
#   Rscript -e 'shinylive::export("dev/spikes/renderui-deps-app", "/tmp/spike-out")'
#   cd /tmp/spike-out && python3 -m http.server 8008
#   # then open http://localhost:8008 and click the button.
#
# No COOP/COEP/MIME server config needed: shinylive's service worker injects the
# cross-origin-isolation headers itself, so any plain static server works.
# First load is slow (cold webR + `shiny` install from the webR CDN).
#
# Pinned: shinylive web assets 0.9.1 — re-confirm on bump (this leans on
# shinylive runtime serving behavior, exactly what a spike, not memory, settles).

library(shiny)

# file-backed dep: absolute src dir + script, the same shape irid ships its
# widget deps as. normalizePath resolves inside the webR FS at runtime.
mk_dep <- function(name, dir, script) htmltools::htmlDependency(
  name = name, version = "0.0.1",
  src = normalizePath(dir, mustWork = FALSE), script = script
)

ui <- fluidPage(
  tags$head(tags$script(HTML(
    "Shiny.addCustomMessageHandler('spike-msg-dep', function(dep){ Shiny.renderDependencies([dep]); });"
  ))),
  tags$h3("issue #34 spike — widget deps under shinylive"),
  tags$p(
    "Click the button, then read the two rows. Each turns green only if its ",
    "dependency script actually loaded and executed under shinylive."
  ),
  actionButton("go", "Deliver both deps (mid-session)"),
  tags$hr(),
  tags$div(id = "statusA", style = "color:#b00; font-weight:bold; margin:4px 0",
           "A) renderUI (native pipeline): NOT LOADED"),
  tags$div(id = "statusB", style = "color:#b00; font-weight:bold; margin:4px 0",
           "B) custom message (side channel, control): NOT LOADED"),
  tags$hr(),
  tags$p(tags$b("Expected if the premise holds: A green, B red.")),
  tags$p("A green => deps delivered via a hidden uiOutput load under shinylive, ",
         "so the 'just the deps via renderUI' fix is viable."),
  tags$p("B is the #34 control: the side channel that 404s under shinylive. ",
         "If B is also green, shinylive now serves the side channel too and the ",
         "#34 root cause has shifted."),
  uiOutput("via_renderui")
)

server <- function(input, output, session) {
  observeEvent(input$go, {
    # (A) native pipeline: a uiOutput carrying a file-backed dep
    output$via_renderui <- renderUI(
      htmltools::attachDependencies(
        tags$span(), mk_dep("spikeRenderui", "libA", "splibA.js")
      )
    )
    # (B) control: custom-message side channel (the known #34 404 path).
    #     Isolated so a failure here cannot break (A).
    tryCatch({
      web <- shiny::createWebDependency(mk_dep("spikeMsg", "libB", "splibB.js"))
      session$sendCustomMessage("spike-msg-dep", web)
    }, error = function(e) message("control path error: ", conditionMessage(e)))
  })
}

shinyApp(ui, server)
