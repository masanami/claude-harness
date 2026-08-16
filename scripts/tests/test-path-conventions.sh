#!/bin/bash
# test-path-conventions.sh
# skills/ agents/ に対する grep ベースの再発防止テスト。
# (i) 裸の scripts/ 参照（${CLAUDE_PLUGIN_ROOT} も <base> も SCRIPT_DIR 自己解決も伴わない
#     bash/node 実行・scriptPath: 形式の参照・scripts/ 配下ドキュメントへの Read 参照）
# (ii) 実行時ファイルから docs/ 配下の設計文書への参照（HTML コメント行は除外。docs/features/ は
#      スキルの入出力ドキュメントであり設計文書ではないため対象外。1行に複数の docs/*.md 参照が
#      併記されている場合は参照ごとに判定し、docs/features/ 以外が1つでもあれば違反とする）
# (iii) 成立しない `echo "$CLAUDE_PLUGIN_ROOT"` 解決手順の再出現（実機検証によりBash環境では
#       常にUNSETであることが確認済み。Base directory起点の解決に一本化されている）
# (iv) skills/*.md 内の呼び出し記述と agents/*.md 内の自己記述（いずれも
#      `subagent_type: '...'` の表記）が、プラグイン名前空間プレフィックス
#      `claude-harness:` 付きであること（Issue #41 実機プローブ: プレフィックス無しの
#      subagent_type は名称解決エラーになる。CodeRabbit指摘対応(PR #92)で
#      subagent_type を検査対象に追加）。
# (v) 「実行時にプラグインルートへ展開される」という誤説明の再出現（CLAUDE_PLUGIN_ROOT は
#     Bash 環境変数として存在せず展開されない — 実機検証済み。正しくは「表記上の
#     プレースホルダであり、実行前に Base directory から解決した絶対パスに置換する」）
# (vi) allowlist できない実行形（実行位置の ${CLAUDE_PLUGIN_ROOT}・マシン固有な絶対パスの
#      直書き・ランチャーへの実行系/パス/環境変数の前置）。Issue #154 の再発防止。
#      検出パターン自体の自己検査（既知の違反形・正当形での検証）を同セクション内に持つ。
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
bare_doc_pattern='`scripts/[A-Za-z0-9_./-]+\.md`'
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
echo "=== (iv) subagent_type プラグイン名前空間プレフィックスチェック ==="

# CodeRabbit指摘対応（PR #92）: subagent_type（Task ツールが受け取る引数名。
# docs/plugin-path-conventions.md (g) がプレフィックス必須の対象としている）を検査しないと、
# 裸の subagent_type が名称解決エラーになる契約なのにこの再発防止テストが見逃してしまう。
# shellcheck disable=SC2016
agenttype_pattern="subagent_type:[[:space:]]*'[^']+'"
agenttype_hits="$(grep -rnoE "$agenttype_pattern" skills agents --include='*.md')"
agenttype_exit=$?

if [ "$agenttype_exit" -ge 2 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("subagent_type 名前空間プレフィックスチェックの grep 実行に失敗")
  echo "  NG - grep 実行エラー（exit ${agenttype_exit}）のため判定不能"
else
  agenttype_violations=""
  if [ -n "$agenttype_hits" ]; then
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      case "$hit" in
        *"subagent_type: 'claude-harness:"*) continue ;;
      esac
      agenttype_violations="${agenttype_violations}${hit}
"
    done <<<"$agenttype_hits"
  fi

  if [ -z "$agenttype_violations" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - subagent_type はすべて claude-harness: プレフィックス付き"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("claude-harness: プレフィックス無しの subagent_type を検出")
    echo "  NG - claude-harness: プレフィックス無しの subagent_type を検出"
    print_indented "$agenttype_violations"
  fi
fi

echo ""
echo "=== (v) 誤った「実行時に展開」説明の再出現チェック ==="

# 「実行時に…展開」「自動的に…展開」「環境変数として展開」等の言い換えも検出する。
# 正しい説明（「実行前に…絶対パスに置換」「絶対パスへ展開したうえで」= モデル自身が行う指示）は
# 「実行時に/自動」を含まないためマッチしない。
misexp_pattern='(実行時に[^。]*展開|自動的に[^。]*展開|自動で[^。]*展開|環境変数として[^。]*展開)'
# 対象は実行時にモデルへロードされる skills/ agents/ のみ。docs/（特に規約正本
# docs/plugin-path-conventions.md）は誤説明の引用・「hooks 設定内でのみ展開される」という
# 正当な説明を必然的に含むため対象外（実行時ファイルからの docs/ 参照は検査(ii)で禁止済み）。
misexp_hits="$(grep -rnE "$misexp_pattern" skills agents --include='*.md')"
misexp_exit=$?

if [ "$misexp_exit" -ge 2 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("誤った「実行時に展開」説明チェックの grep 実行に失敗")
  echo "  NG - grep 実行エラー（exit ${misexp_exit}）のため判定不能"
elif [ -n "$misexp_hits" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("誤った「実行時にプラグインルートへ展開される」説明を検出")
  echo "  NG - 誤った「実行時にプラグインルートへ展開される」説明を検出"
  print_indented "$misexp_hits"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 誤った「実行時に展開」説明は無い"
fi

echo ""
echo "=== (vi) allowlist できない実行形チェック ==="

# Issue #154: Claude Code の Bash permission マッチャは
#  - ワイルドカードがトークン境界でしか効かない（パス中間の `*` は解釈されない）
#  - `:` より手前はルールとコマンドが引用符まで含めて完全一致する必要がある
#  - 先頭トークンが一致しないとマッチしない
# ため、スクリプト実行は必ずランチャー経由（`claude-harness-run <target>`）にする。検出対象は:
#  (a) `${CLAUDE_PLUGIN_ROOT}` を実行位置に書く形（引用符の有無を問わない。そもそも展開されない）
#  (b) 実行位置にマシン固有の絶対パスを直書きする形（配布プラグインでは成立しない）
#  (c) ランチャーへの実行系・パス・環境変数の前置（bash claude-harness-run / …/claude-harness-run /
#      FOO=bar claude-harness-run。環境変数は `--env` で渡す）
# フォールバック形 `bash "<プラグインルート>/scripts/xxx.sh"` はプレースホルダ表記であり、
# パスの引用符も含めて正当（引数側の引用符は allowlist に影響しない）。
# 規約の正本は docs/plugin-path-conventions.md (a)。

# 実行位置の ${CLAUDE_PLUGIN_ROOT}（引用符あり・なしの両方）
plugin_root_exec_pattern='(bash|node)[[:space:]]+"?\$\{?CLAUDE_PLUGIN_ROOT\}?'
# 実行位置のマシン固有な絶対パス直書き（引用符あり・なしの両方）
abs_path_exec_pattern='(bash|node)[[:space:]]+"?/[A-Za-z0-9_./~-]+\.(sh|mjs|js)'
# ランチャーの前置。環境変数名は POSIX 準拠（小文字・数字・アンダースコアを含む）で受ける
prefixed_launcher_pattern='(bash[[:space:]]+claude-harness-run|[A-Za-z0-9_./~-]+/claude-harness-run|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+claude-harness-run)'

# --- (vi-a) 検出パターン自体の自己検査 ---
# このテストが本規約の唯一の再発防止装置であり、パターンが壊れると違反を素通りさせて
# しまう（grep は「マッチなし」と「検出できない」を区別しない）。既知の違反形・正当形を
# 直接パターンに掛けて、検出器そのものが機能していることを確認する。
assert_detects() {
  local description="$1" pattern="$2" expected="$3" sample="$4"
  local actual="no"
  printf '%s\n' "$sample" | grep -qE "$pattern" && actual="yes"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("検出パターンの自己検査: ${description}")
    echo "  NG - ${description}（expected=${expected} actual=${actual}）"
    echo "       pattern: ${pattern}"
    echo "       sample:  ${sample}"
  fi
}

# サンプルは検出器へ掛けるリテラル文字列であり、${CLAUDE_PLUGIN_ROOT} や ~ を展開させないため
# シングルクォートで書く（展開したら検査にならない）。関数化しているのは、この意図的な
# シングルクォート群へまとめて shellcheck 指示子を効かせるため。
# shellcheck disable=SC2016,SC2088
run_detector_self_checks() {
  assert_detects '違反: bash "${CLAUDE_PLUGIN_ROOT}/..." を検出する' \
    "$plugin_root_exec_pattern" yes 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/xxx.sh" <引数>'
  assert_detects '違反: 引用符なしの ${CLAUDE_PLUGIN_ROOT} 実行も検出する' \
    "$plugin_root_exec_pattern" yes 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/xxx.sh <引数>'
  assert_detects '違反: node "${CLAUDE_PLUGIN_ROOT}/..." を検出する' \
    "$plugin_root_exec_pattern" yes 'node "${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/run-walkthrough.mjs"'
  assert_detects '正当: フォールバックのプレースホルダ表記は検出しない' \
    "$plugin_root_exec_pattern" no 'bash "<プラグインルート>/scripts/xxx.sh" <引数>'

  assert_detects '違反: 引用符付きの絶対パス直書き実行を検出する' \
    "$abs_path_exec_pattern" yes 'bash "/Users/me/.claude/plugins/cache/mp/claude-harness/3.2.0/scripts/xxx.sh"'
  assert_detects '違反: 引用符なしの絶対パス直書き実行を検出する' \
    "$abs_path_exec_pattern" yes 'bash /Users/me/.claude/plugins/cache/mp/claude-harness/3.2.0/scripts/xxx.sh'
  assert_detects '正当: bash -c "<コマンド>" は検出しない' \
    "$abs_path_exec_pattern" no 'bash -c "<Step2で特定したE2Eコマンド>"'
  assert_detects '正当: フォールバックのプレースホルダ表記は検出しない' \
    "$abs_path_exec_pattern" no 'bash "<プラグインルート>/scripts/xxx.sh" <引数>'

  assert_detects '違反: bash 前置のランチャー呼び出しを検出する' \
    "$prefixed_launcher_pattern" yes 'bash claude-harness-run quality-check-runner'
  assert_detects '違反: パス付きのランチャー呼び出しを検出する' \
    "$prefixed_launcher_pattern" yes '~/.local/bin/claude-harness-run quality-check-runner'
  assert_detects '違反: 大文字の環境変数前置を検出する' \
    "$prefixed_launcher_pattern" yes 'FOO=bar claude-harness-run quality-check-runner'
  assert_detects '違反: 小文字（POSIX 形式）の環境変数前置も検出する' \
    "$prefixed_launcher_pattern" yes 'foo_bar2=baz claude-harness-run quality-check-runner'
  assert_detects '正当: --env 経由の環境変数受け渡しは検出しない' \
    "$prefixed_launcher_pattern" no "claude-harness-run --env FOO=bar demo-e2e-out 'CASE-101'"
  assert_detects '正当: cd との複合コマンドは検出しない' \
    "$prefixed_launcher_pattern" no 'cd "{worktreeパス}" && claude-harness-run ci-wait {PR番号}'
}

run_detector_self_checks

# --- (vi-b) 実ファイルの走査 ---
plugin_root_exec_hits="$(grep -rnE "$plugin_root_exec_pattern" skills agents --include='*.md')"
plugin_root_exec_exit=$?
abs_path_exec_hits="$(grep -rnE "$abs_path_exec_pattern" skills agents --include='*.md')"
abs_path_exec_exit=$?
prefixed_launcher_hits="$(grep -rnE "$prefixed_launcher_pattern" skills agents --include='*.md')"
prefixed_launcher_exit=$?

if [ "$plugin_root_exec_exit" -ge 2 ] || [ "$abs_path_exec_exit" -ge 2 ] || [ "$prefixed_launcher_exit" -ge 2 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("allowlist できない実行形チェックの grep 実行に失敗")
  echo "  NG - grep 実行エラー（exit ${plugin_root_exec_exit}/${abs_path_exec_exit}/${prefixed_launcher_exit}）のため判定不能"
else
  bad_exec_violations="${plugin_root_exec_hits}
${abs_path_exec_hits}
${prefixed_launcher_hits}"
  bad_exec_violations="$(printf '%s\n' "$bad_exec_violations" | grep -v '^[[:space:]]*$')"

  if [ -z "$bad_exec_violations" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - allowlist できない実行形（\${CLAUDE_PLUGIN_ROOT} 実行・絶対パス直書き・ランチャーへの前置）は無い"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("allowlist できない実行形を検出")
    echo "  NG - allowlist できない実行形を検出"
    print_indented "$bad_exec_violations"
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
