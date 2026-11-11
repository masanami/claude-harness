#!/bin/bash
# test-ci-wait.sh
# scripts/ci-wait.sh の純粋関数（classify_checks / ci_wait_decision / extract_run_id /
# extract_run_ids / build_failed_checks_json / tail_lines / truncate_to_budget）と、
# gh呼び出し関数をスタブで上書きした main() の分岐（pr_exists false / green / red /
# timeout / none 確定〔チェック 0 件が約 120 秒続いてから。#341〕・attempt=1でのsingle-shotモード / 1ジョブ失敗・他ジョブ実行中で run の完了を
# 待ってからログを取る〔#295〕）を検証する。
#
# 実行方法: bash scripts/tests/test-ci-wait.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../ci-wait.sh"

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

# 実際に sleep させない（ループ制御のみ検証したいテストで使う）。
noop_sleep() { :; }

echo "=== classify_checks ==="
{
  assert_eq "空配列 -> empty" "empty" "$(classify_checks '[]')"
  assert_eq "全てpass -> green" "green" "$(classify_checks '[{"bucket":"pass"},{"bucket":"skipping"}]')"
  assert_eq "pending混在(fail無し) -> pending" "pending" "$(classify_checks '[{"bucket":"pass"},{"bucket":"pending"}]')"
  assert_eq "fail混在(pending有り) -> red(待たずに確定)" "red" "$(classify_checks '[{"bucket":"pending"},{"bucket":"fail"}]')"
  assert_eq "cancel -> red" "red" "$(classify_checks '[{"bucket":"cancel"}]')"
}

echo ""
echo "=== ci_wait_decision ==="
{
  # 引数: classification attempt max_attempts empty_elapsed秒 none_confirm秒（#341: 回数ではなく待った時間で none を確定する）
  assert_eq "red -> stop:red" "stop:red" "$(ci_wait_decision "red" 1 5 0 120)"
  assert_eq "green -> stop:green" "stop:green" "$(ci_wait_decision "green" 1 5 0 120)"
  assert_eq "empty かつ 0件の継続が0秒(初回) -> continue" "continue" "$(ci_wait_decision "empty" 1 31 0 120)"
  assert_eq "empty かつ 0件の継続が30秒(旧実装では none だった) -> continue" "continue" "$(ci_wait_decision "empty" 2 31 30 120)"
  assert_eq "empty かつ 0件の継続が119秒 -> continue" "continue" "$(ci_wait_decision "empty" 2 31 119 120)"
  assert_eq "empty かつ 0件の継続が120秒に到達 -> stop:none" "stop:none" "$(ci_wait_decision "empty" 5 31 120 120)"
  assert_eq "empty かつ 0件の継続が120秒超 -> stop:none" "stop:none" "$(ci_wait_decision "empty" 3 31 126 120)"
  assert_eq "empty かつ attemptがmax到達(120秒未達でも) -> stop:none(timeoutにしない)" "stop:none" "$(ci_wait_decision "empty" 3 3 60 120)"
  assert_eq "pending かつ attempt未達 -> continue" "continue" "$(ci_wait_decision "pending" 2 5 0 120)"
  assert_eq "pending かつ attemptがmax到達 -> stop:timeout" "stop:timeout" "$(ci_wait_decision "pending" 5 5 0 120)"
}

echo ""
echo "=== extract_run_id / extract_run_ids ==="
{
  assert_eq "runs/xxx/job/yyy 形式からrun_idを抽出" "123456789" "$(extract_run_id "https://github.com/o/r/actions/runs/123456789/job/987654321")"
  assert_eq "マッチしないlinkは空文字" "" "$(extract_run_id "https://example.com/no-run-id")"

  failed='[{"name":"a","workflow":"w1","link":"https://github.com/o/r/actions/runs/111/job/1"},{"name":"b","workflow":"w1","link":"https://github.com/o/r/actions/runs/111/job/2"},{"name":"c","workflow":"w2","link":"https://github.com/o/r/actions/runs/222/job/3"}]'
  run_ids="$(extract_run_ids "$failed")"
  run_ids_count="$(echo "$run_ids" | grep -c .)"
  assert_eq "同一run_idは重複排除され一意になる(2件)" "2" "$run_ids_count"
  assert_eq "1件目のrun_idは111" "111" "$(echo "$run_ids" | sed -n '1p')"
  assert_eq "2件目のrun_idは222" "222" "$(echo "$run_ids" | sed -n '2p')"
}

echo ""
echo "=== build_failed_checks_json ==="
{
  checks='[{"name":"a","bucket":"pass","workflow":"w","link":"l1"},{"name":"b","bucket":"fail","workflow":"w","link":"l2"},{"name":"c","bucket":"cancel","workflow":"w","link":"l3"}]'
  failed="$(build_failed_checks_json "$checks")"
  failed_count="$(jq 'length' <<<"$failed")"
  assert_eq "fail/cancelのみ抽出(2件)" "2" "$failed_count"
  assert_eq "1件目の名前はb" "b" "$(jq -r '.[0].name' <<<"$failed")"
}

echo ""
echo "=== run_status_is_unfinished ==="
{
  for st in queued in_progress waiting requested pending; do
    assert_eq "${st} -> 未完了(待つ)" "true" "$(run_status_is_unfinished "$st" && echo true || echo false)"
  done
  assert_eq "completed -> 完了(待たない)" "false" "$(run_status_is_unfinished completed && echo true || echo false)"
  assert_eq "空(取得失敗) -> 待たない(従来どおりログ取得へ進む)" "false" "$(run_status_is_unfinished "" && echo true || echo false)"
}

echo ""
echo "=== tail_lines / truncate_to_budget ==="
{
  multi_line="$(printf 'l1\nl2\nl3\nl4\nl5\n')"
  tailed="$(tail_lines "$multi_line" 2)"
  assert_eq "tail_lines: 末尾2行のみ" "$(printf 'l4\nl5')" "$tailed"

  short="hello"
  assert_eq "truncate_to_budget: budget以下ならそのまま" "$short" "$(truncate_to_budget "$short" 100)"

  long="$(printf 'x%.0s' $(seq 1 200))"
  truncated="$(truncate_to_budget "$long" 50)"
  truncated_len=${#truncated}
  assert_eq "truncate_to_budget: budget超過時は先頭にマーカー+末尾のみ残る(短くなる)" "true" "$([ "$truncated_len" -lt 200 ] && echo true || echo false)"
  assert_eq "truncate_to_budget: 切り詰めマーカーを含む" "true" "$(echo "$truncated" | grep -q '(truncated)' && echo true || echo false)"
}

echo ""
echo "=== main(): PR不存在 -> pr_exists:false, ci:none で即終了(ポーリングしない) ==="
{
  fetch_pr_view() { return 1; }
  output="$(main "no-such-branch" 900 30)"
  assert_eq "pr_exists: false" "false" "$(jq -r '.pr_exists' <<<"$output")"
  assert_eq "ci: none" "none" "$(jq -r '.ci' <<<"$output")"
  assert_eq "pr_number: null" "null" "$(jq -r '.pr_number' <<<"$output")"
}

echo ""
echo "=== main(): PR存在・即green(全checks pass) ==="
{
  fetch_pr_view() {
    PR_VIEW_JSON='{"number":42,"url":"https://github.com/o/r/pull/42","state":"OPEN"}'
    return 0
  }
  fetch_pr_checks() { echo '[{"name":"build","state":"SUCCESS","bucket":"pass","description":"","workflow":"CI","link":"l"}]'; }
  POLL_SLEEP_CMD=noop_sleep

  output="$(main "42" 900 30)"
  assert_eq "pr_exists: true" "true" "$(jq -r '.pr_exists' <<<"$output")"
  assert_eq "ci: green" "green" "$(jq -r '.ci' <<<"$output")"
  assert_eq "pr_number: 42" "42" "$(jq -r '.pr_number' <<<"$output")"
  assert_eq "failed_checks: 空配列" "0" "$(jq '.failed_checks | length' <<<"$output")"
}

echo ""
echo "=== main(): PR存在・red(失敗チェック)・ログ抽出 ==="
{
  fetch_pr_view() {
    PR_VIEW_JSON='{"number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN"}'
    return 0
  }
  fetch_pr_checks() { echo '[{"name":"test","state":"FAILURE","bucket":"fail","description":"","workflow":"CI","link":"https://github.com/o/r/actions/runs/999/job/1"}]'; }
  fetch_run_log_failed() { printf 'line1\nline2\nERROR: boom\n'; }
  POLL_SLEEP_CMD=noop_sleep

  output="$(main "7" 900 30)"
  assert_eq "ci: red" "red" "$(jq -r '.ci' <<<"$output")"
  assert_eq "failed_checks: 1件" "1" "$(jq '.failed_checks | length' <<<"$output")"
  assert_eq "failure_log_excerptにログ内容が含まれる" "true" "$(echo "$output" | jq -r '.failure_log_excerpt' | grep -q 'ERROR: boom' && echo true || echo false)"
}

echo ""
echo "=== main(): pending続きでtimeout ==="
{
  fetch_pr_view() {
    PR_VIEW_JSON='{"number":9,"url":"https://github.com/o/r/pull/9","state":"OPEN"}'
    return 0
  }
  fetch_pr_checks() { echo '[{"name":"build","state":"IN_PROGRESS","bucket":"pending","description":"","workflow":"CI","link":"l"}]'; }
  POLL_SLEEP_CMD=noop_sleep

  # timeout=60, interval=30 -> max_attempts = 60/30+1 = 3
  output="$(main "9" 60 30)"
  assert_eq "ci: timeout" "timeout" "$(jq -r '.ci' <<<"$output")"
}

echo ""
echo "=== main(): timeout=0 は single-shot(ポーリングせず1回で確定) ==="
{
  fetch_pr_view() {
    PR_VIEW_JSON='{"number":13,"url":"https://github.com/o/r/pull/13","state":"OPEN"}'
    return 0
  }
  call_count=0
  fetch_pr_checks() {
    call_count=$((call_count + 1))
    echo '[{"name":"build","state":"IN_PROGRESS","bucket":"pending","description":"","workflow":"CI","link":"l"}]'
  }
  POLL_SLEEP_CMD=noop_sleep

  output="$(main "13" 0 30)"
  assert_eq "timeout=0でpending -> stop:timeout相当(1回で確定)" "timeout" "$(jq -r '.ci' <<<"$output")"
}

# main は $(...) のサブシェルで動くため、呼び出し回数・待った秒数はファイルで数える
# （#295 の run の完了待ちと、#341 の「CI 無し」の確定の待ちのテストで使う）。
STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-ci-wait.XXXXXX")"
trap 'rm -rf "$STATE_DIR"' EXIT

# ---------------------------------------------------------------------------
# #341: 「CI 無し（none）」は、チェック 0 件が約 120 秒続いてから確定する（回数ではなく待った時間）。
# 偽の時計: sleep を実際には待たず、渡された秒数を足し込むだけにする。偽の gh は、足し込んだ秒数
# （＝ポーリング開始からの経過秒）に応じてチェックの一覧を返す。
# ---------------------------------------------------------------------------
reset_clock() { rm -f "$STATE_DIR"/*; echo 0 > "$STATE_DIR/elapsed"; }
clock_sleep() { echo $(( $(cat "$STATE_DIR/elapsed") + $1 )) > "$STATE_DIR/elapsed"; }
elapsed_seconds() { cat "$STATE_DIR/elapsed"; }
fake_checks_pass='[{"name":"build","state":"SUCCESS","bucket":"pass","description":"","workflow":"CI","link":"l"}]'
fake_checks_pending='[{"name":"build","state":"IN_PROGRESS","bucket":"pending","description":"","workflow":"CI","link":"l"}]'
fake_checks_fail='[{"name":"test","state":"FAILURE","bucket":"fail","description":"","workflow":"CI","link":"https://github.com/o/r/actions/runs/777/job/1"}]'
# CHECKS_APPEAR_AT 秒以降は CHECKS_AFTER を返し、それより前は 0 件を返す。
fetch_pr_checks_by_clock() {
  if [ "$(elapsed_seconds)" -ge "$CHECKS_APPEAR_AT" ]; then
    echo "$CHECKS_AFTER"
  else
    echo '[]'
  fi
}
fetch_pr_view() {
  PR_VIEW_JSON='{"number":11,"url":"https://github.com/o/r/pull/11","state":"OPEN"}'
  return 0
}
fetch_run_status() { echo completed; }
fetch_run_log_failed() { printf 'FAIL: late check\n'; }
POLL_SLEEP_CMD=clock_sleep

echo ""
echo "=== main(): 取得の失敗は none にしない (#343) ==="
{
  fetch_pr_checks() { echo "Warning: failed" >&2; return 1; }
  reset_clock
  rc=0
  output="$(main "11" 300 30 2>/dev/null)" || rc=$?
  assert_eq "取得失敗が続けば exit 1" "1" "$rc"
  assert_eq "取得失敗では ci: none を出さない" "" "$output"
  assert_eq "取得失敗でも timeout の枠(300秒)を使い切るまで再試行する" "300" "$(elapsed_seconds)"

  CALLS_FILE="$STATE_DIR/calls"; echo 0 >"$CALLS_FILE"
  fetch_pr_checks() {
    local n; n=$(($(cat "$CALLS_FILE") + 1)); echo "$n" >"$CALLS_FILE"
    if [ "$n" -le 2 ]; then return 1; fi
    echo "$fake_checks_pass"
  }
  reset_clock
  output="$(main "11" 300 30 2>/dev/null)"
  assert_eq "失敗の後に取得できれば green" "green" "$(jq -r '.ci' <<<"$output")"
}

echo ""
echo "=== main(): ① ③ チェック 0 件のまま -> 約 120 秒経つまで none にならず、120 秒で none (#341) ==="
{
  fetch_pr_checks() { echo '[]'; }
  reset_clock
  output="$(main "11" 900 30)"
  assert_eq "0件が続けば ci: none" "none" "$(jq -r '.ci' <<<"$output")"
  assert_eq "none の確定までに 120 秒待った(30秒×4。旧実装は30秒)" "120" "$(elapsed_seconds)"
}

echo ""
echo "=== main(): ② 60〜90 秒後にチェックが現れたら none ではなく結果の判定へ進む (#341) ==="
{
  fetch_pr_checks() { fetch_pr_checks_by_clock; }
  for at in 60 90; do
    CHECKS_APPEAR_AT=$at CHECKS_AFTER="$fake_checks_pass"; reset_clock
    assert_eq "${at}秒後に pass が現れる -> ci: green" "green" "$(jq -r '.ci' <<<"$(main "11" 900 30)")"

    CHECKS_APPEAR_AT=$at CHECKS_AFTER="$fake_checks_fail"; reset_clock
    output="$(main "11" 900 30)"
    assert_eq "${at}秒後に fail が現れる -> ci: red" "red" "$(jq -r '.ci' <<<"$output")"
    assert_eq "${at}秒後に fail が現れる -> 失敗ログを取る" "true" "$(jq -r '.failure_log_excerpt' <<<"$output" | grep -q 'FAIL: late check' && echo true || echo false)"

    CHECKS_APPEAR_AT=$at CHECKS_AFTER="$fake_checks_pending"; reset_clock
    assert_eq "${at}秒後に pending が現れ終わらない -> ci: timeout(none にしない)" "timeout" "$(jq -r '.ci' <<<"$(main "11" 300 30)")"
  done
}

echo ""
echo "=== main(): ④ poll 間隔を変えても、none の確定までの待ちは約 120 秒 (#341) ==="
{
  fetch_pr_checks() { echo '[]'; }
  # 120 秒に達した最初の poll で確定する（120 以上・120+間隔 未満）。
  for interval_and_expected in "10:120" "7:126" "45:135" "120:120" "1:120"; do
    interval="${interval_and_expected%%:*}" expected="${interval_and_expected##*:}"
    reset_clock
    output="$(main "11" 900 "$interval")"
    assert_eq "間隔${interval}秒: ci: none" "none" "$(jq -r '.ci' <<<"$output")"
    assert_eq "間隔${interval}秒: none の確定までに ${expected} 秒待った" "$expected" "$(elapsed_seconds)"
  done
}

echo ""
echo "=== main(): 0 件が途中で途切れたら、120 秒を数え直す (#341) ==="
{
  # 0〜60秒は 0 件、90秒に pending が 1 回だけ出て、その後はまた 0 件。
  fetch_pr_checks() {
    if [ "$(elapsed_seconds)" -eq 90 ]; then echo "$fake_checks_pending"; else echo '[]'; fi
  }
  reset_clock
  output="$(main "11" 900 30)"
  assert_eq "途切れた後も 0 件が続けば ci: none" "none" "$(jq -r '.ci' <<<"$output")"
  assert_eq "途切れた後の 0 件(120秒〜)から数え直して 240 秒で確定" "240" "$(elapsed_seconds)"
}

echo ""
echo "=== main(): timeout が 120 秒より短いときは、今の結果を変えない(timeout の時点で 0 件なら none) (#341) ==="
{
  fetch_pr_checks() { echo '[]'; }
  reset_clock
  output="$(main "11" 60 30)"
  assert_eq "timeout=60: 枠の終わりで 0 件 -> ci: none(timeout にしない)" "none" "$(jq -r '.ci' <<<"$output")"
  assert_eq "timeout=60: timeout の枠(60秒)を超えて待たない" "60" "$(elapsed_seconds)"

  reset_clock
  output="$(main "11" 0 30)"
  assert_eq "timeout=0(single-shot): 0 件 -> ci: none" "none" "$(jq -r '.ci' <<<"$output")"
  assert_eq "timeout=0(single-shot): 待たない" "0" "$(elapsed_seconds)"
}

echo ""
echo "=== main(): 既定の timeout(900秒) の中で none が確定する (#341) ==="
{
  fetch_pr_checks() { echo '[]'; }
  reset_clock
  output="$(main "11")"
  assert_eq "既定の引数: ci: none" "none" "$(jq -r '.ci' <<<"$output")"
  assert_eq "既定の引数: 120 秒で確定(900秒の枠と ticket の ci ステップの 20 分に収まる)" "120" "$(elapsed_seconds)"
}

# 偽の GitHub: run 999 は status を run-finish-after 回目の照会で completed にする。--log-failed は
# 本物と同じく run が completed になるまで何も返さない（stderr にだけ出す）。
reset_run_state() {
  rm -f "$STATE_DIR"/*
  echo "$1" > "$STATE_DIR/run-finish-after"
}
fetch_run_status() {
  local n
  n=$(( $(cat "$STATE_DIR/status.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE_DIR/status.count"
  if [ "$n" -ge "$(cat "$STATE_DIR/run-finish-after")" ]; then
    : > "$STATE_DIR/run-completed"
    echo completed
  else
    echo in_progress
  fi
}
fetch_run_log_failed() {
  if [ -f "$STATE_DIR/run-completed" ]; then
    printf 'line1\nFAIL: test_widget (ubuntu)\n'
  else
    echo "run $1 is still in progress; logs will be available when it is complete" >&2
  fi
}
counting_sleep() {
  echo x >> "$STATE_DIR/sleeps"
}
sleep_count() { grep -c x "$STATE_DIR/sleeps" 2>/dev/null || echo 0; }

echo ""
echo "=== main(): 1ジョブ失敗・他ジョブ実行中 -> run の完了を待ってからログを取る(#295) ==="
{
  fetch_pr_view() {
    PR_VIEW_JSON='{"number":15,"url":"https://github.com/o/r/pull/15","state":"OPEN"}'
    return 0
  }
  fetch_pr_checks() { echo '[{"name":"test (ubuntu-latest)","state":"FAILURE","bucket":"fail","description":"","workflow":"CI","link":"https://github.com/o/r/actions/runs/999/job/1"},{"name":"test (macos-latest)","state":"IN_PROGRESS","bucket":"pending","description":"","workflow":"CI","link":"https://github.com/o/r/actions/runs/999/job/2"}]'; }
  POLL_SLEEP_CMD=counting_sleep

  # 3回目の照会で completed（2回 sleep してから取れる）。
  reset_run_state 3
  output="$(main "15" 900 30)"
  assert_eq "ci: red(失敗は確定のまま)" "red" "$(jq -r '.ci' <<<"$output")"
  assert_eq "failed_checks: 失敗したジョブ1件のみ" "1" "$(jq '.failed_checks | length' <<<"$output")"
  assert_eq "run の完了後のログが failure_log_excerpt に入る(空にならない)" "true" "$(jq -r '.failure_log_excerpt' <<<"$output" | grep -q 'FAIL: test_widget' && echo true || echo false)"
  assert_eq "run が完了するまで poll 間隔で待った(2回)" "2" "$(sleep_count)"

  # 既に completed の run は待たない。
  reset_run_state 1
  output="$(main "15" 900 30)"
  assert_eq "完了済みの run: 待たずにログを取る(sleep 0回)" "0" "$(sleep_count)"
  assert_eq "完了済みの run: ログが入る" "true" "$(jq -r '.failure_log_excerpt' <<<"$output" | grep -q 'FAIL: test_widget' && echo true || echo false)"

  # timeout の枠（max_attempts = 60/30+1 = 3）を超えては待たない。枠内で終わらなければ従来どおりログは空。
  reset_run_state 100
  output="$(main "15" 60 30 2>/dev/null)"
  assert_eq "枠を使い切ったら待つのをやめる(sleep は max_attempts-1 = 2回まで)" "2" "$(sleep_count)"
  assert_eq "枠内に完了しなければ ci は red のまま" "red" "$(jq -r '.ci' <<<"$output")"
  assert_eq "枠内に完了しなければログは空(従来どおり)" "" "$(jq -r '.failure_log_excerpt' <<<"$output")"
  assert_eq "枠内に完了しなければ stderr で知らせる" "true" "$(main "15" 60 30 2>&1 >/dev/null | grep -q 'still in progress' && echo true || echo false)"

  # single-shot（timeout=0）は待たない。
  reset_run_state 100
  main "15" 0 30 >/dev/null 2>&1
  assert_eq "timeout=0: 待たない(sleep 0回)" "0" "$(sleep_count)"
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
