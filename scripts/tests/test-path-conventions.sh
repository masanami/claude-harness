#!/bin/bash
# test-path-conventions.sh
# skills/ agents/ に対する grep ベースの再発防止テスト。
# (i) 裸の scripts/ 参照（${CLAUDE_PLUGIN_ROOT} も <base> も SCRIPT_DIR 自己解決も伴わない bash/node 実行）
# (ii) 実行時ファイルから docs/ 配下の設計文書への参照（HTML コメント行は除外。docs/features/ は
#      スキルの入出力ドキュメントであり設計文書ではないため対象外）
# (iii) 成立しない `echo "$CLAUDE_PLUGIN_ROOT"` 解決手順の再出現（実機検証によりBash環境では
#       常にUNSETであることが確認済み。Base directory起点の解決に一本化されている）
# を検出する。規約の正本は docs/plugin-path-conventions.md。
#
# 実行方法: bash scripts/tests/test-path-conventions.sh
# 失敗時は非0 exitし、違反箇所の一覧を出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

cd "$REPO_ROOT" || exit 1

# 既知の許容パターン（ホワイトリスト）。「file:line」を1行ずつ記載する。
# 該当箇所を修正した場合はここからも対応する行を削除すること。

# (i) 裸の scripts/ 参照の許容リスト。現時点では既知の例外は無い。
BARE_SCRIPT_ALLOWLIST="
"

# (ii) docs/ 設計文書参照の許容リスト。
# init-project/SKILL.md:137 は「生成先ドキュメントの標準パス例」であり、本規約が対象とする
# 自己参照（このプラグイン自身の設計文書を実行時に読みに行く）には当たらない。
# （本行番号は本Issue #80 のパス規約修正でファイル冒頭側に4行追加されたことに伴うシフト後の値）
DOCS_REF_ALLOWLIST="
skills/init-project/SKILL.md:137
"

# (iii) echo "$CLAUDE_PLUGIN_ROOT" 解決手順の許容リスト。現時点では既知の例外は無い。
DEAD_ECHO_ALLOWLIST="
"

is_allowlisted() {
  local file_line="$1"
  local allowlist="$2"
  echo "$allowlist" | grep -Fxq "$file_line"
}

print_indented() {
  local text="$1"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "       ${line}"
  done <<<"$text"
}

echo "=== (i) 裸の scripts/ 参照チェック ==="

# shellcheck disable=SC2016 # バッククォートは正規表現リテラルであり、シェル展開の対象ではない
bare_script_hits="$(grep -rnE '(bash|node)[[:space:]]+"?scripts/|`scripts/[A-Za-z0-9_.-]+\.(sh|js|mjs)[^`]*`[[:space:]]*(を実行|実行する)' skills agents --include='*.md' || true)"

bare_script_violations=""
if [ -n "$bare_script_hits" ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    if ! is_allowlisted "${file}:${lineno}" "$BARE_SCRIPT_ALLOWLIST"; then
      bare_script_violations="${bare_script_violations}${hit}
"
    fi
  done <<<"$bare_script_hits"
fi

if [ -z "$bare_script_violations" ]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 裸の scripts/ 参照は無い"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("裸の scripts/ 参照を検出")
  echo "  NG - 裸の scripts/ 参照を検出"
  print_indented "$bare_script_violations"
fi

echo ""
echo "=== (ii) docs/ 設計文書への参照チェック ==="

docs_ref_hits="$(grep -rnE 'docs/[A-Za-z0-9_./-]*\.md' skills agents --include='*.md' \
  | grep -v 'docs/features/' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*<!--.*-->[[:space:]]*$' || true)"

docs_ref_violations=""
if [ -n "$docs_ref_hits" ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    if ! is_allowlisted "${file}:${lineno}" "$DOCS_REF_ALLOWLIST"; then
      docs_ref_violations="${docs_ref_violations}${hit}
"
    fi
  done <<<"$docs_ref_hits"
fi

if [ -z "$docs_ref_violations" ]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - docs/ 設計文書への参照は無い（HTML コメントを除く）"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("docs/ 設計文書への参照を検出")
  echo "  NG - docs/ 設計文書への参照を検出"
  print_indented "$docs_ref_violations"
fi

echo ""
echo "=== (iii) echo \"\$CLAUDE_PLUGIN_ROOT\" 解決手順チェック ==="

dead_echo_hits="$(grep -rnE 'echo[[:space:]]+"?\$\{?CLAUDE_PLUGIN_ROOT\}?"?' skills agents --include='*.md' || true)"

dead_echo_violations=""
if [ -n "$dead_echo_hits" ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    if ! is_allowlisted "${file}:${lineno}" "$DEAD_ECHO_ALLOWLIST"; then
      dead_echo_violations="${dead_echo_violations}${hit}
"
    fi
  done <<<"$dead_echo_hits"
fi

if [ -z "$dead_echo_violations" ]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 成立しない echo \"\$CLAUDE_PLUGIN_ROOT\" 解決手順は無い"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("echo \"\$CLAUDE_PLUGIN_ROOT\" 解決手順の再出現を検出")
  echo "  NG - echo \"\$CLAUDE_PLUGIN_ROOT\" 解決手順の再出現を検出"
  print_indented "$dead_echo_violations"
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
