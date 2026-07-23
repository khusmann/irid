## Resubmission

This is a resubmission. In response to CRAN feedback, I have added a `\value`
section to `reactiveVal.Rd` (the shared documentation page for the re-exported
shiny primitives), describing the return value of each documented function.

## Submission

This is the first submission of 'irid' to CRAN.

## R CMD check results

0 errors | 0 warnings | 1 note

* checking CRAN incoming feasibility ... NOTE
  Maintainer: 'Kyle Husmann <irid@kylehusmann.com>'
  New submission

  This is a new submission.

  The check also flags "Possibly misspelled words in DESCRIPTION: DOM, UI".
  These are standard technical acronyms (Document Object Model; user
  interface), not misspellings.

## Test environments

* Local: Ubuntu 20.04.2 LTS, R 4.2.2
* win-builder: R-devel and R-release (https://win-builder.r-project.org/)

## Note on bundled JavaScript

The client runtime shipped in 'inst/js/irid.js' and the widget bundle under
'inst/widgets/' are compiled build artifacts produced with esbuild. Their
TypeScript source lives in the package's public repository under 'srcts/'
(https://github.com/khusmann/irid) and is not needed at install time; the
compiled bundles are vendored so that source and CRAN installs require no Node
toolchain. Build instructions are in the repository README.
