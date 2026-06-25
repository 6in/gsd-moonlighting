# gsd-moonlighting

GSD のフェーズ（`plan → execute → verify`）を**夜間に無人で**回しつつ、作業中の Claude の
コンテキストを肥大させないための **Claude Code スキル**。

各 GSD ステップを [ht-webif](https://github.com/6in/claude-p) の別 `--fresh` ターンとして
実行する。ターンごとにコンテキストはクリアされ、継続性は GSD のファイル（`.planning/*`）+
git に載る。ht-webif は対話型 Claude TUI を駆動するため、課金は Max サブスクのまま
（`claude -p` の API 課金が発生しない）。

このリポジトリは**オーケストレーション層（スキル本体）だけ**を持つ。実際にターンを駆動する
エンジン層（`ht-webif` バイナリ・helper スクリプト・agent プロファイル）は別リポジトリ
[`6in/claude-p`](https://github.com/6in/claude-p) が提供する。

```
6in/gsd-moonlighting ← このリポジトリ : skills/gsd-moonlighting/ （moonlighting.sh / spawn-worktree.sh / SKILL.md）
6in/claude-p         ← エンジン       : ht-webif(Rust) + launch-agents.sh / ma-client.sh + agents/*.toml
```

## 依存

| 依存 | 入手 |
|------|------|
| [`6in/claude-p`](https://github.com/6in/claude-p) | clone して `just install`（`ht-webif` / `ma-client.sh` / `launch-agents.sh` を `~/.local/bin/` に配置、agent プロファイルを `~/.config/claude-p/agents/` に配置） |
| Claude Code | 対話型 TUI を駆動するため必須 |
| GSD ワークフロー | 対象プロジェクトに `.planning/ROADMAP.md` + `STATE.md` が存在すること |

`spawn-worktree.sh` は helper を **PATH 優先**（`just install` → `~/.local/bin/`）で解決し、
無ければ `--webif-dir`（既定 `~/workspaces/claude-p`）の `scripts/` にフォールバックする。

## インストール

claude-p を先に入れる:

```bash
git clone https://github.com/6in/claude-p.git ~/workspaces/claude-p
cd ~/workspaces/claude-p && just install   # ht-webif + helper を ~/.local/bin、profile を ~/.config/claude-p/agents へ
```

スキルを Claude Code に認識させる（シンボリックリンク推奨 — このリポジトリの更新が即反映される）:

```bash
git clone https://github.com/6in/gsd-moonlighting.git ~/workspaces/moonlighting
ln -s ~/workspaces/moonlighting/skills/gsd-moonlighting ~/.claude/skills/gsd-moonlighting
```

## 使い方（最短）

対象 GSD プロジェクトを開いている Claude セッションで:

```
/gsd-moonlighting 3        # フェーズ3を無人実行（3-5 で範囲、only 3 で単発）
```

スキル経由を使わず直接起動する場合は対象プロジェクト dir から:

```bash
~/.claude/skills/gsd-moonlighting/scripts/spawn-worktree.sh \
  --here --agents claude --launch --run-moonlighting "--only 3 --steps plan,execute,verify"
```

監視 / 停止:

```bash
tail -f <project>/.moonlighting/progress.log          # 進捗
cat     <project>/.moonlighting/morning-queue.md       # 人間レビュー待ちで halt したフェーズ
kill "$(cat <project>/.moonlighting/moonlighting.pid)" # 停止
```

詳細は [`skills/gsd-moonlighting/SKILL.md`](skills/gsd-moonlighting/SKILL.md) と
[利用ガイド](skills/gsd-moonlighting/gsd-moonlighting-readme.md) を参照。

## 設計上の不変条件

- **launcher + monitor に徹する** — ループは `moonlighting.sh` がデタッチで回す。起動した
  Claude 自身のコンテキストでターンをポーリングし続けない（本末転倒）。
- **cwd 不変条件** — ht-webif は対象プロジェクト dir で起動する（driven claude がその cwd を
  継承する）。helper/バイナリは PATH から、cwd ではない。
- **discuss は人間が起きている間に** — 夜間ループにグレーゾーンの設計判断を自動回答させない。
  質問・ブロッカー・失敗・タイムアウトが出たら推測せず halt して `morning-queue.md` に積む。
