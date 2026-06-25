#!/usr/bin/env bash
# merge-worktrees.sh — reconcile parallel moonlighting worktrees back into REPO.
#
# Split of concerns (the "smart" part):
#   CODE  -> GSD's validated `worktree cleanup-wave`: per-branch `git merge --no-ff`
#            guarded by base-match / no-deletions / clean-tree / SUMMARY-rescue checks.
#   META  -> STATE.md is NEVER text-merged. A `merge=ours` driver keeps cleanup-wave from
#            conflicting on it, then `gsd query state sync` REGENERATES the counters from
#            the on-disk phase artifacts (.planning/phases/*/). ROADMAP rows are per-phase
#            distinct lines so git 3-way-merges them; `validate consistency` asserts the end.
#
# Inputs: per-worktree manifest entries written by spawn-worktree.sh into
#   <REPO>/.moonlighting/manifest.d/<name>.json  ({agent_id,worktree_path,branch,expected_base})
#
# Constraints inherited from cleanup-wave:
#   - branch names MUST match ^worktree-agent-[A-Za-z0-9._/-]+$ (spawn-worktree.sh enforces)
#   - a worktree branch that DELETES any file vs its base is BLOCKED (additive phases only)
#   - the worktree dir must still exist + be clean; cleanup-wave removes it on success
set -uo pipefail

REPO=""; DRY_RUN=false; NO_COMMIT=false; SELECT=""
WEBIF_DIR="${WEBIF_DIR:-/home/parallels/workspaces/claude-p}"

usage() {
  cat >&2 <<'EOF'
merge-worktrees.sh — reconcile parallel moonlighting worktrees back into the repo.

  --repo DIR     repo to integrate into (default: `git rev-parse --show-toplevel`)
  --select LIST  comma-list of worktree names (agent_id) to merge — the human gate:
                 only phases that passed manual verification. Default: ALL entries.
  --dry-run      assemble + print the manifest and planned steps; merge nothing
  --no-commit    run cleanup-wave + state sync but do not git-commit the reconcile
  -h|--help
EOF
  exit 1
}
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --select) SELECT="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-commit) NO_COMMIT=true; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
say() { printf '%s\n' "$*" >&2; }

REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$REPO" ] && [ -d "$REPO/.git" ] || git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || { say "merge-worktrees: --repo is not a git repo: $REPO"; exit 1; }

# Resolve gsd-tools. NB: the global-npm PATH `gsd-tools` can be an OLDER build that lacks the
# `worktree` command (and miscomputes progress); the local gsd-core install has cleanup-wave.
# So we prefer the gsd-core shims and AUTO-SELECT the first candidate that actually recognises
# `worktree cleanup-wave` — never blindly trust PATH.
# Capture-then-grep (NOT a pipe): cleanup-wave exits 2 on the missing-arg probe, and `pipefail`
# would otherwise propagate that 2 even when grep matches.
gsd_has_worktree() { local out; out="$(eval "$1 query worktree cleanup-wave" 2>&1)"; printf '%s' "$out" | grep -q 'Usage: worktree cleanup-wave'; }
GSD=""; cands=()
[ -f "$REPO/gsd-core/bin/gsd-tools.cjs" ]         && cands+=("node $REPO/gsd-core/bin/gsd-tools.cjs")
[ -f "$REPO/.claude/gsd-core/bin/gsd-tools.cjs" ] && cands+=("node $REPO/.claude/gsd-core/bin/gsd-tools.cjs")
[ -f "$HOME/.claude/gsd-core/bin/gsd-tools.cjs" ] && cands+=("node $HOME/.claude/gsd-core/bin/gsd-tools.cjs")
command -v gsd-tools >/dev/null 2>&1              && cands+=("gsd-tools")
for c in "${cands[@]}"; do gsd_has_worktree "$c" && { GSD="$c"; break; }; done
[ -n "$GSD" ] || { say "merge-worktrees: no gsd-tools with 'worktree cleanup-wave' support found (need the gsd-core install, not just the global-npm PATH shim)"; exit 1; }
say "gsd-tools: $GSD"
gsd() { ( cd "$REPO" && eval "$GSD \"\$@\"" ) ; }

MANIFEST_DIR="$REPO/.moonlighting/manifest.d"
OUT="$REPO/.moonlighting/cleanup-manifest.json"
[ -d "$MANIFEST_DIR" ] || { say "merge-worktrees: no manifest dir ($MANIFEST_DIR) — nothing spawned?"; exit 1; }
shopt -s nullglob; entries=("$MANIFEST_DIR"/*.json); shopt -u nullglob
[ "${#entries[@]}" -gt 0 ] || { say "merge-worktrees: no manifest entries in $MANIFEST_DIR"; exit 1; }

# assemble per-entry files into a single {worktrees:[...]} manifest (node: always present w/ gsd).
# --select FILTERS to approved names (agent_id); empty = keep all. Names with no match -> error.
node -e '
  const fs=require("fs"),p=require("path");
  const dir=process.argv[1], out=process.argv[2];
  const sel=(process.argv[3]||"").split(",").map(s=>s.trim()).filter(Boolean);
  let ws=fs.readdirSync(dir).filter(f=>f.endsWith(".json"))
    .map(f=>JSON.parse(fs.readFileSync(p.join(dir,f),"utf8")));
  if (sel.length) {
    const have=new Set(ws.map(w=>w.agent_id));
    const missing=sel.filter(s=>!have.has(s));
    if (missing.length) { process.stderr.write(`--select names not in manifest: ${missing.join(", ")}\n`); process.exit(3); }
    ws=ws.filter(w=>sel.includes(w.agent_id));
  }
  if (!ws.length) { process.stderr.write("no manifest entries after select\n"); process.exit(4); }
  fs.writeFileSync(out, JSON.stringify({worktrees:ws}, null, 2));
  process.stderr.write(`assembled ${ws.length} entr${ws.length===1?"y":"ies"}${sel.length?` (selected: ${sel.join(",")})`:""} -> ${out}\n`);
' "$MANIFEST_DIR" "$OUT" "$SELECT" || { say "merge-worktrees: manifest assembly failed (or --select mismatch)"; exit 1; }

say "=== merge-worktrees: repo $REPO ==="
say "--- manifest ---"; cat "$OUT" >&2

if $DRY_RUN; then
  say "--- DRY-RUN: would set merge.ours.driver, write .gitattributes, run:"
  say "      gsd query worktree cleanup-wave --manifest $OUT"
  say "      gsd query state sync && gsd query validate consistency"
  exit 0
fi

# 1. install the `ours` driver (NOT built-in) + .gitattributes so STATE.md never conflicts
git -C "$REPO" config merge.ours.driver true
GA="$REPO/.gitattributes"
grep -qs 'STATE.md merge=ours' "$GA" 2>/dev/null \
  || printf '%s\n' '# moonlighting: STATE.md is regenerated by `gsd query state sync`, never merged' \
                   '.planning/STATE.md merge=ours' >> "$GA"
if ! git -C "$REPO" diff --quiet -- .gitattributes 2>/dev/null || \
   [ -n "$(git -C "$REPO" status --porcelain -- .gitattributes)" ]; then
  git -C "$REPO" add .gitattributes
  $NO_COMMIT || git -C "$REPO" commit -q -m 'chore: STATE.md merge=ours for worktree reconcile' || true
fi

# 2. CODE merge via GSD's validated cleanup-wave (also removes the worktrees on success)
say "--- cleanup-wave ---"
gsd query worktree cleanup-wave --manifest "$OUT"; wave_rc=$?
if [ "$wave_rc" -ne 0 ]; then
  say "merge-worktrees: cleanup-wave reported blocked (rc=$wave_rc) — resolve the listed entry, then re-run."
  say "  (common causes: branch_contains_deletions, worktree_dirty, base_mismatch, merge_failed)"
  exit "$wave_rc"
fi

# 3. META regen: recompute STATE.md counters from disk; assert consistency
say "--- state sync ---";          gsd query state sync
say "--- validate consistency ---"; gsd query validate consistency || true

# 4. commit the regenerated meta
if ! $NO_COMMIT; then
  git -C "$REPO" add .planning/STATE.md .planning/ROADMAP.md 2>/dev/null || true
  git -C "$REPO" diff --cached --quiet || \
    git -C "$REPO" commit -q -m 'chore: reconcile STATE/ROADMAP after worktree wave'
fi

# 5. clear the consumed manifest entries (worktrees are gone)
rm -f "$MANIFEST_DIR"/*.json "$OUT"
say "=== merge-worktrees: done ==="
