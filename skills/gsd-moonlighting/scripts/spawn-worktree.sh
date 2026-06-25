#!/usr/bin/env bash
# spawn-worktree.sh — prepare a moonlighting target: generate a port-shifted
# instances.conf IN a directory and launch ht-webif THERE.
#
# Invariant: each Claude operates on its own working directory, so ht-webif must be
# launched with cwd = the target project dir (launch-agents.sh keeps the launcher's cwd;
# the driven claude TUI inherits it). claude-p only provides the helper scripts + the
# ht-webif binary — it is NOT the cwd.
#
# Two modes, same core (gen conf -> launch in <target>):
#   --here [--dir D]   in place: target = the invoking session's cwd (or D). No worktree.
#   --repo R --name N --index I   parallel: create a git worktree and target it.
#
# Port plan: target index I, agent k (0-based): port = BASE + I*STRIDE + k.
# STRIDE must exceed the agent count so targets never overlap (default 10).
set -uo pipefail

WEBIF_DIR="${WEBIF_DIR:-/home/parallels/workspaces/claude-p}"  # fallback for helper scripts if not on PATH
HERE=false; DIR=""
REPO=""; NAME=""; INDEX=""; BRANCH=""
AGENTS="claude"                 # comma list; matches agents/<name>.toml profiles
BASE_PORT=8080; STRIDE=10
WORKTREES_ROOT=""               # default: <repo>/../<repo-name>-wt
LAUNCH=false
RUN_MOONLIGHTING=""                # phase spec for moonlighting (e.g. "--from 2"); empty = don't
DRY_RUN=false

usage() {
  cat >&2 <<'EOF'
spawn-worktree.sh — generate instances.conf in a target dir and launch ht-webif there.

  IN-PLACE (single project, default target = your cwd):
    --here [--dir DIR]      operate in DIR (default: current working directory)

  WORKTREE (parallel jobs):
    --repo DIR --name NAME --index I   create worktree <root>/<name> and target it

  common:
    --agents a,b           agents in port order (default: claude)
    --index I              port offset index (worktree: required; --here: default 0)
    --base-port N          first port (default: 8080)
    --stride N             ports per target (default: 10; must exceed agent count)
    --branch NAME          worktree branch (default: moonlighting/<name>)
    --worktrees-root D     worktree parent (default: <repo>/../<repo>-wt)
    --webif-dir DIR        fallback dir for ma-client.sh/launch-agents.sh if not on PATH (default: claude-p)
    --launch               actually launch ht-webif (needs ht-webif on PATH)
    --run-moonlighting "ARGS" after launch, start moonlighting with these phase args (detached)
    --dry-run              print the plan + conf; create/launch nothing
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --here) HERE=true; shift;;
    --dir) DIR="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --index) INDEX="$2"; shift 2;;
    --agents) AGENTS="$2"; shift 2;;
    --base-port) BASE_PORT="$2"; shift 2;;
    --stride) STRIDE="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --worktrees-root) WORKTREES_ROOT="$2"; shift 2;;
    --webif-dir) WEBIF_DIR="$2"; shift 2;;
    --launch) LAUNCH=true; shift;;
    --run-moonlighting) RUN_MOONLIGHTING="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

# resolve a helper: prefer PATH (just install -> ~/.local/bin), else claude-p/scripts.
resolve_helper() { command -v "$1" 2>/dev/null || { [ -x "$WEBIF_DIR/scripts/$1" ] && echo "$WEBIF_DIR/scripts/$1"; }; }
MA="$(resolve_helper ma-client.sh)"
LAUNCHER="$(resolve_helper launch-agents.sh)"
MOONLIGHTING="$(dirname "$(readlink -f "$0")")/moonlighting.sh"
say() { printf '%s\n' "$*" >&2; }

# --- resolve TARGET dir + mode ------------------------------------------------
TARGET=""
if $HERE; then
  TARGET="${DIR:-$(pwd)}"
  NAME="${NAME:-$(basename "$TARGET")}"
  INDEX="${INDEX:-0}"
  [ -d "$TARGET" ] || { echo "spawn-worktree: --dir not a directory: $TARGET" >&2; exit 1; }
else
  [ -n "$REPO" ] && [ -n "$NAME" ] && [ -n "$INDEX" ] || {
    echo "spawn-worktree: worktree mode needs --repo, --name, --index (or use --here)" >&2; usage; }
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "spawn-worktree: $REPO is not a git repo" >&2; exit 1; }
  # Default branch matches cleanup-wave's required pattern ^worktree-agent-[A-Za-z0-9._/-]+$
  # so merge-worktrees.sh can reconcile it via `gsd query worktree cleanup-wave`.
  BRANCH="${BRANCH:-worktree-agent-$NAME}"
  case "$BRANCH" in
    worktree-agent-*) :;;
    *) echo "spawn-worktree: WARNING — branch '$BRANCH' does not match worktree-agent-* ; cleanup-wave will reject it (merge back manually)." >&2;;
  esac
  repo_name="$(basename "$REPO")"
  WORKTREES_ROOT="${WORKTREES_ROOT:-$(dirname "$REPO")/${repo_name}-wt}"
  TARGET="$WORKTREES_ROOT/$NAME"
fi

IFS=',' read -ra agent_list <<< "$AGENTS"
[ "$STRIDE" -gt "${#agent_list[@]}" ] || { echo "spawn-worktree: --stride ($STRIDE) must exceed agent count (${#agent_list[@]})" >&2; exit 1; }

# --- build the instances.conf body (port-shifted, codex gets isolated CODEX_HOME) ------
build_conf() {
  echo "# generated by spawn-worktree.sh — target '$NAME' (index $INDEX)"
  local k=0 agent port
  for agent in "${agent_list[@]}"; do
    port=$((BASE_PORT + INDEX * STRIDE + k))
    case "$agent" in
      codex) echo "codex      $port  CODEX_HOME=$TARGET/.codex-home";;
      *)     printf '%-10s %s\n' "$agent" "$port";;
    esac
    k=$((k + 1))
  done
}

say "=== spawn-worktree: ${HERE:+in-place }$NAME (index $INDEX) ==="
say "target: $TARGET${BRANCH:+   branch: $BRANCH}"
say "ports:  $(build_conf | grep -vE '^#' | awk '{print $1"="$2}' | tr '\n' ' ')"

if $DRY_RUN; then
  next="write instances.conf into $TARGET"
  $LAUNCH && next="$next, launch ht-webif there"
  [ -n "$RUN_MOONLIGHTING" ] && next="$next, run moonlighting ($RUN_MOONLIGHTING)"
  say "--- DRY-RUN: would $next"
  say "--- instances.conf ---"; build_conf >&2
  exit 0
fi

# 1. create worktree (worktree mode only) + record a cleanup-wave manifest entry
if ! $HERE; then
  # expected_base = REPO HEAD the new branch forks from; merge-worktrees.sh / cleanup-wave
  # asserts merge-base(mainHEAD, branch) == this SHA before merging.
  BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
  if [ -d "$TARGET" ]; then
    say "worktree dir already exists: $TARGET (reusing)"
  else
    git -C "$REPO" worktree add -b "$BRANCH" "$TARGET" || { say "git worktree add failed"; exit 1; }
  fi
  # one manifest file per worktree (parallel-safe; assembled by merge-worktrees.sh).
  # Lives under .moonlighting/ (gitignored). REPO is the integration root, not the worktree.
  MANIFEST_DIR="$REPO/.moonlighting/manifest.d"
  mkdir -p "$MANIFEST_DIR"
  ABS_TARGET="$(cd "$TARGET" && pwd)"
  printf '{"agent_id":"%s","worktree_path":"%s","branch":"%s","expected_base":"%s"}\n' \
    "$NAME" "$ABS_TARGET" "$BRANCH" "$BASE_SHA" > "$MANIFEST_DIR/$NAME.json"
  say "manifest: $MANIFEST_DIR/$NAME.json (base ${BASE_SHA:0:9})"
fi

# 2. generate instances.conf in the target dir
build_conf > "$TARGET/instances.conf"
say "wrote $TARGET/instances.conf"
for agent in "${agent_list[@]}"; do [ "$agent" = codex ] && mkdir -p "$TARGET/.codex-home"; done

# 3. launch instances (cwd = target, so launcher keeps it and ht-webif inherits it)
if $LAUNCH; then
  [ -n "$LAUNCHER" ] && [ -x "$LAUNCHER" ] || { say "launch-agents.sh not on PATH nor in $WEBIF_DIR/scripts (run 'just install' in claude-p)"; exit 1; }
  command -v ht-webif >/dev/null 2>&1 || { say "ERROR: ht-webif not on PATH (run 'just install' in claude-p)"; exit 1; }
  ( cd "$TARGET" && "$LAUNCHER" up ) || { say "launch-agents up failed"; exit 1; }
  say "instances up (cwd=$TARGET)"
else
  say "skipped launch (pass --launch). To launch manually:"
  say "  ( cd \"$TARGET\" && \"${LAUNCHER:-launch-agents.sh}\" up )"
fi

# 4. optionally run moonlighting against this target's instances
if [ -n "$RUN_MOONLIGHTING" ]; then
  mkdir -p "$TARGET/.moonlighting"
  say "starting moonlighting (detached): $RUN_MOONLIGHTING"
  # shellcheck disable=SC2086
  nohup "$MOONLIGHTING" --conf-dir "$TARGET" --ma-client "$MA" --state-dir "$TARGET/.moonlighting" \
        --execute-agent "${agent_list[0]}" $RUN_MOONLIGHTING \
        > "$TARGET/.moonlighting/run.log" 2>&1 &
  echo "$!" > "$TARGET/.moonlighting/moonlighting.pid"   # run-queue.sh polls this for completion
  say "moonlighting PID $! — tail $TARGET/.moonlighting/progress.log"
else
  say "to run moonlighting on this target:"
  say "  $MOONLIGHTING --conf-dir \"$TARGET\" --ma-client \"$MA\" --state-dir \"$TARGET/.moonlighting\" --from <N>"
fi
