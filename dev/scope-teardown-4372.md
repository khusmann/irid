# Scope teardown for shiny#4372 (reactiveVal reclamation)

Issue: [#24](https://github.com/khusmann/irid/issues/24). Branch: `scope-teardown-4372`.

## Problem

`make_scope` ([R/scope.R](../R/scope.R)) tears down only the **observers** it
tracks via `register_observer`. The `reactiveVal`s held by mini-store leaves,
scalar slot accessors, and the keyed `pos_rv` **leak until session end** —
shiny 1.7.4 has no public API to destroy a `reactiveVal`. Each unmounted `Each`
item / `Match` case leaves its leaves in the session's reactive graph. Bounded
per-session, but it grows under churn (a dashboard adding/removing rows).

This is the "Known limitation — reactive-leak until shiny#4372 lands" in
ARCHITECTURE.md.

## What shiny#4372 actually merged (verified)

PR merged **2026-05-29**. Confirmed public API on `ShinySession` (and
`MockShinySession`):

- `session$makeScope(id)` — creates/retrieves a **child scope proxy** with its
  own `destroy()` and `onDestroy()`. Reactives created **within this scope's
  reactive domain** auto-register via weak references.
- `session$destroy(id = NULL)` — destroys child `id` (or self-destructs a proxy
  when called with no `id`). Reclaims observers **and** reactiveVals registered
  in that scope.
- `session$onDestroy(callback)` — cleanup callbacks fired on scope destroy.

The mechanism is **scope-at-creation**, not scope-at-destroy: a reactiveVal is
reclaimed by `destroy(id)` only if it was *created inside* that child scope's
reactive domain.

> Note: `session$makeScope(id)` **does** exist in the merged API — the issue and
> the current scope.R/ARCHITECTURE roxygen guessed at `makeSubdomain()` and were
> wrong. The real entry point is `makeScope`. Those stale references are fixed in
> step 4 below.

## The crux (open question for the spike)

`observe()` takes a `domain =` argument, so scoping an observer is a one-liner.
But `reactiveVal()` / `reactiveValues()` take **no `domain` argument** in 1.7.4
— they capture `getDefaultReactiveDomain()` at construction. So associating a
*reactiveVal* with a child scope can't be a `domain =` pass-through; it requires
either:

- **(A)** running the construction inside
  `shiny::withReactiveDomain(scope$session, { reactiveVal(...) })`, or
- **(B)** a new `domain =` argument on `reactiveVal()` added by #4372.

**Which one is real is the single thing the implementation hinges on.** The spike
([dev/spikes/scope-teardown-4372.R](spikes/scope-teardown-4372.R)) settles it. The
design below is written for **(A)** because it's the more general mechanism (it
also scopes *user*-authored `observe()` calls inside a component body for free —
see "Bonus" below) and degrades to a clean no-op pre-#4372. If the spike shows
(B) is available and (A) is *not*, fall back to threading `domain =` per
construction site; the creation-site inventory is identical either way.

## Design

A single forward-compat seam: `make_scope` owns both the scope identity and a
`with_scope(expr)` runner. Every per-item / per-case reactive is constructed
through `with_scope`. Pre-#4372, `scope$session` is just the outer session and
`with_scope` is `withReactiveDomain(session, expr)` — a no-op, today's behavior.
Post-#4372, `scope$session` is the child proxy, so the same constructions
auto-register there and `destroy()` reclaims them.

### `make_scope(session, id)`

```r
make_scope <- function(session, id = NULL) {
  has_4372 <- !is.null(session) && is.function(session$makeScope)

  if (has_4372) {
    # shiny#4372: child scope auto-tracks observers AND reactiveVals.
    child <- session$makeScope(id)
    list(
      session           = child,
      register_observer = function(obs) invisible(),   # auto-tracked
      with_scope        = function(expr) expr,          # `child` IS the domain
      destroy           = function() child$destroy()
    )
  } else {
    # Pre-#4372 fallback: manual observer tracker; reactiveVals leak.
    observers <- list()
    list(
      session           = session,
      register_observer = function(obs) {
        observers[[length(observers) + 1L]] <<- obs
      },
      with_scope        = function(expr) expr,
      destroy           = function() {
        for (obs in observers) obs$destroy()
        observers <<- list()
        invisible()
      }
    )
  }
}
```

Subtlety on `with_scope`: it must run `expr` inside the scope's domain **at the
construction site**, so it has to be lazy. Two clean options:

- Make `with_scope <- function(expr) withReactiveDomain(scope$session, expr)`
  and rely on R's lazy promise: `expr` isn't forced until `withReactiveDomain`
  evaluates it inside the domain. Callers write
  `scope$with_scope({ ...construct... })`.
- Pre-#4372, `withReactiveDomain(session, expr)` re-installs the *current*
  default domain, so it's a genuine no-op. (Confirm in the spike that this holds
  even when `session` is the active domain.)

Use the `withReactiveDomain` form in both branches for uniformity (drop the
`expr` identity shortcut in the `has_4372` branch — `child` is the domain there).
The `register_observer` no-op stays because observers created under the child
domain auto-register; we keep the call sites so the fallback still tracks them.

### Creation-site inventory (route all four through the scope)

| Reactive | Site | Change |
|---|---|---|
| mini-store leaf `rv` | [mini_store.R:158](../R/mini_store.R#L158) | construct inside `scope$with_scope({...})` |
| mini-store root propagator `observe` | [mini_store.R:93](../R/mini_store.R#L93) | already `domain = scope$session`; keep, drop `register_observer` reliance under #4372 |
| slot accessor `rv` | [mini_store.R:244](../R/mini_store.R#L244) | construct inside `scope$with_scope({...})` |
| slot accessor propagator `observe` | [mini_store.R:250](../R/mini_store.R#L250) | already `domain = scope$session`; keep |
| keyed `pos_rv` | [mount.R:620](../R/mount.R#L620) | construct inside `scope$with_scope({...})` |
| inner per-item mount | [mount.R:184](../R/mount.R#L184) | pass `entry$scope$session` instead of `session` |
| inner per-case mount | [mount.R:811](../R/mount.R#L811) | pass `scope$session` instead of `session` |

For the two `observe()` propagators that already pass `domain = scope$session`:
under #4372 `scope$session` is the child proxy, so they auto-register correctly
with no change. Pre-#4372 they pass the outer session (same as today) and are
tracked via `register_observer`. No edit needed beyond what's there.

For the inner mounts, `irid_mount_processed` builds its observers against the
`session` it's handed. Passing `scope$session` makes the per-item mount's
bindings/event observers attach to the child scope so `destroy(id)` reclaims them
too — and pre-#4372 `scope$session` is the outer session, so behavior is
unchanged. (The mount also calls `session$sendCustomMessage` / `session$output`
/ `insertUI`; confirm the child proxy forwards these — spike question.)

### `id` allocation

`make_scope` now needs an `id`. Both call sites already have a stable token:

- `Each`: `build_entry` makes `wrapper_id <- counter()` immediately before
  `make_scope(session)`. Pass it: `make_scope(session, id = wrapper_id)`.
- `Match`: use `cf_id` plus the active-case index (a case can re-mount over the
  session's life, so include a monotonic suffix to avoid id reuse colliding in
  the scope registry). Simplest: `make_scope(session, id = counter())` — pull a
  fresh token from the same counter the rest of the mount uses. Confirm in the
  spike whether `makeScope` tolerates an id format (string vs the module-id
  shape it expects).

### Teardown

`scope$destroy()` already exists at every site (`teardown_entry`, the Match
observer, the top-level `destroy`). Under #4372 it becomes `child$destroy()`
which cascades to observers + reactiveVals. **Teardown ordering is unchanged** —
mount → scope (the mount's observers read scope leaves). The existing
ordering note in scope.R stays valid.

## Bonus closed by the same seam: user observers

A bare `observe()` / `observeEvent()` written inside a component body (e.g. an
analytics tick in an `Each` item callback) currently attaches to the session
domain and keeps firing after the item unmounts. The `child` proxy passed as the
inner mount's domain means the body runs inside the child scope, so those user
observers attach there and are torn down with the item — no irid-specific
primitive. ARCHITECTURE.md already promises this; the `with_scope`/child-domain
inner mount delivers it. (Spike: confirm a user `observe()` created during body
evaluation is reclaimed by `destroy(id)`.)

## Spike (run against a #4372 shiny — required before implementing)

[dev/spikes/scope-teardown-4372.R](spikes/scope-teardown-4372.R) prints PASS/FAIL
verdicts for:

1. `session$makeScope(id)` exists and returns a proxy with `destroy`/`onDestroy`.
2. **Mechanism (A) vs (B):** does a `reactiveVal` constructed inside
   `withReactiveDomain(child, ...)` get reclaimed by `session$destroy(id)`?
   Does `reactiveVal(domain = child)` exist / work?
3. An `observe(domain = child)` stops firing after `destroy(id)`.
4. A reactiveVal created in the child scope is finalized after `destroy(id)` +
   `gc()` (weak-ref reclamation actually runs).
5. The child proxy forwards `sendCustomMessage` / `output` / `insertUI` (so the
   inner per-item mount can run against it).
6. Pre-#4372 sanity: `withReactiveDomain(session, expr)` is a no-op when
   `session` is already the active domain.
7. `makeScope` tolerates the id format we plan to pass (counter integer →
   `as.character`).

**Caveat to pin:** spike is pinned to the merged-shiny ref it runs against
(record `packageVersion("shiny")` + git SHA in the doc once run). #4372 method
names / weak-ref semantics may shift before a CRAN release; re-confirm on bump.

## Doc / tag cleanup (step 4)

- scope.R roxygen: replace `makeSubdomain()` references with
  `makeScope(id)` / `destroy(id)` / `onDestroy` / weak-ref auto-registration.
- ARCHITECTURE.md: the "Known limitation — reactive-leak" block and the
  `makeSubdomain` paragraph in *Control Flow Lifecycle* → rewrite to describe the
  feature-detected `makeScope` path (now-resolved, no longer a known limit when
  running on a #4372 shiny).
- Keep all `# shiny#4372:` grep tags; update their wording where they say
  "replaced by subdomain cascade" → "scope cascade".

## Commit plan (one concept per commit, on this branch)

1. Spike + this design doc (commit before running; fold results back after).
2. `make_scope` feature-detect + `with_scope` seam + `id` param.
3. Route the four creation sites through the scope (mini_store.R, mount.R).
4. Inner mounts run against `scope$session`.
5. Doc/tag cleanup (scope.R roxygen, ARCHITECTURE.md, grep tags).
6. Tests (see TESTING.md — scope teardown under both feature-detect branches).
</content>
</invoke>
