#!/bin/bash
# fetch-pr-comments.sh
# skills/pr-review-respond/SKILL.md（Step 2）が Bash ツールで直接実行する決定的スクリプト
# （Issue #108 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し、呼び出し元自身の
# 直接実行に一本化した）。
# PRのレビューコメントを3経路（レビュー本体/会話タブ/インライン）+ GraphQL reviewThreads +
# 変更ファイル一覧から取得し、単一の正規化配列へ組み立てる。
#
# 使い方:
#   scripts/fetch-pr-comments.sh <PR番号>
#
# 出力（stdout にJSON1個）:
#   {
#     "pr": 48,
#     "diff_stat": "path/a.js | +12 -3\npath/b.js | +5 -0",
#     "comments": [
#       {
#         "id": "123",
#         "threadId": "PRRT_xxx" | null,
#         "source": "review" | "conversation" | "inline",
#         "author": "login",
#         "is_bot": true | false,
#         "path": "a.js" | null,
#         "line": 10 | null,
#         "diff_hunk": "..." | null,
#         "body": "...",
#         "is_resolved": true | false,
#         "is_outdated": true | false
#       }
#     ]
#   }
#
# フィールドの定義:
#   - id: コメントのDB ID（またはgh/GraphQLが返す識別子）を文字列化したもの。
#     review/conversation/inlineでID空間は別だが、この正規化配列内では一意識別子として扱う。
#   - threadId: GraphQL reviewThread のnode id。inlineコメントで対応するスレッドが
#     見つかった場合のみ値を持つ。review/conversationコメントは常にnull。
#   - source: "review"（PR全体へのレビュー本体コメント。空bodyのレビューは除外する）/
#     "conversation"（PR会話タブ、行に紐付かない）/ "inline"（個別行コメント）。
#   - is_bot: is_bot_author() の判定結果（gh を呼ばない純粋関数として分離。テスト対象）。
#   - path/line/diff_hunk: inlineコメントのみ値を持つ。他はnull。
#   - is_resolved/is_outdated: inlineコメントで対応スレッドが見つかった場合のみそのスレッドの
#     値。他はfalse。
#
# owner/repo は `gh repo view --json owner,name` で解決する。
#
# 関数分離（テスト容易性のため）:
#   - gh を呼ぶ取得系関数: resolve_repo / fetch_reviews_json / fetch_conversation_json /
#     fetch_inline_json / fetch_review_threads_json / fetch_pr_files_json
#   - 取得済みJSON文字列から正規化配列を組み立てる純粋パース関数: normalize_comments /
#     build_diff_stat / is_bot_author
# パース関数はこのスクリプトを `source` してフィクスチャJSON（4つの入力JSON文字列）から
# 直接呼び出してテストできる（scripts/tests/test-fetch-pr-comments.sh）。
#
# gh呼び出しの失敗・jq不在は stderr にメッセージを出し、exit非0で終了する。
#
# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。

set -u

# jq の有無をチェックする。無ければ stderr にエラーメッセージ + エラーJSONを出す。
check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# author login からボット判定を行う純粋関数（gh を呼ばない）。
# [bot] サフィックス、または既知のAIレビュアーのlogin名にマッチすれば真(exit 0)を返す。
# 引数: login文字列
# 戻り値: 0=bot, 1=not bot
is_bot_author() {
  local login="${1:-}"

  case "$login" in
    *"[bot]")
      return 0
      ;;
  esac

  case "$login" in
    coderabbitai | coderabbit-ai | coderabbitai-io | sourcery-ai | greptile-apps | greptileai | korbit-ai | devin-ai-integration | graphite-app | codeium)
      return 0
      ;;
  esac

  return 1
}

# --- gh を呼ぶ取得系関数 ---

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

# 引数: PR番号
# 戻り値: stdout に `gh pr view --json reviews` の生JSON
fetch_reviews_json() {
  local pr="$1"
  gh pr view "$pr" --json reviews 2>/dev/null
}

# 引数: PR番号
# 戻り値: stdout に `gh pr view --json comments` の生JSON
fetch_conversation_json() {
  local pr="$1"
  gh pr view "$pr" --json comments 2>/dev/null
}

# 引数: PR番号, owner, repo
# 戻り値: stdout に `gh api repos/{owner}/{repo}/pulls/{pr}/comments` の生JSON（配列）
fetch_inline_json() {
  local pr="$1" owner="$2" repo="$3"
  gh api "repos/${owner}/${repo}/pulls/${pr}/comments" --paginate --slurp 2>/dev/null |
    jq -c '[.[][]]'
}

# 引数: PR番号, owner, repo
# 戻り値: stdout に GraphQL reviewThreads クエリの生JSON
fetch_review_threads_json() {
  local pr="$1" owner="$2" repo="$3"
  # shellcheck disable=SC2016 # GraphQLクエリ内の$owner/$repo/$prはGraphQL変数でありシェル展開の対象ではない
  gh api graphql -f query='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              isOutdated
              comments(first: 100) {
                nodes { databaseId }
              }
            }
          }
        }
      }
    }' -f owner="$owner" -f repo="$repo" -F pr="$pr" 2>/dev/null
}

# 引数: PR番号
# 戻り値: stdout に `gh pr view --json files` の生JSON
fetch_pr_files_json() {
  local pr="$1"
  gh pr view "$pr" --json files 2>/dev/null
}

# --- 純粋パース関数（gh を呼ばない） ---

# gh pr view --json files の出力から diff_stat 相当のコンパクトな文字列を組み立てる。
# 引数: files_json（{"files":[{"path":..., "additions":N, "deletions":N}, ...]}）
# 戻り値: stdout に "path | +N -M" 形式の行を改行連結した文字列
build_diff_stat() {
  local files_json="$1"
  jq -r '
    (.files // [])
    | map("\(.path) | +\(.additions // 0) -\(.deletions // 0)")
    | join("\n")
  ' <<<"$files_json"
}

# GraphQL reviewThreads の生JSONから、inlineコメントのdatabaseIdとの対応付けに使う
# 軽量lookup配列を組み立てる（gh を呼ばない）。
# 引数: threads_json
# 戻り値: stdout に [{threadId, isResolved, isOutdated, databaseIds: [...]}, ...]
build_threads_lookup() {
  local threads_json="$1"
  jq -c '
    [(.data.repository.pullRequest.reviewThreads.nodes // [])[]
     | {
         threadId: .id,
         isResolved: (.isResolved // false),
         isOutdated: (.isOutdated // false),
         databaseIds: [(.comments.nodes // [])[] | .databaseId]
       }
    ]
  ' <<<"$threads_json"
}

# 4経路の生JSONから正規化されたコメント配列を組み立てる（gh を呼ばない純粋関数）。
# 引数: reviews_json, conversation_json, inline_json, threads_json
# 結果: NORMALIZED_COMMENTS_JSON
normalize_comments() {
  local reviews_json="$1" conversation_json="$2" inline_json="$3" threads_json="$4"

  local threads_lookup
  threads_lookup=$(build_threads_lookup "$threads_json")
  if [ -z "$threads_lookup" ]; then
    threads_lookup="[]"
  fi

  # 空bodyのレビュー本体（APPROVE/REQUEST_CHANGESのみでコメント本文が無いもの）は
  # 返信対象が無いため除外する。
  local reviews_raw
  reviews_raw=$(jq -c '
    (.reviews // [])
    | map(select((.body // "") != ""))
    | map({
        id: (.id | tostring),
        threadId: null,
        source: "review",
        author: (.author.login // "unknown"),
        path: null,
        line: null,
        diff_hunk: null,
        body: .body,
        is_resolved: false,
        is_outdated: false
      })
    | .[]
  ' <<<"$reviews_json")

  local conversation_raw
  conversation_raw=$(jq -c '
    (.comments // [])
    | map({
        id: (.id | tostring),
        threadId: null,
        source: "conversation",
        author: (.author.login // "unknown"),
        path: null,
        line: null,
        diff_hunk: null,
        body: (.body // ""),
        is_resolved: false,
        is_outdated: false
      })
    | .[]
  ' <<<"$conversation_json")

  local inline_raw
  inline_raw=$(jq -c --argjson threads "$threads_lookup" '
    (. // [])
    | map(
        . as $c
        | ([$threads[] | select(.databaseIds | index($c.id))] | .[0]) as $t
        | {
            id: ($c.id | tostring),
            threadId: ($t.threadId // null),
            source: "inline",
            author: ($c.user.login // "unknown"),
            path: $c.path,
            line: ($c.line // $c.original_line // null),
            diff_hunk: $c.diff_hunk,
            body: ($c.body // ""),
            is_resolved: ($t.isResolved // false),
            is_outdated: ($t.isOutdated // false)
          }
      )
    | .[]
  ' <<<"$inline_json")

  local merged_lines=()
  local line author is_bot_bool merged
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    author=$(jq -r '.author' <<<"$line")
    if is_bot_author "$author"; then
      is_bot_bool="true"
    else
      is_bot_bool="false"
    fi
    merged=$(jq -c --argjson is_bot "$is_bot_bool" '. + {is_bot: $is_bot}' <<<"$line")
    merged_lines+=("$merged")
  done <<<"$(printf '%s\n%s\n%s\n' "$reviews_raw" "$conversation_raw" "$inline_raw")"

  if [ "${#merged_lines[@]}" -eq 0 ]; then
    NORMALIZED_COMMENTS_JSON="[]"
    return 0
  fi

  NORMALIZED_COMMENTS_JSON=$(printf '%s\n' "${merged_lines[@]}" | jq -s -c '.')
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <PR番号>" >&2
}

main() {
  local pr="${1:-}"

  if [ -z "$pr" ] || ! [[ "$pr" =~ ^[0-9]+$ ]]; then
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  if ! resolve_repo; then
    exit 1
  fi
  local owner="$REPO_OWNER" repo="$REPO_NAME"

  local reviews_json conversation_json inline_json threads_json files_json
  if ! reviews_json=$(fetch_reviews_json "$pr") || [ -z "$reviews_json" ]; then
    echo "Error: failed to fetch reviews for PR #${pr}" >&2
    exit 1
  fi
  if ! conversation_json=$(fetch_conversation_json "$pr") || [ -z "$conversation_json" ]; then
    echo "Error: failed to fetch conversation comments for PR #${pr}" >&2
    exit 1
  fi
  if ! inline_json=$(fetch_inline_json "$pr" "$owner" "$repo"); then
    echo "Error: failed to fetch inline comments for PR #${pr}" >&2
    exit 1
  fi
  if ! threads_json=$(fetch_review_threads_json "$pr" "$owner" "$repo") || [ -z "$threads_json" ]; then
    echo "Error: failed to fetch review threads for PR #${pr}" >&2
    exit 1
  fi
  if ! files_json=$(fetch_pr_files_json "$pr") || [ -z "$files_json" ]; then
    echo "Error: failed to fetch changed files for PR #${pr}" >&2
    exit 1
  fi

  normalize_comments "$reviews_json" "$conversation_json" "$inline_json" "$threads_json"
  local comments_json="$NORMALIZED_COMMENTS_JSON"

  local diff_stat
  diff_stat=$(build_diff_stat "$files_json")

  jq -n \
    --argjson pr "$pr" \
    --arg diff_stat "$diff_stat" \
    --argjson comments "$comments_json" \
    '{pr: $pr, diff_stat: $diff_stat, comments: $comments}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
