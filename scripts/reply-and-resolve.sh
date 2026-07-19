#!/bin/bash
# reply-and-resolve.sh
# skills/pr-review-respond/scripts/review-respond.js（Dynamic Workflow、mode: 'respond'）が
# git-ops エージェント（agentType: 'claude-harness:git-ops'）経由で実行する決定的スクリプト。
# 分類済みコメントへの返信投稿とスレッドのResolved化を、1件ずつ**逐次**行う
# （GitHub secondary rate limit対策のため並列fan-outしない）。
#
# 使い方:
#   scripts/reply-and-resolve.sh <PR番号> <items_json_file|->
#
# 入力JSON（配列。ファイルまたは "-" でstdin指定）:
#   [{"commentId": "123", "threadId": "PRRT_xxx"|null, "reply_body": "...", "resolve": true|false}, ...]
#
# 出力（stdout にJSON1個）:
#   {"pr": 48, "results": [...], "succeeded": n, "failed": n}
#   各 results 要素:
#   {"commentId": "123", "replied": true|false, "resolved": true|false|"skipped_not_applicable", "error": string|null}
#
# 処理の要点:
#   1. 冪等性（返信済みスキップ）: 投稿する返信本文の末尾に隠しマーカー
#      `<!-- pr-review-respond:{commentId} -->` を付与する。処理開始時に一度、既存コメント
#      一覧（threadIdが非nullの項目向けは `gh api .../pulls/{pr}/comments`、threadIdがnullの
#      項目向けは `gh pr view {pr} --json comments`）を取得し、このマーカーを含む既存コメントが
#      あれば「返信済み」として新規投稿をスキップする（replied: true として記録）。
#   2. 返信: threadIdが非null（インラインコメント）の場合は
#      `gh api -X POST repos/{o}/{r}/pulls/{pr}/comments -f body=... -F in_reply_to={commentId}`。
#      threadIdがnull（会話タブ/レビュー本体コメント）の場合は
#      `gh pr comment {pr} --body "..."`（新規のPRコメントとして投稿）。
#   3. Resolved化: 返信が成立している（冪等性スキップ含む replied: true）、かつ resolve:true、
#      かつ threadIdが非nullの場合のみ、GraphQL resolveReviewThread mutationを実行。
#      threadIdがnullなら resolved: "skipped_not_applicable" として記録する
#      （該当なしを暗黙のfalseにしない）。返信自体が成立しなかった場合（投稿失敗）は
#      Resolved化を試みない（返信の付いていないスレッドを隠してしまうのを避けるため。
#      code-reviewer指摘の回帰修正）。
#      冪等性判定で「既に返信済み」と判定された項目についても、resolve:trueであれば
#      resolve_threadを実際に呼ぶ（呼び出しをスキップしない）。GitHubのresolveReviewThreadは
#      既にresolve済みのスレッドに対しても安全に再実行できる（idempotent）ため、
#      「前回実行でresolveも成功していたはず」と推測して呼び出しを省略すると、前回の
#      resolveが実際には失敗していたケースを検知できず誤って放置してしまう
#      （code-reviewer/design-reviewer指摘の回帰修正。以前は "skipped_already" という
#      値でこの呼び出し自体をスキップしていたが、安全側に倒して廃止した）。
#
# 関数分離（テスト容易性のため）:
#   - gh を呼ぶ関数: resolve_repo / fetch_existing_inline_bodies / fetch_existing_conversation_bodies /
#     post_inline_reply / post_conversation_reply / resolve_thread
#   - 純粋関数: build_marker / build_reply_body_with_marker / body_list_contains_marker /
#     build_resolve_mutation_query
# gh を呼ぶ関数は、scripts/README.md の「外部呼び出し関数をテストからスタブ関数で上書きする」
# 方針に従い、テストからスタブに差し替えて main() 全体の分岐（返信/Resolved化/冪等性スキップ/
# エラー集計）を検証する（scripts/tests/test-reply-and-resolve.sh）。
#
# `failed` は results 内で error が非nullの項目数。1件でも failed > 0 なら exit 1、
# それ以外は exit 0（scripts/README.md の出力規約: exit code と JSON の両方で成否を表現する）。
#
# main() はテスト容易性のため exit を直接呼ばず、常に return で終了コード相当の値を返す
# （このファイルが直接実行された場合のみ、末尾の呼び出しが main の戻り値で実際に exit する）。
#
# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。

set -u

MARKER_PREFIX="pr-review-respond"

# jq の有無をチェックする。無ければ stderr にエラーメッセージ + エラーJSONを出す。
check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# --- 純粋関数（gh を呼ばない） ---

# 冪等性検出用の隠しマーカーを組み立てる。
# 引数: commentId
# 戻り値: stdout に "<!-- pr-review-respond:{commentId} -->"
build_marker() {
  local comment_id="$1"
  printf '<!-- %s:%s -->' "$MARKER_PREFIX" "$comment_id"
}

# 返信本文の末尾にマーカーを付与する。
# 引数: reply_body, commentId
# 戻り値: stdout に "{reply_body}\n\n{マーカー}"
build_reply_body_with_marker() {
  local reply_body="$1" comment_id="$2"
  printf '%s\n\n%s' "$reply_body" "$(build_marker "$comment_id")"
}

# bodyの配列（JSON文字列配列）の中に、指定commentIdのマーカーを含むものが1件でも
# あるかを判定する。
# 引数: bodies_json（["body1", "body2", ...] 形式のJSON配列文字列）, commentId
# 戻り値: 0=含む(既に返信済み), 1=含まない
body_list_contains_marker() {
  local bodies_json="$1" comment_id="$2"
  local marker
  marker=$(build_marker "$comment_id")
  jq -e --arg marker "$marker" 'any(.[]; type == "string" and (index($marker) != null))' <<<"$bodies_json" >/dev/null 2>&1
}

# resolveReviewThread GraphQL mutationのクエリ文字列を組み立てる（純粋関数として分離）。
# 戻り値: stdout にクエリ文字列
build_resolve_mutation_query() {
  cat <<'EOF'
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}
EOF
}

# --- gh を呼ぶ関数 ---

# owner/repo をリポジトリ設定から解決する。
# 結果: REPO_OWNER, REPO_NAME
resolve_repo() {
  local json
  if ! json=$(gh repo view --json owner,name 2>/dev/null); then
    echo "Error: failed to resolve owner/repo via gh repo view" >&2
    return 1
  fi
  REPO_OWNER=$(jq -r '.owner.login' <<<"$json")
  REPO_NAME=$(jq -r '.name' <<<"$json")
  if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    echo "Error: could not parse owner/repo from gh repo view output" >&2
    return 1
  fi
  return 0
}

# threadIdが非nullの項目向けの既存コメント本文一覧を取得する。
# 引数: PR番号, owner, repo
# 戻り値: stdout に ["body1", "body2", ...] 形式のJSON配列
fetch_existing_inline_bodies() {
  local pr="$1" owner="$2" repo="$3"
  gh api "repos/${owner}/${repo}/pulls/${pr}/comments" --paginate --slurp 2>/dev/null |
    jq -c '[.[][] | .body]'
}

# threadIdがnullの項目向けの既存コメント本文一覧を取得する。
# 引数: PR番号
# 戻り値: stdout に ["body1", "body2", ...] 形式のJSON配列
fetch_existing_conversation_bodies() {
  local pr="$1"
  gh pr view "$pr" --json comments 2>/dev/null | jq -c '[(.comments // [])[] | .body]'
}

# インラインコメントへの返信を投稿する。
# 引数: PR番号, owner, repo, commentId, body（マーカー付与済み）
# 戻り値: 0=成功, 1=失敗
post_inline_reply() {
  local pr="$1" owner="$2" repo="$3" comment_id="$4" body="$5"
  gh api -X POST "repos/${owner}/${repo}/pulls/${pr}/comments" \
    -f body="$body" -F in_reply_to="$comment_id" >/dev/null 2>&1
}

# 会話タブ/レビュー本体コメント向けに、新規のPRコメントとして返信を投稿する。
# 引数: PR番号, body（マーカー付与済み）
# 戻り値: 0=成功, 1=失敗
post_conversation_reply() {
  local pr="$1" body="$2"
  gh pr comment "$pr" --body "$body" >/dev/null 2>&1
}

# reviewThreadをResolved化する。
# 引数: threadId
# 戻り値: 0=成功, 1=失敗
resolve_thread() {
  local thread_id="$1"
  local query
  query=$(build_resolve_mutation_query)
  gh api graphql -f query="$query" -f threadId="$thread_id" >/dev/null 2>&1
}

# --- main ---

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <PR番号> <items_json_file|->" >&2
}

# 入力JSON（配列）をファイルまたはstdinから読み込む。
# 引数: items_arg（ファイルパス、または "-" でstdin）
# 戻り値: stdout にJSON全文。失敗時は非0を返す。
read_items_json() {
  local items_arg="$1"
  if [ "$items_arg" = "-" ]; then
    cat
    return 0
  fi
  if [ ! -f "$items_arg" ]; then
    echo "Error: items file not found: ${items_arg}" >&2
    return 1
  fi
  cat "$items_arg"
}

# 1件の項目を処理し、結果オブジェクト（JSON文字列）を stdout に出力する。
# 引数: pr, owner, repo, item_json（1件分のJSONオブジェクト）, inline_bodies_json, conversation_bodies_json
# 戻り値: 0=このitemにerrorが無かった, 1=errorがあった（呼び出し元のfailedカウントに使う）
process_item() {
  local pr="$1" owner="$2" repo="$3" item_json="$4" inline_bodies_json="$5" conversation_bodies_json="$6"

  local comment_id thread_id reply_body resolve_flag
  comment_id=$(jq -r '.commentId' <<<"$item_json")
  thread_id=$(jq -r '.threadId' <<<"$item_json")
  reply_body=$(jq -r '.reply_body' <<<"$item_json")
  resolve_flag=$(jq -r '.resolve' <<<"$item_json")

  local already_replied="false"
  if [ "$thread_id" != "null" ]; then
    if body_list_contains_marker "$inline_bodies_json" "$comment_id"; then
      already_replied="true"
    fi
  else
    if body_list_contains_marker "$conversation_bodies_json" "$comment_id"; then
      already_replied="true"
    fi
  fi

  local replied="false"
  local error_msg=""

  if [ "$already_replied" = "true" ]; then
    replied="true"
  else
    local full_body
    full_body=$(build_reply_body_with_marker "$reply_body" "$comment_id")
    if [ "$thread_id" != "null" ]; then
      if post_inline_reply "$pr" "$owner" "$repo" "$comment_id" "$full_body"; then
        replied="true"
      else
        error_msg="failed to post inline reply for comment ${comment_id}"
      fi
    else
      if post_conversation_reply "$pr" "$full_body"; then
        replied="true"
      else
        error_msg="failed to post conversation reply for comment ${comment_id}"
      fi
    fi
  fi

  local resolved_json
  if [ "$thread_id" = "null" ]; then
    resolved_json='"skipped_not_applicable"'
  elif [ "$replied" != "true" ]; then
    # 返信が(冪等性スキップでも新規投稿でも)成立しなかった場合はResolved化を試みない。
    # 返信が付いていないスレッドを隠してしまう（レビュアーの指摘が未回答のまま見えなくなる）
    # のを避けるための安全側の判断（code-reviewer指摘 finding#4 の回帰修正）。
    resolved_json="false"
  elif [ "$resolve_flag" = "true" ]; then
    # 冪等性チェックで「既に返信済み」と判定された項目も、resolve_threadは実際に呼ぶ。
    # GitHub の resolveReviewThread は既にresolve済みのスレッドに対しても安全に
    # 再実行できる（idempotent）ため、「前回実行で resolve処理も併走済みのはず」という
    # 推測に基づいて呼び出しを省略すると、前回のresolveが実際には失敗していたケースを
    # 検出できず、誤って成功扱いのまま放置してしまう（code-reviewer/design-reviewer
    # 指摘 finding#3 の回帰修正。以前は already_replied=true の場合 "skipped_already" として
    # 呼び出し自体をスキップしていた）。
    if resolve_thread "$thread_id"; then
      resolved_json="true"
    else
      resolved_json="false"
      if [ -z "$error_msg" ]; then
        error_msg="failed to resolve thread ${thread_id} for comment ${comment_id}"
      fi
    fi
  else
    resolved_json="false"
  fi

  local error_json="null"
  local item_failed=0
  if [ -n "$error_msg" ]; then
    error_json=$(jq -n --arg m "$error_msg" '$m')
    item_failed=1
  fi

  jq -n \
    --arg commentId "$comment_id" \
    --argjson replied "$replied" \
    --argjson resolved "$resolved_json" \
    --argjson error "$error_json" \
    '{commentId: $commentId, replied: $replied, resolved: $resolved, error: $error}'

  return $item_failed
}

main() {
  local pr="${1:-}" items_arg="${2:-}"

  if [ -z "$pr" ] || ! [[ "$pr" =~ ^[0-9]+$ ]] || [ -z "$items_arg" ]; then
    print_usage
    return 1
  fi

  if ! check_jq; then
    return 1
  fi

  local items_json
  if ! items_json=$(read_items_json "$items_arg"); then
    return 1
  fi

  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$items_json"; then
    echo "Error: items JSON must be a top-level array" >&2
    return 1
  fi

  if ! resolve_repo; then
    return 1
  fi
  local owner="$REPO_OWNER" repo="$REPO_NAME"

  local need_inline need_conv
  need_inline=$(jq 'any(.[]; .threadId != null)' <<<"$items_json")
  need_conv=$(jq 'any(.[]; .threadId == null)' <<<"$items_json")

  local inline_bodies="[]" conversation_bodies="[]"
  if [ "$need_inline" = "true" ]; then
    if ! inline_bodies=$(fetch_existing_inline_bodies "$pr" "$owner" "$repo") || [ -z "$inline_bodies" ]; then
      echo "Warning: failed to fetch existing inline comments for idempotency check; proceeding without it" >&2
      inline_bodies="[]"
    fi
  fi
  if [ "$need_conv" = "true" ]; then
    if ! conversation_bodies=$(fetch_existing_conversation_bodies "$pr") || [ -z "$conversation_bodies" ]; then
      echo "Warning: failed to fetch existing conversation comments for idempotency check; proceeding without it" >&2
      conversation_bodies="[]"
    fi
  fi

  local results=()
  local succeeded=0
  local failed=0

  local item result
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    if result=$(process_item "$pr" "$owner" "$repo" "$item" "$inline_bodies" "$conversation_bodies"); then
      succeeded=$((succeeded + 1))
    else
      failed=$((failed + 1))
    fi
    results+=("$result")
  done < <(jq -c '.[]' <<<"$items_json")

  local results_json="[]"
  if [ "${#results[@]}" -gt 0 ]; then
    results_json=$(printf '%s\n' "${results[@]}" | jq -s -c '.')
  fi

  jq -n \
    --argjson pr "$pr" \
    --argjson results "$results_json" \
    --argjson succeeded "$succeeded" \
    --argjson failed "$failed" \
    '{pr: $pr, results: $results, succeeded: $succeeded, failed: $failed}'

  if [ "$failed" -gt 0 ]; then
    return 1
  fi
  return 0
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
