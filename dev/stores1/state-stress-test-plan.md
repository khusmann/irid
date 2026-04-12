# Plan: Stress-test irid's state primitives with realistic examples

## Purpose

This task produces implementations of three realistic irid example apps. The
goal is to see how irid's existing state primitives (`reactiveVal`, `reactive`,
`Each`, `Index`, `When`) hold up as app complexity grows — particularly around
operations that touch many pieces of state at once (reset, snapshot for save,
load from a saved draft, passing related state through child components).

The output will be used to evaluate how irid's state primitives feel under
realistic load. Your job is to produce the cleanest, most idiomatic
implementations you can using the primitives that exist today. Do not invent new
primitives or abstractions.

**Important:** write the code the way you would if these were going to ship as
example apps. Not throwaway sketches, not strawmen — the cleanest version you
can write with the tools available.

## Orientation

Before writing anything:

1. Read `ARCHITECTURE.md` for an overview of irid's reactive model and what
   primitives exist.
2. Read `examples/todo.R` carefully. This is the canonical pattern for
   state-heavy irid apps and your code should follow its style.
3. Skim `examples/cards.R`, `examples/temperature.R`, and `examples/composing.R`
   for smaller patterns around component composition and reactive wiring.
4. Note the code style rules in `CLAUDE.md` — in particular the multi-line
   function call convention.

## What to build

Write three `.R` files in `dev/stores`. They do not need to run, but they should
be syntactically plausible R and stylistically consistent with
`examples/todo.R`. Do not stub render code with `...` unless it is genuinely
repetitive — write enough of the real rendering to show how state actually flows
into components.

Each file gets a header comment describing what the app does and what state it
manages.

---

### Example 1 — Multi-step wizard form

**File:** `dev/stores/state-example-wizard.R`

A four-step signup form.

**State:**

- Current step (1 through 4).
- Step 1 (account): username, email, password, confirm_password.
- Step 2 (profile): display_name, bio, avatar_url, timezone.
- Step 3 (preferences): theme, language, email_notifications, sms_notifications,
  newsletter.
- Step 4 (review): no new fields — reads everything from steps 1-3 and displays
  it as read-only text for confirmation.

**Operations:**

- `next_step()` / `prev_step()` — advance/retreat, disabled at bounds.
- `reset()` — clear every field back to defaults and return to step 1.
- `submit()` — assemble the full state into a single nested list and hand it to
  a stub `post_to_server(payload)` function.
- `load_draft(saved)` — given a nested list matching the shape of the form
  (possibly partial), populate the form fields from it. This simulates restoring
  a partially-filled draft from localStorage.

**Rendering:**

- One component per step: `Step1Account`, `Step2Profile`, `Step3Preferences`,
  `Step4Review`. Each step component should receive only the state it needs, not
  the entire app state.
- A progress indicator at the top showing the current step.
- Next/Previous/Submit buttons at the bottom.

**Pay attention to:** how `reset()` is wired up; what `Step2Profile`'s function
signature looks like; how the review step reads all the earlier state; what
`submit()` and `load_draft()` look like end-to-end.

---

### Example 2 — Dashboard filter panel with saved presets

**File:** `dev/stores/state-example-filters.R`

A filter bar driving a results view, with named preset support.

**State:**

- `date_from`, `date_to` — date strings.
- `category` — character vector (multi-select).
- `search` — text.
- `sort_by` — one of "date", "name", "priority".
- `sort_dir` — "asc" or "desc".
- `page` — integer.
- `presets` — a list of saved preset objects, each shaped like
  `list(name = "...", filters = <snapshot of the filter fields>)`.

**Operations:**

- `reset_filters()` — restore all filter fields to defaults. Does not touch the
  presets list.
- `current_filters()` — read all the filter fields into one list for
  serialization.
- `save_preset(name)` — capture the current filters and append a new preset with
  that name.
- `load_preset(name)` — find the named preset and apply its filters.
- `delete_preset(name)`.
- `share_url()` — produce a URL query string from `current_filters()`. The
  encoding can be a stub — what matters is that it reads all the filter fields.

**Rendering:**

- A `FilterBar` component containing all the filter controls.
- A `PresetList` component showing preset buttons: clicking a preset loads it,
  an X button deletes it.
- A derived `results_count` reactive returning a fake count based on the filter
  state (e.g. `length(category) * 10 + page` — it just needs to re-derive when
  any filter changes).
- A results panel can be a stub that pretty-prints `current_filters()` and the
  count. The point is showing reactivity, not real data.

**Pay attention to:** what `current_filters()` looks like, what `load_preset()`
looks like, what `reset_filters()` looks like, what argument(s) `FilterBar`
takes.

---

### Example 3 — Survey authoring tool

**File:** `dev/stores/state-example-survey.R`

A form designer where the user builds a survey question-by-question and sees a
live preview of it on the right.

**State:**

- `title` — survey title.
- `description` — survey description.
- `questions` — a list of question objects, each with:
  - `id` — integer.
  - `type` — one of "text", "number", "choice".
  - `label` — question text.
  - `required` — boolean.
  - `config` — a nested list of type-specific settings:
    - text: `list(placeholder, max_length)`
    - number: `list(min, max, step)`
    - choice: `list(options = character_vector, allow_multiple)`
- `selected_id` — the id of the question currently being edited, or NULL if
  none.

**Operations:**

- `add_question(type)` — append a new question with default values for the given
  type.
- `remove_question(id)`.
- `move_up(id)`, `move_down(id)` — reorder within the list.
- `select_question(id)` — mark a question as the one being edited and populate
  the center-pane edit form with its current values.
- `save_edit()` — write the edit form's current values back to the question in
  the list.
- `cancel_edit()` — discard the edit form's changes and clear selection.

**Rendering:**

Three panes side-by-side:

- **Left pane:** the question list. Each row shows the label and has
  add-above/move-up/move-down/remove buttons. An "add question" dropdown at the
  bottom creates a new question of a chosen type.
- **Center pane:** the edit form for the currently-selected question. The form
  must show fields appropriate to the question's type: text questions have
  placeholder and max_length inputs, number questions have min/max/step, choice
  questions have an options editor (with add/remove buttons for individual
  options) and an allow_multiple checkbox. A Save and Cancel button at the
  bottom.
- **Right pane:** a live preview of the whole survey, rendering each question as
  an actual HTML input (`tags$input`, `tags$select`, etc.) based on its type and
  config.

The type-specific form section and the preview rendering for choice questions
should be their own components (`ChoiceEditor`, `ChoicePreview`).

**Pay attention to:** how the edit form is populated when `selected_id` changes;
how `save_edit()` writes back; how you represent the in-progress edit state (one
reactiveVal? several?); what happens if the user selects a different question
without saving first — does old state leak; what `ChoiceEditor` takes as its
argument(s); whether the live preview pulls from the question list, from the
edit form, or both.

---

## Design constraints

1. **Use only existing irid primitives.** `reactiveVal`, `reactive`, `Each`,
   `Index`, `When`, `tags$*`. Do not invent new abstractions or helper wrappers.
   If you find yourself wishing for something that doesn't exist, write it the
   long way and leave a `# NOTE:` comment describing what you wanted.

2. **Avoid the single-giant-reactiveVal anti-pattern.** Putting the entire app
   state into one `reactiveVal(list(...))` loses granularity — any change
   invalidates every reader. Use loose `reactiveVal`s for distinct pieces of
   state, the way `examples/todo.R` does. Nested lists _inside_ a leaf
   reactiveVal are fine when the contents are logically atomic (like the todos
   list in `examples/todo.R`); they are not fine as a substitute for decomposing
   unrelated state.

3. **Write idiomatic, clean code.** These should look like code you would be
   willing to ship as example apps. Extract helpers where they earn their keep,
   name things clearly, follow the style of `examples/todo.R` and the
   `CLAUDE.md` conventions.

4. **Do not try to run the code or set up tests.** These are read-only
   comparisons. Syntactic plausibility is enough.

5. **One file per example.** Do not share code between files — each file should
   be self-contained so each can be read independently.

## What to return

After writing all three files, return a short report (under 400 words) covering:

- **Friction points, per example.** For each of the three apps, name one or two
  places where the code felt like more work than the problem deserved — where
  you wrote the same field name six times, where you had to plumb a bag of
  reactiveVals through a component signature, where reset/load/snapshot felt
  mechanical and repetitive, where component composition felt awkward. Be
  specific and point at line numbers.

- **`# NOTE:` comments.** List any comments you left behind flagging missing
  abstractions or things you wished existed.

- **Which example felt cleanest and which felt ugliest**, and why in one
  sentence each.

- **Any existing primitive that surprised you** — positively or negatively — in
  how it handled the load.

Do **not** propose solutions, new primitives, or design changes in the report.
Describe the friction as you experienced it and stop there. A later pass will
compare these implementations against an alternative and decide what, if
anything, to change.
