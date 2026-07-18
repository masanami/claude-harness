#!/bin/bash
# create-debt-issues.sh
# skills/reduce-debt/SKILL.md Step 5（修正Issueの起票）のための決定的スクリプト。
# ユーザー承認済みの manifest JSON（負債項目の配列）を受け取り、各項目を
# `gh issue create --label tech-debt` で一括起票し、manifestのindexとissue番号/URLの
# 対応表JSONを返す。
#
# 背景: Issue #55 では Workflow(pipeline) 化を不採用とし、本スクリプトによる
# 決定的な一括起票で「1:1対応の構造保証・wall-clock短縮・コンテキスト削減」を達成する。
# 粒度判定（分割/統合すべきか）はリード（LLM）が行い、本スクリプトは
# targetFiles件数の機械的カウントによる警告付与のみを行う（起票は止めない）。
#
# 使い方:
#   scripts/create-debt-issues.sh <manifest.jsonファイルパス>
#
# manifest.json の形式（配列）:
#   [
#     {
#       "title": "...",
#       "parentRef": "元の親Issue番号への参照（例: #12）または既存負債である旨の説明",
#       "targetFiles": ["path/to/file1", "path/to/file2"],
#       "problem": "現状の問題点",
#       "expectedState": "期待する改善後の状態",
#       "priority": "高/中/低（任意。未指定なら本文の「## 優先度」セクション自体を省略する）"
#     },
#     ...
#   ]
#
# 出力（stdout にJSON1個）:
#   {
#     "results": [
#       {"index": 0, "status": "created", "issueNumber": 123, "issueUrl": "https://..."},
#       {"index": 1, "status": "created", "issueNumber": 124, "issueUrl": "https://...", "warning": "target_files_exceeds_threshold"},
#       {"index": 2, "status": "failed", "error": "..."}
#     ],
#     "createdCount": 2,
#     "failedCount": 1
#   }
#
# exit code: 全件 created なら 0。1件でも failed があれば 1（JSONはどちらの場合もstdoutに出す）。
# manifest 検証（必須フィールドの有無等）とテンプレート適用（本文組み立て）は gh を呼ばない
# 純粋関数として分離している（extract-acceptance-criteria.sh の
# fetch_issue_body / parse_acceptance_criteria の分離パターンを踏襲）。
# gh 呼び出しは create_github_issue() でラップしており、テストではこの関数を
# 上書き定義することでモック化できる。
#
# 部分失敗時の再実行: 対応表JSONの status: "failed" の項目だけを集めた
# 新しいmanifestを作り、本スクリプトを再度呼び出せばよい（凝った差分適用機構は持たない）。
#
# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。

set -u

# 粒度ヒューリスティックの閾値。targetFilesの件数がこれを超える項目には
# 対応表の結果に warning フィールドを付ける（起票は止めない。機械的カウントのみ）。
TARGET_FILES_WARNING_THRESHOLD=5

# jq の有無をチェックする。無ければ stderr にエラーメッセージ + エラーJSONを出す。
check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# 1件のmanifest項目（JSONオブジェクト文字列）の必須フィールドを検証する。gh を呼ばない純粋関数。
# 引数: item_json（JSONオブジェクト文字列）
# 結果: ITEM_VALIDATION_STATUS ("ok" | "invalid"), ITEM_VALIDATION_ERROR (エラーメッセージ or 空文字)
validate_manifest_item() {
  local item_json="$1"
  local missing=()
  local field

  # title/parentRef/problem/expectedState は「非空文字列」であることを要求する。
  # jq -r '.field // empty' だけだとオブジェクト等の非文字列値もJSON表現の非空文字列として
  # 通過してしまう（例: title:{} が "{}" という非空文字列扱いになる）ため、
  # type == "string" を明示的に検証する。
  for field in title parentRef problem expectedState; do
    if ! jq -e --arg f "$field" \
      '(.[$f] // null) | (type == "string") and (length > 0)' \
      <<<"$item_json" >/dev/null 2>&1; then
      missing+=("$field")
    fi
  done

  # targetFiles は「非空配列であり、かつ全要素が非空文字列」であることを要求する。
  if ! jq -e \
    '(.targetFiles // null) as $tf
     | ($tf | type) == "array"
     and ($tf | length) > 0
     and ($tf | all(.[]; (type == "string") and (length > 0)))' \
    <<<"$item_json" >/dev/null 2>&1; then
    missing+=("targetFiles")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    ITEM_VALIDATION_STATUS="ok"
    ITEM_VALIDATION_ERROR=""
  else
    ITEM_VALIDATION_STATUS="invalid"
    local joined
    joined=$(
      IFS=,
      echo "${missing[*]}"
    )
    ITEM_VALIDATION_ERROR="missing required field(s): ${joined}"
  fi
}

# 検証済みのmanifest項目からIssue本文を組み立てる。gh を呼ばない純粋関数。
# 引数: item_json（JSONオブジェクト文字列）
# 結果: ISSUE_BODY（本文テキスト）
# skills/reduce-debt/SKILL.md Step5が定める「子Issue本文に含めるべき要素」
# （元の親Issue番号への参照 / 対象ファイル・モジュール / 現状の問題点 / 期待する改善後の状態）に対応する。
build_issue_body() {
  local item_json="$1"
  local parentRef problem expectedState files_md priority priority_section

  parentRef=$(jq -r '.parentRef' <<<"$item_json")
  problem=$(jq -r '.problem' <<<"$item_json")
  expectedState=$(jq -r '.expectedState' <<<"$item_json")
  files_md=$(jq -r '.targetFiles[] | "- " + .' <<<"$item_json")
  # priority は任意フィールド。未指定（null/空文字）なら「## 優先度」セクション自体を省略する。
  priority=$(jq -r '.priority // empty' <<<"$item_json")

  priority_section=""
  if [ -n "$priority" ]; then
    priority_section="

## 優先度

${priority}"
  fi

  ISSUE_BODY="## 元Issue・既存負債の参照

${parentRef}

## 対象ファイル・モジュール

${files_md}

## 現状の問題点

${problem}

## 期待する改善後の状態

${expectedState}${priority_section}"
}

# 粒度ヒューリスティック: targetFilesの件数が閾値を超えるかを機械的にチェックする。
# LLMによる粒度批評は行わない（コード側の機械的カウントのみ）。起票を止める判断はしない。
# 引数: item_json（JSONオブジェクト文字列）
# 結果: GRANULARITY_WARNING（"target_files_exceeds_threshold" または空文字）
check_granularity_warning() {
  local item_json="$1"
  local count
  count=$(jq '.targetFiles | if type == "array" then length else 0 end' <<<"$item_json")

  if [ "${count:-0}" -gt "$TARGET_FILES_WARNING_THRESHOLD" ]; then
    GRANULARITY_WARNING="target_files_exceeds_threshold"
  else
    GRANULARITY_WARNING=""
  fi
}

# gh呼び出しラッパー。テストではこの関数を上書き定義してモック化する。
# 引数: title body
# 標準出力: 作成されたIssueのURL（gh issue createのデフォルト出力）
create_github_issue() {
  local title="$1"
  local body="$2"
  gh issue create --label tech-debt --title "$title" --body "$body"
}

# Issue URLからIssue番号を抽出する純粋関数（例: ".../issues/123" -> "123"）。
# create_github_issue の出力が複数行（gh の tip/警告メッセージ等の混入）であっても、
# 「.../issues/N」形式のURL行だけを対象にし、その末尾の数字のみを拾う
# （単純に全行の末尾数字を拾うと、警告行に含まれる無関係な数字を issue 番号と誤認する）。
extract_issue_number_from_url() {
  local url="$1"
  echo "$url" | grep -oE '/issues/[0-9]+[[:space:]]*$' | tail -n1 | grep -oE '[0-9]+'
}

# 1件のmanifest項目を処理する（検証 -> 本文組み立て -> 粒度チェック -> gh起票）。
# 引数: index（manifest配列内のインデックス） item_json（JSONオブジェクト文字列）
# 結果: ITEM_RESULT_JSON（この項目に対応する結果オブジェクトJSON）
process_manifest_item() {
  local index="$1"
  local item_json="$2"

  validate_manifest_item "$item_json"
  if [ "$ITEM_VALIDATION_STATUS" != "ok" ]; then
    ITEM_RESULT_JSON=$(jq -n --argjson index "$index" --arg error "$ITEM_VALIDATION_ERROR" \
      '{index: $index, status: "failed", error: $error}')
    return
  fi

  build_issue_body "$item_json"
  check_granularity_warning "$item_json"

  local title
  title=$(jq -r '.title' <<<"$item_json")

  # gh の stderr を stdout に混ぜない: URL（issueUrlとして扱う値）にエラーメッセージが
  # 混入すると issue番号のパース誤りという silent failure になるため、別ファイルに分離する。
  local create_output create_exit stderr_file
  stderr_file="$(mktemp)"
  if create_output=$(create_github_issue "$title" "$ISSUE_BODY" 2>"$stderr_file"); then
    create_exit=0
  else
    create_exit=$?
  fi
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  rm -f "$stderr_file"

  if [ "$create_exit" -ne 0 ]; then
    local err_msg="$stderr_content"
    [ -z "$err_msg" ] && err_msg="$create_output"
    ITEM_RESULT_JSON=$(jq -n --argjson index "$index" --arg error "$err_msg" \
      '{index: $index, status: "failed", error: $error}')
    return
  fi

  # gh の正常終了時stdoutにURL行以外の出力（tip等）が混じっていても、
  # issueUrlにはURL行だけを保存する（extract_issue_number_from_urlと同様、
  # 「.../issues/N」形式のURL行を対象にする）。
  local issue_url issue_number
  issue_url=$(echo "$create_output" | grep -oE 'https?://[^[:space:]]+/issues/[0-9]+' | tail -n1)
  issue_number=$(extract_issue_number_from_url "$issue_url")

  if [ -z "$issue_url" ] || [ -z "$issue_number" ]; then
    ITEM_RESULT_JSON=$(jq -n --argjson index "$index" \
      --arg error "gh succeeded but did not return a parsable issue URL: ${create_output}" \
      '{index: $index, status: "failed", error: $error}')
    return
  fi

  local result
  result=$(jq -n --argjson index "$index" --argjson issueNumber "$issue_number" --arg issueUrl "$issue_url" \
    '{index: $index, status: "created", issueNumber: $issueNumber, issueUrl: $issueUrl}')

  if [ -n "$GRANULARITY_WARNING" ]; then
    result=$(jq --arg w "$GRANULARITY_WARNING" '. + {warning: $w}' <<<"$result")
  fi

  ITEM_RESULT_JSON="$result"
}

# 各Issue起票の直後にstderrへ結果1行を出力する（中断時の二重起票対策）。
# stdoutは最終対応表JSON1個のみという規約を維持するため、進捗はstderr専用にする。
# 途中で処理が中断（Ctrl-C・タイムアウト等）しても、この行の履歴から
# 「どこまで起票済みか」を人間が把握でき、再実行時に丸ごと再起票して
# 二重起票してしまう事故を防げる。
# 引数: index item_json（元のmanifest項目） result_json（process_manifest_itemの結果）
emit_progress_line() {
  local index="$1" item_json="$2" result_json="$3"
  local title status line

  title=$(jq -r '.title // "(no title)"' <<<"$item_json")
  status=$(jq -r '.status' <<<"$result_json")

  if [ "$status" = "created" ]; then
    local issue_number
    issue_number=$(jq -r '.issueNumber' <<<"$result_json")
    line="[${index}] created #${issue_number}: ${title}"
  else
    local error
    error=$(jq -r '.error' <<<"$result_json")
    line="[${index}] failed: ${title} (${error})"
  fi

  echo "$line" >&2
}

# manifest全体（JSON配列文字列）を処理し、対応表JSON全体を組み立てる。
# 引数: manifest_json（JSON配列文字列）
# 結果: RESULTS_JSON（{"results": [...], "createdCount": N, "failedCount": M}）
process_manifest() {
  local manifest_json="$1"
  local count idx item results_array created_count failed_count status

  count=$(jq 'length' <<<"$manifest_json")
  results_array="[]"
  created_count=0
  failed_count=0

  idx=0
  while [ "$idx" -lt "$count" ]; do
    item=$(jq -c ".[$idx]" <<<"$manifest_json")
    process_manifest_item "$idx" "$item"
    results_array=$(jq --argjson r "$ITEM_RESULT_JSON" '. + [$r]' <<<"$results_array")
    emit_progress_line "$idx" "$item" "$ITEM_RESULT_JSON"

    status=$(jq -r '.status' <<<"$ITEM_RESULT_JSON")
    if [ "$status" = "created" ]; then
      created_count=$((created_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi

    idx=$((idx + 1))
  done

  RESULTS_JSON=$(jq -n --argjson results "$results_array" --argjson created "$created_count" --argjson failed "$failed_count" \
    '{results: $results, createdCount: $created, failedCount: $failed}')
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <manifest.jsonファイルパス>" >&2
}

main() {
  local manifest_path="${1:-}"

  if [ -z "$manifest_path" ]; then
    print_usage
    return 1
  fi

  if ! check_jq; then
    return 1
  fi

  if [ ! -f "$manifest_path" ]; then
    echo "Error: manifest file not found: ${manifest_path}" >&2
    return 1
  fi

  local manifest_json
  if ! manifest_json=$(jq -c '.' "$manifest_path" 2>&1); then
    echo "Error: failed to parse manifest as JSON: ${manifest_json}" >&2
    return 1
  fi

  local manifest_type
  manifest_type=$(jq -r 'type' <<<"$manifest_json")
  if [ "$manifest_type" != "array" ]; then
    echo "Error: manifest must be a JSON array, got: ${manifest_type}" >&2
    return 1
  fi

  process_manifest "$manifest_json"

  echo "$RESULTS_JSON"

  local failed_count
  failed_count=$(jq -r '.failedCount' <<<"$RESULTS_JSON")
  if [ "$failed_count" -gt 0 ]; then
    return 1
  fi
  return 0
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
