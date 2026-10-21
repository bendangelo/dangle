# Gated trees and speculative gates: fewer second gates when the base branch moves

**Problem.** Two runners (or a runner and a person running `dangle land`) gate branches at the
same time. When A lands first, B's gate was against the old base. B merges the new base in and,
unless the regate hook says otherwise, gates again *under the land lock*. In a project whose gate
takes 20 minutes and whose branches mostly touch the same core packages, nearly every landing
then costs two gates, the other runner waits on the lock, and after three loops a plan fails
with "`$BASE` kept moving; try again". (wenmar: 2 of the last ~20 plans failed this way, and
plans took 40 minutes to 2 hours each.)

**What merge queues do** (GitHub merge queue, bors, Zuul): gate each branch against the base
*plus every branch ahead of it in the queue*. When the ones ahead land as gated, the result is
already tested, and nothing is gated twice.

**This plan does that in three small steps, all in `bin/dangle`:**

1. **Gated trees.** A gate result depends only on the tree it checked. After a passing gate,
   dangle records the tree (`git rev-parse HEAD^{tree}`) in `$STATE/gated/<tree>`. In
   `land()`'s loop, after merging the moved base in, if the merged tree is already recorded,
   it lands without a second gate (`gate   this tree already passed`). This needs no
   configuration and is always safe: the exact tree was gated.
2. **Speculative gates.** Before its first gate, a branch writes
   `$STATE/queue/<branch>` (its pid and the sha it is about to gate) and removes it when it
   lands or fails (and in `cleanup`). When other live entries exist, it gates a speculative
   commit instead of its own HEAD: on a detached HEAD in its worktree, it merges each queued
   sha, oldest entry first. If every merge is clean, it gates that commit, and a pass is
   recorded under the speculative tree (step 1). Then it checks out its branch again: the
   branch itself never contains the other branches' commits. When A then lands exactly as
   gated, B's merge of the new base usually produces that same tree, and step 1 lands B with no
   second gate. If a merge conflicts, or the speculative gate fails, B gates its own HEAD as
   today. It never lands something untested: the worst case is today's behaviour plus one
   wasted gate when an earlier branch fails.
3. **The retry limit counts gates, not loops.** Today `tries` counts every pass through the
   land loop, including ones where the base moved only by a pushed plan or note (no gate
   needed). Count only the loops that run a gate (limit 3, as now), and cap all loops at 20.

**Out of scope:** batching several branches into one gate (worth it with many runners; with
two, speculation gives most of the gain), and releasing the land lock during a second gate.

## Where in `bin/dangle`
- `run_gate` (the gate section): after the gate hook and the `Done when:` command pass, `mkdir
  -p "$STATE/gated"` and `touch "$STATE/gated/$(git -C "$dir" rev-parse 'HEAD^{tree}')"`. Prune
  entries older than 7 days there too (`find "$STATE/gated" -type f -mtime +7 -delete`).
- New `queue_add <branch> <sha>`, `queue_drop <branch>`, `queue_ahead <branch>` (the shas of
  live entries other than `<branch>`, oldest first by file mtime; an entry whose pid is dead is
  removed, as `take_lock` does). `cleanup` calls `queue_drop` for its branch.
- New `speculate <worktree> <branch>`: prints the speculative sha, or fails when there is
  nothing ahead or a merge conflicts (leaving the worktree back on `<branch>`, clean).
- `land()`, at `say "  gate   running (log $log)"`: `queue_add`, then the first `run_gate` is
  `speculate`d when possible: on a pass, check out the branch again and continue (the branch's
  own tree is not recorded, so the land loop decides). On a failure of the speculative gate,
  check out the branch and fall through to the existing `while ! run_gate …` loop.
- `land()`'s inner loop: before `if [ -n "$MERGED_BY" ] || regate_needed "$old" "$new"`,
  check `[ -f "$STATE/gated/$(git -C "$path" rev-parse 'HEAD^{tree}')" ]`; when present, say
  `  gate   this tree already passed` and skip the second gate. Move `tries` so it counts only
  loops that run `run_gate`, and add a `loops` cap of 20 with the same failure message.
- `queue_drop` on every `return` path of `land()` after `queue_add`.

## Tests (`test/run.sh`)
Use a gate hook that appends `git rev-parse HEAD^{tree}` to `$tmp/gated-trees` and passes:
- **a moved base whose merge gives a tree already gated lands without a second gate**: gate a
  branch, record its merged tree by hand in `.git/dangle/gated/`, move `main` so the merge
  produces that tree, `dangle land`; the gate ran once and the output says "already passed".
- **speculation**: plan A and plan B, two runners (`dangle 010 &` and `dangle 020`), the gate
  hook sleeping 3 s. Both land; the gate ran at most three times in total (A, B on A, and no
  second gate for B), and `$tmp/gated-trees` contains the tree `main` ends with.
- **a conflicting queue entry is not speculated on**: A and B edit the same line; B gates its
  own HEAD (the log has no speculative merge) and lands after A as today (conflict path).
- **a failing speculative gate falls back**: the gate fails when a file only A adds is present;
  B's speculative gate fails, its own gate passes, and B lands.
- **the loop limit counts gates**: five pushes of a README change to `main` during a landing
  (regate hook says no gate needed) still land.
- The existing suite passes: `test/run.sh`.

Release as 0.1.18 with a README section "Two runners" describing the queue.
