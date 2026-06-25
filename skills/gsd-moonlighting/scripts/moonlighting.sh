#!/usr/bin/env bash
# moonlighting.sh — drive GSD phases overnight, one fresh WebIf turn at a time.
#
# The point: gsd-autonomous loops phases in ONE Claude session, so context piles up.
# This runs each GSD step as a separate `--fresh` ht-webif turn (context cleared every
# turn via /clear or respawn), so context never accumulates. Continuity lives in GSD's
# files (.planning/*) + git. All WebIf I/O is delegated to ma-client.sh — we never curl.
#
# Run DETACHED (the skill launches it with nohup &); it writes progress/PID to STATE_DIR
# and never streams into the launching Claude's context.
#
# Discuss is done by a human while awake; this drives plan -> execute (-> verify) only.
# On any question / blocker / escalation / failure it does NOT guess — it halts and queues
# the phase for morning review.
set -uo pipefail

# ---- defaults ----------------------------------------------------------------
WEBIF_DIR="${WEBIF_DIR:-/home/parallels/workspaces/claude-p}"
# CONF_DIR = cwd used to resolve instances.conf (per-worktree); defaults to WEBIF_DIR.
# MA_CLIENT = path to ma-client.sh (always lives in claude-p, even for worktrees).
CONF_DIR=""
MA_CLIENT=""
STEPS="plan,execute"
PLAN_AGENT="claude"
EXECUTE_AGENT="claude"
VERIFY_AGENT="claude"
FIX_AGENT="claude"
FIX_RETRIES=0         # verify→fix→re-verify attempts (0 = off; verify fail halts immediately)
LAST_RESULT=""        # most recent turn result body (for verdict parsing)
ONLY=""; FROM=""; TO=""
TIMEOUT=7200          # per-turn seconds (2h; execute phases can run long)
POLL=60               # poll interval seconds
STATE_DIR="$(pwd)/.moonlighting"
DRY_RUN=false

usage() {
  cat >&2 <<'EOF'
moonlighting.sh — drive GSD phases overnight via ht-webif fresh turns.

  --webif-dir DIR     fallback dir for ma-client.sh if not on PATH (default: claude-p)
  --conf-dir DIR      dir holding instances.conf = target cwd (default: \$PWD)
  --ma-client PATH    explicit ma-client.sh path (overrides PATH lookup)
  --only N            run a single phase (PoC)
  --from N [--to M]   run a phase range in order
  --steps a,b         per-phase step sequence (default: plan,execute)
  --plan-agent A      agent (instances.conf name) for plan   (default: claude)
  --execute-agent A   agent for execute                      (default: claude)
  --verify-agent A    agent for verify                       (default: claude)
  --fix-agent A       agent for the fix step (gsd-code-review --fix) (default: claude)
  --fix-retries N     on verify FAIL, run gsd-code-review --fix --auto then
                      re-verify, up to N times (default: 0 = off, verify fail halts)
  --timeout SEC       per-turn timeout (default: 7200 = 2h)
  --poll SEC          poll interval (default: 60)
  --state-dir DIR     progress/queue/pid dir (default: ./.moonlighting)
  --dry-run           print the ma-client commands; send nothing
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --webif-dir) WEBIF_DIR="$2"; shift 2;;
    --conf-dir) CONF_DIR="$2"; shift 2;;
    --ma-client) MA_CLIENT="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --from) FROM="$2"; shift 2;;
    --to) TO="$2"; shift 2;;
    --steps) STEPS="$2"; shift 2;;
    --plan-agent) PLAN_AGENT="$2"; shift 2;;
    --execute-agent) EXECUTE_AGENT="$2"; shift 2;;
    --verify-agent) VERIFY_AGENT="$2"; shift 2;;
    --fix-agent) FIX_AGENT="$2"; shift 2;;
    --fix-retries) FIX_RETRIES="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --poll) POLL="$2"; shift 2;;
    --state-dir) STATE_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

CONF_DIR="${CONF_DIR:-$(pwd)}"              # where instances.conf lives = target project cwd
# resolve ma-client.sh: explicit --ma-client > PATH (just install) > claude-p/scripts fallback.
MA="${MA_CLIENT:-$(command -v ma-client.sh 2>/dev/null || echo "$WEBIF_DIR/scripts/ma-client.sh")}"
[ -x "$MA" ] || { echo "moonlighting: ma-client.sh not on PATH nor at $MA (run 'just install' in claude-p)" >&2; exit 1; }
[ -f "$CONF_DIR/instances.conf" ] || echo "moonlighting: warning — no instances.conf in $CONF_DIR" >&2

# ---- phase list --------------------------------------------------------------
phases=()
if [ -n "$ONLY" ]; then
  phases=("$ONLY")
elif [ -n "$FROM" ]; then
  end="${TO:-$FROM}"
  for ((p=FROM; p<=end; p++)); do phases+=("$p"); done
else
  echo "moonlighting: specify --only N or --from N [--to M]" >&2; exit 1
fi

mkdir -p "$STATE_DIR"
PROGRESS="$STATE_DIR/progress.log"
QUEUE="$STATE_DIR/morning-queue.md"
echo $$ > "$STATE_DIR/moonlighting.pid"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "$PROGRESS" >&2; }
queue() { printf -- '- phase %s / %s: %s\n' "$1" "$2" "$3" >> "$QUEUE"; }

agent_for() {
  case "$1" in
    plan) echo "$PLAN_AGENT";; execute) echo "$EXECUTE_AGENT";;
    verify) echo "$VERIFY_AGENT";; fix) echo "$FIX_AGENT";;
    *) echo "$EXECUTE_AGENT";;
  esac
}
skill_for() {
  case "$1" in
    plan) echo "gsd-plan-phase";; execute) echo "gsd-execute-phase";;
    verify) echo "gsd-verify-work";; fix) echo "gsd-code-review";;
    *) echo "$1";;
  esac
}
# Skill args per step — mirror gsd-autonomous's unattended invocation:
#   plan    -> "<N> --auto"                (suppress interactive prompts)
#   execute -> "<N> --auto --no-transition" (autonomous manages phase transitions)
#   verify  -> "<N>"
#   fix     -> "<N> --fix --auto"          (review + auto-apply fixes, bounded re-review loop)
skill_args() {  # step phase
  case "$1" in
    plan)    echo "$2 --auto";;
    execute) echo "$2 --auto --no-transition";;
    verify)  echo "$2";;
    fix)     echo "$2 --fix --auto";;
    *)       echo "$2";;
  esac
}

build_prompt() {  # step phase
  local step="$1" phase="$2" skill args extra=""
  skill="$(skill_for "$step")"; args="$(skill_args "$step" "$phase")"
  # verify is verdict-gated by the loop: a FAIL is a normal result, NOT a block.
  # The agent must end with a machine-readable VERIFY_VERDICT line so moonlighting
  # can decide pass / fix-and-retry / halt without guessing.
  if [ "$step" = "verify" ]; then
    extra="
【verify ステップ専用ルール】検証結果が FAIL でも MOONLIGHTING_BLOCKED にしないでください。失敗は正常な検証結果です。
VERIFICATION.md に結果を記録し、回答本文の最後に必ず次のいずれか1行だけを出力してください:
  VERIFY_VERDICT: pass   （全成功基準クリア）
  VERIFY_VERDICT: fail   （未達あり）
MOONLIGHTING_BLOCKED は、ユーザへの質問・grey-area の判断・本物の escalation のときだけに限定します。"
  fi
  cat <<EOF
Phase ${phase} の「${step}」を、無人(unattended)で実行してください。
次のスキルを指定の引数でそのまま起動すること: Skill(skill="${skill}", args="${args}")
${skill} を最後まで完走させ、phase ${phase} の ${step} を完了させてください。
途中でユーザへの質問・grey-area の判断・blocker・escalation が必要になったら、推測で答えたり勝手に決めたりせず、
回答本文の先頭に "MOONLIGHTING_BLOCKED: <理由>" と1行だけ書いて、そこで停止してください（メニューを開いたまま待たない）。
完了したら、実行した内容と検証結果（テスト/コミット）を簡潔に報告してください。${extra}
EOF
}

# verify verdict: prefer the agent's VERIFY_VERDICT line, fall back to VERIFICATION.md status.
# echoes: passed | failed | unknown
verify_verdict() {  # phase
  local phase="$1" v pad vf
  v="$(printf '%s' "$LAST_RESULT" | grep -oiE 'VERIFY_VERDICT:[[:space:]]*(pass|fail)' | head -1 \
        | grep -oiE '(pass|fail)$' | tr 'A-Z' 'a-z')"
  case "$v" in pass) echo passed; return;; fail) echo failed; return;; esac
  pad="$(printf '%02d' "$phase" 2>/dev/null)" || pad="$phase"
  vf="$(ls "$CONF_DIR"/.planning/phases/${pad}-*/${pad}-VERIFICATION.md \
         "$CONF_DIR"/.planning/phases/${phase}-*/${phase}-VERIFICATION.md 2>/dev/null | head -1)"
  [ -f "$vf" ] || { echo unknown; return; }
  if   grep -qiE '^status:[[:space:]]*passed'        "$vf"; then echo passed
  elif grep -qiE '^status:[[:space:]]*(failed|fail)' "$vf"; then echo failed
  else echo unknown; fi
}

# verify with bounded fix→re-verify loop. Always verdict-gated (even with FIX_RETRIES=0,
# a FAIL halts loud instead of silently passing). 0 ok / 1 halt.
run_verify_with_fix() {  # phase
  local phase="$1" attempt=0 verdict
  while :; do
    run_step verify "$phase" || return 1          # turn-level block/fail/timeout already queued
    verdict="$(verify_verdict "$phase")"
    case "$verdict" in
      passed) log "phase ${phase} verify: PASS"; return 0;;
      failed) log "phase ${phase} verify: FAIL (verdict)";;
      *) log "phase ${phase} verify: verdict undetermined — halting for morning review"
         queue "$phase" verify "verify verdict undetermined (no VERIFY_VERDICT line and no VERIFICATION.md status)"; return 1;;
    esac
    if [ "$attempt" -ge "$FIX_RETRIES" ]; then
      log "phase ${phase} verify: still FAIL after ${attempt} fix attempt(s) — halting for morning review"
      queue "$phase" verify "verification failed after ${attempt} fix attempt(s); needs human review"
      return 1
    fi
    attempt=$((attempt + 1))
    log "phase ${phase} ▶ fix attempt ${attempt}/${FIX_RETRIES} (gsd-code-review --fix --auto)"
    run_step fix "$phase" || return 1             # fix-turn block/fail already queued
  done                                            # loop back to re-verify
}

# ma-client result: status は stderr の "[ma-client] status: X" に出る / result は stdout。
turn_status() { ( cd "$CONF_DIR" && "$MA" result "$1" "$2" ) 2>&1 1>/dev/null \
  | grep -oE 'status: [a-zA-Z]+' | head -1 | awk '{print $2}'; }
turn_result() { ( cd "$CONF_DIR" && "$MA" result "$1" "$2" ) 2>/dev/null; }

run_step() {  # step phase  -> 0 ok, 1 halt
  local step="$1" phase="$2" agent prompt tid st elapsed=0 result
  agent="$(agent_for "$step")"
  prompt="$(build_prompt "$step" "$phase")"

  if $DRY_RUN; then
    log "DRY-RUN phase ${phase} step ${step} agent=${agent}:"
    printf '  ( cd %q && %q %q -p "<prompt>" --fresh --async )\n' "$CONF_DIR" "$MA" "$agent" >&2
    return 0
  fi

  log "phase ${phase} ▶ ${step} (agent=${agent}) — sending fresh turn"
  tid="$( ( cd "$CONF_DIR" && "$MA" "$agent" -p "$prompt" --fresh --async ) 2>/dev/null | tail -1 )"
  if [ -z "$tid" ]; then
    log "phase ${phase} ${step}: no turn_id (is the '${agent}' instance up? run launch-agents.sh up)"
    queue "$phase" "$step" "WebIf 接続不可/turn_id なし"; return 1
  fi
  log "phase ${phase} ${step}: turn_id=${tid}, polling (timeout=${TIMEOUT}s)"

  while :; do
    st="$(turn_status "$agent" "$tid")"
    case "$st" in
      done|failed)
        result="$(turn_result "$agent" "$tid")"
        LAST_RESULT="$result"   # expose for verify_verdict()
        # MOONLIGHTING_BLOCKED takes precedence in EITHER status: the agent may report a
        # grey-area halt as status:"failed" (with the marker in its error/body). The marker
        # is protocol-defined to sit at the START of a line ("回答本文の先頭に
        # MOONLIGHTING_BLOCKED: <理由> と1行だけ"). Match it LINE-ANCHORED — a naive substring
        # grep false-positives when a SUCCESS report merely mentions the word (e.g.
        # "MOONLIGHTING_BLOCKED なし" / "no MOONLIGHTING_BLOCKED occurred").
        if printf '%s' "$result" | grep -qE '^[[:space:]]*MOONLIGHTING_BLOCKED:'; then
          log "phase ${phase} ${step}: BLOCKED — halting for morning review"
          queue "$phase" "$step" "$(printf '%s' "$result" | grep -m1 -E '^[[:space:]]*MOONLIGHTING_BLOCKED:')"
          return 1
        fi
        if [ "$st" = failed ]; then
          log "phase ${phase} ${step}: FAILED — halting"
          queue "$phase" "$step" "turn failed: $(printf '%s' "$result" | tail -1)"; return 1
        fi
        log "phase ${phase} ${step}: done"
        return 0;;
      timeout)
        # ht-webif wrote {"status":"timeout"} after its own per-turn deadline
        # (profile turn_timeout_secs). This is terminal server-side — do NOT keep
        # polling until our own outer TIMEOUT, which would waste the whole window.
        log "phase ${phase} ${step}: WebIf turn timeout — halting for morning review"
        queue "$phase" "$step" "WebIf turn timeout (turn ${tid}); raise turn_timeout_secs in agents/claude.toml if the work is legitimately long"
        return 1;;
    esac
    sleep "$POLL"; elapsed=$((elapsed + POLL))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      log "phase ${phase} ${step}: TIMEOUT after ${elapsed}s — halting"
      queue "$phase" "$step" "timeout ${elapsed}s (turn ${tid})"; return 1
    fi
  done
}

# ---- main loop ---------------------------------------------------------------
IFS=',' read -ra step_list <<< "$STEPS"
log "moonlighting start: phases=[${phases[*]}] steps=[${STEPS}] webif=${WEBIF_DIR} dry_run=${DRY_RUN}"
for phase in "${phases[@]}"; do
  for step in "${step_list[@]}"; do
    # verify routes through the verdict-gated fix→re-verify loop; all other steps run once.
    if [ "$step" = "verify" ]; then
      run_verify_with_fix "$phase"; rc=$?
    else
      run_step "$step" "$phase"; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      log "halted at phase ${phase} step ${step}. See ${QUEUE}. Stopping run."
      rm -f "$STATE_DIR/moonlighting.pid"; exit 2
    fi
  done
  log "phase ${phase}: all steps complete"
done
log "moonlighting done: all phases complete"
rm -f "$STATE_DIR/moonlighting.pid"
