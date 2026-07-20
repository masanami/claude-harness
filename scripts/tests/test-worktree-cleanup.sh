#!/bin/bash
# test-worktree-cleanup.sh
# scripts/worktree-cleanup.sh の実際の git worktree 削除操作（クリーン時の削除・
# dirty時の既定拒否・--force・--skip-if-dirty）を、一時gitリポジトリ+実際の
# worktree を作成して検証する。
#
# 実行方法: bash scripts/tests/test-worktree-cleanup.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../worktree-cleanup.sh"

# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

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

TMP_ROOT="$(mktemp -d)"
cleanup_all() { rm -rf "$TMP_ROOT"; }
trap cleanup_all EXIT

REPO_DIR="${TMP_ROOT}/repo"
mkdir -p "$REPO_DIR"
(
  cd "$REPO_DIR" || exit 1
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test User"
  echo "hello" >README.md
  git add README.md
  git commit -q -m "initial commit"
)

echo "=== is_dirty ==="
{
  WT_CLEAN="${TMP_ROOT}/wt-clean"
  git -C "$REPO_DIR" worktree add -q "$WT_CLEAN" -b feature/issue-1-clean main >/dev/null 2>&1
  assert_eq "クリーンなworktreeはfalse" "false" "$(is_dirty "$WT_CLEAN")"

  WT_DIRTY="${TMP_ROOT}/wt-dirty"
  git -C "$REPO_DIR" worktree add -q "$WT_DIRTY" -b feature/issue-2-dirty main >/dev/null 2>&1
  echo "modified" >>"${WT_DIRTY}/README.md"
  assert_eq "未コミット変更があるworktreeはtrue" "true" "$(is_dirty "$WT_DIRTY")"
}

echo ""
echo "=== main(): クリーンなworktreeは既定で削除される ==="
{
  output="$(main "$WT_CLEAN")"
  assert_eq "removed=true" "true" "$(jq -r '.removed' <<<"$output")"
  assert_eq "skipped=false" "false" "$(jq -r '.skipped' <<<"$output")"
  assert_eq "dirty=false" "false" "$(jq -r '.dirty' <<<"$output")"
  assert_eq "worktreeディレクトリが実際に削除される" "false" "$([ -d "$WT_CLEAN" ] && echo true || echo false)"
}

echo ""
echo "=== main(): dirtyなworktreeは既定(フラグ無し)で削除を拒否する ==="
{
  set +u
  stderr_out="$(main "$WT_DIRTY" 2>&1 1>/dev/null)"
  exit_code=$?
  set -u
  assert_eq "非0 exitで拒否される" "1" "$exit_code"
  assert_eq "エラーメッセージに理由が含まれる" "true" "$(echo "$stderr_out" | grep -q "uncommitted changes" && echo true || echo false)"
  assert_eq "worktreeは削除されず残る(保護される)" "true" "$([ -d "$WT_DIRTY" ] && echo true || echo false)"
}

echo ""
echo "=== main(): --skip-if-dirty はdirtyなworktreeを削除せず正常終了する ==="
{
  output="$(main "$WT_DIRTY" --skip-if-dirty)"
  assert_eq "removed=false" "false" "$(jq -r '.removed' <<<"$output")"
  assert_eq "skipped=true" "true" "$(jq -r '.skipped' <<<"$output")"
  assert_eq "dirty=true" "true" "$(jq -r '.dirty' <<<"$output")"
  assert_eq "worktreeは削除されず残る" "true" "$([ -d "$WT_DIRTY" ] && echo true || echo false)"
}

echo ""
echo "=== main(): --force はdirtyでも強制削除する ==="
{
  output="$(main "$WT_DIRTY" --force)"
  assert_eq "removed=true" "true" "$(jq -r '.removed' <<<"$output")"
  assert_eq "dirty=true(削除前の状態として記録される)" "true" "$(jq -r '.dirty' <<<"$output")"
  assert_eq "worktreeディレクトリが実際に削除される" "false" "$([ -d "$WT_DIRTY" ] && echo true || echo false)"
}

echo ""
echo "=== main(): 存在しないworktree_pathはエラー ==="
{
  set +u
  stderr_out="$(main "${TMP_ROOT}/does-not-exist" 2>&1 1>/dev/null)"
  exit_code=$?
  set -u
  assert_eq "非0 exit" "1" "$exit_code"
}

echo ""
echo "=== main(): 不明なフラグはエラー ==="
{
  set +u
  stderr_out="$(main "$REPO_DIR" --bogus-flag 2>&1 1>/dev/null)"
  exit_code=$?
  set -u
  assert_eq "非0 exit" "1" "$exit_code"
}

cleanup_all
trap - EXIT

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
