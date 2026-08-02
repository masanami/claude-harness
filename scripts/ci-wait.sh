#!/bin/bash
# ci-wait.sh
# 使い方: scripts/ci-wait.sh <PR番号 or ブランチ名> [timeout秒（既定: 900）] [poll間隔秒（既定: 30）]（詳細は下記参照）
# 仕様の正本は scripts/specs/ci-wait.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

DEFAULT_TIMEOUT_SECONDS=900
DEFAULT_POLL_INTERVAL_SECONDS=30
NONE_CONFIRM_ATTEMPTS=2
LOG_TAIL_LINES=100
LOG_CHAR_BUDGET=4000

POLL_SLEEP_CMD="${POLL_SLEEP_CMD:-sleep}"

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

# fetch_pr_checks は lib/common.sh（scripts/lib/common.sh）に集約（pr-merge-preflight.sh と
# 同じ実装。ここでは warn_on_empty を渡さないため Warning は出さない元の挙動を維持する）。

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
  if jq -e "any(.[]; ${JQ_FAIL_CANCEL_PREDICATE})" <<<"$checks_json" >/dev/null 2>&1; then
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
  jq -c "[.[] | select(${JQ_FAIL_CANCEL_PREDICATE}) | {name, workflow, link}]" <<<"$checks_json"
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
