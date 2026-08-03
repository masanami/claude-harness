#!/bin/bash
# test-run-walkthrough-pause-ms.sh
# skills/demo/scripts/run-walkthrough.mjs が WALKTHROUGH_PAUSE_MS をパースする際の
# 純粋関数 parsePauseMs（skills/demo/scripts/lib/parse-pause-ms.mjs）を検証する（Issue #148）。
#
# run-walkthrough.mjs 本体は Playwright 起動を伴うため完全な自動テストは困難だが、
# env パース部分（正の整数のみ受理・不正値は無効化＝静止しない）は副作用の無い
# 純粋関数に切り出してあるため、node の ESM 動的評価経由で外部コマンドを叩かずに検証できる。
#
# 実行方法: bash scripts/tests/test-run-walkthrough-pause-ms.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PARSE_MODULE="${REPO_ROOT}/skills/demo/scripts/lib/parse-pause-ms.mjs"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

if ! command -v node >/dev/null 2>&1; then
  echo "NG - node が見つからないためテストを実行できません"
  exit 1
fi

if [ ! -f "$PARSE_MODULE" ]; then
  echo "NG - ${PARSE_MODULE} が見つかりません"
  exit 1
fi

# $1: テスト名, $2: env値をセットするか(1/0), $3: env値(セットする場合), $4: 期待値("null" または数値文字列)
run_case() {
  local desc="$1"
  local set_env="$2"
  local raw_value="$3"
  local expected="$4"

  local actual
  if [ "$set_env" = "1" ]; then
    actual="$(TEST_PAUSE_MS_RAW="$raw_value" node --input-type=module -e "
      import { parsePauseMs } from '${PARSE_MODULE}';
      const result = parsePauseMs(process.env.TEST_PAUSE_MS_RAW);
      console.log(result === null ? 'null' : String(result));
    " 2>&1)"
  else
    actual="$(node --input-type=module -e "
      import { parsePauseMs } from '${PARSE_MODULE}';
      const result = parsePauseMs(undefined);
      console.log(result === null ? 'null' : String(result));
    " 2>&1)"
  fi
  local node_exit=$?

  if [ "$node_exit" -ne 0 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("${desc}: node実行エラー(exit ${node_exit}): ${actual}")
    echo "  NG - ${desc}: node実行エラー(exit ${node_exit})"
    echo "       ${actual}"
    return
  fi

  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${desc}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("${desc}: expected=${expected} actual=${actual}")
    echo "  NG - ${desc}: expected=${expected} actual=${actual}"
  fi
}

echo "=== parsePauseMs: 正の整数は有効値として受理される ==="
run_case "5000（既定値相当）" 1 "5000" "5000"
run_case "1（最小の正の整数）" 1 "1" "1"
run_case "2000（他の正の整数）" 1 "2000" "2000"

echo ""
echo "=== parsePauseMs: 未指定時は null（＝静止しない。従来挙動） ==="
run_case "env未指定" 0 "" "null"
run_case "空文字" 1 "" "null"

echo ""
echo "=== parsePauseMs: 不正値は無効化され null になる ==="
run_case "0（正の整数ではない）" 1 "0" "null"
run_case "負数" 1 "-100" "null"
run_case "非数値文字列" 1 "abc" "null"
run_case "小数" 1 "500.5" "null"
run_case "数値+単位付き文字列" 1 "5000ms" "null"
run_case "先頭ゼロ付き数値文字列" 1 "0500" "null"
run_case "16進表記" 1 "0x10" "null"
run_case "指数表記" 1 "5e3" "null"
run_case "先頭プラス符号付き" 1 "+5000" "null"
run_case "前後に空白を含む数値文字列" 1 " 5000 " "null"

echo ""
echo "=== run-walkthrough.mjs 側の配線チェック（回帰ガード） ==="
# parsePauseMs 単体は上記で検証済みだが、run-walkthrough.mjs 側で
# import されていること・ctx.goto / ctx.step の完了直後に実際に
# waitForTimeout(pauseMs) が呼ばれていることまではここまでのテストでは
# 検証できない（run-walkthrough.mjs は Playwright 起動を伴うため import 不能）。
# grep ベースで存在確認する（scripts/tests/test-path-conventions.sh と同じ手法）。
RUNNER_FILE="${REPO_ROOT}/skills/demo/scripts/run-walkthrough.mjs"

if [ ! -f "$RUNNER_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("run-walkthrough.mjs が見つかりません: ${RUNNER_FILE}")
  echo "  NG - ${RUNNER_FILE} が見つかりません"
else
  # $1: テスト名, $2: 検索パターン(拡張正規表現)
  assert_runner_contains() {
    local desc="$1"
    local pattern="$2"
    if grep -qE "$pattern" "$RUNNER_FILE"; then
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok - ${desc}"
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("${desc}: パターン未検出: ${pattern}")
      echo "  NG - ${desc}: パターン未検出"
    fi
  }

  assert_runner_contains "parsePauseMs を lib/parse-pause-ms.mjs から import している" \
    "import \{ parsePauseMs \} from '\./lib/parse-pause-ms\.mjs'"

  waitfortimeout_count="$(grep -cE 'if \(pauseMs\) await page\.waitForTimeout\(pauseMs\)' "$RUNNER_FILE")"
  if [ "$waitfortimeout_count" -ge 2 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - waitForTimeout(pauseMs) 呼び出しが2箇所以上存在する(ctx.goto/ctx.step想定): ${waitfortimeout_count}件"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("waitForTimeout(pauseMs) 呼び出しが2箇所未満（検出: ${waitfortimeout_count}件）")
    echo "  NG - waitForTimeout(pauseMs) 呼び出しが2箇所未満（検出: ${waitfortimeout_count}件）"
  fi
fi

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
