# Spike: in the LIVE app, which reactive flush is each irid message emitted in?
# Decides whether batching "one super-message per flush" collapses the render to
# a single paint, or whether the nested-control-flow cascade spans multiple
# flushes (which per-flush batching could NOT merge into one paint).
#
# Run: IRID_E2E=1 Rscript dev/spikes/flush_attribution.R

LOG <- file.path(normalizePath("dev/spikes"), "flush_attr.log")
if (file.exists(LOG)) file.remove(LOG)
PORT <- 7831L

boot <- function(pkg_root, port, log) {
  pkgload::load_all(pkg_root, quiet = TRUE, helpers = FALSE, attach_testthat = FALSE)
  say <- function(...) {
    cat(sprintf(...), "\n", file = log, append = TRUE, sep = "")
  }
  App <- function() {
    todos <- shiny::reactiveVal(
      lapply(1:6, function(i) list(id = i, text = paste("Todo", i), done = FALSE))
    )
    irid::tags$ul(id = "todo-list", irid::Each(todos, by = function(t) t$id, function(todo) {
      irid::When(function() TRUE, function() irid::tags$li(class = "todo",
        irid::tags$span(function() todo$text()), irid::tags$button("x")))
    }))
  }
  pt <- get("process_tags", asNamespace("irid"))
  dep <- get("irid_dependency", asNamespace("irid"))
  mp <- get("irid_mount_processed", asNamespace("irid"))
  cfg <- get("irid_send_config", asNamespace("irid"))
  rdy <- get("irid_send_ready", asNamespace("irid"))
  ui <- function(req) htmltools::attachDependencies(pt(App())$tag, dep())
  server <- function(input, output, session) {
    say("0.0  SERVER ENTERED")
    t0 <- Sys.time()
    ms <- function() as.numeric(Sys.time() - t0) * 1000
    orig <- session$sendCustomMessage
    session$sendCustomMessage <- function(type, message) {
      id <- if (is.null(message$id)) "-" else message$id
      say("%7.1f  SEND  %-12s id=%s", ms(), type, id)
      orig(type, message)
    }
    arm <- function() {
      session$onFlushed(function() {
        say("%7.1f  ---- FLUSH BOUNDARY ----", ms())
        arm()
      })
    }
    arm()
    cfg(session)
    res <- pt(App())
    say("%7.1f  (mount begin)", ms())
    mp(res, session)
    say("%7.1f  (mount end)", ms())
    rdy(session)
  }
  shiny::runApp(shiny::shinyApp(ui, server), port = port,
                host = "127.0.0.1", launch.browser = FALSE)
}

proc <- callr::r_bg(boot, args = list(pkg_root = normalizePath("."), port = PORT, log = LOG),
                    stderr = "|", stdout = "|")
for (i in 1:100) {
  if (!proc$is_alive()) { cat("DIED:\n", proc$read_all_error()); stop("died") }
  ok <- tryCatch({ con <- url(sprintf("http://127.0.0.1:%d", PORT)); suppressWarnings(readLines(con, n = 1)); close(con); TRUE }, error = function(e) FALSE)
  if (ok) break
  Sys.sleep(0.1)
}
cat("up\n")
b <- chromote::ChromoteSession$new()
b$Page$navigate(sprintf("http://127.0.0.1:%d", PORT))
b$Page$loadEventFired(wait_ = TRUE)
Sys.sleep(2.5)
cat("li:", b$Runtime$evaluate("document.querySelectorAll('li.todo').length")$result$value, "\n")
b$close()
cat("=== child stderr ===\n", proc$read_all_error(), "\n")
proc$kill()
cat("\n=== emission log ===\n")
if (file.exists(LOG)) { cat(readLines(LOG), sep = "\n"); file.remove(LOG) } else cat("NO LOG FILE\n")
