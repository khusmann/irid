# Spike (#28 follow-on): does a widget's client→server channel survive a Shiny
# module's namespace?
#
# The widget send path (inst/js/irid.js) reconstructs the managed-stream key on
# the CLIENT as `irid_ev_${id}_${event}` and looks it up in `managed`. But the
# server registers that stream under `session$ns(input_id)` (R/mount.R:277). If
# `session$ns` is non-identity inside a module, the two strings differ and the
# client lookup misses -> widget events/props silently no-op in a module.
#
# DOM events are immune (they bind a closure over the stream object, no
# string round-trip), which is why modules "work" today for non-widget UI.
#
# This is pure server-side string composition, so no browser is needed: we only
# need to know what `session$ns(input_id)` yields vs. what the client rebuilds.
#
# Run:  Rscript dev/spikes/widget-module-ns.R
# Pinned: shiny 1.7.4 (re-confirm on bump).

library(shiny)

# Mirror the two key constructions, given a session + the widget's DOM id.
report <- function(label, session, widget_id, event = "relayout") {
  input_id    <- paste0("irid_ev_", widget_id, "_", event)  # R/mount.R input_id
  managed_key <- session$ns(input_id)                       # how the server registers it (msg.inputId)
  client_key  <- paste0("irid_ev_", widget_id, "_", event)  # how pushManaged() rebuilds it on the client
  cat(sprintf("\n[%s]\n", label))
  cat("  ns identity?       ", identical(session$ns("x"), "x"), "\n")
  cat("  managed key (srv): ", managed_key, "\n")
  cat("  client rebuild:    ", client_key, "\n")
  cat("  MATCH (works?):    ", identical(managed_key, client_key), "\n")
}

# --- real top-level app: the root namespace is EMPTY, so ns is identity ------
# A deployed app's root `session$ns` is `NS(NULL)`, which returns its argument
# unchanged. (testServer can't model this: it injects a fake "mock-session"
# namespace, so don't use testServer to judge the top-level case.)
cat("\n[real top-level app: NS(NULL)]\n")
cat("  ns identity?       ", identical(shiny::NS(NULL)("x"), "x"), "\n")
root_managed <- shiny::NS(NULL)("irid_ev_irid-1_relayout")
root_client  <- "irid_ev_irid-1_relayout"
cat("  managed key (srv): ", root_managed, "\n")
cat("  client rebuild:    ", root_client, "\n")
cat("  MATCH (works?):    ", identical(root_managed, root_client), "\n")

# --- inside a module: ns prepends the module id ------------------------------
# A widget rendered by renderIrid inside moduleServer mounts against the MODULE
# session (renderIrid uses getDefaultReactiveDomain()), so session$ns is the
# module's. The widget's DOM id is itself seeded from the (namespaced) output
# name, so we use a representative namespaced id here.
mod <- function(id) {
  moduleServer(id, function(input, output, session) {
    report("inside module 'counter1'", session, widget_id = "counter1-display-1")
  })
}
testServer(mod, args = list(id = "counter1"), expr = {})

cat("\nVERDICT: MATCH is TRUE at the real top level (root ns is identity) but",
    "FALSE inside a module (session$ns adds a prefix the client rebuild omits),",
    "so widget events/props are broken in modules today.\n")
