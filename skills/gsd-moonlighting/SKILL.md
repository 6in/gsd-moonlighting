---
name: gsd-moonlighting
description: Run GSD phases overnight without bloating context. Use when the user says /gsd-moonlighting or wants to let GSD work unattended (while they sleep) on already-discussed phases. Launches a detached orchestrator that drives each GSD step as a separate fresh ht-webif turn (context cleared every turn; state lives in .planning/* + git). You are a launcher+monitor — you do NOT run the loop in your own context.
argument-hint: "[N | N-M | only N]  (phase selector; omit to confirm scope interactively)"
---

# gsd-moonlighting

Drive GSD phases **overnight** while keeping context flat. `gsd-autonomous` loops phases
in one session, so context grows unbounded. This instead runs each GSD step
(`plan` → `execute`) as a **separate `--fresh` ht-webif turn**: context is cleared every
turn, and continuity lives in GSD's files (`.planning/*`) + git. Billing stays on the Max
subscription because ht-webif drives the interactive Claude TUI, not `claude -p`.

**Your role is launcher + monitor, not loop runner.** The loop lives in
`scripts/moonlighting.sh` (delegates all WebIf I/O to `ma-client.sh`). You launch it
**detached** and hand back monitoring commands — never poll the loop turn-by-turn in your
own context, or this session bloats too (the very problem we are avoiding).

## Division of labor (do NOT autonomize judgment)
- **Awake (human, beforehand):** run `/gsd-discuss-phase` for the target phases so all
  design decisions are captured. Planning then needs no dialogue.
- **Overnight (this skill):** `plan` → `execute` per phase, in order, each a fresh turn.
- **On any question / grey-area / blocker / failure / timeout:** the loop does NOT guess.
  It halts and writes the phase to `<state-dir>/morning-queue.md` for human review.

## The cwd invariant (read this first)
Each Claude operates on **its own working directory**. ht-webif keeps the launcher's cwd
(`launch-agents.sh` does not `cd`), and the driven claude TUI inherits it. So **ht-webif
must be launched from the target GSD project dir** — i.e. the cwd of the session invoking
this skill. `ht-webif`, `ma-client.sh`, and `launch-agents.sh` are resolved **from PATH**
(`just install` in claude-p copies them to `~/.local/bin/`); `--webif-dir` (default
`/home/parallels/workspaces/claude-p`) is only a **fallback** for the helper scripts if
they are not on PATH. None of these is the cwd.
Launching ht-webif in `claude-p` would make the loop operate on claude-p itself, not your
project. `spawn-worktree.sh` generates the `instances.conf` and launches in the right dir
for you (in place, or in a worktree).

## Argument — phase selector ($ARGUMENTS)
Map the invocation argument to a `moonlighting.sh` phase flag, then pass it through
`--run-moonlighting`:
- `N`      → `--from N`        (phase N onward, in ROADMAP order)
- `N-M`    → `--from N --to M` (range)
- `only N` → `--only N`        (single phase)
- *(omitted)* → do NOT guess. Read `.planning/STATE.md` (current phase) + `ROADMAP.md`, then
  confirm with the user which phase(s) and steps before launching.

Default steps are `plan,execute`. Add `verify` only if the user wants the verify step too.
For model routing, pick the agents/profiles per role (see "Model routing" below) and pass
`--plan-agent / --execute-agent / --verify-agent`.

## Preconditions — verify before launching
1. **You are in the target GSD project dir** (the repo with `.planning/ROADMAP.md` +
   `STATE.md`), and the target phases have been **discussed** (decisions captured). If not,
   stop and tell the user to `/gsd-discuss-phase` first.
2. **`just install` has been run** in claude-p, so `ht-webif`, `ma-client.sh`, and
   `launch-agents.sh` are all on PATH (`~/.local/bin/`). (claude-p stays as the
   `--webif-dir` fallback if the helpers are not on PATH.)
3. **`skipAutoPermissionPrompt: true` is set in `~/.claude/settings.json`.** The driven
   claude starts as bare `claude` in the target dir; if that dir has never been trusted (a
   git worktree, or any first-time cwd — NOT worktree-specific), Claude Code shows a "Do you
   trust the files in this folder?" dialog and the driven claude hangs there, no-op'ing the
   turn. `skipAutoPermissionPrompt: true` suppresses it. Verify it before an unattended run;
   if missing, the first fresh-dir turn will silently stall. (See claude-p README 前提依存.)
4. **Confirm scope with the user:** which phases, which agent per role (model routing), and
   that an unattended run is wanted. Note that setup writes `instances.conf`, `turns-<port>/`,
   `.moonlighting/` (and `.codex-home` if codex) into the dir — gitignore them.

## How to launch (in place, detached)
From the **target project dir** (your cwd). Dry-run first to see the port plan + conf:
```bash
~/.claude/skills/gsd-moonlighting/scripts/spawn-worktree.sh --here --agents claude --dry-run
```
Then generate `instances.conf` here, launch ht-webif **in this dir**, and start moonlighting
detached — one command:
```bash
~/.claude/skills/gsd-moonlighting/scripts/spawn-worktree.sh \
  --here --agents claude --launch --run-moonlighting "--from <N> --steps plan,execute"
```
`spawn-worktree.sh` runs `launch-agents.sh up` with cwd = this dir (so the driven claude
operates on THIS project) and starts `moonlighting.sh --conf-dir <this dir>` in the background.
Report back the moonlighting PID + progress log path, then **stop** — do not babysit the loop.

(If ht-webif is already up in this exact dir, you may skip straight to
`moonlighting.sh --conf-dir "$PWD" --from <N>`; `--conf-dir` defaults to the cwd.)

## Parallel worktrees (fan out across multiple GSD jobs)
One ht-webif instance set can only serve one working dir. To run several phases/features
in parallel, give each its own **git worktree + port-shifted instances.conf**, generated on
the spot. `scripts/spawn-worktree.sh` does this (claude-p itself is never modified):

```bash
# one isolated worktree (index -> port block: 0=8080.., 1=8090.., 2=8100..):
~/.claude/skills/gsd-moonlighting/scripts/spawn-worktree.sh \
  --repo <source-repo> --name feat-a --index 0 --agents claude \
  --launch --run-moonlighting "--from 2"
```
It: creates the worktree (branch `worktree-agent-<name>`, matching cleanup-wave's required
pattern so `merge-worktrees.sh` can reconcile it) and records a manifest entry under
`<repo>/.moonlighting/manifest.d/` → writes `instances.conf` inside it
with ports `BASE + index*STRIDE + k` → launches ht-webif **with cwd = the worktree** (so its
claude TUI operates on that worktree's `.planning`) → starts moonlighting against those ports.
Isolation is automatic: unique ports give unique PID/LOG (`/tmp/ht-webif-<port>.*`) and
turns dirs; `codex` gets a per-worktree `CODEX_HOME`.

Fan out by calling it once per job with incrementing `--index` (keep `--stride` > agent
count so blocks never overlap):
```bash
for i in 0 1 2; do
  spawn-worktree.sh --repo <repo> --name "job$i" --index "$i" --launch --run-moonlighting "--only $((i+2))"
done
```
Always `--dry-run` first to see the port plan. Tear down with
`( cd <worktree> && launch-agents.sh down-all )` then
`git -C <repo> worktree remove <worktree>`.

### Merging the worktrees back (integration) — `merge-worktrees.sh`
moonlighting parallelizes *phases* across worktrees; reconcile them with one command:
```bash
~/.claude/skills/gsd-moonlighting/scripts/merge-worktrees.sh --repo <repo>   # --dry-run first
```
It splits the merge into the two parts that diverge differently from base:
- **Code → GSD's validated `gsd query worktree cleanup-wave`.** Reads the per-worktree
  manifest entries (`worktree_path` / `branch` / `expected_base`) that `spawn-worktree.sh`
  emitted, and does a per-branch `git merge --no-ff` guarded by merge-base match, no-deletions,
  clean-tree, and SUMMARY rescue — then removes each worktree. (GSD's own worktrees are
  *intra-phase*; moonlighting's are *inter-phase* — orthogonal axes, but the merge machinery
  is reusable.)
- **Meta → regenerated, never text-merged.** STATE.md is a *derived* file: a `merge=ours`
  driver (installed by the script via `git config merge.ours.driver true`, since `ours` is
  NOT built-in) keeps cleanup-wave from conflicting on it, then `gsd query state sync`
  recomputes the counters from the on-disk `.planning/phases/*/` artifacts. ROADMAP rows are
  per-phase distinct lines so git 3-way-merges them. `gsd query validate consistency` asserts
  the result. This closes the manual-reconcile gap for the additive case.

**Constraints (inherited from cleanup-wave):** branch names must match
`^worktree-agent-[A-Za-z0-9._/-]+$` (spawn-worktree.sh default); a worktree branch that
**deletes/renames** a file vs its base is **blocked** (`branch_contains_deletions`) — additive
phases only, resolve renames by hand; the worktree must be clean (all work committed; gitignored
runtime artifacts are fine).

## Model routing (optional, the multi-agent edge)
`--plan-agent` / `--execute-agent` / `--verify-agent` take `instances.conf` agent names
(`claude` / `codex` / `opencode` …). Use a strong agent for `plan`/`verify` and a cheaper
one for the `execute` grind, and make `verify` a **different** agent than `execute` so the
checker is a different model than the generator (harder to fool than same-model self-check).

## Monitor / stop (hand these to the user)
```bash
tail -f <project>/.moonlighting/progress.log     # live progress
cat   <project>/.moonlighting/morning-queue.md    # phases halted for review
kill "$(cat <project>/.moonlighting/moonlighting.pid)"   # stop the run
```

## Flags (scripts/moonlighting.sh)
`--only N` | `--from N [--to M]` · `--steps plan,execute` · `--{plan,execute,verify}-agent A`
· `--conf-dir DIR` (where `instances.conf` lives = target cwd; **default: `$PWD`**)
· `--ma-client PATH` (default: `ma-client.sh` from PATH, else `<webif-dir>/scripts/`)
· `--webif-dir DIR` (fallback for helper scripts if not on PATH) · `--timeout SEC` (7200 = 2h)
· `--poll SEC` (60) · `--state-dir DIR` (default `./.moonlighting`) · `--dry-run`.

## Invariants
- **cwd invariant:** ht-webif must be launched in the target project dir; the helper
  scripts/binary come from PATH (`--webif-dir` is only a fallback), never the cwd.
- Launch detached; never run the poll loop inside this Claude session.
- Discuss is human-only and done awake; never let the overnight loop auto-answer
  grey-area design decisions — halt and queue instead.
- All WebIf I/O goes through `ma-client.sh`; do not hand-roll curl.
