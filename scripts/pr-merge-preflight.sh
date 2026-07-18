#!/bin/bash
# pr-merge-preflight.sh
# /pr-merge スキルの Phase 0（base ブランチ判定・ゲート判定）と
# Phase 1（PR情報・CI・mergeable・外部レビュー待機ポーリング）を切り出した
# 決定的なシェルスクリプト。
#
# 使い方:
#   scripts/pr-merge-preflight.sh <PR番号> [timeout秒]
#     -> gh でPR情報・CI・reviews を取得し、外部レビュー未投稿なら
#        タイムアウトまでポーリングし、決定表（blocking判定）とrisk算出を行う。
#     timeout秒省略時は600秒（10分。60秒間隔で最大10回チェックする既存仕様を踏襲）。
#
# 出力（stdout にJSON1個）:
#   {
#     "gate": "production" | "integration",
#     "base": "...",            # PRのbaseブランチ名（後続フェーズでの再取得を避けるために含める）
#     "default_branch": "...",  # リポジトリの既定ブランチ名（同上）
#     "ci": {"status": "pass"|"fail"|"pending"|"none", "checks": [...]},
#     "mergeable": "MERGEABLE"|"CONFLICTING"|"UNKNOWN",
#     "mergeStateStatus": "...",
#     "reviews": [{"author": "...", "state": "..."}],
#     "commented_bodies": ["..."],
#     "blocking": bool,
#     "block_reasons": ["changes_requested" | "ci_failed" | "conflicting" | "merge_blocked"],
#     "risk": {"files_changed": n, "insertions": n, "deletions": n, "touches_sensitive": bool}
#   }
#
# 「COMMENTED の内容に重大な指摘がないか」は意味判断のため commented_bodies を
# 返すだけに留め、スクリプト側では本文の意味を一切判定しない（LLM 側の責務）。
#
# CI・mergeable/mergeStateStatus・files/additions/deletions/changedFiles は外部レビュー待機
# ポーリング（最大約10分かかりうる）の完了後に取得する（ポーリング開始前のスナップショットを
# 使うと、ポーリング中にCIが完了する・他の変更でmergeableやfilesが変わる等のケースで
# 古い状態のまま blocking判定・risk算出をしてしまうため。main 参照）。
#
# gh 呼び出しを行う処理（fetch_*）と、入力から出力を組み立てる純粋な判定処理
# （determine_gate / determine_ci_status / judge_blocking / compute_touches_sensitive /
#  reviews_poll_decision / build_risk_json）を関数として分離している。
# このファイルを `source` すれば gh を呼ばずに純粋関数を直接テストできる。

set -u

# 変数名は source する側（テストファイル等）の SCRIPT_DIR と衝突しないよう
# このスクリプト専用の名前にしている（source すると同名グローバル変数は上書きされるため）。
PR_MERGE_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENSITIVE_PATHS_CONFIG="${PR_MERGE_PREFLIGHT_DIR}/config/sensitive-paths.txt"

# sensitive-paths.txt が存在しない場合の内蔵デフォルト（同ファイルの内容と同期させる）。
DEFAULT_SENSITIVE_PATTERNS=(
  ".github/workflows/*"
  "*secret*"
  "*credential*"
  "*.pem"
  "*.key"
  "*.env"
  "scripts/*"
  "CLAUDE.md"
  ".claude/settings.json"
  ".claude/settings.local.json"
)

# 外部レビュー待機ポーリングの既定値。
# 既存 SKILL.md Phase 1 の仕様（60秒間隔・最大10回・最大約10分）を踏襲する。
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-60}"
POLL_SLEEP_CMD="${POLL_SLEEP_CMD:-sleep}"
DEFAULT_TIMEOUT_SECONDS=600

# jq の有無をチェックする。無ければ stderr にエラーメッセージ + エラーJSONを出す。
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

# リポジトリの既定ブランチ名を取得する。
fetch_default_branch() {
  local output stderr_file
  stderr_file="$(mktemp)"
  if ! output=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>"$stderr_file"); then
    echo "Error: failed to fetch default branch via gh: $(cat "$stderr_file")" >&2
    rm -f "$stderr_file"
    return 1
  fi
  rm -f "$stderr_file"
  printf '%s' "$output"
}

# PR の base/reviews を1回の gh 呼び出しでまとめて取得する。PR の存在確認も兼ねる。
#
# mergeable/mergeStateStatus/files/additions/deletions/changedFiles/reviewDecision は
# ここでは取得しない（ここで取得した値は外部レビュー待機ポーリング開始前のスナップショットに
# なってしまい、ポーリング中にCIが完了する・他の変更でmergeableやfilesが変わる等で
# judge_blocking / risk算出に古い値を渡してしまうバグの原因になるため）。
# それらは poll_for_reviews の後に fetch_pr_checks / fetch_pr_recheck / fetch_pr_review_decision で
# 改めて取得する（main 参照）。
fetch_pr_view() {
  local pr_num="$1"
  local output stderr_file
  stderr_file="$(mktemp)"
  if ! output=$(gh pr view "$pr_num" \
    --json baseRefName,reviews \
    2>"$stderr_file"); then
    echo "Error: failed to fetch PR #${pr_num} via gh: $(cat "$stderr_file")" >&2
    rm -f "$stderr_file"
    return 1
  fi
  rm -f "$stderr_file"
  printf '%s' "$output"
}

# CI チェック結果を取得する。
# gh pr checks は CI が pending/fail の場合に非0 exitを返す仕様のため、
# exit code ではなく stdout が有効なJSON配列かどうかで成否を判定する
# （非0 exit = 失敗、とは限らないため）。
# チェックが1件も無い/取得できない場合は空配列を返す（非致命）。
fetch_pr_checks() {
  local pr_num="$1"
  local output
  output=$(gh pr checks "$pr_num" --json name,state,bucket,description,workflow,link 2>/dev/null)
  if [ -z "$output" ] || ! jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1; then
    echo "Warning: no CI checks data available for PR #${pr_num} (no checks configured, or fetch failed)" >&2
    printf '[]'
    return 0
  fi
  printf '%s' "$output"
}

# ポーリングループ用の軽量な reviews 再取得。
fetch_pr_reviews_only() {
  local pr_num="$1"
  local output
  output=$(gh pr view "$pr_num" --json reviews -q '.reviews' 2>/dev/null)
  if [ -z "$output" ]; then
    printf '[]'
    return 0
  fi
  printf '%s' "$output"
}

# reviewDecision のみを取得する軽量フェッチ。
# ポーリング完了後（REVIEWS_JSON確定後）に呼び、judge_blocking に渡す値を
# 最終的なreviewsの状態と整合させるために使う（ポーリング開始前の値を使い回さない）。
fetch_pr_review_decision() {
  local pr_num="$1"
  local output
  output=$(gh pr view "$pr_num" --json reviewDecision -q '.reviewDecision' 2>/dev/null)
  printf '%s' "$output"
}

# 外部レビュー待機ポーリング完了後に mergeable/mergeStateStatus/files/additions/deletions/
# changedFiles を再取得する。
# judge_blocking（mergeable/mergeStateStatus）と risk 算出（files/additions/deletions/
# changedFiles）に渡す値を、ポーリング完了後の最新状態に合わせるために使う
# （ポーリング開始前に取得した古い値を使い回すと、ポーリング中に他の変更でmergeableや
#  変更ファイルが変わった場合に古い状態のまま判定してしまうため）。
fetch_pr_recheck() {
  local pr_num="$1"
  local output stderr_file
  stderr_file="$(mktemp)"
  if ! output=$(gh pr view "$pr_num" \
    --json mergeable,mergeStateStatus,files,additions,deletions,changedFiles \
    2>"$stderr_file"); then
    echo "Error: failed to re-fetch PR #${pr_num} via gh: $(cat "$stderr_file")" >&2
    rm -f "$stderr_file"
    return 1
  fi
  rm -f "$stderr_file"
  printf '%s' "$output"
}

# ---------------------------------------------------------------------------
# 純粋関数（gh を呼ばない。source して直接テスト可能）
# ---------------------------------------------------------------------------

# base ブランチと既定ブランチの一致/不一致から承認ゲートを判定する。
# 一致（本番へのマージ・昇格） -> production
# 不一致（統合ブランチへの集約） -> integration
determine_gate() {
  local base="$1" default_branch="$2"
  if [ "$base" = "$default_branch" ]; then
    echo "production"
  else
    echo "integration"
  fi
}

# CI チェック結果配列（[{bucket: "pass"|"fail"|"pending"|"skipping"|"cancel", ...}]）から
# 全体のCIステータスを判定する。優先順位: fail/cancel > pending > (空なら none) > pass
# cancel（キャンセルされたチェック）は「実行が完了していない」点で fail と同様に扱う
# （成功したとは断定できないため）。
determine_ci_status() {
  local checks_json="$1"
  local count
  count=$(jq 'length' <<<"$checks_json" 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    echo "none"
    return
  fi
  if jq -e 'any(.[]; .bucket == "fail" or .bucket == "cancel")' <<<"$checks_json" >/dev/null 2>&1; then
    echo "fail"
    return
  fi
  if jq -e 'any(.[]; .bucket == "pending")' <<<"$checks_json" >/dev/null 2>&1; then
    echo "pending"
    return
  fi
  echo "pass"
}

# 決定表: checks（[{bucket: ...}]）・mergeable文字列・mergeStateStatus文字列・
# reviewDecision文字列から blocking可否と理由を判定する。
# 結果はグローバル変数 BLOCKING / BLOCK_REASONS_JSON に格納する。
#
# - reviewDecision が CHANGES_REQUESTED -> blocking=true, "changes_requested"
#   （reviews配列を直接走査しないのは fetch_pr_view のコメント参照。GitHub側が算出する
#    reviewDecision は同一レビュアーの最新状態のみを反映するため、解消済みの
#    CHANGES_REQUESTED で恒久的にblockingしない）
# - CI が fail/cancel 状態 -> blocking=true, "ci_failed"
# - mergeable が CONFLICTING -> blocking=true, "conflicting"
# - mergeStateStatus が BLOCKED（branch protectionの必須条件未達等）-> blocking=true, "merge_blocked"
# - COMMENTED のみ・APPROVED のみ・reviews空 -> 上記に該当しない限り blocking=false
#   （COMMENTED の中身の意味はここでは判定しない。呼び出し元が commented_bodies を見て判断する）
judge_blocking() {
  local checks_json="$1" mergeable="$2" merge_state_status="$3" review_decision="$4"
  local reasons="[]"
  local blocking="false"

  if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
    reasons=$(jq -c '. + ["changes_requested"]' <<<"$reasons")
    blocking="true"
  fi

  if jq -e 'any(.[]; .bucket == "fail" or .bucket == "cancel")' <<<"$checks_json" >/dev/null 2>&1; then
    reasons=$(jq -c '. + ["ci_failed"]' <<<"$reasons")
    blocking="true"
  fi

  if [ "$mergeable" = "CONFLICTING" ]; then
    reasons=$(jq -c '. + ["conflicting"]' <<<"$reasons")
    blocking="true"
  fi

  if [ "$merge_state_status" = "BLOCKED" ]; then
    reasons=$(jq -c '. + ["merge_blocked"]' <<<"$reasons")
    blocking="true"
  fi

  BLOCKING="$blocking"
  BLOCK_REASONS_JSON="$reasons"
}

# 外部レビュー待機ポーリングを続けるか止めるかを判定する純粋関数。
# 引数: reviews_count, attempt（現在の試行回数。初回チェックが1）, max_attempts
# 戻り値: "stop" または "continue"
#
# - reviews_count > 0（レビューが投稿された） -> stop
# - attempt >= max_attempts（試行回数を使い切った） -> stop
# - それ以外 -> continue
reviews_poll_decision() {
  local reviews_count="$1" attempt="$2" max_attempts="$3"
  if [ "$reviews_count" -gt 0 ]; then
    echo "stop"
    return
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "stop"
    return
  fi
  echo "continue"
}

# 変更ファイルパス配列（files_json: [{path: "...", ...}]）と sensitive パターン
# （改行区切り文字列）から、sensitive パスへの変更が含まれるかを判定する純粋関数。
compute_touches_sensitive() {
  local files_json="$1" patterns="$2"
  local path pattern
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      # shellcheck disable=SC2053
      if [[ "$path" == $pattern ]]; then
        echo "true"
        return
      fi
    done <<<"$patterns"
  done < <(jq -r '.[]?.path // empty' <<<"$files_json")
  echo "false"
}

# risk JSON（files_changed/insertions/deletions/touches_sensitive）を組み立てる。
build_risk_json() {
  local changed_files="$1" insertions="$2" deletions="$3" touches_sensitive="$4"
  jq -n \
    --argjson files_changed "$changed_files" \
    --argjson insertions "$insertions" \
    --argjson deletions "$deletions" \
    --argjson touches_sensitive "$touches_sensitive" \
    '{files_changed: $files_changed, insertions: $insertions, deletions: $deletions, touches_sensitive: $touches_sensitive}'
}

# sensitive パターン一覧を返す（改行区切り文字列）。
# config_path が存在すればそれを読み、コメント行(#)・空行を除外する。
# 存在しなければ内蔵デフォルトにフォールバックする。
load_sensitive_patterns() {
  local config_path="$1"
  if [ -f "$config_path" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$config_path"
  else
    printf '%s\n' "${DEFAULT_SENSITIVE_PATTERNS[@]}"
  fi
}

# ---------------------------------------------------------------------------
# ポーリングループ（外部作用あり。判定は reviews_poll_decision に委譲）
# ---------------------------------------------------------------------------

# 外部レビュー待機ポーリングループ本体。
# 引数: pr_num, initial_reviews_json（fetch_pr_view で取得済みの初回reviews）, timeout_seconds
# 結果はグローバル変数 REVIEWS_JSON に格納する。
#
# テスト時は POLL_SLEEP_CMD に no-op のスタブ関数名を、fetch_pr_reviews_only を
# スタブ関数で上書きすることで、実際に待たずにループ制御を検証できる。
poll_for_reviews() {
  local pr_num="$1" initial_reviews_json="$2" timeout_seconds="$3"
  local interval="$POLL_INTERVAL_SECONDS"
  # 初回チェック + timeout内に実行できる再チェック回数（初回チェック分を別枠にすることで
  # 指定されたtimeout秒数ぶんをフルにポーリングへ使う）。
  local max_attempts=$((timeout_seconds / interval + 1))
  if [ "$max_attempts" -lt 1 ]; then
    max_attempts=1
  fi

  local reviews_json="$initial_reviews_json"
  local count
  count=$(jq 'length' <<<"$reviews_json" 2>/dev/null || echo 0)
  local attempt=1
  local decision
  decision=$(reviews_poll_decision "$count" "$attempt" "$max_attempts")

  while [ "$decision" = "continue" ]; do
    "$POLL_SLEEP_CMD" "$interval"
    attempt=$((attempt + 1))
    reviews_json=$(fetch_pr_reviews_only "$pr_num")
    count=$(jq 'length' <<<"$reviews_json" 2>/dev/null || echo 0)
    decision=$(reviews_poll_decision "$count" "$attempt" "$max_attempts")
  done

  REVIEWS_JSON="$reviews_json"
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <PR番号> [timeout秒（既定: ${DEFAULT_TIMEOUT_SECONDS}）]" >&2
}

main() {
  local pr_num="${1:-}"
  local timeout_seconds="${2:-$DEFAULT_TIMEOUT_SECONDS}"

  if [ -z "$pr_num" ]; then
    print_usage
    exit 1
  fi
  if ! [[ "$pr_num" =~ ^[0-9]+$ ]]; then
    echo "Error: PR number must be numeric, got '${pr_num}'" >&2
    print_usage
    exit 1
  fi
  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]]; then
    echo "Error: timeout seconds must be numeric, got '${timeout_seconds}'" >&2
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  local default_branch
  if ! default_branch="$(fetch_default_branch)"; then
    exit 1
  fi

  local view_json
  if ! view_json="$(fetch_pr_view "$pr_num")"; then
    exit 1
  fi

  local base
  base="$(jq -r '.baseRefName' <<<"$view_json")"
  local gate
  gate="$(determine_gate "$base" "$default_branch")"

  local initial_reviews
  initial_reviews="$(jq -c '.reviews // []' <<<"$view_json")"

  poll_for_reviews "$pr_num" "$initial_reviews" "$timeout_seconds"
  # REVIEWS_JSON はここで確定する

  # ポーリング完了後に CI・mergeable/mergeStateStatus・files/additions/deletions/changedFiles を
  # 再取得する（ポーリング中にCIが完了したり、他の変更でmergeableやfilesが変わったりする場合、
  # ポーリング開始前の古いスナップショットのまま judge_blocking / risk算出に渡ってしまうため）。
  local checks_json
  checks_json="$(fetch_pr_checks "$pr_num")"

  local ci_status
  ci_status="$(determine_ci_status "$checks_json")"
  local ci_json
  ci_json=$(jq -n --arg status "$ci_status" --argjson checks "$checks_json" '{status: $status, checks: $checks}')

  local recheck_json
  if ! recheck_json="$(fetch_pr_recheck "$pr_num")"; then
    exit 1
  fi

  local mergeable merge_state_status
  mergeable="$(jq -r '.mergeable' <<<"$recheck_json")"
  merge_state_status="$(jq -r '.mergeStateStatus' <<<"$recheck_json")"

  # reviewDecision はポーリング完了後の最終状態に合わせて取り直す
  # （ポーリング開始前に取得した古い値を使うと、ポーリング中に投稿されたレビューを
  #  反映しないままjudge_blockingに渡ってしまうため）。
  local review_decision
  review_decision="$(fetch_pr_review_decision "$pr_num")"

  judge_blocking "$checks_json" "$mergeable" "$merge_state_status" "$review_decision"
  # BLOCKING / BLOCK_REASONS_JSON はここで確定する

  local reviews_simple commented_bodies
  reviews_simple=$(jq -c '[.[] | {author: (.author.login // null), state: .state}]' <<<"$REVIEWS_JSON")
  commented_bodies=$(jq -c '[.[] | select(.state == "COMMENTED") | .body]' <<<"$REVIEWS_JSON")

  local files_json insertions deletions changed_files
  files_json="$(jq -c '.files // []' <<<"$recheck_json")"
  insertions="$(jq -r '.additions // 0' <<<"$recheck_json")"
  deletions="$(jq -r '.deletions // 0' <<<"$recheck_json")"
  changed_files="$(jq -r '.changedFiles // 0' <<<"$recheck_json")"

  local patterns touches_sensitive risk_json
  patterns="$(load_sensitive_patterns "$SENSITIVE_PATHS_CONFIG")"
  touches_sensitive="$(compute_touches_sensitive "$files_json" "$patterns")"
  risk_json=$(build_risk_json "$changed_files" "$insertions" "$deletions" "$touches_sensitive")

  jq -n \
    --arg gate "$gate" \
    --arg base "$base" \
    --arg default_branch "$default_branch" \
    --argjson ci "$ci_json" \
    --arg mergeable "$mergeable" \
    --arg mergeStateStatus "$merge_state_status" \
    --argjson reviews "$reviews_simple" \
    --argjson commented_bodies "$commented_bodies" \
    --argjson blocking "$BLOCKING" \
    --argjson block_reasons "$BLOCK_REASONS_JSON" \
    --argjson risk "$risk_json" \
    '{
      gate: $gate,
      base: $base,
      default_branch: $default_branch,
      ci: $ci,
      mergeable: $mergeable,
      mergeStateStatus: $mergeStateStatus,
      reviews: $reviews,
      commented_bodies: $commented_bodies,
      blocking: $blocking,
      block_reasons: $block_reasons,
      risk: $risk
    }'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
