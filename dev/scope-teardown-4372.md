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

## What shiny#4372 actually merged (verified against source)

PR merged **2026-05-29**. Verified by reading the merged source, checked out at
[.claude/worktrees/shiny-dev](../.claude/worktrees/shiny-dev) — **shiny
1.13.0.9000**, HEAD `44fd783` (re-confirm on bump). Public API on `ShinySession`
(and `MockShinySession`):

- `session$makeScope(namespace)` — creates/retrieves a **child scope proxy** with
  its own `destroy()` and `onDestroy()`. `namespace` is validated by
  `validateNamespace`: a **non-empty, non-NA string** (not the reserved internal
  root). Reactives constructed while this proxy is the **default reactive
  domain** auto-register a weak destroy handle against it.
- `session$destroy(namespace = NULL)` — destroys child `namespace`; on the root
  session, calling with no `namespace` **errors** (must name a scope). The proxy's
  own `destroy()` (no arg) self-destructs.
- `session$onDestroy(callback)` — cleanup callbacks fired on scope destroy.

The mechanism is **scope-at-creation**, not scope-at-destroy.

> ⚠️ **`makeScope` is a *module namespace* scope, not a bare lifetime container.**
> It namespaces inputs/outputs through `NS(namespace)` (`createSessionProxy` wires
> `input`/`output`/`sendInputMessage`/`registerDataObj` through `ns()`). This
> drives a correction to the issue's plan — see *Design* below: we use the child
> scope **only as a destroy domain**, and must **not** route the inner per-item
> mount's I/O through it.

> Note: `session$makeScope` **does** exist — the issue and the current
> scope.R/ARCHITECTURE roxygen guessed at `makeSubdomain()` and were wrong. Fixed
> in step 4.

## The crux — RESOLVED from source (mechanism A)

`observe()` takes a `domain =` argument. `reactiveVal()` / `reactiveValues()`
**do not** — confirmed in the merged source:
`reactiveVal <- function(value = NULL, label = NULL)` has no `domain` formal.
Auto-registration happens *inside* `ReactiveVal$new`, against the **default
reactive domain at construction time**:

```r
# shiny-dev R/reactives.R, ReactiveVal$initialize
domain <- getDefaultReactiveDomain()
if (!is.null(domain) && is.function(domain$onDestroy)) {
  wr <- rlang::new_weakref(key = self)
  private$.destroyHandle <- domain$onDestroy(make_weak_destroy_wrapper(wr))
}
```

So scoping a reactiveVal **requires** constructing it inside
`shiny::withReactiveDomain(scope$session, { reactiveVal(...) })` — there is no
`domain =` pass-through (mechanism B does not exist). Observers follow the same
weak-handle path via `setAutoDestroy` (`autoDestroy = TRUE` default), so an
`observe(domain = child)` is also reclaimed by `child$destroy()`.

This also means the design scopes *user*-authored `observe()` inside a component
body for free (the body runs under the child domain — see *Bonus*), and degrades
to a clean no-op pre-#4372 (where the session exposes no `makeScope`, so we never
build a child and `withReactiveDomain(session, …)` is a no-op).

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
    # shiny#4372: child scope auto-tracks observers AND reactiveVals
    # constructed under its reactive domain.
    child <- session$makeScope(id)
    list(
      session           = child,
      register_observer = function(obs) invisible(),   # auto-tracked
      with_scope        = function(expr) withReactiveDomain(child, expr),
      destroy           = function() child$destroy()    # self-destruct proxy
    )
  } else {
    # Pre-#4372 fallback: manual observer tracker; reactiveVals leak
    # (today's behavior). `withReactiveDomain(session, …)` is a no-op.
    observers <- list()
    list(
      session           = session,
      register_observer = function(obs) {
        observers[[length(observers) + 1L]] <<- obs
      },
      with_scope        = function(expr) withReactiveDomain(session, expr),
      destroy           = function() {
        for (obs in observers) obs$destroy()
        observers <<- list()
        invisible()
      }
    )
  }
}
```

`with_scope(expr)` relies on R's lazy promise — `expr` is not forced until
`withReactiveDomain` evaluates it under the scope's domain. Callers write
`scope$with_scope({ ...construct accessor + body... })`. Pre-#4372,
`withReactiveDomain(session, …)` re-installs the already-active default domain, a
genuine no-op (and reactiveVals fall back to today's leak-until-session-end). The
`register_observer` no-op stays under #4372 (observers auto-register via the
child domain); the call sites remain so the fallback path still tracks them.

Note `destroy()` calls `child$destroy()` (the proxy self-destruct), **not**
`session$destroy(id)` — the latter errors on the root session unless given a
namespace, and the proxy form is the documented child-teardown path.

### Creation-site inventory

The leak is exactly the **reactiveVals** with no explicit destroy: mini-store
leaves, slot-accessor `rv`s, keyed `pos_rv`. The propagating observers and the
inner mount's binding/event observers are **already** explicitly torn down (by
`scope$destroy()`'s tracker and `mount$destroy()` respectively), so they were
never the leak — they only need to keep working.

The clean seam is to wrap the whole **accessor + body construction** for one
item / case in `scope$with_scope({...})` (i.e. `withReactiveDomain(scope$session,
…)`). That single wrap captures every reactiveVal created inside
`make_mini_store` / `make_slot_accessor`, the keyed `pos_rv`, **and** any
user-authored `observe()` in the body — all auto-register against the child.

| Reactive | Site | Change |
|---|---|---|
| mini-store leaf `rv` | [mini_store.R:158](../R/mini_store.R#L158) | (no edit here) constructed under the `with_scope` wrap at the call site |
| mini-store root propagator `observe` | [mini_store.R:93](../R/mini_store.R#L93) | keep `domain = scope$session`; under the wrap it also auto-destroys |
| slot accessor `rv` | [mini_store.R:244](../R/mini_store.R#L244) | (no edit here) constructed under the `with_scope` wrap |
| slot accessor propagator `observe` | [mini_store.R:250](../R/mini_store.R#L250) | keep `domain = scope$session` |
| keyed `pos_rv` | [mount.R:620](../R/mount.R#L620) | constructed under the `with_scope` wrap in `build_entry` |
| `Each` build_entry: accessor + `cf_fn(...)` body | [mount.R:585-648](../R/mount.R#L585) | wrap the accessor build + body eval in `scope$with_scope({...})` |
| `Match`: `make_mini_store` + `body(binding)` | [mount.R:794-804](../R/mount.R#L794) | wrap the binding build + body eval in `scope$with_scope({...})` |
| inner per-item mount | [mount.R:184](../R/mount.R#L184) | **unchanged — stays on raw `session`** (see below) |
| inner per-case mount | [mount.R:811](../R/mount.R#L811) | **unchanged — stays on raw `session`** |

**Why the inner mounts stay on `session` (correction to the issue's plan).**
`irid_mount_processed` registers Shiny outputs (`session$output[[id]] <- …`) and
event observers keyed on raw input IDs (`irid_ev_{id}_{event}`,
`irid_prop_{id}_{key}`). Those IDs are irid's globally-unique element IDs and the
client binds to them verbatim. The child proxy from `makeScope` **namespaces**
`input`/`output` through `NS(namespace)`, so routing the mount through it would
turn `output[["irid-7"]]` into `output[["ns-irid-7"]]` and read events from the
wrong input — breaking every output/event inside an `Each`/`Match`. The mount's
own observers are already destroyed explicitly by `mount$destroy()`, so they
don't leak; there is nothing to gain and correctness to lose by namespacing them.
The mount therefore keeps running against the raw outer `session`.

A binding observer (raw-session domain) depending on a mini-store leaf
(child-scope domain) is fine — reactive dependency tracking is per-reactive, not
per-domain; the domain only governs lifecycle. Teardown order **mount → scope**
(unchanged) guarantees the mount's observers are gone before the leaves they read
are reclaimed.

### `id` (namespace) allocation

`make_scope` now needs a `namespace` string. `validateNamespace` accepts any
non-empty, non-NA string, so a stringified counter token works. It must be
**unique per live scope** (the scope registry is keyed by it) — and since we do
*not* route any I/O through the child proxy, the namespace is purely a scope key,
never an actual input/output prefix on the wire.

- `Each`: `build_entry` makes `wrapper_id <- counter()` right before
  `make_scope`. Pass `make_scope(session, id = as.character(wrapper_id))`.
- `Match`: pull a fresh `make_scope(session, id = as.character(counter()))` per
  active-case mount, so a case re-mounting over the session's life never reuses a
  retired scope key.

The `counter()` token is monotonic and globally unique within the mount, so
collisions can't occur.

### Teardown

`scope$destroy()` already exists at every site (`teardown_entry`, the Match
observer, the top-level `destroy`). Under #4372 it becomes `child$destroy()`
which cascades to observers + reactiveVals.

**Teardown ordering is unchanged but now load-bearing.** The spike found that
post-destroy a scope reactiveVal is **actively destroyed** — `.destroyed` is set
and any get/set raises `destroyedReactiveError` ("Can't access reactive …; its
module session has been destroyed"), not a silent no-op or a lazy GC. So the
mount → scope order is not just hygiene: any observer or accessor that reads a
leaf **must** be torn down before the scope, or it throws on the next access.
irid already destroys the mount (its binding/event observers) before the scope at
every site, and the propagators live in the scope itself — so this holds. The
existing ordering note in scope.R stays valid and gains this teeth.

## Bonus closed by the same seam: user observers

A bare `observe()` / `observeEvent()` written inside a component body (e.g. an
analytics tick in an `Each` item callback) currently attaches to the session
domain and keeps firing after the item unmounts. Because `with_scope` evaluates
the body under the child domain, those user observers auto-register against the
child (`setAutoDestroy` weak handle) and are torn down by `child$destroy()` — no
irid-specific primitive. ARCHITECTURE.md already promises this; `with_scope`
delivers it. (This is delivered by the body-eval wrap, **not** by the inner mount
domain, which stays on `session`.)

## Spike — RAN, all PASS

[dev/spikes/scope-teardown-4372.R](spikes/scope-teardown-4372.R) ran against the
checked-out dev shiny (loaded via `pkgload::load_all`; its newer
`cachem`/`commonmark`/`promises` deps were installed into a throwaway temp lib so
the project library is untouched). Verdicts:

```
[PASS] makeScope(stringified-counter) returns proxy with $destroy
[PASS] makeScope returns proxy with $onDestroy
[PASS] reactiveVal() has NO `domain` formal (mechanism B absent)
[PASS] scoped observe fired on dependency change
[PASS] scope reactiveVal throws on access after destroy() (actively reclaimed)
[PASS] child-scope reactiveVal env finalized after destroy + gc
[PASS] user observe (no explicit domain) picked up child as default domain
[PASS] user observe + its rv reclaimed by child$destroy() (the bonus)
```

Resolved by the run, beyond the source reading:

- **Mechanism A only.** `reactiveVal` has no `domain` formal; scoping requires the
  `withReactiveDomain(child, …)` wrap. Confirmed reclaimed.
- **Active destroy, not lazy GC.** Post-`destroy()`, a scope reactiveVal *throws*
  on access — see *Teardown* above. Finalizer also fires after `gc()`.
- **Bonus holds.** A user `observe()` with no explicit domain, created during a
  body eval under `withReactiveDomain(child, …)`, is reclaimed by
  `child$destroy()`.

The spike deliberately does **not** test inner-mount-through-child — that path is
rejected by design (namespacing), so we only confirm reclamation of the
reactiveVals/observers we actually scope.

**Caveat to pin:** behavior is pinned to **shiny 1.13.0.9000 / HEAD `44fd783`**.
#4372 method names / weak-ref semantics may shift before a CRAN release;
re-confirm on bump. The dev checkout lives at
[.claude/worktrees/shiny-dev](../.claude/worktrees/shiny-dev) (gitignored).

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
