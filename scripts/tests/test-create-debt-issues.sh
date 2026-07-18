#!/bin/bash
# shellcheck disable=SC2329
# test-create-debt-issues.sh
# scripts/create-debt-issues.sh の純粋関数（manifest検証・本文組み立て・粒度ヒューリスティック・
# 対応表組み立て）を gh API を呼ばずに直接テストする。
# gh 呼び出しは create_github_issue() 関数でラップされているため、
# テスト側でこの関数を上書き定義してモック化する。
#
# 実行方法: bash scripts/tests/test-create-debt-issues.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。
#
# 本ファイルでは create_github_issue / mock_create_github_issue を複数回上書き定義し、
# 各テストブロックから間接的に呼び出す（gh をモック化するため）。shellcheckの
# 「呼ばれていない関数」誤検知（SC2329）をファイル全体で抑止する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../create-debt-issues.sh"

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
    echo "       actual:              ${haystack}"
  fi
}

assert_not_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected NOT to contain: ${needle}"
    echo "       actual:                  ${haystack}"
  fi
}

# --- フィクスチャ: manifest 項目（単体） ---

FIXTURE_VALID_ITEM='{"title":"重複したバリデーションロジックの共通化","parentRef":"#12","targetFiles":["src/foo.ts","src/bar.ts"],"problem":"バリデーションロジックが3箇所に重複している","expectedState":"共通関数に切り出され、重複が解消されている"}'

FIXTURE_MISSING_TITLE='{"title":"","parentRef":"#12","targetFiles":["src/foo.ts"],"problem":"問題","expectedState":"期待状態"}'

FIXTURE_MISSING_MULTIPLE='{"title":"タイトル","parentRef":"","targetFiles":["src/foo.ts"],"problem":"","expectedState":"期待状態"}'

FIXTURE_EMPTY_TARGET_FILES='{"title":"タイトル","parentRef":"#12","targetFiles":[],"problem":"問題","expectedState":"期待状態"}'

FIXTURE_OBJECT_TITLE='{"title":{},"parentRef":"#12","targetFiles":["src/foo.ts"],"problem":"問題","expectedState":"期待状態"}'

FIXTURE_OBJECT_TARGET_FILE_ENTRY='{"title":"タイトル","parentRef":"#12","targetFiles":[{}],"problem":"問題","expectedState":"期待状態"}'

FIXTURE_UNDER_THRESHOLD='{"title":"タイトル","parentRef":"#12","targetFiles":["a.ts","b.ts"],"problem":"問題","expectedState":"期待状態"}'

FIXTURE_OVER_THRESHOLD='{"title":"タイトル","parentRef":"#12","targetFiles":["a.ts","b.ts","c.ts","d.ts","e.ts","f.ts"],"problem":"問題","expectedState":"期待状態"}'

FIXTURE_ITEM_WITH_PRIORITY='{"title":"タイトル","parentRef":"#12","targetFiles":["src/a.ts"],"problem":"問題","expectedState":"期待状態","priority":"高"}'

# --- フィクスチャ: manifest 全体（配列） ---
# index0: 正常（閾値以下） -> created, warningなし
# index1: 必須フィールド欠落（problem欠落） -> failed（gh呼ばれない）
# index2: 正常（閾値超過） -> created, warningあり
# index3: gh呼び出し失敗をシミュレートするマーカー付きタイトル -> failed

read -r -d '' FIXTURE_MANIFEST_MIXED <<'EOF'
[
  {
    "title": "item0 通常項目",
    "parentRef": "#12",
    "targetFiles": ["src/a.ts", "src/b.ts"],
    "problem": "問題0",
    "expectedState": "期待状態0"
  },
  {
    "title": "item1 problem欠落",
    "parentRef": "#12",
    "targetFiles": ["src/c.ts"],
    "problem": "",
    "expectedState": "期待状態1"
  },
  {
    "title": "item2 閾値超過",
    "parentRef": "#12",
    "targetFiles": ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts"],
    "problem": "問題2",
    "expectedState": "期待状態2"
  },
  {
    "title": "item3 GH_FAIL_MARKER",
    "parentRef": "#12",
    "targetFiles": ["src/d.ts"],
    "problem": "問題3",
    "expectedState": "期待状態3"
  }
]
EOF

# --- モック: create_github_issue（gh を呼ばない） ---
# MOCK_ISSUE_COUNTER から連番のissue番号を払い出す。
# タイトルに "GH_FAIL_MARKER" を含む場合は失敗をシミュレートする。
MOCK_ISSUE_COUNTER=100
mock_create_github_issue() {
  local title="$1"
  if [[ "$title" == *"GH_FAIL_MARKER"* ]]; then
    echo "mock gh error: simulated failure" >&2
    return 1
  fi
  MOCK_ISSUE_COUNTER=$((MOCK_ISSUE_COUNTER + 1))
  echo "https://github.com/example/repo/issues/${MOCK_ISSUE_COUNTER}"
  return 0
}

echo "=== test: validate_manifest_item - 必須フィールドが揃っている場合は ok ==="
validate_manifest_item "$FIXTURE_VALID_ITEM"
assert_eq "ITEM_VALIDATION_STATUS が ok" "ok" "$ITEM_VALIDATION_STATUS"
assert_eq "ITEM_VALIDATION_ERROR が空" "" "$ITEM_VALIDATION_ERROR"

echo "=== test: validate_manifest_item - title欠落は invalid ==="
validate_manifest_item "$FIXTURE_MISSING_TITLE"
assert_eq "ITEM_VALIDATION_STATUS が invalid" "invalid" "$ITEM_VALIDATION_STATUS"
assert_contains "エラーメッセージに title が含まれる" "$ITEM_VALIDATION_ERROR" "title"

echo "=== test: validate_manifest_item - 複数フィールド欠落時はすべて列挙される ==="
validate_manifest_item "$FIXTURE_MISSING_MULTIPLE"
assert_eq "ITEM_VALIDATION_STATUS が invalid" "invalid" "$ITEM_VALIDATION_STATUS"
assert_contains "エラーメッセージに parentRef が含まれる" "$ITEM_VALIDATION_ERROR" "parentRef"
assert_contains "エラーメッセージに problem が含まれる" "$ITEM_VALIDATION_ERROR" "problem"

echo "=== test: validate_manifest_item - targetFilesが空配列は invalid ==="
validate_manifest_item "$FIXTURE_EMPTY_TARGET_FILES"
assert_eq "ITEM_VALIDATION_STATUS が invalid" "invalid" "$ITEM_VALIDATION_STATUS"
assert_contains "エラーメッセージに targetFiles が含まれる" "$ITEM_VALIDATION_ERROR" "targetFiles"

echo "=== test: validate_manifest_item - titleがオブジェクト値の場合は invalid（型検証の回帰防止） ==="
validate_manifest_item "$FIXTURE_OBJECT_TITLE"
assert_eq "ITEM_VALIDATION_STATUS が invalid" "invalid" "$ITEM_VALIDATION_STATUS"
assert_contains "エラーメッセージに title が含まれる" "$ITEM_VALIDATION_ERROR" "title"

echo "=== test: validate_manifest_item - targetFilesの要素がオブジェクト値の場合は invalid（型検証の回帰防止） ==="
validate_manifest_item "$FIXTURE_OBJECT_TARGET_FILE_ENTRY"
assert_eq "ITEM_VALIDATION_STATUS が invalid" "invalid" "$ITEM_VALIDATION_STATUS"
assert_contains "エラーメッセージに targetFiles が含まれる" "$ITEM_VALIDATION_ERROR" "targetFiles"

echo "=== test: build_issue_body - 本文にparentRef/targetFiles/problem/expectedStateが含まれる ==="
build_issue_body "$FIXTURE_VALID_ITEM"
assert_contains "本文に parentRef が含まれる" "$ISSUE_BODY" "#12"
assert_contains "本文に1件目のtargetFileが含まれる" "$ISSUE_BODY" "- src/foo.ts"
assert_contains "本文に2件目のtargetFileが含まれる" "$ISSUE_BODY" "- src/bar.ts"
assert_contains "本文に problem が含まれる" "$ISSUE_BODY" "バリデーションロジックが3箇所に重複している"
assert_contains "本文に expectedState が含まれる" "$ISSUE_BODY" "共通関数に切り出され、重複が解消されている"

echo "=== test: build_issue_body - priority指定時は優先度セクションが出力される（Issue #55 デグレレビュー対応） ==="
build_issue_body "$FIXTURE_ITEM_WITH_PRIORITY"
assert_contains "本文に優先度セクションの見出しが含まれる" "$ISSUE_BODY" "## 優先度"
assert_contains "本文に優先度の値が含まれる" "$ISSUE_BODY" "高"

echo "=== test: build_issue_body - priority未指定時は優先度セクションが省略される ==="
build_issue_body "$FIXTURE_VALID_ITEM"
assert_not_contains "本文に優先度セクションが含まれない" "$ISSUE_BODY" "## 優先度"

echo "=== test: extract_issue_number_from_url - 複数行出力でも正しいissue番号だけを抽出する ==="
MULTILINE_OUTPUT=$'Warning: something happened 42\nhttps://github.com/example/repo/issues/777'
assert_eq "issue番号が777のみ（警告行の数字42を拾わない）" "777" "$(extract_issue_number_from_url "$MULTILINE_OUTPUT")"

echo "=== test: check_granularity_warning - 閾値以下では警告なし ==="
check_granularity_warning "$FIXTURE_UNDER_THRESHOLD"
assert_eq "GRANULARITY_WARNING が空" "" "$GRANULARITY_WARNING"

echo "=== test: check_granularity_warning - 閾値超過で警告あり ==="
check_granularity_warning "$FIXTURE_OVER_THRESHOLD"
assert_eq "GRANULARITY_WARNING が target_files_exceeds_threshold" "target_files_exceeds_threshold" "$GRANULARITY_WARNING"

echo "=== test: process_manifest_item - 正常項目はcreatedになりwarningを含まない（モック使用） ==="
create_github_issue() { mock_create_github_issue "$@"; }
process_manifest_item "0" "$FIXTURE_VALID_ITEM"
assert_eq "status が created" "created" "$(jq -r '.status' <<<"$ITEM_RESULT_JSON")"
assert_eq "index が 0" "0" "$(jq -r '.index' <<<"$ITEM_RESULT_JSON")"
assert_eq "issueNumberが数値として入る" "101" "$(jq -r '.issueNumber' <<<"$ITEM_RESULT_JSON")"
assert_eq "issueUrlが入る" "https://github.com/example/repo/issues/101" "$(jq -r '.issueUrl' <<<"$ITEM_RESULT_JSON")"
assert_eq "warningキーが存在しない" "false" "$(jq 'has("warning")' <<<"$ITEM_RESULT_JSON")"

echo "=== test: process_manifest_item - 閾値超過項目はwarningフィールドを持つ（起票は止めない）（モック使用） ==="
create_github_issue() { mock_create_github_issue "$@"; }
process_manifest_item "1" "$FIXTURE_OVER_THRESHOLD"
assert_eq "status が created（起票は止めない）" "created" "$(jq -r '.status' <<<"$ITEM_RESULT_JSON")"
assert_eq "warningがtarget_files_exceeds_threshold" "target_files_exceeds_threshold" "$(jq -r '.warning' <<<"$ITEM_RESULT_JSON")"

echo "=== test: process_manifest_item - 必須フィールド欠落項目はfailedになりghは呼ばれない ==="
GH_CALLED=0
create_github_issue() { GH_CALLED=1; mock_create_github_issue "$@"; }
process_manifest_item "2" "$FIXTURE_MISSING_MULTIPLE"
assert_eq "status が failed" "failed" "$(jq -r '.status' <<<"$ITEM_RESULT_JSON")"
assert_eq "gh呼び出しが行われていない" "0" "$GH_CALLED"
assert_contains "errorにフィールド欠落の情報が含まれる" "$(jq -r '.error' <<<"$ITEM_RESULT_JSON")" "parentRef"

echo "=== test: process_manifest_item - gh呼び出し失敗はfailedになりエラーを記録する ==="
create_github_issue() { mock_create_github_issue "$@"; }
FIXTURE_GH_FAIL_ITEM='{"title":"GH_FAIL_MARKER 項目","parentRef":"#12","targetFiles":["src/z.ts"],"problem":"問題","expectedState":"期待状態"}'
process_manifest_item "3" "$FIXTURE_GH_FAIL_ITEM"
assert_eq "status が failed" "failed" "$(jq -r '.status' <<<"$ITEM_RESULT_JSON")"
assert_contains "errorにgh失敗メッセージが含まれる" "$(jq -r '.error' <<<"$ITEM_RESULT_JSON")" "simulated failure"

echo "=== test: process_manifest_item - gh成功時にstderrへ警告が出てもissueUrlに混入しない（silent failure回帰防止） ==="
create_github_issue() {
  echo "gh: a warning you can ignore (rate limit notice)" >&2
  echo "https://github.com/example/repo/issues/888"
  return 0
}
process_manifest_item "0" "$FIXTURE_VALID_ITEM"
assert_eq "status が created" "created" "$(jq -r '.status' <<<"$ITEM_RESULT_JSON")"
assert_eq "issueUrlに警告文言が混入していない" "https://github.com/example/repo/issues/888" "$(jq -r '.issueUrl' <<<"$ITEM_RESULT_JSON")"
assert_eq "issueNumberが888" "888" "$(jq -r '.issueNumber' <<<"$ITEM_RESULT_JSON")"

echo "=== test: process_manifest_item - gh成功時にstdoutへ複数行出力があってもissueUrlはURL行のみになる（型混入の回帰防止） ==="
create_github_issue() {
  echo "https://github.com/example/repo/issues/999"
  echo "Tip: connect with gh CLI"
  return 0
}
process_manifest_item "0" "$FIXTURE_VALID_ITEM"
assert_eq "status が created" "created" "$(jq -r '.status' <<<"$ITEM_RESULT_JSON")"
assert_eq "issueUrlがURL行のみ（Tip行が混入しない）" "https://github.com/example/repo/issues/999" "$(jq -r '.issueUrl' <<<"$ITEM_RESULT_JSON")"
assert_eq "issueNumberが999" "999" "$(jq -r '.issueNumber' <<<"$ITEM_RESULT_JSON")"

echo "=== test: process_manifest_item - gh成功と判定されたがURLが抽出できない場合はfailedにする ==="
create_github_issue() {
  echo "unexpected output without a URL"
  return 0
}
process_manifest_item "0" "$FIXTURE_VALID_ITEM"
assert_eq "status が failed（URL抽出不能はfailed扱い）" "failed" "$(jq -r '.status' <<<"$ITEM_RESULT_JSON")"

echo "=== test: process_manifest - 空manifestは0件・exit相当のcreated/failedともに0で完了する ==="
create_github_issue() { mock_create_github_issue "$@"; }
process_manifest "[]"
assert_eq "resultsが空配列" "0" "$(jq '.results | length' <<<"$RESULTS_JSON")"
assert_eq "createdCountが0" "0" "$(jq -r '.createdCount' <<<"$RESULTS_JSON")"
assert_eq "failedCountが0" "0" "$(jq -r '.failedCount' <<<"$RESULTS_JSON")"

echo "=== test: process_manifest - 混在manifestで対応表が正しく組み立てられる ==="
create_github_issue() { mock_create_github_issue "$@"; }
MOCK_ISSUE_COUNTER=200
process_manifest "$FIXTURE_MANIFEST_MIXED"
assert_eq "results が4件" "4" "$(jq '.results | length' <<<"$RESULTS_JSON")"
assert_eq "index0 は created" "created" "$(jq -r '.results[0].status' <<<"$RESULTS_JSON")"
assert_eq "index1 は failed（必須フィールド欠落）" "failed" "$(jq -r '.results[1].status' <<<"$RESULTS_JSON")"
assert_eq "index2 は created（警告あり）" "created" "$(jq -r '.results[2].status' <<<"$RESULTS_JSON")"
assert_eq "index2 の warning" "target_files_exceeds_threshold" "$(jq -r '.results[2].warning' <<<"$RESULTS_JSON")"
assert_eq "index3 は failed（gh失敗）" "failed" "$(jq -r '.results[3].status' <<<"$RESULTS_JSON")"
assert_eq "createdCount が 2" "2" "$(jq -r '.createdCount' <<<"$RESULTS_JSON")"
assert_eq "failedCount が 2" "2" "$(jq -r '.failedCount' <<<"$RESULTS_JSON")"

echo "=== test: process_manifest - 各Issue起票直後にstderrへ逐次結果を出力する（中断時の二重起票対策・Issue #55 デグレレビュー対応） ==="
create_github_issue() { mock_create_github_issue "$@"; }
MOCK_ISSUE_COUNTER=500
PROGRESS_STDERR=$( { process_manifest "$FIXTURE_MANIFEST_MIXED" >/dev/null; } 2>&1 )
assert_contains "index0（created）の進捗行がstderrに出る" "$PROGRESS_STDERR" "[0] created"
assert_contains "index0の進捗行にタイトルが含まれる" "$PROGRESS_STDERR" "item0 通常項目"
assert_contains "index1（failed）の進捗行がstderrに出る" "$PROGRESS_STDERR" "[1] failed"
assert_contains "index2（created・警告あり）の進捗行がstderrに出る" "$PROGRESS_STDERR" "[2] created"
assert_contains "index3（failed・gh失敗）の進捗行がstderrに出る" "$PROGRESS_STDERR" "[3] failed"

echo "=== test: CLIレベル（main関数直接呼び出し、ghはモック） - 全件成功でexit 0 ==="
create_github_issue() { mock_create_github_issue "$@"; }
MOCK_ISSUE_COUNTER=300
TMP_MANIFEST_ALL_OK="$(mktemp)"
printf '[%s]' "$FIXTURE_VALID_ITEM" >"$TMP_MANIFEST_ALL_OK"
CLI_OUTPUT_OK=$(main "$TMP_MANIFEST_ALL_OK")
CLI_EXIT_OK=$?
rm -f "$TMP_MANIFEST_ALL_OK"
assert_eq "exit code が 0（全件成功）" "0" "$CLI_EXIT_OK"
assert_eq "resultsが1件" "1" "$(jq '.results | length' <<<"$CLI_OUTPUT_OK")"
assert_eq "createdCountが1" "1" "$(jq -r '.createdCount' <<<"$CLI_OUTPUT_OK")"

echo "=== test: CLIレベル（main関数直接呼び出し） - 部分失敗を含む場合はexit 1（stdoutには対応表を出す） ==="
create_github_issue() { mock_create_github_issue "$@"; }
MOCK_ISSUE_COUNTER=400
TMP_MANIFEST_MIXED="$(mktemp)"
printf '%s' "$FIXTURE_MANIFEST_MIXED" >"$TMP_MANIFEST_MIXED"
CLI_OUTPUT_MIXED=$(main "$TMP_MANIFEST_MIXED")
CLI_EXIT_MIXED=$?
rm -f "$TMP_MANIFEST_MIXED"
assert_eq "exit code が 1（部分失敗）" "1" "$CLI_EXIT_MIXED"
assert_eq "resultsが4件（stdoutにJSONが出ている）" "4" "$(jq '.results | length' <<<"$CLI_OUTPUT_MIXED")"

echo "=== test: CLIレベル - manifestファイルが存在しない場合はexit非0 ==="
main "/nonexistent/path/manifest.json" >/dev/null 2>/dev/null
assert_eq "exit code が非0" "1" "$?"

echo "=== test: CLIレベル - manifestが配列でないJSONの場合はexit非0 ==="
TMP_MANIFEST_NOT_ARRAY="$(mktemp)"
printf '{"foo":"bar"}' >"$TMP_MANIFEST_NOT_ARRAY"
main "$TMP_MANIFEST_NOT_ARRAY" >/dev/null 2>/dev/null
CLI_EXIT_NOT_ARRAY=$?
rm -f "$TMP_MANIFEST_NOT_ARRAY"
assert_eq "exit code が非0" "1" "$CLI_EXIT_NOT_ARRAY"

echo "=== test: CLIレベル - manifestが不正なJSONの場合はexit非0 ==="
TMP_MANIFEST_INVALID_JSON="$(mktemp)"
printf 'not a json' >"$TMP_MANIFEST_INVALID_JSON"
main "$TMP_MANIFEST_INVALID_JSON" >/dev/null 2>/dev/null
CLI_EXIT_INVALID_JSON=$?
rm -f "$TMP_MANIFEST_INVALID_JSON"
assert_eq "exit code が非0" "1" "$CLI_EXIT_INVALID_JSON"

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
