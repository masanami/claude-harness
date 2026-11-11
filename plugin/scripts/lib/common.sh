#!/bin/bash
# scripts/lib/common.sh
# scripts/*.sh 間で重複していた共通ヘルパーを集約したライブラリ（Issue #128）。
# 各スクリプトはスクリプト自身の位置起点で source する（呼び出し元の cwd に依存させないため）:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# 既存の「対象スクリプトを source して関数を直接テストする」方式（scripts/README.md
# 「テスト」節）と両立するよう、ここに定義する関数もトップレベル関数として定義する
# （サブシェル化しない。単独で `bash scripts/lib/common.sh` として実行することは想定しない）。
#
# 適用範囲について: scripts/*.sh 配下の18スクリプトが対象（Issue #128 の実測範囲）。
# skills/init-project/scripts/generate-settings.sh にも同型の check_jq 実装（gs_check_jq）が
# 存在するが、(1) skills/*/scripts/ は scripts/ とは別のディレクトリ境界であり、本ライブラリの
# source パス解決（スクリプト自身の位置起点の相対パス）がそのままでは届かないこと、
# (2) skills↔scripts間の参照を増やす設計判断は本Issueのスコープ外であること、の2点から
# 意図的に対象外としている（見送り）。
#
# 提供する関数・変数:
#   - check_jq [error_json]
#       jq の有無を確認する。無ければ stderr にエラーメッセージ + エラーJSONを出し非0を返す。
#       error_json 省略時は '{"error":"jq not found"}'。analyze-project.sh のみ元実装が
#       '{"status":"error","error":"jq not found"}' を出力していたため、analyze-project.sh は
#       source 後に check_jq を自スクリプト専用のエラーJSONへ束縛するローカルラッパーで上書きする
#       （呼び出し箇所ごとに引数を渡し忘れるリスクを無くすため。_common_check_jq_impl 参照）。
#   - resolve_repo
#       `gh repo view` から owner/repo を解決し、グローバル変数 REPO_OWNER / REPO_NAME に
#       格納する。3スクリプト（fetch-pr-comments.sh / reply-and-resolve.sh /
#       check-subtask-completion.sh）で完全に同一実装だったものを集約。
#   - fetch_pr_checks <pr_num> [warn_on_empty]
#       `gh pr checks` の結果を取得する。成功時（チェック 0 件を含む）は JSON 配列を stdout に出し
#       exit 0。取得に失敗した場合は stdout へ何も出さず exit 1（「チェック 0 件」の `[]` とは
#       区別する。呼び出し側は exit code で失敗を判定する）。
#       gh pr checks は CI が pending/fail の場合に非0 exitを返す仕様のため、
#       exit code ではなく stdout が有効なJSON配列かどうかで成否を判定する。
#       0 件の判定: gh が "no checks reported" を stderr に出した場合、または stdout が `[]` の場合。
#       warn_on_empty は 0 件の Warning だけを制御する（"1" で出す。省略時は出さない）。
#       取得失敗の Warning は引数に関わらず常に出す。
#   - JQ_FAIL_CANCEL_PREDICATE
#       CIチェックの fail/cancel 判定に使う jq 式の述語部分（4箇所で重複していたもの）。
#       利用側は `jq -e "any(.[]; ${JQ_FAIL_CANCEL_PREDICATE})"` や
#       `jq -c "[.[] | select(${JQ_FAIL_CANCEL_PREDICATE})]"` のように埋め込んで使う
#       （完全な jq プログラム自体は呼び出し箇所ごとに異なる= any/select 等の外側の形が
#       異なるため、共通化対象は述語部分の文字列に留める）。

# check_jq の実体。error_json 引数を必須で取る内部実装。check_jq（既定JSON）と
# analyze-project.sh 側のローカル上書き（自スクリプト専用JSON）の両方から呼ばれる共通コア。
_common_check_jq_impl() {
  local error_json="$1"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '%s\n' "$error_json" >&2
    return 1
  fi
  return 0
}

check_jq() {
  local error_json="${1:-}"
  if [ -z "$error_json" ]; then
    error_json='{"error":"jq not found"}'
  fi
  _common_check_jq_impl "$error_json"
}

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

fetch_pr_checks() {
  local pr_num="$1"
  local warn_on_empty="${2:-}"
  local output err_file err
  err_file="$(mktemp)"
  output=$(gh pr checks "$pr_num" --json name,state,bucket,description,workflow,link 2>"$err_file")
  err="$(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  if [ -n "$output" ] && jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1; then
    if [ "$warn_on_empty" = "1" ] && [ "$(jq 'length' <<<"$output")" = "0" ]; then
      echo "Warning: no CI checks reported for PR #${pr_num}" >&2
    fi
    printf '%s' "$output"
    return 0
  fi
  # gh は「チェックが 1 件も無い」ときに stdout を空にして "no checks reported" を stderr に出す。
  # これは取得の失敗ではなく 0 件。
  if [ -z "$output" ] && grep -qi "no checks reported" <<<"$err"; then
    if [ "$warn_on_empty" = "1" ]; then
      echo "Warning: no CI checks reported for PR #${pr_num}" >&2
    fi
    printf '[]'
    return 0
  fi
  echo "Warning: failed to fetch CI checks for PR #${pr_num}${err:+: ${err}}" >&2
  return 1
}

# shellcheck disable=SC2034 # source する各スクリプト側の jq 式に文字列展開して使われる
JQ_FAIL_CANCEL_PREDICATE='.bucket == "fail" or .bucket == "cancel"'
