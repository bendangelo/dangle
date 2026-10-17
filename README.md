# dangle

A carrot on a stick for your coding agent. Write plans during the day, and dangle works
through them overnight: each plan gets its own git worktree, your agent implements it, your
gate checks it, and only what passes lands.

```
   o
    \
     \_______________________
                             |
                             |
                             ?        1. You write plans. dangle holds out the stick.

  [========o.....................)  4/12   2. Overnight, the agent chases plan after plan.

        \|/
       \\|//
       .-'-.
       |   |
       |   |       10 landed           3. The gate passes, the plan lands: carrot.
        \ /
         V
```

It is one POSIX shell script. It needs `git` and an agent CLI, and it works with any language,
any agent ([Claude Code](https://claude.com/claude-code) by default,
[Codex](https://github.com/openai/codex), [opencode](https://opencode.ai),
[pi](https://github.com/badlogic/pi-mono), or your own command) and any way of landing
(straight onto a branch, or through pull requests and CI).

**Made for [superpowers](https://github.com/obra/superpowers).** Superpowers' brainstorming and
writing-plans skills write plans to `docs/superpowers/plans/`, which is where dangle looks
first. Use a strong model during the day to brainstorm and write the plans, then let dangle
run them overnight. It also works with plans from anywhere else: they are just Markdown files.

## Install

```sh
mise use -g github:bendangelo/dangle@0.1.11
# (plain `github:bendangelo/dangle` works too, once a release is a day old: mise's
#  minimum_release_age)
# or
curl -fsSL https://raw.githubusercontent.com/bendangelo/dangle/main/install.sh | sh
```

Or copy `bin/dangle` anywhere on your `PATH`.

## Start

```sh
cd your-repo
dangle init              # writes .dangle/ with a gate for your language; read it
dangle skill             # teaches your agents how to write plans for dangle
dangle doctor --agent    # checks the setup and that the agent answers
dangle --dry-run         # what would run
dangle                   # run it
```

## Plans

A plan is a Markdown file in the plans folder (`docs/superpowers/plans`, `docs/plans` or
`plans`, or `PLANS=` in the config). Every `*.md` directly in it is active; subfolders are
inactive (`done/` holds landed plans, `hold/` parks one). dangle runs the first plan, in
filename order, whose dependencies have landed, and again until none is left: filename order,
except that a plan never runs before what it `depends=` on.

```markdown
# Payroll: employee master file
<!-- dangle: depends=863,864 agent=claude:sonnet -->

Goal, files, steps, tests...

Done when: `cargo test payroll_employee`
```

- The id is the plan's number: `2026-10-14-865-name.md` and `865-name.md` are both `865`. A plan
  without a number goes by its name after the date, and its first words work too: `shop-A1`
  names `2026-10-12-shop-A1-report-links.md` (never `shop-A10-…`), on the command line and in
  `depends=`.
- `depends=` holds a plan back until those plans have landed (a dependency that fails holds it
  for the night). `agent=` picks the agent for it.
- `Done when:` is a command dangle runs after the gate; the plan lands only when it passes.
- **Private plans:** if git ignores the plans folder (a public repository whose plans stay
  out of it), dangle copies the plans into each worktree, never commits them, and moves a
  landed plan to `done/` on disk.
- Keep plans small: one goal, one session, a few hundred lines at most (`dangle lint` warns).
  The skill from `dangle skill` tells your agents all of this, and how to tidy a repository's
  existing plans into this shape.

## Running

```sh
dangle                         # every active plan, in order
dangle 865 870                 # only these, in this order, then stop
dangle 865 --rest              # 865 first, then everything else
dangle -a claude:haiku         # pick the agent for this run
dangle -a opus                 # the default agent with another model
dangle status                  # ready, waiting, running, kept, submitted
dangle 866                     # continue a failed plan in its kept worktree (--fresh: start over)
dangle --watch                 # never run out: wait for new plans when the queue is empty
```

A run of every active plan (no ids, or `--rest`) looks at the plans folder again before each
plan: a plan you write and commit while dangle runs is **picked up** and joins the end of the
queue (still never before what it `depends=` on). An uncommitted plan waits until you commit
it; a private plan, until it has not changed for a minute. With `--watch`, an empty queue, or
one blocked by a failed plan, waits for more (every `DANGLE_POLL` seconds, default 30) instead
of ending the run; Ctrl-C ends it and writes the summary.

While an agent or the gate runs, a line every 5 minutes says how long it has run and what it
printed last (`HEARTBEAT=5m`, `0` turns it off):

```
  865  Payroll: employee master file
  agent  pi:ollama-local/qwen3.8:latest  (log .git/dangle/logs/865.log)
  ...    agent 5m  │ Compiling operations v0.1.0
  ...    agent 10m  │ test payroll::employees::tests::creates ... ok
  gate   running (log .git/dangle/logs/865.gate.log)
  ...    gate 5m  │ gate: test passed in 115.7s
  land   3e25cb7 on dev (pushed to origin)
```

For each plan dangle creates the worktree `.worktrees/plan-<id>` from the base branch, runs
the agent, commits anything it left uncommitted, merges the base branch in, moves the plan to
`done/` in the branch, and runs the gate. A failed gate gets one fix-up run of the agent
(`FIXES=`) with the gate's output. Then, under a lock, it lands: squashes the branch onto the
base branch and pushes it. A plan that fails keeps its worktree for you to look at.

A merge of the base branch that conflicts does not end the plan. Where both sides only added
lines at the same place (two plans adding to one list, `match` or doc section), dangle keeps
both, the base's lines first, and the gate checks the result (unless the base also added one of
the branch's lines to that file, which would list it twice). Any other conflict goes to the
agent with `merge-prompt.md`, which spends one of the `FIXES`; it counts only when the merge is
committed with no conflict marker left, and is undone otherwise. A conflict found while landing
lets go of the lock first, so no other landing waits on the agent, and the gate runs again
before the branch lands. `dangle land` by hand settles the added-lines kind too and leaves any
other conflict for you.

### One plan at a time, more runners when you want them

By default a run works on **one plan at a time**. That keeps everything simple: one agent, one
build, one gate on the machine; a plan always starts from a base branch that already has the
plans before it; and nothing ever needs to merge two agents' work at once.

When the machine has room for more, open another terminal in the same repository and start
another `dangle`. Runners in one repository share the work safely:

- each plan is **claimed** by the runner that starts it, and the others skip it;
- a plan that depends on one another runner is working on **waits** for it to land, then runs;
- **landings take turns** (one lock), and each landing merges in what the others landed first.

```sh
dangle                 # terminal 1: the night's run
dangle                 # terminal 2: a second runner on the same queue
dangle 866             # or: just this one plan, beside the main run
```

Claims live in `.git/dangle/`, so they are per clone: runners on two computers do not see each
other's claims. Give each computer its own ids (`dangle 864 865` on one, `dangle 872 873` on
the other).

The night stops early when the agent fails fast twice in a row (out of credit, signed out,
the model is down) instead of failing every plan in minutes. The computer is kept awake
(`systemd-inhibit` or `caffeinate`). The summary is in `.git/dangle/last-run.md`, and the
logs are in `.git/dangle/logs/`.

## Plans that are already done

A repository's plans folder often falls behind its code: some plans were carried out by hand,
or by an earlier runner, and never moved. Running them again wastes a night. `dangle audit`
asks the agent about each active plan in a throwaway checkout (it changes nothing):

```sh
dangle audit -a claude:sonnet      # a strong model is worth it for this
cat .git/dangle/audit.md           # done / partial <what is missing> / todo, per plan
dangle audit --apply               # moves the ones found done to done/, in one commit
```

Check the plans it calls done before `--apply`. A plan it calls partial is worth a short
"Corrections" section at the top saying what is already there; the skill from `dangle skill`
walks an agent through all of this.

## Agents

`AGENT=` in the config, `-a` for one run, or `agent=` in one plan. Your own default for every
repository goes in `~/.config/dangle/config` (a repository's `.dangle/config` wins over it):

```sh
mkdir -p ~/.config/dangle
echo 'AGENT=pi:ollama-local/qwen3.8:latest' >> ~/.config/dangle/config
```


| Spec | Runs |
|---|---|
| `claude` (the default), `claude:haiku` | `claude -p --output-format stream-json --verbose --dangerously-skip-permissions [--model …]` |
| `codex`, `codex:gpt-5` | `codex exec --dangerously-bypass-approvals-and-sandbox [--model …]` |
| `opencode`, `opencode:anthropic/claude-sonnet-5-5` | `opencode run --auto [--model …]` |
| `pi`, `pi:ollama/qwen3` | `pi -p --mode json --approve [--model …]` |
| `opus` | the default agent with this model |
| `cheap` | `ALIAS_cheap=claude:haiku` from the config |
| `./scripts/my-agent` | your own command |

pi and Claude Code run in their streaming modes, and dangle turns each event into one line of
the log: `→ bash cargo test`, `→ Edit src/lib.rs`, or the agent's text. The raw events are
kept beside it (`<id>.jsonl`). That is what the heartbeat shows while an agent works.

Words after the spec are passed on (`AGENT=opencode --variant high`). The prompt is always the
last argument. An agent runs with `DANGLE=1`, `DANGLE_PLAN`, `DANGLE_PLAN_FILE`,
`DANGLE_WORKTREE`, `DANGLE_BRANCH`, `DANGLE_BASE` and `DANGLE_MODEL` set, and stdin closed.
Your own command can be a wrapper script for anything unusual (a container, a session id).

**Agents run without permission prompts.** That is what lets them work unattended, and it
means they can run any command your user can. Run dangle in a container or VM for code you do
not trust.

## Customizing: everything is a file in `.dangle/`

Each step is a short file your agents can read and change. Ask one: "make dangle copy
node_modules into new worktrees" or "land through a GitHub PR and wait for CI".

| File | When | What |
|---|---|---|
| `config` | always | `KEY=value` settings (read, never run) |
| `copy` | new worktree | paths copied from the main checkout (copy-on-write where the disk can), or `link <path>` for a symlink: `.env`, `node_modules`, a warm `target/` |
| `hooks/setup` | new worktree, after `copy` | install dependencies, reserve a port, seed a database |
| `hooks/gate` | before every landing | your checks; exit 0 = may land |
| `hooks/regate <old> <new>` | the base moved during a gate | exit 1 = no second gate (e.g. only docs changed) |
| `hooks/land` | landing, after the gate | replaces the built-in squash-and-push |
| `hooks/teardown` | before a worktree is removed | save a build cache for the next one |
| `audit-prompt.md` | `dangle audit` | the audit prompt, with `{{plan}}` |
| `hooks/lint <plans>` | `dangle lint` | your own plan checks (skill names exist, no forbidden commands); exit non-zero = error |
| `hooks/done <summary>` | end of a run | notify yourself: `notify-send`, ntfy, e-mail |
| `prompt.md`, `fix-prompt.md`, `merge-prompt.md` | each agent run | the prompts, with `{{plan}}`, `{{branch}}`, `{{base}}`, `{{gate}}`, `{{gate_log}}`, `{{gate_tail}}`, `{{conflicts}}` |

Hooks run with `DANGLE_PRIMARY` (the main checkout), `DANGLE_WORKTREE`, `DANGLE_BRANCH`,
`DANGLE_BASE`, and for `land`, `DANGLE_TITLE`, `DANGLE_MESSAGE_FILE` and `DANGLE_REMOTE`.

### Landing your way

The built-in landing squashes the branch into one commit on the base branch and pushes it. A
`hooks/land` replaces that step; it runs in the worktree after the gate passed, holding the
land lock. `examples/land/` has three:

- `github-pr`: push, open a pull request, wait for CI with `gh pr checks --watch`, squash-merge.
- `gitlab-mr`: open a merge request that merges when its pipeline passes.
- `merge-commit`: a merge commit instead of a squash.

A hook that hands off without waiting (the PR merges later) leaves the plan **submitted**:
dangle skips it, and the plans that depend on it, until it shows up in `done/` on the base
branch. A hook that waits keeps the night in order.

## Worktrees by hand

dangle's worktrees work for people too:

```sh
dangle new my-fix              # .worktrees/my-fix, with copy + setup
cd "$(dangle path my-fix)"
dangle land                    # gate, squash, land, remove (--keep keeps it, --fix asks the agent)
dangle list                    # worktrees, ahead/behind, changes
dangle rm my-fix               # teardown, then remove
```

## Configuration

```sh
BASE=main            # the branch plans land on (default: origin's HEAD, main, master)
PLANS=docs/plans     # the plans folder
DONE=done            # landed plans move to PLANS/DONE
AGENT=claude:sonnet   # default: claude
FIX_AGENT=claude:opus
FIXES=1              # fix-up runs after a failed gate
AGENT_TIMEOUT=4h
GATE_TIMEOUT=60m
REMOTE=origin        # none: never fetch or push
WORKTREES=.worktrees
BRANCH_PREFIX=plan-
MAX_LINES=300
HEARTBEAT=5m         # a progress line while an agent or the gate runs; 0 = off
ALIAS_cheap=claude:haiku
```

`DANGLE_AGENT`, `DANGLE_FIX_AGENT` and `DANGLE_REMOTE` in the environment override them.

## Development

```sh
test/run.sh                      # end-to-end tests with a fake agent
shellcheck -s sh bin/dangle
```

MIT license.
