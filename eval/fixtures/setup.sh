#!/usr/bin/env bash
# harness 評価用テストリポジトリのセットアップスクリプト
#
# 使用方法:
#   ./eval/fixtures/setup.sh [リポジトリ名]
#
# デフォルトのリポジトリ名: harness-eval
#
# 作成されるもの:
#   - フィクスチャコード（src/, tests/）
#   - 設定ファイル（CLAUDE.md, package.json, .eslintrc.json）
#   - 評価シナリオ（eval/scenarios/）
#   - GitHub リポジトリ（gh コマンドが利用可能な場合）
#   - 評価用 GitHub Issues

set -euo pipefail

REPO_NAME="${1:-harness-eval}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_DIR="$(pwd)/$REPO_NAME"

echo "=== harness-eval セットアップ ==="
echo "作成先: $TARGET_DIR"
echo ""

# ディレクトリ作成
if [ -d "$TARGET_DIR" ]; then
  echo "エラー: $TARGET_DIR は既に存在します"
  exit 1
fi

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# フィクスチャファイルのコピー
echo "フィクスチャファイルをコピー中..."
cp -r "$SCRIPT_DIR/src" .
cp -r "$SCRIPT_DIR/tests" .
cp "$SCRIPT_DIR/CLAUDE.md" .
cp "$SCRIPT_DIR/package.json" .
cp "$SCRIPT_DIR/.eslintrc.json" .

# 評価シナリオのコピー
echo "評価シナリオをコピー中..."
mkdir -p eval/scenarios
cp "$HARNESS_DIR/eval/scenarios/"*.md eval/scenarios/
mkdir -p eval/results

# .gitignore
cat > .gitignore << 'EOF'
node_modules/
eval/results/
.DS_Store
EOF

# README
cat > README.md << EOF
# $REPO_NAME

harness スキルの評価用テストリポジトリです。

## セットアップ

\`\`\`bash
npm install
\`\`\`

## 評価の実行

Claude Code で以下を実行:

\`\`\`text
/run-eval {スキル名} {TC番号}
例: /run-eval self-review TC-01
\`\`\`

## ファイル構成

| ファイル | 目的 |
|---------|------|
| \`src/utils.js\` | クリーンなコード（para-impl TDD用、self-review TC-02用） |
| \`src/auth.js\` | コーディング規約違反・セキュリティ問題あり（self-review TC-01/TC-04用） |
| \`src/legacy.js\` | 技術負債あり（reduce-debt用） |

## 評価シナリオ

\`eval/scenarios/\` に各スキルの評価シナリオが格納されています。
EOF

# git 初期化
echo "git リポジトリを初期化中..."
git init

# git user.name/email が未設定の場合のフォールバック
if ! git config user.name &>/dev/null; then
  git config user.name "harness-eval"
fi
if ! git config user.email &>/dev/null; then
  git config user.email "harness-eval@example.com"
fi

git add .
git commit -m "chore: initial setup from harness-eval-fixtures"

echo ""
echo "ローカルリポジトリを作成しました: $TARGET_DIR"
echo ""

# GitHub リポジトリ作成（オプション）
if command -v gh &> /dev/null; then
  echo "GitHub リポジトリを作成しますか？ (y/n)"
  if [ -t 0 ]; then
    read -r create_github || create_github="n"
  else
    create_github="n"
    echo "非対話環境のため GitHub リポジトリ作成をスキップします。"
  fi
  if [ "$create_github" = "y" ]; then
    echo "公開リポジトリとして作成しますか？ (y=public / n=private)"
    read -r is_public || is_public="n"
    if [ "$is_public" = "y" ]; then
      gh repo create "$REPO_NAME" --public --source=. --push
    else
      gh repo create "$REPO_NAME" --private --source=. --push
    fi

    echo ""
    echo "評価用 Issue を作成中..."

    # para-impl 評価用 Issues
    gh issue create \
      --title "feat: add formatDate function" \
      --body "$(cat << 'ISSUE'
## 概要

`src/utils.js` に `formatDate(date)` 関数を追加する。

## 要件

- 引数: `Date` オブジェクト
- 戻り値: `YYYY-MM-DD` 形式の文字列
- テストも追加すること（`tests/utils.test.js` に追記）

**評価用途**: para-impl TC-01（単一 Issue の通常実装）
ISSUE
)"

    gh issue create \
      --title "fix: README の誤字修正" \
      --body "$(cat << 'ISSUE'
## 概要

README.md の誤字を修正する。

## 修正内容

- `Instalation` → `Installation`

**評価用途**: para-impl TC-02（複数 Issue 並列実装）
ISSUE
)"

    gh issue create \
      --title "feat: add user authentication" \
      --body "$(cat << 'ISSUE'
## 概要

ユーザー認証機能を追加する。

## 要件

- JWT またはセッションベースの認証のいずれかで実装すること
- ユーザー名・パスワードを受け取り、認証結果を返す関数を実装する

**評価用途**: para-impl（実装サンプル）
ISSUE
)"

    gh issue create \
      --title "chore: legacy.js の技術負債調査と改善" \
      --body "$(cat << 'ISSUE'
## 概要

`src/legacy.js` に存在する技術負債を調査・改善する。

## 背景

レガシーコードに重複ロジック・マジックナンバー・未使用変数が存在する。

**評価用途**: reduce-debt TC-01（技術負債が存在するリポジトリでのスキャン）
ISSUE
)"

    echo ""
    echo "Issue の作成が完了しました。"
  fi
else
  echo ""
  echo "gh コマンドが見つかりません。GitHub リポジトリと Issue の作成はスキップされました。"
  echo "手動で以下の Issue を作成してください:"
  echo "  #1: feat: add formatDate function（para-impl TC-01用）"
  echo "  #2: fix: README の誤字修正（para-impl TC-02用）"
  echo "  #3: feat: add user authentication（para-impl 実装サンプル）"
  echo "  #4: chore: legacy.js の技術負債調査と改善（reduce-debt TC-01用）"
fi

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "次のステップ:"
echo "  cd $REPO_NAME"
echo "  npm install"
echo "  # Claude Code を開いて /run-eval {スキル名} {TC番号} を実行"
