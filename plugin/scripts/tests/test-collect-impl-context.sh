#!/bin/bash
# test-collect-impl-context.sh
# scripts/collect-impl-context.sh の純粋関数（#N 参照抽出・PR files の union・
# changedDirs 導出・resolution_status 決定）を gh API を呼ばずに直接テストする。
#
# 実行方法: bash scripts/tests/test-collect-impl-context.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../collect-impl-context.sh"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# --- アサーションヘルパー ---

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

echo "=== test: extract_references — 単純な複数参照を抽出できる ==="
extract_references "See #12 for details, also fixes #45."
assert_eq "2件抽出される" "2" "$(jq 'length' <<<"$EXTRACTED_REFERENCES_JSON")"
assert_eq "昇順ソートされる" "[12,45]" "$EXTRACTED_REFERENCES_JSON"

echo "=== test: extract_references — 重複参照は除去される ==="
extract_references "Closes #5. Related to #5 again. Also #100."
assert_eq "重複除去後3件ではなく2件" "2" "$(jq 'length' <<<"$EXTRACTED_REFERENCES_JSON")"
assert_eq "内容が [5,100]" "[5,100]" "$EXTRACTED_REFERENCES_JSON"

echo "=== test: extract_references — 見出し記法(##)は誤検出しない ==="
extract_references $'## 概要\n\n本文。\n\n## 完了条件\n\n- [ ] 条件1'
assert_eq "見出しは参照として拾わない" "[]" "$EXTRACTED_REFERENCES_JSON"

echo "=== test: extract_references — 参照が1件も無い本文で空配列 ==="
extract_references "参照なしの本文です。"
assert_eq "空配列" "[]" "$EXTRACTED_REFERENCES_JSON"

echo "=== test: extract_references — CRLF改行でも正しく抽出できる ==="
FIXTURE_CRLF=$(printf 'Closes #7.\r\nAlso #8.\r\n')
extract_references "$FIXTURE_CRLF"
assert_eq "CRLFでも2件抽出" "[7,8]" "$EXTRACTED_REFERENCES_JSON"

echo "=== test: extract_references — 標準入力からも読み取れる ==="
# パイプ経由 (cmd | fn) だとサブシェルで実行され呼び出し元にグローバル変数の変更が
# 伝搬しないため、here-string (<<<) でstdinを渡す（サブシェルを跨がない）。
EXTRACTED_REFERENCES_JSON=""
extract_references <<<"Fixes #9."
assert_eq "stdin経由でも抽出できる" "[9]" "$EXTRACTED_REFERENCES_JSON"

echo "=== test: union_file_arrays — 複数配列を重複除去して統合する ==="
union_file_arrays '["b.txt","a.txt"]' '["a.txt","c.txt"]'
assert_eq "3件に統合される" "3" "$(jq 'length' <<<"$UNIONED_FILES_JSON")"
assert_eq "ソート済みの配列" '["a.txt","b.txt","c.txt"]' "$UNIONED_FILES_JSON"

echo "=== test: union_file_arrays — 引数が0個でも空配列を返す ==="
union_file_arrays
assert_eq "空配列" "[]" "$UNIONED_FILES_JSON"

echo "=== test: union_file_arrays — 単一配列でもそのまま統合される ==="
union_file_arrays '["x.txt","y.txt"]'
assert_eq "2件" "2" "$(jq 'length' <<<"$UNIONED_FILES_JSON")"

echo "=== test: derive_changed_dirs — ネストしたファイルからディレクトリを導出する ==="
derive_changed_dirs '["scripts/foo.sh","skills/bar/SKILL.md","scripts/tests/test-foo.sh"]'
assert_eq "3ディレクトリに重複なく分解される" "3" "$(jq 'length' <<<"$CHANGED_DIRS_JSON")"
assert_eq "ソート済みの配列" '["scripts","scripts/tests","skills/bar"]' "$CHANGED_DIRS_JSON"

echo "=== test: derive_changed_dirs — ルート直下ファイルは '.' として扱う ==="
derive_changed_dirs '["README.md","scripts/foo.sh"]'
assert_eq "'.' を含む2件" '[".","scripts"]' "$CHANGED_DIRS_JSON"

echo "=== test: derive_changed_dirs — 同一ディレクトリの複数ファイルは重複除去される ==="
derive_changed_dirs '["scripts/a.sh","scripts/b.sh"]'
assert_eq "1件のみ" '["scripts"]' "$CHANGED_DIRS_JSON"

echo "=== test: derive_changed_dirs — 空配列入力なら空配列を返す ==="
derive_changed_dirs '[]'
assert_eq "空配列" "[]" "$CHANGED_DIRS_JSON"

echo "=== test: resolve_status — 参照0件は no_references_found ==="
resolve_status 0 0
assert_eq "no_references_found" "no_references_found" "$RESOLUTION_STATUS"

echo "=== test: resolve_status — 参照ありで未解決0件は ok ==="
resolve_status 3 0
assert_eq "ok" "ok" "$RESOLUTION_STATUS"

echo "=== test: resolve_status — 未解決が1件以上あれば unresolved_references ==="
resolve_status 3 1
assert_eq "unresolved_references" "unresolved_references" "$RESOLUTION_STATUS"

echo "=== test: CLIレベル — 引数なしはexit非0 ==="
"$TARGET_SCRIPT" >/dev/null 2>&1
NO_ARG_EXIT=$?
assert_eq "exit code が非0" "1" "$NO_ARG_EXIT"

echo "=== test: CLIレベル — 非数値引数はexit非0 ==="
"$TARGET_SCRIPT" "abc" >/dev/null 2>&1
NON_NUMERIC_EXIT=$?
assert_eq "exit code が非0" "1" "$NON_NUMERIC_EXIT"

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
