#!/bin/bash
# test-license-sync.sh
# ルートの `LICENSE` と `plugin/LICENSE` の内容が一致することの検査（Issue #257）。
#
# 配布物（利用者のキャッシュへコピーされる範囲）は `plugin/` の中身だけで、ルートの `LICENSE` は
# 入らない。ライセンスを配布物へ同梱するため `plugin/LICENSE` に**実ファイルのコピー**を置いている
# （シンボリックリンクはキャッシュへのコピーで壊れうるため採らない）。コピーは片方だけ直すと
# 黙ってずれるので、ここでバイト一致を固定する。
#   (L-1) ルートの `LICENSE` が在る
#   (L-2) `plugin/LICENSE` が在り、シンボリックリンクではない通常ファイルである
#   (L-3) 2 つの内容がバイト単位で一致する
#
# 実行方法: bash scripts/tests/test-license-sync.sh

set -u

LICENSE_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${LICENSE_TEST_DIR}/../.." && pwd)"

ROOT_LICENSE="${PLUGIN_ROOT}/../LICENSE"
PLUGIN_LICENSE="${PLUGIN_ROOT}/LICENSE"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("$1")
  echo "  NG - $1"
  [ -n "${2:-}" ] && echo "       $2"
  return 0
}

echo "=== L-1: ルートの LICENSE が在る"
if [ -f "$ROOT_LICENSE" ]; then
  pass "ルートの LICENSE が在る"
else
  fail "ルートの LICENSE が在る" "not found: ${ROOT_LICENSE}"
fi

echo "=== L-2: plugin/LICENSE が通常ファイルとして在る"
if [ -f "$PLUGIN_LICENSE" ] && [ ! -L "$PLUGIN_LICENSE" ]; then
  pass "plugin/LICENSE が通常ファイルとして在る"
elif [ -L "$PLUGIN_LICENSE" ]; then
  fail "plugin/LICENSE が通常ファイルとして在る" "シンボリックリンクになっている（キャッシュへのコピーで壊れうる）: ${PLUGIN_LICENSE}"
else
  fail "plugin/LICENSE が通常ファイルとして在る" "not found: ${PLUGIN_LICENSE}"
fi

echo "=== L-3: 2 つの内容が一致する"
if [ -f "$ROOT_LICENSE" ] && [ -f "$PLUGIN_LICENSE" ] && cmp -s "$ROOT_LICENSE" "$PLUGIN_LICENSE"; then
  pass "LICENSE と plugin/LICENSE の内容が一致する"
else
  fail "LICENSE と plugin/LICENSE の内容が一致する" "直し方: ルートの LICENSE を正として cp LICENSE plugin/LICENSE"
fi

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
