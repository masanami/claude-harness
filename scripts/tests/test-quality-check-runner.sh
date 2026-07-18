#!/bin/bash
# test-quality-check-runner.sh
# scripts/quality-check-runner.sh の純粋関数（gate_status_from_exit / compute_result /
# parse_lint_counts / parse_typecheck_errors / parse_test_counts / join_by）と、
# CLI レベルでの全ゲート分岐（pass/fail/skip・auto-fix適用）を検証する。
# 後者は実コマンドを実行しないモックコマンド文字列（"exit 0" 等）を
# --lint/--typecheck/--test/--auto-fix に渡すことで、外部プロジェクトのツール
# チェインに依存せずゲーティングロジックだけを検証する。
#
# 実行方法: bash scripts/tests/test-quality-check-runner.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../quality-check-runner.sh"

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

# =============================================================================
echo "=== test: gate_status_from_exit ==="
# =============================================================================

assert_eq "exit 0 -> pass" "pass" "$(gate_status_from_exit 0)"
assert_eq "exit 1 -> fail" "fail" "$(gate_status_from_exit 1)"
assert_eq "exit 127 -> fail" "fail" "$(gate_status_from_exit 127)"

# =============================================================================
echo "=== test: compute_result ==="
# =============================================================================

assert_eq "全てpass -> pass" "pass" "$(compute_result "pass" "pass" "pass")"
assert_eq "1つでもfailを含む -> fail" "fail" "$(compute_result "pass" "fail" "pass")"
assert_eq "全てskip -> pass（skipは失敗ではない）" "pass" "$(compute_result "skip" "skip" "skip")"
assert_eq "pass/skip混在でfail無し -> pass" "pass" "$(compute_result "pass" "skip" "pass")"

# =============================================================================
echo "=== test: parse_lint_counts ==="
# =============================================================================

assert_eq "ESLint形式 'X problems (Y errors, Z warnings)' から抽出" \
  "3 7" "$(parse_lint_counts '10 problems (3 errors, 7 warnings)')"
assert_eq "2桁以上の件数を誤って末尾の桁だけ抽出しない（貪欲マッチ境界バグの回帰防止）" \
  "138 24" "$(parse_lint_counts 'summary: 138 errors, 24 warnings found')"
assert_eq "該当パターンが無い場合は errors/warnings ともに null" \
  "null null" "$(parse_lint_counts 'no issues found')"
assert_eq "errorsのみ言及されている場合はwarningsがnull" \
  "5 null" "$(parse_lint_counts '5 errors detected')"

# =============================================================================
echo "=== test: parse_typecheck_errors ==="
# =============================================================================

assert_eq "tsc形式 'Found N errors.' から抽出" \
  "3" "$(parse_typecheck_errors 'Found 3 errors in 2 files.')"
assert_eq "単数形 'Found 1 error.' も抽出できる" \
  "1" "$(parse_typecheck_errors 'Found 1 error.')"
assert_eq "該当パターンが無い場合は null" \
  "null" "$(parse_typecheck_errors 'compiled successfully')"

# =============================================================================
echo "=== test: parse_test_counts ==="
# =============================================================================

assert_eq "Jest/Vitest形式 'Tests: N failed, M passed, K skipped, T total' から抽出" \
  "8 2 1" "$(parse_test_counts 'Tests: 2 failed, 8 passed, 1 skipped, 11 total')"
assert_eq "pytest形式 'M passed, N failed in Ts' から抽出" \
  "5 1 null" "$(parse_test_counts '5 passed, 1 failed in 2.34s')"
assert_eq "2桁以上の件数を誤って末尾の桁だけ抽出しない（貪欲マッチ境界バグの回帰防止）" \
  "138 null null" "$(parse_test_counts '138 passed')"
assert_eq "該当パターンが無い場合は全て null" \
  "null null null" "$(parse_test_counts 'no test output')"

# =============================================================================
echo "=== test: join_by ==="
# =============================================================================

assert_eq "0個の要素 -> 空文字" "" "$(join_by " → " )"
assert_eq "1個の要素 -> そのまま" "cmd1" "$(join_by " → " "cmd1")"
assert_eq "複数要素を ' → ' で連結" "cmd1 → cmd2 → cmd3" "$(join_by " → " "cmd1" "cmd2" "cmd3")"

# =============================================================================
echo "=== test: CLI（全ゲートpass。件数抽出込み） ==="
# =============================================================================

OUT_ALL_PASS="$("$TARGET_SCRIPT" \
  --auto-fix "printf 'fixed\n'" \
  --lint "printf '0 problems (0 errors, 0 warnings)\n'" \
  --typecheck "printf 'Found 0 errors.\n'" \
  --test "printf 'Tests: 0 failed, 3 passed, 0 skipped, 3 total\n'")"
EXIT_ALL_PASS=$?

assert_eq "全ゲートpass時の result" "pass" "$(jq -r '.result' <<<"$OUT_ALL_PASS")"
assert_eq "全ゲートpass時の exit code" "0" "$EXIT_ALL_PASS"
assert_eq "auto_fix.applied が true" "true" "$(jq -r '.auto_fix.applied' <<<"$OUT_ALL_PASS")"
assert_eq "auto_fix.summary にコマンドが記録される" "printf 'fixed\n'" "$(jq -r '.auto_fix.summary' <<<"$OUT_ALL_PASS")"
assert_eq "lintゲートのstatus" "pass" "$(jq -r '.gates.lint.status' <<<"$OUT_ALL_PASS")"
assert_eq "lintゲートのerrors件数" "0" "$(jq -r '.gates.lint.errors' <<<"$OUT_ALL_PASS")"
assert_eq "typecheckゲートのstatus" "pass" "$(jq -r '.gates.typecheck.status' <<<"$OUT_ALL_PASS")"
assert_eq "testゲートのstatus" "pass" "$(jq -r '.gates.test.status' <<<"$OUT_ALL_PASS")"
assert_eq "testゲートのpassed件数" "3" "$(jq -r '.gates.test.passed' <<<"$OUT_ALL_PASS")"

# =============================================================================
echo "=== test: CLI（lintのみfail。他はskip。exit codeで判定しwarningsは無視） ==="
# =============================================================================

OUT_LINT_FAIL="$("$TARGET_SCRIPT" --lint "printf '0 errors, 5 warnings\n'; exit 1")"
EXIT_LINT_FAIL=$?

assert_eq "lintのみ指定時、他ゲートはskip" "skip" "$(jq -r '.gates.typecheck.status' <<<"$OUT_LINT_FAIL")"
assert_eq "lint fail時 result は fail" "fail" "$(jq -r '.result' <<<"$OUT_LINT_FAIL")"
assert_eq "lint fail時 exit code は 1" "1" "$EXIT_LINT_FAIL"
assert_eq "status判定はexit codeのみ（errors=0でもexit非0ならfail）" \
  "fail" "$(jq -r '.gates.lint.status' <<<"$OUT_LINT_FAIL")"
assert_eq "auto-fix未指定時 applied は false" "false" "$(jq -r '.auto_fix.applied' <<<"$OUT_LINT_FAIL")"

# =============================================================================
echo "=== test: CLI（typecheckのみfail） ==="
# =============================================================================

OUT_TYPECHECK_FAIL="$("$TARGET_SCRIPT" \
  --lint "exit 0" \
  --typecheck "printf 'Found 2 errors.\n'; exit 1" \
  --test "exit 0")"

assert_eq "typecheck fail時 result は fail" "fail" "$(jq -r '.result' <<<"$OUT_TYPECHECK_FAIL")"
assert_eq "typecheckゲートのstatus" "fail" "$(jq -r '.gates.typecheck.status' <<<"$OUT_TYPECHECK_FAIL")"
assert_eq "typecheckゲートのerrors件数" "2" "$(jq -r '.gates.typecheck.errors' <<<"$OUT_TYPECHECK_FAIL")"
assert_eq "他ゲートがpassでも1つのfailでresultはfail" "pass" "$(jq -r '.gates.lint.status' <<<"$OUT_TYPECHECK_FAIL")"

# =============================================================================
echo "=== test: CLI（testのみfail） ==="
# =============================================================================

OUT_TEST_FAIL="$("$TARGET_SCRIPT" --test "printf 'Tests: 1 failed, 4 passed, 0 skipped, 5 total\n'; exit 1")"

assert_eq "test fail時 result は fail" "fail" "$(jq -r '.result' <<<"$OUT_TEST_FAIL")"
assert_eq "testゲートのstatus" "fail" "$(jq -r '.gates.test.status' <<<"$OUT_TEST_FAIL")"
assert_eq "testゲートのfailed件数" "1" "$(jq -r '.gates.test.failed' <<<"$OUT_TEST_FAIL")"
assert_eq "testゲートのpassed件数" "4" "$(jq -r '.gates.test.passed' <<<"$OUT_TEST_FAIL")"

# =============================================================================
echo "=== test: CLI（全ゲート未指定 -> 全てskip。resultはpass） ==="
# =============================================================================

OUT_ALL_SKIP="$("$TARGET_SCRIPT")"
EXIT_ALL_SKIP=$?

assert_eq "全ゲート未指定時 result は pass" "pass" "$(jq -r '.result' <<<"$OUT_ALL_SKIP")"
assert_eq "全ゲート未指定時 exit code は 0" "0" "$EXIT_ALL_SKIP"
assert_eq "lintゲートはskip" "skip" "$(jq -r '.gates.lint.status' <<<"$OUT_ALL_SKIP")"
assert_eq "typecheckゲートはskip" "skip" "$(jq -r '.gates.typecheck.status' <<<"$OUT_ALL_SKIP")"
assert_eq "testゲートはskip" "skip" "$(jq -r '.gates.test.status' <<<"$OUT_ALL_SKIP")"
assert_eq "skip時のerrors件数はnull" "null" "$(jq -r '.gates.lint.errors' <<<"$OUT_ALL_SKIP")"

# =============================================================================
echo "=== test: CLI（複数auto-fixコマンドを検出順に実行しsummaryへ連結） ==="
# =============================================================================

OUT_MULTI_AUTOFIX="$("$TARGET_SCRIPT" \
  --auto-fix "printf 'step1\n'" \
  --auto-fix "printf 'step2\n'" \
  --lint "exit 0")"

assert_eq "複数auto-fixのsummaryが検出順に連結される" \
  "printf 'step1\n' → printf 'step2\n'" "$(jq -r '.auto_fix.summary' <<<"$OUT_MULTI_AUTOFIX")"

# =============================================================================
echo "=== test: CLI（引数バリデーション） ==="
# =============================================================================

"$TARGET_SCRIPT" --lint >/dev/null 2>&1
assert_eq "--lint に値が無い場合はexit 1" "1" "$?"

"$TARGET_SCRIPT" --unknown-flag >/dev/null 2>&1
assert_eq "未知のフラグはexit 1" "1" "$?"

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
