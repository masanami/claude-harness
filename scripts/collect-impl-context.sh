#!/bin/bash
# collect-impl-context.sh
# skills/reduce-debt/SKILL.md Step 1（実装コンテキストの取得）のための決定的スクリプト。
# 親Issue本文から子Issue・PRへの `#N` 参照を抽出し、PR側の変更ファイルを集約する。
#
# 使い方:
#   scripts/collect-impl-context.sh <親Issue番号>
#
# 出力（stdout にJSON1個）:
#   {
#     "parentIssue": 43,
#     "childIssues": [44, 45],
#     "prs": [46, 47],
#     "changedFiles": ["scripts/foo.sh", "skills/bar/SKILL.md"],
#     "changedDirs": ["scripts", "skills/bar"],
#     "unresolvedReferences": [],
#     "resolution_status": "ok" | "no_references_found" | "unresolved_references"
#   }
#
# resolution_status の意味:
#   - "ok": 本文中に #N 参照があり、全件を issue/pr のいずれかに分類できた
#           （PR参照が0件で changedFiles が空になるのは正常系であり "ok" のまま）
#   - "no_references_found": 本文中に #N 形式の参照が1件も無かった
#   - "unresolved_references": #N 参照はあったが、issue/pr いずれとしても
#     判定できなかった番号が1件以上あった（unresolvedReferences に列挙）
#
# gh呼び出しの失敗・jq不在など真の異常系は stderr にメッセージを出し、exit非0で終了する。
#
# テスト容易性のため、gh を呼ぶ処理（fetch_issue_body / classify_reference / fetch_pr_files）と
# 純粋関数（extract_references / union_file_arrays / derive_changed_dirs / resolve_status）を
# 分離している。このファイルを `source` すれば gh を呼ばずに純粋関数だけを直接テストできる。
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

# gh issue view で親Issue本文を取得する。
# 引数: Issue番号
# 戻り値: 本文テキストを stdout に出力（呼び出し側で $() キャプチャする）。失敗時は非0を返す。
fetch_issue_body() {
  local issue_num="$1"
  local output stderr_file
  # stderr を stdout に混ぜない: gh が成功時に出す警告（rate limit 通知等）が
  # 本文に混入するとパース誤りの silent failure になるため、別ファイルに分離する。
  stderr_file="$(mktemp)"
  if ! output=$(gh issue view "$issue_num" --json body -q .body 2>"$stderr_file"); then
    echo "Error: failed to fetch issue #${issue_num} via gh: $(cat "$stderr_file")" >&2
    rm -f "$stderr_file"
    return 1
  fi
  rm -f "$stderr_file"
  printf '%s' "$output"
}

# 本文テキストから `#N` 形式の参照番号を抽出し、重複を除いた昇順のJSON配列にする。
# gh を呼ばない純粋関数。引数または stdin で本文テキストを受け取る。
# 結果: EXTRACTED_REFERENCES_JSON（例: "[44,45,46]"）
extract_references() {
  local body
  if [ "$#" -ge 1 ]; then
    body="$1"
  else
    body="$(cat)"
  fi

  # gh issue view --json body はCRLF改行の本文を返すことがある。先に正規化する。
  body="${body//$'\r'/}"

  local nums
  nums=$(printf '%s\n' "$body" | grep -oE '#[0-9]+' | sed 's/^#//' | sort -n -u)

  if [ -z "$nums" ]; then
    EXTRACTED_REFERENCES_JSON="[]"
    return
  fi

  EXTRACTED_REFERENCES_JSON=$(printf '%s\n' "$nums" | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber)')
}

# 参照番号がIssueかPRかを判定する。gh を呼ぶため純粋関数ではない。
# 引数: 参照番号
# 結果: REFERENCE_TYPE ("issue" | "pr" | "unresolved")
classify_reference() {
  local num="$1"
  if gh pr view "$num" --json number >/dev/null 2>&1; then
    REFERENCE_TYPE="pr"
    return
  fi
  if gh issue view "$num" --json number >/dev/null 2>&1; then
    REFERENCE_TYPE="issue"
    return
  fi
  REFERENCE_TYPE="unresolved"
}

# PRの変更ファイル一覧を取得する。gh を呼ぶため純粋関数ではない。
# 引数: PR番号
# 結果: PR_FILES_JSON（変更ファイルパスのJSON配列）。失敗時は非0を返す。
fetch_pr_files() {
  local pr_num="$1"
  local output stderr_file
  stderr_file="$(mktemp)"
  if ! output=$(gh pr view "$pr_num" --json files --jq '[.files[].path]' 2>"$stderr_file"); then
    echo "Error: failed to fetch files for PR #${pr_num} via gh: $(cat "$stderr_file")" >&2
    rm -f "$stderr_file"
    return 1
  fi
  rm -f "$stderr_file"
  PR_FILES_JSON="$output"
}

# 複数のJSON配列（文字列引数）を重複除去・ソートしたうえで統合する。gh を呼ばない純粋関数。
# 引数: JSON配列文字列を可変長で受け取る（0個可）
# 結果: UNIONED_FILES_JSON
union_file_arrays() {
  local merged="[]"
  local arr
  for arr in "$@"; do
    # bash 3.2 の "${array[@]:-}" は空配列でも1個の空文字列引数を渡してくることがあるため、
    # 空文字列はスキップする（jq --argjson に渡すと invalid JSON エラーになる）。
    [ -z "$arr" ] && continue
    merged=$(jq -c --argjson a "$arr" '. + $a' <<<"$merged")
  done
  UNIONED_FILES_JSON=$(jq -c 'unique | sort' <<<"$merged")
}

# 変更ファイル一覧からディレクトリ一覧（重複除去・ソート）を導出する。gh を呼ばない純粋関数。
# ルート直下のファイル（ディレクトリを持たない）は "." として扱う。
# 引数: changedFilesのJSON配列文字列
# 結果: CHANGED_DIRS_JSON
derive_changed_dirs() {
  local files_json="$1"
  CHANGED_DIRS_JSON=$(jq -c '
    [.[] | split("/") as $parts
      | if ($parts | length) > 1 then ($parts[0:-1] | join("/")) else "." end]
    | unique | sort
  ' <<<"$files_json")
}

# 参照総数と未解決件数から resolution_status を決定する。gh を呼ばない純粋関数。
# 引数: 参照総数 未解決件数
# 結果: RESOLUTION_STATUS
resolve_status() {
  local total_refs="$1" unresolved_count="$2"
  if [ "$total_refs" -eq 0 ]; then
    RESOLUTION_STATUS="no_references_found"
  elif [ "$unresolved_count" -gt 0 ]; then
    RESOLUTION_STATUS="unresolved_references"
  else
    RESOLUTION_STATUS="ok"
  fi
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <親Issue番号>" >&2
}

main() {
  local arg="${1:-}"

  if [ -z "$arg" ]; then
    print_usage
    exit 1
  fi

  if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
    echo "Error: issue number must be numeric, got '${arg}'" >&2
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  local body
  if ! body="$(fetch_issue_body "$arg")"; then
    exit 1
  fi

  extract_references "$body"
  local refs_json="$EXTRACTED_REFERENCES_JSON"
  local refs_count
  refs_count=$(jq 'length' <<<"$refs_json")

  local child_issues_json="[]"
  local prs_json="[]"
  local unresolved_json="[]"
  local file_arrays=()

  if [ "$refs_count" -gt 0 ]; then
    local i num
    i=0
    while [ "$i" -lt "$refs_count" ]; do
      num=$(jq -r ".[$i]" <<<"$refs_json")
      classify_reference "$num"
      case "$REFERENCE_TYPE" in
        issue)
          child_issues_json=$(jq -c --argjson n "$num" '. + [$n]' <<<"$child_issues_json")
          ;;
        pr)
          prs_json=$(jq -c --argjson n "$num" '. + [$n]' <<<"$prs_json")
          if fetch_pr_files "$num"; then
            file_arrays+=("$PR_FILES_JSON")
          else
            exit 1
          fi
          ;;
        unresolved)
          unresolved_json=$(jq -c --argjson n "$num" '. + [$n]' <<<"$unresolved_json")
          ;;
      esac
      i=$((i + 1))
    done
  fi

  union_file_arrays "${file_arrays[@]:-}"
  local changed_files_json="$UNIONED_FILES_JSON"
  derive_changed_dirs "$changed_files_json"
  local changed_dirs_json="$CHANGED_DIRS_JSON"

  local unresolved_count
  unresolved_count=$(jq 'length' <<<"$unresolved_json")
  resolve_status "$refs_count" "$unresolved_count"

  jq -n \
    --argjson parentIssue "$arg" \
    --argjson childIssues "$child_issues_json" \
    --argjson prs "$prs_json" \
    --argjson changedFiles "$changed_files_json" \
    --argjson changedDirs "$changed_dirs_json" \
    --argjson unresolvedReferences "$unresolved_json" \
    --arg status "$RESOLUTION_STATUS" \
    '{parentIssue: $parentIssue, childIssues: $childIssues, prs: $prs, changedFiles: $changedFiles, changedDirs: $changedDirs, unresolvedReferences: $unresolvedReferences, resolution_status: $status}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
