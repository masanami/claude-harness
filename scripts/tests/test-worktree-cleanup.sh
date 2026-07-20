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
echo "=== worktreeロック（resolve_worktree_lock_dir/acquire_worktree_lock/release_worktree_lock） ==="
{
  WT_LOCK="${TMP_ROOT}/wt-lock"
  git -C "$REPO_DIR" worktree add -q "$WT_LOCK" -b feature/issue-9-lock main >/dev/null 2>&1

  lock_dir_from_main="$(resolve_worktree_lock_dir "$REPO_DIR")"
  lock_dir_from_worktree="$(resolve_worktree_lock_dir "$WT_LOCK")"
  assert_eq "resolve_worktree_lock_dir: mainリポジトリとworktreeから同一ロックパスに解決される（worktree-setup.shと同じロックを取り合う契約の裏付け）" "$lock_dir_from_main" "$lock_dir_from_worktree"
  assert_eq "resolve_worktree_lock_dir: 固定ロック名で終わる" "claude-harness-worktree-ops.lock" "$(basename "$lock_dir_from_main")"

  acquire_worktree_lock "$lock_dir_from_worktree" >/dev/null 2>&1
  acquire_rc=$?
  assert_eq "acquire_worktree_lock: 未取得なら成功(0)を返す" "0" "$acquire_rc"
  assert_eq "acquire_worktree_lock: ロックディレクトリが作成される" "true" "$([ -d "$lock_dir_from_worktree" ] && echo true || echo false)"

  release_worktree_lock "$lock_dir_from_worktree"
  assert_eq "release_worktree_lock: ロックディレクトリが削除される" "false" "$([ -d "$lock_dir_from_worktree" ] && echo true || echo false)"

  # --- staleロックは奪取される ---
  mkdir "$lock_dir_from_worktree"
  echo "1" >"${lock_dir_from_worktree}/acquired_at" # epoch=1（大昔）なので確実にstale
  WORKTREE_LOCK_STALE_SECONDS=1
  WORKTREE_LOCK_WAIT_SECONDS=10
  acquire_worktree_lock "$lock_dir_from_worktree" >/dev/null 2>&1
  stale_rc=$?
  assert_eq "acquire_worktree_lock: staleロックは奪取して成功(0)する" "0" "$stale_rc"
  release_worktree_lock "$lock_dir_from_worktree"
  # 既定値へ復元（以降の main() テストに影響させないため）。shellcheckのsource境界を
  # 跨いだ使用追跡の限界によるfalse positiveのため無効化する。
  # shellcheck disable=SC2034
  WORKTREE_LOCK_STALE_SECONDS=120
  # shellcheck disable=SC2034
  WORKTREE_LOCK_WAIT_SECONDS=60

  git -C "$REPO_DIR" worktree remove --force "$WT_LOCK" >/dev/null 2>&1
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
