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

# 部分一致アサーション（stderr のメッセージ検査用）。
assert_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"

  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
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
assert_eq "pass/skip混在でfail無し -> pass" "pass" "$(compute_result "pass" "skip" "pass")"

# Issue #192: 1つも実行していない状態（全skip）を「全ゲート通過」と読める pass にしない。
assert_eq "全てskip -> skip（検査していないものを pass に見せない）" \
  "skip" "$(compute_result "skip" "skip" "skip")"
assert_eq "引数なし（ゲートが1つも無い）-> skip（空集合を空虚に pass へ倒さない）" \
  "skip" "$(compute_result)"
assert_eq "fail と skip の混在 -> fail（failを最優先）" \
  "fail" "$(compute_result "skip" "fail" "skip")"

# fail-closed: status が既知の3値以外（ゲートJSONの組み立て失敗等で空になった場合を含む）
# は判定不能であり、pass 側へ落とさない。
assert_eq "空文字の status -> fail（判定不能を pass に丸めない）" \
  "fail" "$(compute_result "pass" "" "pass")"
assert_eq "未知の status -> fail（fail-closed）" \
  "fail" "$(compute_result "pass" "unknown" "skip")"

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

# CLI レベルのテストは、実プロジェクトのツールチェインに依存せずゲーティングロジック
# だけを検証する。従来はモックとしてシェル構文を含む文字列（"printf ...; exit 1"）を
# 渡していたが、ランナーはコマンドをシェルへ渡さなくなった（Issue #223）ため使えない。
# 代わりに **allowlist に載っている実行系の名前**でスタブ実行ファイルを一時ディレクトリに
# 作り、PATH の先頭に置く。現在の契約（allowlist に無い実行系は実行しない／シェル構文は
# 拒否する）を迂回せずにモックできる形はこれだけである。
FIXTURE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/qcr-fixture.XXXXXX")"
qcr_fixture_cleanup() {
  rm -rf "$FIXTURE_BIN"
}
trap qcr_fixture_cleanup EXIT
PATH="${FIXTURE_BIN}:${PATH}"
export PATH

# スタブを作る。引数: 実行ファイル名, 終了コード, 標準出力に出す本文
make_tool() {
  local name="$1" code="$2" output="$3"
  {
    printf '#!/bin/bash\n'
    printf "cat <<'QCR_FIXTURE_EOF'\n"
    printf '%s\n' "$output"
    printf 'QCR_FIXTURE_EOF\n'
    printf 'exit %s\n' "$code"
  } >"${FIXTURE_BIN}/${name}"
  chmod +x "${FIXTURE_BIN}/${name}"
}

make_tool prettier 0 'fixed'
make_tool eslint 0 '0 problems (0 errors, 0 warnings)'
make_tool tsc 0 'Found 0 errors.'
make_tool jest 0 'Tests: 0 failed, 3 passed, 0 skipped, 3 total'

OUT_ALL_PASS="$("$TARGET_SCRIPT" \
  --auto-fix "prettier --write ." \
  --lint "eslint ." \
  --typecheck "tsc --noEmit" \
  --test "jest" 2>/dev/null)"
EXIT_ALL_PASS=$?

assert_eq "全ゲートpass時の result" "pass" "$(jq -r '.result' <<<"$OUT_ALL_PASS")"
assert_eq "全ゲートpass時の exit code" "0" "$EXIT_ALL_PASS"
assert_eq "auto_fix.applied が true" "true" "$(jq -r '.auto_fix.applied' <<<"$OUT_ALL_PASS")"
assert_eq "auto_fix.summary にコマンドが記録される" "prettier --write ." "$(jq -r '.auto_fix.summary' <<<"$OUT_ALL_PASS")"
assert_eq "lintゲートのstatus" "pass" "$(jq -r '.gates.lint.status' <<<"$OUT_ALL_PASS")"
assert_eq "lintゲートのerrors件数" "0" "$(jq -r '.gates.lint.errors' <<<"$OUT_ALL_PASS")"
assert_eq "typecheckゲートのstatus" "pass" "$(jq -r '.gates.typecheck.status' <<<"$OUT_ALL_PASS")"
assert_eq "testゲートのstatus" "pass" "$(jq -r '.gates.test.status' <<<"$OUT_ALL_PASS")"
assert_eq "testゲートのpassed件数" "3" "$(jq -r '.gates.test.passed' <<<"$OUT_ALL_PASS")"

# =============================================================================
echo "=== test: CLI（lintのみfail。他はskip。exit codeで判定しwarningsは無視） ==="
# =============================================================================

make_tool eslint 1 '0 errors, 5 warnings'
OUT_LINT_FAIL="$("$TARGET_SCRIPT" --lint "eslint ." 2>/dev/null)"
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

make_tool eslint 0 '0 problems (0 errors, 0 warnings)'
make_tool tsc 1 'Found 2 errors.'
make_tool jest 0 'Tests: 0 failed, 1 passed, 0 skipped, 1 total'
OUT_TYPECHECK_FAIL="$("$TARGET_SCRIPT" \
  --lint "eslint ." \
  --typecheck "tsc --noEmit" \
  --test "jest" 2>/dev/null)"

assert_eq "typecheck fail時 result は fail" "fail" "$(jq -r '.result' <<<"$OUT_TYPECHECK_FAIL")"
assert_eq "typecheckゲートのstatus" "fail" "$(jq -r '.gates.typecheck.status' <<<"$OUT_TYPECHECK_FAIL")"
assert_eq "typecheckゲートのerrors件数" "2" "$(jq -r '.gates.typecheck.errors' <<<"$OUT_TYPECHECK_FAIL")"
assert_eq "他ゲートがpassでも1つのfailでresultはfail" "pass" "$(jq -r '.gates.lint.status' <<<"$OUT_TYPECHECK_FAIL")"

# =============================================================================
echo "=== test: CLI（testのみfail） ==="
# =============================================================================

make_tool jest 1 'Tests: 1 failed, 4 passed, 0 skipped, 5 total'
OUT_TEST_FAIL="$("$TARGET_SCRIPT" --test "jest" 2>/dev/null)"

assert_eq "test fail時 result は fail" "fail" "$(jq -r '.result' <<<"$OUT_TEST_FAIL")"
assert_eq "testゲートのstatus" "fail" "$(jq -r '.gates.test.status' <<<"$OUT_TEST_FAIL")"
assert_eq "testゲートのfailed件数" "1" "$(jq -r '.gates.test.failed' <<<"$OUT_TEST_FAIL")"
assert_eq "testゲートのpassed件数" "4" "$(jq -r '.gates.test.passed' <<<"$OUT_TEST_FAIL")"

# =============================================================================
echo "=== test: CLI（引数なし＝実行すべきゲートが1つも無い。Issue #192 の false pass 回帰） ==="
# =============================================================================
# 呼び出し側がフラグを渡し忘れた場合、「1つも検査していない」状態が pass（exit 0）
# として報告されると安全網が素通りする。result は専用の "skip"、exit code は 3 とし、
# exit code だけを見る呼び出し側にも result だけを見る呼び出し側にも成功と読ませない。

OUT_ALL_SKIP="$("$TARGET_SCRIPT" 2>/dev/null)"
EXIT_ALL_SKIP=$?

assert_eq "全ゲート未指定時 result は skip（pass にしない）" "skip" "$(jq -r '.result' <<<"$OUT_ALL_SKIP")"
assert_eq "全ゲート未指定時 exit code は 3（0 にしない）" "3" "$EXIT_ALL_SKIP"
assert_eq "lintゲートはskip" "skip" "$(jq -r '.gates.lint.status' <<<"$OUT_ALL_SKIP")"
assert_eq "typecheckゲートはskip" "skip" "$(jq -r '.gates.typecheck.status' <<<"$OUT_ALL_SKIP")"
assert_eq "testゲートはskip" "skip" "$(jq -r '.gates.test.status' <<<"$OUT_ALL_SKIP")"
assert_eq "skip時のerrors件数はnull" "null" "$(jq -r '.gates.lint.errors' <<<"$OUT_ALL_SKIP")"
assert_eq "ゲート未実行でも stdout のJSONは出力される（exit 2 の jq 不在とは異なる）" \
  "true" "$(jq -e 'has("gates")' <<<"$OUT_ALL_SKIP" >/dev/null 2>&1 && echo true || echo false)"

ERR_ALL_SKIP="$("$TARGET_SCRIPT" 2>&1 >/dev/null)"
assert_contains "ゲート未実行の事実が stderr に明示される" "$ERR_ALL_SKIP" "no quality gate was executed"

# --auto-fix は「直す」手続きであって検査ではないため、指定されていてもゲート実行数には数えない。
OUT_AUTOFIX_ONLY="$("$TARGET_SCRIPT" --auto-fix "prettier --write ." 2>/dev/null)"
EXIT_AUTOFIX_ONLY=$?

assert_eq "--auto-fix のみ指定でも result は skip（auto-fix は検査ではない）" \
  "skip" "$(jq -r '.result' <<<"$OUT_AUTOFIX_ONLY")"
assert_eq "--auto-fix のみ指定時 exit code は 3" "3" "$EXIT_AUTOFIX_ONLY"
assert_eq "--auto-fix のみ指定でも auto_fix.applied は true" \
  "true" "$(jq -r '.auto_fix.applied' <<<"$OUT_AUTOFIX_ONLY")"

# 空文字のコマンド（="" は skip 相当の指定）だけを渡した場合も「実行すべきゲートが1つも無い」。
OUT_EMPTY_CMDS="$("$TARGET_SCRIPT" --lint "" --typecheck "" --test "" 2>/dev/null)"
EXIT_EMPTY_CMDS=$?

assert_eq "空文字コマンドのみ（実行されるゲートが0）でも result は skip" \
  "skip" "$(jq -r '.result' <<<"$OUT_EMPTY_CMDS")"
assert_eq "空文字コマンドのみの exit code は 3" "3" "$EXIT_EMPTY_CMDS"

# =============================================================================
echo "=== test: CLI（ゲートを1つでも実行していれば従来どおり pass。後方互換） ==="
# =============================================================================
# 一部ゲートのみを指定する呼び出し（型チェックの無いプロジェクト等）は正当な既存経路。
# 「1つも実行していない」場合だけを skip とし、部分実行の pass は変えない。

make_tool jest 0 'Tests: 0 failed, 3 passed, 0 skipped, 3 total'
OUT_PARTIAL_PASS="$("$TARGET_SCRIPT" --test "jest" 2>/dev/null)"
EXIT_PARTIAL_PASS=$?

assert_eq "testゲートのみ実行して成功なら result は pass" "pass" "$(jq -r '.result' <<<"$OUT_PARTIAL_PASS")"
assert_eq "部分実行passの exit code は 0" "0" "$EXIT_PARTIAL_PASS"
assert_eq "未指定のlintゲートは skip のまま" "skip" "$(jq -r '.gates.lint.status' <<<"$OUT_PARTIAL_PASS")"

# =============================================================================
echo "=== test: CLI（複数auto-fixコマンドを検出順に実行しsummaryへ連結） ==="
# =============================================================================

make_tool prettier 0 'step1'
make_tool eslint 0 'step2'
OUT_MULTI_AUTOFIX="$("$TARGET_SCRIPT" \
  --auto-fix "prettier --write ." \
  --auto-fix "eslint --fix ." \
  --lint "true" 2>/dev/null)"

assert_eq "複数auto-fixのsummaryが検出順に連結される" \
  "prettier --write . → eslint --fix ." "$(jq -r '.auto_fix.summary' <<<"$OUT_MULTI_AUTOFIX")"

# =============================================================================
echo "=== test: CLI（引数バリデーション） ==="
# =============================================================================

"$TARGET_SCRIPT" --lint >/dev/null 2>&1
assert_eq "--lint に値が無い場合はexit 1" "1" "$?"

"$TARGET_SCRIPT" --unknown-flag >/dev/null 2>&1
assert_eq "未知のフラグはexit 1" "1" "$?"

"$TARGET_SCRIPT" --lint "true" --lint "true" >/dev/null 2>&1
assert_eq "--lint を2回指定した場合はexit 1（無言の上書きを許さない）" "1" "$?"

"$TARGET_SCRIPT" --typecheck "true" --typecheck "true" >/dev/null 2>&1
assert_eq "--typecheck を2回指定した場合はexit 1" "1" "$?"

"$TARGET_SCRIPT" --test "true" --test "true" >/dev/null 2>&1
assert_eq "--test を2回指定した場合はexit 1" "1" "$?"

"$TARGET_SCRIPT" --lint "" --lint "true" >/dev/null 2>&1
assert_eq "1回目が空文字でも2回目の--lintはexit 1（値の中身でなくフラグ指定回数で重複判定）" "1" "$?"

# =============================================================================
echo "=== test: CLI（シェル解釈を挟まない契約。詳細は test-command-spec.sh） ==="
# =============================================================================
# 迂回不能性そのものの固定は scripts/tests/test-command-spec.sh が担う。ここでは
# ランナーの CLI 契約として「拒否は exit 4／stdout に JSON を出さない」ことだけを確認する。

QCR_REJECT_STDOUT="$("$TARGET_SCRIPT" --lint "eslint .; touch /dev/null" 2>/dev/null)"
assert_eq "シェル構文を含むコマンドは exit 4" "4" "$?"
assert_eq "拒否時は stdout に JSON を出さない" "" "$QCR_REJECT_STDOUT"

# =============================================================================
echo "=== test: skip 契約が仕様・呼び出し側ドキュメントへ伝播しているか（Issue #192） ==="
# =============================================================================
# runner が返す "skip" は、最終的に LLM（スキル・サブエージェント）が解釈して初めて
# 意味を持つ。呼び出し側の手順が「skip も pass のうち」と読める状態へ戻ると、
# スクリプトを直しても false pass が LLM 層で復活する。そのため、仕様の正本と
# 各呼び出し側が skip を pass に読み替えない旨を明記していることを逐語で固定する。

QCR_TEST_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

assert_file_contains() {
  local description="$1"
  local file="$2"
  local needle="$3"

  if [ ! -f "$file" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file not found: ${file}"
    return
  fi
  if grep -qF -- "$needle" "$file"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected ${file} to contain: ${needle}"
  fi
}

assert_file_contains "仕様の正本に result:\"skip\" の節がある" \
  "${QCR_TEST_REPO_ROOT}/scripts/specs/quality-check-runner.md" \
  '## ゲートが1つも無い場合（`result: "skip"`）'
assert_file_contains "仕様の正本に skip の終了コード 3 が記載されている" \
  "${QCR_TEST_REPO_ROOT}/scripts/specs/quality-check-runner.md" \
  '`skip` なら 3'
assert_file_contains "/quality-check は skip を pass に読み替えない" \
  "${QCR_TEST_REPO_ROOT}/skills/quality-check/SKILL.md" \
  '`pass` にも読み替えない'
assert_file_contains "/promote-verify は skip をそのまま格納する（pass にも明示スキップにもしない）" \
  "${QCR_TEST_REPO_ROOT}/skills/promote-verify/SKILL.md" \
  'そのまま格納し、`pass` にも `skipped: true` にも読み替えない'
assert_file_contains "feature-implementer に skip の扱い（4-3）がある" \
  "${QCR_TEST_REPO_ROOT}/agents/feature-implementer.md" \
  '### 4-3. `skip`（ゲートが1つも実行されていない）場合'
assert_file_contains "/commit は skip を pass に読み替えず未検証として報告する" \
  "${QCR_TEST_REPO_ROOT}/skills/commit/SKILL.md" \
  '品質ゲート未検証であることをユーザーへの報告に明記する'
assert_file_contains "/para-impl のリードが skip の返却を扱う行を持つ" \
  "${QCR_TEST_REPO_ROOT}/skills/para-impl/SKILL.md" \
  '`skip`（`/quality-check` のゲートが1つも実行されていない）'

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
