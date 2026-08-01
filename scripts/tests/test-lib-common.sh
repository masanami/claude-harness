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

  gh() { echo ""; return 1; }
  result_empty="$(fetch_pr_checks 42)"
  assert_eq "gh失敗/空出力時は空配列を返す" "[]" "$result_empty"

  stderr_no_warn="$(gh() { echo ""; return 1; }; fetch_pr_checks 42 2>&1 1>/dev/null)"
  assert_eq "warn_on_empty省略時はWarningを出さない(ci-wait.sh互換)" "" "$stderr_no_warn"

  stderr_warn="$(gh() { echo ""; return 1; }; fetch_pr_checks 42 1 2>&1 1>/dev/null)"
  assert_eq "warn_on_empty=1指定時はWarningをstderrに出す(pr-merge-preflight.sh互換)" \
    "Warning: no CI checks data available for PR #42 (no checks configured, or fetch failed)" \
    "$stderr_warn"

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
