#!/usr/bin/env bash
# run-queue.sh — bounded worker pool for inter-phase moonlighting.
#
# Problem: spawning one worktree per phase and launching them ALL at once melts the box at
# ~10 phases (10x ht-webif + 10x driven Claude TUI + 10x moonlighting). This decouples the
# TOTAL phase count N from the concurrency K: keep at most K worktrees running; when one
# finishes, tear down its ht-webif (NO process reuse) and start the next from the queue.
#
# It does NOT merge — merge is a separate, human-gated step. Completed worktrees persist
# (branches + dirs) for manual verification, then `merge-worktrees.sh --select <approved>`.
#
# Completion = the worktree's .moonlighting/moonlighting.pid is no longer alive (written by
# spawn-worktree.sh). Slot teardown uses `launch-agents.sh down-all` with cwd = that worktree,
# so it only kills that worktree's port (its instances.conf lists one port) — never the others.
#
# Run it detached, like moonlighting itself:
#   nohup run-queue.sh --repo R --phases 2,3,4,5 --max-parallel 3 > queue.out 2>&1 &
set -uo pipefail

REPO=""; PHASES=""; K=2; BASE_PORT=5080; STRIDE=10; AGENTS="claude"; POLL=30; DRY_RUN=false
# Optional moonlighting passthrough (empty = moonlighting's own defaults: STEPS=plan,execute).
# Without these, queue mode could only ever run plan,execute — no way to gate phases with verify.
STEPS=""; VERIFY_AGENT=""; FIX_RETRIES=""
SELF_DIR="$(dirname "$(readlink -f "$0")")"
SPAWN="$SELF_DIR/spawn-worktree.sh"

usage() {
  cat >&2 <<'EOF'
run-queue.sh — run a queue of phases through a bounded pool of moonlighting worktrees.

  --repo DIR            git repo / integration root (required)
  --phases LIST         comma-list of phase numbers to run, in order (e.g. 2,3,4,5)
  --max-parallel K      concurrent worktrees (default: 2; size to what the box handles)
  --base-port N         first port (default: 5080)
  --stride N            ports per slot (default: 10; must exceed agent count)
  --agents a,b          agents per slot in port order (default: claude)
  --steps a,b           moonlighting step sequence per phase (default: plan,execute; add verify to gate)
  --verify-agent A      agent for the verify step (default: same as execute; prefer a different model)
  --fix-retries N       on verify FAIL: gsd-code-review --fix then re-verify, up to N times (default: 0)
  --poll N              seconds between completion checks (default: 30)
  --dry-run             print the plan (queue, K, port blocks); launch nothing

Pool frees a slot when a phase's moonlighting process exits; it does NOT merge. After manual
verification, integrate with: merge-worktrees.sh --repo R [--select p2,p4]
EOF
  exit 1
}
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --phases) PHASES="$2"; shift 2;;
    --max-parallel) K="$2"; shift 2;;
    --base-port) BASE_PORT="$2"; shift 2;;
    --stride) STRIDE="$2"; shift 2;;
    --agents) AGENTS="$2"; shift 2;;
    --steps) STEPS="$2"; shift 2;;
    --verify-agent) VERIFY_AGENT="$2"; shift 2;;
    --fix-retries) FIX_RETRIES="$2"; shift 2;;
    --poll) POLL="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

[ -n "$REPO" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "run-queue: --repo is not a git repo: $REPO" >&2; usage; }
[ -n "$PHASES" ] || { echo "run-queue: --phases required" >&2; usage; }
[ -x "$SPAWN" ] || { echo "run-queue: spawn-worktree.sh not found at $SPAWN" >&2; exit 1; }
LAUNCHER="$(command -v launch-agents.sh || true)"

IFS=',' read -ra QUEUE <<< "$PHASES"
repo_name="$(basename "$REPO")"
WTROOT="$(dirname "$REPO")/${repo_name}-wt"

# Extra moonlighting args appended to each "--only <ph>" spawn. Each is added only when set, so
# the default (no flags) preserves the previous behaviour exactly (moonlighting's plan,execute).
ML_EXTRA="${STEPS:+ --steps $STEPS}${VERIFY_AGENT:+ --verify-agent $VERIFY_AGENT}${FIX_RETRIES:+ --fix-retries $FIX_RETRIES}"

say "=== run-queue: ${#QUEUE[@]} phases [${PHASES}], K=$K, ports ${BASE_PORT}+slot*${STRIDE} ==="
if $DRY_RUN; then
  say "--- DRY-RUN plan ---"
  i=0; for ph in "${QUEUE[@]}"; do slot=$((i % K)); say "  phase $ph -> slot $slot -> port $((BASE_PORT + slot*STRIDE)) -> worktree $WTROOT/p$ph (branch moonlight/p$ph -> worktree-agent-p$ph at merge)"; i=$((i+1)); done
  say "  steps per phase: ${STEPS:-plan,execute (moonlighting default)}${VERIFY_AGENT:+ ; verify-agent=$VERIFY_AGENT}${FIX_RETRIES:+ ; fix-retries=$FIX_RETRIES}"
  say "  (only K=$K run at once; teardown on completion frees the slot; NO auto-merge)"
  exit 0
fi

# slot state (index 0..K-1): phase number + worktree dir; empty string = free
declare -a SLOT_PHASE SLOT_WT
for ((i=0;i<K;i++)); do SLOT_PHASE[i]=""; SLOT_WT[i]=""; done
qi=0  # next queue index to dispatch

pid_alive() { local f="$1" p; p="$(cat "$f" 2>/dev/null || true)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

while :; do
  # 1. fill free slots from the queue
  for ((i=0;i<K;i++)); do
    if [ -z "${SLOT_PHASE[i]}" ] && [ "$qi" -lt "${#QUEUE[@]}" ]; then
      ph="${QUEUE[$qi]}"; qi=$((qi+1))
      name="p$ph"
      say "slot $i: start phase $ph ($name) on port $((BASE_PORT + i*STRIDE))"
      "$SPAWN" --repo "$REPO" --name "$name" --index "$i" --base-port "$BASE_PORT" --stride "$STRIDE" \
               --agents "$AGENTS" --launch --run-moonlighting "--only $ph$ML_EXTRA" >>"$REPO/.moonlighting/queue.log" 2>&1 \
        || say "slot $i: spawn failed for phase $ph (see .moonlighting/queue.log)"
      SLOT_PHASE[i]="$ph"; SLOT_WT[i]="$WTROOT/$name"
    fi
  done

  # 2. done? queue exhausted and all slots free
  busy=0; for ((i=0;i<K;i++)); do [ -n "${SLOT_PHASE[i]}" ] && busy=1; done
  if [ "$busy" -eq 0 ] && [ "$qi" -ge "${#QUEUE[@]}" ]; then break; fi

  sleep "$POLL"

  # 3. reap finished slots (moonlighting pid gone) → teardown ht-webif, free slot
  for ((i=0;i<K;i++)); do
    [ -n "${SLOT_PHASE[i]}" ] || continue
    pidf="${SLOT_WT[i]}/.moonlighting/moonlighting.pid"
    if [ -f "$pidf" ] && ! pid_alive "$pidf"; then
      last="$(tail -n 1 "${SLOT_WT[i]}/.moonlighting/progress.log" 2>/dev/null || true)"
      say "slot $i: phase ${SLOT_PHASE[i]} FINISHED — last: ${last:-<no progress>}"
      # tear down this worktree's ht-webif only (cwd-scoped instances.conf)
      if [ -n "$LAUNCHER" ]; then ( cd "${SLOT_WT[i]}" && "$LAUNCHER" down-all ) >>"$REPO/.moonlighting/queue.log" 2>&1 || true; fi
      say "slot $i: torn down → free. Worktree kept for verification: ${SLOT_WT[i]}"
      SLOT_PHASE[i]=""; SLOT_WT[i]=""
    fi
  done
done

say "=== run-queue: all ${#QUEUE[@]} phases done. Worktrees await verification. ==="
say "Verify each (cd <worktree> && build/test), then merge approved:"
say "  merge-worktrees.sh --repo \"$REPO\" --select <approved,names>   # omit --select = all"
