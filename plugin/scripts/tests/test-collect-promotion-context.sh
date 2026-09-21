#!/bin/bash
# test-collect-promotion-context.sh
# scripts/collect-promotion-context.sh の純粋関数（parse_name_status）と、git操作を伴う関数
# （resolve_ref/compute_merge_base/compute_diff_stat/collect_name_status_raw/write_diff_file）を、
# 一時gitリポジトリを作成して検証する。test-collect-review-diff.sh と同じ方針。
#
# fetch_origin は main() からのみ呼ばれる別関数であり、このテストは fetch_origin を直接は
# 呼ばない（origin リモートを用意しない）。main() 経由のCLIレベルテストでも fetch_origin は
# best-effort（失敗しても警告のみで継続）のため、origin 未設定でも main() 全体は失敗しない。
#
# 実行方法: bash scripts/tests/test-collect-promotion-context.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../collect-promotion-context.sh"

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

# --- parse_name_status: gitを呼ばない純粋関数の単体テスト ---
echo "=== test: parse_name_status — 通常行(M/A/D)をJSON配列へ変換する ==="
{
  parse_name_status $'M\tsrc/a.js\nA\tsrc/new.js\nD\tsrc/old.js'
  result="$NAME_STATUS_JSON"
  assert_eq "3件の要素" "3" "$(jq 'length' <<<"$result")"
  assert_eq "1件目はstatus=M, path=src/a.js" '{"status":"M","path":"src/a.js"}' "$(jq -c '.[0]' <<<"$result")"
  assert_eq "2件目はstatus=A, path=src/new.js" '{"status":"A","path":"src/new.js"}' "$(jq -c '.[1]' <<<"$result")"
  assert_eq "3件目はstatus=D, path=src/old.js" '{"status":"D","path":"src/old.js"}' "$(jq -c '.[2]' <<<"$result")"
}

echo "=== test: parse_name_status — rename行(3カラム)はoldPath付きで変換する ==="
{
  parse_name_status $'R100\told/path.js\tnew/path.js'
  result="$NAME_STATUS_JSON"
  assert_eq "1件の要素" "1" "$(jq 'length' <<<"$result")"
  assert_eq "statusはR100" "R100" "$(jq -r '.[0].status' <<<"$result")"
  assert_eq "pathは新しいパス(new/path.js)" "new/path.js" "$(jq -r '.[0].path' <<<"$result")"
  assert_eq "oldPathは元のパス(old/path.js)" "old/path.js" "$(jq -r '.[0].oldPath' <<<"$result")"
}

echo "=== test: parse_name_status — 通常行にはoldPathキーが存在しない ==="
{
  parse_name_status $'M\tsrc/a.js'
  result="$NAME_STATUS_JSON"
  assert_eq "oldPathキーは存在しない(has=false)" "false" "$(jq 'has("oldPath")' <<<"$(jq -c '.[0]' <<<"$result")")"
}

echo "=== test: parse_name_status — 空文字なら空配列 ==="
{
  parse_name_status ""
  assert_eq "空配列" "[]" "$NAME_STATUS_JSON"
}

echo "=== test: parse_name_status — 通常行とrename行が混在していても両方正しく変換される ==="
{
  parse_name_status $'M\tsrc/a.js\nR090\told/b.js\tnew/b.js\nA\tsrc/c.js'
  result="$NAME_STATUS_JSON"
  assert_eq "3件の要素" "3" "$(jq 'length' <<<"$result")"
  assert_eq "rename行(2件目)のoldPath" "old/b.js" "$(jq -r '.[1].oldPath' <<<"$result")"
  assert_eq "通常行(3件目)はstatus=A" "A" "$(jq -r '.[2].status' <<<"$result")"
}

# --- 一時gitリポジトリのセットアップ ---
# main ブランチに初期コミット -> feature ブランチへ分岐 -> ファイル追加・変更・rename。
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
  echo "to be renamed" >rename-me.txt
  git add tracked.txt rename-me.txt
  git commit -q -m "initial commit"

  git checkout -q -b feature/promotion-branch
  {
    echo "line1"
    echo "line2 modified"
  } >tracked.txt
  echo "brand new file" >new-file.txt
  git mv rename-me.txt renamed.txt
  git add tracked.txt new-file.txt renamed.txt
  git commit -q -m "modify, add, and rename files"
)

cd "$REPO_DIR" || exit 1

echo "=== test: resolve_ref — originが無い場合はローカルブランチにフォールバックする ==="
resolve_ref "main"
assert_eq "origin/mainが無いのでローカルmainにフォールバック" "main" "$RESOLVED_REF"

resolve_ref "feature/promotion-branch"
assert_eq "origin/feature/promotion-branchが無いのでローカルにフォールバック" "feature/promotion-branch" "$RESOLVED_REF"

echo "=== test: resolve_ref — 存在しないref名は戻り値1 ==="
resolve_ref "no-such-branch-xyz" 2>/dev/null
RESOLVE_REF_FAIL_STATUS=$?
assert_eq "戻り値が非0" "1" "$RESOLVE_REF_FAIL_STATUS"

echo "=== test: resolve_ref — '-'始まりのrefはgitに渡さず拒否する（オプション注入対策） ==="
resolve_ref "--upload-pack=touch /tmp/pwned" 2>/dev/null
RESOLVE_REF_DASH_STATUS=$?
assert_eq "戻り値が非0" "1" "$RESOLVE_REF_DASH_STATUS"

echo "=== test: compute_merge_base — mainとfeatureブランチのmerge-baseがmainの先頭になる ==="
MAIN_HEAD_SHA="$(git rev-parse main)"
compute_merge_base "main" "feature/promotion-branch"
assert_eq "merge-baseはmainのHEAD" "$MAIN_HEAD_SHA" "$MERGE_BASE"

echo "=== test: compute_diff_stat — three-dot diffのstat出力にtracked.txtが含まれる ==="
compute_diff_stat "main" "feature/promotion-branch"
if [[ "$DIFF_STAT" == *"tracked.txt"* ]]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - diff_statにtracked.txtが含まれる"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("diff_statにtracked.txtが含まれる")
  echo "  NG - diff_statにtracked.txtが含まれる"
fi

echo "=== test: collect_name_status_raw + parse_name_status — 実gitリポジトリでの統合動作(add/modify/rename) ==="
collect_name_status_raw "main" "feature/promotion-branch"
parse_name_status "$NAME_STATUS_RAW"
NS_RESULT="$NAME_STATUS_JSON"

assert_eq "3件の変更(tracked.txt modify, new-file.txt add, renamed.txt rename)" "3" "$(jq 'length' <<<"$NS_RESULT")"

MODIFIED_ENTRY="$(jq -c '.[] | select(.path == "tracked.txt")' <<<"$NS_RESULT")"
assert_eq "tracked.txtのstatusはM" "M" "$(jq -r '.status' <<<"$MODIFIED_ENTRY")"

ADDED_ENTRY="$(jq -c '.[] | select(.path == "new-file.txt")' <<<"$NS_RESULT")"
assert_eq "new-file.txtのstatusはA" "A" "$(jq -r '.status' <<<"$ADDED_ENTRY")"

RENAMED_ENTRY="$(jq -c '.[] | select(.path == "renamed.txt")' <<<"$NS_RESULT")"
RENAMED_STATUS="$(jq -r '.status' <<<"$RENAMED_ENTRY")"
case "$RENAMED_STATUS" in
  R*) RENAMED_STATUS_STARTS_WITH_R="0" ;;
  *) RENAMED_STATUS_STARTS_WITH_R="1" ;;
esac
assert_eq "renamed.txtのstatusはRで始まる" "0" "$RENAMED_STATUS_STARTS_WITH_R"
assert_eq "renamed.txtのoldPathはrename-me.txt" "rename-me.txt" "$(jq -r '.oldPath' <<<"$RENAMED_ENTRY")"

echo "=== test: write_diff_file — full diffが一時ファイルに書き出される ==="
write_diff_file "main" "feature/promotion-branch"
assert_eq "diff_fileが生成される" "0" "$([ -f "$DIFF_FILE" ] && echo 0 || echo 1)"
DIFF_CONTENT="$(cat "$DIFF_FILE")"
if [[ "$DIFF_CONTENT" == *"line2 modified"* ]]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - diffにtracked.txtの変更内容が含まれる"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("diffにtracked.txtの変更内容が含まれる")
  echo "  NG - diffにtracked.txtの変更内容が含まれる"
fi
if [[ "$DIFF_CONTENT" == *"brand new file"* ]]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - diffに新規ファイルの内容が含まれる"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("diffに新規ファイルの内容が含まれる")
  echo "  NG - diffに新規ファイルの内容が含まれる"
fi
rm -f "$DIFF_FILE"

echo "=== test: CLIレベル（main()） — 引数2つでJSON1個を出力する（fetch_originはbest-effortで失敗を許容） ==="
CLI_OUTPUT=$("$TARGET_SCRIPT" "main" "feature/promotion-branch" 2>/dev/null)
CLI_EXIT=$?
assert_eq "exit code 0" "0" "$CLI_EXIT"
assert_eq "baseは引数のmain" "main" "$(jq -r '.base' <<<"$CLI_OUTPUT")"
assert_eq "integrationは引数のfeature/promotion-branch" "feature/promotion-branch" "$(jq -r '.integration' <<<"$CLI_OUTPUT")"
assert_eq "merge_baseがmainのHEAD" "$MAIN_HEAD_SHA" "$(jq -r '.merge_base' <<<"$CLI_OUTPUT")"
assert_eq "name_statusに3件の変更を含む" "3" "$(jq '.name_status | length' <<<"$CLI_OUTPUT")"

CLI_DIFF_FILE="$(jq -r '.diff_file' <<<"$CLI_OUTPUT")"
if [ -f "$CLI_DIFF_FILE" ] && grep -q "brand new file" "$CLI_DIFF_FILE"; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - diff_fileが実在し、新規ファイルの中身を含む"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("diff_fileが実在し、新規ファイルの中身を含む")
  echo "  NG - diff_fileが実在し、新規ファイルの中身を含む"
fi
rm -f "$CLI_DIFF_FILE"

echo "=== test: CLIレベル（main()） — 引数不足はexit非0 ==="
"$TARGET_SCRIPT" "main" >/dev/null 2>&1
MISSING_ARG_EXIT=$?
assert_eq "exit code が非0" "1" "$MISSING_ARG_EXIT"

echo "=== test: CLIレベル（main()） — 存在しないbranchはexit非0 ==="
"$TARGET_SCRIPT" "main" "no-such-integration-branch-xyz" >/dev/null 2>&1
BAD_REF_EXIT=$?
assert_eq "exit code が非0" "1" "$BAD_REF_EXIT"

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
