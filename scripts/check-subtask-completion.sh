#!/bin/bash
# check-subtask-completion.sh
# skills/promote-verify/SKILL.md（Step 3）が Bash ツールで直接実行する決定的スクリプト
# （Issue #110 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し、呼び出し元自身の
# 直接実行に一本化した）。統合ブランチ→main 昇格前検証パッケージの一部として、親Issueの
# 全サブタスク（子Issue）がマージ済みかを機械的に判定する（Issue #52）。
#
# 使い方:
#   scripts/check-subtask-completion.sh <parent_issue_number>
#
# 取得経路（優先順）:
#   1. sub_issues_api: GitHub の Sub-issues API
#      (`gh api repos/{owner}/{repo}/issues/{parent}/sub_issues`) で子Issue一覧を取得する。
#      成功（HTTPエラーでない）かつ非空配列を返せばこの経路を採用する。
#   2. parent_label_fallback: 上記が失敗（404等。Sub-issues APIが未有効化のリポジトリ等）または
#      空配列の場合のフォールバック。Issue本文に "Parent: #<parent>" という文字列を含む
#      Issueを `gh search issues` で検索する。
#
# 各子Issueのマージ済み判定（「merged PRとの突合」）:
#   子Issueの state が CLOSED であることに加えて、その子Issueをcloseした merged PR が
#   実在することを `gh search prs --state merged "#<child> in:body"` で確認する
#   （見つかった最初のPR番号を mergedPr とする）。
#
# 出力（stdout にJSON1個）:
#   {
#     "parent": 52,
#     "source": "sub_issues_api" | "parent_label_fallback",
#     "status": "ok" | "no_children_found",
#     "children": [{"number": 60, "title": "...", "state": "CLOSED", "mergedPr": 61 | null}],
#     "allMerged": true | false
#   }
#
# 「子Issueが1件も見つからなかった」場合は status: "no_children_found" を明示し、children は
# 空配列、allMerged は暗黙にtrueにせず false とする（scripts/README.md の出力規約:
# 「特定できなかった」「対象外だった」は暗黙の空配列・空文字ではなく明示的なステータス
# フィールドで返す。空集合に対する論理的な真=trueの罠を避ける安全側の設計判断）。
#
# allMerged は children が非空、かつ全要素が state == "CLOSED" かつ mergedPr が非nullの場合のみ true。
#
# 関数分離（テスト容易性のため。scripts/README.md「外部呼び出し関数をテストからスタブ関数で
# 上書きする」方針に従う）:
#   - gh を呼ぶ関数: resolve_repo / fetch_sub_issues_json / fetch_fallback_issues_json /
#     fetch_merged_pr_number
#   - 純粋関数: normalize_sub_issues_json / normalize_fallback_issues_json / build_child_entry /
#     compute_all_merged
# テストからは gh を呼ぶ関数をスタブ関数で上書きしたうえで main() を呼び出し、
# sub_issues_api経路/フォールバック経路/子Issue0件/一部未マージの各分岐を検証する
# （scripts/tests/test-check-subtask-completion.sh。fetch-pr-comments.sh / reply-and-resolve.sh
# のテスト方針と同じ）。
#
# main() はテスト容易性のため exit を直接呼ばず、常に return で終了コード相当の値を返す
# （このファイルが直接実行された場合のみ、末尾の呼び出しが main の戻り値で実際に exit する。
# reply-and-resolve.sh と同じパターン）。
#
# gh呼び出し自体の失敗（owner/repo解決失敗等）・jq不在は stderr にメッセージを出し、
# exit非0で終了する（sub_issues_api/フォールバック双方の「結果が空」はエラーではなく
# no_children_found として正常終了する点に注意）。
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

# Sub-issues API で子Issue一覧の生JSON配列を取得する。
# 引数: parent_issue, owner, repo
# 戻り値: stdout に生JSON配列。gh api が失敗（404等）した場合は非0を返す。
fetch_sub_issues_json() {
  local parent="$1" owner="$2" repo="$3"
  gh api "repos/${owner}/${repo}/issues/${parent}/sub_issues" 2>/dev/null
}

# "Parent: #<parent>" を本文に含むIssueを検索する（フォールバック経路）。
# 引数: parent_issue, owner, repo
# 戻り値: stdout に生JSON配列（number, title, state）。
fetch_fallback_issues_json() {
  local parent="$1" owner="$2" repo="$3"
  gh search issues "Parent: #${parent} in:body" --repo "${owner}/${repo}" --json number,title,state 2>/dev/null
}

# 子Issueをcloseした merged PR の番号を検索する。見つからなければ空文字を返す。
# 引数: child_issue_number, owner, repo
# 戻り値: stdout にPR番号（見つかった最初の1件）、または空文字
fetch_merged_pr_number() {
  local child="$1" owner="$2" repo="$3"
  gh search prs --repo "${owner}/${repo}" --state merged "#${child} in:body" --json number --jq '.[0].number // empty' 2>/dev/null
}

# --- 純粋関数（gh を呼ばない） ---

# sub_issues API の生JSON配列を {number, title, state(大文字)} 配列へ正規化する。
# 引数: raw_json
# 戻り値: stdout に正規化済みJSON配列（パース失敗時は空文字）
normalize_sub_issues_json() {
  local raw="$1"
  jq -c '[.[] | {number: .number, title: .title, state: (.state | ascii_upcase)}]' <<<"$raw" 2>/dev/null
}

# フォールバック検索結果の生JSON配列を {number, title, state(大文字)} 配列へ正規化する。
# 引数: raw_json
# 戻り値: stdout に正規化済みJSON配列（パース失敗時は空文字）
normalize_fallback_issues_json() {
  local raw="$1"
  jq -c '[.[] | {number: .number, title: .title, state: (.state | ascii_upcase)}]' <<<"$raw" 2>/dev/null
}

# 1件の子Issueエントリを組み立てる。
# 引数: number, title, state, merged_pr（空文字なら未検出=null）
# 戻り値: stdout にJSONオブジェクト
build_child_entry() {
  local number="$1" title="$2" state="$3" merged_pr="$4"
  if [ -n "$merged_pr" ]; then
    jq -n --argjson number "$number" --arg title "$title" --arg state "$state" --argjson mergedPr "$merged_pr" \
      '{number: $number, title: $title, state: $state, mergedPr: $mergedPr}'
  else
    jq -n --argjson number "$number" --arg title "$title" --arg state "$state" \
      '{number: $number, title: $title, state: $state, mergedPr: null}'
  fi
}

# children配列（mergedPr込み）から allMerged を判定する。
# 空配列は常にfalse（呼び出し元は status: "no_children_found" 時にこの関数を呼ばない）。
# 引数: children_json
# 戻り値: 0=true(全件マージ済み), 1=false
compute_all_merged() {
  local children_json="$1"
  jq -e 'length > 0 and (map(.state == "CLOSED" and .mergedPr != null) | all)' <<<"$children_json" >/dev/null 2>&1
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <parent_issue_number>" >&2
}

main() {
  local parent="${1:-}"

  if [ -z "$parent" ] || ! [[ "$parent" =~ ^[0-9]+$ ]]; then
    print_usage
    return 1
  fi

  if ! check_jq; then
    return 1
  fi

  if ! resolve_repo; then
    return 1
  fi
  local owner="$REPO_OWNER" repo="$REPO_NAME"

  local source="" children_json="[]"

  local sub_raw
  if sub_raw=$(fetch_sub_issues_json "$parent" "$owner" "$repo"); then
    local normalized
    normalized=$(normalize_sub_issues_json "$sub_raw")
    if [ -n "$normalized" ] && [ "$(jq 'length' <<<"$normalized" 2>/dev/null)" != "0" ]; then
      source="sub_issues_api"
      children_json="$normalized"
    fi
  fi

  # sub_issues_api経路が使えなかった（gh api失敗、または空配列）場合はフォールバックへ。
  if [ -z "$source" ]; then
    # フォールバックは常に最終的に採用された経路として source に記録する
    # （フォールバックも空だった場合を含む。「見つからなかった」という事実そのものは、
    # 後段の status: no_children_found が明示するため、source はどの経路を最後に
    # 試みたかの記録に留める）。
    source="parent_label_fallback"
    local fallback_raw
    if fallback_raw=$(fetch_fallback_issues_json "$parent" "$owner" "$repo"); then
      local normalized_fb
      normalized_fb=$(normalize_fallback_issues_json "$fallback_raw")
      if [ -n "$normalized_fb" ] && [ "$(jq 'length' <<<"$normalized_fb" 2>/dev/null)" != "0" ]; then
        children_json="$normalized_fb"
      fi
    fi
  fi

  local status="ok"
  local final_children="[]"
  local children_count
  children_count="$(jq 'length' <<<"$children_json" 2>/dev/null)"
  [ -z "$children_count" ] && children_count="0"

  if [ "$children_count" = "0" ]; then
    status="no_children_found"
    final_children="[]"
  else
    local idx number title state entry merged_pr
    for ((idx = 0; idx < children_count; idx++)); do
      number=$(jq -r ".[$idx].number" <<<"$children_json")
      title=$(jq -r ".[$idx].title" <<<"$children_json")
      state=$(jq -r ".[$idx].state" <<<"$children_json")
      merged_pr=""
      if [ "$state" = "CLOSED" ]; then
        merged_pr=$(fetch_merged_pr_number "$number" "$owner" "$repo")
      fi
      entry=$(build_child_entry "$number" "$title" "$state" "$merged_pr")
      final_children=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$final_children")
    done
  fi

  local all_merged="false"
  if [ "$status" = "ok" ] && compute_all_merged "$final_children"; then
    all_merged="true"
  fi

  jq -n \
    --argjson parent "$parent" \
    --arg source "$source" \
    --arg status "$status" \
    --argjson children "$final_children" \
    --argjson allMerged "$all_merged" \
    '{parent: $parent, source: $source, status: $status, children: $children, allMerged: $allMerged}'

  return 0
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
