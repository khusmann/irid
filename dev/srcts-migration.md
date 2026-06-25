# Design: TypeScript client (`srcts/`) with a vendored build artifact

## Status

**Implemented** on the `srcts-migration` branch (Phases 1–7 below). Supersedes the
V8-based approach in **#30** (unit-testing the pure JS decision logic): once the
client is TypeScript with a native test runner, the V8 harness is the thing we'd
throw away, so #30 is folded into this work rather than done first — close #30 as
superseded when the PR merges. See *Relationship to #30* below.

## Why

The irid client (`inst/js/irid.js`, `inst/widgets/plotly/plotly-irid.js`) is
server-language-agnostic: it speaks a JSON wire protocol over Shiny's custom-message
transport, and the JS-side `Shiny` object is identical under Shiny-for-R and
Shiny-for-Python. The near-term goal is a **Python server package alongside the R
one**, both driving the *same* client. That makes the client a shared artifact,
which changes the calculus that originally chose "no JS build step":

1. **A typed wire-protocol contract is the prize.** The message shapes
   (`irid-attr`, `irid-events`, the sequence/channel gating, `value_meta`, the
   widget batch shape, …) currently live only in `ARCHITECTURE.md` prose and are
   enforced nowhere. With two server implementations that must agree on the wire,
   a single `protocol.ts` becomes the source of truth both servers target.
2. **Native testing.** vitest tests the pure decision logic *and* the
   throttle/debounce/coalesce timing logic (with fake timers) — the latter is the
   one area #30 explicitly punted on because V8 can't drive it.
3. **One source, two consumers.** The built client is vendored into both the R
   and Python packages, eliminating a second hand-maintained copy.

This is exactly the pattern Posit uses one layer down: `rstudio/shiny` keeps its
client in TypeScript (`srcts/`), builds to `inst/www/shared/shiny.min.js`, and
`py-shiny` vendors the built assets. We mirror it.

## The cost we are accepting

We give up the "edit `inst/js/irid.js` and it ships" simplicity. In its place:

- a node toolchain for contributors who touch the client,
- a build + vendor pipeline,
- **committed build artifacts** (so the R package installs without node) plus a CI
  freshness check.

This is justified by the multi-server goal, not by testing alone — V8 (#30) would
have gotten us testing without the build step. The trigger is the Python port being
a real near-term goal.

## Toolchain

- **TypeScript** — source language.
- **esbuild** — bundle each entry point to a browser-ready **IIFE** file, `target:
  es2019` (a sane modern-browser baseline). One fast dependency, trivial config.
  (Rejected: webpack/rollup — heavier for no gain here; tsc-only per-file emit —
  keeps a global-script model that makes real modules and vitest awkward, and module
  sharing is the whole point; tsup — an esbuild wrapper that saves ~15 lines of
  config but adds an abstraction/dep for two entries; Vite lib mode — oriented at
  npm ESM/CJS packages, awkward for a browser IIFE.)
- **`tsc --noEmit`** — the **typecheck**. esbuild only strips types and transpiles —
  it does **not** type-check — so `tsc` is the only thing actually checking types.
  These coexist by design; do not "simplify" by deleting the tsc step.
- **vitest** — unit tests (uses esbuild under the hood, so TS "just works"; ships
  fake timers for the timing logic).

No minification initially. Bundle to **readable JS + an external source map**;
revisit minification only if payload is ever measured to matter. The R dependency
functions keep pointing at the same output paths, so the htmlDependency wiring is
unchanged.

**Source maps.** Emit an external `.map` per bundle and ship **both** the `.map`
and the `//# sourceMappingURL=…` comment (shipping the comment without the map
404s for devtools users). Shiny has no prod/dev distinction that strips maps — it
serves the dependency directory as static files — but browsers fetch the `.map`
only when devtools is open, so end users never download it in normal use. The only
cost is a few KB in the tarball/git, and irid is open-source so exposing TS sources
via the map is a non-issue. → ship both.

## Source of truth & vendoring

**Decided:** eventual destination is a **monorepo** where `srcts/` is the single
source both the R and Python packages vendor from. For now, `srcts/` lives in *this*
repo and the build vendors into `inst/js/` and `inst/widgets/plotly/`. The TS is kept
strictly **server-agnostic** (no R-specific assumptions) so the eventual lift into the
monorepo is a move, not a rewrite. The Python package will vendor the same built
artifacts once that restructure happens.

## Layout

```
srcts/
  package.json
  tsconfig.json            # strict; noEmit (typecheck only — esbuild does the emit)
  vitest.config.ts
  esbuild.mjs              # builds both entries to inst/
  src/
    protocol.ts            # THE wire-protocol types (shared contract)
    shiny.d.ts             # minimal ambient `Shiny` / jQuery `$` declarations
    core/
      seq.ts               # sequence / stale-echo gate (pure)        [#30 core]
      payload.ts           # buildPayload, attachPayloadMeta
      anchors.ts           # comment-anchor registry + range ops
      ratelimit.ts         # throttle/debounce/coalesce + per-element ordering queue
      stale.ts             # stale-indicator timers (DOM + setTimeout)
      widgets.ts           # defineWidget, mountWidget, pendingInits
      handlers.ts          # irid-attr / -swap / -mutate / -events / -config / -widget-init
      index.ts             # assembles window.irid + registers handlers  (entry)
    widgets/
      plotly/
        pure.ts            # approxEq, idsToIndices, idsFromPoints, visibility,
                           # rangeSpec/scalarSpec/selectionSpec/visibilitySpec  [#30 plotly]
        index.ts           # factory: Plotly.react/relayout/restyle glue        (entry)
    __tests__/
      seq.test.ts
      ratelimit.test.ts    # fake-timers (the gap V8 couldn't cover)
      plotly-pure.test.ts
      ...
```

## Test scope (vitest)

vitest runs **node-env, no jsdom**. It covers the **pure decision logic + timing**
only — `seq`, `plotly/pure`, and `ratelimit` (fake timers). The DOM-bound modules
(`anchors`, `handlers`, `stale`, `widgets`) stay **e2e-only**, for the same reason
#30 gave: faithfully mocking the DOM / `Plotly.*` / Shiny glue is more work and less
trustworthy than the real browser the chromote suite already drives.

For `ratelimit` to be unit-testable without a Shiny stub, its **send and idle-state
dependencies must be injected** (passed as callbacks) rather than calling
`Shiny.setInputValue` / `shinyapp.$idleTimeout` directly. That's a small port-time
refactor — extract the pure ordering-queue / throttle / debounce logic from the
Shiny touchpoints — consistent with the "isolate the pure unit" theme.

Build outputs (committed):

```
inst/js/irid.js                          (+ irid.js.map)
inst/widgets/plotly/plotly-irid.js       (+ .map)
```

`irid.css` stays a hand-authored asset in `inst/js/` (not part of the TS build).

## Module decomposition (porting the two files)

**`irid.js` → `srcts/src/core/*`** — split along the concerns already documented in
ARCHITECTURE.md's *Client-Side Protocol*:

- `seq.ts` — `isStaleEcho`, per-channel counter bump (pure; takes `sequences` as a
  parameter instead of closing over a module global).
- `payload.ts` — `buildPayload`, `attachPayloadMeta`.
- `anchors.ts` — `indexAnchors`, `lookupAnchors`, `parseFragment`, `detachRange`.
- `ratelimit.ts` — managed streams, throttle/debounce/coalesce, the per-element FIFO
  ordering queue + `drainQueue`. Pure logic + timers; the prime fake-timer test target.
- `stale.ts` — `markStale` / `clearStale` / `onEventSent` + the `shiny:idle`/`busy`
  wiring.
- `widgets.ts` — registry (`defined`, `pendingInits`, `widgets`), `mountWidget`,
  `destroyWidgetsIn`.
- `handlers.ts` — the six `Shiny.addCustomMessageHandler` registrations.
- `index.ts` — builds `window.irid` (`defineWidget`, `sendWidgetEvent`,
  `setWidgetProp`) and registers handlers. esbuild entry → `inst/js/irid.js`.

**`plotly-irid.js` → `srcts/src/widgets/plotly/*`**:

- `pure.ts` — the #30 plotly targets: `approxEq`, `idsToIndices`, `idsFromPoints`,
  `typedVisibility`/`stringVisibility`/`readVisibility`, `slimPoints`, and the pure
  entry-method factories (`rangeSpec`/`scalarSpec` → `{writeSpec, matchesCurrent,
  fromRelayout}`; `selectionSpec`/`visibilitySpec` → `{writeSpec, matchesCurrent}`).
- `index.ts` — the async factory; composes each entry's pure spec with its impure
  `apply`/`applyDeferred` (Plotly.relayout/restyle/react + the `mutate` guard).
  esbuild entry → `inst/widgets/plotly/plotly-irid.js`.

Both entries emit IIFE bundles, so `window.irid` is still assigned the same way and
the factory still calls `window.irid.defineWidget` — runtime behavior is byte-for-byte
equivalent in shape, just sourced from TS.

## Type surface

**`protocol.ts` is type-only** — interfaces/types with zero runtime code. It carries
the wire-protocol message/payload shapes **and** the public client API: the `Irid`
interface (`defineWidget`, `sendWidgetEvent`, `setWidgetProp`) plus the widget
**factory/handle contract** (`(el, props, sendEvent, setProp) => Handle |
Promise<Handle>`, `Handle = { update, destroy }`) — the widget-author API is part of
the typed prize, not just the wire. A `declare global { interface Window { irid: Irid
} }` augmentation lets the plotly bundle reference `window.irid.defineWidget` safely.
Being type-only, `protocol.ts` is erased at build, so both independent bundles import
it with **no runtime duplication** — it is the one thing crossing the bundle boundary.

**External globals.** The client touches two untyped globals: `Shiny` (the Shiny
client object) and `$` (jQuery, for `shiny:idle`/`busy` and `Shiny.unbindAll`/
`bindAll` adjacency).

- **Shiny:** use the official **`@types/rstudio-shiny`** declarations. They aren't
  published to npm, so they're a **git-pinned devDep** (`github:rstudio/shiny#v1.11.0`,
  which is literally packaged as `@types/rstudio-shiny` with a no-op `prepare`). They
  augment `window.Shiny` with the full `ShinyClass` and cover everything irid calls
  (`addCustomMessageHandler`, `setInputValue` with a typed `priority`, `bindAll`/
  `unbindAll`). Two gaps remain, bridged by a tiny ambient `src/shiny.d.ts`: (a) the
  post-init methods are typed *optional* (Shiny attaches them after init), so calls
  take a `!`/guard — correct, since irid runs post-init; (b) `shinyapp.$idleTimeout`
  (the backpressure gate) is an internal field they don't type, so it needs a local
  cast/augmentation.
- **jQuery `$`:** a one-method shim in `src/shiny.d.ts` (`$(target).on/.one`) — not
  worth pulling all of `@types/jquery`.

So we no longer hand-roll a guess of Shiny's API — `shiny.d.ts` shrinks to the bare
`Shiny` global alias + the `$` shim.

**Package manager: pnpm** (via corepack, pinned in `packageManager`). Chosen over
npm for the committed **monorepo** future (pnpm workspaces). The git-pinned Shiny
dep and esbuild's native-binary postinstall are allow-listed in
`pnpm-workspace.yaml` (`allowBuilds`).

## CI

- **`R-CMD-check.yaml`** — unchanged; runs against the *committed* built artifacts,
  no node needed.
- **New `client.yaml`** (node job, on push to `main` and on PRs targeting `main`):
  pin node via `setup-node` (+ `.nvmrc` / `engines`), then `npm ci` → `npm run
  typecheck` (`tsc --noEmit`) → `npm test` (vitest, `--coverage`) → `npm run build`
  → **`git diff --exit-code inst/`**. The diff check is a **fail-with-diff freshness
  gate**: a PR that edits `.ts` but forgets to rebuild fails with a clear "run
  `npm run build` and commit" message.

  This is the boring, robust option: a few lines, **no token, no loop risk, no
  wrong-commit-status problem**. The fancier *auto-commit-back* (rebuild and push
  the bundle so contributors never need node) is deferred — see *Future
  enhancements*.
- **`e2e.yaml`** — unchanged; remains the integration acceptance gate that the
  ported client preserves real browser behavior (it boots Chrome against the built
  artifacts via the existing chromote driver).
- **`test-coverage.yaml`** — still R-side only; client coverage now reportable
  separately from vitest if we want it later.

## .Rbuildignore / .gitignore

- `.Rbuildignore`: add `^srcts$`, `^package\.json$` if any lands at root (none
  planned — all node config lives under `srcts/`), so the R tarball ships only the
  built `inst/` JS.
- `.gitignore`: add `srcts/node_modules/`. Built artifacts under `inst/` are
  **committed** (do not ignore them).

## Relationship to #30

#30 chose V8 specifically to avoid a node/vitest toolchain and keep tests in
`devtools::test()`. That tradeoff only holds while we stay no-build-step. Under this
plan the same pure logic (the core sequence/stale-echo gate; the plotly
identity/diff helpers and entry specs) is tested by **vitest** instead — natively
typed, and extended to the timer logic V8 couldn't reach. Resolution: **close #30 as
superseded by this work** (or repurpose it to track "port the pure-logic tests to
vitest"), and reference this doc.

## Phased plan (one concept per commit, feature branch)

1. **Scaffold.** `srcts/` with `package.json`, `tsconfig.json` (strict),
   `vitest.config.ts`, `esbuild.mjs`, npm scripts (`build`, `test`, `typecheck`),
   `shiny.d.ts`. `.Rbuildignore` + `.gitignore` updates. No source ported yet.
2. **Protocol types.** `src/protocol.ts` — the message/payload contract, derived
   from ARCHITECTURE.md's *Client-Side Protocol* section.
3. **Port core.** `irid.js` → `src/core/*`; esbuild emits `inst/js/irid.js`.
   Re-run the e2e suite to confirm parity.
4. **Port plotly.** `plotly-irid.js` → `src/widgets/plotly/*`; emits the widget JS.
   Re-run plotly e2e.
5. **Unit tests.** vitest for `seq`, `plotly/pure`, and `ratelimit` (fake timers) —
   the #30 scope plus the timing logic.
6. **CI.** Add `client.yaml` (typecheck + test + build + **fail-with-diff freshness
   gate**; upload vitest coverage under the `client` flag). Verify R-CMD-check still
   green against committed artifacts.
7. **Docs.** ARCHITECTURE.md (build step + `srcts/` layout), TESTING.md (vitest
   layer, how to run, the build-freshness gate), update the "no JS build step"
   references, README contributor setup.

## Re-confirm-on-bump caveats

- esbuild IIFE output assigning `window.irid`: re-verify the global is assigned
  before any factory script runs (load order is preserved by the htmlDependency
  `script` vector / separate deps; the e2e suite is the check).
- **`@types/rstudio-shiny` is git-pinned to `v1.11.0`.** Its internal type paths
  (`srcts/types/src/...`) and the optional-method modeling can shift across versions
  — re-confirm the bridge in `src/shiny.d.ts` still compiles on a bump, and keep the
  pinned tag in step with the Shiny the app actually runs against.
- The jQuery `$` shim covers only `.on`/`.one`; widen only if irid's usage grows.

## Coverage reporting

Wire client coverage into the existing Codecov setup. vitest emits `lcov` natively
(`--coverage`, c8/istanbul); upload it from `client.yaml` under a **`client`
Codecov flag**, and tag the R upload `r`, so the two reports stay separate rather
than averaging into one misleading number. Keep it **advisory** — no PR gate,
consistent with TESTING.md's "chase meaningful branches, not the number." Cheap to
add since Codecov is already configured for the R side.

## Future enhancements

- **Auto-commit-back the bundle.** Instead of the fail-with-diff gate, have CI
  rebuild and push the regenerated bundle back to the branch, so contributors can
  tweak `.ts` (comments, small fixes) without a local node toolchain. Deferred
  because the payoff is mostly an *external-contributor* convenience (negligible
  while solo) and the cost is real: the `GITHUB_TOKEN`-pushes-don't-re-trigger-
  workflows gotcha forces a PAT / GitHub App token to get the rebuilt artifact
  re-validated, plus fork-PR fallbacks, commit-loop guards, and the green-check-on-
  the-wrong-commit problem. **Revisit at the monorepo stage**, where build
  orchestration is already more involved and a bot identity likely exists, so the
  marginal cost drops just as the contributor-ergonomics benefit becomes real.
- **Client coverage gating / Codecov UI polish** — keep advisory for now.

## Open decisions

(None outstanding.)
