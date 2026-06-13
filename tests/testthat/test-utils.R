test_that("compact drops zero-length elements, preserving names (purrr semantics)", {
  expect_equal(compact(list(a = 1, b = NULL, c = 3)), list(a = 1, c = 3))
  expect_equal(compact(list(1, NULL, 2)), list(1, 2))
  # empty vectors are zero-length too, so they drop as well
  expect_equal(compact(list(a = 1, b = character(0), c = NULL)), list(a = 1))
  expect_equal(compact(list()), list())
  expect_equal(compact(list(a = 1, b = 2)), list(a = 1, b = 2))
})

test_that("every checks a predicate over all elements (purrr semantics)", {
  expect_true(every(list(2, 4, 6), \(x) x %% 2 == 0))
  expect_false(every(list(2, 3, 6), \(x) x %% 2 == 0))
  expect_true(every(list(), \(x) FALSE)) # vacuously true
  # NA / non-TRUE results count as FALSE
  expect_false(every(list(1, NA_real_), \(x) x > 0))
})
