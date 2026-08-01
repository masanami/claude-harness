#!/bin/bash
# extract-acceptance-criteria.sh
# 使い方: scripts/extract-acceptance-criteria.sh <issue番号|--stdin>（詳細は下記参照）
# 仕様の正本は scripts/specs/extract-acceptance-criteria.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# gh issue view で Issue 本文を取得する。
# 引数: Issue番号
# 戻り値: 本文テキストを stdout に出力（呼び出し側で $() キャプチャする）。失敗時は非0を返す。
fetch_issue_body() {
  local issue_num="$1"
  local output stderr_file
  # stderr を stdout に混ぜない: gh が成功時に出す警告（rate limit 通知等）が
  # 本文に混入するとセクション誤認の silent failure になるため、別ファイルに分離する。
  stderr_file="$(mktemp)"
  if ! output=$(gh issue view "$issue_num" --json body -q .body 2>"$stderr_file"); then
    echo "Error: failed to fetch issue #${issue_num} via gh: $(cat "$stderr_file")" >&2
    rm -f "$stderr_file"
    return 1
  fi
  rm -f "$stderr_file"
  printf '%s' "$output"
}

# 本文テキストから「## 受入基準」「## 完了条件」セクション配下の
# チェックリスト行を抽出し、結果をグローバル変数 PARSE_STATUS / CRITERIA_JSON に格納する。
# gh を呼ばない純粋関数。引数または stdin で本文テキストを受け取る。
#
# 使い方:
#   parse_acceptance_criteria "$body_text"
#   echo "$body_text" | parse_acceptance_criteria
parse_acceptance_criteria() {
  local body
  if [ "$#" -ge 1 ]; then
    body="$1"
  else
    body="$(cat)"
  fi

  # gh issue view --json body はCRLF改行の本文を返すことがある。
  # \r を残したままだと各行末の text に \r が混入するため、先に正規化する。
  body="${body//$'\r'/}"

  # 「## 受入基準」または「## 完了条件」セクション配下の行だけを抜き出す。
  # 次の "## " 見出しが来たらキャプチャを止める。
  # 両方のセクションが同一本文に存在する場合は連番で通しIDを振る（意図的な仕様）。
  # インデント付き（ネストした）チェックリスト行は対象外（列0の "- [ ]"/"- [x]" のみ抽出）。
  local section
  section=$(printf '%s\n' "$body" | awk '
    /^## (受入基準|完了条件)[[:space:]]*$/ { capture=1; next }
    /^## / { capture=0 }
    capture { print }
  ')

  local criteria_json="[]"
  local idx=0
  local status="no_checklist_found"
  local line mark text id checked

  while IFS= read -r line; do
    if [[ "$line" =~ ^-\ \[([xX\ ])\][[:space:]]+(.+)$ ]]; then
      idx=$((idx + 1))
      mark="${BASH_REMATCH[1]}"
      text="${BASH_REMATCH[2]}"
      if [ "$mark" = "x" ] || [ "$mark" = "X" ]; then
        checked=true
      else
        checked=false
      fi
      id="AC-${idx}"
      criteria_json=$(jq -c --arg id "$id" --arg text "$text" --argjson checked "$checked" \
        '. + [{"id": $id, "text": $text, "checked": $checked}]' <<<"$criteria_json")
      status="ok"
    fi
  done <<<"$section"

  PARSE_STATUS="$status"
  CRITERIA_JSON="$criteria_json"
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <issue番号>" >&2
  echo "       ${prog} --stdin   (本文をstdinから読み込む。gh を呼ばない。issueはnullとして出力。テスト・デバッグ用)" >&2
}

main() {
  local arg="${1:-}"

  if [ -z "$arg" ]; then
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  local issue_json="null"
  local body

  if [ "$arg" = "--stdin" ]; then
    body="$(cat)"
  else
    if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
      echo "Error: issue number must be numeric, got '${arg}'" >&2
      print_usage
      exit 1
    fi
    issue_json="$arg"
    if ! body="$(fetch_issue_body "$arg")"; then
      exit 1
    fi
  fi

  parse_acceptance_criteria "$body"

  jq -n --argjson issue "$issue_json" --argjson criteria "$CRITERIA_JSON" --arg status "$PARSE_STATUS" \
    '{issue: $issue, criteria: $criteria, parse_status: $status}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
