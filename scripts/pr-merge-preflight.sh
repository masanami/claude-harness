#!/bin/bash
# pr-merge-preflight.sh
# 使い方: scripts/pr-merge-preflight.sh <PR番号> [timeout秒]（詳細は下記参照）
# 仕様の正本は scripts/specs/pr-merge-preflight.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# 変数名は source する側（テストファイル等）の SCRIPT_DIR と衝突しないよう
# このスクリプト専用の名前にしている（source すると同名グローバル変数は上書きされるため）。
PR_MERGE_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENSITIVE_PATHS_CONFIG="${PR_MERGE_PREFLIGHT_DIR}/config/sensitive-paths.txt"

# 外部レビュー待機ポーリングは明示指定時だけ行う。
# ローカルレビューを既定ゲートとし、PR上の外部AIレビューを待たない（Issue #155）。
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-60}"
POLL_SLEEP_CMD="${POLL_SLEEP_CMD:-sleep}"
DEFAULT_TIMEOUT_SECONDS=0

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

# fetch_pr_checks は lib/common.sh（scripts/lib/common.sh）に集約（ci-wait.sh と同じ実装。
# ここでは warn_on_empty=1 を渡し、取得失敗/空の際に Warning を出す元の挙動を維持する）。

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
  if jq -e "any(.[]; ${JQ_FAIL_CANCEL_PREDICATE})" <<<"$checks_json" >/dev/null 2>&1; then
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

  if jq -e "any(.[]; ${JQ_FAIL_CANCEL_PREDICATE})" <<<"$checks_json" >/dev/null 2>&1; then
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
# config_path を読み、コメント行(#)・空行を除外する。
# この設定ファイルはスクリプトと同一プラグイン内に同梱されており、欠損＝インストール破損
# なのでフォールバックせず、stderrにファイルパスを含むエラーを出して非0 exitする
# （内蔵デフォルトへのフォールバックは行わない。古い内蔵コピーが黙って使われる方が
#  機微パス検出漏れとして危険なため。Issue #129）。
load_sensitive_patterns() {
  local config_path="$1"
  if [ ! -f "$config_path" ]; then
    echo "Error: sensitive paths config file not found: ${config_path} (installation broken - this file should be bundled with the plugin)" >&2
    return 1
  fi
  local result grep_rc
  result="$(grep -vE '^[[:space:]]*(#|$)' "$config_path")"
  grep_rc=$?
  # grep はマッチ0件（全行コメント/空ファイル）の場合に exit 1 を返すが、これはファイル欠損とは
  # 異なる正常系（有効パターン0件）として扱う。exit 1 のみを許容し、それ以外の非0
  # （例: exit 2 = 読み取り権限が無い等の実エラー）は失敗として伝播させる（セルフレビュー指摘:
  # `|| true` で全ての非0を握りつぶすと、読み取り失敗時もsensitive判定が黙って無効化されるため）。
  if [ "$grep_rc" -gt 1 ]; then
    echo "Error: failed to read sensitive paths config file: ${config_path} (grep exit code ${grep_rc})" >&2
    return 1
  fi
  # 有効なパターンが0件（全行コメント/空ファイル）の場合、compute_touches_sensitive は常にfalseを
  # 返しsensitiveパス検出が全面的に無効化される。ファイル欠損ではないためエラーにはしないが、
  # 黙って無効化されたままにしないよう警告する（セルフレビュー指摘: Issue #129が排除しようとした
  # 「検出が黙って無効化される」状態と同種のため）。
  if [ -z "$result" ]; then
    echo "Warning: sensitive paths config file has no valid patterns (all commented/blank): ${config_path} (sensitive path detection will be disabled)" >&2
  fi
  printf '%s' "$result"
  return 0
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

  # sensitive パターン設定ファイルの読み込みは PR番号にもリモート状態にも依存しない
  # 静的な前提条件（欠損＝インストール破損）のため、明示設定時には長時間になりうる
  # 外部レビュー待機ポーリングやその他の gh 呼び出しより前に fail-fast する（セルフレビュー指摘:
  # Issue #129。ポーリング後まで検出が遅延すると、インストール破損時に無駄な待機の末に
  # 失敗するUXになってしまうため）。
  local patterns
  if ! patterns="$(load_sensitive_patterns "$SENSITIVE_PATHS_CONFIG")"; then
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
  checks_json="$(fetch_pr_checks "$pr_num" 1)"

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

  local touches_sensitive risk_json
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
