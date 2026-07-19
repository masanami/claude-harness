#!/bin/bash
# test-check-subtask-completion.sh
# scripts/check-subtask-completion.sh を gh API を呼ばずにテストする。
#
# 純粋関数（normalize_sub_issues_json/normalize_fallback_issues_json/build_child_entry/
# compute_all_merged）は直接呼び出して検証する。
# gh を呼ぶ関数（resolve_repo/fetch_sub_issues_json/fetch_fallback_issues_json/
# fetch_merged_pr_number）は、scripts/README.md の「外部呼び出し関数をテストからスタブ関数で
# 上書きする」方針に従い、source後にスタブへ差し替えたうえで main() を実行し、以下の分岐を検証する:
#   (a) sub_issues API経路で全マージ済み
#   (b) sub_issues API経路で一部未マージ
#   (c) フォールバック経路（sub_issues APIが失敗）
#   (d) 子Issue0件（両経路とも空）
#
# 実行方法: bash scripts/tests/test-check-subtask-completion.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../check-subtask-completion.sh"

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

# --- 純粋関数 ---

echo "=== normalize_sub_issues_json ==="
{
  raw='[{"number":60,"title":"Sub A","state":"closed"},{"number":61,"title":"Sub B","state":"open"}]'
  result=$(normalize_sub_issues_json "$raw")
  assert_eq "2件に正規化される" "2" "$(jq 'length' <<<"$result")"
  assert_eq "stateは大文字化される(closed->CLOSED)" "CLOSED" "$(jq -r '.[0].state' <<<"$result")"
  assert_eq "stateは大文字化される(open->OPEN)" "OPEN" "$(jq -r '.[1].state' <<<"$result")"
}

echo "=== normalize_fallback_issues_json ==="
{
  raw='[{"number":70,"title":"Fallback A","state":"CLOSED"}]'
  result=$(normalize_fallback_issues_json "$raw")
  assert_eq "1件に正規化される" "1" "$(jq 'length' <<<"$result")"
  assert_eq "titleが保持される" "Fallback A" "$(jq -r '.[0].title' <<<"$result")"
}

echo "=== build_child_entry ==="
{
  entry_with_pr=$(build_child_entry "60" "Sub A" "CLOSED" "61")
  assert_eq "mergedPr指定時はその値になる" "61" "$(jq -r '.mergedPr' <<<"$entry_with_pr")"
  assert_eq "numberはそのまま" "60" "$(jq -r '.number' <<<"$entry_with_pr")"

  entry_without_pr=$(build_child_entry "62" "Sub C" "OPEN" "")
  assert_eq "merged_pr未検出時はnull" "null" "$(jq -r '.mergedPr' <<<"$entry_without_pr")"
}

echo "=== compute_all_merged ==="
{
  if compute_all_merged '[{"state":"CLOSED","mergedPr":1},{"state":"CLOSED","mergedPr":2}]'; then r="true"; else r="false"; fi
  assert_eq "全件CLOSED+mergedPr非null -> true" "true" "$r"

  if compute_all_merged '[{"state":"CLOSED","mergedPr":1},{"state":"OPEN","mergedPr":null}]'; then r="true"; else r="false"; fi
  assert_eq "1件でもOPEN -> false" "false" "$r"

  if compute_all_merged '[{"state":"CLOSED","mergedPr":null}]'; then r="true"; else r="false"; fi
  assert_eq "CLOSEDだがmergedPrがnull -> false" "false" "$r"

  if compute_all_merged '[]'; then r="true"; else r="false"; fi
  assert_eq "空配列 -> false（空集合の論理的真=trueの罠を避ける）" "false" "$r"
}

# --- main(): gh呼び出し関数をスタブに差し替えて分岐を検証 ---

# デフォルトスタブ
# shellcheck disable=SC2329  # main（source元）から間接的に呼ばれる（関数上書き）
resolve_repo() {
  # shellcheck disable=SC2034  # main（source元）内で owner="$REPO_OWNER" として参照される
  REPO_OWNER="testowner"
  # shellcheck disable=SC2034  # main（source元）内で repo="$REPO_NAME" として参照される
  REPO_NAME="testrepo"
  return 0
}

SUB_ISSUES_RESULT=""
SUB_ISSUES_EXIT=0
# shellcheck disable=SC2329
fetch_sub_issues_json() {
  printf '%s' "$SUB_ISSUES_RESULT"
  return "$SUB_ISSUES_EXIT"
}

FALLBACK_ISSUES_RESULT="[]"
FALLBACK_ISSUES_EXIT=0
# shellcheck disable=SC2329
fetch_fallback_issues_json() {
  printf '%s' "$FALLBACK_ISSUES_RESULT"
  return "$FALLBACK_ISSUES_EXIT"
}

# child番号 -> merged PR番号 の対応表(スペース区切りの "child:pr" ペア)
MERGED_PR_MAP=""
# shellcheck disable=SC2329
fetch_merged_pr_number() {
  local child="$1"
  local pair
  for pair in $MERGED_PR_MAP; do
    local c="${pair%%:*}"
    local p="${pair##*:}"
    if [ "$c" = "$child" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf ''
  return 0
}

reset_stubs() {
  SUB_ISSUES_RESULT=""
  SUB_ISSUES_EXIT=0
  FALLBACK_ISSUES_RESULT="[]"
  FALLBACK_ISSUES_EXIT=0
  MERGED_PR_MAP=""
}

echo "=== main: (a) sub_issues API経路で全マージ済み ==="
{
  reset_stubs
  SUB_ISSUES_RESULT='[{"number":60,"title":"Sub A","state":"closed"},{"number":61,"title":"Sub B","state":"closed"}]'
  MERGED_PR_MAP="60:100 61:101"

  output=$(main "52")
  assert_eq "sourceはsub_issues_api" "sub_issues_api" "$(jq -r '.source' <<<"$output")"
  assert_eq "statusはok" "ok" "$(jq -r '.status' <<<"$output")"
  assert_eq "children 2件" "2" "$(jq '.children | length' <<<"$output")"
  assert_eq "allMergedはtrue" "true" "$(jq -r '.allMerged' <<<"$output")"
  assert_eq "1件目のmergedPrは100" "100" "$(jq -r '.children[0].mergedPr' <<<"$output")"
  assert_eq "parentは52" "52" "$(jq -r '.parent' <<<"$output")"
}

echo "=== main: (b) sub_issues API経路で一部未マージ(OPEN混在) ==="
{
  reset_stubs
  SUB_ISSUES_RESULT='[{"number":60,"title":"Sub A","state":"closed"},{"number":62,"title":"Sub C","state":"open"}]'
  MERGED_PR_MAP="60:100"

  output=$(main "52")
  assert_eq "sourceはsub_issues_api" "sub_issues_api" "$(jq -r '.source' <<<"$output")"
  assert_eq "allMergedはfalse(1件OPEN)" "false" "$(jq -r '.allMerged' <<<"$output")"
  assert_eq "OPEN側のmergedPrはnull(closeでないためfetch_merged_pr_numberを呼ばない)" "null" "$(jq -r '.children[1].mergedPr' <<<"$output")"
}

echo "=== main: (b') sub_issues API経路でCLOSEDだがmerged PRが見つからない場合はallMerged=false ==="
{
  reset_stubs
  SUB_ISSUES_RESULT='[{"number":63,"title":"Sub D","state":"closed"}]'
  MERGED_PR_MAP=""

  output=$(main "52")
  assert_eq "mergedPrはnull(見つからない)" "null" "$(jq -r '.children[0].mergedPr' <<<"$output")"
  assert_eq "allMergedはfalse" "false" "$(jq -r '.allMerged' <<<"$output")"
}

echo "=== main: (c) フォールバック経路（sub_issues APIが失敗=非0 exit） ==="
{
  reset_stubs
  SUB_ISSUES_EXIT=1
  SUB_ISSUES_RESULT=""
  FALLBACK_ISSUES_RESULT='[{"number":70,"title":"Fallback A","state":"CLOSED"}]'
  MERGED_PR_MAP="70:200"

  output=$(main "52")
  assert_eq "sourceはparent_label_fallback" "parent_label_fallback" "$(jq -r '.source' <<<"$output")"
  assert_eq "statusはok" "ok" "$(jq -r '.status' <<<"$output")"
  assert_eq "children 1件" "1" "$(jq '.children | length' <<<"$output")"
  assert_eq "allMergedはtrue" "true" "$(jq -r '.allMerged' <<<"$output")"
}

echo "=== main: (c') フォールバック経路（sub_issues APIが空配列を返す） ==="
{
  reset_stubs
  SUB_ISSUES_EXIT=0
  SUB_ISSUES_RESULT='[]'
  FALLBACK_ISSUES_RESULT='[{"number":71,"title":"Fallback B","state":"CLOSED"}]'
  MERGED_PR_MAP="71:201"

  output=$(main "52")
  assert_eq "空配列時もフォールバックへ切り替わる" "parent_label_fallback" "$(jq -r '.source' <<<"$output")"
  assert_eq "children 1件" "1" "$(jq '.children | length' <<<"$output")"
}

echo "=== main: (d) 子Issue0件（両経路とも空） ==="
{
  reset_stubs
  SUB_ISSUES_EXIT=1
  SUB_ISSUES_RESULT=""
  FALLBACK_ISSUES_RESULT='[]'

  output=$(main "52")
  assert_eq "statusはno_children_found" "no_children_found" "$(jq -r '.status' <<<"$output")"
  assert_eq "childrenは空配列" "0" "$(jq '.children | length' <<<"$output")"
  assert_eq "allMergedは暗黙にtrueにせずfalse" "false" "$(jq -r '.allMerged' <<<"$output")"
}

echo "=== main: 引数不正(非数値)はexit非0 ==="
{
  reset_stubs
  main "not-a-number" >/dev/null 2>&1
  status=$?
  assert_eq "戻り値が非0" "1" "$status"
}

echo "=== main: 引数無しはexit非0 ==="
{
  reset_stubs
  main >/dev/null 2>&1
  status=$?
  assert_eq "戻り値が非0" "1" "$status"
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
