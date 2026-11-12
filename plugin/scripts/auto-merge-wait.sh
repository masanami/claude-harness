#!/bin/bash
# auto-merge-wait.sh
# 使い方: scripts/auto-merge-wait.sh <PR番号> [--timeout-minutes <分>（既定: 30）] [--interval <秒>（既定: 30）]
# 仕様の正本は scripts/specs/ci-trigger.md を参照（#363）。
#
# /pr-merge が、CI の運用の宣言（.claude-harness/ci.json）が before-merge のリポジトリで、既定ブランチ宛ての PR を
# マージするときに使う。即時マージの代わりに自動マージを予約し（gh pr merge <PR> --auto --squash --delete-branch）、
# 上限つきで PR の状態を見て、次の 3 つのどれかを stdout の JSON で返す（exit 0）:
#   merged        : マージされた
#   checks_failed : チェックが落ちた（fail / cancel が 1 件でも出た）。予約は残る（直して push し直せば、通った後にマージされる）
#   timeout       : 上限に達した。予約は残る（GitHub が後でマージしうる）
# 予約に失敗した・PR が閉じられた・予約が外れた（マージされずに auto-merge が無効になった）・状態を取れないまま上限に達した
# ときは、stderr に理由を出して exit 1（stdout は空）。引数の誤りは exit 2（予約しない）。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

AUTO_MERGE_DEFAULT_TIMEOUT_MINUTES=30
AUTO_MERGE_DEFAULT_INTERVAL_SECONDS=30
AUTO_MERGE_SLEEP_CMD="${AUTO_MERGE_SLEEP_CMD:-sleep}"

# ---------------------------------------------------------------------------
# gh 呼び出し（外部作用あり）
# ---------------------------------------------------------------------------

# 自動マージを予約する（必須チェック等の条件がそろったら GitHub がマージする）。
reserve_auto_merge() {
  gh pr merge "$@"
}

# PR の状態（state・autoMergeRequest）を取得する。取れなければ非0。
fetch_pr_merge_state() {
  gh pr view "$1" --json number,url,state,autoMergeRequest 2>/dev/null
}

# fetch_pr_checks は lib/common.sh に集約（ci-wait.sh・pr-merge-preflight.sh と同じ実装）。

# ---------------------------------------------------------------------------
# 純粋関数（gh を呼ばない。source して直接テスト可能）
# ---------------------------------------------------------------------------

# checks 配列を分類する: "empty" | "pending" | "red" | "green"（ci-wait.sh の classify_checks と同じ規則）。
auto_merge_classify_checks() {
  local checks_json="$1"
  if [ "$(jq 'length' <<<"$checks_json" 2>/dev/null || echo 0)" -eq 0 ]; then
    echo "empty"
  elif jq -e "any(.[]; ${JQ_FAIL_CANCEL_PREDICATE})" <<<"$checks_json" >/dev/null 2>&1; then
    echo "red"
  elif jq -e 'any(.[]; .bucket == "pending")' <<<"$checks_json" >/dev/null 2>&1; then
    echo "pending"
  else
    echo "green"
  fi
}

# 引数: state（MERGED|CLOSED|OPEN）, auto_merge_on（true|false）, checks の分類, attempt（初回=1）, max_attempts
# 戻り値: stop:merged | stop:closed | stop:disabled | stop:checks_failed | stop:timeout | continue
auto_merge_decision() {
  local state="$1" auto_merge_on="$2" checks="$3" attempt="$4" max_attempts="$5"
  case "$state" in
    MERGED) echo "stop:merged"; return ;;
    CLOSED) echo "stop:closed"; return ;;
  esac
  if [ "$auto_merge_on" != "true" ]; then
    echo "stop:disabled"
    return
  fi
  if [ "$checks" = "red" ]; then
    echo "stop:checks_failed"
    return
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "stop:timeout"
    return
  fi
  echo "continue"
}

print_usage() {
  echo "Usage: $(basename "$0") <PR番号> [--timeout-minutes <分>（既定: ${AUTO_MERGE_DEFAULT_TIMEOUT_MINUTES}）] [--interval <秒>（既定: ${AUTO_MERGE_DEFAULT_INTERVAL_SECONDS}）]" >&2
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local pr="" timeout_minutes="$AUTO_MERGE_DEFAULT_TIMEOUT_MINUTES" interval="$AUTO_MERGE_DEFAULT_INTERVAL_SECONDS"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout-minutes) timeout_minutes="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --interval) interval="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      -*) echo "Error: unknown option '$1'" >&2; print_usage; return 2 ;;
      *)
        if [ -n "$pr" ]; then echo "Error: unexpected argument '$1'" >&2; print_usage; return 2; fi
        pr="$1"; shift ;;
    esac
  done
  if ! [[ "$pr" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: PR number must be a positive integer, got '${pr}'" >&2
    print_usage
    return 2
  fi
  if ! [[ "$timeout_minutes" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --timeout-minutes must be a positive integer, got '${timeout_minutes}'" >&2
    print_usage
    return 2
  fi
  if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --interval must be a positive integer, got '${interval}'" >&2
    print_usage
    return 2
  fi
  if ! check_jq; then
    return 1
  fi

  if ! reserve_auto_merge "$pr" --auto --squash --delete-branch >&2; then
    echo "Error: failed to enable auto-merge for PR #${pr} (gh pr merge --auto). Check that the repository allows auto-merge and that the base branch has required checks" >&2
    return 1
  fi

  local max_attempts=$((timeout_minutes * 60 / interval + 1))
  local attempt=1 view state auto_on checks_json="[]" checks decision pr_url=""
  while true; do
    if ! view="$(fetch_pr_merge_state "$pr")" || ! state="$(jq -er '.state' <<<"$view" 2>/dev/null)"; then
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "Error: failed to read the state of PR #${pr} until the limit (${timeout_minutes} min). The auto-merge reservation may still be active" >&2
        return 1
      fi
      "$AUTO_MERGE_SLEEP_CMD" "$interval"
      attempt=$((attempt + 1))
      continue
    fi
    pr_url="$(jq -r '.url // ""' <<<"$view")"
    auto_on="$(jq -r '.autoMergeRequest != null' <<<"$view")"
    checks="pending"
    if [ "$state" = "OPEN" ]; then
      # チェックを取れなかった回は pending と扱って待ち続ける（落ちたとも通ったとも決めない）。
      if checks_json="$(fetch_pr_checks "$pr")"; then
        checks="$(auto_merge_classify_checks "$checks_json")"
      else
        checks_json="[]"
      fi
    fi
    decision="$(auto_merge_decision "$state" "$auto_on" "$checks" "$attempt" "$max_attempts")"
    [ "$decision" != "continue" ] && break
    "$AUTO_MERGE_SLEEP_CMD" "$interval"
    attempt=$((attempt + 1))
  done

  local result="${decision#stop:}" kept=false failed="[]"
  case "$result" in
    closed)
      echo "Error: PR #${pr} was closed without being merged" >&2
      return 1 ;;
    disabled)
      echo "Error: the auto-merge reservation of PR #${pr} was removed before it merged (e.g. disabled by someone, or a new push by a user without write access)" >&2
      return 1 ;;
    checks_failed)
      kept=true
      failed="$(jq -c "[.[] | select(${JQ_FAIL_CANCEL_PREDICATE}) | {name, workflow, link}]" <<<"$checks_json")" ;;
    timeout)
      kept=true ;;
  esac
  jq -n --arg result "$result" --argjson pr "$pr" --arg url "$pr_url" --argjson kept "$kept" \
    --argjson failed "$failed" --argjson tm "$timeout_minutes" --argjson waited "$(((attempt - 1) * interval))" \
    '{result: $result, pr_number: $pr, pr_url: $url, auto_merge_kept: $kept, failed_checks: $failed,
      timeout_minutes: $tm, waited_seconds: $waited}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
