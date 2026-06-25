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

Tests that need a suggested package guard with `skip_if_not_installed()` (`DT`,
`plotly`, `bslib`, …). The shiny#4372 scoped-teardown tests in `test-scope.R`
guard on a runtime feature-detect (`shiny_has_scope()`) and skip on a shiny
without the PR (CRAN today); they start running automatically once a shiny
carrying it is installed.

## Client tests (TypeScript)

The client is TypeScript under `srcts/`, built to `inst/` with esbuild. Its pure
decision logic is unit-tested with **vitest**;
DOM / `Plotly.*` / Shiny-glue behavior stays in the R e2e suite (faithfully mocking
it is less trustworthy than a real browser).

```sh
cd srcts
corepack pnpm install         # first time (pnpm pinned via packageManager)
corepack pnpm test            # vitest unit tests
corepack pnpm run typecheck   # tsc --noEmit
corepack pnpm run coverage    # vitest + lcov
corepack pnpm run build       # rebuild the inst/ bundles
```

Unit-tested modules (tests in `srcts/src/__tests__/`): `core/seq` (the
sequence/stale-echo gate), `widgets/plotly/pure` (identity/diff helpers + the pure
half of each translation-table entry), and `core/ratelimit` (throttle/debounce +
the per-element ordering queue, with fake timers — the timing case the old V8 plan
couldn't reach).

**Built artifacts are committed.** `inst/js/irid.js` and
`inst/widgets/plotly/plotly-irid.js` (+ `.map`) are generated from `srcts/`. After
changing any `.ts`, run `pnpm run build` and commit the `inst/` changes — the
`client.yaml` CI job rebuilds and fails the run if they're stale.

## CI

Four workflows under `.github/workflows/`:

- **`R-CMD-check.yaml`** — the main check job; leaves `IRID_E2E` unset, so e2e
  skips and the unit tests run once here. Runs against the committed `inst/`
  bundles (no node needed).
- **`e2e.yaml`** — a dedicated job that sets `IRID_E2E=1`, installs Chrome, and
  runs only the `*-e2e.R` files (against the committed bundles).
- **`client.yaml`** — the TypeScript job: `pnpm` typecheck + vitest (with coverage)
  + esbuild build, then a `git diff` **freshness gate** that fails if the committed
  `inst/` bundles don't match a fresh build.
- **`test-coverage.yaml`** — runs `covr` and uploads to Codecov under the `r` flag
  (the README badge). Like the check job it leaves `IRID_E2E` unset, so the number
  is R-side unit-test coverage (it excludes the e2e suite and the gated shiny#4372
  path, and can't see the client). Client coverage uploads separately from
  `client.yaml` under the `client` flag.

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

The client (TypeScript under `srcts/`) is not visible to `covr`. Its pure decision
logic is unit-tested with vitest (see *Client tests* above) and reported to Codecov
under the `client` flag; DOM/Shiny-glue behavior is covered by the e2e suite.
