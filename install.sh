#!/usr/bin/env bash
# install.sh — install the gsd-moonlighting skill into Claude Code's skills dir.
#
# Default is a SYMLINK (this repo stays the source of truth; `git pull` updates the
# skill instantly). Use --copy for a detached copy. The engine layer (ht-webif +
# helper scripts) is NOT installed here — it comes from the separate 6in/claude-p
# repo via `just install`; this script only checks for it and warns.
#
# Usage:
#   ./install.sh                 # symlink skills/gsd-moonlighting -> ~/.claude/skills/gsd-moonlighting
#   ./install.sh --copy          # copy instead of symlink
#   ./install.sh --dest DIR      # install into DIR/gsd-moonlighting (default: ~/.claude/skills)
#   ./install.sh --force         # replace an existing destination
#   ./install.sh --uninstall     # remove the installed skill
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="gsd-moonlighting"
SRC="$REPO_DIR/skills/$SKILL_NAME"

SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
MODE="symlink"   # symlink | copy
FORCE=false
UNINSTALL=false

say() { printf '%s\n' "[install] $*" >&2; }
die() { printf '%s\n' "[install] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --copy) MODE="copy"; shift;;
    --symlink) MODE="symlink"; shift;;
    --dest) SKILLS_DIR="$2"; shift 2;;
    --force) FORCE=true; shift;;
    --uninstall) UNINSTALL=true; shift;;
    -h|--help) grep '^# ' "$0"; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

[ -f "$SRC/SKILL.md" ] || die "skill not found at $SRC (run from the repo, or pass --dest correctly)"
DEST="$SKILLS_DIR/$SKILL_NAME"

if $UNINSTALL; then
  if [ -L "$DEST" ] || [ -e "$DEST" ]; then
    rm -rf "$DEST"; say "removed $DEST"
  else
    say "nothing to remove at $DEST"
  fi
  exit 0
fi

# Already a symlink pointing at our source? Idempotent no-op.
if [ -L "$DEST" ] && [ "$(readlink -f "$DEST")" = "$(readlink -f "$SRC")" ]; then
  say "already linked: $DEST -> $SRC"
else
  if [ -L "$DEST" ] || [ -e "$DEST" ]; then
    $FORCE || die "destination exists: $DEST (use --force to replace, or --uninstall first)"
    rm -rf "$DEST"; say "replaced existing $DEST"
  fi
  mkdir -p "$SKILLS_DIR"
  if [ "$MODE" = "copy" ]; then
    cp -R "$SRC" "$DEST"; say "copied $SRC -> $DEST"
  else
    ln -s "$SRC" "$DEST"; say "linked $DEST -> $SRC"
  fi
fi

# Engine-layer dependency check (claude-p / just install). Warn only — not fatal.
missing=()
for dep in ht-webif ma-client.sh launch-agents.sh; do
  command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if [ "${#missing[@]}" -gt 0 ]; then
  say "WARNING: engine layer not on PATH: ${missing[*]}"
  say "  the skill needs 6in/claude-p installed. Run:"
  say "    git clone https://github.com/6in/claude-p.git ~/workspaces/claude-p"
  say "    cd ~/workspaces/claude-p && just install"
else
  say "engine layer OK (ht-webif + helpers on PATH)"
fi

say "done. In a Claude Code session: /$SKILL_NAME <phase>"
