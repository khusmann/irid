# Spike for issue #34 — deliver widget deps through Shiny's native render
# pipeline so they load under shinylive, WITHOUT page-attaching at process_tags.
#
# Premise under test: a *file-backed* html_dependency delivered mid-session via
# `renderUI` (a uiOutput, i.e. Shiny's native render pipeline) is served by
# shinylive — whereas the same dep shipped on a custom-message side channel
# (`Shiny.renderDependencies` from `sendCustomMessage`) 404s. If the premise
# holds, irid can route widget deps through a hidden uiOutput at mount time
# instead of page-attaching them, which would also reach widgets that appear
# only inside When/Each/Match (the current static-tree-only limitation).
#
# This is a *plain Shiny* app (no irid) so the only thing under test is the
# stock Shiny dep-delivery surface under shinylive. It runs TWO deliveries on
# one button click and reports which script actually executed in the browser:
#
#   (A) renderUI(attachDependencies(span, depA))   -> sets window.__SPIKE_RENDERUI
#   (B) sendCustomMessage(renderDependencies(depB)) -> sets window.__SPIKE_MSG
#
# Both deps are file-backed and their script files live in NON-www subdirs
# (libA/, libB/) of the app — so shinylive will NOT serve them as plain static
# assets. The only way a global gets set is if that dep's serving path actually
# resolved (HTTP 200 + executed). A global is unambiguous: a <script src> that
# 404s never runs.
#
#   Expected if premise holds: __SPIKE_RENDERUI set, __SPIKE_MSG absent.
#   (B) is the control — it reproduces the known #34 404 and proves the harness
#   can actually detect a non-served dep, so a PASS on (A) isn't a false positive
#   where everything loads regardless.
#
# ── Running this ────────────────────────────────────────────────────────────
# Run:  Rscript dev/spikes/renderui-deps-shinylive.R
# Build-ignored via `^dev$` in .Rbuildignore.
#
# shinylive runs the whole app in-browser via webR. This spike serves the
# static export with the headers + MIME webR needs for cross-origin isolation
# (COOP/COEP + application/wasm) and drives headless Chrome to the verdict.
#
# CAVEAT (learned the hard way while writing this): under cross-origin
# isolation webR runs R inside a *Web Worker*, and a bare headless-Chrome
# session does not auto-attach to worker targets — so a sandbox/CI headless
# boot can stall before the app ever renders, with no console output, even
# though serving is correct (the harness verifies `crossOriginIsolated === true`
# and a clean wasm compile, then waits for the app). If it stalls at the boot
# gate, run it on a machine with a real (headed) Chrome — the same environment
# where shinylive demos already work — rather than trusting a headless box.
# First boot is slow (cold webR + `shiny` package install from the webR CDN).
#
# Pinned: shinylive web assets 0.9.1, Shiny 1.7.4 — re-confirm on bump (this
# leans on shinylive runtime behavior, exactly what a spike, not memory, settles).

stopifnot(requireNamespace("shiny"), requireNamespace("shinylive"),
          requireNamespace("chromote"), requireNamespace("httpuv"),
          requireNamespace("callr"))

`%||%` <- function(a, b) if (is.null(a)) b else a
cat("shiny:    ", as.character(utils::packageVersion("shiny")), "\n")
cat("shinylive:", as.character(utils::packageVersion("shinylive")),
    " (web assets", shinylive::assets_version(), ")\n\n")

# --- build the throwaway app dir -------------------------------------------

appdir <- file.path(tempdir(), "spike-app")
unlink(appdir, recursive = TRUE)
dir.create(file.path(appdir, "libA"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(appdir, "libB"), recursive = TRUE, showWarnings = FALSE)

writeLines("window.__SPIKE_RENDERUI = Date.now();",
           file.path(appdir, "libA", "splibA.js"))
writeLines("window.__SPIKE_MSG = Date.now();",
           file.path(appdir, "libB", "splibB.js"))

writeLines(c(
  'library(shiny)',
  '',
  '# file-backed dep: absolute src dir + script, the same shape irid ships its',
  '# widget deps as. normalizePath resolves inside the webR FS at runtime.',
  'mk_dep <- function(name, dir, script) htmltools::htmlDependency(',
  '  name = name, version = "0.0.1",',
  '  src = normalizePath(dir, mustWork = FALSE), script = script',
  ')',
  '',
  'ui <- fluidPage(',
  '  tags$head(tags$script(HTML(',
  '    "Shiny.addCustomMessageHandler(\'spike-msg-dep\', function(dep){ Shiny.renderDependencies([dep]); });"',
  '  ))),',
  '  textOutput("ready"),',
  '  actionButton("go", "go"),',
  '  uiOutput("via_renderui")',
  ')',
  '',
  'server <- function(input, output, session) {',
  '  output$ready <- renderText("READY")',
  '  observeEvent(input$go, {',
  '    # (A) native pipeline: a uiOutput carrying a file-backed dep',
  '    output$via_renderui <- renderUI(',
  '      htmltools::attachDependencies(tags$span("ru"), mk_dep("spikeRenderui", "libA", "splibA.js"))',
  '    )',
  '    # (B) control: custom-message side channel (the known #34 404 path).',
  '    #     Isolated so a failure here cannot break (A).',
  '    tryCatch({',
  '      web <- shiny::createWebDependency(mk_dep("spikeMsg", "libB", "splibB.js"))',
  '      session$sendCustomMessage("spike-msg-dep", web)',
  '    }, error = function(e) message("control path error: ", conditionMessage(e)))',
  '  })',
  '}',
  '',
  'shinyApp(ui, server)'
), file.path(appdir, "app.R"))

# --- export to a static shinylive site -------------------------------------

outdir <- file.path(tempdir(), "spike-out")
unlink(outdir, recursive = TRUE)
cat("exporting shinylive site ...\n")
shinylive::export(appdir, outdir)

# --- serve it from a CHILD process -----------------------------------------
# Two non-negotiables for webR cross-origin isolation, both verified necessary:
#   * COOP `same-origin` + COEP `require-corp` (else webR drops to the degraded
#     PostMessage channel and the Shiny server loop never runs), and
#   * `Content-Type: application/wasm` (else the threaded build's streaming
#     compile fails).
# httpuv's stock static server maps neither, so we serve via a small handler.
# It runs in a child process because an in-process R handler can't answer
# requests while the parent thread is blocked driving Chrome.

serve_fn <- function(outdir, port) {
  mime <- c(
    html = "text/html", js = "text/javascript", mjs = "text/javascript",
    wasm = "application/wasm", json = "application/json", css = "text/css",
    svg = "image/svg+xml", png = "image/png", ico = "image/x-icon",
    gif = "image/gif", woff2 = "font/woff2", woff = "font/woff",
    ttf = "font/ttf", data = "application/octet-stream",
    rds = "application/octet-stream", so = "application/octet-stream",
    py = "text/x-python", txt = "text/plain", map = "application/json",
    tgz = "application/gzip"
  )
  coiso <- list(
    "Cross-Origin-Opener-Policy"   = "same-origin",
    "Cross-Origin-Embedder-Policy" = "require-corp",
    "Cross-Origin-Resource-Policy" = "cross-origin"
  )
  serve <- function(req) {
    path <- sub("\\?.*$", "", req$PATH_INFO)
    if (path == "/" || path == "") path <- "/index.html"
    f <- file.path(outdir, sub("^/", "", path))
    if (!file.exists(f) || dir.exists(f)) {
      return(list(status = 404L,
                  headers = list("Content-Type" = "text/plain"), body = "404"))
    }
    ext <- tolower(tools::file_ext(f))
    ct <- if (!is.null(mime[[ext]])) mime[[ext]] else "application/octet-stream"
    list(status = 200L,
         headers = c(list("Content-Type" = ct), coiso),
         body = readBin(f, "raw", file.info(f)$size))
  }
  httpuv::runServer("127.0.0.1", port, list(call = serve))
}

port <- httpuv::randomPort()
proc <- callr::r_bg(serve_fn, args = list(outdir = outdir, port = port),
                    supervise = TRUE)
on.exit(tryCatch(proc$kill(), error = function(e) NULL), add = TRUE)
Sys.sleep(2)
if (!proc$is_alive()) stop("static server died:\n",
                           paste(proc$read_all_error_lines(), collapse = "\n"))
url <- sprintf("http://127.0.0.1:%d/", port)
cat("serving at", url, "\n")

# --- drive headless chrome --------------------------------------------------

b <- chromote::ChromoteSession$new()
on.exit(tryCatch(b$close(), error = function(e) NULL), add = TRUE)
b$Runtime$enable(wait_ = TRUE)
b$Page$navigate(url, wait_ = TRUE)

ev <- function(js, await = TRUE) {
  r <- b$Runtime$evaluate(js, returnByValue = TRUE, awaitPromise = await,
                          wait_ = TRUE)
  if (!is.null(r$exceptionDetails)) {
    stop("JS error: ", r$exceptionDetails$exception$description %||%
           r$exceptionDetails$text)
  }
  r$result$value
}

# webR cold boot is slow; the server is "up" once the ready output round-trips.
cat("waiting for shinylive/webR to boot (cold boot can take minutes) ...\n")
boot_deadline <- Sys.time() + 360
booted <- FALSE
repeat {
  st <- jsonlite::fromJSON(ev("JSON.stringify({
    coi: self.crossOriginIsolated,
    ready: (document.getElementById('ready')||{}).textContent || null
  })"))
  if (!is.null(st$ready) && grepl("READY", st$ready)) { booted <- TRUE; break }
  if (Sys.time() > boot_deadline) break
  cat(sprintf("  ... still booting (crossOriginIsolated=%s)\n",
              isTRUE(st$coi)))
  Sys.sleep(10)
}
if (!booted) {
  cat("\nSTALLED at the boot gate — the app never rendered.\n")
  cat("crossOriginIsolated was:", isTRUE(st$coi), "\n")
  cat("If that is TRUE, serving is correct and this is the headless-worker\n")
  cat("stall described in the header — re-run on a machine with headed Chrome.\n")
  quit(status = 3)
}
cat("app is up; clicking go ...\n")

ev("document.getElementById('go').click(); true", await = FALSE)

# Give both delivery paths time to inject + fetch + execute their <script>.
Sys.sleep(1)
seen_deadline <- Sys.time() + 30
repeat {
  hit <- ev("(typeof window.__SPIKE_RENDERUI !== 'undefined') ||
             (typeof window.__SPIKE_MSG !== 'undefined')")
  if (isTRUE(hit) || Sys.time() > seen_deadline) break
  Sys.sleep(0.5)
}
Sys.sleep(2)  # let a slower second path land before we read both

res <- jsonlite::fromJSON(ev("JSON.stringify({
  renderui: (typeof window.__SPIKE_RENDERUI !== 'undefined'),
  msg:      (typeof window.__SPIKE_MSG !== 'undefined'),
  resources: (performance.getEntriesByType('resource')||[])
    .filter(function(e){return /splib[AB]\\.js/.test(e.name);})
    .map(function(e){return e.name.replace(/^https?:\\/\\/[^/]+/, '') + ' status=' + (e.responseStatus || '?');})
})"))

# --- verdict ---------------------------------------------------------------

cat("\n================ VERDICT ================\n")
cat(sprintf("(A) renderUI file-backed dep executed:        %s\n",
            if (isTRUE(res$renderui)) "YES" else "no"))
cat(sprintf("(B) custom-message file-backed dep executed:  %s   (control)\n",
            if (isTRUE(res$msg)) "YES" else "no"))
cat("\nsplib resource requests seen by the browser:\n")
if (length(res$resources)) {
  for (r in res$resources) cat("  ", r, "\n")
} else {
  cat("   (none — neither script was even requested)\n")
}

cat("\n")
if (isTRUE(res$renderui) && !isTRUE(res$msg)) {
  cat("PASS — premise holds: renderUI delivers a file-backed dep under\n")
  cat("shinylive (served), while the custom-message side channel 404s.\n")
  cat("=> routing widget deps through a hidden uiOutput at mount time is viable.\n")
} else if (isTRUE(res$renderui) && isTRUE(res$msg)) {
  cat("MIXED — renderUI works, but the custom-message control ALSO loaded.\n")
  cat("shinylive may now serve the side channel too (asset-version change?).\n")
  cat("renderUI is still viable; the #34 root cause may have shifted.\n")
} else if (!isTRUE(res$renderui)) {
  cat("FAIL — renderUI did NOT deliver the file-backed dep under shinylive.\n")
  cat("The 'just the deps via renderUI' approach does not work as hoped;\n")
  cat("inspect the resource list above (404? never requested?).\n")
}
cat("========================================\n")
