# harness

AI駆動開発チームのための汎用ハーネスプラグイン。

Claude Code プラグインとして、任意のリポジトリに横展開できるエージェント・スキル・フックのセットを提供します。

---

## 概要

開発者がAIエージェントチームを統率し、並列開発で生産性を最大化する「AI駆動開発」のためのハーネスです。

- **プロジェクト非依存**: 特定のフレームワークやドメインに依存しない汎用設計
- **CLAUDE.md連携**: プロジェクト固有の設定はCLAUDE.mdに記述するだけで動作
- **star 型並列実装**: 複数Issueをリード（オーケストレーター）が `ticket-worker` サブエージェントに並列委譲して実装（ADR 0001 決定2）
- **カスタマイズ可能**: エージェント・スキルをプロジェクト側でオーバーライド可能

### 含まれる機能

| カテゴリ | 内容 |
|---------|------|
| エージェント (6) | コードレビュー、設計レビュー、機能実装(設計成果物＋TDD: feature-implementer)、チケット実装worker(ticket-worker)、ドキュメント整合性検証、E2Eテスト実装(e2e-engineer) |
| スキル | 機能定義(要件＋クリティカル設計)、チケット作成、並列実装、TDD実装、技術負債チェック、プロジェクト初期設定、E2Eテスト作成、E2Eテストシナリオ解説＋独立検証、動作確認(デモ)、PRレビュー対応、PRマージ、Conventional Commits、PRセルフレビュー、品質ゲートチェック、公開面×テスト担保の診断(surface-audit)、設計判断記録(ADR)の作成 |
| フック (1) | Write/Edit後の自動フォーマット |
| ワークフロー定義 (1) | ブランチ戦略 |

---

## インストール

```bash
# マーケットプレイス経由（Claude Code内で実行）
/plugin marketplace add masanami/claude-harness
/plugin install claude-harness@masanami-harness --scope user

# ローカルのプラグインディレクトリを指定して起動
claude --plugin-dir /path/to/claude-harness
```

> **Note**: `--scope user` を指定すると `.claude/settings.json` に記録され、プロジェクト単位で管理できます。省略するとユーザースコープ（全プロジェクト共通）にインストールされます。

### スクリプトランチャーの導入（推奨・一度きり）

スキルが同梱スクリプトを実行する際は、PATH 上のランチャー `claude-harness-run` を経由します。これを導入すると、利用側は `Bash(claude-harness-run:*)` の1行を許可するだけでよく、プラグイン更新で許可が外れません（未導入でも動きますが、headless 実行では permission 拒否になりえます）。

```bash
# 1. インストール先を、ランチャー自身と同じ規則で解決する
#    （CLAUDE_HARNESS_ROOT 優先 → installed_plugins.json → cache 配下）
#    **候補を検証してからバージョン降順に最初の1件を採る**。最大バージョンを先に選ぶと、
#    その実体が消えている場合に有効な旧候補を飛ばして解決に失敗する（bin/claude-harness-run
#    の chr_resolve_from_installed_json も、この順で候補を絞ってから選んでいる）。
#    各所の `|| true` は set -e 下で落ちないため（未導入の環境では installed_plugins.json が
#    無く jq が非0で終わる＝まさにこの手順を実行する状況）。
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SRC="${CLAUDE_HARNESS_ROOT:-}"
if [ -z "$SRC" ]; then
  while IFS= read -r cand; do
    if [ -n "$cand" ] && [ -f "${cand%/}/bin/claude-harness-run" ]; then SRC="${cand%/}"; break; fi
  done <<EOF
$(jq -r '[ (.plugins // {}) | to_entries[]
    | select(.key | startswith("claude-harness@"))
    | (if (.value | type) == "array" then .value[] else .value end)
    | select(type == "object" and .installPath != null) ]
  | sort_by(.version // "0" | split(".") | map(tonumber? // 0)) | reverse
  | .[].installPath' "$CONFIG_DIR/plugins/installed_plugins.json" 2>/dev/null || true)
$(ls -d "$CONFIG_DIR"/plugins/cache/*/claude-harness/*/ 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n -r || true)
EOF
fi

# 2. ランチャーを PATH 上へコピーする
mkdir -p ~/.local/bin
install -m 0755 "$SRC/bin/claude-harness-run" ~/.local/bin/claude-harness-run

# 3. 疎通確認（シェルからと、Claude Code の Bash ツールからの両方で実行する）
claude-harness-run --plugin-root   # プラグインルートの絶対パスが表示される
claude-harness-run --list          # 実行可能なスクリプト一覧が表示される
```

手順の詳細・allowlist の書き方・トラブルシューティングは [スクリプトランチャー](docs/script-launcher.md) を参照してください。

### 更新

```
/plugin
```

プラグイン管理画面から harness を選択し、更新を実行してください。

ローカルディレクトリ指定（`--plugin-dir`）の場合は `git pull` で更新してください。

---

## クイックスタート

1. プラグインをインストール
2. `/init-project` で `CLAUDE.md` を自動生成（エージェントはすべて `CLAUDE.md` 経由でプロジェクト情報を取得します）
3. `/para-impl 123` でIssue #123の実装を開始
4. `/para-impl 123 456 789` で複数Issueを star 型で並列実装

---

## スキル一覧

### 開発ワークフロー

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/define-feature` | `/define-feature [テーマ]` | 対話から機能仕様ドキュメント(`docs/features/{slug}.md`)を作成。要件＋クリティカル設計決定＋(必要なら)機能全体の設計を1ドキュメントに集約 |
| `/create-ticket` | `/create-ticket <機能specパス or 親Issue番号>` | 機能仕様→親要件チケット、または親Issue→実装チケット群に分解（GitHub Issue 作成専用） |
| `/para-impl` | `/para-impl {Issue番号...}` | Issueを分析→実装→PR作成（複数Issue時は star 型並列実装） |
| `/pr-review-respond` | `/pr-review-respond [PR番号]` | PRレビューコメントへの対応 |
| `/pr-merge` | `/pr-merge [PR番号]` | PRのレビューとマージ |
| `/reduce-debt` | `/reduce-debt {親Issue番号}` | 親Issueの実装範囲を技術負債スキャン→必要に応じて修正Issue起票 |

### テスト・品質

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/create-e2e` | `/create-e2e [Issue/PR/機能]` | 仕様ベースのE2Eテスト設計→実装→実行（非対話） |
| `/explain-e2e` | `/explain-e2e [テスト/Issue/PR]` | 実装済みE2Eのテストシナリオ解説（Phase 1・メインセッションで対話的に）と独立検証（Phase 2・Task直接委譲） |
| `/demo` | `/demo [Issue/PR/機能]` | AIがHeaded Playwrightで動作確認（ユーザーは観察して承認） |
| `/demo-e2e` | `/demo-e2e [カタログCSV/CASE_ID/specファイル/画面名]` | E2Eテストケースカタログと突き合わせ、1ケースごとに解説→実演（Headed Playwright）→人間判定を繰り返す |
| `/quality-check` | `/quality-check` | lint + typecheck + test の一括実行（機械可読な結果） |
| `/self-review` | `/self-review` | コード変更のセルフレビュー |
| `/codex-review` | `/codex-review [Issue番号]` | Codexのread-only multi-agent capsuleでローカル差分をクロスモデルレビュー（shadow・修正なし） |
| `/surface-audit` | `/surface-audit` | 公開面×テスト担保の診断。公開面（HTTP API・CLI・公開ライブラリ API・イベント・永続化スキーマ・UI）をカテゴリ側から列挙し、テストが実際に担保している振る舞いと突き合わせて、**テスト未担保の公開面（GAP）**を検出する。**出力はトリアージ前提の候補**であり、ファイル生成・修正・Issue 起票はしない |

### ユーティリティ

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/commit` | `/commit` | Conventional Commits形式でコミット |
| `/init-project` | `/init-project` | プロジェクトを分析してCLAUDE.mdを自動生成 |
| `/create-adr` | `/create-adr [テーマ]` / `/create-adr promote <機能仕様パス\|ディレクトリ...>` | 恒常的な設計決定を ADR(`docs/adr/NNNN-slug.md`)として記録。`promote` は退役する機能仕様から ADR 昇格の要否を判定するモードで、ファイル・ディレクトリを**複数指定**でき、ディレクトリ直下の `*.md` を一括判定する（例: `/create-adr promote docs/features/`）。定常フローに必須ではないオンデマンドスキル |

---

## ドキュメント

本プラグインは [AI駆動開発戦略](docs/ai-driven-development-strategy.md) を前提に設計されています。導入前にこのドキュメントを確認してください。

### 戦略・ワークフロー

- [AI駆動開発戦略](docs/ai-driven-development-strategy.md) — 開発サイクル、レビュー優先順位、品質保証・テスト戦略、クリティカル箇所の定義、設計判断記録（ADR）の規約、既定の開発フロー（SDD ＋ コード正・テスト正／4.4）と受入基準の粒度（4.5）
- [ADR 0002: GDD を不採用とし、計装のみ回収する](docs/adr/0002-gdd-not-adopted-salvage-instruments.md) — 既定フローを確定させた決定と根拠（改訂2 で GDD 固有資産の削除まで決定）
- [ブランチ戦略](docs/branching-strategy.md) — GitHub Flow、Conventional Commits、マージ規約
- [Codex ticket worker の承認境界](docs/codex-write-approval-boundary.md) — `codex exec --sandbox workspace-write` で何が OS レベルで強制でき、何ができないか（実測）。commit / push / Issue / PR / merge の権限分解、fail-closed 規定、**Phase 2a の着手条件**（Issue #200 §6）

### ガイド

- [変更履歴](CHANGELOG.md) — 破壊的変更と移行手順（4.0.0 以降）
- [セットアップガイド](docs/getting-started.md) — インストールからCLAUDE.md整備、動作確認まで
- [スクリプトランチャー](docs/script-launcher.md) — `claude-harness-run` の導入手順、allowlist の書き方、permission マッチャの実測記録
- [プラグイン内ファイル参照のパス規約](docs/plugin-path-conventions.md) — スキル・エージェントを書くときの規約。パス解決、`SKILL.md` と `references/` の線引き、**実行時テキストと docs の書き分け（(h)）**
- [カスタマイズ方法](docs/customization.md) — エージェント/スキルのオーバーライド、フック追加

---

## 設計思想

### エージェントのオーバーライド

プロジェクト側で `.claude/agents/{agent-name}.md` を配置すると、プラグインの同名エージェントを上書きできます。プロジェクト固有の観点を追加したい場合や、不要な観点を省きたい場合に利用してください。

---

## 横展開手順

新規プロジェクトにharnessを導入する手順:

1. プラグインをインストール
2. `/init-project` で `CLAUDE.md` を自動生成
3. 必要に応じてエージェントをオーバーライド（`.claude/agents/` に配置）
4. `/para-impl` でIssue実装を開始
