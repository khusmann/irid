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

test_that("empty list() at a leaf position is a leaf", {
  state <- reactiveStore(list(todos = list()))
  expect_true(inherits(state$todos, "reactiveLeaf"))
  expect_false(inherits(state$todos, "reactiveStore"))
  expect_equal(shiny::isolate(state$todos()), list())
})

test_that("setNames(list(), character(0)) is also a leaf", {
  state <- reactiveStore(list(group = setNames(list(), character(0))))
  expect_true(inherits(state$group, "reactiveLeaf"))
  expect_false(inherits(state$group, "reactiveStore"))
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

test_that("unnamed list at root is rejected", {
  expect_error(reactiveStore(list("a", "b")), "named list")
})

test_that("partially-named list at root errors with positions", {
  expect_error(
    reactiveStore(list(a = 1, "b")),
    "store root.*partially named.*positions 2"
  )
})

test_that("partially-named list inside a branch errors with path", {
  expect_error(
    reactiveStore(list(group = list(a = 1, "b"))),
    "'group'.*partially named.*positions 2"
  )
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

# --- List-leaf semantics ------------------------------------------------------

test_that("list leaf write replaces the entire value", {
  state <- reactiveStore(list(todos = list(list(id = 1), list(id = 2))))
  state$todos(list(list(id = 9)))
  expect_equal(shiny::isolate(state$todos()), list(list(id = 9)))
})

test_that("$ on a leaf errors with a hint pointing at leaf()$name", {
  state <- reactiveStore(list(todos = list(list(id = 1))))
  expect_error(state$todos$id, "leaf\\(\\)\\$id")
})

test_that("list leaf accepts any-shape write (no validation)", {
  state <- reactiveStore(list(todos = list(list(id = 1), list(id = 2))))
  state$todos(list())
  expect_equal(shiny::isolate(state$todos()), list())
  state$todos(list(a = 1, b = 2))
  expect_equal(shiny::isolate(state$todos()), list(a = 1, b = 2))
  state$todos("loading")
  expect_equal(shiny::isolate(state$todos()), "loading")
  state$todos(NULL)
  expect_null(shiny::isolate(state$todos()))
})

test_that("observer reading a list leaf fires on write", {
  state <- reactiveStore(list(todos = list(list(id = 1))))
  fired <- 0L
  obs <- shiny::observe({
    state$todos()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)

  state$todos(list(list(id = 2)))
  flushReact()
  expect_equal(fired, 2L)

  state$todos(list())
  flushReact()
  expect_equal(fired, 3L)
  obs$destroy()
})

test_that("deep root patch replaces list leaf wholesale", {
  state <- reactiveStore(list(
    user = list(name = "A"),
    todos = list(list(id = 1), list(id = 2))
  ))
  state(list(todos = list(list(id = 9))))
  expect_equal(shiny::isolate(state$todos()), list(list(id = 9)))
  expect_equal(shiny::isolate(state$user$name()), "A")
})

# --- Classed lists are opaque leaves -----------------------------------------

test_that("data.frame initial is stored as a leaf, class preserved", {
  df <- data.frame(x = 1:3, y = c("a", "b", "c"), stringsAsFactors = FALSE)
  state <- reactiveStore(list(df = df))
  expect_true(inherits(state$df, "reactiveLeaf"))
  expect_false(inherits(state$df, "reactiveStore"))
  expect_equal(shiny::isolate(state$df()), df)
})

test_that("data.frame leaf accepts data.frame writes without shape validation", {
  state <- reactiveStore(list(df = data.frame(x = 1:3)))
  new_df <- data.frame(x = 4:6, y = 7:9)
  state$df(new_df)
  expect_equal(shiny::isolate(state$df()), new_df)
})

test_that("data.frame is not navigated into via $", {
  state <- reactiveStore(list(df = data.frame(x = 1:3)))
  expect_error(state$df$x, "leaf\\(\\)\\$x")
})

test_that("tibble (if installed) is stored opaquely as a leaf", {
  skip_if_not_installed("tibble")
  tb <- tibble::tibble(x = 1:3, y = c("a", "b", "c"))
  state <- reactiveStore(list(tb = tb))
  expect_equal(shiny::isolate(state$tb()), tb)
  expect_true(inherits(shiny::isolate(state$tb()), "tbl_df"))
})

test_that("classed list leaf accepts arbitrary replacement (types not enforced)", {
  state <- reactiveStore(list(df = data.frame(x = 1:3)))
  state$df("not a df anymore")
  expect_equal(shiny::isolate(state$df()), "not a df anymore")
})

test_that("nested classed list leaf survives a branch patch", {
  state <- reactiveStore(list(view = list(df = data.frame(x = 1:3), n = 1L)))
  new_df <- data.frame(x = 10:12)
  state$view(list(df = new_df))
  expect_equal(shiny::isolate(state$view$df()), new_df)
  expect_equal(shiny::isolate(state$view$n()), 1L)
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

# --- Atomic patches (validate-then-commit) -----------------------------------

test_that("root patch rejects deep unknown key without committing siblings", {
  state <- reactiveStore(list(
    user = list(name = "A"),
    settings = list(theme = "dark")
  ))
  expect_error(
    state(list(
      user = list(name = "Bob"),
      settings = list(unknown = "x")
    )),
    "'settings'.*unknown"
  )
  expect_equal(shiny::isolate(state$user$name()), "A")
  expect_equal(shiny::isolate(state$settings$theme()), "dark")
})

test_that("nested branch patch validates whole subtree before committing", {
  state <- reactiveStore(list(
    a = list(x = 1, y = 2),
    b = list(z = "z")
  ))
  expect_error(
    state(list(
      a = list(x = 10, y = 20),
      b = list(unknown = "x")
    )),
    "'b'.*unknown"
  )
  expect_equal(shiny::isolate(state$a$x()), 1)
  expect_equal(shiny::isolate(state$a$y()), 2)
  expect_equal(shiny::isolate(state$b$z()), "z")
})

test_that("failed atomic patch produces no reactive flush", {
  state <- reactiveStore(list(
    user = list(name = "A"),
    settings = list(theme = "dark")
  ))
  fired <- 0L
  obs <- shiny::observe({
    state()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)
  try(
    state(list(
      user = list(name = "Bob"),
      settings = list(unknown = "x")
    )),
    silent = TRUE
  )
  flushReact()
  expect_equal(fired, 1L)
  obs$destroy()
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

# --- names / length on a branch ----------------------------------------------

test_that("names() returns top-level keys in construction order", {
  state <- reactiveStore(list(b = 1, a = 2, c = 3))
  expect_equal(names(state), c("b", "a", "c"))
})

test_that("length() matches names()", {
  state <- reactiveStore(list(b = 1, a = 2, c = 3))
  expect_equal(length(state), 3L)
})

test_that("names() on a nested branch returns its keys", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  expect_equal(names(state$user), c("name", "email"))
  expect_equal(length(state$user), 2L)
})

test_that("reading length() does not subscribe to leaf changes", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  fired <- 0L
  obs <- shiny::observe({
    length(state)
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)
  state$user$name("Z")
  flushReact()
  expect_equal(fired, 1L)
  obs$destroy()
})

# --- [[ on a branch ----------------------------------------------------------

test_that("[[ string is identical to $", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_identical(state[["user"]], state$user)
  expect_identical(state$user[["name"]], state$user$name)
})

test_that("[[ integer matches the keyed access", {
  state <- reactiveStore(list(user = list(name = "A"), n = 1))
  expect_identical(state[[1L]], state$user)
  expect_identical(state[[2L]], state$n)
  expect_identical(state[[1L]], state[[names(state)[1]]])
})

test_that("[[ accepts numeric and coerces to integer", {
  state <- reactiveStore(list(user = list(name = "A"), n = 1))
  expect_identical(state[[1.0]], state$user)
})

test_that("[[ rejects non-integer numeric indices", {
  state <- reactiveStore(list(user = list(name = "A"), n = 1))
  expect_error(state[[1.5]], "integer index")
})

test_that("[[ with out-of-range integer errors", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_error(state[[99L]], "out of range")
  expect_error(state[[0L]], "out of range")
  expect_error(state[[NA_integer_]], "out of range")
})

test_that("[[ with unknown string key errors", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_error(state[["nope"]], "Unknown key 'nope'")
})

test_that("[[ with NA_character_ errors", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_error(state[[NA_character_]], "single key")
})

test_that("[[ on a leaf returns the callable, not the value", {
  state <- reactiveStore(list(user = list(name = "A")))
  leaf <- state$user[["name"]]
  expect_true(is.function(leaf))
  expect_equal(shiny::isolate(leaf()), "A")
})

# --- [[<- ; as.list returns callables ----------------------------------------

test_that("[[<- on a branch errors with a hint", {
  state <- reactiveStore(list(user = list(name = "A")))
  expect_error(
    state$user[["name"]] <- "X",
    "store\\$key\\(value\\)"
  )
})

test_that("as.list returns the named list of child callables", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  out <- as.list(state$user)
  expect_equal(names(out), c("name", "email"))
  expect_identical(out$name, state$user$name)
  expect_identical(out$email, state$user$email)
})

# --- Iteration via lapply / imap --------------------------------------------

test_that("lapply on a branch yields a named list of callables", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  out <- lapply(state$user, identity)
  expect_equal(names(out), c("name", "email"))
  expect_identical(out$name, state$user$name)
  expect_identical(out$email, state$user$email)
})

test_that("lapply that resolves callables matches branch read", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  values <- lapply(state$user, function(f) shiny::isolate(f()))
  expect_equal(values, shiny::isolate(state$user()))
})

test_that("purrr::imap iterates a branch directly", {
  skip_if_not_installed("purrr")
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  out <- purrr::imap(state$user, function(field, key) {
    list(key = key, is_fn = is.function(field), value = shiny::isolate(field()))
  })
  expect_equal(out$name$key, "name")
  expect_true(out$name$is_fn)
  expect_equal(out$name$value, "A")
  expect_equal(out$email$value, "B")
})

# --- Reactivity inside iteration --------------------------------------------

test_that("observer reading one field via iterated callable subscribes only to that leaf", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  fields <- lapply(state$user, identity)
  fired <- 0L
  obs <- shiny::observe({
    fields$name()
    fired <<- fired + 1L
  })
  flushReact()
  expect_equal(fired, 1L)

  state$user$email("X")    # sibling
  flushReact()
  expect_equal(fired, 1L)

  state$user$name("Y")     # tracked leaf
  flushReact()
  expect_equal(fired, 2L)
  obs$destroy()
})

# --- print / str smoke tests -------------------------------------------------

test_that("print(branch) lists every top-level key", {
  state <- reactiveStore(list(user = list(name = "A"), todos = list(list(id = 1))))
  out <- capture.output(print(state))
  expect_true(any(grepl("user", out)))
  expect_true(any(grepl("todos", out)))
})

test_that("print(leaf) shows the current value for scalars", {
  state <- reactiveStore(list(x = 42))
  out <- capture.output(print(state$x))
  expect_true(any(grepl("42", out)))
})

test_that("print(leaf) abbreviates list-valued leaves", {
  state <- reactiveStore(list(todos = list(list(id = 1), list(id = 2))))
  out <- capture.output(print(state$todos))
  expect_true(any(grepl("list", out)))
})

test_that("print(leaf) shows rows x cols for data.frame", {
  state <- reactiveStore(list(df = data.frame(x = 1:3, y = 4:6)))
  out <- capture.output(print(state$df))
  expect_true(any(grepl("3 x 2", out)))
})

test_that("print(leaf) shows dims for matrices and arrays", {
  state <- reactiveStore(list(m = matrix(1:6, nrow = 2, ncol = 3)))
  out <- capture.output(print(state$m))
  expect_true(any(grepl("2 x 3", out)))
})

test_that("str(branch) is non-empty and shows nested keys", {
  state <- reactiveStore(list(user = list(name = "A", email = "B")))
  out <- capture.output(str(state))
  expect_gt(length(out), 1L)
  expect_true(any(grepl("user", out)))
  expect_true(any(grepl("name", out)))
})

test_that("str(branch) does not error on list-valued leaves", {
  state <- reactiveStore(list(todos = list(list(id = 1))))
  expect_no_error(capture.output(str(state)))
})

# --- Leaf error stubs --------------------------------------------------------

test_that("[[ on a leaf errors and points at Each / leaf()", {
  state <- reactiveStore(list(todos = list(list(id = 1))))
  expect_error(state$todos[[1L]], "Each|leaf\\(\\)")
})

test_that("length() on a leaf returns 1 (callable-as-singular)", {
  # No custom `length.reactiveLeaf` — leaves inherit reactiveVal's default
  # length-1 behavior. htmltools' `dropNullsOrEmpty` calls `length()` on
  # every attribute value, so a throwing length method would prevent
  # `value = state$leaf` from surviving tag construction.
  state <- reactiveStore(list(todos = list(list(id = 1))))
  expect_equal(length(state$todos), 1L)
})

test_that("names() on a leaf errors with a hint", {
  state <- reactiveStore(list(todos = list(list(id = 1))))
  expect_error(names(state$todos), "names\\(leaf\\(\\)\\)")
})

# --- I() opt-out: bare named lists as leaves --------------------------------

test_that("I()-wrapped named list at construction becomes a leaf", {
  state <- reactiveStore(list(filter = I(list(foo = 1, bar = 2))))
  expect_true(inherits(state$filter, "reactiveLeaf"))
  expect_false(inherits(state$filter, "reactiveStore"))
})

test_that("I()-wrapped value strips AsIs class on read", {
  state <- reactiveStore(list(filter = I(list(foo = 1, bar = 2))))
  val <- shiny::isolate(state$filter())
  expect_equal(val, list(foo = 1, bar = 2))
  expect_false(inherits(val, "AsIs"))
  expect_null(oldClass(val))
})

test_that("I()-wrapped leaf accepts any-shape writes (union types)", {
  state <- reactiveStore(list(req = I(list(status = "loading"))))
  state$req(list(status = "success", data = 1:3))
  expect_equal(
    shiny::isolate(state$req()),
    list(status = "success", data = 1:3)
  )
  state$req(list(status = "error", message = "boom"))
  expect_equal(
    shiny::isolate(state$req()),
    list(status = "error", message = "boom")
  )
  state$req(NULL)
  expect_null(shiny::isolate(state$req()))
})

test_that("I(list()) gives a shape-flexible empty leaf (df-or-list pattern)", {
  state <- reactiveStore(list(data = I(list())))
  expect_true(inherits(state$data, "reactiveLeaf"))
  state$data(data.frame(x = 1:3))
  expect_equal(shiny::isolate(state$data()), data.frame(x = 1:3))
  state$data(list(a = 1, b = 2))
  expect_equal(shiny::isolate(state$data()), list(a = 1, b = 2))
})

test_that("I() preserves underlying class while stripping AsIs", {
  df <- data.frame(x = 1:3)
  state <- reactiveStore(list(df = I(df)))
  val <- shiny::isolate(state$df())
  expect_s3_class(val, "data.frame")
  expect_false(inherits(val, "AsIs"))
})

test_that("I()-wrapped value at root patch reaches the leaf", {
  state <- reactiveStore(list(filter = I(list(foo = 1))))
  state(list(filter = list(bar = 2, baz = 3)))
  expect_equal(shiny::isolate(state$filter()), list(bar = 2, baz = 3))
})
