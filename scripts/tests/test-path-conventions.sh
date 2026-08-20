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
# (vii) ランチャー／フォールバックへ渡すパス引数の引用漏れ（空白を含むパスで引数が分割される）。
#       先頭トークンと target は規約上引用符を付けないため対象外。検出器の自己検査つき。
# (viii) 「シェルクォート安全埋め込み」の規律を持つファイルが、同じ実行形テンプレートで
#        その非信頼値を "<value>" の形で示していないこと（規律とテンプレートの自己矛盾）。
#        PR #176 が持ち込んだコマンドインジェクションの回帰と同型。
# (ix) 「スクリプトの実行形（重要）」定型注記の**不変コアの節**が各コピーに揃っていること。
#      正本とのバイト一致は要求しない（呼び出し箇所ごとに正当に異なる部分を潰すと回帰を作る）。
# (x) 「参照ファイルの読み出し（重要）」定型注記に、配送経路（read-plugin-doc）と
#     失敗時の停止規則の節が揃っていること。Read 直読みは headless で沈黙して失敗するため。
# (xi) references/ templates/ 参照の解決性（dangling / orphan / 解決不能表記）。
# を検出する。規約の正本は docs/plugin-path-conventions.md（(ix)(x)(xi) は同 (b)(c)、
# 棚卸しの記録は docs/skill-note-inventory.md）。
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
echo "=== (vii) ランチャー／フォールバックへ渡すパス引数の引用チェック ==="

# docs/plugin-path-conventions.md (a): 「引数として渡す値（パス等）は従来どおり引用してよい」
# 「空白を含みうる値（ファイルパス・worktree パス等）は**引用する**」。
# 引用を落とすと、空白を含むリポジトリパスで引数が分割され、スクリプトが
# 「引数が多すぎる」と誤認して異常終了する（Issue #171-4）。
# 検出対象は「コマンド文字列の中の、引用符が付いていないパス様の引数」。
# 先頭トークン（ランチャー／bash）と target（スクリプト名・スクリプトパス）は
# 規約上引用符を付けないため対象外にする。

# パス様のトークン: パス区切りと拡張子を持つもの、または名前がパス／ファイルを指す
# プレースホルダ（`<...パス>` `<...file>` `{...path}` 等）。
# 拡張子を要求することで、ブランチ名（`{type}/issue-{番号}-{説明}`）を誤検出しない。
path_arg_pattern='(^|[^"'"'"'])[^[:space:]]*/[^[:space:]]*\.(md|json|sh|mjs|js|ts|txt|ya?ml|log)|^<[^>]*(パス|ファイル|path|Path|file|File)[^>]*>$|^\{[^}]*(パス|path|Path)[^}]*\}$'

# コマンド文字列を受け取り、引用されていないパス様の引数を1行1件で返す。
unquoted_path_args() {
  local command_string="$1"
  local -a tokens
  local token skip=0 index=0
  # shellcheck disable=SC2206 # 意図的にシェルのトークン分割で引数へ割る（引用符は文字として残る）
  tokens=($command_string)

  case "${tokens[0]:-}" in
    claude-harness-run)
      skip=1
      # --env KEY=VALUE はランチャー自身のオプション（規約上 target より前に置く）。
      # **複数回指定できる**ため、先頭から続く限り読み飛ばす（1組だけ飛ばすと
      # target を引数と誤認し、規約どおり引用符を付けない target を違反として報告する）。
      while [ "${tokens[$skip]:-}" = "--env" ]; do
        skip=$((skip + 2))
      done
      skip=$((skip + 1)) # target
      ;;
    bash)
      skip=2 # bash + スクリプトパス
      ;;
    *) return 0 ;;
  esac

  for token in "${tokens[@]}"; do
    index=$((index + 1))
    [ "$index" -le "$skip" ] && continue
    # リダイレクト以降は引数ではない
    case "$token" in
      '>' | '>>' | '|' | '&&' | ';') return 0 ;;
    esac
    # 既に引用されているものは対象外
    case "$token" in
      '"'* | "'"*) continue ;;
    esac
    if printf '%s' "$token" | grep -qE "$path_arg_pattern"; then
      printf '%s\n' "$token"
    fi
  done
  return 0
}

# --- (vii-a) 検出パターン自体の自己検査 ---
assert_arg_detection() {
  local description="$1" expected="$2" command_string="$3"
  local actual="no"
  [ -n "$(unquoted_path_args "$command_string")" ] && actual="yes"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("パス引数の引用検出の自己検査: ${description}")
    echo "  NG - ${description}（expected=${expected} actual=${actual}）"
    echo "       command: ${command_string}"
  fi
}

assert_arg_detection '違反: 引用符なしの台帳パスを検出する' yes \
  'claude-harness-run guarantee-index-check <リポジトリルート>/docs/guarantees.md'
assert_arg_detection '違反: 引用符なしの cwd 相対パスを検出する' yes \
  'claude-harness-run guarantee-index-check docs/guarantees.md'
assert_arg_detection '違反: 引用符なしのパスプレースホルダを検出する' yes \
  'claude-harness-run reply-and-resolve <PR番号> <items_json_file>'
assert_arg_detection '違反: フォールバック形の引数側の引用漏れも検出する' yes \
  'bash "<プラグインルート>/scripts/guarantee-index-check.sh" docs/guarantees.md'
assert_arg_detection '正当: 引用符付きのパス引数は検出しない' no \
  'claude-harness-run guarantee-index-check "<リポジトリルート>/docs/guarantees.md"'
assert_arg_detection '正当: target のスクリプトパス（引用符なしが規約）は検出しない' no \
  'claude-harness-run skills/demo/scripts/run-walkthrough.mjs "/絶対パス/flow.mjs"'
assert_arg_detection '正当: 番号・フラグ列は検出しない' no \
  'claude-harness-run quality-check-runner <Step2で組み立てたCLIフラグ列>'
assert_arg_detection '正当: ブランチ名（拡張子を持たない）は検出しない' no \
  'claude-harness-run worktree-setup {issue番号} {type}/issue-{番号}-{説明} {base}'
assert_arg_detection '正当: リダイレクト先は引数ではないので検出しない' no \
  'claude-harness-run analyze-project . > /tmp/analyze-output.json'
assert_arg_detection '正当: --env 付きの呼び出しでも target を誤検出しない' no \
  "claude-harness-run --env FOO=bar demo-e2e-out 'CASE-101'"
assert_arg_detection '正当: --env を複数回指定しても target を誤検出しない' no \
  'claude-harness-run --env A=1 --env B=2 skills/demo/scripts/run-walkthrough.mjs "/絶対パス/flow.mjs"'
assert_arg_detection '違反: --env が複数あっても引数側の引用漏れは検出する' yes \
  'claude-harness-run --env A=1 --env B=2 skills/demo/scripts/run-walkthrough.mjs /絶対パス/flow.mjs'
assert_arg_detection '違反: 継続行を結合した形の引数も検出する' yes \
  'claude-harness-run skills/init-project/scripts/generate-settings.sh --input /tmp/analyze-output.json'
assert_arg_detection '正当: 継続行を結合した形でも引用済みなら検出しない' no \
  'claude-harness-run skills/init-project/scripts/generate-settings.sh --input "/tmp/analyze-output.json"'

# --- (vii-b) 実ファイルの走査 ---
# コマンド文字列の抽出: (1) バッククォートで囲まれた `claude-harness-run ...` /
# `bash "<プラグインルート>/..." ...`、(2) コードブロック内の行頭 claude-harness-run。
#
# **grep の終了コードは、パイプへ通す前に取ること**: `x="$(grep ... | tr ...)"` と書くと
# `$?` はパイプ最後尾（tr）のものになり、**grep の exit 2（実行エラー＝検査不能）が 0 に化ける**。
# 抽出と整形を段に分けて、grep 自身の終了コードを保存する。
# shellcheck disable=SC2016
launcher_spans_raw="$(grep -rhoE '`(claude-harness-run|bash "<プラグインルート>/)[^`]*`' skills agents --include='*.md')"
launcher_spans_exit=$?
launcher_spans="$(printf '%s' "$launcher_spans_raw" | tr -d '`')"

# **継続行（行末 `\`）を結合してから走査する**: 物理行だけを見ると、
# `claude-harness-run xxx \` の次行に置かれた引数が検査対象から外れる。
codeblock_files="$(find skills agents -name '*.md' -type f)"
codeblock_files_exit=$?
codeblock_spans=""
if [ -n "$codeblock_files" ]; then
  # shellcheck disable=SC2016 # awk プログラム本体であり、シェル展開を意図していない
  codeblock_spans="$(printf '%s\n' "$codeblock_files" | tr '\n' '\0' | xargs -0 awk '
    {
      if (pending != "") { cur = pending " " $0 } else { cur = $0 }
      pending = ""
      if (cur ~ /\\[[:space:]]*$/) {
        sub(/[[:space:]]*\\[[:space:]]*$/, "", cur)
        pending = cur
        next
      }
      if (cur ~ /^[[:space:]]*claude-harness-run /) { print cur }
    }
    END { if (pending ~ /^[[:space:]]*claude-harness-run /) { print pending } }
  ')"
fi
codeblock_spans_exit=$?

if [ "$launcher_spans_exit" -ge 2 ] || [ "$codeblock_spans_exit" -ge 2 ] || [ "$codeblock_files_exit" -ne 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("パス引数の引用チェックの抽出に失敗")
  echo "  NG - 抽出エラー（grep=${launcher_spans_exit} / awk=${codeblock_spans_exit} / find=${codeblock_files_exit}）のため判定不能"
elif [ -z "$launcher_spans" ] && [ -z "$codeblock_spans" ]; then
  # 抽出0件は「違反なし」ではなく「検出器が対象を拾えていない」（検査不能≠0件）
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("ランチャー呼び出しを1件も抽出できず判定不能")
  echo "  NG - ランチャー呼び出しを1件も抽出できず判定不能（検出器が壊れている可能性）"
else
  unquoted_violations=""
  while IFS= read -r span; do
    [ -z "$span" ] && continue
    hits="$(unquoted_path_args "$span")"
    if [ -n "$hits" ]; then
      unquoted_violations="${unquoted_violations}${span}  →  ${hits}
"
    fi
  done <<<"${launcher_spans}
${codeblock_spans}"

  if [ -z "$unquoted_violations" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ランチャー／フォールバックへ渡すパス引数はすべて引用されている"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("引用符なしのパス引数を検出")
    echo "  NG - 引用符なしのパス引数を検出（空白を含むパスで引数が分割される）"
    print_indented "$unquoted_violations"
  fi
fi

echo ""
echo "=== (viii) 非信頼値をダブルクォートで埋め込ませていないか ==="

# 「シェルクォート安全埋め込み」の規律を持つスキルは、**その値をダブルクォートで
# 埋め込む実行形テンプレートを同時に載せてはならない**（テンプレートと規則が矛盾し、
# テンプレートに従うとコマンドインジェクションの余地が残る）。
# 対象値は規律の本文で名指しされているプレースホルダ（例: `<file>`）。
untrusted_violations=""
untrusted_checked=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # 規律が名指ししている値（`<name>` の形）を規律の行から取り出す
  rule_line="$(grep -F 'シェルクォート安全埋め込み' "$f")"
  # shellcheck disable=SC2016 # grep のパターン（バッククォート囲みのプレースホルダ）
  values="$(printf '%s' "$rule_line" | grep -oE '`<[A-Za-z_][A-Za-z0-9_]*>`' | tr -d '`' | sort -u)"
  [ -z "$values" ] && continue
  while IFS= read -r value; do
    [ -z "$value" ] && continue
    untrusted_checked=$((untrusted_checked + 1))
    # ランチャー／フォールバックのコマンド文字列の中で "値" の形になっていないか
    hits="$(grep -nE "(claude-harness-run|scripts/[A-Za-z0-9_-]+\.sh)\"?[^\`]*\"${value}\"" "$f")"
    hits_exit=$?
    if [ "$hits_exit" -ge 2 ]; then
      untrusted_violations="${untrusted_violations}${f}: grep 実行エラー（exit ${hits_exit}）
"
    elif [ -n "$hits" ]; then
      untrusted_violations="${untrusted_violations}${f}: ${value} がダブルクォートで埋め込まれている
${hits}
"
    fi
  done <<<"$values"
done <<<"$(grep -rl 'シェルクォート安全埋め込み' skills agents --include='*.md')"

if [ "$untrusted_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("非信頼値の検査対象を1件も抽出できず判定不能")
  echo "  NG - 非信頼値の検査対象を1件も抽出できず判定不能（検出器が壊れている可能性）"
elif [ -n "$untrusted_violations" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("非信頼値がダブルクォートで埋め込まれている")
  echo "  NG - 非信頼値がダブルクォートで埋め込まれている（規律とテンプレートの自己矛盾）"
  print_indented "$untrusted_violations"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 「シェルクォート安全埋め込み」の対象値（${untrusted_checked} 件）はダブルクォートで埋め込まれていない"
fi

echo ""
echo "=== (ix) 定型注記の不変コア節チェック（スクリプトの実行形） ==="

# 「スクリプトの実行形（重要）」の定型注記は 29 箇所に逐語コピーされている。
# **これを正本1箇所＋参照へ集約する道は取らない**: 参照先（references/）はプラグイン配下
# ＝作業ディレクトリ外にあり、headless 委譲では Read が拒否されるため、集約すると規約が
# 1バイトも届かなくなる（規約の正本 docs/plugin-path-conventions.md (b) 参照）。
# 一方、正本とのバイト一致照合も取らない: 注記は呼び出し箇所ごとに正当に異なる部分
# （スクリプト名・引数・--env の要否・非信頼値の扱い・スキル固有の cwd 制約）を持ち、
# 一致を強制すると適用範囲の例外を潰して回帰を作る（PR #176 で実際に、非信頼値まで
# ダブルクォートで囲んでコマンドインジェクションの余地を作った）。
#
# そこで**不変コアの節だけを固定し、可変部は自由に残す**。下記の節が1つでも欠けた
# コピーは、その箇所で規約が機能しない:
#   - プラグイン配下          : 探す場所（欠けると導入先プロジェクトを探す）
#   - Bash(claude-harness-run:*) : この形でしか allowlist できない理由（欠けると「親切に」パスを足す）
#   - 相対パス                : 禁止形の明示
#   - command not found       : フォールバックの発動条件
#   - Base directory          : 成立する唯一のルート解決手順
#   - プレースホルダ          : ${CLAUDE_PLUGIN_ROOT} を環境変数と誤解させない歯止め
#   - ランチャー導入          : 恒久解（欠けると毎回フォールバックし続ける）

EXEC_NOTE_MARKER='**スクリプトの実行形（重要）**'
EXEC_NOTE_REQUIRED=(
  'プラグイン配下'
  'Bash(claude-harness-run:*)'
  '相対パス'
  'command not found'
  'Base directory'
  'プレースホルダ'
  'ランチャー導入'
)

REF_NOTE_MARKER='参照ファイルは導入先プロジェクトではなく'
REF_NOTE_REQUIRED=(
  'プラグイン配下'
  'read-plugin-doc'
  '非0'
  '停止'
  'command not found'
  'Base directory'
)

# 1行の注記テキストと必須節の配列名を受け取り、欠けている節を1行1件で返す。
# 節の照合は grep -F（バイト厳密）で行う。macOS 標準 awk は非 ASCII 文字列の `==` を
# 誤って真にするため、日本語を含む一致判定には使わない（scripts/README.md「テスト」節）。
missing_clauses() {
  local text="$1"
  shift
  local clause
  for clause in "$@"; do
    printf '%s' "$text" | grep -qF "$clause" || printf '%s\n' "$clause"
  done
}

# --- (ix-a) 検出器自体の自己検査 ---
# grep は「欠落なし」と「照合が壊れて何も見つけられない」を区別しない。既知の完全形・
# 欠落形を直接掛けて、検出器が機能していることを確認する。
assert_missing() {
  local description="$1" expected="$2" text="$3"
  shift 3
  local actual
  actual="$(missing_clauses "$text" "$@" | tr '\n' ',' | sed 's/,$//')"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("不変コア検出器の自己検査: ${description}")
    echo "  NG - ${description}（expected='${expected}' actual='${actual}'）"
  fi
}

# サンプルはリテラルとして掛けるためシングルクォートで書く（展開したら検査にならない）。
# shellcheck disable=SC2016
run_exec_note_selfcheck() {
  local complete='本スキルはプラグインとして配布されるため、スクリプトはプラグイン配下にある。必ず `claude-harness-run xxx` の形式（この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）で実行し、相対パス `scripts/xxx.sh` では呼び出さないこと。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/xxx.sh"` にフォールバックする（プラグインルートは「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。ユーザーにランチャー導入を案内すること。'

  assert_missing '完全な注記では欠落を報告しない' '' "$complete" "${EXEC_NOTE_REQUIRED[@]}"

  # 実際に起きたドリフト（agents/feature-implementer.md が allowlist 根拠・プレースホルダ・
  # 恒久解の3節を落としていた形）を再現し、3件とも報告されることを確認する。
  # 置換ではなくリテラルで書く: パラメータ展開のパターンでは `*` がグロブとして働き、
  # 意図より広く食って別の節まで消した「別物」を検査してしまうため。
  local drifted='本スキルはプラグインとして配布されるため、スクリプトはプラグイン配下にある。必ず `claude-harness-run xxx` の形式（パス・バージョン・引用符を付けない）で実行し、相対パス `scripts/xxx.sh` では呼び出さないこと。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/xxx.sh"` にフォールバックする（プラグインルートは「Base directory for this skill」から解決した絶対パス）。'
  assert_missing '実際に起きた3節ドリフトを検出する' \
    'Bash(claude-harness-run:*),プレースホルダ,ランチャー導入' \
    "$drifted" "${EXEC_NOTE_REQUIRED[@]}"

  assert_missing '所在の節が欠けた注記を検出する' 'プラグイン配下' \
    "${complete//プラグイン配下/導入先}" "${EXEC_NOTE_REQUIRED[@]}"
  assert_missing '禁止形の節が欠けた注記を検出する' '相対パス' \
    "${complete//相対パス/相対的なパス表記}" "${EXEC_NOTE_REQUIRED[@]}"
  assert_missing 'フォールバック発動条件が欠けた注記を検出する' 'command not found' \
    "${complete//command not found/実行できない場合}" "${EXEC_NOTE_REQUIRED[@]}"
  assert_missing 'ルート解決手順が欠けた注記を検出する' 'Base directory' \
    "${complete//Base directory for this skill/スキルの基準ディレクトリ}" "${EXEC_NOTE_REQUIRED[@]}"
}
run_exec_note_selfcheck

# --- (ix-b) 実ファイルの走査 ---
exec_note_violations=""
exec_note_checked=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"
    text="${hit#*:}"
    exec_note_checked=$((exec_note_checked + 1))
    missing="$(missing_clauses "$text" "${EXEC_NOTE_REQUIRED[@]}" | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$missing" ]; then
      exec_note_violations="${exec_note_violations}${f}:${lineno}: 欠落節 ${missing}
"
    fi
  done <<<"$(grep -nF "$EXEC_NOTE_MARKER" "$f")"
done <<<"$(grep -rlF "$EXEC_NOTE_MARKER" skills agents --include='*.md')"

if [ "$exec_note_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("スクリプトの実行形注記を1件も抽出できず判定不能")
  echo "  NG - スクリプトの実行形注記を1件も抽出できず判定不能（検出器が壊れている可能性）"
elif [ -n "$exec_note_violations" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("スクリプトの実行形注記から不変コアの節が欠けている")
  echo "  NG - スクリプトの実行形注記から不変コアの節が欠けている"
  print_indented "$exec_note_violations"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - スクリプトの実行形注記（${exec_note_checked} 箇所）はすべて不変コアの節を備えている"
fi

echo ""
echo "=== (x) 参照ファイル読み出し注記の配送経路チェック ==="

# references/ templates/ はプラグイン配下＝作業ディレクトリ外にあり、Read ツールでの
# 読み出しは利用側の allow が無ければ拒否される。headless 委譲には許可する相手がいないため
# 拒否がそのまま確定するが、**モデルは読めないまま手順を推測して完走できてしまう**
# （実測: /guarantee-audit bootstrap が references/bootstrap-mode.md を読めないまま完走し、
#  検証器の exit 2 で初めて発覚した）。
# そこで読み出しを allowlist 済みの配送経路（read-plugin-doc）へ寄せ、届かない場合は
# 非0 終了で止まる形にしてある。注記からこの節が落ちると沈黙する失敗へ戻るため固定する。

run_ref_note_selfcheck() {
  local complete='参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。読み出しは `claude-harness-run read-plugin-doc "skills/x/references/y.md"` で行う。**非0 終了は「読まなくてよかった」ではない** — 推測で続行せず停止して報告すること。`claude-harness-run: command not found` の場合のみ Read へフォールバックし、「Base directory for this skill」を起点に解決する。'

  assert_missing '完全な読み出し注記では欠落を報告しない' '' "$complete" "${REF_NOTE_REQUIRED[@]}"
  assert_missing '配送経路が欠けた注記（Read 一本の旧形）を検出する' 'read-plugin-doc' \
    "${complete//read-plugin-doc/cat}" "${REF_NOTE_REQUIRED[@]}"
  # 停止規則の節だけを落とした形。`**` はパラメータ展開のパターンではグロブとして
  # 解釈されるため、置換ではなくリテラルを別に書く（置換にすると先頭から食われ、
  # 別の節まで消えた別物を検査してしまう）。
  local no_halt_rule='参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。読み出しは `claude-harness-run read-plugin-doc "skills/x/references/y.md"` で行う。`claude-harness-run: command not found` の場合のみ Read へフォールバックし、「Base directory for this skill」を起点に解決する。'
  assert_missing '失敗時の停止規則が欠けた注記を検出する' '非0,停止' \
    "$no_halt_rule" "${REF_NOTE_REQUIRED[@]}"
}
run_ref_note_selfcheck

ref_note_violations=""
ref_note_checked=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"
    text="${hit#*:}"
    ref_note_checked=$((ref_note_checked + 1))
    missing="$(missing_clauses "$text" "${REF_NOTE_REQUIRED[@]}" | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$missing" ]; then
      ref_note_violations="${ref_note_violations}${f}:${lineno}: 欠落節 ${missing}
"
    fi
  done <<<"$(grep -nF "$REF_NOTE_MARKER" "$f")"
done <<<"$(grep -rlF "$REF_NOTE_MARKER" skills agents --include='*.md')"

if [ "$ref_note_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("参照ファイル読み出し注記を1件も抽出できず判定不能")
  echo "  NG - 参照ファイル読み出し注記を1件も抽出できず判定不能（検出器が壊れている可能性）"
elif [ -n "$ref_note_violations" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("参照ファイル読み出し注記から配送経路・停止規則の節が欠けている")
  echo "  NG - 参照ファイル読み出し注記から配送経路・停止規則の節が欠けている"
  print_indented "$ref_note_violations"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 参照ファイル読み出し注記（${ref_note_checked} 箇所）はすべて配送経路と停止規則を備えている"
fi

echo ""
echo "=== (xi) references/ templates/ 参照の解決性チェック ==="

# 「A の記述と B のファイル配置を一致させること」という散文規定は必ずずれ、ずれても
# 誰も検出しない。参照先の綴り違い・移動・スキル跨ぎの書き方（`<base>/../<skill>/...`）を
# 機械で解決し、(a) 指しているのに存在しない（dangling）と
# (b) 存在するのにどこからも指されていない（orphan）の両方を検出する。

# 1行のテキストから参照トークンを抜き、プラグインルート相対の実パスへ解決して1行1件で返す。
# 解決できない表記（owner スキルの無い agents/ からの裸の `references/...`）は
# 先頭に "UNRESOLVED " を付けて返す。
REF_TOKEN_PATTERN='((skills/[a-z0-9_-]+/)|(<[^>]*>/(\.\./[a-z0-9_-]+/)?))?(references|templates)/[A-Za-z0-9_.-]+'

resolve_ref_tokens() {
  local text="$1" owner="$2" tok
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in
      skills/*) printf '%s\n' "$tok" ;;
      \<*\>/../*) printf 'skills/%s\n' "${tok#*/../}" ;;
      \<*\>/*)
        if [ -z "$owner" ]; then printf 'UNRESOLVED %s\n' "$tok"
        else printf 'skills/%s/%s\n' "$owner" "${tok#*>/}"; fi
        ;;
      *)
        if [ -z "$owner" ]; then printf 'UNRESOLVED %s\n' "$tok"
        else printf 'skills/%s/%s\n' "$owner" "$tok"; fi
        ;;
    esac
  done <<<"$(printf '%s' "$text" | grep -oE "$REF_TOKEN_PATTERN")"
}

# --- (xi-a) 解決器自体の自己検査 ---
assert_resolves() {
  local description="$1" owner="$2" expected="$3" text="$4"
  local actual
  actual="$(resolve_ref_tokens "$text" "$owner" | tr '\n' ',' | sed 's/,$//')"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("参照解決器の自己検査: ${description}")
    echo "  NG - ${description}（expected='${expected}' actual='${actual}'）"
  fi
}

# shellcheck disable=SC2016
run_ref_resolve_selfcheck() {
  assert_resolves '同一スキル内の <base> 相対を owner で解決する' 'para-impl' \
    'skills/para-impl/references/star-parallel.md' '手順は `<base>/references/star-parallel.md` を読む'
  assert_resolves 'スキル跨ぎの <base>/../<skill>/ を正しく解決する' 'para-impl' \
    'skills/create-ticket/references/guarantee-section.md' \
    '正本は `<base>/../create-ticket/references/guarantee-section.md`'
  assert_resolves 'エージェント側の <...base>/../<skill>/ も解決する' '' \
    'skills/create-ticket/references/guarantee-section.md' \
    '`<tdd-implのbase>/../create-ticket/references/guarantee-section.md` で解決して Read する'
  assert_resolves 'プラグインルート相対のフルパスをそのまま扱う' 'guarantee-audit' \
    'skills/guarantee-audit/references/bootstrap-mode.md' \
    'read-plugin-doc "skills/guarantee-audit/references/bootstrap-mode.md"'
  assert_resolves '裸の templates/ も owner で解決する' 'init-project' \
    'skills/init-project/templates/detection-report.md' '`templates/detection-report.md` を Read し'
  assert_resolves 'owner の無いファイルからの裸の参照は解決不能として報告する' '' \
    'UNRESOLVED references/guarantee-section.md' '正本は `references/guarantee-section.md`'
  assert_resolves '参照トークンが無ければ何も返さない' 'demo' '' 'ここには参照トークンが無い'
}
run_ref_resolve_selfcheck

# --- (xi-b) dangling: 指しているのに存在しない ---
ref_dangling=""
ref_tokens_checked=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    skills/*) owner="$(printf '%s' "$f" | cut -d/ -f2)" ;;
    *) owner="" ;;
  esac
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"
    text="${hit#*:}"
    while IFS= read -r target; do
      [ -z "$target" ] && continue
      ref_tokens_checked=$((ref_tokens_checked + 1))
      case "$target" in
        "UNRESOLVED "*)
          ref_dangling="${ref_dangling}${f}:${lineno}: 参照先を解決できない表記 ${target#UNRESOLVED }（owner スキルが無いファイルからは \`<...base>/../<skill>/...\` かプラグインルート相対で書く）
"
          ;;
        *)
          [ -e "$target" ] || ref_dangling="${ref_dangling}${f}:${lineno}: 参照先が存在しない ${target}
"
          ;;
      esac
    done <<<"$(resolve_ref_tokens "$text" "$owner")"
  done <<<"$(grep -nE "$REF_TOKEN_PATTERN" "$f")"
done <<<"$(find skills agents -name '*.md' | sort)"

if [ "$ref_tokens_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("参照トークンを1件も抽出できず判定不能")
  echo "  NG - 参照トークンを1件も抽出できず判定不能（検出器が壊れている可能性）"
elif [ -n "$ref_dangling" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("references/ templates/ への参照が解決できない")
  echo "  NG - references/ templates/ への参照が解決できない"
  print_indented "$ref_dangling"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - references/ templates/ への参照（${ref_tokens_checked} 件）はすべて実在ファイルへ解決する"
fi

# --- (xi-c) orphan: 存在するのにどこからも指されていない ---
ref_orphans=""
ref_files_checked=0
while IFS= read -r target; do
  [ -z "$target" ] && continue
  [ -f "$target" ] || continue
  ref_files_checked=$((ref_files_checked + 1))
  kind="$(printf '%s' "$target" | cut -d/ -f3)"
  base="$(basename "$target")"
  cites="$(grep -rlF "${kind}/${base}" skills agents)"
  cites_exit=$?
  if [ "$cites_exit" -ge 2 ]; then
    ref_orphans="${ref_orphans}${target}: grep 実行エラー（exit ${cites_exit}）
"
  elif [ -z "$cites" ]; then
    ref_orphans="${ref_orphans}${target}: どのスキル・エージェントからも参照されていない
"
  fi
done <<<"$(find skills -path '*/references/*' -o -path '*/templates/*' | sort)"

if [ "$ref_files_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("references/ templates/ のファイルを1件も列挙できず判定不能")
  echo "  NG - references/ templates/ のファイルを1件も列挙できず判定不能（検出器が壊れている可能性）"
elif [ -n "$ref_orphans" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("どこからも参照されない references/ templates/ ファイルがある")
  echo "  NG - どこからも参照されない references/ templates/ ファイルがある"
  print_indented "$ref_orphans"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - references/ templates/ のファイル（${ref_files_checked} 件）はすべてどこかから参照されている"
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
