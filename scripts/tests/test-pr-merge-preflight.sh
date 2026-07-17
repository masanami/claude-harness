#!/bin/bash
# test-pr-merge-preflight.sh
# scripts/pr-merge-preflight.sh の純粋関数（determine_gate / determine_ci_status /
# judge_blocking / reviews_poll_decision / compute_touches_sensitive / build_risk_json /
# load_sensitive_patterns）とポーリングループ制御（poll_for_reviews）を
# gh API を呼ばずに直接テストする。
#
# 実行方法: bash scripts/tests/test-pr-merge-preflight.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../pr-merge-preflight.sh"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# --- アサーションヘルパー ---

assert_eq() {
  local description="$1"
  local expected="$2"
  local actual="$3"

  if [ "$expected" = "$actual" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected: ${expected}"
    echo "       actual:   ${actual}"
  fi
}

# =============================================================================
echo "=== test: determine_gate ==="
# =============================================================================

assert_eq "base=default_branch(main=main) -> production" \
  "production" "$(determine_gate "main" "main")"
assert_eq "base != default_branch(feat/x != main) -> integration" \
  "integration" "$(determine_gate "feat/x" "main")"
assert_eq "既定ブランチが master のリポジトリでも一致すれば production" \
  "production" "$(determine_gate "master" "master")"

# =============================================================================
echo "=== test: determine_ci_status ==="
# =============================================================================

assert_eq "checksが空配列 -> none" \
  "none" "$(determine_ci_status '[]')"
assert_eq "全チェックpass -> pass" \
  "pass" "$(determine_ci_status '[{"bucket":"pass"},{"bucket":"pass"}]')"
assert_eq "1件でもfailを含む -> fail" \
  "fail" "$(determine_ci_status '[{"bucket":"pass"},{"bucket":"fail"}]')"
assert_eq "fail無しでpending含む -> pending" \
  "pending" "$(determine_ci_status '[{"bucket":"pass"},{"bucket":"pending"}]')"
assert_eq "failとpending両方あれば fail が優先" \
  "fail" "$(determine_ci_status '[{"bucket":"fail"},{"bucket":"pending"}]')"
assert_eq "cancelを含む -> fail扱い（成功と断定できないため）" \
  "fail" "$(determine_ci_status '[{"bucket":"pass"},{"bucket":"cancel"}]')"

# =============================================================================
echo "=== test: judge_blocking ==="
# =============================================================================

# judge_blocking の引数: checks_json, mergeable, merge_state_status, review_decision
# （reviews_json を直接渡さないのは、GitHub側が算出する review_decision を使うことで
#  「レビュアーがCHANGES_REQUESTEDの後にAPPROVEDした」ような解消済みレビューを
#  誤ってblockingし続けないようにするため。fetch_pr_view/judge_blocking のコメント参照）

judge_blocking '[]' "MERGEABLE" "CLEAN" "CHANGES_REQUESTED"
assert_eq "reviewDecisionがCHANGES_REQUESTED -> blocking=true" "true" "$BLOCKING"
assert_eq "reviewDecisionがCHANGES_REQUESTED -> block_reasonsにchanges_requested" \
  "changes_requested" "$(jq -r '.[0]' <<<"$BLOCK_REASONS_JSON")"

judge_blocking '[{"bucket":"fail"}]' "MERGEABLE" "CLEAN" ""
assert_eq "CI失敗あり -> blocking=true" "true" "$BLOCKING"
assert_eq "CI失敗あり -> block_reasonsにci_failed" \
  "ci_failed" "$(jq -r '.[0]' <<<"$BLOCK_REASONS_JSON")"

judge_blocking '[{"bucket":"cancel"}]' "MERGEABLE" "CLEAN" ""
assert_eq "CIがcancelされた -> blocking=true（成功と断定できないため）" "true" "$BLOCKING"
assert_eq "CIがcancelされた -> block_reasonsにci_failed" \
  "ci_failed" "$(jq -r '.[0]' <<<"$BLOCK_REASONS_JSON")"

judge_blocking '[]' "CONFLICTING" "DIRTY" ""
assert_eq "コンフリクトあり -> blocking=true" "true" "$BLOCKING"
assert_eq "コンフリクトあり -> block_reasonsにconflicting" \
  "conflicting" "$(jq -r '.[0]' <<<"$BLOCK_REASONS_JSON")"

judge_blocking '[]' "MERGEABLE" "BLOCKED" ""
assert_eq "mergeStateStatusがBLOCKED -> blocking=true（branch protection未達等）" "true" "$BLOCKING"
assert_eq "mergeStateStatusがBLOCKED -> block_reasonsにmerge_blocked" \
  "merge_blocked" "$(jq -r '.[0]' <<<"$BLOCK_REASONS_JSON")"

judge_blocking '[{"bucket":"pass"}]' "MERGEABLE" "CLEAN" ""
assert_eq "COMMENTEDのみ・CIパス・コンフリクト無し -> blocking=false" "false" "$BLOCKING"
assert_eq "COMMENTEDのみ -> block_reasonsは空" "0" "$(jq 'length' <<<"$BLOCK_REASONS_JSON")"

judge_blocking '[{"bucket":"pass"}]' "MERGEABLE" "CLEAN" "APPROVED"
assert_eq "reviewDecisionがAPPROVED -> blocking=false" "false" "$BLOCKING"

judge_blocking '[]' "MERGEABLE" "CLEAN" ""
assert_eq "reviewDecision無し・CIチェック無し・コンフリクト無し -> blocking=false" "false" "$BLOCKING"

echo "--- 過去に解消済みのCHANGES_REQUESTEDで恒久的にblockingしないことの確認 ---"
echo "    （reviews配列自体は使わず review_decision のみで判定するため、"
echo "     最終的にAPPROVEDになったPRはreviews履歴にCHANGES_REQUESTEDが残っていてもblocking=falseになる）"
judge_blocking '[{"bucket":"pass"}]' "MERGEABLE" "CLEAN" "APPROVED"
assert_eq "レビュー履歴に過去のCHANGES_REQUESTEDが含まれていても、reviewDecisionがAPPROVEDならblocking=false" \
  "false" "$BLOCKING"

judge_blocking '[{"bucket":"fail"}]' "CONFLICTING" "BLOCKED" "CHANGES_REQUESTED"
assert_eq "複合ブロック要因が全部あるとき -> blocking=true" "true" "$BLOCKING"
assert_eq "複合ブロック要因 -> block_reasonsが4件" "4" "$(jq 'length' <<<"$BLOCK_REASONS_JSON")"
assert_eq "複合ブロック要因 -> 理由の中身" \
  "changes_requested ci_failed conflicting merge_blocked" \
  "$(jq -r '[.[]] | join(" ")' <<<"$BLOCK_REASONS_JSON")"

# =============================================================================
echo "=== test: reviews_poll_decision ==="
# =============================================================================

assert_eq "reviews件数>0なら試行回数に関わらずstop" \
  "stop" "$(reviews_poll_decision 1 1 10)"
assert_eq "reviews件数0・attempt<max_attempts -> continue" \
  "continue" "$(reviews_poll_decision 0 1 10)"
assert_eq "reviews件数0・attempt==max_attempts -> stop" \
  "stop" "$(reviews_poll_decision 0 10 10)"
assert_eq "reviews件数0・attempt>max_attempts -> stop" \
  "stop" "$(reviews_poll_decision 0 11 10)"

# =============================================================================
echo "=== test: compute_touches_sensitive ==="
# =============================================================================

PATTERNS_FIXTURE=$'.github/workflows/*\n*secret*\nscripts/*'

assert_eq "workflowファイルの変更 -> true" \
  "true" "$(compute_touches_sensitive '[{"path":".github/workflows/ci.yml"}]' "$PATTERNS_FIXTURE")"
assert_eq "sensitiveな語を含むファイル -> true" \
  "true" "$(compute_touches_sensitive '[{"path":"app/secrets/key.pem"}]' "$PATTERNS_FIXTURE")"
assert_eq "scripts配下の変更 -> true" \
  "true" "$(compute_touches_sensitive '[{"path":"scripts/foo.sh"}]' "$PATTERNS_FIXTURE")"
assert_eq "非sensitiveなファイルのみ -> false" \
  "false" "$(compute_touches_sensitive '[{"path":"src/foo.ts"},{"path":"README.md"}]' "$PATTERNS_FIXTURE")"
assert_eq "複数ファイル中1件だけsensitive -> true" \
  "true" "$(compute_touches_sensitive '[{"path":"src/foo.ts"},{"path":"scripts/bar.sh"}]' "$PATTERNS_FIXTURE")"
assert_eq "空のfiles配列 -> false" \
  "false" "$(compute_touches_sensitive '[]' "$PATTERNS_FIXTURE")"

# =============================================================================
echo "=== test: build_risk_json ==="
# =============================================================================

RISK_FIXTURE=$(build_risk_json 3 16 10 true)
assert_eq "files_changed" "3" "$(jq -r '.files_changed' <<<"$RISK_FIXTURE")"
assert_eq "insertions" "16" "$(jq -r '.insertions' <<<"$RISK_FIXTURE")"
assert_eq "deletions" "10" "$(jq -r '.deletions' <<<"$RISK_FIXTURE")"
assert_eq "touches_sensitive" "true" "$(jq -r '.touches_sensitive' <<<"$RISK_FIXTURE")"

RISK_FIXTURE_FALSE=$(build_risk_json 1 2 0 false)
assert_eq "touches_sensitiveがfalseのケース" "false" "$(jq -r '.touches_sensitive' <<<"$RISK_FIXTURE_FALSE")"

# =============================================================================
echo "=== test: load_sensitive_patterns ==="
# =============================================================================

TMP_CONFIG="$(mktemp)"
cat >"$TMP_CONFIG" <<'EOF'
# comment line
foo/*

bar/*
EOF
LOADED_PATTERNS="$(load_sensitive_patterns "$TMP_CONFIG")"
assert_eq "コメント行・空行を除外して2件" "2" "$(printf '%s\n' "$LOADED_PATTERNS" | grep -c .)"
assert_eq "1件目がfoo/*" "foo/*" "$(printf '%s\n' "$LOADED_PATTERNS" | sed -n '1p')"
rm -f "$TMP_CONFIG"

NONEXISTENT_CONFIG="/tmp/does-not-exist-$$-sensitive-paths.txt"
FALLBACK_PATTERNS="$(load_sensitive_patterns "$NONEXISTENT_CONFIG")"
assert_eq "設定ファイル不在時は内蔵デフォルトにフォールバック" \
  "${#DEFAULT_SENSITIVE_PATTERNS[@]}" "$(printf '%s\n' "$FALLBACK_PATTERNS" | grep -c .)"

echo "=== test: 実際の scripts/config/sensitive-paths.txt を読み込める ==="
# SENSITIVE_PATHS_CONFIG は pr-merge-preflight.sh を source した時点で
# 実ファイルの絶対パスに解決済み（SCRIPT_DIR は source 後に対象スクリプト側の値で
# 上書きされているため、テスト側で SCRIPT_DIR から再計算しない）。
assert_eq "設定ファイルが存在する" "0" "$([ -f "$SENSITIVE_PATHS_CONFIG" ] && echo 0 || echo 1)"
REAL_PATTERNS="$(load_sensitive_patterns "$SENSITIVE_PATHS_CONFIG")"
assert_eq "設定ファイルから1件以上のパターンが読める" \
  "true" "$([ "$(printf '%s\n' "$REAL_PATTERNS" | grep -c .)" -gt 0 ] && echo true || echo false)"

# =============================================================================
echo "=== test: poll_for_reviews（sleepを実際に待たず、フェッチをスタブしてループ制御を検証） ==="
# =============================================================================

SLEEP_CALLS=0
# shellcheck disable=SC2329  # poll_for_reviews から $POLL_SLEEP_CMD 経由で間接的に呼ばれる
fake_sleep() {
  SLEEP_CALLS=$((SLEEP_CALLS + 1))
}

echo "--- ケース1: 初回reviewsが既に非空 -> ポーリングもsleepも発生しない ---"
SLEEP_CALLS=0
# shellcheck disable=SC2034  # poll_for_reviews 内で参照される（source元のグローバル変数）
POLL_SLEEP_CMD="fake_sleep"
# shellcheck disable=SC2034  # poll_for_reviews 内で参照される（source元のグローバル変数）
POLL_INTERVAL_SECONDS=1
# shellcheck disable=SC2329  # poll_for_reviews から間接的に呼ばれる（関数上書き）
fetch_pr_reviews_only() {
  echo "NG: fetch_pr_reviews_only は呼ばれてはいけない" >&2
  echo '[{"state":"SHOULD_NOT_BE_CALLED"}]'
}
poll_for_reviews "123" '[{"state":"APPROVED"}]' 3
assert_eq "初回reviewsが非空ならsleepは呼ばれない" "0" "$SLEEP_CALLS"
assert_eq "REVIEWS_JSONは初回の値のまま" "APPROVED" "$(jq -r '.[0].state' <<<"$REVIEWS_JSON")"

echo "--- ケース2: 初回空・1回目の再フェッチでreviewsが投稿される ---"
SLEEP_CALLS=0
# fetch_pr_reviews_only は poll_for_reviews 内で command substitution ( $(...) ) 経由で
# 呼ばれるためサブシェルで実行される。呼び出し回数を親シェルへ伝搬させるにはファイルに
# 書き出す必要がある（プレーンな変数インクリメントはサブシェル内で消えてしまう）。
FETCH_CALL_COUNT_FILE="$(mktemp)"
echo 0 >"$FETCH_CALL_COUNT_FILE"
# shellcheck disable=SC2329  # poll_for_reviews から間接的に呼ばれる（関数上書き）
fetch_pr_reviews_only() {
  echo "$(($(cat "$FETCH_CALL_COUNT_FILE") + 1))" >"$FETCH_CALL_COUNT_FILE"
  echo '[{"state":"APPROVED"}]'
}
poll_for_reviews "123" '[]' 3
assert_eq "1回の再フェッチで見つかるケース: sleepは1回だけ" "1" "$SLEEP_CALLS"
assert_eq "1回の再フェッチで見つかるケース: 再フェッチは1回だけ" "1" "$(cat "$FETCH_CALL_COUNT_FILE")"
assert_eq "1回の再フェッチで見つかるケース: REVIEWS_JSONが更新される" "APPROVED" "$(jq -r '.[0].state' <<<"$REVIEWS_JSON")"
rm -f "$FETCH_CALL_COUNT_FILE"

echo "--- ケース3: 常に空 -> タイムアウトまでポーリングして空のまま終了 ---"
SLEEP_CALLS=0
# shellcheck disable=SC2329  # poll_for_reviews から間接的に呼ばれる（関数上書き）
fetch_pr_reviews_only() {
  echo '[]'
}
poll_for_reviews "123" '[]' 3
# POLL_INTERVAL_SECONDS=1, timeout=3 -> max_attempts=3 -> 初回1回 + 再フェッチ2回 = sleep 2回
assert_eq "タイムアウトケース: sleepはmax_attempts-1回" "2" "$SLEEP_CALLS"
assert_eq "タイムアウトケース: REVIEWS_JSONは空配列のまま" "0" "$(jq 'length' <<<"$REVIEWS_JSON")"

unset -f fetch_pr_reviews_only

# =============================================================================
echo "=== test: CLIレベル（引数バリデーション。ghを呼ばない） ==="
# =============================================================================

CLI_STDERR_FILE="$(mktemp)"

"$TARGET_SCRIPT" >"$CLI_STDERR_FILE" 2>&1
CLI_EXIT_NO_ARGS=$?
assert_eq "PR番号省略時はexit 1" "1" "$CLI_EXIT_NO_ARGS"

"$TARGET_SCRIPT" "not-a-number" >"$CLI_STDERR_FILE" 2>&1
CLI_EXIT_NAN=$?
assert_eq "PR番号が数値でない場合はexit 1" "1" "$CLI_EXIT_NAN"

"$TARGET_SCRIPT" "1" "not-a-number" >"$CLI_STDERR_FILE" 2>&1
CLI_EXIT_TIMEOUT_NAN=$?
assert_eq "timeout秒が数値でない場合はexit 1" "1" "$CLI_EXIT_TIMEOUT_NAN"

rm -f "$CLI_STDERR_FILE"

echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi

exit 0
