#!/bin/bash
# test-auto-merge-wait.sh
# scripts/auto-merge-wait.sh（/pr-merge が before-merge の宣言で main 宛の PR に自動マージを予約し、上限つきで結果を待つ。#363）の
# 純粋関数（auto_merge_decision）と、gh 呼び出し関数をスタブで上書きした main() の分岐を検証する。
#   - 予約は gh pr merge <PR> --auto --squash --delete-branch で行う
#   - 結果は merged / checks_failed / timeout の 3 つ（stdout の JSON。exit 0）。checks_failed・timeout は予約が残る
#   - 予約の失敗・PR が閉じられた・予約が外れた・状態を取れないまま上限 -> exit 1（stdout は空）
#   - 上限の既定は 30 分。--timeout-minutes で変えられる
#   - 引数の誤りは exit 2（予約しない）
#
# 実行方法: bash scripts/tests/test-auto-merge-wait.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${TEST_DIR}/../auto-merge-wait.sh"

# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

assert_eq() {
  local description="$1" expected="$2" actual="$3"
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

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-auto-merge-wait.XXXXXX")"
trap 'rm -rf "$STATE_DIR"' EXIT

# 偽の時計（main は $(...) のサブシェルで動くので、待った秒数・呼び出しはファイルで数える）。
CLOCK_FILE="$STATE_DIR/clock"
reset_clock() { echo 0 >"$CLOCK_FILE"; : >"$STATE_DIR/reserve-args"; }
elapsed_seconds() { cat "$CLOCK_FILE"; }
fake_sleep() { echo $(($(cat "$CLOCK_FILE") + $1)) >"$CLOCK_FILE"; }
AUTO_MERGE_SLEEP_CMD=fake_sleep

reserve_auto_merge() { echo "$*" >>"$STATE_DIR/reserve-args"; return 0; }

# 状態: MERGE_AT 秒で MERGED、CLOSE_AT 秒で CLOSED、DISABLE_AT 秒で予約が外れる（いずれも空なら起きない）。
MERGE_AT="" CLOSE_AT="" DISABLE_AT="" VIEW_FAIL=""
fetch_pr_merge_state() {
  [ -n "$VIEW_FAIL" ] && return 1
  local now state=OPEN auto='{"mergeMethod":"SQUASH"}'
  now="$(elapsed_seconds)"
  if [ -n "$MERGE_AT" ] && [ "$now" -ge "$MERGE_AT" ]; then state=MERGED auto=null; fi
  if [ -n "$CLOSE_AT" ] && [ "$now" -ge "$CLOSE_AT" ]; then state=CLOSED auto=null; fi
  if [ -n "$DISABLE_AT" ] && [ "$now" -ge "$DISABLE_AT" ]; then auto=null; fi
  printf '{"number":%s,"url":"https://github.com/o/r/pull/%s","state":"%s","autoMergeRequest":%s}' "$1" "$1" "$state" "$auto"
}
# チェック: FAIL_AT 秒で fail が出る。それまでは CHECKS_BEFORE（既定は pending 1 件）。
FAIL_AT="" CHECKS_BEFORE='[{"name":"check","bucket":"pending","workflow":"CI","link":"l"}]'
fetch_pr_checks() {
  local now; now="$(elapsed_seconds)"
  if [ -n "$FAIL_AT" ] && [ "$now" -ge "$FAIL_AT" ]; then
    echo '[{"name":"check / make-check","bucket":"fail","workflow":"CI","link":"https://github.com/o/r/actions/runs/5/job/1"},{"name":"lint","bucket":"pass","workflow":"CI","link":"l2"}]'
  else
    echo "$CHECKS_BEFORE"
  fi
}

run_main() {
  RC=0
  OUT="$(main "$@" 2>"$STATE_DIR/err")" || RC=$?
  ERR="$(cat "$STATE_DIR/err")"
}

echo "=== auto_merge_decision ==="
{
  assert_eq "MERGED -> stop:merged" "stop:merged" "$(auto_merge_decision MERGED false pending 1 5)"
  assert_eq "MERGED は上限でも merged" "stop:merged" "$(auto_merge_decision MERGED false red 5 5)"
  assert_eq "CLOSED -> stop:closed" "stop:closed" "$(auto_merge_decision CLOSED false pending 1 5)"
  assert_eq "OPEN・予約あり・red -> stop:checks_failed" "stop:checks_failed" "$(auto_merge_decision OPEN true red 1 5)"
  assert_eq "OPEN・予約なし -> stop:disabled" "stop:disabled" "$(auto_merge_decision OPEN false pending 1 5)"
  assert_eq "OPEN・予約あり・pending -> continue" "continue" "$(auto_merge_decision OPEN true pending 1 5)"
  assert_eq "OPEN・予約あり・empty（CI の起動待ち） -> continue" "continue" "$(auto_merge_decision OPEN true empty 1 5)"
  assert_eq "OPEN・予約あり・green（マージ待ち） -> continue" "continue" "$(auto_merge_decision OPEN true green 2 5)"
  assert_eq "OPEN・予約あり・pending・上限 -> stop:timeout" "stop:timeout" "$(auto_merge_decision OPEN true pending 5 5)"
}

echo ""
echo "=== main(): 予約してマージされた -> merged ==="
{
  reset_clock; MERGE_AT=90 CLOSE_AT="" DISABLE_AT="" FAIL_AT="" VIEW_FAIL=""
  run_main 7
  assert_eq "exit 0" "0" "$RC"
  assert_eq "予約のコマンド" "7 --auto --squash --delete-branch" "$(cat "$STATE_DIR/reserve-args")"
  assert_eq "result: merged" "merged" "$(jq -r '.result' <<<"$OUT")"
  assert_eq "auto_merge_kept: false" "false" "$(jq -r '.auto_merge_kept' <<<"$OUT")"
  assert_eq "pr_number" "7" "$(jq -r '.pr_number' <<<"$OUT")"
  assert_eq "pr_url" "https://github.com/o/r/pull/7" "$(jq -r '.pr_url' <<<"$OUT")"
  assert_eq "マージを観測した時点で止まる(90秒)" "90" "$(elapsed_seconds)"
  assert_eq "waited_seconds" "90" "$(jq -r '.waited_seconds' <<<"$OUT")"
  assert_eq "timeout_minutes の既定は 30" "30" "$(jq -r '.timeout_minutes' <<<"$OUT")"
}

echo ""
echo "=== main(): チェックが落ちた -> checks_failed（予約は残る） ==="
{
  reset_clock; MERGE_AT="" FAIL_AT=60
  run_main 7
  assert_eq "exit 0" "0" "$RC"
  assert_eq "result: checks_failed" "checks_failed" "$(jq -r '.result' <<<"$OUT")"
  assert_eq "auto_merge_kept: true" "true" "$(jq -r '.auto_merge_kept' <<<"$OUT")"
  assert_eq "failed_checks は落ちたものだけ" '[{"name":"check / make-check","workflow":"CI","link":"https://github.com/o/r/actions/runs/5/job/1"}]' "$(jq -c '.failed_checks' <<<"$OUT")"
  assert_eq "落ちた時点で止まる(60秒)" "60" "$(elapsed_seconds)"
}

echo ""
echo "=== main(): 上限に達した -> timeout（予約は残る）。既定 30 分・--timeout-minutes で変えられる ==="
{
  reset_clock; FAIL_AT=""
  run_main 7
  assert_eq "exit 0" "0" "$RC"
  assert_eq "result: timeout" "timeout" "$(jq -r '.result' <<<"$OUT")"
  assert_eq "auto_merge_kept: true" "true" "$(jq -r '.auto_merge_kept' <<<"$OUT")"
  assert_eq "既定の上限 30 分(1800秒)まで待つ" "1800" "$(elapsed_seconds)"

  reset_clock
  run_main 7 --timeout-minutes 5 --interval 60
  assert_eq "--timeout-minutes 5 -> timeout" "timeout" "$(jq -r '.result' <<<"$OUT")"
  assert_eq "--timeout-minutes 5 -> 300 秒で止まる" "300" "$(elapsed_seconds)"
  assert_eq "timeout_minutes が出力に載る" "5" "$(jq -r '.timeout_minutes' <<<"$OUT")"

  # チェックが 0 件のまま（CI が予約で起動していない等）でも、none とは決めずに上限まで待つ。
  reset_clock; CHECKS_BEFORE='[]'
  run_main 7 --timeout-minutes 1
  assert_eq "チェック 0 件のまま -> timeout" "timeout" "$(jq -r '.result' <<<"$OUT")"
  CHECKS_BEFORE='[{"name":"check","bucket":"pending","workflow":"CI","link":"l"}]'

  # 通ったがマージされていない（必須レビュー待ち等）も上限で timeout。
  reset_clock; CHECKS_BEFORE='[{"name":"check","bucket":"pass","workflow":"CI","link":"l"}]'
  run_main 7 --timeout-minutes 1
  assert_eq "green のままマージされない -> timeout" "timeout" "$(jq -r '.result' <<<"$OUT")"
  CHECKS_BEFORE='[{"name":"check","bucket":"pending","workflow":"CI","link":"l"}]'
}

echo ""
echo "=== main(): 異常 -> exit 1（stdout は空） ==="
{
  reset_clock
  reserve_auto_merge() { echo "auto-merge is not allowed for this repository" >&2; return 1; }
  run_main 7
  assert_eq "予約の失敗 -> exit 1" "1" "$RC"
  assert_eq "予約の失敗 -> stdout 空" "" "$OUT"
  assert_eq "予約の失敗 -> 待たない" "0" "$(elapsed_seconds)"
  reserve_auto_merge() { echo "$*" >>"$STATE_DIR/reserve-args"; return 0; }

  reset_clock; CLOSE_AT=30
  run_main 7
  assert_eq "PR が閉じられた -> exit 1" "1" "$RC"
  assert_eq "PR が閉じられた -> stdout 空" "" "$OUT"
  CLOSE_AT=""

  reset_clock; DISABLE_AT=30
  run_main 7
  assert_eq "予約が外れた -> exit 1" "1" "$RC"
  assert_eq "予約が外れた -> 理由を stderr に出す" "true" "$(grep -qi 'auto-merge' <<<"$ERR" && echo true || echo false)"
  DISABLE_AT=""

  reset_clock; VIEW_FAIL=1
  run_main 7 --timeout-minutes 1
  assert_eq "状態を取れないまま上限 -> exit 1" "1" "$RC"
  assert_eq "状態を取れなくても上限までは取り直す" "60" "$(elapsed_seconds)"
  VIEW_FAIL=""
}

echo ""
echo "=== 引数の誤り -> exit 2（予約しない） ==="
{
  for bad in "" "abc" "0" "7 --timeout-minutes 0" "7 --timeout-minutes x" "7 --interval 0" "7 --nope 1" "7 8"; do
    reset_clock
    # shellcheck disable=SC2086
    run_main $bad
    assert_eq "引数 [${bad}] -> exit 2" "2" "$RC"
    assert_eq "引数 [${bad}] -> 予約しない" "" "$(cat "$STATE_DIR/reserve-args")"
  done
}

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
