# Component Scoping — Design Document

**Status:** Proposed
**Date:** April 2026

---

## 1. Motivation

Reactive primitives created by irid internally — attribute bindings, event
observers, Shiny outputs, control-flow observers — are already scoped to a
mount handle and destroyed via `mount$destroy()`. But reactive primitives
created by **user code inside a component function** are not.

When the user writes:

```r
Card <- function(col) {
  observe({ analytics$card_viewed(col) })
  tags$div(strong(col), ...)
}
```

...the `observe()` is created during tree construction and attaches to the
session's reactive domain, not to the mount of the card. When the card
unmounts, irid tears down its internal observers but the user's `observe()`
keeps firing.

This leak compounds with every `When()` branch switch, every `Each()` add or
remove, and every `Index()` grow/shrink. An app that churns 50 cards creates
50 orphaned observers, each still firing, each holding closures alive. This
is the same dangling-observer pain that motivates the whole project —
reproduced inside irid for any user who reaches for `observe()` inside a
component.

The common case (pure `reactiveVal` + `reactive()` referenced only via tag
attributes) is safe: on unmount, internal binding observers die and release
their closures, making the whole subgraph unreachable. The gap is
specifically user-level `observe()` / `observeEvent()` / `reactive()` created
inside a component body.

---

## 2. Goals

- Reactive primitives created inside a component function are destroyed when
  the component unmounts
- Works for `observe()` and `observeEvent()` today; `reactive()` follows once
  Shiny provides a `destroy()` method
- Zero-friction API: user writes `observe({...})` exactly as in Shiny, with
  no re-exports, no renames, no namespace games
- Nests correctly: components inside components inherit no spooky behavior
- Error-safe: a throw during component construction unwinds the scope cleanly
- Top-level `observe()` (inside `iridApp(fn)` at the App level, or inside
  `renderIrid(...)`) still falls back to session scope, matching user
  expectations for app-lifetime observers
- No dependency on Shiny changes — works against current R Shiny

---

## 3. Design

### 3.1 Reactive domain per component

Shiny observers attach themselves to whatever `shiny::getDefaultReactiveDomain()`
returns at creation time. Specifically, `shiny::observe()` registers an
`onEnded` callback on that domain that calls the observer's `destroy()`
method. This is already the mechanism that tears down all of a session's
observers when the session ends.

We use the same mechanism at a finer granularity: create a small
`ReactiveDomain` subclass per component mount, push it onto Shiny's domain
stack for the duration of the component function call via
[`shiny::withReactiveDomain()`](https://rdrr.io/cran/shiny/man/withReactiveDomain.html),
and trigger its "ended" callbacks on unmount.

```r
ComponentDomain <- R6::R6Class("ComponentDomain",
  inherit = shiny:::ReactiveDomain,
  public = list(
    parent = NULL,
    ended_callbacks = list(),

    initialize = function(parent) {
      self$parent <- parent
    },

    onEnded = function(callback) {
      self$ended_callbacks <- c(self$ended_callbacks, list(callback))
      invisible()
    },

    end = function() {
      for (cb in self$ended_callbacks) try(cb(), silent = TRUE)
      self$ended_callbacks <- list()
      invisible()
    }

    # Delegate session-shaped accessors (input, output, sendCustomMessage,
    # ns, etc.) to $parent. See open questions below.
  )
)
```

### 3.2 Running a component function inside a scope

```r
with_component_scope <- function(fn) {
  parent <- shiny::getDefaultReactiveDomain()
  domain <- ComponentDomain$new(parent = parent)
  result <- shiny::withReactiveDomain(domain, fn())
  list(result = result, domain = domain)
}
```

Call sites pass a zero-argument lambda:

```r
scope <- with_component_scope(\() cf_fn(item, index_rv))
child <- scope$result
item_domain <- scope$domain
```

Any `observe()`/`observeEvent()` created inside `fn` resolves its domain
via `getDefaultReactiveDomain()`, which returns `domain` for the dynamic
extent of the call. Those observers register their `destroy` on `domain`'s
`onEnded`. When the caller later invokes `domain$end()`, all attached
observers are destroyed.

### 3.3 Integration with mount lifecycle

Every site that calls a user function returning a tag tree wraps the call
in `with_component_scope()` and attaches the returned `domain` to the
corresponding mount handle. On `mount$destroy()`, the mount calls
`domain$end()` before destroying its own internal observers.

**`iridApp(fn)`** — [app.R:32](../R/app.R#L32): wrap `process_tags(fn())`.
Attach the returned domain to the mount handle.

**`renderIrid`** — [app.R:69](../R/app.R#L69): same wrap around `func()`.

**`Each` item creation** — [mount.R:209](../R/mount.R#L209): wrap
`cf_fn(item, index_rv)`; attach the returned domain to the per-item mount
handle created on [mount.R:240](../R/mount.R#L240).

**`Index` slot creation** — [mount.R:287](../R/mount.R#L287): same
treatment; attach to the per-slot mount.

**`When`/`Match` branch evaluation** — [mount.R:353](../R/mount.R#L353) and
the corresponding `Match` site: wrap the branch function call; attach the
returned domain to the `current_mount`.

Each mount handle grows a single `user_domain` reference alongside its
internal `observers` list. `mount$destroy()` walks both:

```r
# Sketch, inside irid_mount_processed's returned destroy function:
destroy <- function() {
  if (!is.null(user_domain)) user_domain$end()
  for (obs in observers) obs$destroy()
}
```

### 3.4 Error handling

`shiny::withReactiveDomain()` already unwinds the domain stack on error.
Any partially-registered observers on the custom domain at the point of
throw are still attached to it — we destroy them by calling `domain$end()`
in the caller's error handler, or by simply never attaching the domain to
a mount (so nothing holds a reference, and GC eventually releases it).

In practice, callers wrap with `tryCatch` and let the unreached domain
fall out of scope:

```r
scope <- tryCatch(
  with_component_scope(\() user_fn(item)),
  error = function(e) {
    # scope's domain is unreachable after this frame unwinds;
    # GC releases it, and any observers it owns along with it
    stop(e)
  }
)
```

---

## 4. What this does not solve

### `reactive()` calcs cannot be torn down today

Shiny's `reactive()` has no `$destroy()` method. A user-level `reactive()`
inside a component can attach to the custom domain via an `onEnded`
callback, but the callback has nothing to call — we can only drop our
reference and hope GC collects it.

Whether GC actually collects it depends on Shiny's internal graph. A
`reactive()` that depends on an upstream `reactiveVal` is held alive
(indirectly) by the upstream's invalidation-callback list: every time
the upstream changes, it notifies downstream dependents, and that
notification path keeps the downstream reactive reachable. Destroying
the downstream observers that watch the `reactive()` detaches *those*
subscriptions, but the `reactive()` itself remains subscribed to its
own upstream deps with no way to unsubscribe.

Net effect: a user `reactive()` inside a component that's unmounted
will, in the worst case, linger in the reactive graph for the life
of the session, recomputing on every upstream invalidation, even though
nothing consumes its value anymore. This is a latent leak — not
unbounded memory growth (the calc holds a bounded cache), but
unbounded *work*, proportional to churn × upstream invalidation rate.

This limitation disappears once Shiny provides `destroy()` for calcs.
See section 5.

### `reactiveVal` does not need scoping

`shiny::reactiveVal` is a plain R closure with no global registration.
It becomes GC-eligible naturally when nothing references it. This
proposal leaves `reactiveVal` alone.

---

## 5. Relationship to upstream Shiny fixes

[py-shiny#2207](https://github.com/posit-dev/py-shiny/issues/2207) is
exploring server-side lifecycle hooks for similar reasons — dangling
effects, dangling calcs (with a `destroy()` method on the table), and
dangling input values. The design here is forward-compatible with each
of those, and anticipates that R Shiny eventually lands the equivalents.

How this doc's design changes under each upstream fix:

**If Shiny adds `$destroy()` to `reactive()` calcs** — the custom domain's
`onEnded` callbacks can now call the calc's `destroy()` just like they
call observers'. The latent-leak story in section 4 goes away: calcs
created inside a component are torn down with the component, unsubscribing
from their upstream dependencies and dropping from the graph. No irid-side
code change required if calcs hook into `onEnded` the same way observers
do; otherwise a ~5-line addition to the `reactive()` attachment path.

**If Shiny adds a first-class reactive-scope API** (something stronger
than `withReactiveDomain`, e.g. explicit ownership tracking or per-scope
destroy semantics) — our `ComponentDomain` collapses to a thin wrapper
around the upstream primitive, or is deleted entirely. User API unchanged.

**If Shiny adds cleanup hooks tied to UI removal** (closer to the
`insertUI`/`removeUI` path) — orthogonal to this proposal; doesn't
change the design, but provides a belt-and-suspenders guarantee for
users who go around irid and reach for `insertUI`/`removeUI`
directly.

Shipping component scoping in irid ahead of upstream means users get
the observer guarantee now. The calc guarantee has to wait on Shiny
either way — there's no workaround at the R level.

---

## 6. Implementation size

- `scope.R` (`ComponentDomain` R6 class, `with_component_scope`): ~80 LoC
- Integration edits in `app.R` and `mount.R`: ~40 LoC across 6 call sites
- Tests: ~120 LoC (mount a component with user observers, destroy mount,
  assert observers stopped firing; nested scopes; error-during-construction
  unwinds cleanly; `Each` churn does not accumulate observers; session
  access delegates correctly from child domain)

Total: ~240 LoC. No NAMESPACE changes needed; no functions shadowed.

---

## 7. Prototyping plan

Build in this order; stop and reassess if a step fails.

**Step 1 — verify `withReactiveDomain` + `onEnded` actually tears down observers.**
Minimal sketch in a scratch file, no integration:

```r
d <- shiny:::ReactiveDomain$new()  # or ComponentDomain prototype
shiny::withReactiveDomain(d, {
  obs <- shiny::observe({ cat("tick\n") })
})
# trigger some reactive invalidation that would cause obs to fire
d$end()  # or whatever method fires onEnded callbacks
# trigger another invalidation; assert obs did not fire
```

If observers are still firing after `d$end()`, the whole approach is dead
and we drop to the shadow fallback.

**Step 2 — determine what session-like surface a custom domain needs.**
Grep irid's own `mount.R` for every use of `session$...` and
`getDefaultReactiveDomain()$...`, then grep a representative user-written
`observe()` corpus (the examples directory, the todo/cards demos) for the
same. Enumerate the minimum interface. Decide between (a) subclassing
`shiny:::ReactiveDomain`, (b) building a plain R6 class with the enumerated
methods, or (c) composition — a wrapper object that delegates everything
unknown to the parent session via `$`.

**Step 3 — build `ComponentDomain` and test in isolation.**
Unit tests covering:

- observe created in scope is destroyed on `$end()`
- observeEvent created in scope is destroyed on `$end()`
- nested component scopes: inner observers attached to inner domain,
  inner `$end()` does not affect outer observers
- an observer in a component can still read `input$foo`, update an
  output, and send a custom message (delegation works)
- `$end()` called twice is a no-op
- error during construction does not leave the domain stack in a bad
  state

**Step 4 — integrate at one call site.**
Pick `Each` item creation ([mount.R:209](../R/mount.R#L209)) — it's the
site with the most leak potential, so the fix is most observable. Add a
`user_domain` slot to the per-item mount. Before integrating
elsewhere, write a churn test: mount an `Each` of 50 items where each
item creates an `observe()`, add/remove repeatedly, assert the count
of live observers stays bounded.

**Step 5 — roll out to remaining call sites.**
`When`, `Match`, `Index`, `iridApp`, `renderIrid`. Run the full test
suite after each.

**Step 6 — document in user-facing docs.**
A short "Component lifecycle" page explaining that observers created
inside components are auto-torn-down on unmount, that `reactive()`
calcs currently aren't (pending Shiny), and that `session_scoped()` is
available if a user deliberately wants an app-lifetime observer from
inside a component.

---

## 8. Open questions

- **Which ShinySession methods does a `ComponentDomain` need to
  delegate?** Observers routinely access `input`, `output`,
  `sendCustomMessage`, `onFlushed`, `ns`, `userData`, etc. through
  the reactive domain. `ComponentDomain` must forward any method the
  user's `observe()` body might reach. The safest implementation is an
  explicit list of forwarded methods rather than dynamic `$` dispatch —
  to be enumerated by grepping irid's own `irid_mount_processed` for
  domain usage, then extended as needed.
- **What if `shiny:::ReactiveDomain` isn't a stable parent to subclass?**
  It lives in Shiny's internal namespace. If inheritance from it is
  fragile, an alternative is to implement `ComponentDomain` as a plain
  R6 class that *satisfies the duck-typed interface* Shiny's `observe()`
  looks for (`onEnded`, session accessors). Worth prototyping both.
- **Do we need an escape hatch?** A `session_scoped(fn)` helper that
  runs `fn` against the parent domain, for users who deliberately
  want session-lifetime observers inside a component. Low priority;
  can add later.
- **Diagnostics?** A `debug = TRUE` mode that logs domain push, domain
  end, and the number of observers destroyed, for tracing leaks during
  development.
- **Fallback plan.** If custom-domain turns out too fragile (e.g.,
  Shiny's internal reactive-domain contract is richer than we can
  satisfy), fall back to a shadow-wrapper approach: re-export
  `observe`/`observeEvent`/`reactive` from irid, wrap their Shiny
  counterparts, and track destructors in an irid-owned stack. Similar
  integration points, higher friction around namespace, but known-
  working in isolation.
