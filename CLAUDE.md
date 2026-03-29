# CLAUDE.md

## Project status

- Greenfield project — no backwards compatibility constraints

## Commit policy

- One-line commit messages unless directed otherwise
- Do not include Co-Authored-By

- If there are uncommitted changes and the user asks for something unrelated to the current work, suggest committing first before switching directions

## Build

- Run `devtools::document()` after changing exports or roxygen comments
- Edit `README.Rmd`, not `README.md`. Run `devtools::build_readme()` after changes to regenerate the md.
