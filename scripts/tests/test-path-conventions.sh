#!/bin/bash
# test-path-conventions.sh
# skills/ agents/ に対する grep ベースの再発防止テスト。
# (i) 裸の scripts/ 参照（${CLAUDE_PLUGIN_ROOT} も <base> も SCRIPT_DIR 自己解決も伴わない
#     bash/node 実行・Workflow scriptPath・scripts/ 配下ドキュメントへの Read 参照）
# (ii) 実行時ファイルから docs/ 配下の設計文書への参照（HTML コメント行は除外。docs/features/ は
#      スキルの入出力ドキュメントであり設計文書ではないため対象外。1行に複数の docs/*.md 参照が
#      併記されている場合は参照ごとに判定し、docs/features/ 以外が1つでもあれば違反とする）
# (iii) 成立しない `echo "$CLAUDE_PLUGIN_ROOT"` 解決手順の再出現（実機検証によりBash環境では
#       常にUNSETであることが確認済み。Base directory起点の解決に一本化されている）
# (iv) skills/*/scripts/*.js（Workflow ランタイムが scriptPath で直接実行するスクリプト）が
#      `export const meta` 以外の export を持たないこと。ランタイムは `export const meta` のみを
#      特別扱いし、本文を async 関数体として実行する契約のため、他の export が1つでも残っていると
#      起動時に `SyntaxError: Unexpected keyword 'export'` で失敗する（Issue #89の実機確認事実）。
# を検出する。規約の正本は docs/plugin-path-conventions.md。
#
# grep の exit code は 0=マッチあり / 1=マッチなし（正常） / 2以上=実行エラー
# （パターン不正・対象不在等）。2以上の場合は「違反なし」として黙って通過させず、テストを失敗させる
# （`|| true` で一括握りつぶすと実行エラーも「違反なし」に見えてしまうため使わない）。
# 各 grep 呼び出しの直後で `$?` を変数へ代入して判定すること（コマンド置換のサブシェル内で
# グローバル変数を更新しても呼び出し元には伝播しないため、ヘルパー関数化はしない）。
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
bare_exec_pattern='(bash|node)[[:space:]]+(-[A-Za-z0-9=_-]+[[:space:]]+)*"?scripts/|scriptPath:[[:space:]]*"?scripts/|`scripts/[A-Za-z0-9_.-]+\.(sh|js|mjs)[^`]*`[[:space:]]*(を実行|実行する)'
bare_exec_hits="$(grep -rnE "$bare_exec_pattern" skills agents --include='*.md')"
bare_exec_exit=$?

# scripts/ 配下のドキュメント（例: scripts/README.md）への裸の Read 参照。
# ${CLAUDE_PLUGIN_ROOT} や <base> による解決手順が同一行内に併記されていれば
# （例: 「正本は `scripts/README.md`（Read する場合は `<base>/../../scripts/README.md` で解決）」）
# 単なる名称としての言及であり違反ではないため除外する。
# shellcheck disable=SC2016
bare_doc_pattern='`scripts/[A-Za-z0-9_.-]+\.md`'
bare_doc_candidates="$(grep -rnE "$bare_doc_pattern" skills agents --include='*.md')"
bare_doc_exit=$?

if [ "$bare_exec_exit" -ge 2 ] || [ "$bare_doc_exit" -ge 2 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("裸の scripts/ 参照チェックの grep 実行に失敗")
  echo "  NG - grep 実行エラー（exit ${bare_exec_exit}/${bare_doc_exit}）のため判定不能"
else
  bare_doc_hits=""
  if [ -n "$bare_doc_candidates" ]; then
    bare_doc_hits="$(printf '%s\n' "$bare_doc_candidates" | grep -v 'CLAUDE_PLUGIN_ROOT\|<base>')"
  fi

  bare_script_hits="${bare_exec_hits}
${bare_doc_hits}"

  bare_script_violations=""
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

  if [ -z "$bare_script_violations" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - 裸の scripts/ 参照は無い"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("裸の scripts/ 参照を検出")
    echo "  NG - 裸の scripts/ 参照を検出"
    print_indented "$bare_script_violations"
  fi
fi

echo ""
echo "=== (ii) docs/ 設計文書への参照チェック ==="

docs_candidate_pattern='docs/[A-Za-z0-9_./-]*\.md'
docs_candidate_hits="$(grep -rnE "$docs_candidate_pattern" skills agents --include='*.md')"
docs_candidate_exit=$?

if [ "$docs_candidate_exit" -ge 2 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("docs/ 設計文書チェックの grep 実行に失敗")
  echo "  NG - grep 実行エラー（exit ${docs_candidate_exit}）のため判定不能"
else
  docs_ref_violations=""
  if [ -n "$docs_candidate_hits" ]; then
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      file="${hit%%:*}"
      rest="${hit#*:}"
      lineno="${rest%%:*}"
      content="${rest#*:}"

      # 行全体が開発者向け出典コメント（HTMLコメント）のみの場合は対象外
      if echo "$content" | grep -qE '^[[:space:]]*<!--.*-->[[:space:]]*$'; then
        continue
      fi

      # 同一行に docs/features/... と docs/adr/... 等が併記されるケースを見逃さないよう、
      # 行単位ではなく行内の docs/*.md 参照ごとに判定する。docs/features/ 以外で、かつ
      # **プラグインリポジトリに実在する設計文書**への参照が1つでもあれば違反とする。
      # （導入先プロジェクトの成果物パスの例示——例: docs/coding-guidelines.md——は
      #  プラグインの docs/ に実在しないため違反にしない）
      plugin_doc_match=""
      while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        case "$ref" in docs/features/*) continue ;; esac
        if [ -f "$ref" ]; then
          plugin_doc_match="$ref"
          break
        fi
      done <<<"$(echo "$content" | grep -oE 'docs/[A-Za-z0-9_./-]*\.md')"
      if [ -z "$plugin_doc_match" ]; then
        continue
      fi

      if ! is_allowlisted "${file}:${lineno}" "$DOCS_REF_ALLOWLIST"; then
        docs_ref_violations="${docs_ref_violations}${hit}
"
      fi
    done <<<"$docs_candidate_hits"
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
fi

echo ""
echo "=== (iii) echo \"\$CLAUDE_PLUGIN_ROOT\" 解決手順チェック ==="

dead_echo_pattern='echo[[:space:]]+"?\$\{?CLAUDE_PLUGIN_ROOT\}?"?'
dead_echo_hits="$(grep -rnE "$dead_echo_pattern" skills agents --include='*.md')"
dead_echo_exit=$?

if [ "$dead_echo_exit" -ge 2 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("echo \"\$CLAUDE_PLUGIN_ROOT\" チェックの grep 実行に失敗")
  echo "  NG - grep 実行エラー（exit ${dead_echo_exit}）のため判定不能"
else
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
fi

echo ""
echo "=== (iv) Workflow スクリプトの export 制約チェック ==="

workflow_script_export_violations=""
while IFS= read -r -d '' file; do
  export_count="$(grep -c '^export ' "$file")"
  if [ "$export_count" -ne 1 ]; then
    workflow_script_export_violations="${workflow_script_export_violations}${file}: export行数=${export_count}（期待値=1。export const meta のみ許容）
"
  fi
done < <(find skills -path '*/scripts/*.js' -print0)

if [ -z "$workflow_script_export_violations" ]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - skills/*/scripts/*.js は全て export const meta のみを export している"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("skills/*/scripts/*.js に export const meta 以外の export を検出")
  echo "  NG - skills/*/scripts/*.js に export const meta 以外の export を検出"
  print_indented "$workflow_script_export_violations"
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
