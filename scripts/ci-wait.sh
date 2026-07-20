#!/bin/bash
# ci-wait.sh
# para-impl の star型並列実装で ticket-worker が Phase 9（CI確認）に使う決定的スクリプト
# （Issue #45 で新設、#105 で呼び出し元を Dynamic Workflow から ticket-worker へ変更）。
# `gh pr checks` を上限付きでポーリングし、失敗時は失敗ジョブのログ末尾を抽出する。
#
# 使い方:
#   scripts/ci-wait.sh <PR番号 or ブランチ名> [timeout秒（既定: 900）] [poll間隔秒（既定: 30）]
#
#   <PR番号 or ブランチ名> は `gh pr view` がそのまま受け付けるセレクタ（PR番号・
#   ブランチ名・URL のいずれでもよい）。対応する PR が存在しない場合は
#   pr_exists: false, ci: 'none' を返して即座に終了する（ポーリングしない）。
#
#   timeout秒に 0 を指定すると「1回だけスナップショットを取得して即終了する」
#   single-shot モードになる（sleep しない）。ticket-worker の attempt>=2
#   冪等分岐（PR作成済みかどうかだけを素早く確認したい場合）はこの用法を使う。
#
# 出力（stdout にJSON1個）:
#   {
#     "ci": "green" | "red" | "timeout" | "none",
#     "failed_checks": [{"name": "...", "workflow": "...", "link": "..."}],
#     "failure_log_excerpt": "...",
#     "pr_url": "...",
#     "pr_number": 123 | null,
#     "pr_exists": true | false
#   }
#
# 設計判断（checks未設定リポジトリの扱い。Issue #45 本文の指示に基づく）:
#   `gh pr checks` が「チェックが1件も無い」を返した場合、それが「本当にCIが
#   設定されていない」のか「ポーリング開始直後でまだチェックが登録されていない」のか
#   を1回のスナップショットだけでは区別できない。本スクリプトは連続
#   NONE_CONFIRM_ATTEMPTS 回（既定2回）空を観測して初めて `ci: 'none'` を確定する
#   （呼び出し側 ticket-worker は 'none' を green 相当としてブロックしない扱いに
#   してよい。実行不能なゲートで永久にブロックしないため）。ループが timeout に達した
#   時点でまだ「空」だった場合も（チェックがpendingだったわけではないため）'timeout'
#   ではなく 'none' として確定する。'timeout' は「チェックはあるが完了を待ちきれなかった
#   （pending のまま時間切れ）」の場合にのみ使う。
#
# gh呼び出しを行う処理（fetch_*）と、入力から出力を組み立てる純粋な判定処理
# （classify_checks / ci_wait_decision / extract_run_ids / tail_lines /
#  truncate_to_budget / build_failed_checks_json）を関数として分離している。
# このファイルを `source` すれば gh を呼ばずに純粋関数を直接テストできる。

set -u

DEFAULT_TIMEOUT_SECONDS=900
DEFAULT_POLL_INTERVAL_SECONDS=30
NONE_CONFIRM_ATTEMPTS=2
LOG_TAIL_LINES=100
LOG_CHAR_BUDGET=4000

POLL_SLEEP_CMD="${POLL_SLEEP_CMD:-sleep}"

check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# gh 呼び出し（外部作用あり）
# ---------------------------------------------------------------------------

# PR の存在確認 + 基本情報の取得。存在しなければ非0を返す（gh pr view 自体の非0終了）。
# 結果: PR_VIEW_JSON
fetch_pr_view() {
  local selector="$1"
  local output
  if ! output=$(gh pr view "$selector" --json number,url,state 2>/dev/null); then
    return 1
  fi
  PR_VIEW_JSON="$output"
  return 0
}

# pr-merge-preflight.sh の fetch_pr_checks と同じ設計（gh pr checks は pending/fail 時に
# 非0 exitを返す仕様のため、exit code ではなく stdout が有効なJSON配列かどうかで成否判定）。
fetch_pr_checks() {
  local pr_num="$1"
  local output
  output=$(gh pr checks "$pr_num" --json name,state,bucket,description,workflow,link 2>/dev/null)
  if [ -z "$output" ] || ! jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1; then
    printf '[]'
    return 0
  fi
  printf '%s' "$output"
}

# 失敗ジョブのログ末尾を取得する。run_id 単位（複数チェックが同一 run に属しうる）。
fetch_run_log_failed() {
  local run_id="$1"
  gh run view "$run_id" --log-failed 2>/dev/null
}

# ---------------------------------------------------------------------------
# 純粋関数（gh を呼ばない。source して直接テスト可能）
# ---------------------------------------------------------------------------

# checks配列（[{bucket: "pass"|"fail"|"pending"|"skipping"|"cancel", ...}]）から
# 現在のスナップショットを分類する: "empty" | "pending" | "red" | "green"
# fail/cancel が1件でもあれば、他がpendingでも即 "red"（失敗確定と扱い、待たない）。
classify_checks() {
  local checks_json="$1"
  local count
  count=$(jq 'length' <<<"$checks_json" 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    echo "empty"
    return
  fi
  if jq -e 'any(.[]; .bucket == "fail" or .bucket == "cancel")' <<<"$checks_json" >/dev/null 2>&1; then
    echo "red"
    return
  fi
  if jq -e 'any(.[]; .bucket == "pending")' <<<"$checks_json" >/dev/null 2>&1; then
    echo "pending"
    return
  fi
  echo "green"
}

# ポーリング継続可否を判定する純粋関数。
# 引数: classification（classify_checksの出力）, attempt（現在の試行回数。初回=1）,
#       max_attempts, empty_streak（このclassificationが"empty"だった場合の、今回を
#       含む連続empty回数。呼び出し側が管理する）, max_empty_confirm
# 戻り値: "stop:green" | "stop:red" | "stop:none" | "stop:timeout" | "continue"
ci_wait_decision() {
  local classification="$1" attempt="$2" max_attempts="$3" empty_streak="$4" max_empty_confirm="$5"

  case "$classification" in
    red)
      echo "stop:red"
      return
      ;;
    green)
      echo "stop:green"
      return
      ;;
    empty)
      if [ "$empty_streak" -ge "$max_empty_confirm" ]; then
        echo "stop:none"
        return
      fi
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "stop:none"
        return
      fi
      echo "continue"
      return
      ;;
    pending)
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "stop:timeout"
        return
      fi
      echo "continue"
      return
      ;;
    *)
      echo "stop:none"
      return
      ;;
  esac
}

# link（例: https://github.com/owner/repo/actions/runs/123456789/job/987654321）から
# run_id を抽出する。マッチしなければ空文字を返す。
extract_run_id() {
  local link="$1"
  if [[ "$link" =~ /runs/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo ""
}

# fail/cancel の checks のみを抽出したJSON配列を返す。
build_failed_checks_json() {
  local checks_json="$1"
  jq -c '[.[] | select(.bucket == "fail" or .bucket == "cancel") | {name, workflow, link}]' <<<"$checks_json"
}

# failed_checks_json（build_failed_checks_json の出力）から一意な run_id 一覧を返す
# （改行区切り文字列。link が run_id を含まない/空の場合はスキップする）。
extract_run_ids() {
  local failed_checks_json="$1"
  local link run_id
  local seen=""
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    run_id="$(extract_run_id "$link")"
    [ -z "$run_id" ] && continue
    case "$seen" in
      *" ${run_id} "*) continue ;;
    esac
    seen="${seen} ${run_id} "
    echo "$run_id"
  done < <(jq -r '.[].link // empty' <<<"$failed_checks_json")
}

# テキストの末尾 n 行を返す（純粋なテキスト処理）。
tail_lines() {
  local text="$1" n="$2"
  printf '%s' "$text" | tail -n "$n"
}

# テキストが budget 文字を超える場合、末尾 budget 文字だけを残し、
# 先頭に切り詰めた旨のマーカーを付ける。
truncate_to_budget() {
  local text="$1" budget="$2"
  local len=${#text}
  if [ "$len" -le "$budget" ]; then
    printf '%s' "$text"
    return
  fi
  local start=$((len - budget))
  printf '...(truncated)...\n%s' "${text:start}"
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <PR番号 or ブランチ名> [timeout秒（既定: ${DEFAULT_TIMEOUT_SECONDS}。0でsingle-shot）] [poll間隔秒（既定: ${DEFAULT_POLL_INTERVAL_SECONDS}）]" >&2
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local selector="${1:-}"
  local timeout_seconds="${2:-$DEFAULT_TIMEOUT_SECONDS}"
  local poll_interval="${3:-$DEFAULT_POLL_INTERVAL_SECONDS}"

  if [ -z "$selector" ]; then
    print_usage
    exit 1
  fi
  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]]; then
    echo "Error: timeout seconds must be numeric, got '${timeout_seconds}'" >&2
    print_usage
    exit 1
  fi
  if ! [[ "$poll_interval" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: poll interval seconds must be a positive integer, got '${poll_interval}'" >&2
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  if ! fetch_pr_view "$selector"; then
    jq -n '{ci: "none", failed_checks: [], failure_log_excerpt: "", pr_url: "", pr_number: null, pr_exists: false}'
    exit 0
  fi

  local pr_number pr_url
  pr_number="$(jq -r '.number' <<<"$PR_VIEW_JSON")"
  pr_url="$(jq -r '.url' <<<"$PR_VIEW_JSON")"

  local max_attempts=$((timeout_seconds / poll_interval + 1))
  if [ "$max_attempts" -lt 1 ]; then
    max_attempts=1
  fi

  local attempt=1
  local empty_streak=0
  local checks_json="[]"
  local classification
  local decision
  local final_status=""

  while true; do
    checks_json="$(fetch_pr_checks "$pr_number")"
    classification="$(classify_checks "$checks_json")"
    if [ "$classification" = "empty" ]; then
      empty_streak=$((empty_streak + 1))
    else
      empty_streak=0
    fi

    decision="$(ci_wait_decision "$classification" "$attempt" "$max_attempts" "$empty_streak" "$NONE_CONFIRM_ATTEMPTS")"

    if [ "$decision" != "continue" ]; then
      final_status="${decision#stop:}"
      break
    fi

    "$POLL_SLEEP_CMD" "$poll_interval"
    attempt=$((attempt + 1))
  done

  local failed_checks_json="[]"
  local failure_log_excerpt=""

  if [ "$final_status" = "red" ]; then
    failed_checks_json="$(build_failed_checks_json "$checks_json")"
    local run_id
    local combined=""
    while IFS= read -r run_id; do
      [ -z "$run_id" ] && continue
      local run_log
      run_log="$(fetch_run_log_failed "$run_id")"
      [ -z "$run_log" ] && continue
      local tail
      tail="$(tail_lines "$run_log" "$LOG_TAIL_LINES")"
      combined="${combined}--- run ${run_id} ---
${tail}
"
    done < <(extract_run_ids "$failed_checks_json")
    failure_log_excerpt="$(truncate_to_budget "$combined" "$LOG_CHAR_BUDGET")"
  fi

  jq -n \
    --arg ci "$final_status" \
    --argjson failed_checks "$failed_checks_json" \
    --arg failure_log_excerpt "$failure_log_excerpt" \
    --arg pr_url "$pr_url" \
    --argjson pr_number "$pr_number" \
    '{ci: $ci, failed_checks: $failed_checks, failure_log_excerpt: $failure_log_excerpt, pr_url: $pr_url, pr_number: $pr_number, pr_exists: true}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
