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

## 2. `TESTING.md` is stale (fix before adding tests)

`TESTING.md` predates several design changes and now describes primitives and
shapes that no longer exist. It must be reconciled with the code first —
otherwise we'd write tests against a fictional API. Confirmed drift:

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
  use the `pos` / `pos_rv` accessor. Rename in the doc.

Action: rewrite `TESTING.md` so the checklist matches the shipped API, fold the
`Index` checks into the `Each` positional section, and **add checkbox state** —
the current doc is a flat list with nothing marked done, so it can't tell us
what's covered. The reorganized doc becomes the source of truth we tick off as
we close the gaps in §3–§4.

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

## 4. Client-side (JS) — the real blind spot

This is the largest gap and the biggest CRAN-confidence risk. Two viable paths;
**pick one before implementation** (see Decision below):

**Option A — JS unit tests (new tooling).** Add a minimal `package.json` +
vitest/jsdom harness under a build-ignored dir, factor the pure logic out of
`irid.js` (echo-gate decision, payload construction, anchor walk, ordering-queue
`drainQueue`) into testable units. Highest-value targets, all currently
untested except via e2e:

- echo gating: stale / current-same-value / server-transform / programmatic;
  per-channel sequence; widget `value_meta` per-key gate.
- `irid-attr` property-vs-attribute dispatch; `false`/`null` → `removeAttribute`.
- comment-anchor registry: populate, lookup-miss rescan, register/deregister on
  insert/remove, reorder preserves entries.
- per-element ordering queue: preemptive flush, drop-empty-slot, ordering beats
  backpressure, per-element isolation.
- payload construction: string/number/boolean fields, `valueAsNumber`,
  swallowed property-access errors.

Cost: introduces a JS toolchain and `.Rbuildignore` entries; must stay out of
the built package so CRAN never sees Node.

**Option B — lean on e2e, broaden it.** Keep zero JS tooling; add e2e cases for
the highest-risk client behaviors not yet covered (stale-indicator show/hide
timing, optimistic-update echo under latency, comment-anchor edge cases in
`<select>`/`<tbody>`). Cheaper to set up, but slower, browser-bound, CRAN-skipped,
and weaker at pinning down pure-logic branches.

Recommendation: **A for the pure-logic cores** (echo gate, ordering queue,
anchor walk, payload builder — they're deterministic and cheap to unit test),
**plus a few targeted B cases** for the genuinely integration-shaped behaviors
(stale indicator timing, restricted-parent parsing). This is where most
remaining `TESTING.md` checkboxes live.

## 5. CRAN-readiness checklist (non-coverage)

- `R CMD check` clean (no NOTES/WARNINGs) with e2e skipped — confirm the default
  `devtools::test()` never boots Chrome (`skip_unless_e2e()` already gates this;
  verify after additions).
- Every new test that needs a Suggests pkg (`DT`, `plotly`, `bslib`, …) guards
  with `skip_if_not_installed()`.
- e2e files keep the `test-<area>-e2e.R` suffix so CI's `filter = "e2e"` picks
  them up with no list to maintain.
- Re-run covr after each phase; record the new overall number in `NEWS.md` under
  the 0.3.0 entry. Set a release gate (proposal: **≥90% R-side**, app.R and
  `When` no longer near-zero).
- Bump `DESCRIPTION` `0.2.0.9000` → `0.3.0` as part of the release commit (not in
  this hardening work).

## 6. Sequencing

1. Reconcile `TESTING.md` with the code (§2) + add checkbox state. *(doc-only)*
2. P0 `test-app.R` (§3) — biggest coverage hole, pure R.
3. P1 `test-when.R` + P2 mount `$destroy()` (§3).
4. P4 plotly pure-R helpers (§3).
5. Decide §4 path; implement JS unit cores (A) and/or targeted e2e (B).
6. P3 scope #4372 `skip_if` test (§3).
7. covr re-run, NEWS entry, version bump → release.

Each numbered step is one commit (per the project's "one concept per commit"
rule). Steps 2–4 and 6 are independent and can land in any order.

## Open decisions (need sign-off before impl)

- **§4 path**: A (JS tooling) vs B (e2e-only) vs the recommended hybrid.
- **§3 P3**: gate a #4372 test with `skip_if`, or defer to e2e/manual for 0.3.0.
- **Coverage gate** (§5): is ≥90% R-side the right bar for the release?
