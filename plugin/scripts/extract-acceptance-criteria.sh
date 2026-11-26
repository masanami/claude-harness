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
# チェックリスト行を抽出し、結果をグローバル変数 PARSE_STATUS / CRITERIA_JSON /
# EXCLUDED_HEADINGS_JSON に格納する。
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
  #
  # 基準ごとの節（section）と小見出し（subheading）を控えるため、awk は行の種別を先頭2文字で
  # 示して出す（#423）: "S " = 節の開始（後ろは節の名前）、"H " = 節の中の "### " 見出し
  # （後ろは見出しの文）、"L " = それ以外の行（後ろは行そのまま）。
  # 節の名前は awk の文字列比較で決めず、正規表現の一致した規則の中で定数として出す
  # （macOS 標準 awk は非 ASCII 文字列の `==` を誤って真にする。scripts/README.md「テスト」節）。
  # "#### " より深い見出しは "L " のまま流し、直近の "### " の小見出しに含める。
  local section
  section=$(printf '%s\n' "$body" | awk '
    /^## 受入基準[[:space:]]*$/ { capture=1; print "S 受入基準"; next }
    /^## 完了条件[[:space:]]*$/ { capture=1; print "S 完了条件"; next }
    /^## / { capture=0 }
    capture && /^###([[:space:]]|$)/ {
      heading=$0
      sub(/^###[[:space:]]*/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      print "H " heading
      next
    }
    capture { print "L " $0 }
  ')

  # 見出しは完全一致だけを抽出対象にする。括弧付きの見出し（「## 受入基準（S2）」等）は
  # 対象外だが、0 件で止まったときに原因が読めるよう、見出し行を控えて報告に出す（#273）。
  local excluded_headings_json
  excluded_headings_json=$(printf '%s\n' "$body" | awk '
    /^## (受入基準|完了条件)[[:space:]]*(（|\()/ { print }
  ' | jq -R -s -c 'split("\n") | map(select(length > 0))')

  local criteria_json="[]"
  local idx=0
  local status="no_checklist_found"
  local line mark text id checked
  # 節の名前（"受入基準" | "完了条件"）と、直近の "### " 見出しの文（JSON の値。無ければ null）。
  local current_section=""
  local current_subheading_json="null"

  while IFS= read -r line; do
    case "$line" in
      "S "*)
        current_section="${line#S }"
        # 節が変わったら小見出しを引き継がない（前の節の小見出しは次の節の基準に付けない）。
        current_subheading_json="null"
        continue
        ;;
      "H "*)
        # 見出しの文が空（"###" だけ。行末の空白の有無は問わない）のときは小見出し無し（null）に戻す。
        if [ -n "${line#H }" ]; then
          current_subheading_json=$(jq -n -c --arg h "${line#H }" '$h')
        else
          current_subheading_json="null"
        fi
        continue
        ;;
      "L "*) line="${line#L }" ;;
      *) continue ;;
    esac
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
      # 既存の項目（id・text・checked）の形は変えず、section・subheading を足すだけにする
      # （check-e2e-traceability.sh・/create-e2e など、ほかの利用者が id・text を読んでいる）。
      criteria_json=$(jq -c --arg id "$id" --arg text "$text" --argjson checked "$checked" \
        --arg section "$current_section" --argjson subheading "$current_subheading_json" \
        '. + [{"id": $id, "text": $text, "checked": $checked, "section": $section, "subheading": $subheading}]' <<<"$criteria_json")
      status="ok"
    fi
  done <<<"$section"

  PARSE_STATUS="$status"
  CRITERIA_JSON="$criteria_json"
  EXCLUDED_HEADINGS_JSON="$excluded_headings_json"
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
    --argjson excluded "$EXCLUDED_HEADINGS_JSON" \
    '{issue: $issue, criteria: $criteria, parse_status: $status, excluded_headings: $excluded}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
