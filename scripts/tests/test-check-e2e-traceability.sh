#!/bin/bash
# test-check-e2e-traceability.sh
# scripts/check-e2e-traceability.sh の突合関数（check_traceability）を
# 外部コマンド（jq以外）を呼ばずに直接テストする。
#
# 実行方法: bash scripts/tests/test-check-e2e-traceability.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../check-e2e-traceability.sh"

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

# --- フィクスチャ: criteria JSON（extract-acceptance-criteria.sh の出力形式） ---

read -r -d '' FIXTURE_CRITERIA <<'EOF'
{"issue": 54, "criteria": [
  {"id": "AC-1", "text": "ユーザーはログインできる", "checked": false},
  {"id": "AC-2", "text": "ログイン失敗時にエラーメッセージが表示される", "checked": false}
], "parse_status": "ok"}
EOF

read -r -d '' FIXTURE_CRITERIA_NO_CHECKLIST <<'EOF'
{"issue": 54, "criteria": [], "parse_status": "no_checklist_found"}
EOF

# --- フィクスチャ: trace JSON（テストケース設計のトレーサビリティ表） ---

read -r -d '' FIXTURE_TRACE_FULL_COVERAGE <<'EOF'
{"cases": [
  {"name": "ログイン成功", "class": "正常系", "criteria": ["AC-1"]},
  {"name": "ログイン失敗", "class": "異常系", "criteria": ["AC-2"]}
]}
EOF

read -r -d '' FIXTURE_TRACE_UNCOVERED <<'EOF'
{"cases": [
  {"name": "ログイン成功", "class": "正常系", "criteria": ["AC-1"]}
]}
EOF

read -r -d '' FIXTURE_TRACE_UNKNOWN_ID <<'EOF'
{"cases": [
  {"name": "ログイン成功", "class": "正常系", "criteria": ["AC-1", "AC-99"]},
  {"name": "ログイン失敗", "class": "異常系", "criteria": ["AC-2", "AC-99"]}
]}
EOF

read -r -d '' FIXTURE_TRACE_EMPTY <<'EOF'
{"cases": []}
EOF

read -r -d '' FIXTURE_TRACE_MISSING_CASES_KEY <<'EOF'
{"foo": []}
EOF

read -r -d '' FIXTURE_CRITERIA_MISSING_KEY <<'EOF'
{"issue": 54, "parse_status": "ok"}
EOF

FIXTURE_TRACE_CASES_NOT_ARRAY='{"cases": null}'
FIXTURE_CRITERIA_NOT_ARRAY='{"issue": 54, "criteria": null, "parse_status": "ok"}'

echo "=== test: 全カバー時に status=ok, uncovered/unknown_idsが空 ==="
check_traceability "$FIXTURE_CRITERIA" "$FIXTURE_TRACE_FULL_COVERAGE"
assert_eq "status が ok" "ok" "$(jq -r '.status' <<<"$RESULT_JSON")"
assert_eq "uncovered が空配列" "0" "$(jq '.uncovered | length' <<<"$RESULT_JSON")"
assert_eq "unknown_ids が空配列" "0" "$(jq '.unknown_ids | length' <<<"$RESULT_JSON")"

echo "=== test: 未カバーが1件ある場合にuncoveredへ正しいid/textが入る ==="
check_traceability "$FIXTURE_CRITERIA" "$FIXTURE_TRACE_UNCOVERED"
assert_eq "status が issues_found" "issues_found" "$(jq -r '.status' <<<"$RESULT_JSON")"
assert_eq "uncovered が1件" "1" "$(jq '.uncovered | length' <<<"$RESULT_JSON")"
assert_eq "uncoveredのidがAC-2" "AC-2" "$(jq -r '.uncovered[0].id' <<<"$RESULT_JSON")"
assert_eq "uncoveredのtextが正しい" "ログイン失敗時にエラーメッセージが表示される" "$(jq -r '.uncovered[0].text' <<<"$RESULT_JSON")"
assert_eq "unknown_ids が空配列" "0" "$(jq '.unknown_ids | length' <<<"$RESULT_JSON")"

echo "=== test: trace側に criteria 集合に存在しないIDがある場合にunknown_idsへ入る（重複除去） ==="
check_traceability "$FIXTURE_CRITERIA" "$FIXTURE_TRACE_UNKNOWN_ID"
assert_eq "status が issues_found" "issues_found" "$(jq -r '.status' <<<"$RESULT_JSON")"
assert_eq "unknown_ids が1件（重複除去済み）" "1" "$(jq '.unknown_ids | length' <<<"$RESULT_JSON")"
assert_eq "unknown_idsの中身がAC-99" "AC-99" "$(jq -r '.unknown_ids[0]' <<<"$RESULT_JSON")"
assert_eq "uncovered が空配列（AC-1,AC-2 とも1回はカバーされている）" "0" "$(jq '.uncovered | length' <<<"$RESULT_JSON")"

echo "=== test: uncoveredとunknown_idsが同時に非空になる複合ケース ==="
read -r -d '' FIXTURE_TRACE_UNCOVERED_AND_UNKNOWN <<'EOF'
{"cases": [
  {"name": "ログイン成功", "class": "正常系", "criteria": ["AC-1", "AC-99"]}
]}
EOF
check_traceability "$FIXTURE_CRITERIA" "$FIXTURE_TRACE_UNCOVERED_AND_UNKNOWN"
assert_eq "status が issues_found" "issues_found" "$(jq -r '.status' <<<"$RESULT_JSON")"
assert_eq "uncovered が1件（AC-2）" "AC-2" "$(jq -r '.uncovered[0].id' <<<"$RESULT_JSON")"
assert_eq "unknown_ids が1件（AC-99）" "AC-99" "$(jq -r '.unknown_ids[0]' <<<"$RESULT_JSON")"

echo "=== test: criteria側のparse_statusがno_checklist_foundの場合にstatus=no_criteria ==="
check_traceability "$FIXTURE_CRITERIA_NO_CHECKLIST" "$FIXTURE_TRACE_EMPTY"
assert_eq "status が no_criteria" "no_criteria" "$(jq -r '.status' <<<"$RESULT_JSON")"
assert_eq "uncovered が空配列" "0" "$(jq '.uncovered | length' <<<"$RESULT_JSON")"
assert_eq "unknown_ids が空配列" "0" "$(jq '.unknown_ids | length' <<<"$RESULT_JSON")"

echo "=== test: criteria配列が空（parse_statusはokでも）status=no_criteria ==="
FIXTURE_CRITERIA_EMPTY_ARRAY='{"issue": 1, "criteria": [], "parse_status": "ok"}'
check_traceability "$FIXTURE_CRITERIA_EMPTY_ARRAY" "$FIXTURE_TRACE_EMPTY"
assert_eq "status が no_criteria" "no_criteria" "$(jq -r '.status' <<<"$RESULT_JSON")"

echo "=== test: 不正なJSON入力でcheck_traceabilityが失敗を返す ==="
if check_traceability "not a json" "$FIXTURE_TRACE_FULL_COVERAGE" 2>/dev/null; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("不正なcriteria JSONで非0を返す")
  echo "  NG - 不正なcriteria JSONで非0を返す"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 不正なcriteria JSONで非0を返す"
fi

echo "=== test: criteria側にcriteriaキーが無い場合に失敗を返す ==="
if check_traceability "$FIXTURE_CRITERIA_MISSING_KEY" "$FIXTURE_TRACE_FULL_COVERAGE" 2>/dev/null; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("criteriaキー欠如で非0を返す")
  echo "  NG - criteriaキー欠如で非0を返す"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - criteriaキー欠如で非0を返す"
fi

echo "=== test: trace側にcasesキーが無い場合に失敗を返す ==="
if check_traceability "$FIXTURE_CRITERIA" "$FIXTURE_TRACE_MISSING_CASES_KEY" 2>/dev/null; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("casesキー欠如で非0を返す")
  echo "  NG - casesキー欠如で非0を返す"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - casesキー欠如で非0を返す"
fi

echo "=== test: trace側のcasesが配列でない（null）場合にスタックトレースを吐かず非0を返す ==="
STDERR_OUTPUT="$(check_traceability "$FIXTURE_CRITERIA" "$FIXTURE_TRACE_CASES_NOT_ARRAY" 2>&1 1>/dev/null)"
CASES_NOT_ARRAY_EXIT=$?
if [ "$CASES_NOT_ARRAY_EXIT" -ne 0 ]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - cases が配列でない場合に非0を返す"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("casesが配列でない場合に非0を返す")
  echo "  NG - casesが配列でない場合に非0を返す"
fi
if echo "$STDERR_OUTPUT" | grep -qi "jq: error"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("casesが配列でない場合にjqのスタックトレースを吐かない")
  echo "  NG - casesが配列でない場合にjqのスタックトレースを吐かない"
  echo "       stderr: ${STDERR_OUTPUT}"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - casesが配列でない場合にjqのスタックトレースを吐かない"
fi

echo "=== test: criteria側のcriteriaが配列でない（null）場合に非0を返す ==="
if check_traceability "$FIXTURE_CRITERIA_NOT_ARRAY" "$FIXTURE_TRACE_FULL_COVERAGE" 2>/dev/null; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("criteriaが配列でない場合に非0を返す")
  echo "  NG - criteriaが配列でない場合に非0を返す"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - criteriaが配列でない場合に非0を返す"
fi

echo "=== test: CLIレベル（一時ファイル経由）での統合確認 ==="
CRITERIA_FILE="$(mktemp)"
TRACE_FILE="$(mktemp)"
printf '%s' "$FIXTURE_CRITERIA" >"$CRITERIA_FILE"
printf '%s' "$FIXTURE_TRACE_UNCOVERED" >"$TRACE_FILE"
CLI_OUTPUT=$("$TARGET_SCRIPT" "$CRITERIA_FILE" "$TRACE_FILE")
CLI_EXIT=$?
rm -f "$CRITERIA_FILE" "$TRACE_FILE"
assert_eq "exit code が 0（issues_foundも正常動作）" "0" "$CLI_EXIT"
assert_eq "statusがissues_found" "issues_found" "$(jq -r '.status' <<<"$CLI_OUTPUT")"
assert_eq "uncoveredが1件" "1" "$(jq '.uncovered | length' <<<"$CLI_OUTPUT")"

echo "=== test: CLIレベル（-によるstdin指定）での統合確認 ==="
CRITERIA_FILE2="$(mktemp)"
printf '%s' "$FIXTURE_CRITERIA" >"$CRITERIA_FILE2"
CLI_OUTPUT2=$(printf '%s' "$FIXTURE_TRACE_FULL_COVERAGE" | "$TARGET_SCRIPT" "$CRITERIA_FILE2" -)
CLI_EXIT2=$?
rm -f "$CRITERIA_FILE2"
assert_eq "exit code が 0" "0" "$CLI_EXIT2"
assert_eq "statusがok" "ok" "$(jq -r '.status' <<<"$CLI_OUTPUT2")"

echo "=== test: CLIレベル（criteria側を- によるstdin指定）での統合確認 ==="
TRACE_FILE3="$(mktemp)"
printf '%s' "$FIXTURE_TRACE_FULL_COVERAGE" >"$TRACE_FILE3"
CLI_OUTPUT3=$(printf '%s' "$FIXTURE_CRITERIA" | "$TARGET_SCRIPT" - "$TRACE_FILE3")
CLI_EXIT3=$?
rm -f "$TRACE_FILE3"
assert_eq "exit code が 0" "0" "$CLI_EXIT3"
assert_eq "statusがok" "ok" "$(jq -r '.status' <<<"$CLI_OUTPUT3")"

echo "=== test: CLIレベル（両方stdin指定はエラー）でexit非0 ==="
if printf 'x' | "$TARGET_SCRIPT" - - >/dev/null 2>&1; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("両方stdin指定でexit非0")
  echo "  NG - 両方stdin指定でexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 両方stdin指定でexit非0"
fi

echo "=== test: CLIレベル（存在しないファイル指定）でexit非0 ==="
if "$TARGET_SCRIPT" /tmp/does-not-exist-check-e2e-traceability.json "$FIXTURE_TRACE_FULL_COVERAGE" >/dev/null 2>&1; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("存在しないファイルでexit非0")
  echo "  NG - 存在しないファイルでexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 存在しないファイルでexit非0"
fi

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
