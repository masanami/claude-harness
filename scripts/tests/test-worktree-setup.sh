#!/bin/bash
# test-worktree-setup.sh
# scripts/worktree-setup.sh の純粋関数（validate_branch_name/compute_worktree_path/
# default_worktree_root）と、実際の git worktree 操作（新規作成・冪等再利用・
# 別ブランチ登録済みの衝突検知・既存ブランチへのworktree作成）を、bare remote付きの
# 一時gitリポジトリで検証する。
#
# 実行方法: bash scripts/tests/test-worktree-setup.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../worktree-setup.sh"

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

echo "=== validate_branch_name ==="
{
  assert_eq "正しい形式(feature)は valid" "valid" "$(validate_branch_name 45 "feature/issue-45-add-x")"
  assert_eq "正しい形式(fix、複数ハイフン説明)は valid" "valid" "$(validate_branch_name 7 "fix/issue-7-login-error-fix")"
  assert_eq "typeが規約外は invalid" "invalid" "$(validate_branch_name 45 "wip/issue-45-add-x")"
  assert_eq "issue番号が不一致は invalid" "invalid" "$(validate_branch_name 45 "feature/issue-99-add-x")"
  assert_eq "説明部分が無いのは invalid" "invalid" "$(validate_branch_name 45 "feature/issue-45-")"
  assert_eq "大文字を含むのは invalid(ケバブケースのみ許容)" "invalid" "$(validate_branch_name 45 "feature/issue-45-AddX")"
}

echo ""
echo "=== compute_worktree_path / default_worktree_root ==="
{
  assert_eq "compute_worktree_path: root/issue-N を組み立てる" "/tmp/wt/issue-45" "$(compute_worktree_path "/tmp/wt" 45)"
  assert_eq "compute_worktree_path: 末尾スラッシュは正規化される" "/tmp/wt/issue-45" "$(compute_worktree_path "/tmp/wt/" 45)"
  assert_eq "default_worktree_root: リポジトリ名-worktrees を1つ上の階層に組み立てる" "/tmp/foo-worktrees" "$(default_worktree_root "/tmp/foo")"
}

echo ""
echo "=== worktreeロック（resolve_worktree_lock_dir/acquire_worktree_lock/release_worktree_lock） ==="
{
  LOCK_TMP_ROOT="$(mktemp -d)"
  lock_test_cleanup() { rm -rf "$LOCK_TMP_ROOT"; }
  trap lock_test_cleanup EXIT

  LOCK_REPO_DIR="${LOCK_TMP_ROOT}/repo"
  mkdir -p "$LOCK_REPO_DIR"
  (
    cd "$LOCK_REPO_DIR" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "hello" >README.md
    git add README.md
    git commit -q -m "initial commit"
  )

  lock_dir="$(resolve_worktree_lock_dir "$LOCK_REPO_DIR")"
  # 期待値も pwd -P で物理パスへ正規化してから比較する（LOCK_REPO_DIRの祖先が
  # symlink経由の可能性がある。macOSの/tmp -> /private/tmp・/var -> /private/var等。
  # resolve_worktree_lock_dir 自身がpwd -Pで正規化する実装のため、期待値側も
  # 同じ基準に揃えないと環境依存で偽陰性になる）。
  lock_repo_dir_physical="$(cd "$LOCK_REPO_DIR" && pwd -P)"
  assert_eq "resolve_worktree_lock_dir: 固定ロック名で終わる" "claude-harness-worktree-ops.lock" "$(basename "$lock_dir")"
  assert_eq "resolve_worktree_lock_dir: git-common-dir配下(絶対パス)を指す" "true" "$([ "$lock_dir" = "${lock_repo_dir_physical}/.git/claude-harness-worktree-ops.lock" ] && echo true || echo false)"

  # --- 取得・解放 ---
  acquire_worktree_lock "$lock_dir" >/dev/null 2>&1
  acquire_rc=$?
  assert_eq "acquire_worktree_lock: 未取得なら成功(0)を返す" "0" "$acquire_rc"
  assert_eq "acquire_worktree_lock: ロックディレクトリが作成される" "true" "$([ -d "$lock_dir" ] && echo true || echo false)"
  assert_eq "acquire_worktree_lock: pidファイルが書き込まれる" "true" "$([ -s "${lock_dir}/pid" ] && echo true || echo false)"
  assert_eq "acquire_worktree_lock: acquired_atファイルが書き込まれる" "true" "$([ -s "${lock_dir}/acquired_at" ] && echo true || echo false)"

  release_worktree_lock "$lock_dir"
  assert_eq "release_worktree_lock: ロックディレクトリが削除される" "false" "$([ -d "$lock_dir" ] && echo true || echo false)"

  # --- 保持中（stale未満）は待機の上タイムアウトする（WAIT_SECONDSをテスト用に短縮） ---
  mkdir "$lock_dir"
  date +%s >"${lock_dir}/acquired_at"
  WORKTREE_LOCK_WAIT_SECONDS=2
  WORKTREE_LOCK_STALE_SECONDS=120
  start_ts="$(date +%s)"
  acquire_worktree_lock "$lock_dir" >/dev/null 2>&1
  timeout_rc=$?
  end_ts="$(date +%s)"
  assert_eq "acquire_worktree_lock: 保持中(non-stale)はタイムアウトで1を返す" "1" "$timeout_rc"
  assert_eq "acquire_worktree_lock: WORKTREE_LOCK_WAIT_SECONDS相当まで待ってから諦める" "true" "$([ $((end_ts - start_ts)) -ge 2 ] && echo true || echo false)"
  rm -rf "$lock_dir"

  # --- staleロック（acquired_atが古い）は奪取して取得できる ---
  mkdir "$lock_dir"
  echo "99999999" >"${lock_dir}/pid"
  echo "1" >"${lock_dir}/acquired_at" # epoch=1（大昔）なので確実にstale
  WORKTREE_LOCK_STALE_SECONDS=1
  WORKTREE_LOCK_WAIT_SECONDS=10
  acquire_worktree_lock "$lock_dir" >/dev/null 2>&1
  stale_rc=$?
  assert_eq "acquire_worktree_lock: staleロックは奪取して成功(0)する" "0" "$stale_rc"
  assert_eq "acquire_worktree_lock: 奪取後は新しいacquired_atで上書きされる" "true" "$([ -s "${lock_dir}/acquired_at" ] && echo true || echo false)"
  release_worktree_lock "$lock_dir"

  # 既定値へ復元（以降の main() テストに影響させないため）。ここでの代入自体は
  # このスコープ内で読まれないが、この後 main() 経由で worktree-setup.sh 側の
  # acquire_worktree_lock が参照するグローバル変数のため必要（shellcheckの
  # source境界を跨いだ使用追跡の限界によるfalse positive）。
  # shellcheck disable=SC2034
  WORKTREE_LOCK_STALE_SECONDS=120
  # shellcheck disable=SC2034
  WORKTREE_LOCK_WAIT_SECONDS=60

  lock_test_cleanup
  trap - EXIT
}

echo ""
echo "=== main(): 実際のgit worktree操作(一時リポジトリ) ==="
{
  TMP_ROOT="$(mktemp -d)"
  cleanup() { rm -rf "$TMP_ROOT"; }
  trap cleanup EXIT

  ORIGIN_DIR="${TMP_ROOT}/origin.git"
  REPO_DIR="${TMP_ROOT}/repo"
  WORKTREE_ROOT="${TMP_ROOT}/worktrees"

  git init -q --bare "$ORIGIN_DIR"

  git clone -q "$ORIGIN_DIR" "$REPO_DIR"
  (
    cd "$REPO_DIR" || exit 1
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "hello" >README.md
    git add README.md
    git commit -q -m "initial commit"
    git branch -M main
    git push -q -u origin main
  )

  # --- 新規作成 ---
  output="$(cd "$REPO_DIR" && main 45 "feature/issue-45-add-x" main "$WORKTREE_ROOT")"
  assert_eq "新規作成: created=true" "true" "$(jq -r '.created' <<<"$output")"
  assert_eq "新規作成: reused=false" "false" "$(jq -r '.reused' <<<"$output")"
  assert_eq "新規作成: branch_existed=false" "false" "$(jq -r '.branch_existed' <<<"$output")"
  assert_eq "新規作成: worktree_pathが実在ディレクトリになる" "true" "$([ -d "${WORKTREE_ROOT}/issue-45" ] && echo true || echo false)"
  assert_eq "新規作成: worktree内で対象ブランチがcheckoutされている" "feature/issue-45-add-x" "$(git -C "${WORKTREE_ROOT}/issue-45" branch --show-current)"

  # --- 冪等再利用（同一ブランチで再実行） ---
  output2="$(cd "$REPO_DIR" && main 45 "feature/issue-45-add-x" main "$WORKTREE_ROOT")"
  assert_eq "再実行(同一ブランチ): created=false" "false" "$(jq -r '.created' <<<"$output2")"
  assert_eq "再実行(同一ブランチ): reused=true" "true" "$(jq -r '.reused' <<<"$output2")"

  # --- 冪等再利用（worktree_rootパスに空白を含む場合。self-review指摘の回帰テスト:
  #     旧実装は find_registered_worktree_branch が awk の $2（空白区切り）で worktree
  #     パスを取得しており、空白を含むパスで先頭トークンしか取得できず「未登録」と
  #     誤判定して stale directory エラーになっていた） ---
  WORKTREE_ROOT_WITH_SPACE="${TMP_ROOT}/work trees"
  output_space1="$(cd "$REPO_DIR" && main 48 "feature/issue-48-space-path" main "$WORKTREE_ROOT_WITH_SPACE")"
  assert_eq "空白を含むworktree_root: 新規作成できる" "true" "$(jq -r '.created' <<<"$output_space1")"
  output_space2="$(cd "$REPO_DIR" && main 48 "feature/issue-48-space-path" main "$WORKTREE_ROOT_WITH_SPACE")"
  assert_eq "空白を含むworktree_root: 再実行で冪等に再利用される(reused=true)" "true" "$(jq -r '.reused' <<<"$output_space2")"
  assert_eq "空白を含むworktree_root: 再実行はstale directoryエラーにならない(created=false)" "false" "$(jq -r '.created' <<<"$output_space2")"

  # --- 別ブランチでの衝突検知 ---
  conflict_stderr="$(cd "$REPO_DIR" && main 45 "fix/issue-45-other-desc" main "$WORKTREE_ROOT" 2>&1 1>/dev/null)"
  conflict_exit=$?
  assert_eq "別ブランチでの再実行: 非0 exitで拒否される" "1" "$conflict_exit"
  assert_eq "別ブランチでの再実行: エラーメッセージに衝突の説明が含まれる" "true" "$(echo "$conflict_stderr" | grep -q "already registered for a different branch" && echo true || echo false)"

  # --- base が remote に存在しない場合 ---
  no_base_stderr="$(cd "$REPO_DIR" && main 46 "feature/issue-46-y" nonexistent-base "$WORKTREE_ROOT" 2>&1 1>/dev/null)"
  no_base_exit=$?
  assert_eq "存在しないbase: 非0 exit" "1" "$no_base_exit"
  assert_eq "存在しないbase: エラーメッセージにbase名を含む" "true" "$(echo "$no_base_stderr" | grep -q "nonexistent-base" && echo true || echo false)"

  # --- 既存ローカルブランチがある場合の冪等作成（worktreeは未登録・ブランチのみ存在） ---
  (
    cd "$REPO_DIR" || exit 1
    git branch "feature/issue-47-existing-branch" main
  )
  output3="$(cd "$REPO_DIR" && main 47 "feature/issue-47-existing-branch" main "$WORKTREE_ROOT")"
  assert_eq "既存ローカルブランチ: created=true(worktreeとしては新規)" "true" "$(jq -r '.created' <<<"$output3")"
  assert_eq "既存ローカルブランチ: branch_existed=true" "true" "$(jq -r '.branch_existed' <<<"$output3")"
  assert_eq "既存ローカルブランチ: 想定ブランチがcheckoutされる" "feature/issue-47-existing-branch" "$(git -C "${WORKTREE_ROOT}/issue-47" branch --show-current)"

  cleanup
  trap - EXIT
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
