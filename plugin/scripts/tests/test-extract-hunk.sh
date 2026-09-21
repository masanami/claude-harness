#!/bin/bash
# test-extract-hunk.sh
# scripts/extract-hunk.sh の純粋テキスト処理（extract_hunk_from_diff）を
# 固定diffフィクスチャで直接テストする。gh/gitは呼ばない（本スクリプト自体が
# gh/gitを呼ばない設計のため、フィクスチャファイルのみで完結する）。
#
# 実行方法: bash scripts/tests/test-extract-hunk.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../extract-hunk.sh"

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

assert_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected to contain: ${needle}"
    echo "       actual: ${haystack}"
  fi
}

# --- フィクスチャdiffファイルの用意 ---
# foo.js: 2つのhunk（1-5行域 / 20-24行域）、bar.js: 1つのhunk。
FIXTURE_DIR="$(mktemp -d)"
FIXTURE_DIFF="${FIXTURE_DIR}/fixture.diff"
cat >"$FIXTURE_DIFF" <<'EOF'
diff --git a/foo.js b/foo.js
index 1111111..2222222 100644
--- a/foo.js
+++ b/foo.js
@@ -1,5 +1,6 @@
 line1
 line2
+added line
 line3
 line4
 line5
@@ -20,4 +21,5 @@
 line20
 line21
+added line2
 line22
 line23
diff --git a/bar.js b/bar.js
index 3333333..4444444 100644
--- a/bar.js
+++ b/bar.js
@@ -1,3 +1,3 @@
 barline1
-old bar line
+new bar line
 barline3
EOF

cleanup() {
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

echo "=== test: extract_hunk_from_diff — 該当行が1つ目のhunk内にある ==="
extract_hunk_from_diff "$FIXTURE_DIFF" "foo.js" 3 3
assert_eq "found=1" "1" "$EXTRACT_FOUND"
assert_contains "1つ目のhunkヘッダを含む" "$EXTRACT_SNIPPET" '@@ -1,5 +1,6 @@'
assert_contains "追加行を含む" "$EXTRACT_SNIPPET" '+added line'

echo "=== test: extract_hunk_from_diff — 該当行が2つ目のhunk内にある(前後N行付き) ==="
extract_hunk_from_diff "$FIXTURE_DIFF" "foo.js" 22 3
assert_eq "found=1" "1" "$EXTRACT_FOUND"
assert_contains "2つ目のhunkヘッダを含む" "$EXTRACT_SNIPPET" '@@ -20,4 +21,5 @@'
assert_contains "前のhunkの末尾行（前後Nコンテキスト）を含む" "$EXTRACT_SNIPPET" ' line5'
assert_contains "境界に区切り記号がある" "$EXTRACT_SNIPPET" '...'

echo "=== test: extract_hunk_from_diff — 該当行がどのhunkにも含まれない場合、最も近いhunkをfound=falseで返す ==="
extract_hunk_from_diff "$FIXTURE_DIFF" "foo.js" 100 3
assert_eq "found=0" "0" "$EXTRACT_FOUND"
assert_contains "最も近い(2つ目の)hunkが入る" "$EXTRACT_SNIPPET" '@@ -20,4 +21,5 @@'

echo "=== test: extract_hunk_from_diff — diffに存在しないファイルはfound=falseかつ空snippet ==="
extract_hunk_from_diff "$FIXTURE_DIFF" "nonexistent.js" 1 3
assert_eq "found=0" "0" "$EXTRACT_FOUND"
assert_eq "snippetは空" "" "$EXTRACT_SNIPPET"

echo "=== test: extract_hunk_from_diff — 別ファイル(bar.js)のhunkも正しく特定できる（セクション境界の切り分け） ==="
extract_hunk_from_diff "$FIXTURE_DIFF" "bar.js" 2 3
assert_eq "found=1" "1" "$EXTRACT_FOUND"
assert_contains "bar.jsのhunkヘッダを含む" "$EXTRACT_SNIPPET" '@@ -1,3 +1,3 @@'
assert_contains "bar.jsの変更行を含む" "$EXTRACT_SNIPPET" '+new bar line'
if [[ "$EXTRACT_SNIPPET" == *"added line"* ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("bar.js検索時にfoo.jsのhunkが混入していないこと")
  echo "  NG - bar.js検索時にfoo.jsのhunkが混入していないこと"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - bar.js検索時にfoo.jsのhunkが混入していないこと"
fi

echo "=== test: extract_hunk_from_diff — context_lines=0なら前後hunkを付与しない ==="
extract_hunk_from_diff "$FIXTURE_DIFF" "foo.js" 22 0
assert_eq "found=1" "1" "$EXTRACT_FOUND"
if [[ "$EXTRACT_SNIPPET" == *"..."* ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("context_lines=0なら区切り記号...が付与されない")
  echo "  NG - context_lines=0なら区切り記号...が付与されない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - context_lines=0なら区切り記号...が付与されない"
fi

echo "=== test: CLIレベル — main()経由でJSON1個を出力する ==="
CLI_OUTPUT=$("$TARGET_SCRIPT" "$FIXTURE_DIFF" "foo.js" 3 3)
CLI_EXIT=$?
assert_eq "exit code 0" "0" "$CLI_EXIT"
assert_eq "found=true" "true" "$(jq -r '.found' <<<"$CLI_OUTPUT")"
assert_eq "file=foo.js" "foo.js" "$(jq -r '.file' <<<"$CLI_OUTPUT")"
assert_eq "line=3" "3" "$(jq -r '.line' <<<"$CLI_OUTPUT")"

echo "=== test: CLIレベル — diff_fileが存在しなければexit非0 ==="
"$TARGET_SCRIPT" "/nonexistent/path/to/diff" "foo.js" 3 >/dev/null 2>&1
NO_DIFF_FILE_EXIT=$?
assert_eq "exit code が非0" "1" "$NO_DIFF_FILE_EXIT"

echo "=== test: CLIレベル — 引数不足はexit非0 ==="
"$TARGET_SCRIPT" "$FIXTURE_DIFF" "foo.js" >/dev/null 2>&1
MISSING_ARG_EXIT=$?
assert_eq "exit code が非0" "1" "$MISSING_ARG_EXIT"

echo "=== test: CLIレベル — 行番号が非数値ならexit非0 ==="
"$TARGET_SCRIPT" "$FIXTURE_DIFF" "foo.js" "abc" >/dev/null 2>&1
NON_NUMERIC_LINE_EXIT=$?
assert_eq "exit code が非0" "1" "$NON_NUMERIC_LINE_EXIT"

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
