#!/bin/bash
# test-lib-common.sh
# scripts/lib/common.sh の共通ヘルパー（check_jq / resolve_repo / fetch_pr_checks /
# JQ_FAIL_CANCEL_PREDICATE）を、外部コマンド（gh/jq の可用性）をスタブしつつ直接テストする。
#
# 実行方法: bash scripts/tests/test-lib-common.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LIB="${SCRIPT_DIR}/../lib/common.sh"

# shellcheck source=/dev/null
source "$TARGET_LIB"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

assert_eq() {
  local description="$1" expected="$2" actual="$3"
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

echo "=== check_jq ==="
{
  assert_eq "jqが存在する環境ではcheck_jqは0を返す" "0" "$(check_jq; echo $?)"

  # command -v jq を失敗させるため、PATH をコマンドが見つからないディレクトリに限定する
  # （builtin/functionは影響を受けないためサブシェルに閉じ込めて安全に検証する）。
  empty_path_dir="$(mktemp -d)"
  trap 'rm -rf "$empty_path_dir"' EXIT

  stderr_default="$(PATH="$empty_path_dir" check_jq 2>&1 1>/dev/null)"
  exit_default="$(PATH="$empty_path_dir" check_jq >/dev/null 2>&1; echo $?)"
  assert_eq "jq不在時はデフォルトのエラーJSONをstderrに出す" \
    '{"error":"jq not found"}' \
    "$(printf '%s\n' "$stderr_default" | tail -n 1)"
  assert_eq "jq不在時は非0を返す(デフォルト)" "1" "$exit_default"

  stderr_custom="$(PATH="$empty_path_dir" check_jq '{"status":"error","error":"jq not found"}' 2>&1 1>/dev/null)"
  exit_custom="$(PATH="$empty_path_dir" check_jq '{"status":"error","error":"jq not found"}' >/dev/null 2>&1; echo $?)"
  assert_eq "jq不在時は引数で渡したエラーJSONをstderrに出す(analyze-project.sh向け)" \
    '{"status":"error","error":"jq not found"}' \
    "$(printf '%s\n' "$stderr_custom" | tail -n 1)"
  assert_eq "jq不在時は非0を返す(カスタムエラーJSON指定時も)" "1" "$exit_custom"
  assert_eq "jq不在時のstderr1行目は共通のエラーメッセージ(カスタムエラーJSON指定時も)" \
    "Error: jq is required but was not found in PATH" \
    "$(printf '%s\n' "$stderr_custom" | sed -n '1p')"

  rm -rf "$empty_path_dir"
  trap - EXIT
}

echo ""
echo "=== resolve_repo ==="
{
  gh() {
    if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
      echo '{"owner":{"login":"masanami"},"name":"claude-harness"}'
      return 0
    fi
    return 1
  }

  REPO_OWNER=""
  REPO_NAME=""
  resolve_repo
  rc=$?
  assert_eq "resolve_repo成功時は0を返す" "0" "$rc"
  assert_eq "resolve_repo成功時はREPO_OWNERを設定する" "masanami" "$REPO_OWNER"
  assert_eq "resolve_repo成功時はREPO_NAMEを設定する" "claude-harness" "$REPO_NAME"

  gh() { return 1; }
  REPO_OWNER=""
  REPO_NAME=""
  resolve_repo >/dev/null 2>&1
  assert_eq "gh repo view失敗時は非0を返す" "1" "$?"

  unset -f gh
}

echo ""
echo "=== fetch_pr_checks ==="
{
  gh() {
    if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
      echo '[{"name":"build","state":"SUCCESS","bucket":"pass","description":"","workflow":"CI","link":"l"}]'
      return 0
    fi
    return 1
  }
  result="$(fetch_pr_checks 42)"
  assert_eq "gh成功時はそのままJSON配列を返す" \
    '[{"name":"build","state":"SUCCESS","bucket":"pass","description":"","workflow":"CI","link":"l"}]' \
    "$result"

  gh() { echo "boom" >&2; return 1; }
  result_fail="$(fetch_pr_checks 42 2>/dev/null)"
  rc_fail=0
  fetch_pr_checks 42 >/dev/null 2>&1 || rc_fail=$?
  assert_eq "取得失敗時は stdout を空にする(0件の[]と区別)" "" "$result_fail"
  assert_eq "取得失敗時は exit 1" "1" "$rc_fail"

  gh() { echo '[]'; return 0; }
  assert_eq "成功した0件は[]を返す" "[]" "$(fetch_pr_checks 42)"
  rc_zero=0
  fetch_pr_checks 42 >/dev/null || rc_zero=$?
  assert_eq "成功した0件は exit 0" "0" "$rc_zero"

  gh() { echo "no checks reported on the 'x' branch" >&2; return 1; }
  assert_eq "gh の no checks reported は0件として[]を返す" "[]" "$(fetch_pr_checks 42 2>/dev/null)"
  rc_nc=0
  fetch_pr_checks 42 >/dev/null 2>&1 || rc_nc=$?
  assert_eq "no checks reported は exit 0" "0" "$rc_nc"

  gh() { echo ""; return 1; }
  stderr_no_warn="$(fetch_pr_checks 42 2>&1 1>/dev/null)"
  assert_eq "取得失敗時はwarn_on_empty省略でもWarningをstderrに出す" \
    "Warning: failed to fetch CI checks for PR #42" "$stderr_no_warn"

  gh() { echo '[]'; return 0; }
  assert_eq "warn_on_empty省略時、0件はWarningを出さない" "" "$(fetch_pr_checks 42 2>&1 1>/dev/null)"
  assert_eq "warn_on_empty=1指定時、0件はWarningを出す" \
    "Warning: no CI checks reported for PR #42" "$(fetch_pr_checks 42 1 2>&1 1>/dev/null)"

  # exit code非依存の設計意図を固定する回帰テスト。gh pr checks は CI が pending/fail の
  # 場合に非0 exitを返す仕様のため、fetch_pr_checks は exit code を見ず「出力の非空性 +
  # jq -e 'type == "array"'」のみで採否を判定する設計になっている（scripts/lib/common.sh
  # 内コメント参照）。exit code 判定へ書き換える退行を検出できるよう、
  # 「非0 exitでも有効な配列は採用する」ケースと「rc=0でも非配列出力は棄却する」ケースの
  # 両方を検証する。
  gh() { echo '[{"bucket":"fail"}]'; return 1; }
  result_nonzero_valid="$(fetch_pr_checks 42)"
  assert_eq "非0 exitでも有効なJSON配列ならそのまま返す(exit code非依存)" \
    '[{"bucket":"fail"}]' \
    "$result_nonzero_valid"

  gh() { echo 'not json'; return 0; }
  result_zero_invalid="$(fetch_pr_checks 42)"
  assert_eq "rc=0でも非JSON配列出力なら取得失敗(stdout空・jq判定が主体)" \
    "" \
    "$result_zero_invalid"
  rc_zero_invalid=0
  fetch_pr_checks 42 >/dev/null 2>&1 || rc_zero_invalid=$?
  assert_eq "rc=0でも非JSON配列出力なら exit 1" "1" "$rc_zero_invalid"

  unset -f gh
}

echo ""
echo "=== JQ_FAIL_CANCEL_PREDICATE ==="
{
  assert_eq "述語文字列が期待値と一致する" \
    '.bucket == "fail" or .bucket == "cancel"' \
    "$JQ_FAIL_CANCEL_PREDICATE"

  checks_with_fail='[{"bucket":"pass"},{"bucket":"fail"}]'
  any_result="$(jq -e "any(.[]; ${JQ_FAIL_CANCEL_PREDICATE})" <<<"$checks_with_fail" >/dev/null 2>&1; echo $?)"
  assert_eq "any(...)形式で組み込んでfail検出できる" "0" "$any_result"

  checks_all_pass='[{"bucket":"pass"},{"bucket":"skipping"}]'
  any_result2="$(jq -e "any(.[]; ${JQ_FAIL_CANCEL_PREDICATE})" <<<"$checks_all_pass" >/dev/null 2>&1; echo $?)"
  assert_eq "fail/cancel無しではany(...)は非0" "1" "$any_result2"

  checks_with_cancel='[{"bucket":"cancel"}]'
  select_result="$(jq -c "[.[] | select(${JQ_FAIL_CANCEL_PREDICATE})]" <<<"$checks_with_cancel")"
  assert_eq "select(...)形式で組み込んでcancelを抽出できる" '[{"bucket":"cancel"}]' "$select_result"
}

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
