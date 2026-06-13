# Throwaway spike: does the IridWidget substrate's JSON encoder preserve
# plotly's fidelity-critical encoding, or must we pre-serialize with plotly's
# own to_JSON and ship the spec as a string prop?
#
# Run: Rscript dev/spikes/plotly-serialize-spike.R

suppressMessages(library(plotly))
tj <- getFromNamespace("to_JSON", "plotly")

# Fidelity-sensitive spec: Date axis, factor-driven color split into 2 traces.
df <- data.frame(
  d = as.Date("2020-01-01") + 0:3,
  y = c(1, 2, 3, 4),
  g = factor(c("a", "b", "a", "b"))
)
b <- plotly_build(
  plot_ly(df, x = ~d, y = ~y, color = ~g, type = "scatter", mode = "markers")
)
spec <- list(data = b$x$data, layout = b$x$layout, config = b$x$config)

plotly_json <- tj(spec)                                              # correct
shiny_json  <- jsonlite::toJSON(spec, auto_unbox = TRUE, null = "null", na = "null")

xkey <- function(s) regmatches(s, regexpr('"x":\\[[^]]*\\]', s, perl = TRUE))[1]

cat("Q1. Does plotly to_JSON differ from the substrate's default encoder?\n")
cat("  plotly :", xkey(plotly_json), "\n")
cat("  shiny  :", xkey(shiny_json), "\n")
cat("  identical full output:", identical(plotly_json, shiny_json), "\n\n")

cat("Q2. Does shipping the plotly JSON as a STRING prop round-trip?\n")
# Substrate encodes the string value; client JSON.parses it back.
wire   <- jsonlite::toJSON(list(spec = unclass(plotly_json)), auto_unbox = TRUE)
inner  <- jsonlite::fromJSON(wire, simplifyVector = FALSE)$spec   # what JS receives as props.spec
parsed <- jsonlite::fromJSON(inner, simplifyVector = FALSE)        # JSON.parse(props.spec)
cat("  recovered string == original to_JSON:", identical(inner, unclass(plotly_json)), "\n")
cat("  recovered trace1 x:", paste(unlist(parsed$data[[1]]$x), collapse = ", "), "\n")
cat("  trace count:", length(parsed$data), "\n\n")

cat("Q3. Bundled plotly.js version (spike doc cites 2.35.2):\n")
deps <- b$dependencies
pm <- Filter(function(d) d$name == "plotly-main", deps)[[1]]
cat("  plotly-main:", pm$version, "\n")

cat("\nQ4. The auto_unbox trap: a single-point trace + float precision.\n")
b1 <- plotly_build(plot_ly(x = 3.14159265358979, y = 1/3, type = "scatter", mode = "markers"))
spec1 <- list(data = b1$x$data, layout = b1$x$layout)
pj <- getFromNamespace("to_JSON", "plotly")(spec1)
sj <- jsonlite::toJSON(spec1, auto_unbox = TRUE, null = "null", na = "null")
xk <- function(s) regmatches(s, regexpr('"x":[^,}]*', s, perl = TRUE))[1]
yk <- function(s) regmatches(s, regexpr('"y":[^,}]*', s, perl = TRUE))[1]
cat("  plotly x:", xk(pj), " y:", yk(pj), "\n")
cat("  shiny  x:", xk(sj), " y:", yk(sj), "\n")
cat("  identical:", identical(pj, sj), "\n")

cat("\nQ5. CORRECTION — use the substrate's ACTUAL encoder (shiny:::toJSON),\n")
cat("   not raw jsonlite defaults. Shiny sets digits=16, use_signif=TRUE.\n")
sj_fn <- getFromNamespace("toJSON", "shiny")
real <- sj_fn(spec1)
xk2 <- function(s) regmatches(s, regexpr('"x":[^,}]*', s, perl = TRUE))[1]
yk2 <- function(s) regmatches(s, regexpr('"y":[^,}]*', s, perl = TRUE))[1]
cat("  shiny:::toJSON x:", xk2(real), " y:", yk2(real), "\n")
cat("  -> precision preserved; Q4's truncation was a raw-jsonlite artifact.\n")
cat("  Conclusion: ship spec as a STRING (plotly::to_JSON) anyway, to DECOUPLE\n")
cat("  fidelity from Shiny's JSON option defaults and match {plotly} exactly.\n")
