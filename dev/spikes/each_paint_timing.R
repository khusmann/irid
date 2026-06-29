# Browser spike: when (which animation frame) does each Each item actually land
# in the DOM? Boots a todo-shaped app, drives it with headless Chrome, and uses a
# MutationObserver tagged with a rAF frame counter to log every node insertion.
#
# If every <li> shares one frame  -> items appear all at once.
# If <li>s spread across frames   -> the "one-by-one" effect is real (multi-frame).
#
# Run: IRID_E2E=1 Rscript dev/spikes/each_paint_timing.R

library(callr)
library(chromote)

PORT <- 7799L
pkg_root <- normalizePath(".")

boot <- function(pkg_root, port) {
  pkgload::load_all(pkg_root, quiet = TRUE, helpers = FALSE, attach_testthat = FALSE)
  library(irid)
  App <- function() {
    todos <- shiny::reactiveVal(
      lapply(1:8, function(i) list(id = i, text = paste("Todo item number", i), done = FALSE))
    )
    irid::tags$ul(
      id = "todo-list",
      irid::Each(todos, by = function(t) t$id, function(todo) {
        irid::When(function() TRUE, function() irid::tags$li(
          class = "todo",
          irid::tags$input(type = "checkbox", checked = todo$done),
          irid::tags$span(function() todo$text()),
          irid::tags$button("x")
        ))
      })
    )
  }
  shiny::runApp(irid::iridApp(App), port = port, host = "127.0.0.1", launch.browser = FALSE)
}

cat("Booting app...\n")
proc <- callr::r_bg(boot, args = list(pkg_root = pkg_root, port = PORT))
# Wait for the port to answer.
for (i in 1:100) {
  if (!proc$is_alive()) { cat(proc$read_all_error()); stop("app died") }
  ok <- tryCatch({ con <- url(sprintf("http://127.0.0.1:%d", PORT)); suppressWarnings(readLines(con, n = 1)); close(con); TRUE },
                 error = function(e) FALSE)
  if (ok) break
  Sys.sleep(0.1)
}
cat("App up.\n")

instrument <- "
window.__frame = 0; window.__log = [];
(function loop(){ window.__frame++; requestAnimationFrame(loop); })();
var mo = new MutationObserver(function(muts){
  var t = Math.round(performance.now());
  muts.forEach(function(m){
    m.addedNodes.forEach(function(n){
      if (n.nodeType === 1)
        window.__log.push({f: window.__frame, t: t, tag: n.tagName, txt: (n.textContent||'').slice(0,24)});
      else if (n.nodeType === 3 && n.textContent.trim())
        window.__log.push({f: window.__frame, t: t, tag: '#text', txt: n.textContent.slice(0,24)});
    });
  });
});
document.addEventListener('DOMContentLoaded', function(){ mo.observe(document.body, {childList:true, subtree:true}); });
"

b <- ChromoteSession$new()
b$Page$addScriptToEvaluateOnNewDocument(source = instrument)
b$Page$navigate(sprintf("http://127.0.0.1:%d", PORT))
b$Page$loadEventFired(wait_ = TRUE)
Sys.sleep(2)  # let irid render + the reactive flushes land

log <- b$Runtime$evaluate("JSON.stringify(window.__log)")$result$value
parsed <- jsonlite::fromJSON(log, simplifyDataFrame = TRUE)
li <- parsed[parsed$tag %in% c("LI", "#text") | grepl("todo", parsed$txt, ignore.case = TRUE), ]
cat("\n--- node insertions (frame f, t ms, tag, text) ---\n")
print(parsed[, c("f", "t", "tag", "txt")], row.names = FALSE)

cat("\n--- summary ---\n")
li_rows <- parsed[parsed$tag == "LI", ]
txt_rows <- parsed[parsed$tag == "#text" & grepl("Todo item", parsed$txt), ]
cat(sprintf("LI elements: %d, spread across %d distinct frames: %s\n",
  nrow(li_rows), length(unique(li_rows$f)), paste(sort(unique(li_rows$f)), collapse=",")))
cat(sprintf("Text nodes:  %d, spread across %d distinct frames: %s\n",
  nrow(txt_rows), length(unique(txt_rows$f)), paste(sort(unique(txt_rows$f)), collapse=",")))

b$close()
proc$kill()
