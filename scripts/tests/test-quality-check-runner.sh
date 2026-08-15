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

# Issue #154: npm workspaces では集計行がワークスペースごとに出力される。
# 最後の1件だけを採用すると実態と乖離するため合算する。
LINT_WORKSPACES="$(
  cat <<'EOF'
> pkg-a@1.0.0 lint
✖ 4 problems (3 errors, 1 warning)

> pkg-b@1.0.0 lint
✖ 30 problems (10 errors, 20 warnings)
EOF
)"
assert_eq "npm workspacesの複数集計行を合算する（最後のワークスペース分だけにしない）" \
  "13 21" "$(parse_lint_counts "$LINT_WORKSPACES")"

LINT_WITH_DETAIL="$(
  cat <<'EOF'
/src/a.ts
  1:1  error  Unexpected var  no-var

✖ 2 problems (2 errors, 0 warnings)
EOF
)"
assert_eq "集計行がある場合は個別の指摘行を合算対象にしない（二重計上防止）" \
  "2 0" "$(parse_lint_counts "$LINT_WITH_DETAIL")"

# =============================================================================
echo "=== test: parse_typecheck_errors ==="
# =============================================================================

assert_eq "tsc形式 'Found N errors.' から抽出" \
  "3" "$(parse_typecheck_errors 'Found 3 errors in 2 files.')"
assert_eq "単数形 'Found 1 error.' も抽出できる" \
  "1" "$(parse_typecheck_errors 'Found 1 error.')"
assert_eq "該当パターンが無い場合は null" \
  "null" "$(parse_typecheck_errors 'compiled successfully')"

TSC_WORKSPACES="$(
  cat <<'EOF'
> pkg-a@1.0.0 typecheck
src/a.ts(3,5): error TS2322: Type 'string' is not assignable to type 'number'.
Found 1 error in 1 file.

> pkg-b@1.0.0 typecheck
Found 4 errors in 2 files.
EOF
)"
assert_eq "npm workspacesの複数 'Found N errors' を合算する" \
  "5" "$(parse_typecheck_errors "$TSC_WORKSPACES")"

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

# Issue #154 の実測不具合: npm workspaces で最後のワークスペース分しか拾えていなかった
# （実測 934 tests に対し 246 を報告）。集計行をすべて合算して解消する。
JEST_WORKSPACES="$(
  cat <<'EOF'
> pkg-a@1.0.0 test
Test Suites: 12 passed, 12 total
Tests:       500 passed, 500 total

> pkg-b@1.0.0 test
Test Suites: 5 passed, 5 total
Tests:       188 passed, 188 total

> pkg-c@1.0.0 test
Test Suites: 7 passed, 7 total
Tests:       246 passed, 246 total
EOF
)"
assert_eq "npm workspacesの複数 'Tests:' 行を合算する（最後のワークスペース分だけにしない）" \
  "934 null null" "$(parse_test_counts "$JEST_WORKSPACES")"

JEST_SUITES_AND_TESTS="$(
  cat <<'EOF'
Test Suites: 1 failed, 2 passed, 3 total
Tests:       4 failed, 20 passed, 1 skipped, 25 total
Snapshots:   0 total
EOF
)"
assert_eq "'Test Suites:' 行を合算対象にしない（スイート数の二重計上防止）" \
  "20 4 1" "$(parse_test_counts "$JEST_SUITES_AND_TESTS")"

VITEST_WORKSPACES="$(
  cat <<'EOF'
 Test Files  3 passed (3)
      Tests  30 passed | 2 skipped (32)

 Test Files  1 passed (1)
      Tests  10 passed (10)
EOF
)"
assert_eq "Vitest形式でも 'Test Files' を除外して 'Tests' 行のみ合算する" \
  "40 null 2" "$(parse_test_counts "$VITEST_WORKSPACES")"

CARGO_STYLE="$(
  cat <<'EOF'
test result: ok. 12 passed; 0 failed; 1 ignored;
test result: ok. 30 passed; 0 failed; 0 ignored;
EOF
)"
assert_eq "'Tests' 集計行を持たない形式（cargo等）でも複数行を合算する" \
  "42 0 null" "$(parse_test_counts "$CARGO_STYLE")"

assert_eq "先頭ゼロの件数を8進数と解釈しない" \
  "8 null null" "$(parse_test_counts '08 passed')"

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

"$TARGET_SCRIPT" --lint "exit 0" --lint "exit 0" >/dev/null 2>&1
assert_eq "--lint を2回指定した場合はexit 1（無言の上書きを許さない）" "1" "$?"

"$TARGET_SCRIPT" --typecheck "exit 0" --typecheck "exit 0" >/dev/null 2>&1
assert_eq "--typecheck を2回指定した場合はexit 1" "1" "$?"

"$TARGET_SCRIPT" --test "exit 0" --test "exit 0" >/dev/null 2>&1
assert_eq "--test を2回指定した場合はexit 1" "1" "$?"

"$TARGET_SCRIPT" --lint "" --lint "exit 0" >/dev/null 2>&1
assert_eq "1回目が空文字でも2回目の--lintはexit 1（値の中身でなくフラグ指定回数で重複判定）" "1" "$?"

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
