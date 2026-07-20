---
name: quality-check
description: "auto-fix→lint→型チェック→テストを順に実行し、必須ゲート通過を機械可読な結果で返す品質ゲートチェック。Triggers on: '/quality-check', '品質チェック', 'QCして', 'quality gate'"
model: sonnet
# effort: auto-fix は機械的範囲のみ（型/テスト失敗の修正は呼び出し元が担う）ため low。
effort: low
---

# 品質ゲートチェック

プロジェクトの **自動修正 → lint → 型チェック → テスト** を順に実行し、**必須ゲート**（Lint・型チェック・テストのパス）を通します。結果は人間向けサマリーと、呼び出し元が判定に使える機械可読な形式の両方で返します。

> 必須ゲートにはこのほか「セルフレビュー」「CI」も含まれますが、本スキルはそのうち自動実行できる Lint / 型チェック / テストの3点を担います。

## 手順

### 1. プロジェクト設定の確認（コマンド特定）

CLAUDE.md および `package.json` 等から、以下のコマンドを特定する（意味理解が必要なため LLM が行う）:

- **auto-fix 系コマンド**（0個以上）: lint --fix / format / organize-imports など、機械的に直せる範囲を直すコマンド
- リントコマンド（チェック用）
- 型チェックコマンド
- テストコマンド

該当するコマンドが存在しないものは省略する（次ステップのスクリプトが「スキップ」として扱い、失敗とはしない）。

### 2. quality-check-runner.sh の実行

**自動修正の事前適用 → lint → 型チェック → テストの順序実行**、exit code に基づく `gates.*.status` 判定、機械可読 JSON の構築は、決定的な処理として `scripts/quality-check-runner.sh` に切り出されている。

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/quality-check-runner.sh"` の形式（`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない。実行前に、スキル起動時の「Base directory for this skill」から解決したプラグインルートの絶対パスに置換して実行する）を用い、相対パス `scripts/quality-check-runner.sh` では呼び出さないこと。
<!-- 正本: docs/plugin-path-conventions.md -->

```bash
RESULT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/quality-check-runner.sh" \
  --auto-fix "<auto-fixコマンド1>" \
  --auto-fix "<auto-fixコマンド2>" \
  --lint "<リントコマンド>" \
  --typecheck "<型チェックコマンド>" \
  --test "<テストコマンド>")
SCRIPT_EXIT=$?
```

- 手順1で特定できなかったコマンドは、対応する `--auto-fix`/`--lint`/`--typecheck`/`--test` フラグごと省略する（0個以上の `--auto-fix` を検出順に指定。`--lint`/`--typecheck`/`--test` は1回のみ指定可）
- スクリプトの exit code: `result` が `pass` なら 0、`fail` なら 1、jq不在なら 2、CLI引数不正（未知フラグ・値欠落・フラグ重複指定）なら 1
- **`$SCRIPT_EXIT` が `2` の場合は `$RESULT` が空（JSONが出力されていない）。この場合は `$RESULT` をJSONとしてパースせず、stderr のメッセージ（jq不在等）をそのまま報告して処理を中断する**
- 各コマンドの生出力（lintエラー箇所・型エラー内容・失敗テストの詳細）は stderr に転記される。**手順4の失敗分析はこの stderr 出力を使う**

出力 JSON の**フィールド定義と件数抽出の仕様の正本は、プラグイン配下の `scripts/README.md`「quality-check-runner.sh の出力仕様」**（ここには複製しない）。**cwd 起点の相対パス `scripts/README.md` では導入先プロジェクトの同名ファイルを誤って参照しうるため、Read する場合はスキル起動時の「Base directory for this skill」を起点に `<base>/../../scripts/README.md` として解決すること。

### 3. 結果サマリー

`$RESULT`（`{result, auto_fix, gates: {lint, typecheck, test}}`）を最後に**機械可読な結果としてそのまま出力**する（呼び出し元のスキル/エージェントが判定に使う）。

あわせて `gates.*` の内容から**人間向けサマリー**（✅ パス / ❌ 失敗 / ⊘ スキップ）を組み立てて提示する:

```text
## 品質ゲートチェック結果

### 自動修正 (適用された場合)
- {auto_fix.summary}

| チェック | 結果 | 詳細 |
|---------|------|------|
| リント | ✅/❌/⊘ | errors, warnings |
| 型チェック | ✅/❌/⊘ | errors |
| テスト | ✅/❌/⊘ | passed/failed/skipped |

### 総合判定: ✅ PASS / ❌ FAIL
```

### 4. 失敗時の対応

`gates.*.status` が `fail` のゲートがある場合:
1. スクリプト実行時に stderr へ転記された生出力（`--- <gate>: <cmd> ---` 区切り）からエラー内容を分析
2. 修正方法を提案
3. ユーザーの指示に応じて修正を実施し、手順2から再実行

> 自律実行コンテキスト（feature-implementer などのサブエージェント呼び出し）では、呼び出し元が機械可読な結果を見て修正ループを管理する。
