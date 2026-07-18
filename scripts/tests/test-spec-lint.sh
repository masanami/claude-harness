#!/bin/bash
# test-spec-lint.sh
# scripts/spec-lint.sh のパース関数（曖昧語検出/プレースホルダ残骸検出/参照切れ検出/
# チェックリスト形式検証）を直接テストする。gh非依存のためgh呼び出しは行わない。
#
# 実行方法: bash scripts/tests/test-spec-lint.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SPEC_LINT_TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SPEC_LINT_TEST_SCRIPT_DIR}/../spec-lint.sh"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

assert_eq() {
  local description="$1"
  local expected="$2"
  local actual="$3"

  if [ "$expected" = "$actual" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected: ${expected}"
    echo "       actual:   ${actual}"
  fi
}

# --- フィクスチャ ---

read -r -d '' FIXTURE_CLEAN <<'EOF'
# サンプル機能

## 概要

サンプル機能の概要。

## 機能要件

- [ ] ユーザーはログインできる
- [x] ログイン失敗時にエラーメッセージが表示される

## 受入基準

- [ ] ログインAPIが `scripts/README.md` を参照する
EOF

read -r -d '' FIXTURE_AMBIGUOUS <<'EOF'
# サンプル機能

## 機能要件

- [ ] 入力値を適切に検証する
- [ ] エラー時は必要に応じてリトライする
- [ ] その他のケースなど柔軟に対応する
EOF

read -r -d '' FIXTURE_PLACEHOLDER <<'EOF'
# サンプル機能

## クリティカル設計決定

### 認可モデル

- 採用案: {採用案}
- 理由: 既存パターンとの整合
EOF

read -r -d '' FIXTURE_CHECKLIST_BAD <<'EOF'
# サンプル機能

## 機能要件

- ユーザーはログインできる
- [ ] ログアウトできる

## 受入基準

- [ ] ログインが成功する
- ログアウトが成功する
EOF

read -r -d '' FIXTURE_CHECKLIST_GOOD <<'EOF'
# サンプル機能

## 機能要件

- [ ] ユーザーはログインできる
- [x] ログアウトできる

## 非機能要件

- パフォーマンス: 通常の箇条書き（対象外セクションなのでチェックボックス不要）
EOF

echo "=== test: 曖昧語検出（あり） ==="
detect_ambiguous_words "$FIXTURE_AMBIGUOUS"
assert_eq "1件目のwordが「適切に」" "適切に" "$(jq -r '.[0].word' <<<"$AMBIGUOUS_JSON")"
assert_eq "1件目のlineが5" "5" "$(jq -r '.[0].line' <<<"$AMBIGUOUS_JSON")"
assert_eq "2件目のwordが「必要に応じて」" "必要に応じて" "$(jq -r '.[1].word' <<<"$AMBIGUOUS_JSON")"

echo "=== test: 曖昧語検出（同一行に複数マッチ） ==="
detect_ambiguous_words "$FIXTURE_AMBIGUOUS"
assert_eq "同一行複数マッチも含め計4件（適切に/必要に応じて/など/柔軟に）" "4" "$(jq 'length' <<<"$AMBIGUOUS_JSON")"
# 7行目「その他のケースなど柔軟に対応する」は「など」と「柔軟に」の2語にマッチする
line7_matches="$(jq -r '[.[] | select(.line == 7) | .word] | join(",")' <<<"$AMBIGUOUS_JSON")"
assert_eq "同一行の複数マッチが両方candidateとして含まれる" "など,柔軟に" "$line7_matches"

echo "=== test: 曖昧語検出（なし） ==="
detect_ambiguous_words "$FIXTURE_CLEAN"
assert_eq "0件" "0" "$(jq 'length' <<<"$AMBIGUOUS_JSON")"

echo "=== test: テンプレートプレースホルダ残骸検出（あり） ==="
detect_template_placeholders "$FIXTURE_PLACEHOLDER"
assert_eq "1件検出される" "1" "$(jq 'length' <<<"$PLACEHOLDERS_JSON")"
assert_eq "textが{採用案}" "{採用案}" "$(jq -r '.[0].text' <<<"$PLACEHOLDERS_JSON")"
assert_eq "行番号が7" "7" "$(jq -r '.[0].line' <<<"$PLACEHOLDERS_JSON")"

echo "=== test: テンプレートプレースホルダ残骸検出（なし） ==="
detect_template_placeholders "$FIXTURE_CLEAN"
assert_eq "0件" "0" "$(jq 'length' <<<"$PLACEHOLDERS_JSON")"

echo "=== test: チェックボックス形式検証（違反あり） ==="
detect_checklist_format_issues "$FIXTURE_CHECKLIST_BAD"
assert_eq "2件検出される" "2" "$(jq 'length' <<<"$CHECKLIST_ISSUES_JSON")"
assert_eq "1件目のsectionが機能要件" "機能要件" "$(jq -r '.[0].section' <<<"$CHECKLIST_ISSUES_JSON")"
assert_eq "2件目のsectionが受入基準" "受入基準" "$(jq -r '.[1].section' <<<"$CHECKLIST_ISSUES_JSON")"

echo "=== test: チェックボックス形式検証（違反なし。対象外セクションは無視） ==="
detect_checklist_format_issues "$FIXTURE_CHECKLIST_GOOD"
assert_eq "0件（非機能要件セクションの通常箇条書きは対象外）" "0" "$(jq 'length' <<<"$CHECKLIST_ISSUES_JSON")"

echo "=== test: 相対パス参照のファイル存在チェック（git一時リポジトリ） ==="
TMP_REPO_DIR="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_repo() {
  rm -rf "$TMP_REPO_DIR"
}
trap cleanup_tmp_repo EXIT

(
  cd "$TMP_REPO_DIR" || exit 1
  git init -q
  mkdir -p docs/features scripts
  echo "existing" > scripts/existing-file.sh
  echo "spec" > docs/features/sample.md
)

FIXTURE_REFS=$'# サンプル機能\n\n## 参照\n\n- 実在するファイル `scripts/existing-file.sh`\n- 存在しないファイル `scripts/missing-file.sh`\n'
REPO_ROOT_RESOLVED="$(resolve_repo_root "${TMP_REPO_DIR}/docs/features/sample.md")"
EXPECTED_GIT_TOPLEVEL="$(cd "$TMP_REPO_DIR" && git rev-parse --show-toplevel)"
assert_eq "resolve_repo_rootがgit repo rootを解決する" "$EXPECTED_GIT_TOPLEVEL" "$REPO_ROOT_RESOLVED"

detect_broken_references "$FIXTURE_REFS" "$REPO_ROOT_RESOLVED"
assert_eq "存在しないパスのみ1件検出される" "1" "$(jq 'length' <<<"$BROKEN_REFS_JSON")"
assert_eq "検出されたpathがscripts/missing-file.sh" "scripts/missing-file.sh" "$(jq -r '.[0].path' <<<"$BROKEN_REFS_JSON")"
assert_eq "existsがfalse" "false" "$(jq -r '.[0].exists' <<<"$BROKEN_REFS_JSON")"

echo "=== test: 相対パス参照のファイル存在チェック（プレースホルダは除外） ==="
FIXTURE_REFS_PLACEHOLDER=$'# サンプル機能\n\n- テンプレート変数 `docs/features/{slug}.md` は除外される\n'
detect_broken_references "$FIXTURE_REFS_PLACEHOLDER" "$REPO_ROOT_RESOLVED"
assert_eq "プレースホルダを含むパスは検出対象外" "0" "$(jq 'length' <<<"$BROKEN_REFS_JSON")"

echo "=== test: resolve_repo_root（gitが使えない場合のフォールバック） ==="
NON_GIT_DIR="$(mktemp -d)"
FALLBACK_ROOT="$(resolve_repo_root "${NON_GIT_DIR}/spec.md")"
assert_eq "git repoでない場合はspecファイルのディレクトリにフォールバックする" "$NON_GIT_DIR" "$FALLBACK_ROOT"
rm -rf "$NON_GIT_DIR"

echo "=== test: グロブメタ文字を含むパス/プレースホルダでハングしない（無限ループ回帰） ==="
# ${var/pattern/} 形式の置換はpatternをクォートしないとglobとして解釈される。
# 「[id]」のようなNext.js動的ルート表記や「{選択肢[A]}」のようなプレースホルダは
# 除去対象文字列にglobメタ文字（[ ]）を含むため、クォート漏れがあると同じ箇所に
# 再マッチし続けて無限ループ（ハング）する。実プロセスとして起動し、一定時間後も
# 生きていればハングとみなす（正しい実装は即座に完了する）。
GLOB_FIXTURE_FILE="$(mktemp)"
cat > "$GLOB_FIXTURE_FILE" <<'EOF'
# サンプル機能

## 参照

- 動的ルート `src/app/[id]/page.tsx` へのリンク
- プレースホルダ残骸 {選択肢[A]}
EOF

GLOB_OUTPUT_FILE="$(mktemp)"
bash "$TARGET_SCRIPT" "$GLOB_FIXTURE_FILE" > "$GLOB_OUTPUT_FILE" 2>&1 &
GLOB_PID=$!
sleep 3
if kill -0 "$GLOB_PID" 2>/dev/null; then
  GLOB_STILL_RUNNING="yes"
  kill -9 "$GLOB_PID" 2>/dev/null
else
  GLOB_STILL_RUNNING="no"
fi
wait "$GLOB_PID" 2>/dev/null
assert_eq "3秒以内に完了している（globメタ文字でハングしない）" "no" "$GLOB_STILL_RUNNING"

if [ "$GLOB_STILL_RUNNING" = "no" ]; then
  GLOB_OUTPUT="$(cat "$GLOB_OUTPUT_FILE")"
  assert_eq "動的ルート([id])を含むパスが存在しない参照として検出される" "src/app/[id]/page.tsx" "$(jq -r '.broken_references[0].path' <<<"$GLOB_OUTPUT")"
  assert_eq "globメタ文字を含むプレースホルダ残骸も検出される" "{選択肢[A]}" "$(jq -r '.template_placeholders[0].text' <<<"$GLOB_OUTPUT")"
fi
rm -f "$GLOB_FIXTURE_FILE" "$GLOB_OUTPUT_FILE"

echo "=== test: CLIレベル（フルスクリプト実行）での統合確認 ==="
CLI_FIXTURE_FILE="$(mktemp)"
printf '%s' "$FIXTURE_AMBIGUOUS" > "$CLI_FIXTURE_FILE"
CLI_OUTPUT=$(bash "$TARGET_SCRIPT" "$CLI_FIXTURE_FILE")
CLI_EXIT=$?
assert_eq "exit code が 0" "0" "$CLI_EXIT"
assert_eq "spec_fileフィールドが入力パスと一致" "$CLI_FIXTURE_FILE" "$(jq -r '.spec_file' <<<"$CLI_OUTPUT")"
assert_eq "ambiguous_wordsが4件" "4" "$(jq '.ambiguous_words | length' <<<"$CLI_OUTPUT")"
assert_eq "template_placeholdersが0件" "0" "$(jq '.template_placeholders | length' <<<"$CLI_OUTPUT")"
assert_eq "broken_referencesが0件" "0" "$(jq '.broken_references | length' <<<"$CLI_OUTPUT")"
assert_eq "checklist_format_issuesが0件" "0" "$(jq '.checklist_format_issues | length' <<<"$CLI_OUTPUT")"
rm -f "$CLI_FIXTURE_FILE"

echo "=== test: CLIレベル（存在しないファイルはexit非0） ==="
bash "$TARGET_SCRIPT" "/nonexistent/path/to/spec.md" >/dev/null 2>&1
NONEXISTENT_EXIT=$?
assert_eq "存在しないファイル指定はexit非0" "1" "$NONEXISTENT_EXIT"

echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi

exit 0
