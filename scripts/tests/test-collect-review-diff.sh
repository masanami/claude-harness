#!/bin/bash
# test-collect-review-diff.sh
# scripts/collect-review-diff.sh の純粋関数（compute_merge_base/collect_commits/
# collect_files/write_diff_file 等）と main() 経由の統合動作を、一時gitリポジトリを
# 作成して検証する。gh を呼ぶ resolve_base のみ、BASE を明示指定することでスキップする
# （CI/サンドボックス環境で gh 認証なしに実行できるようにするため）。
#
# 実行方法: bash scripts/tests/test-collect-review-diff.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../collect-review-diff.sh"

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

assert_contains_json_array() {
  local description="$1" json_array="$2" needle="$3"
  if jq -e --arg n "$needle" 'index($n) != null' <<<"$json_array" >/dev/null 2>&1; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected array to contain: ${needle}"
    echo "       actual: ${json_array}"
  fi
}

# --- 一時gitリポジトリのセットアップ ---
# main ブランチに初期コミット -> feature ブランチへ分岐 -> tracked変更 + untracked新規ファイル。
REPO_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$REPO_DIR"
}
trap cleanup EXIT

(
  cd "$REPO_DIR" || exit 1
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test User"
  echo "line1" >tracked.txt
  git add tracked.txt
  git commit -q -m "initial commit"

  git checkout -q -b feature/test-branch
  {
    echo "line1"
    echo "line2 modified"
  } >tracked.txt
  git add tracked.txt
  git commit -q -m "modify tracked file"

  # 作業ツリー側にさらに未コミットの変更（tracked）と、未追跡の新規ファイルを作る
  {
    echo "line1"
    echo "line2 modified"
    echo "line3 uncommitted"
  } >tracked.txt
  echo "brand new content" >untracked-new-file.txt
)

cd "$REPO_DIR" || exit 1

echo "=== test: resolve_base — override指定時はghを呼ばずそのまま採用する ==="
resolve_base "main"
assert_eq "overrideがそのままRESOLVED_BASEになる" "main" "$RESOLVED_BASE"

echo "=== test: resolve_base_ref — originが無い場合はローカルブランチにフォールバックする ==="
resolve_base_ref "main"
assert_eq "origin/mainが無いのでローカルmainにフォールバック" "main" "$BASE_REF"

echo "=== test: resolve_base_ref — 存在しないbase名はexit非0相当（戻り値1） ==="
resolve_base_ref "no-such-branch-xyz" 2>/dev/null
RESOLVE_REF_FAIL_STATUS=$?
assert_eq "戻り値が非0" "1" "$RESOLVE_REF_FAIL_STATUS"

echo "=== test: resolve_base_ref — '-'始まりのbaseはgitに渡さず拒否する（オプション注入対策の回帰テスト） ==="
resolve_base_ref "--upload-pack=touch /tmp/pwned" 2>/dev/null
RESOLVE_REF_DASH_STATUS=$?
assert_eq "戻り値が非0" "1" "$RESOLVE_REF_DASH_STATUS"

echo "=== test: compute_merge_base — mainとfeatureブランチのmerge-baseがmainの先頭になる ==="
MAIN_HEAD_SHA="$(git rev-parse main)"
compute_merge_base "main"
assert_eq "merge-baseはmainのHEAD" "$MAIN_HEAD_SHA" "$MERGE_BASE"

echo "=== test: collect_commits — feature側の1コミットのみが列挙される ==="
collect_commits "main"
assert_eq "1件のコミット" "1" "$(jq 'length' <<<"$COMMITS_JSON")"

echo "=== test: collect_files — merge_base基準でtracked変更ファイルが含まれる（未追跡は含まれない） ==="
collect_files "$MAIN_HEAD_SHA"
assert_contains_json_array "tracked.txtが含まれる" "$FILES_JSON" "tracked.txt"
# stage_untracked_as_intent_to_add を呼ぶ前なので、この時点ではuntracked新規ファイルは含まれないはず
if jq -e --arg n "untracked-new-file.txt" 'index($n) != null' <<<"$FILES_JSON" >/dev/null 2>&1; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("intent-to-add前はuntrackedファイルがfilesに含まれないこと")
  echo "  NG - intent-to-add前はuntrackedファイルがfilesに含まれないこと"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - intent-to-add前はuntrackedファイルがfilesに含まれないこと"
fi

echo "=== test: stage_untracked_as_intent_to_add + collect_files — untracked新規ファイルが検出されるようになる（回帰テスト） ==="
stage_untracked_as_intent_to_add
collect_files "$MAIN_HEAD_SHA"
assert_contains_json_array "intent-to-add後はuntracked-new-file.txtがfilesに含まれる" "$FILES_JSON" "untracked-new-file.txt"

echo "=== test: stage_untracked_as_intent_to_add — git add失敗時は戻り値1を伝播する（回帰テスト。CodeRabbit指摘: 従来は握りつぶして常にreturn 0していた） ==="
NON_REPO_DIR="$(mktemp -d)"
(
  cd "$NON_REPO_DIR" || exit 1
  stage_untracked_as_intent_to_add 2>/dev/null
)
STAGE_FAIL_STATUS=$?
assert_eq "gitリポジトリ外ではgit add --intent-to-add -Aが失敗し戻り値1が伝播する" "1" "$STAGE_FAIL_STATUS"
rm -rf "$NON_REPO_DIR"

echo "=== test: write_diff_file — 未コミットの作業ツリー変更 + untracked新規ファイルの両方がdiff本文に含まれる（回帰テスト） ==="
write_diff_file "$MAIN_HEAD_SHA"
assert_eq "diff_fileが生成される" "0" "$([ -f "$DIFF_FILE" ] && echo 0 || echo 1)"
DIFF_CONTENT="$(cat "$DIFF_FILE")"
if [[ "$DIFF_CONTENT" == *"line3 uncommitted"* ]]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 未コミットの作業ツリー変更がdiffに含まれる"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("未コミットの作業ツリー変更がdiffに含まれる")
  echo "  NG - 未コミットの作業ツリー変更がdiffに含まれる"
fi
if [[ "$DIFF_CONTENT" == *"brand new content"* ]]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - untracked新規ファイルの内容がdiffに含まれる（回帰テスト本体）"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("untracked新規ファイルの内容がdiffに含まれる（回帰テスト本体）")
  echo "  NG - untracked新規ファイルの内容がdiffに含まれる（回帰テスト本体）"
fi
rm -f "$DIFF_FILE"

echo "=== test: CLIレベル（main()） — BASE明示指定でghを呼ばずJSON1個を出力する ==="
CLI_OUTPUT=$("$TARGET_SCRIPT" "main")
CLI_EXIT=$?
assert_eq "exit code 0" "0" "$CLI_EXIT"
assert_eq "baseがmain" "main" "$(jq -r '.base' <<<"$CLI_OUTPUT")"
assert_eq "merge_baseがmainのHEAD" "$MAIN_HEAD_SHA" "$(jq -r '.merge_base' <<<"$CLI_OUTPUT")"
assert_contains_json_array "filesにtracked.txtを含む" "$(jq -c '.files' <<<"$CLI_OUTPUT")" "tracked.txt"
assert_contains_json_array "filesにuntracked-new-file.txtを含む(main()経由でも回帰テストが通る)" "$(jq -c '.files' <<<"$CLI_OUTPUT")" "untracked-new-file.txt"

CLI_DIFF_FILE="$(jq -r '.diff_file' <<<"$CLI_OUTPUT")"
if [ -f "$CLI_DIFF_FILE" ] && grep -q "brand new content" "$CLI_DIFF_FILE"; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - diff_fileが実在し、untracked新規ファイルの中身を含む"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("diff_fileが実在し、untracked新規ファイルの中身を含む")
  echo "  NG - diff_fileが実在し、untracked新規ファイルの中身を含む"
fi
rm -f "$CLI_DIFF_FILE"

echo "=== test: CLIレベル（main()） — BASE省略かつgh不在/失敗環境ではexit非0 ==="
(
  cd "$REPO_DIR" || exit 1
  # gh をPATHから完全に除去するのは困難なため、GH_TOKEN等の環境変数操作ではなく
  # 単純に BASE省略時の gh 呼び出し失敗（このリポジトリはGitHubリポジトリではない）を利用する。
  "$TARGET_SCRIPT" >/dev/null 2>&1
)
NO_BASE_EXIT=$?
assert_eq "exit code が非0（gh解決失敗）" "1" "$NO_BASE_EXIT"

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
