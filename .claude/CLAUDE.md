# CLAUDE.md

## Orientation

- Read `ARCHITECTURE.md` before searching through the project
- Read `TESTING.md` when orienting yourself on testing
- Examples live in `examples/*` and `vignettes/articles/examples.Rmd`

## Project status

- Greenfield project — no backwards compatibility constraints

## Commit policy

- One-line commit messages unless directed otherwise
- Do not include Co-Authored-By

- If there are uncommitted changes and the user asks for something unrelated to the current work, suggest committing first before switching directions

## Code style

- Multi-line R function calls: opening args on a new line after the function name

```r
hist(
  foo,
  bar
)
```

- `R/utils.R` holds small base-R list helpers (`compact`, `every`, ...) for
  predicate-filtering patterns that read worse in base R. Each one matches its
  same-named purrr function's behaviour (so the name is honest, not a
  look-alike) but takes a plain `\(x) ...` predicate, not purrr's `~` formula.
  Only helpers with a real call site live there — if you need
  `keep`/`discard`/`some`/etc., add it to `utils.R` (matching purrr semantics)
  when the use site appears, rather than depending on purrr.

## Build

- Run `devtools::document()` after changing exports or roxygen comments
- Edit `README.Rmd`, not `README.md`. Run `devtools::build_readme()` after changes to regenerate the md.
