nacre_dependency <- function() {
  htmltools::htmlDependency(
    name = "nacre",
    version = "0.0.1",
    src = system.file("js", package = "nacre"),
    script = "nacre.js"
  )
}
