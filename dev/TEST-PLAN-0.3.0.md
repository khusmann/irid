# Test hardening plan — 0.3.0 CRAN release

Status of this doc: **proposal, pending approval.** Implementation happens on
this branch (`test-hardening-0.3.0`) once the plan is signed off.

Target: cut `irid` 0.3.0 to CRAN with a test suite we trust. Today the suite is
solid where it exists but has a few load-bearing blind spots, and the plan
doc (`TESTING.md`) has drifted from the code. This document records the current
state, the gaps, and a prioritized path to close them.

## 1. Where we are today

R-side line coverage (covr, `type = "tests"`, e2e suite excluded):

| File             | Coverage | Notes                                              |
| ---------------- | -------- | -------------------------------------------------- |
| `app.R`          | **0%**   | `iridApp` / `iridOutput` / `renderIrid` / `irid_send_config` — entry points, only ever touched by e2e |
| `plotly.R`       | 68%      | coercion + state-prop helpers; rest is e2e-only    |
| `scope.R`        | 71%      | shiny#4372 seam; fallback path tested, #4372 path not |
| `primitives.R`   | 73%      | `When` lifecycle largely untested (see below)       |
| `mount.R`        | 81%      | biggest/most complex file; `$destroy()` propagation thin |
| `event.R`        | 93%      |                                                    |
| `process_tags.R` | 93%      |                                                    |
| `mini_store.R`   | 98%      |                                                    |
| `store.R`        | 98%      | best-covered area                                  |
| `checks.R`       | 100%     |                                                    |
| `proxy.R`        | 100%     |                                                    |
| `widget.R`       | 100%     |                                                    |
| **Overall**      | **84.9%** | R only; excludes all client JS                    |

What this number hides:

- **The whole client is invisible to covr.** `inst/js/irid.js` (~900 lines) and
  `inst/widgets/plotly/plotly-irid.js` (~430 lines) carry a large share of the
  behavior described in `TESTING.md` — `irid-attr`/`-swap`/`-mutate` dispatch,
  the comment-anchor registry, optimistic-update echo gating, the stale
  indicator, the per-element ordering queue, payload construction. None of it is
  unit-tested; it is only exercised, partially, by 5 e2e files
  (`*-e2e.R`), which are themselves skipped on CRAN and off by default locally.
- **84.9% is the e2e-excluded number.** app.R and the plotly client paths look
  worse than they are in practice because their real coverage lives in e2e.

## 2. `TESTING.md` is stale — and we retire it, not rebuild it

`TESTING.md` predates several design changes and now describes primitives and
shapes that no longer exist. The drift is the symptom, not the disease: a
hand-maintained prose checklist that mirrors the test suite has no compiler and
nothing that runs it, so it *will* drift again. Once the behaviors are encoded as
tests with descriptive `test_that()` names, **the test files are the source of
truth** and the checklist is pure maintenance debt.

So the decision for 0.3.0 is: **do not rebuild the behavior checklist.** Treat it
as a throwaway tracker during the hardening (or just track against §3–§4 of this
doc and the test files, which overlap), then at the end **slim `TESTING.md` down
to a testing-*infrastructure* guide** and delete the exhaustive checklist:

- **Keep** the durable infra content (today's lines ~469–488): the e2e naming
  convention (`test-<area>-e2e.R`), `skip_unless_e2e()` gating, the `IRID_E2E`
  env var, the CI job split, how to run e2e locally — plus JS-harness run
  instructions if §4 Option A lands. None of this lives in any test file, and
  `CLAUDE.md` points here for orientation.
- **Delete** the behavior checklist (today's lines ~1–468). The test suite
  replaces it.

This also removes the busywork of reconciling every stale checkbox — we only
touch the lines we're keeping. The confirmed drift below is recorded so the
*tests* we write target the shipped API, not so we fix it in place:

- **`Index` is not a primitive.** It is gone from the code (no export, nothing in
  `primitives.R`; remaining "Index" hits in the source are the English word).
  Positional `Each` (`by = NULL`) absorbed it. `TESTING.md` still has a full
  `Index` lifecycle section and ~9 references across the doc — all stale.
- **Reactive text child is not a `<span>`.** `TESTING.md` line 21 says the child
  "becomes a `<span>` binding with `attr = "textContent"`." The code now emits a
  comment-anchor pair with `target = "text"` (no `attr`), validated at mount by
  `coerce_text_child` — so it works inside restricted-content parents. The newer
  lines (22–23) already describe the correct behavior; the old `<span>` line
  contradicts them and must go.
- **`index_rv` naming.** `TESTING.md` refers to `index_rv`; the code/architecture
  use the `pos` / `pos_rv` accessor. (Recorded for the `Each` tests, not for a
  doc rename — the section is being deleted.)

## 3. R-side gaps (priority order)

### P0 — `app.R` entry points (0% → covered)

No new file exists for this. Add `test-app.R`:

- `iridApp(fn)` calls `fn()` twice (UI + server pass) with a shared counter so
  element IDs line up between static HTML and reactive wiring. Assert ID parity.
- `irid_send_config` is invoked synchronously in the server function; sends the
  `irid-config` message with `getOption("irid.stale_timeout")`.
- `iridOutput(id)` attaches the irid JS/CSS dependency.
- `renderIrid`: processes the tree and mounts after flush; uses `isolate()` so
  the UI expression doesn't take a reactive dependency; reactive invalidation
  re-renders; config sent in the `onFlushed` callback.

Drive these with `shiny::testServer()` / `shiny::MockShinySession` where
possible so they run as plain unit tests (no browser), matching how
`test-mount-sequence.R` already mocks a session.

### P1 — `When` lifecycle (`primitives.R` 73%)

There is no `test-when.R`; `When` is only used incidentally as a fixture
elsewhere. `TESTING.md` lists the full `When` contract but none of it is
asserted. Add `test-when.R` covering:

- renders `yes` on `TRUE`, `otherwise` on `FALSE`, nothing on `FALSE` with no
  `otherwise`;
- short-circuit: re-evaluating with the same condition does not destroy/recreate
  the child mount (the property that protects inner `Each` state);
- switching branches destroys the previous mount and creates a new one;
- inner reactive state survives a condition re-eval that stays the same.

Mirror the mount/destroy assertion style in `test-each.R` / `test-match.R`.

### P2 — mount `$destroy()` propagation (`mount.R` 81%)

`TESTING.md`'s "Destroy / cleanup" section is only partially exercised. Add a
`test-mount-lifecycle.R` (or extend the relevant files) for:

- `$destroy()` tears down all observers;
- When/Match: destroying the mount destroys the active branch's child mount;
- Each: destroying destroys all per-item child mounts;
- nested control flows: destroy propagates recursively.

### P3 — `scope.R` #4372 path (71%)

The fallback (pre-#4372) path is tested; the feature-detected #4372 branch is
not, because CRAN shiny doesn't carry the PR. Decide one of:

- gate a test on a feature-detect (`skip_if` shiny lacks `makeScope` child
  teardown) so it runs on a dev shiny and skips on CRAN; or
- accept the fallback-only coverage for 0.3.0 and note the #4372 path as
  e2e/manual until shiny ships it.

Recommend the first — a cheap `skip_if`-gated test keeps the seam honest as
shiny evolves. Tag it `# shiny#4372:` like the code sites.

### P4 — `plotly.R` non-e2e helpers (68%)

`coerce_plotly_value` / `coerce_state_prop` / `to_plotly_spec` and the
name-validation paths are pure R and should be unit-tested directly (wire-shape
coercion: `list(40, 200)` → numeric range, `NA` → `NULL`, date-axis stays
character, the `force()` capture-loop fix). This lifts plotly.R coverage without
needing the browser.

## 4. Client-side (JS) — the real blind spot (tracked in #30)

This is the largest gap and the biggest CRAN-confidence risk: the fragile logic
in `irid.js` / `plotly-irid.js` is exercised **only** by the browser e2e suite,
which runs in a separate, browser-gated CI job — a regression in the
diffing/sequencing logic lands green if that job flakes or is skipped.
[Issue #30](https://github.com/khusmann/irid/issues/30) already scopes this work;
it supersedes the vitest-vs-e2e framing an earlier draft of this plan used.

**Mechanism: the `V8` R package** (`Suggests: V8`), *not* a node/vitest
toolchain. Tests `ct$source()` the helper file and call the pure functions
directly, asserting from R — so they stay in testthat, under one
`devtools::test()` and one CI job, consistent with the project's no-JS-build-step
principle. (The one place node + fake timers would beat V8 is throttle/debounce
*timing*; leave that to e2e unless we decide it's worth covering.)

**Discipline — audit before extracting (#30 step 0).** For each candidate,
confirm it's a real gap first: which `test-plotly-e2e.R` rows already drive the
helper end-to-end, and whether a pure-R twin is already tested. Only extract +
unit-test where coverage is thin **and** the logic is bug-prone. The
sequence/stale-echo gate has no R counterpart and is the clearest genuine gap.

**Refactor cost.** The pure helpers are module-scoped inside IIFE/factory
closures and currently unreachable. The work is extracting them into a
separately-loadable unit on a shared namespace (browser loads it as an extra
script dep; V8 `source()`s the same file) — a second script dep + namespace seam.
Prototype the seam on one helper (e.g. `idsToIndices`) to derisk before
committing.

**In scope — unit-test (pure, operate on plain objects):**

- core: the **stale-echo / sequence gate** (`shouldSkip` + `markStale` /
  `clearStale` / `onEventSent`) — the subtlety behind the `TODO(#28)`
  notify-first ordering constraint; pinning it makes the #28 rework safer.
- plotly: `approxEq`, `idsToIndices`, `idsFromPoints`, `readVisibility`,
  `typedVisibility` / `stringVisibility`, and each translation-table entry's
  `fromRelayout` / `matchesCurrent` / `writeSpec`.

**Out of scope — leave to e2e** (DOM / `Plotly.*` / Shiny glue; mocking
faithfully is more work and less trustworthy than a real browser): anchor
registry (`indexAnchors` / `lookupAnchors`), `parseFragment` / `detachRange`,
`mountWidget` / `destroyWidgetsIn`, Shiny input plumbing; plotly `apply` /
`applyDeferred` / `render` / `attachListeners` / `destroy`.

**Plus a few targeted e2e** for genuinely integration-shaped behaviors not yet
covered: stale-indicator show/hide timing, optimistic-echo under latency,
comment-anchor edge cases in `<select>` / `<tbody>`.

Deliverables (from #30): coverage audit → V8 seam prototype on one helper →
unit tests for the in-scope plotly helpers → unit tests for the core
sequence/stale-echo gate.

## 5. CRAN-readiness checklist (non-coverage)

- `R CMD check` clean (no NOTES/WARNINGs) with e2e skipped — confirm the default
  `devtools::test()` never boots Chrome (`skip_unless_e2e()` already gates this;
  verify after additions).
- Every new test that needs a Suggests pkg (`DT`, `plotly`, `bslib`, `V8`, …)
  guards with `skip_if_not_installed()`. Add `V8` to `Suggests` if §4 lands.
- e2e files keep the `test-<area>-e2e.R` suffix so CI's `filter = "e2e"` picks
  them up with no list to maintain.
- Re-run covr after each phase; record the new overall number in `NEWS.md` under
  the 0.3.0 entry. Set a release gate (proposal: **≥90% R-side**, app.R and
  `When` no longer near-zero).
- Bump `DESCRIPTION` `0.2.0.9000` → `0.3.0` as part of the release commit (not in
  this hardening work).

## 6. Sequencing

1. P0 `test-app.R` (§3) — biggest coverage hole, pure R.
2. P1 `test-when.R` + P2 mount `$destroy()` (§3).
3. P4 plotly pure-R helpers (§3).
4. §4 / #30: V8 seam prototype → in-scope JS unit tests + targeted e2e.
5. P3 scope #4372 `skip_if` test (§3).
6. **Retire `TESTING.md`** (§2): delete the behavior checklist, keep/slim the
   infra guide, add JS-harness run notes if §4 Option A landed.
7. covr re-run, NEWS entry, version bump → release.

Each numbered step is one commit (per the project's "one concept per commit"
rule). Steps 1–3 and 5 are independent and can land in any order; step 6 comes
last so the retired doc reflects the final test layout.

## Open decisions (need sign-off before impl)

- **§3 P3**: gate a #4372 test with `skip_if`, or defer to e2e/manual for 0.3.0.
- **Coverage gate** (§5): is ≥90% R-side the right bar for the release?

(§4's mechanism is settled — `V8`, per #30 — so it's no longer an open question.)
