#!/bin/bash
# test-mutation-run.sh
# scripts/mutation-run.sh の純粋関数（porcelain_path/classify_failure_kind/
# check_dirty_scope）と、CLIレベル（main()経由）の統合動作を、一時gitリポジトリを
# 作成して検証する。
#
# 実行方法: bash scripts/tests/test-mutation-run.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../mutation-run.sh"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

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

# --- porcelain_path ---
echo "=== test: porcelain_path — ステータス2文字+空白を取り除きpathのみ返す ==="
assert_eq "' M path/to/file.js' -> 'path/to/file.js'" "path/to/file.js" "$(porcelain_path " M path/to/file.js")"
assert_eq "'?? new-file.txt' -> 'new-file.txt'" "new-file.txt" "$(porcelain_path "?? new-file.txt")"

# --- classify_failure_kind ---
echo "=== test: classify_failure_kind — アサーション起因の文字列を検出する ==="
assert_eq "AssertionErrorを含む出力はassertion" "assertion" "$(classify_failure_kind "Error: AssertionError: expected true to be false")"
assert_eq "expect(...)を含む出力はassertion" "assertion" "$(classify_failure_kind "  expect(received).toBe(expected)")"
assert_eq "Expected/Receivedパターンはassertion" "assertion" "$(classify_failure_kind "Expected: 200 Received: 500")"
assert_eq "無関係なクラッシュはother" "other" "$(classify_failure_kind "TypeError: Cannot read properties of undefined (reading 'foo')")"
assert_eq "空文字出力はother" "other" "$(classify_failure_kind "")"

# --- check_dirty_scope ---
echo "=== test: check_dirty_scope — 対象ファイル範囲外の変更を検出する ==="
{
  check_dirty_scope "$(printf ' M src/a.js\n M src/b.js\n')" "src/a.js" "src/b.js"
  assert_eq "範囲内のみなら OUT_OF_SCOPE_LINES は空" "" "$OUT_OF_SCOPE_LINES"
  assert_eq "対象ファイルに変更があれば ANY_TARGET_DIRTY は true" "true" "$ANY_TARGET_DIRTY"
}
{
  check_dirty_scope "$(printf ' M src/a.js\n M src/unexpected.js\n')" "src/a.js"
  assert_eq "範囲外の変更がある場合はOUT_OF_SCOPE_LINESに含まれる" "0" "$([[ "$OUT_OF_SCOPE_LINES" == *"src/unexpected.js"* ]] && echo 0 || echo 1)"
}
{
  check_dirty_scope "" "src/a.js"
  assert_eq "porcelain出力が空なら対象ファイルの変更も無し(ANY_TARGET_DIRTY=false)" "false" "$ANY_TARGET_DIRTY"
  assert_eq "porcelain出力が空ならOUT_OF_SCOPE_LINESも空" "" "$OUT_OF_SCOPE_LINES"
}

# --- normalize_to_repo_relative ---
# 変異エージェント（agents/e2e-mutation-injector.md）の契約は「実際に編集したファイルの絶対パス」を
# 返すことになっているが、`git status --porcelain`（引数無し・リポジトリ全体）が返すパスは常に
# リポジトリルート相対である。この不一致を吸収せずに絶対パスと相対パスを直接比較すると、
# check_dirty_scope が「範囲外の変更」と誤検出し、実運用の全ミューテーションが復元前に
# exit 1 で打ち切られる（回帰テスト: コードレビューで実機再現・確認済みのバグ）。
echo "=== test: normalize_to_repo_relative — 絶対パスをリポジトリルート相対へ正規化する ==="
assert_eq "リポジトリ配下の絶対パスはルート相対に変換される" "sub/impl.js" "$(normalize_to_repo_relative "/repo" "/repo/sub/impl.js")"
assert_eq "リポジトリ直下のファイルも変換される" "impl.js" "$(normalize_to_repo_relative "/repo" "/repo/impl.js")"
assert_eq "既に相対パスならそのまま返す" "impl.js" "$(normalize_to_repo_relative "/repo" "impl.js")"
assert_eq "リポジトリルート外の絶対パスはそのまま返す(比較で不一致のままとなり異常系として検出される想定)" "/other/impl.js" "$(normalize_to_repo_relative "/repo" "/other/impl.js")"
assert_eq "repo_rootが空文字列(取得失敗)の場合は絶対パスをそのまま返す" "/repo/impl.js" "$(normalize_to_repo_relative "" "/repo/impl.js")"

# --- 一時gitリポジトリでの統合テスト（main() 経由） ---
REPO_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$REPO_DIR"
}
trap cleanup EXIT

(
  cd "$REPO_DIR" || exit 1
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test User"
  cat >impl.js <<'EOF'
function isEven(n) {
  return n % 2 === 0;
}
module.exports = { isEven };
EOF
  cat >impl.test.js <<'EOF'
const assert = require('assert');
const { isEven } = require('./impl');
assert.strictEqual(isEven(4), true, 'AssertionError: expected isEven(4) to be true');
console.log('ok');
EOF
  git add impl.js impl.test.js
  git commit -q -m "initial commit"
)

cd "$REPO_DIR" || exit 1

TEST_CMD="node impl.test.js"

echo "=== test: CLI — 引数不足はexit 1（stdoutにJSONを出さない） ==="
OUT_MISSING_ARGS=$("$TARGET_SCRIPT" 2>/dev/null)
EXIT_MISSING_ARGS=$?
assert_eq "exit code 1" "1" "$EXIT_MISSING_ARGS"
assert_eq "stdoutは空" "" "$OUT_MISSING_ARGS"

echo "=== test: CLI — 非gitリポジトリではexit 1 ==="
NON_REPO_DIR="$(mktemp -d)"
(
  cd "$NON_REPO_DIR" || exit 1
  "$TARGET_SCRIPT" "$TEST_CMD" impl.js >/dev/null 2>&1
)
EXIT_NON_REPO=$?
assert_eq "exit code 1" "1" "$EXIT_NON_REPO"
rm -rf "$NON_REPO_DIR"

echo "=== test: CLI — 未コミット変更が対象ファイル範囲外にある場合はexit 1（テスト実行前に打ち切る） ==="
echo "// unrelated stray edit" >>impl.test.js
OUT_SCOPE=$("$TARGET_SCRIPT" "$TEST_CMD" impl.js 2>/dev/null)
EXIT_SCOPE=$?
assert_eq "exit code 1" "1" "$EXIT_SCOPE"
assert_eq "stdoutは空(異常系ではJSONを出さない)" "" "$OUT_SCOPE"
git checkout -- impl.test.js

echo "=== test: CLI — 対象ファイルが実際には変更されていない場合はexit 1 ==="
OUT_NO_MUTATION=$("$TARGET_SCRIPT" "$TEST_CMD" impl.js 2>/dev/null)
EXIT_NO_MUTATION=$?
assert_eq "exit code 1" "1" "$EXIT_NO_MUTATION"
assert_eq "stdoutは空" "" "$OUT_NO_MUTATION"

echo "=== test: CLI — ミューテーション注入→失敗検出→復元→再パス確認までの正常系（回帰テスト本体） ==="
# impl.js に不具合を注入する（isEvenの判定を反転させる）。バックアップはリポジトリ外の
# シェル変数に保持する（リポジトリ内に未追跡のバックアップファイルを残すと、次の
# クリーン確認ステップが「対象ファイル範囲外の変更」として誤検出してしまうため）。
IMPL_ORIG="$(cat impl.js)"
sed -i.tmp 's/n % 2 === 0/n % 2 !== 0/' impl.js
rm -f impl.js.tmp

CLI_OUTPUT=$("$TARGET_SCRIPT" "$TEST_CMD" impl.js 2>/dev/null)
CLI_EXIT=$?
assert_eq "exit code 0（復元・再パスとも成功）" "0" "$CLI_EXIT"
assert_eq "testFailed: true（注入により失敗した）" "true" "$(jq -r '.testFailed' <<<"$CLI_OUTPUT")"
assert_eq "failureKind: assertion（assert.strictEqualのAssertionErrorを検出）" "assertion" "$(jq -r '.failureKind' <<<"$CLI_OUTPUT")"
assert_eq "restored: true" "true" "$(jq -r '.restored' <<<"$CLI_OUTPUT")"
assert_eq "rePassed: true" "true" "$(jq -r '.rePassed' <<<"$CLI_OUTPUT")"

IMPL_AFTER="$(cat impl.js)"
assert_eq "impl.jsの中身が注入前の内容に完全復元されている" "$IMPL_ORIG" "$IMPL_AFTER"
POST_STATUS="$(git status --porcelain -- impl.js)"
assert_eq "git status --porcelain -- impl.js が空（真にクリーン）" "" "$POST_STATUS"

echo "=== test: CLI — mutated_file を絶対パスで渡しても(実運用の契約どおり)正常に検出・復元される（回帰テスト） ==="
# agents/e2e-mutation-injector.md の契約は絶対パスを返すことになっている。
# 絶対パス vs git status --porcelain のルート相対パスの不一致で誤って「範囲外の変更」と
# 判定されないことを確認する（normalize_to_repo_relative の統合テスト）。
IMPL_ORIG_ABS="$(cat impl.js)"
sed -i.tmp 's/n % 2 === 0/n % 2 !== 0/' impl.js
rm -f impl.js.tmp
ABS_IMPL_PATH="${REPO_DIR}/impl.js"

CLI_OUTPUT_ABS=$("$TARGET_SCRIPT" "$TEST_CMD" "$ABS_IMPL_PATH" 2>/dev/null)
CLI_EXIT_ABS=$?
assert_eq "絶対パス指定でも exit code 0（復元・再パスとも成功）" "0" "$CLI_EXIT_ABS"
assert_eq "絶対パス指定でも testFailed: true が検出される" "true" "$(jq -r '.testFailed' <<<"$CLI_OUTPUT_ABS")"
assert_eq "絶対パス指定でも restored: true" "true" "$(jq -r '.restored' <<<"$CLI_OUTPUT_ABS")"
assert_eq "絶対パス指定でも rePassed: true" "true" "$(jq -r '.rePassed' <<<"$CLI_OUTPUT_ABS")"
IMPL_AFTER_ABS="$(cat impl.js)"
assert_eq "絶対パス指定でもimpl.jsが完全復元されている" "$IMPL_ORIG_ABS" "$IMPL_AFTER_ABS"

echo "=== test: CLI — テストが元々パスする変異（歯抜け検出）でも復元・再パスは正常終了する ==="
# isEven に無関係な変異（コメント追加のみ）を注入する。既存アサーションには影響しないため
# testFailed: false になるはず（歯の無いテストを検出するケースの模擬）。
echo "// no-op comment injected for mutation testing" >>impl.js
CLI_OUTPUT_TOOTHLESS=$("$TARGET_SCRIPT" "$TEST_CMD" impl.js 2>/dev/null)
CLI_EXIT_TOOTHLESS=$?
assert_eq "exit code 0" "0" "$CLI_EXIT_TOOTHLESS"
assert_eq "testFailed: false（無関係な変異はテストに検出されない）" "false" "$(jq -r '.testFailed' <<<"$CLI_OUTPUT_TOOTHLESS")"
assert_eq "failureKind: none" "none" "$(jq -r '.failureKind' <<<"$CLI_OUTPUT_TOOTHLESS")"
assert_eq "restored: true" "true" "$(jq -r '.restored' <<<"$CLI_OUTPUT_TOOTHLESS")"
assert_eq "rePassed: true" "true" "$(jq -r '.rePassed' <<<"$CLI_OUTPUT_TOOTHLESS")"

echo "=== test: CLI — 複数ファイル指定時、範囲チェック・復元とも複数ファイルにまたがって機能する ==="
cat >impl2.js <<'EOF'
function double(n) {
  return n * 2;
}
module.exports = { double };
EOF
git add impl2.js
git commit -q -m "add impl2"
echo "// stray injected comment in impl2" >>impl2.js
echo "// another stray injected comment in impl.js" >>impl.js

OUT_MULTI=$("$TARGET_SCRIPT" "$TEST_CMD" impl.js impl2.js 2>/dev/null)
EXIT_MULTI=$?
assert_eq "exit code 0" "0" "$EXIT_MULTI"
assert_eq "restored: true" "true" "$(jq -r '.restored' <<<"$OUT_MULTI")"
POST_STATUS_MULTI="$(git status --porcelain -- impl.js impl2.js)"
assert_eq "複数ファイルとも完全復元されクリーン" "" "$POST_STATUS_MULTI"

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
