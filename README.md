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
any agent ([pi](https://github.com/badlogic/pi-mono), [opencode](https://opencode.ai),
[Claude Code](https://claude.com/claude-code), Codex, or your own command) and any way of
landing (straight onto a branch, or through pull requests and CI).

## Install

```sh
mise use -g github:bendangelo/dangle
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
`plans`, or `PLANS=` in the config). Every `*.md` directly in it is active; filename order is
run order; subfolders are inactive (`done/` holds landed plans, `hold/` parks one).

```markdown
# Payroll: employee master file
<!-- dangle: depends=863,864 agent=claude:sonnet -->

Goal, files, steps, tests...

Done when: `cargo test payroll_employee`
```

- The id is the plan's number: `2026-10-14-865-name.md` and `865-name.md` are both `865`. A plan
  without a number goes by its name, and any unique part of a name works too.
- `depends=` skips a plan until those plans have landed. `agent=` picks the agent for it.
- `Done when:` is a command dangle runs after the gate; the plan lands only when it passes.
- Keep plans small: one goal, one session, a few hundred lines at most (`dangle lint` warns).
  The skill from `dangle skill` tells your agents all of this, and how to tidy a repository's
  existing plans into this shape.

## Running

```sh
dangle                         # every active plan, in order
dangle 865 870                 # only these, in this order, then stop
dangle 865 --rest              # 865 first, then everything else
dangle -a claude:haiku         # pick the agent for this run
dangle -a qwen3.8:latest       # the default agent with another model
dangle status                  # ready, waiting, running, kept, submitted
dangle 866                     # continue a failed plan in its kept worktree (--fresh: start over)
```

For each plan dangle creates the worktree `.worktrees/plan-<id>` from the base branch, runs
the agent, commits anything it left uncommitted, merges the base branch in, moves the plan to
`done/` in the branch, and runs the gate. A failed gate gets one fix-up run of the agent
(`FIXES=`) with the gate's output. Then, under a lock, it lands: squashes the branch onto the
base branch and pushes it. A plan that fails keeps its worktree for you to look at.

A second `dangle` can run beside the first: `dangle 866` while the night's run is going claims
866, and the main run skips it. Landings take turns.

The night stops early when the agent fails fast twice in a row (out of credit, signed out,
the model is down) instead of failing every plan in minutes. The computer is kept awake
(`systemd-inhibit` or `caffeinate`). The summary is in `.git/dangle/last-run.md`, and the
logs are in `.git/dangle/logs/`.

## Agents

`AGENT=` in the config, `-a` for one run, or `agent=` in one plan:

| Spec | Runs |
|---|---|
| `pi`, `pi:ollama-local/qwen3.8:latest` | `pi -p --approve [--model …]` |
| `opencode`, `opencode:anthropic/claude-sonnet-5-5` | `opencode run --auto [--model …]` |
| `claude`, `claude:haiku` | `claude -p --dangerously-skip-permissions [--model …]` |
| `codex`, `codex:gpt-5` | `codex exec --dangerously-bypass-approvals-and-sandbox [--model …]` |
| `qwen3.8:latest` | the default agent with this model |
| `cheap` | `ALIAS_cheap=claude:haiku` from the config |
| `./scripts/my-agent` | your own command |

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
| `hooks/done <summary>` | end of a run | notify yourself: `notify-send`, ntfy, e-mail |
| `prompt.md`, `fix-prompt.md` | each agent run | the prompts, with `{{plan}}`, `{{branch}}`, `{{base}}`, `{{gate}}`, `{{gate_log}}`, `{{gate_tail}}` |

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
AGENT=pi:ollama-local/qwen3.8:latest
FIX_AGENT=claude:sonnet
FIXES=1              # fix-up runs after a failed gate
AGENT_TIMEOUT=4h
GATE_TIMEOUT=60m
REMOTE=origin        # none: never fetch or push
WORKTREES=.worktrees
BRANCH_PREFIX=plan-
MAX_LINES=300
ALIAS_cheap=claude:haiku
```

`DANGLE_AGENT`, `DANGLE_FIX_AGENT` and `DANGLE_REMOTE` in the environment override them.

## Development

```sh
test/run.sh                      # end-to-end tests with a fake agent
shellcheck -s sh bin/dangle
```

MIT license.
