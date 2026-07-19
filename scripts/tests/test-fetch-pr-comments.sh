#!/bin/bash
# test-fetch-pr-comments.sh
# scripts/fetch-pr-comments.sh のパース関数（normalize_comments/build_diff_stat/
# is_bot_author）を gh API を呼ばずに直接テストする。
#
# 実行方法: bash scripts/tests/test-fetch-pr-comments.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../fetch-pr-comments.sh"

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

# --- フィクスチャ ---

FIXTURE_REVIEWS='{"reviews":[
  {"id":"PRR_1","author":{"login":"alice"},"body":"LGTM overall but see comments","state":"COMMENTED"},
  {"id":"PRR_2","author":{"login":"bob"},"body":"","state":"APPROVED"}
]}'

FIXTURE_CONVERSATION='{"comments":[
  {"id":"IC_1","author":{"login":"coderabbitai[bot]"},"body":"General note on PR"}
]}'

FIXTURE_INLINE='[
  {"id":111,"user":{"login":"carol"},"path":"src/a.js","line":10,"diff_hunk":"@@ -1,3 +1,3 @@","body":"fix this","in_reply_to_id":null},
  {"id":222,"user":{"login":"coderabbitai[bot]"},"path":"src/b.js","line":5,"diff_hunk":"@@ -1,2 +1,2 @@","body":"nit: rename","in_reply_to_id":null},
  {"id":333,"user":{"login":"dave"},"path":"src/c.js","line":1,"diff_hunk":"@@ -1 +1 @@","body":"no matching thread","in_reply_to_id":null}
]'

FIXTURE_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"id":"PRRT_1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"databaseId":111}]}},
  {"id":"PRRT_2","isResolved":true,"isOutdated":true,"comments":{"nodes":[{"databaseId":222}]}}
]}}}}}'

FIXTURE_FILES='{"files":[
  {"path":"path/a.js","additions":12,"deletions":3},
  {"path":"path/b.js","additions":5,"deletions":0}
]}'

# --- is_bot_author ---
echo "=== is_bot_author ==="
{
  if is_bot_author "coderabbitai[bot]"; then r="true"; else r="false"; fi
  assert_eq 'is_bot_author: "coderabbitai[bot]" は true' "true" "$r"

  if is_bot_author "some-app[bot]"; then r="true"; else r="false"; fi
  assert_eq 'is_bot_author: 任意の "xxx[bot]" サフィックスは true' "true" "$r"

  if is_bot_author "coderabbitai"; then r="true"; else r="false"; fi
  assert_eq 'is_bot_author: 既知のAIレビュアー名(サフィックス無し)は true' "true" "$r"

  if is_bot_author "alice"; then r="true"; else r="false"; fi
  assert_eq 'is_bot_author: 通常のユーザー名は false' "false" "$r"

  if is_bot_author ""; then r="true"; else r="false"; fi
  assert_eq 'is_bot_author: 空文字は false' "false" "$r"
}

# --- build_diff_stat ---
echo "=== build_diff_stat ==="
{
  actual=$(build_diff_stat "$FIXTURE_FILES")
  expected=$'path/a.js | +12 -3\npath/b.js | +5 -0'
  assert_eq 'build_diff_stat: 1行1ファイルの "path | +N -M" 形式' "$expected" "$actual"

  empty_actual=$(build_diff_stat '{"files":[]}')
  assert_eq 'build_diff_stat: filesが空なら空文字' "" "$empty_actual"
}

# --- normalize_comments ---
echo "=== normalize_comments ==="
{
  normalize_comments "$FIXTURE_REVIEWS" "$FIXTURE_CONVERSATION" "$FIXTURE_INLINE" "$FIXTURE_THREADS"
  result="$NORMALIZED_COMMENTS_JSON"

  count=$(jq 'length' <<<"$result")
  assert_eq 'normalize_comments: 空bodyのレビュー(PRR_2)は除外され計5件(review1+conversation1+inline3)' "5" "$count"

  review_entry=$(jq -c '.[] | select(.id == "PRR_1")' <<<"$result")
  assert_eq 'normalize_comments: reviewコメントのsourceはreview' "review" "$(jq -r '.source' <<<"$review_entry")"
  assert_eq 'normalize_comments: reviewコメントのthreadIdはnull' "null" "$(jq -r '.threadId' <<<"$review_entry")"
  assert_eq 'normalize_comments: reviewコメントのpathはnull' "null" "$(jq -r '.path' <<<"$review_entry")"
  assert_eq 'normalize_comments: reviewコメントのis_botはfalse(alice)' "false" "$(jq -r '.is_bot' <<<"$review_entry")"

  approved_missing=$(jq '[.[] | select(.id == "PRR_2")] | length' <<<"$result")
  assert_eq 'normalize_comments: 空bodyレビュー(PRR_2)は結果に含まれない' "0" "$approved_missing"

  conv_entry=$(jq -c '.[] | select(.id == "IC_1")' <<<"$result")
  assert_eq 'normalize_comments: conversationコメントのsourceはconversation' "conversation" "$(jq -r '.source' <<<"$conv_entry")"
  assert_eq 'normalize_comments: conversationコメントのis_botはtrue(coderabbitai[bot])' "true" "$(jq -r '.is_bot' <<<"$conv_entry")"
  assert_eq 'normalize_comments: conversationコメントのthreadIdはnull' "null" "$(jq -r '.threadId' <<<"$conv_entry")"

  inline_111=$(jq -c '.[] | select(.id == "111")' <<<"$result")
  assert_eq 'normalize_comments: inlineコメント(111)のsourceはinline' "inline" "$(jq -r '.source' <<<"$inline_111")"
  assert_eq 'normalize_comments: inlineコメント(111)のthreadIdは対応スレッド' "PRRT_1" "$(jq -r '.threadId' <<<"$inline_111")"
  assert_eq 'normalize_comments: inlineコメント(111)のis_resolvedはfalse' "false" "$(jq -r '.is_resolved' <<<"$inline_111")"
  assert_eq 'normalize_comments: inlineコメント(111)のis_outdatedはfalse' "false" "$(jq -r '.is_outdated' <<<"$inline_111")"
  assert_eq 'normalize_comments: inlineコメント(111)のpath' "src/a.js" "$(jq -r '.path' <<<"$inline_111")"
  assert_eq 'normalize_comments: inlineコメント(111)のline' "10" "$(jq -r '.line' <<<"$inline_111")"
  assert_eq 'normalize_comments: inlineコメント(111)のdiff_hunk' "@@ -1,3 +1,3 @@" "$(jq -r '.diff_hunk' <<<"$inline_111")"

  inline_222=$(jq -c '.[] | select(.id == "222")' <<<"$result")
  assert_eq 'normalize_comments: inlineコメント(222)のis_botはtrue(coderabbitai[bot])' "true" "$(jq -r '.is_bot' <<<"$inline_222")"
  assert_eq 'normalize_comments: inlineコメント(222)のthreadIdは対応スレッド(resolved+outdated)' "PRRT_2" "$(jq -r '.threadId' <<<"$inline_222")"
  assert_eq 'normalize_comments: inlineコメント(222)のis_resolvedはtrue' "true" "$(jq -r '.is_resolved' <<<"$inline_222")"
  assert_eq 'normalize_comments: inlineコメント(222)のis_outdatedはtrue' "true" "$(jq -r '.is_outdated' <<<"$inline_222")"

  inline_333=$(jq -c '.[] | select(.id == "333")' <<<"$result")
  assert_eq 'normalize_comments: 対応スレッドが見つからないinlineコメント(333)のthreadIdはnull' "null" "$(jq -r '.threadId' <<<"$inline_333")"
  assert_eq 'normalize_comments: 対応スレッドが見つからないinlineコメント(333)のis_resolvedはfalse' "false" "$(jq -r '.is_resolved' <<<"$inline_333")"
}

# --- normalize_comments: 全経路が空の場合 ---
echo "=== normalize_comments: all empty ==="
{
  normalize_comments '{"reviews":[]}' '{"comments":[]}' '[]' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
  empty_result="$NORMALIZED_COMMENTS_JSON"
  assert_eq 'normalize_comments: 全経路が空なら空配列' "[]" "$empty_result"
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
