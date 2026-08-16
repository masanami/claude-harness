#!/bin/bash
# test-list-test-files.sh
# scripts/list-test-files.sh のテストファイル判定・E2E/結合/単体の分類・CLI 契約
# （stdout JSON / exit code / 列挙の決定性 / オプションによる上書き）をテストする。gh 非依存。
#
# 実行方法: bash scripts/tests/test-list-test-files.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2034 # LTF_*_GLOBS への代入は source した list-test-files.sh 側の
# 関数が読む入力であり、本ファイル内では読み出さない（shellcheck からは未使用に見える）
set -u

LTF_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${LTF_TEST_DIR}/../list-test-files.sh"

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

# テストファイル判定を "yes"/"no" で返す。
is_test() {
  if ltf_is_test_file "$1"; then
    printf '%s' "yes"
  else
    printf '%s' "no"
  fi
}

# 除外判定を "yes"/"no" で返す。
is_excluded() {
  if ltf_is_excluded "$1"; then
    printf '%s' "yes"
  else
    printf '%s' "no"
  fi
}

# 分類結果を返す（LTF_CATEGORY はサブシェルを跨がないため、呼び出し後に参照する）。
classify() {
  ltf_classify "$1"
  printf '%s' "$LTF_CATEGORY"
}

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

echo "=== test: テストファイル判定（ファイル名規則） ==="
assert_eq "foo.test.ts" "yes" "$(is_test "src/foo.test.ts")"
assert_eq "foo.spec.ts" "yes" "$(is_test "src/foo.spec.ts")"
assert_eq "foo_test.go" "yes" "$(is_test "pkg/foo_test.go")"
assert_eq "user_spec.rb" "yes" "$(is_test "spec/models/user_spec.rb")"
assert_eq "test_foo.py" "yes" "$(is_test "app/test_foo.py")"
assert_eq "FooTest.java" "yes" "$(is_test "src/main/java/FooTest.java")"
assert_eq "FooTests.cs" "yes" "$(is_test "src/FooTests.cs")"
assert_eq "checkout.feature（Gherkin）" "yes" "$(is_test "features/checkout.feature")"
assert_eq "通常の実装ファイルはテストではない" "no" "$(is_test "src/index.ts")"
assert_eq "テストという語を含むだけの実装ファイルはテストではない" "no" "$(is_test "src/testing-utils.ts")"

echo "=== test: テストファイル判定（ディレクトリ規則） ==="
assert_eq "tests/ 配下のコードファイル" "yes" "$(is_test "tests/api/contact.ts")"
assert_eq "__tests__/ 配下のコードファイル" "yes" "$(is_test "src/__tests__/button.tsx")"
assert_eq "e2e/ 配下のコードファイル" "yes" "$(is_test "e2e/auth.ts")"
assert_eq "tests/ 配下でもコード拡張子でなければ対象外" "no" "$(is_test "tests/data/sample.json")"
assert_eq "ルート直下の単独ファイルは対象外" "no" "$(is_test "README.md")"

echo "=== test: 除外判定 ==="
assert_eq "node_modules 配下" "yes" "$(is_excluded "node_modules/pkg/index.test.js")"
assert_eq "vendor 配下" "yes" "$(is_excluded "vendor/lib/foo_test.go")"
assert_eq "__snapshots__ 配下" "yes" "$(is_excluded "src/__snapshots__/foo.test.ts.snap")"
assert_eq "fixtures 配下" "yes" "$(is_excluded "tests/fixtures/user.test.ts")"
assert_eq "testdata 配下（Go のフィクスチャ規約）" "yes" "$(is_excluded "pkg/testdata/foo_test.go")"
assert_eq "型定義ファイル" "yes" "$(is_excluded "types/foo.d.ts")"
assert_eq "playwright.config.ts（設定ファイル）" "yes" "$(is_excluded "playwright.config.ts")"
assert_eq "通常のテストは除外しない" "no" "$(is_excluded "tests/api/contact.test.ts")"

echo "=== test: 分類（E2E / 結合 / 単体） ==="
assert_eq "e2e/ 配下は E2E" "e2e" "$(classify "e2e/auth.spec.ts")"
assert_eq "cypress/ 配下は E2E" "e2e" "$(classify "cypress/e2e/login.cy.js")"
assert_eq "playwright/ 配下は E2E" "e2e" "$(classify "playwright/checkout.spec.ts")"
assert_eq "ファイル名に e2e を含む場合も E2E" "e2e" "$(classify "tests/login.e2e.test.ts")"
assert_eq ".feature は E2E" "e2e" "$(classify "features/checkout.feature")"
assert_eq "integration/ 配下は結合" "integration" "$(classify "tests/integration/api.test.ts")"
assert_eq "ファイル名に integration を含む場合も結合" "integration" "$(classify "tests/api.integration.test.ts")"
assert_eq "それ以外は単体" "unit" "$(classify "src/foo.test.ts")"
assert_eq "tests/ 直下の素のテストは単体" "unit" "$(classify "tests/util.test.ts")"

echo "=== test: 分類の判定規則が記録される ==="
ltf_classify "e2e/auth.spec.ts"
assert_eq "E2E の判定規則" "dir:e2e" "$LTF_CATEGORY_RULE"
ltf_classify "src/foo.test.ts"
assert_eq "既定（単体）の判定規則" "default:unit" "$LTF_CATEGORY_RULE"

echo "=== test: オプションによる上書き（関数レベル） ==="
LTF_E2E_GLOBS=("tests/browser/*")
assert_eq "--e2e 指定が既定規則より優先される" "e2e" "$(classify "tests/browser/login.test.ts")"
ltf_classify "tests/browser/login.test.ts"
assert_eq "上書きの判定規則が記録される" "option:e2e(tests/browser/*)" "$LTF_CATEGORY_RULE"
LTF_E2E_GLOBS=()

LTF_INTEGRATION_GLOBS=("tests/api/*")
assert_eq "--integration 指定が既定規則より優先される" "integration" "$(classify "tests/api/contact.test.ts")"
LTF_INTEGRATION_GLOBS=()

LTF_INCLUDE_GLOBS=("scenarios/*.ts")
assert_eq "--include 指定でテストファイルに追加できる" "yes" "$(is_test "scenarios/happy-path.ts")"
LTF_INCLUDE_GLOBS=()

LTF_EXCLUDE_GLOBS=("legacy/*")
assert_eq "--exclude 指定で除外できる" "yes" "$(is_excluded "legacy/old.test.ts")"
LTF_EXCLUDE_GLOBS=()

# フィクスチャリポジトリを作る
FIXTURE_REPO="${TMP_ROOT}/fixture-repo"
mkdir -p "${FIXTURE_REPO}/e2e" "${FIXTURE_REPO}/tests/integration" "${FIXTURE_REPO}/src" \
  "${FIXTURE_REPO}/node_modules/pkg" "${FIXTURE_REPO}/tests/browser"
printf 'test("login", () => {});\n' > "${FIXTURE_REPO}/e2e/auth.spec.ts"
printf 'it("contact", () => {});\n' > "${FIXTURE_REPO}/tests/integration/contact.test.ts"
printf 'it("util", () => {});\n' > "${FIXTURE_REPO}/src/util.test.ts"
printf 'export const x = 1;\n' > "${FIXTURE_REPO}/src/index.ts"
printf 'it("vendored", () => {});\n' > "${FIXTURE_REPO}/node_modules/pkg/dep.test.js"
printf 'it("browser", () => {});\n' > "${FIXTURE_REPO}/tests/browser/checkout.test.ts"
(
  cd "$FIXTURE_REPO" || exit 1
  git init -q
)

echo "=== test: CLI（列挙・分類・除外） ==="
CLI_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" 2>/dev/null)"
CLI_EXIT=$?
assert_eq "exit code が 0" "0" "$CLI_EXIT"
assert_eq "status が ok" "ok" "$(jq -r '.status' <<<"$CLI_OUT")"
assert_eq "source が git" "git" "$(jq -r '.source' <<<"$CLI_OUT")"
assert_eq "合計4件（node_modules と実装ファイルを除く）" "4" "$(jq -r '.counts.total' <<<"$CLI_OUT")"
assert_eq "E2E は1件" "1" "$(jq -r '.counts.e2e' <<<"$CLI_OUT")"
assert_eq "結合は1件" "1" "$(jq -r '.counts.integration' <<<"$CLI_OUT")"
assert_eq "単体は2件" "2" "$(jq -r '.counts.unit' <<<"$CLI_OUT")"
assert_eq "node_modules 配下は列挙しない" "0" "$(jq -r '[.files[] | select(.path | startswith("node_modules"))] | length' <<<"$CLI_OUT")"
assert_eq "実装ファイルは列挙しない" "0" "$(jq -r '[.files[] | select(.path == "src/index.ts")] | length' <<<"$CLI_OUT")"

echo "=== test: CLI（列挙順が決定的） ==="
assert_eq "パス昇順で返る" "e2e/auth.spec.ts src/util.test.ts tests/browser/checkout.test.ts tests/integration/contact.test.ts" \
  "$(jq -r '[.files[].path] | join(" ")' <<<"$CLI_OUT")"
CLI_OUT_AGAIN="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" 2>/dev/null)"
assert_eq "同じ入力なら同じ出力（決定性）" "$CLI_OUT" "$CLI_OUT_AGAIN"

echo "=== test: CLI（未追跡のテストファイルも列挙する） ==="
printf 'it("brand new", () => {});\n' > "${FIXTURE_REPO}/tests/new-feature.test.ts"
UNTRACKED_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" 2>/dev/null)"
assert_eq "コミット前のテストも拾う" "1" "$(jq -r '[.files[] | select(.path == "tests/new-feature.test.ts")] | length' <<<"$UNTRACKED_OUT")"
rm -f "${FIXTURE_REPO}/tests/new-feature.test.ts"

echo "=== test: CLI（オプションによる上書き） ==="
OVERRIDE_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" --e2e "tests/browser/*" 2>/dev/null)"
assert_eq "--e2e 指定で E2E が2件になる" "2" "$(jq -r '.counts.e2e' <<<"$OVERRIDE_OUT")"
EXCLUDE_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" --exclude "src/*" 2>/dev/null)"
assert_eq "--exclude 指定で件数が減る" "3" "$(jq -r '.counts.total' <<<"$EXCLUDE_OUT")"
INCLUDE_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" --include "src/index.ts" 2>/dev/null)"
assert_eq "--include 指定で対象を追加できる" "5" "$(jq -r '.counts.total' <<<"$INCLUDE_OUT")"

echo "=== test: CLI（--root で起点を指定できる） ==="
ROOT_OUT="$(bash "$TARGET_SCRIPT" --root "$FIXTURE_REPO" 2>/dev/null)"
ROOT_EXIT=$?
assert_eq "exit code が 0" "0" "$ROOT_EXIT"
assert_eq "合計4件" "4" "$(jq -r '.counts.total' <<<"$ROOT_OUT")"

echo "=== test: CLI（非 git ディレクトリでは find へフォールバックする） ==="
PLAIN_DIR="${TMP_ROOT}/plain-dir"
mkdir -p "${PLAIN_DIR}/tests" "${PLAIN_DIR}/node_modules/pkg"
printf 'it("plain", () => {});\n' > "${PLAIN_DIR}/tests/plain.test.ts"
printf 'it("vendored", () => {});\n' > "${PLAIN_DIR}/node_modules/pkg/dep.test.js"
PLAIN_OUT="$(cd "$PLAIN_DIR" && bash "$TARGET_SCRIPT" 2>/dev/null)"
PLAIN_EXIT=$?
assert_eq "exit code が 0" "0" "$PLAIN_EXIT"
assert_eq "source が find" "find" "$(jq -r '.source' <<<"$PLAIN_OUT")"
assert_eq "テストを1件列挙する" "1" "$(jq -r '.counts.total' <<<"$PLAIN_OUT")"
assert_eq "node_modules は除外される" "0" "$(jq -r '[.files[] | select(.path | startswith("node_modules"))] | length' <<<"$PLAIN_OUT")"

echo "=== test: CLI（テストが1件も無い場合は明示ステータスを返す） ==="
EMPTY_DIR="${TMP_ROOT}/empty-project"
mkdir -p "${EMPTY_DIR}/src"
printf 'export const x = 1;\n' > "${EMPTY_DIR}/src/index.ts"
EMPTY_OUT="$(cd "$EMPTY_DIR" && bash "$TARGET_SCRIPT" 2>/dev/null)"
EMPTY_EXIT=$?
assert_eq "exit code は 0（異常ではない）" "0" "$EMPTY_EXIT"
assert_eq "status が no_test_files_found" "no_test_files_found" "$(jq -r '.status' <<<"$EMPTY_OUT")"
assert_eq "files は空配列" "0" "$(jq -r '.files | length' <<<"$EMPTY_OUT")"

echo "=== test: CLI（実行前提の欠落は exit 2 で stdout は空） ==="
UNKNOWN_OPT_OUT="$(bash "$TARGET_SCRIPT" --bogus 2>/dev/null)"
UNKNOWN_OPT_EXIT=$?
assert_eq "未知オプションは exit 2" "2" "$UNKNOWN_OPT_EXIT"
assert_eq "未知オプション時の stdout は空" "" "$UNKNOWN_OPT_OUT"

bash "$TARGET_SCRIPT" somearg >/dev/null 2>&1
POSITIONAL_EXIT=$?
assert_eq "位置引数は受け付けない（exit 2）" "2" "$POSITIONAL_EXIT"

MISSING_VALUE_OUT="$(bash "$TARGET_SCRIPT" --root 2>/dev/null)"
MISSING_VALUE_EXIT=$?
assert_eq "値の無いオプションは exit 2" "2" "$MISSING_VALUE_EXIT"
assert_eq "その場合の stdout は空" "" "$MISSING_VALUE_OUT"

MISSING_ROOT_OUT="$(bash "$TARGET_SCRIPT" --root "${TMP_ROOT}/nonexistent" 2>/dev/null)"
MISSING_ROOT_EXIT=$?
assert_eq "存在しない --root は exit 2" "2" "$MISSING_ROOT_EXIT"
assert_eq "その場合の stdout は空" "" "$MISSING_ROOT_OUT"

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
