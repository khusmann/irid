## Submission

This is the first submission of 'irid' to CRAN.

## R CMD check results

0 errors | 0 warnings | 1 note

* checking CRAN incoming feasibility ... NOTE
  Maintainer: 'Kyle Husmann <khusmann@gmail.com>'
  New submission

  This is a new submission.

## Test environments

* Local: Ubuntu 20.04.2 LTS, R 4.2.2
* win-builder: R-devel and R-release  <!-- TODO: run devtools::check_win_devel() / check_win_release() and confirm before submitting -->
* macOS builder: macbuilder.r-project.org  <!-- TODO: run devtools::check_mac_release() and confirm before submitting -->

## Note on bundled JavaScript

The client runtime shipped in 'inst/js/irid.js' and the widget bundle under
'inst/widgets/' are compiled build artifacts produced with esbuild. Their
TypeScript source lives in the package's public repository under 'srcts/'
(https://github.com/khusmann/irid) and is not needed at install time; the
compiled bundles are vendored so that source and CRAN installs require no Node
toolchain. Build instructions are in the repository README.
