# Spike: confirm how the redesigned protocol message shapes cross the wire.
#
# Throwaway / build-ignored. Run with:  Rscript dev/spikes/protocol-serialization.R
#
# WHY: the protocol-types redesign (dev/protocol-types.md) bets on several
# jsonlite + Shiny serialization behaviors. For server->client custom messages the
# client receives JSON.parse() of exactly what Shiny's toJSON emits, so printing
# that JSON *is* the client-side shape. `session$sendCustomMessage(type, msg)` runs
# `msg` through `shiny:::toJSON`, so we call it directly here for fidelity.
#
# PINNED: shiny 1.7.4, jsonlite 2.0.0. Re-confirm on bump.
#
# The bets, most load-bearing first:
#   1. Required booleans survive — especially FALSE (producer-owns-defaults).
#   2. NULL in a list() constructor is KEPT as `null` (NOT dropped) — so the encoder
#      must actively OMIT semantic-absence fields; they're `null` on the wire today.
#   3. Present-but-empty ([]/{}/"") survives and is distinct from absent — but the
#      []-vs-{} choice is keyed off list NAMES, so the encoder must build the right type.
#   4. The empty-text wire shape — justifies the "R must normalize empty -> ''" fix.
#   5. Array-forcing — a length-1 array field must not unbox to a scalar.
#   6. New nests (gate / timing / domOpts / valueGates) round-trip as objects.
#
# Together (2,3): the encoder must keep three states distinct that the naive
# list()/jsonlite path conflates — absent (omit key) / present-empty ([]/{}/"") / null
# (never on the wire).

stopifnot(packageVersion("shiny") == "1.7.4")
toJSON <- shiny:::toJSON  # the exact custom-message serializer

pass <- 0L; fail <- 0L
check <- function(label, json, ok) {
  verdict <- if (ok) { pass <<- pass + 1L; "PASS" } else { fail <<- fail + 1L; "FAIL" }
  cat(sprintf("  [%s] %s\n", verdict, label))
}
section <- function(n, title) cat(sprintf("\n=== %d. %s ===\n", n, title))
show <- function(label, x) {
  j <- as.character(toJSON(x))
  cat(sprintf("  %-22s -> %s\n", label, j))
  j
}

# --------------------------------------------------------------------------
section(1, "Required booleans survive (esp. FALSE)")
# An IridDomEvent built the *new* way: nested timing/domOpts, concrete booleans.
dom_event <- list(
  id = "irid-3", event = "input", channel = "irid_ev_irid-3_input",
  source = "dom",
  timing = list(mode = "debounce", ms = 200L),
  coalesce = FALSE,
  domOpts = list(preventDefault = FALSE, stopPropagation = FALSE,
                 capture = FALSE, passive = FALSE),
  clientOnly = FALSE
)
j <- show("dom event (all false)", dom_event)
check("coalesce present as scalar false", j, grepl('"coalesce":false', j, fixed = TRUE))
check("domOpts nested object of false", j,
      grepl('"domOpts":{"preventDefault":false,"stopPropagation":false,"capture":false,"passive":false}', j, fixed = TRUE))
check("clientOnly present as false", j, grepl('"clientOnly":false', j, fixed = TRUE))
check("timing nested w/ ms (debounce)", j, grepl('"timing":{"mode":"debounce","ms":200}', j, fixed = TRUE))

# immediate + coalesce=TRUE must be representable (orthogonality decision).
imm <- list(id = "irid-4", event = "click", channel = "irid_ev_irid-4_click",
            source = "dom", timing = list(mode = "immediate"), coalesce = TRUE,
            domOpts = list(preventDefault = TRUE, stopPropagation = FALSE,
                           capture = FALSE, passive = FALSE),
            clientOnly = FALSE)
j <- show("immediate + coalesce", imm)
check("immediate timing has no ms/leading", j, grepl('"timing":{"mode":"immediate"}', j, fixed = TRUE))
check("immediate co-exists w/ coalesce:true", j, grepl('"coalesce":true', j, fixed = TRUE))

# throttle carries ms + leading.
thr <- list(timing = list(mode = "throttle", ms = 100L, leading = TRUE))
j <- show("throttle timing", thr)
check("throttle has ms + leading", j, grepl('"timing":{"mode":"throttle","ms":100,"leading":true}', j, fixed = TRUE))

# --------------------------------------------------------------------------
section(2, "NULL in a list() constructor is KEPT as null (NOT dropped)")
# The drop-on-NULL rule is for `x[[k]] <- NULL` (assignment). The event message is
# built with a single list(...) constructor, which KEEPS NULL elements -> jsonlite
# emits them as `null`. So `filter`/`kind`/`ms`/`leading`/ready-`id` are `null` on
# the wire today, NOT absent. Only the incrementally-assigned fields (gate, valueGates)
# are genuinely omitted. The encoder must actively OMIT semantic-absence fields.
j <- show("list(filter=NULL, kind=NULL)", list(filter = NULL, kind = NULL))
check("constructor keeps NULL as `null` (not dropped)", j,
      grepl('"filter":null', j, fixed = TRUE) && grepl('"kind":null', j, fixed = TRUE))
cat("  incremental drop: ",
    { x <- list(a = 1); x[["b"]] <- NULL; sprintf("x[[\"b\"]]<-NULL => length %d", length(x)) },
    "\n", sep = "")
check("ready list(id=NULL) is {\"id\":null}, not {}", as.character(toJSON(list(id = NULL))),
      grepl('"id":null', as.character(toJSON(list(id = NULL))), fixed = TRUE))

# --------------------------------------------------------------------------
section(3, "Present-but-empty survives (and is distinct from absent)")
# Three states the encoder must keep distinct: absent (omit key), present-empty
# ([]/{}/""), null (not used on the wire). jsonlite picks []-vs-{} off NAMES:
# unnamed empty list -> [], named empty list -> {}. So the encoder must build an
# empty ARRAY field as an unnamed list and an empty MAP field as a named list.
j_arr <- show("empty array  list(removes=character(0))", list(removes = character(0)))
j_map <- show("empty map    setNames(list(),char(0))", list(values = setNames(list(), character(0))))
check("empty array -> [] (unnamed list)", j_arr, grepl('"removes":[]', j_arr, fixed = TRUE))
check("empty map -> {} (named list)", j_map, grepl('"values":{}', j_map, fixed = TRUE))
check("present-empty `[]` is distinct from absent (key present)",
      as.character(toJSON(list(a = 1, removes = list()))),
      grepl('"removes":[]', as.character(toJSON(list(a = 1, removes = list()))), fixed = TRUE))

# --------------------------------------------------------------------------
section(4, "Empty-text wire shape (drives the normalize -> '' fix)")
# What does coerce_text_child's as.character() actually put on the wire?
cat("  coerce_text_child(NULL) == ", deparse(as.character(NULL)), "\n", sep = "")
text_cases <- list(
  "NULL/character(0)" = as.character(NULL),
  "NA"               = NA_character_,
  "empty"            = "",
  "number"           = as.character(42))
for (nm in names(text_cases)) {
  show(sprintf("value = %s", nm),
       list(id = "irid-5", target = "text", value = text_cases[[nm]]))
}
j_null <- as.character(toJSON(list(value = as.character(NULL))))
j_na   <- as.character(toJSON(list(value = NA_character_)))
check("NULL/character(0) does NOT serialize as a string", j_null,
      !grepl('"value":""', j_null, fixed = TRUE))   # expected: "value":[] (the wart)
check("NA serializes as null (not a string)", j_na, grepl('"value":null', j_na, fixed = TRUE))
cat("  => empty/NA are NOT '' on the wire; R must normalize so value: string holds.\n")
# The post-fix target shape:
invisible(show("value = '' (post-fix)", list(id = "irid-5", target = "text", value = "")))

# --------------------------------------------------------------------------
section(5, "__irid_state_keys array-forcing")
j_scalar <- show("c('xaxis_range')   (bug)", list(`__irid_state_keys` = c("xaxis_range")))
j_I      <- show("I(c('xaxis_range')) (fix)", list(`__irid_state_keys` = I(c("xaxis_range"))))
j_aslist <- show("as.list(c('x'))     (fix)", list(`__irid_state_keys` = as.list(c("xaxis_range"))))
j_two    <- show("c('a','b')          (ok)", list(`__irid_state_keys` = c("a", "b")))
check("length-1 unboxes to scalar (the bug)", j_scalar,
      grepl('"__irid_state_keys":"xaxis_range"', j_scalar, fixed = TRUE))
check("I() forces a 1-element array", j_I,
      grepl('"__irid_state_keys":["xaxis_range"]', j_I, fixed = TRUE))
check("length-2 is already an array", j_two,
      grepl('"__irid_state_keys":["a","b"]', j_two, fixed = TRUE))

# --------------------------------------------------------------------------
section(6, "New nests round-trip as objects")
attr_dom <- list(id = "irid-3", target = "dom", attr = "value", value = "hello",
                 gate = list(seq = 12L, channel = "irid_ev_irid-3_input"))
j <- show("irid-attr dom + gate", attr_dom)
check("gate is a nested object", j,
      grepl('"gate":{"seq":12,"channel":"irid_ev_irid-3_input"}', j, fixed = TRUE))

attr_widget <- list(id = "irid-7", target = "widget",
                    values = list(content = "x", cursor = list(line = 1L, ch = 2L)),
                    valueGates = list(content = list(seq = 5L, channel = "irid_prop_irid-7_content")))
j <- show("irid-attr widget + valueGates", attr_widget)
check("values is a nested object", j, grepl('"values":{"content":"x"', j, fixed = TRUE))
check("valueGates is a per-key object map", j,
      grepl('"valueGates":{"content":{"seq":5,"channel":"irid_prop_irid-7_content"}}', j, fixed = TRUE))

# programmatic widget batch: valueGates omitted entirely.
prog <- list(id = "irid-7", target = "widget", values = list(content = "x"))
j <- show("programmatic widget (no gate)", prog)
check("omitted valueGates => no key on the wire", j, !grepl("valueGates", j, fixed = TRUE))

# --------------------------------------------------------------------------
cat(sprintf("\n--- %d passed, %d failed ---\n", pass, fail))
if (fail > 0L) quit(status = 1L)
