# Testing

The behavior spec lives in the test files themselves (`tests/testthat/`), each
named for the code it exercises and with descriptive `test_that()` labels. This
document is the **testing-infrastructure guide**: how the suite is organized, how
to run it, and how the browser (e2e) layer and coverage are wired.

## File layout and naming

**Unit tests** — one file per source module, named verbatim after it with an
optional `-<component>` suffix for sub-areas of a large module:

```
test-<source-file>[-<component>].R
```

The prefix matches the `R/` basename exactly, underscores included
(`process_tags.R` → `test-process_tags.R`, `mini_store.R` → `test-mini_store.R`).
The hyphen is the only separator that introduces a sub-area, e.g. `mount.R` is
split across `test-mount-sequence.R`, `test-mount-text.R`,
`test-mount-lifecycle.R`, and the control-flow primitives in `primitives.R` sit
together as `test-primitives-when.R` / `-each.R` / `-match.R` / `-output.R`.

Most unit tests need no browser: they drive the reactive machinery with
`shiny::MockShinySession` / `shiny::testServer`, capturing the `irid-*` custom
messages a mount would send (see `test-mount-sequence.R`,
`test-mount-lifecycle.R`, `test-app.R` for the pattern).

**End-to-end tests** — browser-driven round-trip tests live alongside the unit
tests and use the `chromote` + `callr` driver in `helper-e2e.R` (+
`helper-e2e-plt.R` for the PlotlyOutput layer).

- **Naming convention (load-bearing):** every e2e test file is
  `test-<area>-e2e.R` (e.g. `test-plotly-e2e.R`). CI selects them with
  `devtools::test(filter = "e2e")`, so a new browser suite is picked up
  automatically by following the suffix — no list to maintain.

## Running the tests

```r
devtools::test()                                  # all unit tests; e2e skipped
devtools::test(filter = "primitives-when")        # one unit suite
```

```sh
# e2e (boots headless Chrome via chromote)
IRID_E2E=1 Rscript -e 'devtools::test(filter = "plotly-e2e")'   # one suite
IRID_E2E=1 Rscript -e 'devtools::test(filter = "e2e")'          # all e2e
```

**Gating** (`skip_unless_e2e()`): e2e never runs on CRAN (`skip_on_cran()`);
otherwise it is opt-in via the `IRID_E2E=1` env var (env vars, not `options()`,
are the idiomatic test-gate mechanism). A bare `devtools::test()` skips e2e so it
doesn't boot Chrome.

**Waiting and flake-resistance.** Tests never sleep on a fixed interval — they
wait on the actual signal:

- `e2e_wait_until(app, js_bool)` polls a (page-guarded) JS condition;
  `e2e_wait_idle(app)` waits on irid's own `shiny:busy/idle` tracker.
- `e2e_poll(reader, pred)` — for conditions whose truth lives in R (e.g. app
  stderr via `e2e_expect_no_error`) or must round-trip through an R reader.
- `e2e_raf(app, n)` flushes `n` animation frames (a deterministic "let queued
  browser work finish"); `e2e_settle(sec)` is a raw sleep kept only as a last
  resort.

Every wait is **loud on timeout**: it aborts via `e2e_fail()`, which dumps the
page console, uncaught exceptions, and the app's stderr, and writes a screenshot
to `$E2E_ARTIFACTS` (falls back to `tempdir()`). A timeout reads as "waited for X
and it never came" instead of a baffling downstream assertion.

**Timeout budget.** Every wait routes its seconds through `e2e_timeout()`, scaled
by `E2E_TIMEOUT_SCALE` (default `1`). CI sets it to `3` to absorb a cold runner
without editing each call; generous ceilings don't slow the happy path because a
wait returns within one poll interval of its condition holding.

Tests that need a suggested package guard with `skip_if_not_installed()` (`DT`,
`plotly`, `bslib`, …). The shiny#4372 scoped-teardown tests in `test-scope.R`
guard on a runtime feature-detect (`shiny_has_scope()`) and skip on a shiny
without the PR (CRAN today); they start running automatically once a shiny
carrying it is installed.

## CI

Three workflows under `.github/workflows/`:

- **`R-CMD-check.yaml`** — the main check job; leaves `IRID_E2E` unset, so e2e
  skips and the unit tests run once here.
- **`e2e.yaml`** — a dedicated job that sets `IRID_E2E=1`, installs Chrome, and
  runs only the `*-e2e.R` files. Sets `E2E_TIMEOUT_SCALE=3` for runner headroom
  and uploads `$E2E_ARTIFACTS` (failure screenshots) on failure.
- **`test-coverage.yaml`** — runs `covr` and uploads to Codecov (the README
  badge). Like the check job it leaves `IRID_E2E` unset, so the reported number
  is R-side, unit-test coverage (it excludes the e2e suite and the gated
  shiny#4372 path, and can't see client JS).

## Coverage

```r
covr::report()                # interactive, per-line
covr::package_coverage()      # overall number
```

The honest ceiling for unit coverage is below 100% by design: defensive
`requireNamespace()` abort branches (only reachable when a Suggests package is
absent), the gated shiny#4372 path, render-time output bodies, and the
browser-effect dispatch in `mount.R` / the JS are intentionally left to e2e or
treated as unreachable in unit context. Chase meaningful branches, not the
number.

Client-side JavaScript (`inst/js/irid.js`, `inst/widgets/*/*.js`) is not visible
to `covr`; its pure decision logic is slated for `V8`-based unit tests (see
issue #30), with DOM/Shiny-glue behavior covered by the e2e suite.
