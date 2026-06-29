#!/usr/bin/env bash
# moonlighting-doctor.sh — gsd-moonlighting を「他環境で動かす前」の事前環境診断ツール。
#
# flutter doctor 的に、対象 GSD プロジェクト dir から実行して 6 セクションを
# [OK]/[WARN]/[FAIL] で表示し、FAIL/WARN 行に「治すならここ」のヒントを添える。
# SKILL.md の Preconditions #1-6（とそこで踏んだ footgun）をそのまま機械チェックにしたもの。
#
# ma-doctor.sh との分担:
#   - ma-doctor.sh = マルチエージェント *ランタイム*（ht-webif / agents プロファイル / 認証 /
#     instances.conf / 稼働インスタンス）の深い診断。
#   - moonlighting-doctor.sh = moonlighting 固有の前提（スクリプト群 / driven-claude の環境設定 /
#     GSD プロジェクト + worktree 対応 gsd-core / gitignore）。ランタイムは ma-doctor に委譲。
#
# 設計原則（ma-doctor.sh を踏襲）:
#   - report-only: settings.json / PATH / gitignore へ一切書き込まない。
#   - FAIL が 1 つでもあれば exit 1、無ければ（WARN のみ含む）exit 0。
#   - 各チェックは個別失敗で abort しない（set -e は使わない）。
#
# 使い方:
#   moonlighting-doctor.sh                 # cwd の repo を診断
#   moonlighting-doctor.sh --repo DIR      # 対象 repo を明示
#   moonlighting-doctor.sh --help          # usage 表示

set -uo pipefail

# --- カウンタ ---
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# --- TTY 判定・カラー ---
if [[ -t 1 ]]; then
    COLOR_OK="\033[32m"; COLOR_WARN="\033[33m"; COLOR_FAIL="\033[31m"
    COLOR_RESET="\033[0m"; COLOR_BOLD="\033[1m"
else
    COLOR_OK=""; COLOR_WARN=""; COLOR_FAIL=""; COLOR_RESET=""; COLOR_BOLD=""
fi

ok()   { OK_COUNT=$((OK_COUNT+1));     echo -e "${COLOR_OK}[OK]${COLOR_RESET} $1"; }
warn() { WARN_COUNT=$((WARN_COUNT+1)); echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $1"; [[ -n "${2:-}" ]] && echo "  ヒント: $2"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); echo -e "${COLOR_FAIL}[FAIL]${COLOR_RESET} $1"; [[ -n "${2:-}" ]] && echo "  ヒント: $2"; }
info() { echo "  [INFO] $1"; }

usage() {
    cat <<EOF
使い方: $(basename "$0") [--repo DIR] [--help|-h]

gsd-moonlighting を別環境で動かす前の事前環境診断（report-only）。対象 GSD プロジェクト dir から
実行し、SKILL.md の Preconditions #1-6 を [OK]/[WARN]/[FAIL] で確認、治す場所をヒントで示す。

  $(basename "$0")              # cwd の repo を診断
  $(basename "$0") --repo DIR   # 対象 repo を明示

特徴:
  - report-only: 設定ファイルへ一切書き込まない
  - FAIL が 1 件でもあれば exit 1、無ければ exit 0
  - 末尾に OK/WARN/FAIL 件数サマリ

チェック内容（6 セクション）:
  1. moonlighting スクリプト群  spawn-worktree / run-queue / merge-worktrees / moonlighting.sh
  2. claude-p ランタイム(PATH)  ht-webif / ma-client.sh / launch-agents.sh + NO_FLICKER fix
  3. driven claude 環境設定     skipAutoPermissionPrompt / claude 認証 / フォルダ信頼
  4. GSD プロジェクト(cwd)      .planning/{ROADMAP,STATE}.md / worktree 対応 gsd-core
  5. gitignore(cwd)            instances.conf / turns-*/ / .moonlighting/ / .codex-home/
  6. 依存コマンド              git / node / curl / jq|python3 / nohup

関連: ランタイム/認証/稼働インスタンスの深い診断は ma-doctor.sh（claude-p）を併用。
EOF
}

# --- 引数 ---
REPO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0;;
        --repo) REPO="${2:-}"; shift 2;;
        *) echo "エラー: 不明な引数: $1" >&2; echo "" >&2; usage >&2; exit 1;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# JSON エンコーダ検出（settings.json 読み取り用）
JSON_ENCODER=""
if command -v jq >/dev/null 2>&1; then JSON_ENCODER="jq"
elif command -v python3 >/dev/null 2>&1; then JSON_ENCODER="python3"; fi

echo -e "${COLOR_BOLD}moonlighting-doctor — gsd-moonlighting 事前環境診断${COLOR_RESET}"
echo "診断日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo "対象 repo: ${REPO}"
echo ""

# ============================================================
# セクション 1: moonlighting スクリプト群
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 1: moonlighting スクリプト群 ===${COLOR_RESET}"
for s in spawn-worktree.sh run-queue.sh merge-worktrees.sh moonlighting.sh; do
    if [[ -f "${SCRIPT_DIR}/${s}" ]]; then
        if [[ -x "${SCRIPT_DIR}/${s}" ]]; then
            ok "${s} あり（実行可）: ${SCRIPT_DIR}/${s}"
        else
            warn "${s} はあるが実行権限なし: ${SCRIPT_DIR}/${s}" "chmod +x ${SCRIPT_DIR}/${s}"
        fi
    else
        fail "${s} が見つかりません: ${SCRIPT_DIR}/" "gsd-moonlighting スキルを再インストール/同期してください"
    fi
done
echo ""

# ============================================================
# セクション 2: claude-p ランタイム（PATH）
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 2: claude-p ランタイム（PATH）===${COLOR_RESET}"
for cmd in ht-webif ma-client.sh launch-agents.sh; do
    if p="$(command -v "$cmd" 2>/dev/null)"; then
        ok "${cmd} あり: ${p}"
    else
        fail "${cmd} が PATH にありません" "claude-p で 'just install' を実行してください（~/.local/bin/ へ配置）"
    fi
done

# 前提 #4: launch-agents.sh が CLAUDE_CODE_NO_FLICKER fix を含むか（fullscreen-renderer footgun）
if la="$(command -v launch-agents.sh 2>/dev/null)"; then
    if grep -q 'CLAUDE_CODE_NO_FLICKER' "$la" 2>/dev/null; then
        ok "launch-agents.sh に CLAUDE_CODE_NO_FLICKER fix あり（fullscreen-renderer footgun 対策）"
    else
        fail "PATH の launch-agents.sh に CLAUDE_CODE_NO_FLICKER の再注入がありません" \
            "古い launch-agents.sh です。claude-p を更新し 'just install' で再配置（新 Claude の初回ダイアログで起動が刺さる）"
    fi
fi

# $HOME/.local/bin が PATH にあるか
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ok "\$HOME/.local/bin が PATH に含まれています";;
    *) warn "\$HOME/.local/bin が PATH に含まれていません" "export PATH=\"\$HOME/.local/bin:\$PATH\" を ~/.bashrc 等に追加";;
esac
info "ランタイム/認証/稼働インスタンスの詳細診断は ma-client.sh と同居の ma-doctor.sh を併用してください"
echo ""

# ============================================================
# セクション 3: driven claude の環境設定（人がつまずく所）
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 3: driven claude の環境設定 ===${COLOR_RESET}"
SETTINGS="${HOME}/.claude/settings.json"

# 前提 #3: skipAutoPermissionPrompt: true（フォルダ信頼ダイアログ抑止）
if [[ ! -f "$SETTINGS" ]]; then
    fail "~/.claude/settings.json が見つかりません" \
        "{\"skipAutoPermissionPrompt\": true} を ~/.claude/settings.json に設定してください（未設定だと初回 dir で信頼ダイアログに刺さる）"
elif [[ -z "$JSON_ENCODER" ]]; then
    warn "JSON エンコーダ(jq/python3)が無く settings.json を確認できません" "jq か python3 をインストールしてください"
else
    skip_val=""
    case "$JSON_ENCODER" in
        jq)      skip_val="$(jq -r '.skipAutoPermissionPrompt // "missing"' "$SETTINGS" 2>/dev/null)";;
        python3) skip_val="$(python3 -c "import json;d=json.load(open('$SETTINGS'));v=d.get('skipAutoPermissionPrompt');print('true' if v is True else 'false' if v is False else 'missing')" 2>/dev/null)";;
    esac
    case "$skip_val" in
        true)  ok "skipAutoPermissionPrompt: true（フォルダ信頼ダイアログを抑止）";;
        false) fail "skipAutoPermissionPrompt が false" "true にしてください。false だと初回 dir/worktree で信頼ダイアログに刺さり turn が no-op になります";;
        *)     fail "skipAutoPermissionPrompt が未設定（${SETTINGS}）" "\"skipAutoPermissionPrompt\": true を追加してください（未設定だと初回 dir で信頼ダイアログに刺さる）";;
    esac
fi

# claude CLI と認証（driven claude 本体）
if command -v claude >/dev/null 2>&1; then
    ok "claude CLI あり: $(command -v claude)"
else
    fail "claude CLI が PATH にありません" "Claude Code をインストールしてください"
fi
creds="${HOME}/.claude/.credentials.json"
if [[ -f "$creds" ]]; then
    ok "claude 認証ファイルあり: ${creds}"
elif [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS は OAuth 認証情報を Keychain に保存し、.credentials.json は作られない。
    # 存在確認のみ（-g/-w を付けない限り Keychain ロック解除プロンプトは出ない）。
    if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
        ok "claude 認証: macOS Keychain に 'Claude Code-credentials' あり（macOS は .credentials.json を使わない）"
    else
        warn "claude 認証を確認できません（macOS Keychain に 'Claude Code-credentials' 未検出）" "claude にログイン済みか確認してください。macOS はファイルではなく Keychain に保存します（claude でログイン）"
    fi
else
    fail "claude 認証ファイルが見つかりません: ${creds}" "Max サブスクリプションでログインしてください（claude にログイン）"
fi

# フォルダ信頼（skipAuto があれば moot だが情報として）
CLAUDE_JSON="${HOME}/.claude.json"
if [[ -f "$CLAUDE_JSON" && -n "$JSON_ENCODER" ]]; then
    trusted=""
    case "$JSON_ENCODER" in
        jq)      trusted="$(jq -r --arg d "$REPO" '.projects[$d].hasTrustDialogAccepted // "missing"' "$CLAUDE_JSON" 2>/dev/null)";;
        python3) trusted="$(python3 -c "import json;d=json.load(open('$CLAUDE_JSON'));e=d.get('projects',{}).get('$REPO',{});v=e.get('hasTrustDialogAccepted');print('true' if v is True else 'false' if v is False else 'missing')" 2>/dev/null)";;
    esac
    case "$trusted" in
        true)    ok "フォルダ信頼: ${REPO} は信頼済み";;
        *)       info "フォルダ信頼: ${REPO} は未登録/未承認（skipAutoPermissionPrompt=true なら問題なし）";;
    esac
fi
echo ""

# ============================================================
# セクション 4: GSD プロジェクト（cwd）
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 4: GSD プロジェクト（${REPO}）===${COLOR_RESET}"
# 前提 #1: .planning/ROADMAP.md + STATE.md
for f in .planning/ROADMAP.md .planning/STATE.md; do
    if [[ -f "${REPO}/${f}" ]]; then
        ok "${f} あり"
    else
        fail "${f} が見つかりません" "GSD プロジェクトのルートで実行していますか？ 未初期化なら /gsd-new-project 等で作成してください"
    fi
done

# CONTEXT.md（discuss 済みか）— phase 個別は判定しきれないので情報提示
ctx_count=0
if [[ -d "${REPO}/.planning/phases" ]]; then
    ctx_count="$(find "${REPO}/.planning/phases" -name '*-CONTEXT.md' 2>/dev/null | wc -l | tr -d ' ')"
fi
if [[ "$ctx_count" -gt 0 ]]; then
    ok "discuss 済み CONTEXT.md: ${ctx_count} 件（対象 phase が discuss 済みか個別に確認を）"
else
    warn "CONTEXT.md が 1 件もありません" "moonlighting は discuss 済み phase 専用。対象 phase を /gsd-discuss-phase してから起動してください"
fi

# 前提 #5: worktree 対応 gsd-core（merge-worktrees.sh の resolver を再現）
if command -v node >/dev/null 2>&1; then
    gsd_has_worktree() { local out; out="$(eval "$1 query worktree cleanup-wave" 2>&1)"; printf '%s' "$out" | grep -q 'Usage: worktree cleanup-wave'; }
    GSD_FOUND=""; cands=()
    [[ -f "${REPO}/gsd-core/bin/gsd-tools.cjs" ]]         && cands+=("node ${REPO}/gsd-core/bin/gsd-tools.cjs")
    [[ -f "${REPO}/.claude/gsd-core/bin/gsd-tools.cjs" ]] && cands+=("node ${REPO}/.claude/gsd-core/bin/gsd-tools.cjs")
    [[ -f "${HOME}/.claude/gsd-core/bin/gsd-tools.cjs" ]] && cands+=("node ${HOME}/.claude/gsd-core/bin/gsd-tools.cjs")
    command -v gsd-tools >/dev/null 2>&1                  && cands+=("gsd-tools")
    for c in "${cands[@]}"; do gsd_has_worktree "$c" && { GSD_FOUND="$c"; break; }; done
    if [[ -n "$GSD_FOUND" ]]; then
        ok "worktree 対応 gsd-tools あり: ${GSD_FOUND}"
        # PATH gsd-tools しか無い＝worktree 非対応の落とし穴を明示
        if [[ "$GSD_FOUND" == "gsd-tools" ]]; then
            info "PATH の gsd-tools が採用されました（worktree 対応版）。問題なし"
        fi
    else
        if [[ ${#cands[@]} -eq 0 ]]; then
            fail "gsd-tools.cjs が見つかりません" "npx -y @opengsd/gsd-core@latest --claude --local を実行（merge-worktrees.sh が worktree cleanup-wave に必要）"
        else
            fail "見つかった gsd-tools がどれも 'worktree cleanup-wave' 非対応" \
                "global-npm の古い gsd-tools のみのようです。gsd-core を導入してください（npx -y @opengsd/gsd-core@latest --claude --local）"
        fi
    fi
else
    fail "node が無く gsd-tools を確認できません" "Node.js をインストールしてください（gsd-tools.cjs の実行に必須）"
fi
echo ""

# ============================================================
# セクション 5: gitignore（cwd）
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 5: gitignore（ランタイム scratch）===${COLOR_RESET}"
# 前提 #6: 未追跡の scratch が残ると cleanup-wave の clean-tree チェックで merge が止まる
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    # ディレクトリ専用パターン（X/）は、問い合わせパスに末尾スラッシュを付けないと
    # 実在しない dir にマッチしない（check-ignore は filesystem を stat しない）。
    # instances.conf はファイルなのでスラッシュ無し、残り 3 つは dir なので末尾 / 付き。
    for entry in instances.conf turns-5080/ .moonlighting/ .codex-home/; do
        if git -C "$REPO" check-ignore -q "$entry" 2>/dev/null; then
            ok "gitignore 済み: ${entry}"
        else
            warn "gitignore されていません: ${entry}" \
                ".gitignore に instances.conf / turns-*/ / .moonlighting/ / .codex-home/ を追加（未追跡 scratch が cleanup-wave の clean-tree を阻害）"
        fi
    done
else
    warn "${REPO} は git repo ではありません（gitignore チェックをスキップ）" "git init 済みの GSD プロジェクトで実行してください"
fi
echo ""

# ============================================================
# セクション 6: 依存コマンド
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 6: 依存コマンド ===${COLOR_RESET}"
for cmd in git node curl nohup; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "${cmd} あり: $(command -v "$cmd")"
    else
        fail "${cmd} が PATH にありません" "${cmd} をインストールしてください"
    fi
done
if [[ -n "$JSON_ENCODER" ]]; then
    ok "JSON エンコーダ: ${JSON_ENCODER}"
else
    fail "jq か python3 のいずれかが必要です" "jq または python3 をインストールしてください（例: apt install jq）"
fi
echo ""

# ============================================================
# 末尾サマリ
# ============================================================
echo "------------------------------------------------------------"
echo -e "診断結果: ${COLOR_OK}OK=${OK_COUNT}${COLOR_RESET} ${COLOR_WARN}WARN=${WARN_COUNT}${COLOR_RESET} ${COLOR_FAIL}FAIL=${FAIL_COUNT}${COLOR_RESET}"
if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "FAIL が ${FAIL_COUNT} 件あります。上記ヒントを参照して修正してください。"
    exit 1
fi
if [[ $WARN_COUNT -gt 0 ]]; then
    echo "FAIL なし。WARN ${WARN_COUNT} 件は起動前に確認推奨です。"
fi
exit 0
