flushReact <- function() shiny:::flushReact()

# --- Construction & shape -----------------------------------------------------

test_that("scalar leaf reads its initial value", {
  state <- reactiveStore(list(x = 1))
  expect_equal(shiny::isolate(state$x()), 1)
})

test_that("nested branch leaf reads its initial value", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_equal(shiny::isolate(state$user$name()), "A")
})

test_that("unnamed list at leaf position is stored atomically", {
  todos <- list(list(id = 1), list(id = 2))
  state <- reactiveStore(list(todos = todos))
  expect_equal(shiny::isolate(state$todos()), todos)
})

test_that("empty named list constructs an empty branch", {
  state <- reactiveStore(list(group = list()))
  expect_equal(shiny::isolate(state$group()), list())
})

test_that("mixed-type children at one level work", {
  state <- reactiveStore(list(a = 1, b = "s", c = list(x = 1)))
  expect_equal(
    shiny::isolate(state()),
    list(a = 1, b = "s", c = list(x = 1))
  )
})

test_that("non-list `initial` is rejected", {
  expect_error(reactiveStore(1), "named list")
  expect_error(reactiveStore("hi"), "named list")
})

# --- Leaf read / write --------------------------------------------------------

test_that("leaf write replaces the value", {
  state <- reactiveStore(list(x = 1))
  state$x(2)
  expect_equal(shiny::isolate(state$x()), 2)
})

test_that("leaf write of NULL works (missing(..1) read/write distinction)", {
  state <- reactiveStore(list(x = 1))
  state$x(NULL)
  expect_null(shiny::isolate(state$x()))
})

test_that("leaf accepts type changes (no enforcement)", {
  state <- reactiveStore(list(user = list(name = "A")))
  state$user$name(42)
  expect_equal(shiny::isolate(state$user$name()), 42)
})

# --- Branch read assembles from children --------------------------------------

test_that("branch read returns named list of children", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  expect_equal(
    shiny::isolate(state$user()),
    list(name = "A", email = "B")
  )
})

test_that("root read returns full nested shape", {
  init <- list(user = list(name = "A", email = "B"), n = 1)
  state <- reactiveStore(init)
  expect_equal(shiny::isolate(state()), init)
})

# --- Branch write patches -----------------------------------------------------

test_that("branch write updates only specified keys", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  state$user(list(name = "Bob"))
  expect_equal(
    shiny::isolate(state$user()),
    list(name = "Bob", email = "B")
  )
})

test_that("root patch leaves sibling branches untouched", {
  state <- reactiveStore(list(
    user = list(name = "A"),
    todos = list(list(id = 1))
  ))
  state(list(user = list(name = "Eve")))
  expect_equal(shiny::isolate(state$user$name()), "Eve")
  expect_equal(shiny::isolate(state$todos()), list(list(id = 1)))
})

test_that("empty patch is a no-op", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  state$user(list())
  expect_equal(
    shiny::isolate(state$user()),
    list(name = "A", email = "B")
  )
})

# --- Unknown-key validation ---------------------------------------------------

test_that("branch write with unknown key errors with path and key", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_error(
    state$user(list(name = "B", phone = "x")),
    "'user'.*phone"
  )
})

test_that("root branch write with unknown key errors with root path", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_error(
    state(list(unknown = 1)),
    "root.*unknown"
  )
})

test_that("non-list patch errors with a clear message", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_error(state$user("hello"), "named list")
})

test_that("branch patch with unnamed elements errors", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_error(state$user(list("x")), "named list")
})

# --- Atomic list semantics ----------------------------------------------------

test_that("atomic list write replaces the entire list", {
  state <- reactiveStore(list(todos = list(list(id = 1), list(id = 2))))
  state$todos(list(list(id = 9)))
  expect_equal(shiny::isolate(state$todos()), list(list(id = 9)))
})

test_that("$ traversal into a leaf returns NULL", {
  state <- reactiveStore(list(todos = list(list(id = 1))))
  expect_null(state$todos$id)
})

test_that("deep root patch replaces atomic list wholesale", {
  state <- reactiveStore(list(
    user = list(name = "A"),
    todos = list(list(id = 1), list(id = 2))
  ))
  state(list(todos = list(list(id = 9))))
  expect_equal(shiny::isolate(state$todos()), list(list(id = 9)))
  expect_equal(shiny::isolate(state$user$name()), "A")
})

# --- Identity stability -------------------------------------------------------

test_that("repeated $ access returns the same leaf (identity stable)", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_identical(state$user$name, state$user$name)
  expect_identical(state$user, state$user)
})

test_that("captured leaf reference still works after a branch write", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  node <- state$user$name
  state$user(list(name = "Z"))
  expect_equal(shiny::isolate(node()), "Z")
  node("Q")
  expect_equal(shiny::isolate(state$user$name()), "Q")
})

# --- Path in error messages ---------------------------------------------------

test_that("nested branch path appears in unknown-key errors", {
  state <- reactiveStore(list(
    user = list(address = list(street = "x"))
  ))
  expect_error(
    state$user$address(list(street = "y", zip = "z")),
    "'user\\$address'.*zip"
  )
})

test_that("deep root patch carries the path through to the offending node", {
  state <- reactiveStore(list(
    user = list(address = list(street = "x"))
  ))
  expect_error(
    state(list(user = list(address = list(zip = "z")))),
    "'user\\$address'.*zip"
  )
})

# --- Reactive granularity -----------------------------------------------------

test_that("leaf observer fires only when its leaf changes", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  fired <- 0L
  obs <- shiny::observe({
    state$user$name()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)        # initial run

  state$user$email("C")
  flushReact()
  expect_equal(fired, 1L)        # sibling change does not trigger

  state$user$name("Z")
  flushReact()
  expect_equal(fired, 2L)
  obs$destroy()
})

test_that("branch observer fires on any descendant leaf change", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  fired <- 0L
  obs <- shiny::observe({
    state$user()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)

  state$user$name("Z")
  flushReact()
  expect_equal(fired, 2L)

  state$user$email("Q")
  flushReact()
  expect_equal(fired, 3L)
  obs$destroy()
})

test_that("root observer fires on any leaf change anywhere", {
  state <- reactiveStore(list(user = list(name = "A"), n = 1))
  fired <- 0L
  obs <- shiny::observe({
    state()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)

  state$n(2)
  flushReact()
  expect_equal(fired, 2L)

  state$user$name("Z")
  flushReact()
  expect_equal(fired, 3L)
  obs$destroy()
})

test_that("branch write of multiple leaves results in a single flush", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  fired <- 0L
  obs <- shiny::observe({
    state$user$name()
    state$user$email()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)

  state$user(list(name = "Z", email = "Q"))
  flushReact()
  expect_equal(fired, 2L)        # one flush, not two
  obs$destroy()
})
