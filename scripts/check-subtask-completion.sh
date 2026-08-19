#!/bin/bash
# check-subtask-completion.sh
# 使い方: scripts/check-subtask-completion.sh <parent_issue_number>（詳細は下記参照）
# 仕様の正本は scripts/specs/collect-promotion-context.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# --- gh を呼ぶ関数 ---

# resolve_repo は lib/common.sh（scripts/lib/common.sh）に集約。

# フォールバック検索の明示上限。gh search issues は --limit 未指定だと既定30件で
# 黙って打ち切るため、必ず明示する。結果件数がこの上限に達した場合、main() は
# 打ち切りの可能性ありとして status: "fallback_truncated" を返す（件数=上限を
# 完全性の反証として扱う。仕様は scripts/specs/collect-promotion-context.md）。
CSC_FALLBACK_SEARCH_LIMIT=300

# Sub-issues API で子Issue一覧の生JSON配列を取得する。
# 引数: parent_issue, owner, repo
# 戻り値: stdout に生JSON配列。gh api が失敗（404等）した場合は非0を返す。
# per_page=100 を明示する（既定30では31件以上の子が黙って欠落する）。GitHub の
# sub-issues は親1件あたり最大100件のため、100を明示すれば1ページで全件になる。
fetch_sub_issues_json() {
  local parent="$1" owner="$2" repo="$3"
  gh api "repos/${owner}/${repo}/issues/${parent}/sub_issues?per_page=100" 2>/dev/null
}

# "Parent: #<parent>" を本文に含むIssueを検索する（フォールバック経路）。
# 引数: parent_issue, owner, repo
# 戻り値: stdout に生JSON配列（number, title, state）。
fetch_fallback_issues_json() {
  local parent="$1" owner="$2" repo="$3"
  gh search issues "Parent: #${parent} in:body" --repo "${owner}/${repo}" \
    --limit "$CSC_FALLBACK_SEARCH_LIMIT" --json number,title,state 2>/dev/null
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
  # 各取得経路が「照会に成功した」（gh が成功し、出力を正規化できた。結果が空配列で
  # あることは成功に含む）かどうかを記録する。0件の結果を「検査した結果の0件」
  # （no_children_found）と「検査不能」（children_lookup_failed）に区別するための入力。
  local sub_lookup_ok="false" fallback_lookup_ok="false"

  local sub_raw
  if sub_raw=$(fetch_sub_issues_json "$parent" "$owner" "$repo"); then
    local normalized
    normalized=$(normalize_sub_issues_json "$sub_raw")
    if [ -n "$normalized" ]; then
      sub_lookup_ok="true"
      if [ "$(jq 'length' <<<"$normalized" 2>/dev/null)" != "0" ]; then
        source="sub_issues_api"
        children_json="$normalized"
      fi
    fi
  fi

  # sub_issues_api経路で子が得られなかった（gh api失敗、または空配列）場合はフォールバックへ。
  if [ -z "$source" ]; then
    # フォールバックは常に最終的に採用された経路として source に記録する
    # （フォールバックも空だった場合を含む。「見つからなかった」という事実そのものは、
    # 後段の status が明示するため、source はどの経路を最後に試みたかの記録に留める）。
    source="parent_label_fallback"
    local fallback_raw
    if fallback_raw=$(fetch_fallback_issues_json "$parent" "$owner" "$repo"); then
      local normalized_fb
      normalized_fb=$(normalize_fallback_issues_json "$fallback_raw")
      if [ -n "$normalized_fb" ]; then
        fallback_lookup_ok="true"
        if [ "$(jq 'length' <<<"$normalized_fb" 2>/dev/null)" != "0" ]; then
          children_json="$normalized_fb"
        fi
      fi
    fi
  fi

  local status="ok"
  local final_children="[]"
  local children_count
  children_count="$(jq 'length' <<<"$children_json" 2>/dev/null)"
  [ -z "$children_count" ] && children_count="0"

  if [ "$children_count" = "0" ]; then
    # 0件は「検査した結果の0件」と「検査不能」を区別する。no_children_found を名乗れる
    # のは両経路（sub-issues API と本文検索）が照会に成功したうえでの0件だけ。どちらか
    # の照会が失敗した0件は children_lookup_failed とし、「子がいない」ことの証明に
    # 使わせない（一時的な取得失敗を『未分解』『サブタスクなし』へ黙って丸めない）。
    if [ "$sub_lookup_ok" = "true" ] && [ "$fallback_lookup_ok" = "true" ]; then
      status="no_children_found"
    else
      status="children_lookup_failed"
    fi
    final_children="[]"
  else
    # フォールバック検索の結果件数が明示上限に達した場合、それより多い子が
    # 打ち切られている可能性があり、この一覧を「全子」として扱えない（件数=上限は
    # 完全性の反証）。children は取得分をそのまま返すが、mergedPr の判定は行わず
    # （不完全な一覧に対する判定は無意味なため）、allMerged は false のままにする。
    if [ "$source" = "parent_label_fallback" ] && [ "$children_count" -ge "$CSC_FALLBACK_SEARCH_LIMIT" ]; then
      status="fallback_truncated"
    fi
    local idx number title state entry merged_pr
    for ((idx = 0; idx < children_count; idx++)); do
      number=$(jq -r ".[$idx].number" <<<"$children_json")
      title=$(jq -r ".[$idx].title" <<<"$children_json")
      state=$(jq -r ".[$idx].state" <<<"$children_json")
      merged_pr=""
      if [ "$status" = "ok" ] && [ "$state" = "CLOSED" ]; then
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
