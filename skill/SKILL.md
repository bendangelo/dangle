---
name: dangle-plans
description: >
  Use when writing implementation plans for dangle (the overnight plan runner), or when
  preparing a repository's existing plans for it: numbering them in run order, splitting
  large ones, marking dependencies, and retiring plans that are already done.
---

# Plans for dangle

dangle runs every `*.md` file directly in the plans folder (`PLANS=` in `.dangle/config`;
`dangle doctor` prints it), one at a time: the first plan in filename order whose
dependencies have landed, again and again. Each plan gets a fresh
worktree from the base branch, an agent implements it, the gate checks it, and only then
does it land. Subfolders are inactive: `done/` holds landed plans, and any other subfolder
(`hold/`, `drafts/`) parks a plan.

## Writing a plan

- **File name:** `NNN-short-name.md`, or with a date `YYYY-MM-DD-NNN-short-name.md`. The number
  is the id (`dangle 865`), and the order of the names is the run order. Use the next free
  number; leave gaps when you might insert plans later. `dangle --dry-run` prints the order.
- **One goal.** A plan is one change a single agent session can finish: about 3 to 8 files.
  Two goals make two plans. Aim for 100 to 300 lines (`MAX_LINES`, warned by `dangle lint`).
- **Header** (optional), on one line under the title:
  `<!-- dangle: depends=863,864 agent=claude:sonnet -->`. `depends` makes dangle skip the plan
  until those plans landed; `agent` picks the agent for a hard plan (a command-line `-a` wins).
- **Write for the agent that runs it, not for you.** It starts cold: name the files, the
  functions, the commands and the tests. Say what "done" is.
- **`Done when:`** a line such as ``Done when: `cargo test payroll` `` gives a command dangle runs
  after the gate; the plan only lands when it passes.
- **No landing steps.** Never tell the agent to merge, push, rebase, switch branches, or move
  the plan: dangle does that.
- **Split rather than grow.** If a plan passes ~300 lines, or needs "and also", split it and
  chain the parts with `depends=`.
- The plan must be **committed on the base branch** before a run: a worktree only sees
  committed files.

## Preparing an existing repository

1. Run `dangle init` if `.dangle/` is missing, and check `.dangle/hooks/gate` really checks.
2. List the plans folder. For each plan, decide from the code and `git log` whether it is
   already done; move done ones to `done/` with `git mv`.
3. Park plans that need a human decision in `hold/`.
4. Put the rest in dependency order, and rename them `NNN-name.md` (keep a leading date if
   the repository uses one), with gaps of 10 so later plans fit between.
5. Split any plan over ~300 lines or with more than one goal; add `depends=` lines.
6. Run `dangle lint` and `dangle --dry-run`; commit the plans.

## Running

- `dangle` runs everything; `dangle 865 870` runs only those; `dangle 865 --rest` runs 865 first,
  then the rest. `-a claude:haiku` picks the agent for this run.
- One plan runs at a time. For more, start a second `dangle` in another terminal: runners
  claim plans, skip what another one runs, and wait for a dependency another one is running.
- `dangle status` shows what is ready, waiting, running or failed. A failed plan keeps its
  worktree: `dangle 866` continues it, `--fresh` starts it over, `dangle land 866` lands it
  after you fixed it by hand.
