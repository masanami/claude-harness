#!/bin/bash
# test-reply-and-resolve.sh
# scripts/reply-and-resolve.sh を gh API を呼ばずにテストする。
#
# 純粋関数（build_marker/build_reply_body_with_marker/body_list_contains_marker/
# build_resolve_mutation_query）は直接呼び出して検証する。
# gh を呼ぶ関数（resolve_repo/fetch_existing_inline_bodies/fetch_existing_conversation_bodies/
# post_inline_reply/post_conversation_reply/resolve_thread）は、scripts/README.md の
# 「外部呼び出し関数をテストからスタブ関数で上書きする」方針に従い、source後にスタブへ
# 差し替えたうえで main() を実行し、返信/Resolved化/冪等性スキップ/エラー集計の分岐を検証する。
#
# main() は process_item() を command substitution ($(...)) 経由で呼ぶため、process_item内から
# 呼ばれるスタブの呼び出し回数・引数をテストプロセス側の変数へ直接反映できない
# （サブシェルを跨げないため）。scripts/README.md の指示どおり、一時ファイルへの追記で
# 呼び出しログを記録し、サブシェル境界を越えて検証する。
#
# 実行方法: bash scripts/tests/test-reply-and-resolve.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../reply-and-resolve.sh"

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

CALL_LOG="$(mktemp)"
TMP_FILES=("$CALL_LOG")

# shellcheck disable=SC2329  # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup() {
  rm -f "${TMP_FILES[@]}"
}
trap cleanup EXIT

# shellcheck disable=SC2329  # main（source元）から間接的に呼ばれる（関数上書き経由）
log_call() {
  echo "$1" >>"$CALL_LOG"
}

reset_call_log() {
  : >"$CALL_LOG"
}

# --- デフォルトスタブ（各シナリオで必要に応じて上書き） ---

# shellcheck disable=SC2329  # main（source元）から間接的に呼ばれる（関数上書き）
resolve_repo() {
  log_call "resolve_repo"
  # shellcheck disable=SC2034  # main（source元）内で owner="$REPO_OWNER" として参照される
  REPO_OWNER="testowner"
  # shellcheck disable=SC2034  # main（source元）内で repo="$REPO_NAME" として参照される
  REPO_NAME="testrepo"
  return 0
}

FETCH_INLINE_BODIES_RESULT="[]"
# shellcheck disable=SC2329  # main（source元）から間接的に呼ばれる（関数上書き）
fetch_existing_inline_bodies() {
  log_call "fetch_existing_inline_bodies pr=$1 owner=$2 repo=$3"
  printf '%s' "$FETCH_INLINE_BODIES_RESULT"
}

FETCH_CONV_BODIES_RESULT="[]"
# shellcheck disable=SC2329  # main（source元）から間接的に呼ばれる（関数上書き）
fetch_existing_conversation_bodies() {
  log_call "fetch_existing_conversation_bodies pr=$1"
  printf '%s' "$FETCH_CONV_BODIES_RESULT"
}

POST_INLINE_REPLY_RESULT=0
# shellcheck disable=SC2329  # process_item（source元）から間接的に呼ばれる（関数上書き）
post_inline_reply() {
  log_call "post_inline_reply pr=$1 owner=$2 repo=$3 commentId=$4 body=${5//$'\n'/\\n}"
  return "$POST_INLINE_REPLY_RESULT"
}

POST_CONVERSATION_REPLY_RESULT=0
# shellcheck disable=SC2329  # process_item（source元）から間接的に呼ばれる（関数上書き）
post_conversation_reply() {
  log_call "post_conversation_reply pr=$1 body=${2//$'\n'/\\n}"
  return "$POST_CONVERSATION_REPLY_RESULT"
}

RESOLVE_THREAD_RESULT=0
# shellcheck disable=SC2329  # process_item（source元）から間接的に呼ばれる（関数上書き）
resolve_thread() {
  log_call "resolve_thread threadId=$1"
  return "$RESOLVE_THREAD_RESULT"
}

reset_stubs() {
  FETCH_INLINE_BODIES_RESULT="[]"
  FETCH_CONV_BODIES_RESULT="[]"
  POST_INLINE_REPLY_RESULT=0
  POST_CONVERSATION_REPLY_RESULT=0
  RESOLVE_THREAD_RESULT=0
  reset_call_log
}

write_items_file() {
  local content="$1"
  local f
  f="$(mktemp)"
  TMP_FILES+=("$f")
  printf '%s' "$content" >"$f"
  printf '%s' "$f"
}

# --- 純粋関数 ---
echo "=== build_marker ==="
{
  assert_eq 'build_marker: 固定フォーマット' '<!-- pr-review-respond:123 -->' "$(build_marker "123")"
}

echo "=== build_reply_body_with_marker ==="
{
  actual=$(build_reply_body_with_marker "Fixed the bug." "42")
  expected=$'Fixed the bug.\n\n<!-- pr-review-respond:42 -->'
  assert_eq 'build_reply_body_with_marker: 本文末尾にマーカーが付与される' "$expected" "$actual"
}

echo "=== body_list_contains_marker ==="
{
  if body_list_contains_marker '["some body <!-- pr-review-respond:9 -->"]' "9"; then r="true"; else r="false"; fi
  assert_eq 'body_list_contains_marker: マーカーを含むbodyがあればtrue' "true" "$r"

  if body_list_contains_marker '["some other body"]' "9"; then r="true"; else r="false"; fi
  assert_eq 'body_list_contains_marker: マーカーを含むbodyが無ければfalse' "false" "$r"

  if body_list_contains_marker '[]' "9"; then r="true"; else r="false"; fi
  assert_eq 'body_list_contains_marker: 空配列ならfalse' "false" "$r"

  if body_list_contains_marker '["<!-- pr-review-respond:99 -->"]' "9"; then r="true"; else r="false"; fi
  assert_eq 'body_list_contains_marker: 別commentIdのマーカーとは一致しない(9 vs 99)' "false" "$r"
}

echo "=== build_resolve_mutation_query ==="
{
  query="$(build_resolve_mutation_query)"
  # shellcheck disable=SC2016 # 期待するのはGraphQL変数トークンのリテラル文字列であり、シェル展開ではない
  dollar_thread_id_token='$threadId'
  case "$query" in
    *resolveReviewThread*"${dollar_thread_id_token}"*) r="true" ;;
    *) r="false" ;;
  esac
  # shellcheck disable=SC2016 # 説明文中の $threadId はGraphQL変数名の言及でありシェル展開ではない
  assert_eq 'build_resolve_mutation_query: resolveReviewThreadと$threadId変数を含む' "true" "$r"
}

# --- main(): 正常系（inline返信+resolve、conversation返信のみ） ---
echo "=== main: 正常系 (inline + conversation, sequential) ==="
{
  reset_stubs
  items_file=$(write_items_file '[
    {"commentId":"1","threadId":"THREAD_1","reply_body":"Fixed.","resolve":true},
    {"commentId":"2","threadId":null,"reply_body":"Thanks for the question.","resolve":false}
  ]')

  output=$(main "42" "$items_file")
  exit_code=$?

  assert_eq 'main: exit code 0(全項目成功)' "0" "$exit_code"
  assert_eq 'main: pr' "42" "$(jq -r '.pr' <<<"$output")"
  assert_eq 'main: results件数2' "2" "$(jq '.results | length' <<<"$output")"
  assert_eq 'main: succeeded=2' "2" "$(jq -r '.succeeded' <<<"$output")"
  assert_eq 'main: failed=0' "0" "$(jq -r '.failed' <<<"$output")"

  r1=$(jq -c '.results[] | select(.commentId == "1")' <<<"$output")
  assert_eq 'main: item1(inline) replied=true' "true" "$(jq -r '.replied' <<<"$r1")"
  assert_eq 'main: item1(inline) resolved=true' "true" "$(jq -r '.resolved' <<<"$r1")"
  assert_eq 'main: item1(inline) error=null' "null" "$(jq -r '.error' <<<"$r1")"

  r2=$(jq -c '.results[] | select(.commentId == "2")' <<<"$output")
  assert_eq 'main: item2(conversation) replied=true' "true" "$(jq -r '.replied' <<<"$r2")"
  assert_eq 'main: item2(conversation) resolved=skipped_not_applicable' "skipped_not_applicable" "$(jq -r '.resolved' <<<"$r2")"

  assert_eq 'main: post_inline_replyが1回呼ばれる' "1" "$(grep -c '^post_inline_reply ' "$CALL_LOG")"
  assert_eq 'main: post_conversation_replyが1回呼ばれる' "1" "$(grep -c '^post_conversation_reply ' "$CALL_LOG")"
  assert_eq 'main: resolve_threadが1回呼ばれる(THREAD_1のみ)' "1" "$(grep -c '^resolve_thread ' "$CALL_LOG")"
  assert_eq 'main: resolve_threadの引数はTHREAD_1' "resolve_thread threadId=THREAD_1" "$(grep '^resolve_thread ' "$CALL_LOG")"

  # 逐次処理の検証: item1のpost/resolveがitem2のpostより先に呼ばれている
  post1_line=$(grep -n 'post_inline_reply.*commentId=1 ' "$CALL_LOG" | head -1 | cut -d: -f1)
  resolve1_line=$(grep -n 'resolve_thread threadId=THREAD_1' "$CALL_LOG" | head -1 | cut -d: -f1)
  post2_line=$(grep -n 'post_conversation_reply' "$CALL_LOG" | head -1 | cut -d: -f1)
  assert_eq 'main: item1のresolveはitem2のpostより先(逐次処理)' "true" "$([ "$resolve1_line" -lt "$post2_line" ] && echo true || echo false)"
  assert_eq 'main: item1のpostはitem1のresolveより先' "true" "$([ "$post1_line" -lt "$resolve1_line" ] && echo true || echo false)"
}

# --- main(): 冪等性(既に返信済み、resolve:true) -> postはスキップするがresolveは実際に試行する ---
# （code-reviewer/design-reviewer指摘の回帰テスト: 冪等性スキップ時に resolve_thread の
#   呼び出し自体を省略すると、前回実行のresolveが実際には失敗していたケースを検知できず
#   誤って放置してしまう。resolveReviewThreadはidempotentなため再試行しても安全）
echo "=== main: 冪等性スキップ (post済みでもresolveは実際に試行する) ==="
{
  reset_stubs
  FETCH_INLINE_BODIES_RESULT='["prior reply <!-- pr-review-respond:5 -->"]'
  items_file=$(write_items_file '[{"commentId":"5","threadId":"THREAD_5","reply_body":"x","resolve":true}]')

  output=$(main "42" "$items_file")
  exit_code=$?

  assert_eq 'main: 冪等性スキップ時もexit code 0' "0" "$exit_code"
  assert_eq 'main: 冪等性スキップ時 replied=true' "true" "$(jq -r '.results[0].replied' <<<"$output")"
  assert_eq 'main: 冪等性スキップ時もresolveは実際に試行され成功する' "true" "$(jq -r '.results[0].resolved' <<<"$output")"
  assert_eq 'main: 冪等性スキップ時はpost_inline_replyが呼ばれない' "0" "$(grep -c '^post_inline_reply ' "$CALL_LOG")"
  assert_eq 'main: 冪等性スキップ時でもresolve_threadは1回呼ばれる' "1" "$(grep -c '^resolve_thread ' "$CALL_LOG")"
}

# --- main(): 冪等性スキップ + 前回のresolveが実際には失敗していたケースの検出 ---
echo "=== main: 冪等性スキップでもresolve失敗を検知できる(旧skipped_already問題の回帰テスト) ==="
{
  reset_stubs
  FETCH_INLINE_BODIES_RESULT='["prior reply <!-- pr-review-respond:9 -->"]'
  RESOLVE_THREAD_RESULT=1
  items_file=$(write_items_file '[{"commentId":"9","threadId":"THREAD_9","reply_body":"x","resolve":true}]')

  output=$(main "42" "$items_file")
  exit_code=$?

  assert_eq 'main: 冪等性スキップでもresolve失敗はexit code 1で検知される' "1" "$exit_code"
  assert_eq 'main: 冪等性スキップでもresolved=falseとして記録される' "false" "$(jq -r '.results[0].resolved' <<<"$output")"
  error_val=$(jq -r '.results[0].error' <<<"$output")
  case "$error_val" in
    *"failed to resolve thread"*) r="true" ;;
    *) r="false" ;;
  esac
  assert_eq 'main: 冪等性スキップでもresolve失敗のerrorが記録される' "true" "$r"
}

# --- main(): 冪等性(既に返信済み、resolve:false) -> resolvedはbool false ---
echo "=== main: 冪等性スキップ (resolve:false -> false) ==="
{
  reset_stubs
  FETCH_INLINE_BODIES_RESULT='["prior reply <!-- pr-review-respond:6 -->"]'
  items_file=$(write_items_file '[{"commentId":"6","threadId":"THREAD_6","reply_body":"x","resolve":false}]')

  output=$(main "42" "$items_file")

  assert_eq 'main: resolve:false時のresolvedはbool false' "false" "$(jq -r '.results[0].resolved' <<<"$output")"
  assert_eq 'main: resolve:false時はresolve_threadが呼ばれない' "0" "$(grep -c '^resolve_thread ' "$CALL_LOG")"
}

# --- main(): 返信失敗 -> error記録、resolveは試行しない（未回答スレッドを隠さないため） ---
echo "=== main: 返信失敗 (post_inline_reply failure) ==="
{
  reset_stubs
  POST_INLINE_REPLY_RESULT=1
  items_file=$(write_items_file '[{"commentId":"7","threadId":"THREAD_7","reply_body":"x","resolve":true}]')

  output=$(main "42" "$items_file")
  exit_code=$?

  assert_eq 'main: 返信失敗時はexit code 1' "1" "$exit_code"
  assert_eq 'main: 返信失敗時 replied=false' "false" "$(jq -r '.results[0].replied' <<<"$output")"
  assert_eq 'main: 返信失敗時はresolveを試行せずresolved=false(未回答スレッドを隠さない)' "false" "$(jq -r '.results[0].resolved' <<<"$output")"
  assert_eq 'main: 返信失敗時はresolve_threadが呼ばれない' "0" "$(grep -c '^resolve_thread ' "$CALL_LOG")"
  error_val=$(jq -r '.results[0].error' <<<"$output")
  case "$error_val" in
    *"failed to post inline reply"*) r="true" ;;
    *) r="false" ;;
  esac
  assert_eq 'main: 返信失敗時のerrorに理由が含まれる' "true" "$r"
  assert_eq 'main: failed=1' "1" "$(jq -r '.failed' <<<"$output")"
}

# --- main(): Resolved化失敗 -> error記録 ---
echo "=== main: Resolved化失敗 (resolve_thread failure) ==="
{
  reset_stubs
  RESOLVE_THREAD_RESULT=1
  items_file=$(write_items_file '[{"commentId":"8","threadId":"THREAD_8","reply_body":"x","resolve":true}]')

  output=$(main "42" "$items_file")
  exit_code=$?

  assert_eq 'main: Resolved化失敗時はexit code 1' "1" "$exit_code"
  assert_eq 'main: Resolved化失敗時もreplyは成功しreplied=true' "true" "$(jq -r '.results[0].replied' <<<"$output")"
  assert_eq 'main: Resolved化失敗時 resolved=false' "false" "$(jq -r '.results[0].resolved' <<<"$output")"
  error_val=$(jq -r '.results[0].error' <<<"$output")
  case "$error_val" in
    *"failed to resolve thread"*) r="true" ;;
    *) r="false" ;;
  esac
  assert_eq 'main: Resolved化失敗時のerrorに理由が含まれる' "true" "$r"
}

# --- main(): 混在バッチ(成功1件+失敗1件) -> succeeded/failed集計 ---
echo "=== main: 混在バッチ ==="
{
  reset_stubs
  items_file=$(write_items_file '[
    {"commentId":"10","threadId":"THREAD_10","reply_body":"ok","resolve":true},
    {"commentId":"11","threadId":null,"reply_body":"x","resolve":false}
  ]')
  POST_CONVERSATION_REPLY_RESULT=1

  output=$(main "42" "$items_file")
  exit_code=$?

  assert_eq 'main: 混在バッチはexit code 1' "1" "$exit_code"
  assert_eq 'main: 混在バッチ succeeded=1' "1" "$(jq -r '.succeeded' <<<"$output")"
  assert_eq 'main: 混在バッチ failed=1' "1" "$(jq -r '.failed' <<<"$output")"
}

# --- main(): 不正入力 ---
echo "=== main: 不正入力 ==="
{
  reset_stubs
  items_file=$(write_items_file '{"not":"an array"}')
  main "42" "$items_file" >/dev/null 2>&1
  assert_eq 'main: 配列でないJSONはexit code 1' "1" "$?"

  main "" "" >/dev/null 2>&1
  assert_eq 'main: 引数無しはexit code 1' "1" "$?"

  main "notanumber" "$items_file" >/dev/null 2>&1
  assert_eq 'main: PR番号が数値でなければexit code 1' "1" "$?"

  main "42" "/nonexistent/path/items.json" >/dev/null 2>&1
  assert_eq 'main: 存在しないファイルはexit code 1' "1" "$?"
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
