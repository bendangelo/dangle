#!/bin/sh
# Tests for dangle: each case builds a throwaway repository (with a bare "remote") and a
# fake agent, runs dangle, and checks what landed. Run: test/run.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
DANGLE="$here/bin/dangle"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 failed=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export DANGLE_AWAKE=1 NO_COLOR=1 XDG_CONFIG_HOME="$tmp/xdg"

ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { failed=$((failed + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
check() { if eval "$2"; then ok "$1"; else no "$1" "$(cat "$tmp/out" 2>/dev/null | tail -n 30)"; fi; }

# The fake agent: implements a plan by writing the file its "Create:" line names and committing.
# A plan line "Agent: idle" makes it do nothing; "Agent: broken" writes a file the gate rejects.
cat > "$tmp/agent" <<'EOF'
#!/bin/sh
prompt=$(eval "printf '%s' \"\${$#}\"")
case $prompt in *"Reply with the single word OK"*) echo OK; exit 0 ;; esac
case $prompt in *"read-only check"*)
  p=$(printf '%s\n' "$prompt" | sed -n 's/.*plan in \([^ ]*\.md\).*/\1/p' | head -n 1)
  touch SHOULD-BE-UNDONE
  if [ -e "$(sed -n 's/^Create: //p' "$p")" ]; then echo "DANGLE-AUDIT: done"; else echo "DANGLE-AUDIT: todo"; fi
  exit 0 ;;
esac
plan=$(printf '%s\n' "$prompt" | sed -n 's/.*plan in \([^ ,]*\.md\).*/\1/p' | head -n 1)
case $prompt in *"The gate failed"*) rm -f BAD; git add -A; git commit -qm "fix: remove BAD"; exit 0 ;; esac
grep -q '^Agent: idle' "$plan" && exit 0
f=$(sed -n 's/^Create: //p' "$plan")
echo "made by $DANGLE_PLAN with ${DANGLE_MODEL:-?}" > "$f"
grep -q '^Agent: broken' "$plan" && touch BAD
git add -A && git commit -qm "implement $DANGLE_PLAN"
EOF
chmod +x "$tmp/agent"

# repo <name>: a repository with a remote, dangle configured, on branch main.
repo() {
  r="$tmp/$1"
  git init -q --bare "$r.git"
  git init -q -b main "$r"
  cd "$r" || exit 1
  git remote add origin "$r.git"
  mkdir -p plans .dangle/hooks
  printf 'BASE=main\nPLANS=plans\nAGENT=%s\nFIXES=1\n' "$tmp/agent" > .dangle/config
  printf '#!/bin/sh\n[ ! -e BAD ] || { echo "BAD file present"; exit 1; }\n' > .dangle/hooks/gate
  chmod +x .dangle/hooks/gate
  echo base > README
  git add -A && git commit -qm init && git push -q origin main
}
plan() { # <file> <create> [extra lines]
  printf '# Plan %s\n\n%s\nCreate: %s\n' "$1" "${3-}" "$2" > "plans/$1"
}
commit() { git add -A && git commit -qm "${1:-plans}" && git push -q origin main; }

echo "dangle tests"

repo basic
plan 010-one.md one.txt
plan 020-two.md two.txt '<!-- dangle: depends=010 -->'
commit
"$DANGLE" -y > "$tmp/out" 2>&1
check "both plans land in order" '[ -f one.txt ] && [ -f two.txt ]'
check "plans move to done/" '[ -f plans/done/010-one.md ] && [ -f plans/done/020-two.md ] && [ ! -f plans/010-one.md ]'
check "landed commits are pushed" '[ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ]'
check "one squashed commit per plan" '[ "$(git rev-list --count main)" = 4 ]'
check "commit subject is the plan title" 'git log -1 --format=%s | grep -q "^Plan 020-two.md$"'
check "worktrees are removed" '[ -z "$(ls .worktrees 2>/dev/null)" ] && [ -z "$(git branch --list "plan-*")" ]'
check "the carrot summary" 'grep -q "2 landed" "$tmp/out"'

repo deps
plan 010-bad.md a.txt 'Agent: idle'
plan 020-after.md b.txt '<!-- dangle: depends=010 -->'
plan 030-free.md c.txt
commit
"$DANGLE" -y > "$tmp/out" 2>&1; rc=$?
check "a plan with no commits fails and keeps its worktree" '[ -d .worktrees/plan-010 ] && grep -q "made no commits" "$tmp/out"'
check "its dependent is skipped" 'grep -q "waits for 010" "$tmp/out" && [ ! -f b.txt ]'
check "an independent plan still lands" '[ -f c.txt ]'
check "exit code 1 when a plan failed" '[ $rc = 1 ]'

repo fix
plan 010-broken.md x.txt 'Agent: broken'
commit
"$DANGLE" -y > "$tmp/out" 2>&1
check "a failed gate gets a fix-up and lands" '[ -f x.txt ] && [ ! -f BAD ] && grep -q "fix-up 1" "$tmp/out"'

repo order
plan 010-a.md a.txt
plan 020-b.md b.txt
plan 030-c.md c.txt
commit
"$DANGLE" -y 030 > "$tmp/out" 2>&1
check "ids given run only those" '[ -f c.txt ] && [ ! -f a.txt ] && [ ! -f b.txt ]'
"$DANGLE" -y 020 --rest > "$tmp/out" 2>&1
check "--rest runs the id first, then the rest" '[ "$(git log --format=%s main | sed -n 2p)" = "Plan 020-b.md" ] && [ -f a.txt ]'

repo fast
plan 010-a.md a.txt 'Agent: idle'
plan 020-b.md b.txt 'Agent: idle'
plan 030-c.md c.txt
commit
"$DANGLE" -y > "$tmp/out" 2>&1
check "two fast failures stop the night" 'grep -q "failed fast twice" "$tmp/out" && [ ! -f c.txt ]'

repo dated
mkdir -p plans
printf '# Dated\n\nCreate: d.txt\n' > plans/2026-10-14-865-dated.md
printf '# Undated\n\nCreate: e.txt\n' > plans/2026-10-15-some-feature.md
commit
"$DANGLE" -n > "$tmp/out" 2>&1
check "ids: number after a date, else the name" 'grep -q "^  865 " "$tmp/out" && grep -q "^  some-feature " "$tmp/out"'
"$DANGLE" -y some-feat > "$tmp/out" 2>&1
check "a part of a name finds a plan" '[ -f e.txt ] && [ ! -f d.txt ]'

repo hookland
plan 010-a.md a.txt
commit
cat > .dangle/hooks/land <<'EOF'
#!/bin/sh
# Lands with a merge commit instead of a squash, as a project might.
set -e
git push -q "$DANGLE_REMOTE" "HEAD:refs/heads/landed-$DANGLE_BRANCH"
cd "$DANGLE_PRIMARY"
git merge -q --no-ff -F "$DANGLE_MESSAGE_FILE" "$DANGLE_BRANCH"
git push -q "$DANGLE_REMOTE" "$DANGLE_BASE"
EOF
chmod +x .dangle/hooks/land
commit "land hook"
"$DANGLE" -y > "$tmp/out" 2>&1
check "a land hook replaces the squash" '[ -f a.txt ] && [ "$(git log -1 --format=%p | wc -w | tr -d " ")" = 2 ] && git ls-remote origin | grep -q landed-plan-010'

repo prhook
plan 010-a.md a.txt
plan 020-b.md b.txt
commit
printf '#!/bin/sh\ngit push -q "$DANGLE_REMOTE" "HEAD:refs/heads/pr-$DANGLE_BRANCH"\n' > .dangle/hooks/land
chmod +x .dangle/hooks/land
commit "pr hook"
"$DANGLE" -y > "$tmp/out" 2>&1
check "a land hook that only opens a PR leaves the plan submitted" 'grep -q "submitted" "$tmp/out" && [ -f plans/010-a.md ]'
"$DANGLE" -y > "$tmp/out" 2>&1
check "a submitted plan is skipped by the next run" 'grep -q "010 skipped  (submitted" "$tmp/out"'
"$DANGLE" status > "$tmp/out" 2>&1
check "status shows it submitted" 'grep -q "^010 *submitted" "$tmp/out"'

repo agents
cd "$tmp/agents" || exit 1
printf 'BASE=main\nPLANS=plans\nAGENT=claude:sonnet\nALIAS_cheap=claude:haiku\nALIAS_local=pi:ollama-local/qwen3.8:latest\n' > .dangle/config
lib="$tmp/lib.sh"; sed 's/^main "\$@"$//' "$DANGLE" > "$lib"
res() { sh -c '. "$1"; find_repo; settings; resolve_agent "$2" "$(cfg AGENT)"; printf "%s|%s" "$AGENT_LABEL" "$AGENT_CMD"' sh "$lib" "$1"; }
check "preset with a model" '[ "$(res claude:haiku)" = "claude:haiku|claude -p --output-format stream-json --verbose --dangerously-skip-permissions --model haiku" ]'
check "a model with a colon stays whole" '[ "$(res pi:ollama-local/qwen3.8:latest)" = "pi:ollama-local/qwen3.8:latest|pi -p --mode json --approve --model ollama-local/qwen3.8:latest" ]'
check "a bare model uses the default agent" '[ "$(res opus)" = "claude:opus|claude -p --output-format stream-json --verbose --dangerously-skip-permissions --model opus" ]'
check "an alias" '[ "$(res local)" = "pi:ollama-local/qwen3.8:latest|pi -p --mode json --approve --model ollama-local/qwen3.8:latest" ]'
check "extra arguments pass through" '[ "$(res "opencode --variant high")" = "opencode|opencode run --auto --variant high" ]'
printf 'BASE=main\nPLANS=plans\n' > .dangle/config
check "with no AGENT the default is Claude Code" '[ "$(res opus)" = "claude:opus|claude -p --output-format stream-json --verbose --dangerously-skip-permissions --model opus" ]'

repo manual
"$DANGLE" new feature > "$tmp/out" 2>&1
cd .worktrees/feature && echo hi > hi.txt && git add -A && git commit -qm "add hi" && cd ../..
"$DANGLE" land feature > "$tmp/out" 2>&1
check "dangle new + dangle land by hand" '[ -f hi.txt ] && [ ! -d .worktrees/feature ] && git log -1 --format=%s | grep -q "^add hi$"'
"$DANGLE" new feature2 > "$tmp/out" 2>&1
( cd .worktrees/feature2 && env DANGLE=1 "$DANGLE" land ) > "$tmp/out" 2>&1
check "an agent cannot land" 'grep -q "refused" "$tmp/out"'

repo copyfiles
echo secret > .env
printf '.env\nlink shared\n' > .dangle/copy
mkdir shared
printf '#!/bin/sh\necho "$DANGLE_BRANCH" > .setup-ran\n' > .dangle/hooks/setup
chmod +x .dangle/hooks/setup
printf '.env\nshared\n.setup-ran\n' > .gitignore
commit "copy"
"$DANGLE" new t > "$tmp/out" 2>&1
check ".dangle/copy copies and links, setup runs" '[ "$(cat .worktrees/t/.env)" = secret ] && [ -L .worktrees/t/shared ] && [ "$(cat .worktrees/t/.setup-ran)" = t ]'

repo initrepo
rm -rf .dangle
echo '{"scripts":{"test":"true"}}' > package.json
"$DANGLE" init > "$tmp/out" 2>&1
check "init writes a gate for the project's language" 'grep -q "npm test" .dangle/hooks/gate && grep -q node_modules .dangle/copy && [ -x .dangle/hooks/setup ]'
check "init leaves the agent to each person" '! grep -q "^AGENT=" .dangle/config'

repo conflict
"$DANGLE" new side > "$tmp/out" 2>&1
( cd .worktrees/side && echo theirs > README && git commit -qam "side edit" )
echo ours > README && commit "base edit"
"$DANGLE" land side > "$tmp/out" 2>&1; export rc=$?
check "a conflict with the base stops the landing" '[ $rc = 1 ] && grep -q "conflicts" "$tmp/out" && [ "$(cat README)" = ours ]'

repo claims
plan 010-a.md a.txt
plan 020-b.md b.txt
commit
mkdir -p .git/dangle/claims/010 && echo $$ > .git/dangle/claims/010/pid
"$DANGLE" -y > "$tmp/out" 2>&1
check "a plan another dangle is running is skipped" 'grep -q "another dangle is running it" "$tmp/out" && [ ! -f a.txt ] && [ -f b.txt ]'
echo 999999 > .git/dangle/claims/010/pid
"$DANGLE" -y > "$tmp/out" 2>&1
check "a dead run's claim is taken over" '[ -f a.txt ]'

repo regate
plan 010-a.md a.txt
cp "$here/examples/regate-docs-only" .dangle/hooks/regate
cat > .dangle/hooks/gate <<'EOF2'
#!/bin/sh
# Counts its runs; on the first, someone else lands a docs change on main meanwhile.
echo run >> "$DANGLE_PRIMARY/.gate-runs"
if [ ! -f "$DANGLE_PRIMARY/.moved" ]; then
  touch "$DANGLE_PRIMARY/.moved"
  cd "$DANGLE_PRIMARY" && mkdir -p docs && echo note > docs/note.md && git add docs && git commit -qm "docs" && git push -q origin main
fi
EOF2
printf '.gate-runs\n.moved\n' > .gitignore
commit "regate"
"$DANGLE" -y > "$tmp/out" 2>&1
check "base moved by docs only: lands without a second gate" '[ -f a.txt ] && [ -f docs/note.md ] && [ "$(wc -l < .gate-runs)" -eq 1 ]'

repo outoforder
plan 010-needs-later.md a.txt '<!-- dangle: depends=020 -->'
plan 020-first.md b.txt
plan 030-last.md c.txt
commit
"$DANGLE" -n > "$tmp/out" 2>&1
check "dry run orders a plan after the later-numbered plan it needs" '[ "$(grep -o "^  0[0-9]0" "$tmp/out" | tr -d " " | tr "\n" " ")" = "020 010 030 " ]'
"$DANGLE" -y > "$tmp/out" 2>&1
check "a plan that needs a later-numbered one runs after it, the same night" '[ -f a.txt ] && [ -f b.txt ] && [ "$(git log --format=%s main | sed -n 3p)" = "Plan 020-first.md" ]'

repo inside
"$DANGLE" new fix-typo > "$tmp/out" 2>&1
( cd .worktrees/fix-typo && echo typo > typo.txt && git add -A && git commit -qm "Fix the typo" && "$DANGLE" land ) > "$tmp/out" 2>&1; rc=$?
check "dangle land from inside the worktree removes it and its branch" '[ $rc = 0 ] && [ ! -d .worktrees/fix-typo ] && [ -z "$(git branch --list fix-typo)" ]'
check "a branch of one commit lands under that commit's subject" '[ "$(git log -1 --format=%s main)" = "Fix the typo" ]'

repo parallel
plan 010-a.md a.txt
plan 020-b.md b.txt '<!-- dangle: depends=010 -->'
commit
sleep 300 & other=$!
mkdir -p .git/dangle/claims/010 && echo $other > .git/dangle/claims/010/pid
DANGLE_POLL=1 "$DANGLE" -y 020 > "$tmp/out" 2>&1 & run=$!
sleep 3
# The other terminal lands 010.
git mv plans/010-a.md plans/done/ 2>/dev/null || { mkdir -p plans/done && git mv plans/010-a.md plans/done/; }
echo a > a.txt && git add -A && git commit -qm "Plan 010" && git push -q origin main
kill $other; wait $run; rc=$?
check "a plan waits for a dependency another dangle is running, then runs" '[ $rc = 0 ] && grep -q "waiting for 010" "$tmp/out" && [ -f b.txt ]'

repo linthook
plan 010-a.md a.txt 'Run cargo test -p db'
commit
printf '#!/bin/sh\n! grep -l -- "cargo test -p" "$@"\n' > .dangle/hooks/lint
chmod +x .dangle/hooks/lint
"$DANGLE" lint > "$tmp/out" 2>&1; rc=$?
check "a lint hook adds the project's own checks" '[ $rc = 1 ] && grep -q "010-a.md" "$tmp/out" && grep -q "1 error" "$tmp/out"'

repo audit
echo made > old.txt && git add old.txt && git commit -qm "old work" && git push -q origin main
plan 010-old.md old.txt
plan 020-new.md new.txt
commit
"$DANGLE" audit > "$tmp/out" 2>&1
check "audit finds a plan already done, changes nothing" 'grep -q "audit  done" "$tmp/out" && grep -q "audit  todo" "$tmp/out" && [ -f plans/010-old.md ] && [ ! -e SHOULD-BE-UNDONE ] && [ -z "$(git status --porcelain)" ]'
"$DANGLE" audit --apply > "$tmp/out" 2>&1
check "audit --apply moves the done plans in one commit" '[ -f plans/done/010-old.md ] && [ -f plans/020-new.md ] && git log -1 --format=%s | grep -q "1 plan(s) already implemented"'

repo shortids
plan 2026-10-12-shop-A1-links.md a.txt
plan 2026-10-12-shop-A10-guides.md b.txt '<!-- dangle: depends=shop-A1 -->'
commit
"$DANGLE" -n > "$tmp/out" 2>&1
check "a short id names a plan by its first words" '[ "$(awk "NR>1{print \$1}" "$tmp/out" | tr "\n" " ")" = "shop-A1-links shop-A10-guides " ]'
"$DANGLE" -y shop-A1 > "$tmp/out" 2>&1
check "dangle shop-A1 runs shop-A1, not shop-A10" '[ -f a.txt ] && [ ! -f b.txt ]'
"$DANGLE" -y > "$tmp/out" 2>&1
check "depends=shop-A1 is met once shop-A1-links lands" '[ -f b.txt ]'

repo userconfig
mkdir -p "$XDG_CONFIG_HOME/dangle"
printf 'AGENT=pi:ollama-local/qwen3.8:latest\nALIAS_q=pi:x\n' > "$XDG_CONFIG_HOME/dangle/config"
printf 'BASE=main\nPLANS=plans\n' > .dangle/config
check "the user config sets the agent when the repository does not" '[ "$(res opus)" = "pi:opus|pi -p --mode json --approve --model opus" ] && [ "$(res q)" = "pi:x|pi -p --mode json --approve --model x" ]'
printf 'BASE=main\nPLANS=plans\nAGENT=codex\n' > .dangle/config
check "the repository config wins over the user config" '[ "$(res o3)" = "codex:o3|codex exec --dangerously-bypass-approvals-and-sandbox --model o3" ]'
rm -rf "$XDG_CONFIG_HOME/dangle"

repo heartbeat
plan 010-slow.md s.txt
commit
printf 'BASE=main\nPLANS=plans\nAGENT=%s\nHEARTBEAT=1s\n' "$tmp/slow-agent" > .dangle/config
printf '#!/bin/sh\necho "compiling things"\nsleep 3\nexec "%s" "$@"\n' "$tmp/agent" > "$tmp/slow-agent"; chmod +x "$tmp/slow-agent"
commit "slow agent"
"$DANGLE" -y > "$tmp/out" 2>&1
check "a heartbeat line shows the time and the last line of output" 'grep -q "\.\.\.    agent [0-9]*s  │ compiling things" "$tmp/out" && [ -f s.txt ]'

repo private
printf 'plans/\n' > .gitignore && git add .gitignore && git commit -qm ignore && git push -q origin main
plan 010-a.md a.txt
plan 020-b.md b.txt '<!-- dangle: depends=010 -->'
"$DANGLE" -y > "$tmp/out" 2>&1
check "private plans (ignored by git) run, land, and move to done/ on disk" '[ -f a.txt ] && [ -f b.txt ] && [ -f plans/done/010-a.md ] && [ -f plans/done/020-b.md ] && [ -z "$(git ls-files plans)" ]'
check "a private plan lands without its plan file in the commit" '! git show --stat HEAD | grep -q "plans/"'

repo hbstop
plan 010-a.md a.txt
commit
printf 'BASE=main\nPLANS=plans\nAGENT=%s\nHEARTBEAT=300s\n' "$tmp/agent" > .dangle/config
commit "long heartbeat"
start=$(date +%s); export start
"$DANGLE" -y 2>&1 | cat > "$tmp/out"
check "the heartbeat stops with the plan (a pipe after dangle closes at once)" '[ $(( $(date +%s) - start )) -lt 60 ] && [ -f a.txt ]'

repo tworunners
plan 010-a.md a.txt
plan 020-b.md b.txt
plan 030-c.md c.txt '<!-- dangle: depends=010 -->'
plan 040-d.md d.txt
commit
printf 'BASE=main\nPLANS=plans\nAGENT=%s\n' "$tmp/slow-agent" > .dangle/config
commit "slow"
"$DANGLE" -y > "$tmp/out1" 2>&1 & r1=$!
sleep 1
"$DANGLE" -y > "$tmp/out2" 2>&1 & r2=$!
wait $r1; export rc1=$?; wait $r2; export rc2=$?
check "two runners in two terminals: every plan lands exactly once" '[ $rc1 = 0 ] && [ $rc2 = 0 ] && [ -f a.txt ] && [ -f b.txt ] && [ -f c.txt ] && [ -f d.txt ] && [ "$(git log --format=%s main | grep -c "^Plan ")" = 4 ]'
check "two runners: both did some of the work" 'grep -q " landed " "$tmp/out1" && grep -q " landed " "$tmp/out2"'

repo jsonagent
plan 010-a.md a.txt
commit
cat > "$tmp/json-agent" <<'EOF2'
#!/bin/sh
echo '{"type":"tool_execution_start","toolName":"bash","args":{"command":"cargo test -p widgets"}}'
sleep 3
echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"All done."}]}}'
exec "$DANGLE_TEST_AGENT" "$@" > /dev/null
EOF2
chmod +x "$tmp/json-agent"
printf 'BASE=main\nPLANS=plans\nAGENT=%s\nHEARTBEAT=1s\n' "$tmp/json-agent" > .dangle/config
commit "json agent"
DANGLE_TEST_AGENT="$tmp/agent" "$DANGLE" -y > "$tmp/out" 2>&1
check "a JSON event stream becomes readable lines in the log and the heartbeat" 'grep -q "agent [0-9]*s  │ → bash cargo test -p widgets" "$tmp/out" && grep -q "^All done.$" .git/dangle/logs/010.log && [ -s .git/dangle/logs/010.jsonl ] && [ -f a.txt ]'

echo
echo "$pass passed, $failed failed"
[ $failed = 0 ]
