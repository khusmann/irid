# CLAUDE.md

## Orientation

- Read `ARCHITECTURE.md` before searching through the project
- Read `TESTING.md` for suite layout and how to run tests; the behavior spec
  lives in the test files under `tests/testthat/`
- Examples live in `examples/*` and `vignettes/articles/examples.Rmd`

## Project status

- Greenfield project — no backwards compatibility constraints

## Commit policy

- One-line commit messages unless directed otherwise
- Do not include Co-Authored-By
- Do not add "created with Claude"-type attribution to commits, issues, or PRs
- Do not hard-wrap (e.g. at 80 chars) issue or PR descriptions — let them flow

- If there are uncommitted changes and the user asks for something unrelated to the current work, suggest committing first before switching directions

<important if="the task involves design work — authoring or revising a design doc, or a design that depends on third-party runtime behavior or framework internals">

## Design workflow

- When a design leans on third-party runtime behavior (event timing, framework
  internals), settle it with a small **throwaway spike** that prints verdicts and
  have the user run it — don't assert the behavior from memory. Spikes live in
  `dev/spikes/` (build-ignored).
- Pin the spike's dependency version in the design doc and note it as a
  re-confirm-on-bump caveat.
- Design docs are the **handoff artifact**: fold spike results back in (resolving
  the doc's open questions) so implementation can start in a fresh context from
  the doc alone. Commit incrementally on a feature branch, one concept per commit.

</important>

## Code style

- Multi-line R function calls: opening args on a new line after the function name

```r
hist(
  foo,
  bar
)
```

## Comments

- Describe the code as it is, not its history. Don't explain absent features or
  rejected alternatives ("we don't use X because...", "removed Y", etc.).
- Rationale for the *current* design is fine — why it works this way, not why
  it isn't something else.

## Build

- Run `devtools::document()` after changing exports or roxygen comments
- Edit `README.Rmd`, not `README.md`. Run `devtools::build_readme()` after changes to regenerate the md.
