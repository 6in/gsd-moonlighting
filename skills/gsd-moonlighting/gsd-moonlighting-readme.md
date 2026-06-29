# gsd-moonlighting 利用ガイド

GSD のフェーズ（plan → execute → verify）を**夜間に無人で**回しつつ、作業中の Claude の
コンテキストを肥大させないためのスキル＋スクリプト群。

`gsd-autonomous` は1セッション内でフェーズを連続実行するためコンテキストが膨張するが、
本スキルは各 GSD ステップを **ht-webif の別 `--fresh` ターン**として実行する。ターンごとに
コンテキストはクリアされ、継続性は GSD のファイル（`.planning/*`）＋ git に載る。ht-webif は
対話型 Claude TUI を駆動するため **課金は Max サブスクのまま**（`claude -p` の API 課金なし）。

> あなた（このスキルを起動する Claude）は **launcher + monitor** であって loop runner では
> ない。ループは `scripts/moonlighting.sh` がデタッチで回す。自分のコンテキストでターンを
> ポーリングし続けない（それをやると本末転倒でこのセッションも膨張する）。

---

## いちばん簡単な起動方法（スキル経由）

**対象 GSD プロジェクトを開いている Claude セッションで、こう打つだけ:**

```
/gsd-moonlighting 3
```

- 引数はフェーズセレクタ: `3`（=フェーズ3）/ `3-5`（=3〜5を順に）/ `only 3`（=3だけ）。
  省略すると、対象スコープを対話で確認してから起動する。
- これを受けた Claude（このスキル）が **launcher として**次を自動で行う:
  1. **前提チェック** — いま target GSD プロジェクト dir にいるか（`.planning/ROADMAP.md`＋
     `STATE.md`）、対象フェーズが `/gsd-discuss-phase` 済みか、`ht-webif`/profile が揃っているか
  2. **スコープ確認** — どのフェーズを、どのステップ（plan/execute/verify）で、どの profile
     （モデル振り分け）で回すかをあなたに確認
  3. **起動** — `scripts/spawn-worktree.sh --here --launch --run-moonlighting ...` を実行して
     instances.conf 生成 → この dir で ht-webif 起動 → `moonlighting.sh` を**デタッチ**で開始
  4. **報告して終了** — moonlighting の PID と監視コマンドを返し、**ループには張り付かない**

> つまり日常的にはスキルを起動するだけでよく、下の §3 以降の生スクリプトは「スキルが内部で
> 叩いているもの」＝仕組みの説明・手動運用・トラブル時の確認用。

### スキルを使わず手動で起動したいとき
スクリプトを直接叩いてもよい（CI/cron や、スキルを介さず細かく制御したいとき）。手順は §3
（単一プロジェクト）・§5（並行 worktree）を参照。スキル経由と等価。

---

## 0. 前提（once-only セットアップ）

`claude-p`（`/home/parallels/workspaces/claude-p`）で `just install` 済みであること。これで
PATH（`~/.local/bin/`）に次が入る:

- `ht-webif`（バイナリ）
- `launch-agents.sh`（多重インスタンスの起動/停止/状態）
- `ma-client.sh`（WebIf への curl ラッパー）

確認:
```bash
command -v ht-webif ma-client.sh launch-agents.sh   # 3つとも出ればOK
```

### エージェント profile の場所（重要）
ht-webif は `AGENT=<名前>` から **`~/.config/claude-p/agents/<名前>.toml`** を読む。
ここに profile が無いと、インスタンスは起動直後に
`Error: agents/<名前>.toml が見つかりません（探索: ~/.config/claude-p/agents）` で**即死**する
（turns も `.moonlighting` も残らない＝「失敗っぽいのに痕跡なし」の典型原因）。

同梱 profile: `claude` / `codex` / `opencode`。

---

## 1. cwd 不変条件（最初に理解する）

**各 Claude は自分の作業ディレクトリ上で動く。** ht-webif は launcher の cwd を保ち
（`launch-agents.sh` は `cd` しない）、駆動される claude TUI もそれを継承する。したがって
**ht-webif は対象 GSD プロジェクト dir（このスキルを起動したセッションの cwd）で起動する**。

`claude-p` は「スクリプト＋バイナリ＋profile」の置き場であって、cwd ではない。`spawn-worktree.sh`
が `instances.conf` 生成と「正しい dir での起動」を肩代わりする（その場 or worktree）。

---

## 2. モデルルーティング（PLAN=Opus / EXECUTE=Sonnet / VERIFY=Opus）

profile はモデルを `model_flag = "--model"` ＋ `model_value = "opus"|"sonnet"` で指定し、
ht-webif は `claude --model <m>` を起動する。役割ごとに別モデルを当てるには、モデル別 profile
を作って `instances.conf` のエージェント名で参照し、moonlighting の
`--plan-agent / --execute-agent / --verify-agent` で振り分ける。

本リポジトリでは次の2 profile を作成済み（`~/.config/claude-p/agents/` と
`claude-p/agents/` の両方に配置 = 再インストールでも消えない）:

| profile | model | 役割 |
|---------|-------|------|
| `opus.toml` | `--model opus` | plan / verify（強いモデル） |
| `sonnet.toml` | `--model sonnet` | execute（量をこなす安価なモデル） |

moonlighting はステップを逐次実行するので、**plan と verify は同じ `opus` インスタンスを共用**
できる（別ターンなので衝突しない）。よって2インスタンスで足りる:

```
# instances.conf（spawn-worktree.sh が生成）
opus       5080
sonnet     5081
```

完全分離したい（plan と verify を別プロセスに）なら3つ目を足す:
```bash
# 例: opus2 profile を作り、--agents opus,sonnet,opus2 で起動、--verify-agent opus2
cp ~/.config/claude-p/agents/opus.toml ~/.config/claude-p/agents/opus2.toml
```

### 新しいモデル profile の作り方
```bash
cp ~/.config/claude-p/agents/claude.toml ~/.config/claude-p/agents/<name>.toml
# 末尾のコメントを外して2行を設定:
#   model_flag  = "--model"
#   model_value = "opus"      # or "sonnet" / フルモデルID
cp ~/.config/claude-p/agents/<name>.toml /home/parallels/workspaces/claude-p/agents/  # source にも
```

---

## 3. クイックスタート（単一プロジェクト、その場で実行）

対象 GSD プロジェクト dir で（`.planning/ROADMAP.md` ＋ `STATE.md` があり、対象フェーズは
`/gsd-discuss-phase` 済み）:

```bash
cd <あなたのGSDプロジェクト>

# (a) ポート計画と instances.conf の中身を確認（何も起動しない）
~/.claude/skills/gsd-moonlighting/scripts/spawn-worktree.sh \
  --here --agents opus,sonnet --dry-run

# (b) instances.conf 生成 → この dir で ht-webif 起動 → moonlighting をデタッチ起動、まで一発
~/.claude/skills/gsd-moonlighting/scripts/spawn-worktree.sh \
  --here --agents opus,sonnet --launch \
  --run-moonlighting "--only <N> --steps plan,execute,verify \
    --plan-agent opus --execute-agent sonnet --verify-agent opus"
```

初回は **`--steps plan` だけ**で1ターン観察し、問題なければ `plan,execute,verify` に広げると安全。

---

## 4. フェーズ選択

moonlighting は対象フェーズの明示が必須（指定しないと `.moonlighting` を作る前に即 exit する＝痕跡が
残らない）。

- `--only N` … 単一フェーズ（PoC 向き）
- `--from N [--to M]` … 範囲を順に

> "plan から始める" には対象フェーズが**未計画**である必要がある。全フェーズに既に `PLAN.md`
> がある場合は、新フェーズ追加（`gsd-tools phase add` 等）か再計画（`--gaps`/replan）を先に。

---

## 5. 並行 worktree（複数ジョブを同時に）

1つの ht-webif インスタンス群は1つの作業 dir しか担当できない。複数フィーチャを並行させるには、
各ジョブに **git worktree ＋ ポートずらしの instances.conf** を与える（`claude-p` 自体は不変）:

```bash
# index→ポート帯: 0=5080.., 1=5090.., 2=5100..（--stride 既定10 > agent数）
~/.claude/skills/gsd-moonlighting/scripts/spawn-worktree.sh \
  --repo <source-repo> --name feat-a --index 0 --agents opus,sonnet \
  --launch --run-moonlighting "--only 2 --plan-agent opus --execute-agent sonnet"

# 複数ファンアウト
for i in 0 1 2; do
  ~/.claude/skills/gsd-moonlighting/scripts/spawn-worktree.sh \
    --repo <repo> --name "job$i" --index "$i" --agents opus,sonnet \
    --launch --run-moonlighting "--only $((i+2)) --execute-agent sonnet"
done
```
worktree（branch `moonlighting/<name>`）を作り、その中に instances.conf を `BASE+index*STRIDE+k`
ポートで書き、**cwd=worktree** で起動 → そのポートに対し moonlighting を回す。ポートが一意なので
PID/LOG（`/tmp/ht-webif-<port>.*`）も turns dir も自動分離。`codex` は worktree ごとの
`CODEX_HOME` を持つ。

---

## 6. 監視・停止

```bash
tail -f <project>/.moonlighting/progress.log      # 進捗（narrator ライン）
cat   <project>/.moonlighting/morning-queue.md     # halt されたフェーズ（理由つき）
kill "$(cat <project>/.moonlighting/moonlighting.pid)"  # moonlighting ループを止める

# ht-webif インスタンスの停止（起動した dir で。instances.conf を読む）
( cd <project> && launch-agents.sh down-all )
launch-agents.sh status                          # 状態確認
# worktree なら最後に: git -C <repo> worktree remove <worktree>
```

---

## 7. 動作の仕組み（完了検知と halt）

- **完了検知ハンドシェイク**: ht-webif は fresh ターンで `/clear` → プロンプト送信 → Enter の後、
  駆動 claude が **result ファイル → status ファイル（`{"status":"done"}`）を自分で書く**のを待つ。
  この status ファイルが完了シグナル。
- **無人実行**: moonlighting のプロンプトは本家 `gsd-autonomous` と同じく
  `Skill(skill="gsd-plan-phase", args="<N> --auto")` /
  `gsd-execute-phase "<N> --auto --no-transition"` / `gsd-verify-work "<N>"` を起動させる。
- **grey-area で止める（推測しない）**: 質問・判断・blocker・escalation が必要になったら、駆動
  claude は本文先頭に `MOONLIGHTING_BLOCKED: <理由>` を1行書いて停止。moonlighting はそれ（status が
  `done`/`failed` いずれでも本文に marker があれば）を検出して **halt し
  `morning-queue.md` に理由行を記録**、人間の朝の判断に委ねる。
- **discuss は人間が起きている間に**: 設計判断は `/gsd-discuss-phase` で事前に確定。夜間ループは
  plan → execute（→ verify）のみ。

---

## 8. トラブルシュート

| 症状 | 原因 / 対処 |
|------|------|
| 起動失敗・**痕跡なし**（instances.conf も .moonlighting も無い） | profile 不在で即死 → `~/.config/claude-p/agents/<agent>.toml` を作る。`/tmp/ht-webif-<port>.log` の先頭にエラーが出る |
| `moonlighting: specify --only N or --from N` で即終了 | フェーズ未指定。`--only`/`--from` を渡す（この exit は `.moonlighting` 作成前なので痕跡が残らない） |
| plan が `§13a Decision Coverage Gate` で halt | locked 決定（CONTEXT の D-xx）が PLAN の `must_haves`（truths/artifacts/key_links）に引用されていない。PLAN の must_haves に該当決定を引用して再コミット、または CONTEXT 側で informational/Discretion 扱いに |
| ターンが `running` のまま進まない | スキル末尾の対話メニューで待っている可能性。次ターンの `/clear` で解消されるが、`--timeout`（既定7200s=2h）で halt されるので朝 queue を確認 |
| `ht-webif が PATH にありません` | `claude-p` で `just install` |
| 課金が心配 | ht-webif は対話 TUI を駆動するので Max サブスク課金。`claude -p`/`ANTHROPIC_API_KEY` は使わない |

---

## 9. フラグ早見表

### `spawn-worktree.sh`
```
--here [--dir DIR]      その場で実行（対象 = cwd または DIR）。NAME 既定=basename, INDEX 既定=0
--repo R --name N --index I   git worktree を作って対象に（並行ジョブ）
--agents a,b            ポート順のエージェント（profile 名と一致）。既定: claude
--base-port N           先頭ポート（既定 5080）
--stride N              対象あたりのポート数（既定10。agent 数より大きいこと）
--branch NAME           worktree のブランチ（既定 moonlighting/<name>）
--worktrees-root D      worktree の親（既定 <repo>/../<repo>-wt）
--webif-dir DIR         PATH に無い場合の helper script フォールバック（既定 claude-p）
--launch                実際に ht-webif を起動（要 ht-webif on PATH）
--run-moonlighting "ARGS"  起動後 moonlighting をデタッチ起動（フェーズ引数を渡す）
--dry-run               計画と conf を表示するだけ
```

### `moonlighting.sh`
```
--only N | --from N [--to M]   実行フェーズ（必須）
--steps a,b                    ステップ列（既定: plan,execute）。verify も可
--plan-agent A                 plan 用エージェント（既定 claude）
--execute-agent A              execute 用エージェント
--verify-agent A               verify 用エージェント（execute と別モデルにすると検証が強い）
--conf-dir DIR                 instances.conf の場所 = 対象 cwd（既定 $PWD）
--ma-client PATH               ma-client.sh の明示パス（既定: PATH → claude-p/scripts）
--webif-dir DIR                helper script フォールバック（既定 claude-p）
--timeout SEC                  ターンごとのタイムアウト（既定 7200 = 2時間）
--poll SEC                     ポーリング間隔（既定 60）
--state-dir DIR                progress/queue/pid の置き場（既定 ./.moonlighting）
--dry-run                      送信する ma-client コマンドを表示するだけ
```

---

## 10. 不変条件（破らない）

- **cwd 不変条件**: ht-webif は対象プロジェクト dir で起動。`--webif-dir`(claude-p) は
  スクリプト/バイナリ/profile の置き場であって cwd ではない。
- ループはデタッチで回す。このスキルを起動した Claude のコンテキストでポーリングしない。
- discuss は人間が起きている間に。夜間ループに grey-area の設計判断を自動回答させない
  （halt して queue する）。
- WebIf I/O はすべて `ma-client.sh` 経由。生 curl を書かない。
- `.gitignore` に `instances.conf` / `turns-*/` / `.moonlighting/` / `.codex-home/` を追加して
  生成物をコミットに混ぜない。
