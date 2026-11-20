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
echo "=== resolve_key / 鍵の形（#388 S3-1） ==="
{
  assert_eq "resolve_key: 数字だけは issue-<数字>" "issue-45" "$(resolve_key 45)"
  assert_eq "resolve_key: issue-<n> はそのまま" "issue-45" "$(resolve_key issue-45)"
  assert_eq "resolve_key: task-<n> はそのまま" "task-12" "$(resolve_key task-12)"
  assert_eq "resolve_key: pr-<n> はそのまま" "pr-7" "$(resolve_key pr-7)"
  assert_eq "resolve_key: 未知の接頭辞は空" "" "$(resolve_key foo-1)"
  assert_eq "resolve_key: 数字の無い鍵は空" "" "$(resolve_key task-)"
  assert_eq "resolve_key: T-12 の形は空（鍵は task-12）" "" "$(resolve_key T-12)"
  assert_eq "鍵 task-12 のブランチは valid" "valid" "$(validate_branch_name task-12 "feature/task-12-add-x")"
  assert_eq "鍵 task-12 に issue- のブランチは invalid" "invalid" "$(validate_branch_name task-12 "feature/issue-12-add-x")"
  assert_eq "鍵 issue-45 に task- のブランチは invalid" "invalid" "$(validate_branch_name issue-45 "feature/task-45-add-x")"
  assert_eq "数字だけの呼び方（45）は issue-45 のブランチだけ valid" "valid" "$(validate_branch_name 45 "feature/issue-45-add-x")"
  assert_eq "未知の鍵は invalid" "invalid" "$(validate_branch_name foo-1 "feature/foo-1-add-x")"
  assert_eq "compute_worktree_path: 鍵 task-12 は root/task-12" "/tmp/wt/task-12" "$(compute_worktree_path "/tmp/wt" task-12)"
  assert_eq "compute_worktree_path: 鍵 issue-45 は root/issue-45（数字だけと同じ）" "/tmp/wt/issue-45" "$(compute_worktree_path "/tmp/wt" issue-45)"
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

  # --- remote のブランチ有無は refs/heads/<b> の完全一致で判定する（Issue #271 の回帰テスト:
  #     旧実装は `git ls-remote --exit-code --heads origin <b>` で、ls-remote のパターンが
  #     末尾一致のため feature/<b> のような別ブランチだけが在っても「在る」と誤判定していた） ---
  (
    cd "$REPO_DIR" || exit 1
    git push -q origin "main:refs/heads/feature/integ-271"
    git push -q origin "main:refs/heads/x/feature/issue-52-tail-only"
  )
  assert_eq "remote_branch_exists: 末尾一致の別ブランチ(feature/<b>)だけが在るなら無いと判定する" "false" "$(cd "$REPO_DIR" && remote_branch_exists "integ-271" && echo true || echo false)"
  assert_eq "verify_base_remote: 末尾一致の別ブランチ(feature/<b>)だけが在るなら無いと判定する" "false" "$(cd "$REPO_DIR" && verify_base_remote "integ-271" && echo true || echo false)"
  tail_base_stderr="$(cd "$REPO_DIR" && main 49 "feature/issue-49-tail-base" "integ-271" "$WORKTREE_ROOT" 2>&1 1>/dev/null)"
  tail_base_exit=$?
  assert_eq "末尾一致の別ブランチだけが在るbase: 非0 exit" "1" "$tail_base_exit"
  assert_eq "末尾一致の別ブランチだけが在るbase: 存在しないbaseのエラーになる" "true" "$(echo "$tail_base_stderr" | grep -q "base branch 'integ-271' does not exist on remote" && echo true || echo false)"

  output_tail_branch="$(cd "$REPO_DIR" && main 52 "feature/issue-52-tail-only" main "$WORKTREE_ROOT")"
  assert_eq "末尾一致の別ブランチだけがremoteに在る作業ブランチ: 既存扱いせず新規作成する(branch_existed=false)" "false" "$(jq -r '.branch_existed' <<<"$output_tail_branch")"

  # 完全一致のブランチが在れば「在る」と判定する既存挙動は保つ
  (
    cd "$REPO_DIR" || exit 1
    git push -q origin "main:refs/heads/integ-271"
    git push -q origin "main:refs/heads/feature/issue-51-remote-only"
  )
  assert_eq "remote_branch_exists: 完全一致のブランチが在れば在ると判定する" "true" "$(cd "$REPO_DIR" && remote_branch_exists "integ-271" && echo true || echo false)"
  output_exact_base="$(cd "$REPO_DIR" && main 49 "feature/issue-49-tail-base" "integ-271" "$WORKTREE_ROOT")"
  assert_eq "完全一致のbaseが在る: worktreeを新規作成できる" "true" "$(jq -r '.created' <<<"$output_exact_base")"
  output_remote_branch="$(cd "$REPO_DIR" && main 51 "feature/issue-51-remote-only" main "$WORKTREE_ROOT")"
  assert_eq "remoteにだけ在る作業ブランチ: 既存扱いする(branch_existed=true)" "true" "$(jq -r '.branch_existed' <<<"$output_remote_branch")"

  # --- 既存ローカルブランチがある場合の冪等作成（worktreeは未登録・ブランチのみ存在） ---
  (
    cd "$REPO_DIR" || exit 1
    git branch "feature/issue-47-existing-branch" main
  )
  output3="$(cd "$REPO_DIR" && main 47 "feature/issue-47-existing-branch" main "$WORKTREE_ROOT")"
  assert_eq "既存ローカルブランチ: created=true(worktreeとしては新規)" "true" "$(jq -r '.created' <<<"$output3")"
  assert_eq "既存ローカルブランチ: branch_existed=true" "true" "$(jq -r '.branch_existed' <<<"$output3")"
  assert_eq "既存ローカルブランチ: 想定ブランチがcheckoutされる" "feature/issue-47-existing-branch" "$(git -C "${WORKTREE_ROOT}/issue-47" branch --show-current)"

  # --- 数字だけの呼び方は鍵 issue-<数字> と同じ出力（#388 S3-1）。key を足し、issue は数 ---
  assert_eq "数字だけの呼び方: key は issue-45" "issue-45" "$(jq -r '.key' <<<"$output")"
  assert_eq "数字だけの呼び方: issue は数 45" "45" "$(jq -r '.issue' <<<"$output")"
  output_key_issue="$(cd "$REPO_DIR" && main issue-45 "feature/issue-45-add-x" main "$WORKTREE_ROOT")"
  assert_eq "鍵 issue-45 は数字だけの呼び方と同じ場所を再利用する(reused=true)" "true" "$(jq -r '.reused' <<<"$output_key_issue")"
  assert_eq "鍵 issue-45: worktree_path は数字だけの呼び方と同じ" "$(jq -r '.worktree_path' <<<"$output")" "$(jq -r '.worktree_path' <<<"$output_key_issue")"

  # --- 鍵 task-<n>: 場所は <root>/task-<n>、ブランチは {type}/task-<n>-{説明}、issue は null ---
  output_task="$(cd "$REPO_DIR" && main task-12 "feature/task-12-add-y" main "$WORKTREE_ROOT")"
  assert_eq "鍵 task-12: created=true" "true" "$(jq -r '.created' <<<"$output_task")"
  assert_eq "鍵 task-12: key は task-12" "task-12" "$(jq -r '.key' <<<"$output_task")"
  assert_eq "鍵 task-12: issue は null" "null" "$(jq -r '.issue' <<<"$output_task")"
  assert_eq "鍵 task-12: worktree は <root>/task-12" "true" "$([ -d "${WORKTREE_ROOT}/task-12" ] && echo true || echo false)"
  assert_eq "鍵 task-12: 作業ブランチがcheckoutされている" "feature/task-12-add-y" "$(git -C "${WORKTREE_ROOT}/task-12" branch --show-current)"
  # 同じ Issue 番号でも task の鍵が違えば、別の作業ツリーとブランチになる
  output_task2="$(cd "$REPO_DIR" && main task-13 "feature/task-13-add-z" main "$WORKTREE_ROOT")"
  assert_eq "鍵 task-13: 別の作業ツリー" "${WORKTREE_ROOT}/task-13" "$(jq -r '.worktree_path' <<<"$output_task2" | sed "s#^$(cd "$WORKTREE_ROOT" && pwd -P)#${WORKTREE_ROOT}#")"
  # 鍵とブランチの名前が合わなければ拒否する
  mismatch_stderr="$(cd "$REPO_DIR" && main task-12 "feature/issue-12-add-y" main "$WORKTREE_ROOT" 2>&1 1>/dev/null)"
  mismatch_exit=$?
  assert_eq "鍵とブランチの名前の不一致: 非0 exit" "1" "$mismatch_exit"
  assert_eq "鍵とブランチの名前の不一致: 期待する形（task-12）を示す" "true" "$(echo "$mismatch_stderr" | grep -q "{type}/task-12-{description}" && echo true || echo false)"
  # 鍵の形でない第 1 引数は拒否する
  bad_key_stderr="$(cd "$REPO_DIR" && main foo-1 "feature/foo-1-x" main "$WORKTREE_ROOT" 2>&1 1>/dev/null)"
  bad_key_exit=$?
  assert_eq "鍵の形でない第1引数: 非0 exit" "1" "$bad_key_exit"
  assert_eq "鍵の形でない第1引数: 説明を出す" "true" "$(echo "$bad_key_stderr" | grep -q "issue number (digits only) or a key" && echo true || echo false)"
  # 別ブランチで登録済みの鍵の場所は、いまと同じく衝突で止まる（相乗りしない）
  task_conflict_stderr="$(cd "$REPO_DIR" && main task-12 "fix/task-12-other" main "$WORKTREE_ROOT" 2>&1 1>/dev/null)"
  task_conflict_exit=$?
  assert_eq "鍵 task-12 が別ブランチで登録済み: 非0 exit" "1" "$task_conflict_exit"
  assert_eq "鍵 task-12 が別ブランチで登録済み: 衝突の説明" "true" "$(echo "$task_conflict_stderr" | grep -q "already registered for a different branch" && echo true || echo false)"

  # --- --detach: 既に origin にあるブランチを、checkout しない形で作る（#388 S3-6。名前の形を検査しない）。
  #     ブランチが別の作業ツリー（issue-45）で checkout されたままでも作れる ---
  (cd "$REPO_DIR" && git push -q origin "feature/issue-45-add-x")
  output_detach="$(cd "$REPO_DIR" && main --detach pr-7 "feature/issue-45-add-x" main "$WORKTREE_ROOT")"
  assert_eq "--detach: created=true" "true" "$(jq -r '.created' <<<"$output_detach")"
  assert_eq "--detach: key は pr-7" "pr-7" "$(jq -r '.key' <<<"$output_detach")"
  assert_eq "--detach: issue は null" "null" "$(jq -r '.issue' <<<"$output_detach")"
  assert_eq "--detach: branch は渡したブランチ" "feature/issue-45-add-x" "$(jq -r '.branch' <<<"$output_detach")"
  assert_eq "--detach: detached=true" "true" "$(jq -r '.detached' <<<"$output_detach")"
  assert_eq "--detach: 作業ツリーはブランチを checkout していない" "" "$(git -C "${WORKTREE_ROOT}/pr-7" branch --show-current)"
  assert_eq "--detach: HEAD は origin のブランチの先頭" "$(git -C "$REPO_DIR" rev-parse origin/feature/issue-45-add-x)" "$(git -C "${WORKTREE_ROOT}/pr-7" rev-parse HEAD)"
  output_detach2="$(cd "$REPO_DIR" && main --detach pr-7 "feature/issue-45-add-x" main "$WORKTREE_ROOT")"
  assert_eq "--detach 再実行: reused=true" "true" "$(jq -r '.reused' <<<"$output_detach2")"
  assert_eq "--detach 再実行: created=false" "false" "$(jq -r '.created' <<<"$output_detach2")"
  # 名前の形（{type}/<鍵>-…）を検査しない
  (cd "$REPO_DIR" && git push -q origin "main:refs/heads/some-free-name")
  output_detach_free="$(cd "$REPO_DIR" && main --detach pr-8 "some-free-name" main "$WORKTREE_ROOT")"
  assert_eq "--detach: 名前の形を検査しない" "true" "$(jq -r '.created' <<<"$output_detach_free")"
  # ブランチが origin に無ければ失敗する
  detach_missing_stderr="$(cd "$REPO_DIR" && main --detach pr-9 "no-such-branch" main "$WORKTREE_ROOT" 2>&1 1>/dev/null)"
  detach_missing_exit=$?
  assert_eq "--detach: ブランチが origin に無い: 非0 exit" "1" "$detach_missing_exit"
  assert_eq "--detach: ブランチが origin に無い: 説明" "true" "$(echo "$detach_missing_stderr" | grep -q "branch 'no-such-branch' does not exist on remote" && echo true || echo false)"
  assert_eq "--detach: ブランチが origin に無い: 作業ツリーを作らない" "false" "$([ -e "${WORKTREE_ROOT}/pr-9" ] && echo true || echo false)"
  # ブランチを checkout した登録済みの場所は、衝突で止まる（相乗りしない）
  (cd "$REPO_DIR" && git push -q origin "feature/task-12-add-y")
  detach_clash_stderr="$(cd "$REPO_DIR" && main --detach task-12 "feature/task-12-add-y" main "$WORKTREE_ROOT" 2>&1 1>/dev/null)"
  detach_clash_exit=$?
  assert_eq "--detach: ブランチを checkout 済みの場所: 非0 exit" "1" "$detach_clash_exit"
  assert_eq "--detach: ブランチを checkout 済みの場所: 衝突の説明" "true" "$(echo "$detach_clash_stderr" | grep -q "already registered for a different branch" && echo true || echo false)"

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
