flushReact <- function() shiny:::flushReact()

new_scope <- function() irid:::make_scope(NULL)

new_mini <- function(initial) {
  parent <- shiny::reactiveVal(initial)
  list(
    parent = parent,
    mini = irid:::make_mini_store(
      get_record = parent,
      set_record = parent,
      scope = new_scope()
    )
  )
}

# --- Construction & shape ----------------------------------------------------

test_that("keys, names, length match the initial record", {
  fix <- new_mini(list(a = 1, b = "x", c = TRUE))
  expect_equal(names(fix$mini), c("a", "b", "c"))
  expect_equal(length(fix$mini), 3L)
})

test_that("initial values are readable from leaves", {
  fix <- new_mini(list(a = 1, b = "x"))
  expect_equal(shiny::isolate(fix$mini$a()), 1)
  expect_equal(shiny::isolate(fix$mini$b()), "x")
})

test_that("whole-record read returns the initial record", {
  fix <- new_mini(list(a = 1, b = "x"))
  expect_equal(shiny::isolate(fix$mini()), list(a = 1, b = "x"))
})

test_that("non-list initial errors", {
  scope <- new_scope()
  rv <- shiny::reactiveVal(1)
  expect_error(
    irid:::make_mini_store(rv, rv, scope),
    "fully named list"
  )
})

test_that("unnamed initial errors", {
  scope <- new_scope()
  rv <- shiny::reactiveVal(list("a", "b"))
  expect_error(
    irid:::make_mini_store(rv, rv, scope),
    "fully named list"
  )
})

test_that("partially-named initial errors with the mini-store message", {
  # Without the permissive pre-check, `is_branch` would error first
  # with a generic store-construction message that leaks through to
  # `Each` / `Match` callers.
  scope <- new_scope()
  rv <- shiny::reactiveVal(list(a = 1, 2))
  expect_error(
    irid:::make_mini_store(rv, rv, scope),
    "fully named list"
  )
})

# --- Read / write round-trips ------------------------------------------------

test_that("whole-record write routes through set_record", {
  fix <- new_mini(list(a = 1, b = 2))
  fix$mini(list(a = 10, b = 20))
  flushReact()
  expect_equal(shiny::isolate(fix$parent()), list(a = 10, b = 20))
  expect_equal(shiny::isolate(fix$mini()), list(a = 10, b = 20))
})

test_that("synthetic setter routes through set_record (parent updates)", {
  fix <- new_mini(list(a = 1, b = 2))
  fix$mini$a(99)
  flushReact()
  expect_equal(shiny::isolate(fix$parent()), list(a = 99, b = 2))
  expect_equal(shiny::isolate(fix$mini$a()), 99)
})

test_that("synthetic setter does not bypass set_record", {
  parent <- shiny::reactiveVal(list(a = 1, b = 2))
  writes <- list()
  set_record <- function(v) {
    writes[[length(writes) + 1L]] <<- v
    parent(v)
  }
  mini <- irid:::make_mini_store(
    get_record = parent,
    set_record = set_record,
    scope = new_scope()
  )
  mini$a(7)
  expect_equal(length(writes), 1L)
  expect_equal(writes[[1]], list(a = 7, b = 2))
})

test_that("parent change propagates to leaves", {
  fix <- new_mini(list(a = 1, b = 2))
  # subscribe to leaves so the propagating observer has work to do
  shiny::isolate(fix$mini$a())
  fix$parent(list(a = 5, b = 6))
  flushReact()
  expect_equal(shiny::isolate(fix$mini$a()), 5)
  expect_equal(shiny::isolate(fix$mini$b()), 6)
})

# --- Fine-grained reactivity -------------------------------------------------

test_that("only changed leaves fire on parent patch", {
  fix <- new_mini(list(a = 1, b = 2))
  count_a <- 0L
  count_b <- 0L
  obs_a <- shiny::observe({ fix$mini$a(); count_a <<- count_a + 1L })
  obs_b <- shiny::observe({ fix$mini$b(); count_b <<- count_b + 1L })
  flushReact()
  initial_a <- count_a
  initial_b <- count_b

  fix$parent(list(a = 10, b = 2))
  flushReact()
  expect_equal(count_a - initial_a, 1L)
  expect_equal(count_b - initial_b, 0L)

  obs_a$destroy()
  obs_b$destroy()
})

test_that("synthetic setter only fires the targeted leaf", {
  fix <- new_mini(list(a = 1, b = 2))
  count_a <- 0L
  count_b <- 0L
  obs_a <- shiny::observe({ fix$mini$a(); count_a <<- count_a + 1L })
  obs_b <- shiny::observe({ fix$mini$b(); count_b <<- count_b + 1L })
  flushReact()
  initial_a <- count_a
  initial_b <- count_b

  fix$mini$a(42)
  flushReact()
  expect_equal(count_a - initial_a, 1L)
  expect_equal(count_b - initial_b, 0L)

  obs_a$destroy()
  obs_b$destroy()
})

test_that("identical write does not fire leaf observers", {
  fix <- new_mini(list(a = 1, b = 2))
  count_a <- 0L
  obs_a <- shiny::observe({ fix$mini$a(); count_a <<- count_a + 1L })
  flushReact()
  initial_a <- count_a

  fix$parent(list(a = 1, b = 99))  # a unchanged
  flushReact()
  expect_equal(count_a - initial_a, 0L)

  obs_a$destroy()
})

# --- Fixed-shape rejection ---------------------------------------------------
#
# Mini-store writes are shape-strict — same contract as `reactiveStore`
# branches. A component receiving a `reactiveStore`-classed callable
# sees the same write semantics whether it's a global store or a
# per-item projection. Shape transitions are parent-level operations
# (reshape the slot in the source collection), not local writes.

test_that("write with unknown key errors", {
  fix <- new_mini(list(a = 1, b = 2))
  expect_error(fix$mini(list(a = 1, b = 2, c = 3)),
               "Unknown keys.*c")
})

test_that("write with non-list errors", {
  fix <- new_mini(list(a = 1, b = 2))
  expect_error(fix$mini(42), "named list")
})

test_that("write with unnamed list errors", {
  fix <- new_mini(list(a = 1, b = 2))
  expect_error(fix$mini(list(1, 2)), "named list")
})

test_that("write with missing keys errors", {
  # Mini-store branch writes replace, like reactiveStore — every locked
  # key must be present. Use the per-field setter (`mini$a(v)`) to
  # update a single slot; that path builds the complete record before
  # routing to set_record. Dropping a field is a parent-level operation
  # (write the reshaped collection through the source callable).
  fix <- new_mini(list(a = 1, b = 2))
  expect_error(fix$mini(list(a = 99)), "[Mm]issing.*b")
})

test_that("nested branch write with missing keys errors", {
  fix <- new_mini(list(id = 1L, user = list(name = "Alice", email = "a@x")))
  expect_error(
    fix$mini$user(list(name = "Bob")),
    "[Mm]issing.*'user'.*email"
  )
})

test_that("per-field setter updates one slot, preserving siblings", {
  # The dedicated single-slot write path. Internally builds the
  # complete sub-record from the current isolate before chaining up,
  # so set_record always sees the full record.
  fix <- new_mini(list(id = 1L, user = list(name = "Alice", email = "a@x")))
  fix$mini$user$name("Bob")
  flushReact()
  expect_equal(
    shiny::isolate(fix$parent()),
    list(id = 1L, user = list(name = "Bob", email = "a@x"))
  )
  expect_equal(shiny::isolate(fix$mini$user$email()), "a@x")
})

# --- Scope cleanup -----------------------------------------------------------

test_that("scope$destroy() tears down internal observer", {
  parent <- shiny::reactiveVal(list(a = 1, b = 2))
  scope <- new_scope()
  mini <- irid:::make_mini_store(parent, parent, scope)

  # Force the propagating observer to register a dependency
  shiny::isolate(mini$a())
  flushReact()

  scope$destroy()

  # After destroy, parent changes should not reach leaves
  parent(list(a = 99, b = 2))
  flushReact()
  expect_equal(shiny::isolate(mini$a()), 1)
})

# --- Auto-bind compatibility -------------------------------------------------

test_that("per-field accessor passes is_irid_reactive", {
  fix <- new_mini(list(a = 1))
  expect_true(irid:::is_irid_reactive(fix$mini$a))
})

test_that("mini-store callable passes is_irid_reactive", {
  fix <- new_mini(list(a = 1))
  expect_true(irid:::is_irid_reactive(fix$mini))
})

# --- Nested records (recursive mini-store) -----------------------------------

test_that("nested named lists become sub-mini-stores", {
  fix <- new_mini(list(
    id = 1L,
    user = list(name = "Alice", email = "a@x")
  ))
  expect_s3_class(fix$mini$user, "reactiveStore")
  expect_equal(names(fix$mini$user), c("name", "email"))
})

test_that("nested leaf reads return the initial value", {
  fix <- new_mini(list(user = list(name = "Alice", email = "a@x")))
  expect_equal(shiny::isolate(fix$mini$user$name()), "Alice")
  expect_equal(shiny::isolate(fix$mini$user$email()), "a@x")
})

test_that("nested leaf write chains up to set_record", {
  fix <- new_mini(list(id = 1L, user = list(name = "Alice", email = "a@x")))
  fix$mini$user$name("Bob")
  flushReact()
  expect_equal(
    shiny::isolate(fix$parent()),
    list(id = 1L, user = list(name = "Bob", email = "a@x"))
  )
})

test_that("nested branch write patches whole sub-record via set_record", {
  fix <- new_mini(list(id = 1L, user = list(name = "Alice", email = "a@x")))
  fix$mini$user(list(name = "Bob", email = "b@x"))
  flushReact()
  expect_equal(
    shiny::isolate(fix$parent()),
    list(id = 1L, user = list(name = "Bob", email = "b@x"))
  )
})

test_that("parent change to a nested field propagates only to that leaf", {
  fix <- new_mini(list(id = 1L, user = list(name = "Alice", email = "a@x")))
  c_name <- 0L; c_email <- 0L
  o_name  <- shiny::observe({ fix$mini$user$name();  c_name  <<- c_name  + 1L })
  o_email <- shiny::observe({ fix$mini$user$email(); c_email <<- c_email + 1L })
  flushReact()
  base_name <- c_name; base_email <- c_email

  fix$parent(list(id = 1L, user = list(name = "Bob", email = "a@x")))
  flushReact()
  expect_equal(c_name  - base_name,  1L)
  expect_equal(c_email - base_email, 0L)

  o_name$destroy(); o_email$destroy()
})

test_that("nested unknown-key write errors at the right depth", {
  fix <- new_mini(list(user = list(name = "A", email = "B")))
  expect_error(
    fix$mini(list(user = list(name = "X", phone = "1"))),
    "Unknown keys.*phone"
  )
})

test_that("synthetic setter chain doesn't subscribe writers to the parent", {
  fix <- new_mini(list(user = list(name = "A", email = "B")))
  # Calling the setter from outside any reactive context succeeds —
  # would error if the chain forgot to `isolate` parent reads.
  expect_silent(fix$mini$user$name("X"))
})

# --- Synchronous local update on user write ---------------------------------

# These cover the regression that broke the each_nested example: writes
# through the chain only updated the parent collection; the local leaf
# `rv` updated on the *next* flush via the propagator. The event
# observer's force-send echo runs before that flush, so binding reads
# saw the stale value and the client overwrote the user's typed input.

test_that("leaf write updates the local rv synchronously (before flush)", {
  fix <- new_mini(list(a = 1, b = 2))
  fix$mini$a(99)
  # No flushReact() — read immediately, mid-flight, like force-send does.
  expect_equal(shiny::isolate(fix$mini$a()), 99)
})

test_that("nested leaf write updates the local rv synchronously", {
  fix <- new_mini(list(user = list(name = "A", email = "B")))
  fix$mini$user$name("X")
  expect_equal(shiny::isolate(fix$mini$user$name()), "X")
})

test_that("branch write updates descendant leaves synchronously", {
  fix <- new_mini(list(user = list(name = "A", email = "B")))
  fix$mini$user(list(name = "X", email = "Y"))
  expect_equal(shiny::isolate(fix$mini$user$name()), "X")
  expect_equal(shiny::isolate(fix$mini$user$email()), "Y")
})

test_that("synthetic setter replaces a list field rather than recursing", {
  # Regression: `modifyList` recurses into matching list-shaped values,
  # so writing a length-3 list over a length-2 list silently kept the
  # original two entries. The synthetic setter now uses `[[<-` so the
  # whole field is replaced atomically.
  fix <- new_mini(list(id = 1L, options = list("Red", "Blue")))
  fix$mini$options(list("Red", "Blue", ""))
  flushReact()
  expect_equal(shiny::isolate(fix$mini$options()),
               list("Red", "Blue", ""))
  expect_equal(shiny::isolate(fix$parent())$options,
               list("Red", "Blue", ""))
})

test_that("write at one branch leaves a list-typed sibling untouched", {
  # Regression: Same `modifyList`-recursion bug surfaced as fields
  # disappearing when an unrelated branch was written. After adding to
  # `options`, changing `author$role` (a different sub-tree) silently
  # collapsed `options` back because the chain used `modifyList` to
  # patch the question record at each level.
  fix <- new_mini(list(
    id = 1L,
    author = list(name = "Alice", role = "Admin"),
    options = list("Red", "Blue")
  ))
  fix$mini$options(list("Red", "Blue", ""))
  flushReact()
  fix$mini$author$role("Viewer")
  flushReact()
  expect_equal(shiny::isolate(fix$mini$options()),
               list("Red", "Blue", ""))
  expect_equal(shiny::isolate(fix$mini$author$role()), "Viewer")
})

test_that("synchronous local write does not double-fire on flush", {
  fix <- new_mini(list(a = 1))
  count <- 0L
  obs <- shiny::observe({ fix$mini$a(); count <<- count + 1L })
  flushReact()
  base <- count

  fix$mini$a(99)        # synchronous local write + chained set_record
  flushReact()          # propagator fires, finds identical, short-circuits
  expect_equal(count - base, 1L)

  obs$destroy()
})
