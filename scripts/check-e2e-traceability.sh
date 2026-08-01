#!/bin/bash
# check-e2e-traceability.sh
# 使い方: scripts/check-e2e-traceability.sh <criteria_json_file|-> <trace_json_file|->（詳細は下記参照）
# 仕様の正本は scripts/specs/extract-acceptance-criteria.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# criteria JSON と trace JSON の文字列を受け取り、突合結果をグローバル変数 RESULT_JSON に格納する。
# 外部コマンドを呼ばない純粋関数（jq のみ使用、gh 等は呼ばない）。
#
# 使い方:
#   check_traceability "$criteria_json_str" "$trace_json_str"
# 戻り値: 不正な入力（JSONとして壊れている・必須キー欠如）の場合は非0を返し、stderrにメッセージを出す。
check_traceability() {
  local criteria_str="$1"
  local trace_str="$2"

  if ! jq -e . >/dev/null 2>&1 <<<"$criteria_str"; then
    echo "Error: criteria JSON is not valid JSON" >&2
    return 1
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$trace_str"; then
    echo "Error: trace JSON is not valid JSON" >&2
    return 1
  fi

  if ! jq -e 'has("criteria")' >/dev/null 2>&1 <<<"$criteria_str"; then
    echo "Error: criteria JSON is missing required key 'criteria'" >&2
    return 1
  fi
  if ! jq -e '.criteria | type == "array"' >/dev/null 2>&1 <<<"$criteria_str"; then
    echo "Error: criteria JSON's 'criteria' key must be an array" >&2
    return 1
  fi
  if ! jq -e 'has("cases")' >/dev/null 2>&1 <<<"$trace_str"; then
    echo "Error: trace JSON is missing required key 'cases'" >&2
    return 1
  fi
  if ! jq -e '.cases | type == "array"' >/dev/null 2>&1 <<<"$trace_str"; then
    echo "Error: trace JSON's 'cases' key must be an array" >&2
    return 1
  fi
  if ! jq -e '
    all(.criteria[];
      (type == "object") and
      (.id? | type == "string") and
      (.text? | type == "string")
    )
  ' >/dev/null 2>&1 <<<"$criteria_str"; then
    echo "Error: each criterion in criteria JSON must be an object with string 'id' and 'text' fields" >&2
    return 1
  fi
  if ! jq -e '
    all(.cases[];
      (type == "object") and
      ((.criteria? | type) == "array") and
      all(.criteria[]; type == "string")
    )
  ' >/dev/null 2>&1 <<<"$trace_str"; then
    echo "Error: each case in trace JSON must be an object with a 'criteria' array of strings" >&2
    return 1
  fi

  local parse_status criteria_count
  parse_status="$(jq -r '.parse_status // "ok"' <<<"$criteria_str")"
  criteria_count="$(jq '.criteria | length' <<<"$criteria_str")"

  if [ "$parse_status" = "no_checklist_found" ] || [ "$criteria_count" -eq 0 ]; then
    RESULT_JSON='{"uncovered":[],"unknown_ids":[],"status":"no_criteria"}'
    return 0
  fi

  # trace 側の全 case.criteria を1つの配列（重複含む）にまとめる
  local covered_ids
  covered_ids="$(jq -c '[.cases[].criteria[]?]' <<<"$trace_str")"

  # uncovered: criteria 側にあって covered_ids に登場しないもの（id/textを保持）
  local uncovered
  uncovered="$(jq -c --argjson covered "$covered_ids" \
    '[.criteria[] | select(.id as $id | ($covered | index($id)) | not) | {id: .id, text: .text}]' \
    <<<"$criteria_str")"

  # unknown_ids: covered_ids にあって criteria 側の id 集合に存在しないもの（重複除去）
  local known_ids
  known_ids="$(jq -c '[.criteria[].id]' <<<"$criteria_str")"
  local unknown_ids
  unknown_ids="$(jq -n -c --argjson known "$known_ids" --argjson covered "$covered_ids" \
    '[$covered[] | select(. as $id | ($known | index($id)) | not)] | unique')"

  local status
  if [ "$(jq 'length' <<<"$uncovered")" -eq 0 ] && [ "$(jq 'length' <<<"$unknown_ids")" -eq 0 ]; then
    status="ok"
  else
    status="issues_found"
  fi

  RESULT_JSON="$(jq -n --argjson uncovered "$uncovered" --argjson unknown_ids "$unknown_ids" --arg status "$status" \
    '{uncovered: $uncovered, unknown_ids: $unknown_ids, status: $status}')"
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <criteria_json_file|-> <trace_json_file|->" >&2
  echo "       criteria_json_file: extract-acceptance-criteria.sh の出力JSONファイル、または - でstdin" >&2
  echo "       trace_json_file:    テストケース設計のトレーサビリティ表JSONファイル、または - でstdin" >&2
  echo "       両方を同時に - にすることはできない" >&2
}

# 引数（ファイルパスまたは "-"）から内容を読み込む。存在しないファイルは非0を返す。
read_input() {
  local arg="$1"
  if [ "$arg" = "-" ]; then
    cat
    return 0
  fi
  if [ ! -f "$arg" ]; then
    echo "Error: file not found: ${arg}" >&2
    return 1
  fi
  cat "$arg"
}

main() {
  if [ "$#" -ne 2 ]; then
    print_usage
    exit 1
  fi

  local criteria_arg="$1"
  local trace_arg="$2"

  if [ "$criteria_arg" = "-" ] && [ "$trace_arg" = "-" ]; then
    echo "Error: cannot read both arguments from stdin" >&2
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  local criteria_str trace_str
  if ! criteria_str="$(read_input "$criteria_arg")"; then
    exit 1
  fi
  if ! trace_str="$(read_input "$trace_arg")"; then
    exit 1
  fi

  if ! check_traceability "$criteria_str" "$trace_str"; then
    exit 1
  fi

  printf '%s\n' "$RESULT_JSON"
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
