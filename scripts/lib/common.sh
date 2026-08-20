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
#       `gh pr checks` の結果を取得する。取得失敗/空の場合は空配列を返す。
#       gh pr checks は CI が pending/fail の場合に非0 exitを返す仕様のため、
#       exit code ではなく stdout が有効なJSON配列かどうかで成否を判定する。
#       warn_on_empty に "1" を渡すと取得失敗/空の際に stderr へ Warning を出す
#       （pr-merge-preflight.sh の元実装の挙動）。省略時は Warning を出さない
#       （ci-wait.sh の元実装の挙動。2つの元実装の唯一の差分だったため引数化した）。
#   - JQ_FAIL_CANCEL_PREDICATE
#       CIチェックの fail/cancel 判定に使う jq 式の述語部分（4箇所で重複していたもの）。
#       利用側は `jq -e "any(.[]; ${JQ_FAIL_CANCEL_PREDICATE})"` や
#       `jq -c "[.[] | select(${JQ_FAIL_CANCEL_PREDICATE})]"` のように埋め込んで使う
#       （完全な jq プログラム自体は呼び出し箇所ごとに異なる= any/select 等の外側の形が
#       異なるため、共通化対象は述語部分の文字列に留める）。

# 保証 ID の書式（`G-{宣言元番号}-{枝番}`）。台帳のパース（guarantee-index-check.sh）と
# 昇格判定の材料検査（promotion-decision.sh）の両方が使うため、**ここを唯一の定義**とする
# （同じ文法を2箇所で持つと、片方だけ変えたときに黙ってずれる）。
# POSIX ERE（bash の `=~`）と Oniguruma（jq の `test()`）のどちらでもそのまま使える表記に限る。
# shellcheck disable=SC2034 # source した側（guarantee-index-check.sh / promotion-decision.sh）で使う
GUARANTEE_ID_PATTERN='G-[0-9]+-[0-9]+'

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
  local output
  output=$(gh pr checks "$pr_num" --json name,state,bucket,description,workflow,link 2>/dev/null)
  if [ -z "$output" ] || ! jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1; then
    if [ "$warn_on_empty" = "1" ]; then
      echo "Warning: no CI checks data available for PR #${pr_num} (no checks configured, or fetch failed)" >&2
    fi
    printf '[]'
    return 0
  fi
  printf '%s' "$output"
}

# shellcheck disable=SC2034 # source する各スクリプト側の jq 式に文字列展開して使われる
JQ_FAIL_CANCEL_PREDICATE='.bucket == "fail" or .bucket == "cancel"'
