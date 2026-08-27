# セットアップガイド

## 1. プラグインのインストール

### マーケットプレイス経由

```bash
# マーケットプレイスを追加
/plugin marketplace add masanami/claude-harness

# プラグインをインストール
/plugin install claude-harness@masanami-harness
```

### GitHub直接指定

```bash
claude plugin add github:masanami/claude-harness
```

### ローカルインストール（開発用）

```bash
claude plugin add ./path/to/claude-harness
```

---

## 2. スクリプトランチャーのセットアップ（推奨・一度きり）

スキルはプラグイン同梱スクリプトを PATH 上のランチャー `claude-harness-run` 経由で実行します。導入すると利用側の許可設定は `Bash(claude-harness-run:*)` の1行で済み、プラグイン更新でも外れません。**未導入でも動作しますが、headless 実行（`claude -p`）ではスクリプト起動が permission 拒否されることがあります。**

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

`.claude/settings.json`（`/init-project` が生成する場合は自動で含まれます）:

```json
{
  "permissions": {
    "allow": ["Bash(claude-harness-run:*)"]
  }
}
```

ランチャーは実行のたびにインストール済みプラグインの現行版を解決するため、プラグインを更新してもコピーを置き直す必要はありません。詳細・トラブルシューティングは [スクリプトランチャー](./script-launcher.md) を参照してください。

### Codex shadow reviewを使う場合

`/codex-review` には、認証済みのCodex CLIと`jq`が必要です。

```bash
codex --version
jq --version
```

Codex CLIのmodel・認証・利用上限は実行者環境の設定を使います。未導入・認証失敗・laneの部分失敗はレビュー完了・指摘ゼロとして扱われず、shadow reviewの`partial` / `failed`として独立に報告されます。

---

## 3. プロジェクトのCLAUDE.mdを整備

プラグインのエージェント・スキルはプロジェクトの `CLAUDE.md` を参照して動作します。以下の情報を記述してください。

### 必須項目

```markdown
# プロジェクト名

## コマンド

- テスト実行: `npm run test`
- リント: `npm run lint`
- 型チェック: `npm run typecheck`
- E2Eテスト: `npm run e2e`
- フォーマット: `npm run format`

## ディレクトリ構成

- ソースコード: `src/`
- テスト: `src/**/__tests__/`
- E2Eテスト: `e2e/`
- ドキュメント: `docs/`
```

### 推奨項目

```markdown
## コーディング規約

- 命名規則: (プロジェクトの規約)
- ディレクトリ構造: (プロジェクトのパターン)
- インポート順序: (プロジェクトの規約)

## ドキュメント

- 機能仕様: `docs/features/`
- API仕様: `docs/api/`

## テスト方針

- 単体テスト: Vitest / Jest
- E2Eテスト: Playwright
- テストパターン: Arrange-Act-Assert
```

---

## 4. 動作確認

### エージェントの確認

```
コードをレビューして → code-reviewer エージェントが起動
```

### スキルの確認

```
/commit → Conventional Commits形式でコミット
/quality-check → 品質ゲートチェック
/para-impl 123 → Issue #123 の実装を開始
/codex-review 123 → 現在の差分をCodexのread-only capsuleでshadow review
```

---

## 5. 開発ワークフロー

導入後の基本的な流れは次のとおり。サイクルの詳細は [AI駆動開発戦略](./ai-driven-development-strategy.md) を参照してください。

1. **要件定義**: 開発者が機能要件を定義し、親チケットを作成
2. **タスク分解**: 子チケットに分解（`/create-ticket` スキルを活用）
3. **並列実装**: `/para-impl {Issue番号...}` で実装（複数指定で star 型並列実行）
4. **レビュー・マージ**: `/pr-merge {PR番号}` でレビューとマージ

---

## 6. 品質方針の設定

レビュー範囲・テスト範囲は固定のレベルではなく、変更のリスク・重要度に応じて判断します。考え方は [AI駆動開発戦略](./ai-driven-development-strategy.md) を参照してください。

CLAUDE.md にプロジェクトの品質方針を明記しておくと、エージェントが適切に判断します:

```markdown
## 品質方針

- レビュー優先順位: 動作確認・E2E > 要件・クリティカル設計 > 詳細設計 > コード
- E2E: 主要ユーザーフローを自動化し、CIで毎PR実行
- クリティカル箇所: 認証・決済・個人情報。設計レビュー（人間）必須、コードレビューはAIエージェント（code-reviewer）必須
```
