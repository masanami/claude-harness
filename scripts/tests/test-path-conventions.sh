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
#      注記**全文**のバイト一致は要求しない（呼び出し箇所ごとに正当に異なる部分を潰すと
#      回帰を作る）が、意味を反転させても部分一致は通ってしまう節（停止規則・禁止形）だけは
#      可変部を含まない**一文まるごと**で照合し、あわせて反転語彙の不在も見る。
#      走査対象には正本テンプレート（docs/plugin-path-conventions.md）も含める
#      ——正本だけ緩められる状態を残さないため。
# (x) 「参照ファイルの読み出し（重要）」定型注記に、配送経路（read-plugin-doc）・失敗時の
#     停止規則・終端マーカーによる切り詰め検査・**配送元の同一性（root 照合）** の節が
#     揃っていること。Read 直読みは headless で沈黙して失敗し、出力上限による部分配送も
#     exit 0 のまま沈黙し、さらにランチャーは同居する最大バージョンを選ぶため
#     **完結しているが別バージョンの本文**も沈黙して通る（`scripts/specs/read-plugin-doc.md`
#     「配送元の同一性」が停止を要求している義務を、呼び出し側の注記へ接続する）。
#     さらに references/ templates/ を持つスキルに注記が在ることを**全称条件**で確かめる
#     （「注記が在るなら中身を見る」だけでは、注記を置いていない新規スキルが素通りする）。
#     加えて (x-e) が、para-impl のゲート参照2本（join-gate / star-parallel）
#     については**本文中の個々の読み出し指示まで**配送経路が第一手であることを見る
#     （注記は配送経路・本文は Read という二重規則の再発防止）。検出器の自己検査つき。
# (xi) references/ templates/ 参照の解決性（dangling / orphan / 解決不能表記）。
# (xii) 定型注記末尾の正本コメント `<!-- 正本: ... -->` の隣接重複。注記本体だけを
#       差し替える一括置換が、既存のコメント行を残したまま2行にしてしまう事故の再発防止。
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

# (ii) docs/ 設計文書参照の許容リスト。現時点では既知の例外は無い。
#
# **行番号でピン止めしたエントリは置かない。** かつて init-project/SKILL.md:137 を
# 「生成先ドキュメントの標準パス例」として許容していたが、その後の編集で行がずれ、
# ピンは当該記述とは無関係な行を指したまま残っていた（＝将来その行に来た違反を黙って許す）。
# (ii) 側に「プラグイン内に実在する docs/*.md か」で絞る判定が入ったため、この種の
# 例外指定はそもそも不要になっている。例外が要る場合は行番号ではなく判定条件で表現すること。
DOCS_REF_ALLOWLIST="
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

# 走査対象には**正本テンプレートを含む** `docs/plugin-path-conventions.md` も入れる。
# コピー側だけを検査して正本を検査しないと、正本を緩めてから一括コピーする経路で
# テストが緑のまま規約が骨抜きになる（正本とコピーが別々の規則で管理される状態）。
NOTE_SCAN_PATHS=(skills agents docs/plugin-path-conventions.md)

# 必須節のうち、**意味を反転させても部分一致は通ってしまう**もの（停止規則・禁止形）は
# 短い断片ではなく**可変部を含まない一文まるごと**で照合する。`grep -F` はバイト厳密なので、
# 「非0 終了でも停止は不要」のような反転はここで落ちる。
# 呼び出し箇所ごとに正当に異なる部分（スクリプト名・引数・--env の要否）は依然として自由。
EXEC_NOTE_MARKER='**スクリプトの実行形（重要）**'
EXEC_NOTE_REQUIRED=(
  'ユーザーのプロジェクトroot ではなく、プラグイン配下'
  'この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる'
  'では呼び出さないこと'
  'command not found'
  'Base directory'
  '`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない'
  'ランチャー導入'
)

REF_NOTE_MARKER='参照ファイルは導入先プロジェクトではなく'
REF_NOTE_REQUIRED=(
  'プラグイン配下'
  'read-plugin-doc'
  '**非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること'
  'read-plugin-doc END'
  # 配送元の同一性。ランチャーは同居する**最大バージョン**を選ぶため、実行中の SKILL.md と
  # 別バージョンの参照ファイルが組み合わさりうる（`scripts/specs/read-plugin-doc.md`
  # 「配送元の同一性」が停止を要求している）。完了マーカーの検査だけでは、
  # **完結しているが別バージョンの本文**を通してしまう。可変部を含まない一文まるごとで照合する。
  '**BEGIN マーカーの `root=` が「Base directory for this skill」の親ツリー（`<root>/skills/<スキル名>` が Base directory）と一致しなければ、別バージョンの本文が届いている** — ランチャーは同居する最大バージョンを選ぶため旧版 SKILL.md ＋ 新版参照ファイルの混成になりうるので、手順へ進まず同様に停止して報告すること。'
  'command not found'
  'Base directory'
)

# 反転・骨抜きの語彙。必須節が在っても、これらが同じ行に在れば違反とする。
# 一文まるごとの照合と二重にしてあるのは、正本側の文を書き換えたうえで全コピーへ
# 展開する経路（正本もコピーも「一致」しているので一文照合だけでは通る）を塞ぐため。
NOTE_FORBIDDEN=(
  '続行してよい'
  '補完してよい'
  '停止は不要'
  '停止しなくてよい'
  '無視してよい'
  '読まなくてよい'
  '呼び出してよい'
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

# 1行の注記テキストから、含まれてはならない語彙を1行1件で返す。
# 「必須節が在る」だけでは意味の反転を検出できない（`非0` と `停止` の断片は、
# 「非0 終了でも停止は不要」という反転文にも含まれてしまう）ため、否定側と対で見る。
forbidden_clauses() {
  local text="$1"
  shift
  local clause
  for clause in "$@"; do
    printf '%s' "$text" | grep -qF "$clause" && printf '%s\n' "$clause"
  done
  return 0
}

# 注記1件を検査し、問題があれば「欠落節 ...」「禁止語 ...」の形で1行1件返す。
inspect_note() {
  local text="$1" required_name="$2"
  local missing forbidden
  case "$required_name" in
    exec) missing="$(missing_clauses "$text" "${EXEC_NOTE_REQUIRED[@]}" | tr '\n' ',' | sed 's/,$//')" ;;
    ref) missing="$(missing_clauses "$text" "${REF_NOTE_REQUIRED[@]}" | tr '\n' ',' | sed 's/,$//')" ;;
  esac
  forbidden="$(forbidden_clauses "$text" "${NOTE_FORBIDDEN[@]}" | tr '\n' ',' | sed 's/,$//')"
  [ -n "$missing" ] && printf '欠落節 %s\n' "$missing"
  [ -n "$forbidden" ] && printf '禁止語 %s\n' "$forbidden"
  return 0
}

# --- (ix-a) 検出器自体の自己検査 ---
# grep は「欠落なし」と「照合が壊れて何も見つけられない」を区別しない。既知の完全形・
# 欠落形を直接掛けて、検出器が機能していることを確認する。
# description / 期待される報告（空なら「問題なし」）/ 注記の種別（exec|ref）/ 注記テキスト
assert_note() {
  local description="$1" expected="$2" kind="$3" text="$4"
  local actual
  actual="$(inspect_note "$text" "$kind" | tr '\n' '|' | sed 's/|$//')"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("不変コア検出器の自己検査: ${description}")
    echo "  NG - ${description}"
    echo "       expected: '${expected}'"
    echo "       actual:   '${actual}'"
  fi
}

# サンプルはリテラルとして掛けるためシングルクォートで書く（展開したら検査にならない）。
# shellcheck disable=SC2016
# サンプルはリテラルとして掛けるためシングルクォートで書く（展開したら検査にならない）。
# 必須節を「可変部を含まない一文まるごと」にしたので、サンプルもその文をそのまま含む。
# shellcheck disable=SC2016
run_exec_note_selfcheck() {
  local complete='本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。必ず `claude-harness-run xxx` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）で実行し、相対パス `scripts/xxx.sh` では呼び出さないこと。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/xxx.sh"` にフォールバックする（プラグインルートは「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。ユーザーにランチャー導入を案内すること。'

  assert_note '完全な注記では問題を報告しない' '' exec "$complete"

  # 実際に起きたドリフト（agents/feature-implementer.md が allowlist 根拠・プレースホルダ・
  # 恒久解の3節を落としていた形）を再現し、3件とも報告されることを確認する。
  # 置換ではなくリテラルで書く: パラメータ展開のパターンでは `*` がグロブとして働き、
  # 意図より広く食って別の節まで消した「別物」を検査してしまうため。
  local drifted='本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。必ず `claude-harness-run xxx` の形式（パス・バージョン・引用符を付けない）で実行し、相対パス `scripts/xxx.sh` では呼び出さないこと。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/xxx.sh"` にフォールバックする（プラグインルートは「Base directory for this skill」から解決した絶対パス）。'
  assert_note '実際に起きた3節ドリフトを検出する' \
    '欠落節 この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる,`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない,ランチャー導入' \
    exec "$drifted"

  # 所在の節だけを落とした形。`**` を含む文字列はパラメータ展開のパターンでグロブとして
  # 働き、意図より広く食って別物を検査してしまうため、置換ではなくリテラルで書く。
  local no_locus='本スキルはプラグインとして配布されるため、スクリプトは導入先のどこかにある。必ず `claude-harness-run xxx` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）で実行し、相対パス `scripts/xxx.sh` では呼び出さないこと。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/xxx.sh"` にフォールバックする（プラグインルートは「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。ユーザーにランチャー導入を案内すること。'
  assert_note '所在の節が欠けた注記を検出する' \
    '欠落節 ユーザーのプロジェクトroot ではなく、プラグイン配下' exec "$no_locus"
  assert_note 'フォールバック発動条件が欠けた注記を検出する' '欠落節 command not found' \
    exec "${complete//command not found/実行できない場合}" 
  assert_note 'ルート解決手順が欠けた注記を検出する' '欠落節 Base directory' \
    exec "${complete//Base directory for this skill/スキルの基準ディレクトリ}"

  # 反転: 節は在るが「相対パスで呼び出してよい」を足した形。
  # 部分一致だけの検査ではこれが通ってしまう（必須節はすべて揃っているため）。
  assert_note '禁止形を許す文言を足した注記を検出する' '禁止語 呼び出してよい' \
    exec "${complete}なお相対パスで呼び出してよい。"
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
    while IFS= read -r problem; do
      [ -z "$problem" ] && continue
      exec_note_violations="${exec_note_violations}${f}:${lineno}: ${problem}
"
    done <<<"$(inspect_note "$text" exec)"
  done <<<"$(grep -nF "$EXEC_NOTE_MARKER" "$f")"
done <<<"$(grep -rlF "$EXEC_NOTE_MARKER" "${NOTE_SCAN_PATHS[@]}" --include='*.md')"

if [ "$exec_note_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("スクリプトの実行形注記を1件も抽出できず判定不能")
  echo "  NG - スクリプトの実行形注記を1件も抽出できず判定不能（検出器が壊れている可能性）"
elif [ -n "$exec_note_violations" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("スクリプトの実行形注記に欠落節または禁止語がある")
  echo "  NG - スクリプトの実行形注記に欠落節または禁止語がある"
  print_indented "$exec_note_violations"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - スクリプトの実行形注記（${exec_note_checked} 箇所・正本テンプレート含む）は不変コアを備え、反転語も無い"
fi

echo ""
echo "=== (x) 参照ファイル読み出し注記の配送経路チェック ==="

# references/ templates/ はプラグイン配下＝作業ディレクトリ外にあり、Read ツールでの
# 読み出しは利用側の allow が無ければ拒否される。headless 委譲には許可する相手がいないため
# 拒否がそのまま確定するが、**モデルは読めないまま手順を推測して完走できてしまう**
# （実測: /guarantee-audit bootstrap が references/bootstrap-mode.md を読めないまま完走し、
#  検証器の exit 2 で初めて発覚した）。
# さらに、配送できても**出力上限で本文が途中で切れる**経路がある（exit 0 のまま部分配送）。
# そこで注記には (1) 配送経路 (2) 非0 での停止規則 (3) 終端マーカーによる切り詰め検査 を
# 揃って持たせ、いずれかが落ちたら検出する。

# shellcheck disable=SC2016
run_ref_note_selfcheck() {
  local complete='参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。読み出しは `claude-harness-run read-plugin-doc "skills/x/references/y.md"` で行う。**非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること。**exit 0 でも終端マーカー `=== read-plugin-doc END ... complete ===` が無ければ本文は完結していない**。**BEGIN マーカーの `root=` が「Base directory for this skill」の親ツリー（`<root>/skills/<スキル名>` が Base directory）と一致しなければ、別バージョンの本文が届いている** — ランチャーは同居する最大バージョンを選ぶため旧版 SKILL.md ＋ 新版参照ファイルの混成になりうるので、手順へ進まず同様に停止して報告すること。`claude-harness-run: command not found` の場合のみ Read へフォールバックし、「Base directory for this skill」を起点に解決する。'

  assert_note '完全な読み出し注記では問題を報告しない' '' ref "$complete"

  assert_note '配送経路が欠けた注記（Read 一本の旧形）を検出する' \
    '欠落節 read-plugin-doc,read-plugin-doc END' ref "${complete//read-plugin-doc/cat}"

  # 停止規則の節だけを落とした形。`**` はパラメータ展開のパターンではグロブとして
  # 解釈されるため、置換ではなくリテラルを別に書く。
  local no_halt_rule='参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。読み出しは `claude-harness-run read-plugin-doc "skills/x/references/y.md"` で行う。**exit 0 でも終端マーカー `=== read-plugin-doc END ... complete ===` が無ければ本文は完結していない**。**BEGIN マーカーの `root=` が「Base directory for this skill」の親ツリー（`<root>/skills/<スキル名>` が Base directory）と一致しなければ、別バージョンの本文が届いている** — ランチャーは同居する最大バージョンを選ぶため旧版 SKILL.md ＋ 新版参照ファイルの混成になりうるので、手順へ進まず同様に停止して報告すること。`claude-harness-run: command not found` の場合のみ Read へフォールバックし、「Base directory for this skill」を起点に解決する。'
  assert_note '失敗時の停止規則が欠けた注記を検出する' \
    '欠落節 **非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること' \
    ref "$no_halt_rule"

  # 終端マーカーの節だけを落とした形（切り詰めの検査手段が無くなる）。
  local no_end_marker='参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。読み出しは `claude-harness-run read-plugin-doc "skills/x/references/y.md"` で行う。**非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること。**BEGIN マーカーの `root=` が「Base directory for this skill」の親ツリー（`<root>/skills/<スキル名>` が Base directory）と一致しなければ、別バージョンの本文が届いている** — ランチャーは同居する最大バージョンを選ぶため旧版 SKILL.md ＋ 新版参照ファイルの混成になりうるので、手順へ進まず同様に停止して報告すること。`claude-harness-run: command not found` の場合のみ Read へフォールバックし、「Base directory for this skill」を起点に解決する。'
  assert_note '終端マーカーによる切り詰め検査が欠けた注記を検出する' \
    '欠落節 read-plugin-doc END' ref "$no_end_marker"

  # 配送元の同一性（root 照合）の節だけを落とした形。完了マーカーの検査は残るため、
  # **完結しているが別バージョン**の本文が黙って通る（codex が PR #190 で挙げた P1 の形）。
  local no_root_check='参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。読み出しは `claude-harness-run read-plugin-doc "skills/x/references/y.md"` で行う。**非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること。**exit 0 でも終端マーカー `=== read-plugin-doc END ... complete ===` が無ければ本文は完結していない**。`claude-harness-run: command not found` の場合のみ Read へフォールバックし、「Base directory for this skill」を起点に解決する。'
  assert_note '配送元の同一性（root 照合）の停止条件が欠けた注記を検出する' \
    '欠落節 **BEGIN マーカーの `root=` が「Base directory for this skill」の親ツリー（`<root>/skills/<スキル名>` が Base directory）と一致しなければ、別バージョンの本文が届いている** — ランチャーは同居する最大バージョンを選ぶため旧版 SKILL.md ＋ 新版参照ファイルの混成になりうるので、手順へ進まず同様に停止して報告すること。' \
    ref "$no_root_check"

  # **意味の反転**: 必須節をすべて残したまま「停止は不要・続行してよい」を足した形。
  # 断片の部分一致だけを見る検査ではこれが通ってしまうため、否定側と対で見る。
  assert_note '停止規則を反転させた注記を検出する' '禁止語 続行してよい,停止は不要' \
    ref "${complete}ただし本文が得られなくても停止は不要であり、手順を推測して続行してよい。"
}
run_ref_note_selfcheck

# --- (x-b) 実ファイルの走査 ---
ref_note_violations=""
ref_note_checked=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"
    text="${hit#*:}"
    ref_note_checked=$((ref_note_checked + 1))
    while IFS= read -r problem; do
      [ -z "$problem" ] && continue
      ref_note_violations="${ref_note_violations}${f}:${lineno}: ${problem}
"
    done <<<"$(inspect_note "$text" ref)"
  done <<<"$(grep -nF "$REF_NOTE_MARKER" "$f")"
done <<<"$(grep -rlF "$REF_NOTE_MARKER" "${NOTE_SCAN_PATHS[@]}" --include='*.md')"

if [ "$ref_note_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("参照ファイル読み出し注記を1件も抽出できず判定不能")
  echo "  NG - 参照ファイル読み出し注記を1件も抽出できず判定不能（検出器が壊れている可能性）"
elif [ -n "$ref_note_violations" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("参照ファイル読み出し注記に欠落節または禁止語がある")
  echo "  NG - 参照ファイル読み出し注記に欠落節または禁止語がある"
  print_indented "$ref_note_violations"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 参照ファイル読み出し注記（${ref_note_checked} 箇所・正本テンプレート含む）は配送経路・停止規則・切り詰め検査・配送元の同一性を備える"
fi

# --- (x-c) 注記の存在は「全称条件」で見る ---
# ここまでの検査は「注記が在るなら中身を見る」という存在条件であり、**注記を1つも
# 置いていないスキルは素通りする**。references/ templates/ を持つのに読み出し注記が
# 無いスキルは、Read 直読み指示だけを持ったまま headless で沈黙して失敗する。
# 新規スキルに対して規約が強制力を持つよう、owner スキル側から全称で確かめる。
missing_note_skills=""
owner_skills_checked=0
while IFS= read -r skill_dir; do
  [ -z "$skill_dir" ] && continue
  skill="$(basename "$skill_dir")"
  if [ ! -d "${skill_dir}/references" ] && [ ! -d "${skill_dir}/templates" ]; then
    continue
  fi
  owner_skills_checked=$((owner_skills_checked + 1))
  if [ ! -f "${skill_dir}/SKILL.md" ]; then
    missing_note_skills="${missing_note_skills}${skill}: SKILL.md が無い
"
    continue
  fi
  if ! grep -qF "$REF_NOTE_MARKER" "${skill_dir}/SKILL.md"; then
    missing_note_skills="${missing_note_skills}${skill_dir}/SKILL.md: references/ templates/ を持つのに読み出し注記が無い
"
  fi
done <<<"$(find skills -mindepth 1 -maxdepth 1 -type d | sort)"

if [ "$owner_skills_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("references/ templates/ を持つスキルを1件も列挙できず判定不能")
  echo "  NG - references/ templates/ を持つスキルを1件も列挙できず判定不能（検出器が壊れている可能性）"
elif [ -n "$missing_note_skills" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("読み出し注記を持たないスキルがある")
  echo "  NG - references/ templates/ を持つのに読み出し注記が無いスキルがある"
  print_indented "$missing_note_skills"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - references/ templates/ を持つスキル（${owner_skills_checked} 件）はすべて読み出し注記を持つ"
fi

# --- (x-d) 注記が参照ファイルを1本に決め打ちしていないか ---
# モード別スキル（`/create-adr` の記録／昇格判定、`/guarantee-audit` の bootstrap／drift、
# `/create-ticket` の要件／実装分解）では、読み出す参照ファイルが選んだモードで変わる。
# 注記が**最初のモードのファイルを固定的に名指し**していると、別モードを選んだ利用者は
# 違う手順書を配送されるか、拒否される Read 経路へ落ちる。**注記と本文の表という2つの規則が
# 同じものについて食い違う**状態であり、実際に3スキルでこの形になっていた。
#
# 判定: 注記が具体的なファイル名を挙げているのに、同じ SKILL.md が挙げている他の参照ファイルを
# どの注記もカバーしていなければ違反。プレースホルダ（具体名を挙げない）にするか、
# ファイルごとに注記を置けば通る。

# stdin: SKILL.md の内容。stdout: 注記が名指ししているのにカバーしていない参照ファイル。
# 注記が具体名を1つも挙げていない（プレースホルダ）場合は何も出さない。
uncovered_note_targets() {
  local line named="" cited="" tok
  while IFS= read -r line; do
    case "$line" in
      *"$REF_NOTE_MARKER"*)
        while IFS= read -r tok; do
          [ -z "$tok" ] && continue
          named="${named}${tok}
"
        done <<<"$(printf '%s' "$line" | grep -oE '(references|templates)/[A-Za-z0-9_.-]+')"
        ;;
      *)
        while IFS= read -r tok; do
          [ -z "$tok" ] && continue
          cited="${cited}${tok}
"
        done <<<"$(printf '%s' "$line" | grep -oE '(references|templates)/[A-Za-z0-9_.-]+')"
        ;;
    esac
  done
  # 注記が具体名を挙げていなければ決め打ちしていない＝検査対象外
  [ -z "$named" ] && return 0
  printf '%s' "$cited" | sort -u | while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    printf '%s' "$named" | grep -Fxq "$tok" || printf '%s\n' "$tok"
  done
}

assert_uncovered() {
  local description="$1" expected="$2" sample="$3"
  local actual
  actual="$(printf '%s\n' "$sample" | uncovered_note_targets | tr '\n' ',' | sed 's/,$//')"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("注記の決め打ち検出器の自己検査: ${description}")
    echo "  NG - ${description}（expected='${expected}' actual='${actual}'）"
  fi
}

assert_uncovered '違反: 注記が第1モードのファイルを決め打ちしている' 'references/promote-mode.md' \
'> 参照ファイルは導入先プロジェクトではなく…`references/record-mode.md`…
| 記録モード | `skills/create-adr/references/record-mode.md` |
| 昇格判定モード | `skills/create-adr/references/promote-mode.md` |'

assert_uncovered '正当: 注記がプレースホルダなら決め打ちしていない' '' \
'> 参照ファイルは導入先プロジェクトではなく…`<読む対象のプラグインルート相対パス>`…
| 記録モード | `skills/create-adr/references/record-mode.md` |
| 昇格判定モード | `skills/create-adr/references/promote-mode.md` |'

assert_uncovered '正当: 参照ファイルが1本だけなら名指しでよい' '' \
'> 参照ファイルは導入先プロジェクトではなく…`references/conflict-resolution.md`…
手順は `skills/pr-merge/references/conflict-resolution.md` を読む。'

assert_uncovered '正当: ファイルごとに注記があれば全部カバーされる' '' \
'> 参照ファイルは導入先プロジェクトではなく…`templates/detection-report.md`…
提示テンプレートは `templates/detection-report.md`。
> 参照ファイルは導入先プロジェクトではなく…`templates/CLAUDE.md.template`…
雛形は `templates/CLAUDE.md.template`。'

assert_uncovered '違反: 複数の未カバーをすべて報告する' 'references/join-gate.md,references/star-parallel.md' \
'> 参照ファイルは導入先プロジェクトではなく…`references/impl-flow.md`…
`skills/para-impl/references/impl-flow.md` を読む。
`skills/para-impl/references/star-parallel.md` を読む。
`skills/para-impl/references/join-gate.md` を読む。'

hardcoded_notes=""
hardcoded_checked=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  grep -qF "$REF_NOTE_MARKER" "$f" || continue
  hardcoded_checked=$((hardcoded_checked + 1))
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    hardcoded_notes="${hardcoded_notes}${f}: 注記が参照ファイルを決め打ちしており ${tok} がどの注記にも現れない
"
  done <<<"$(uncovered_note_targets <"$f")"
done <<<"$(find skills -mindepth 2 -maxdepth 2 -name 'SKILL.md' | sort)"

if [ "$hardcoded_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("読み出し注記を持つ SKILL.md を1件も列挙できず判定不能")
  echo "  NG - 読み出し注記を持つ SKILL.md を1件も列挙できず判定不能（検出器が壊れている可能性）"
elif [ -n "$hardcoded_notes" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("注記が参照ファイルを1本に決め打ちしている")
  echo "  NG - 注記が参照ファイルを1本に決め打ちしており、他の参照ファイルを取りこぼす"
  print_indented "$hardcoded_notes"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 注記（${hardcoded_checked} スキル）は参照ファイルを決め打ちしていない"
fi

# --- (x-e) para-impl のゲート参照が配送経路を第一手にしているか ---
# 注記（(x-b)〜(x-d)）が配送経路を規定していても、**本文中の個々の読み出し指示が
# `Read し` のままだと注記と本文で規則が二重化し、実際に届くのは Read 経路になる**
# （PR #184 で codex が指摘した形）。para-impl の3つの参照ファイルは
# **ゲートの手順書**であり、読めなければゲートそのものが無効化される:
#   - references/join-gate.md      … 合流ゲート（サブエージェント起動前に必読と指定されている）
#   - references/star-parallel.md  … star 型並列実装の手順
# star-parallel.md は 19KB 超で、Read が通っても出力上限の切り詰め域にある
# （配送経路なら `--from-line` で分割配送される）。
# 検査対象を para-impl の2本に限定するのは、他スキルの残存が別種の性質（表の中のパス表記・
# 条件付き参照・スクリプト実行の記述）を持ち、一律の判定に載せると PR #176 型の
# 「掃引の横展開が範囲外を壊す」回帰を作るため。移行が進んだ分だけここへ足す。

PARA_IMPL_GATE_REFS=(
  references/join-gate.md
  references/star-parallel.md
)

# stdin: SKILL.md の内容。$1: 検査対象の参照ファイルトークン（例 references/join-gate.md）。
# stdout: 違反を1行1件で返す。違反が無ければ何も出さない。
# 判定は2つ:
#   (1) その参照ファイルを配送経路（read-plugin-doc + プラグインルート相対の実パス）で
#       読み出す指示が最低1つ在ること。
#   (2) その参照ファイルに言及しつつ Read を命じる行は、フォールバックである旨を
#       同じ行に明示していること（第一手の Read 直読みを禁じる）。
# 単なる相互参照（`… の「ネストへの伝播」に定義` 等、Read を命じない行）は (2) の対象外。
# 定型注記そのものはプレースホルダで書かれるため走査から外す（(x-b)〜(x-d) の担当）。
gate_delivery_violations() {
  local token="$1" line lineno=0 seen=0 delivered=0
  local delivery="read-plugin-doc \"skills/para-impl/${token}\""
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    case "$line" in
      *"$REF_NOTE_MARKER"*) continue ;;
      *"$token"*) ;;
      *) continue ;;
    esac
    seen=$((seen + 1))
    case "$line" in *"$delivery"*) delivered=1 ;; esac
    case "$line" in
      *Read*)
        case "$line" in
          *フォールバック*) ;;
          *) printf '%s\n' "${lineno}: ${token} を Read 直読みで命じている（配送経路が第一手になっていない）" ;;
        esac
        ;;
    esac
  done
  if [ "$seen" -eq 0 ]; then
    printf '%s\n' "0: ${token} への言及が1件も無い（検査対象が消えた可能性）"
  elif [ "$delivered" -eq 0 ]; then
    printf '%s\n' "0: ${token} を配送経路 ${delivery} で読み出す指示が無い"
  fi
}

assert_gate_delivery() {
  local description="$1" token="$2" expected="$3" sample="$4"
  local actual
  actual="$(printf '%s\n' "$sample" | gate_delivery_violations "$token" | tr '\n' ',' | sed 's/,$//')"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("ゲート参照の配送経路検出器の自己検査: ${description}")
    echo "  NG - ${description}（expected='${expected}' actual='${actual}'）"
  fi
}

# shellcheck disable=SC2016
run_gate_delivery_selfcheck() {
  assert_gate_delivery '正当: 配送経路が第一手でフォールバックを明示している' \
    'references/join-gate.md' '' \
'**起動する前に必ず前掲の配送経路で読み出すこと**（`claude-harness-run read-plugin-doc "skills/para-impl/references/join-gate.md"`。Read 直読みは前掲の注記のとおりランチャー未導入時のフォールバックに限る）。'

  assert_gate_delivery '違反: Read 直読みを第一手として命じている（移行前の形）' \
    'references/join-gate.md' \
    '1: references/join-gate.md を Read 直読みで命じている（配送経路が第一手になっていない）,0: references/join-gate.md を配送経路 read-plugin-doc "skills/para-impl/references/join-gate.md" で読み出す指示が無い' \
'**起動する前に必ず `${CLAUDE_PLUGIN_ROOT}/skills/para-impl/references/join-gate.md` を Read すること**（`<base>/references/join-gate.md` として解決する）。'

  assert_gate_delivery '違反: 配送経路の行はあるが別の行が Read 直読みを命じている' \
    'references/join-gate.md' \
    '2: references/join-gate.md を Read 直読みで命じている（配送経路が第一手になっていない）' \
'`claude-harness-run read-plugin-doc "skills/para-impl/references/join-gate.md"` で読み出す。
なお `<base>/references/join-gate.md` を Read しても良い。'

  assert_gate_delivery '違反: 配送経路の指示が無い（言及だけ）' \
    'references/join-gate.md' \
    '0: references/join-gate.md を配送経路 read-plugin-doc "skills/para-impl/references/join-gate.md" で読み出す指示が無い' \
'合流ゲートの定義は `references/join-gate.md` にある。'

  assert_gate_delivery '正当: Read を命じない相互参照は違反にしない' \
    'references/join-gate.md' '' \
'`claude-harness-run read-plugin-doc "skills/para-impl/references/join-gate.md"` で読み出す。
委譲プロンプトには合流ゲート伝播条項（`references/join-gate.md` の「ネストへの伝播」に定義）を含める。'

  assert_gate_delivery '違反: 配送経路のパスが別スキルを指していて実質未配送' \
    'references/join-gate.md' \
    '0: references/join-gate.md を配送経路 read-plugin-doc "skills/para-impl/references/join-gate.md" で読み出す指示が無い' \
'`claude-harness-run read-plugin-doc "skills/promote-verify/references/join-gate.md"` で読み出す。'

  assert_gate_delivery '違反: 参照そのものが消えた場合も判定不能として報告する' \
    'references/join-gate.md' \
    '0: references/join-gate.md への言及が1件も無い（検査対象が消えた可能性）' \
'ここには合流ゲートの参照が無い。'

  # 定型注記はプレースホルダで書かれ、走査から外れることを確認する
  # （注記の中身は (x-b)〜(x-d) の担当。ここで二重に見ると規則が二重化する）。
  assert_gate_delivery '正当: 定型注記の行は走査対象から外れる' \
    'references/join-gate.md' '' \
"> **参照ファイルの読み出し（重要）**: ${REF_NOTE_MARKER}**プラグイン配下**にある。Read ツールでの読み出しは拒否される。references/join-gate.md
\`claude-harness-run read-plugin-doc \"skills/para-impl/references/join-gate.md\"\` で読み出す。"
}
run_gate_delivery_selfcheck

# --- (x-e-2) 実ファイルの走査 ---
gate_delivery_report=""
gate_refs_checked=0
PARA_IMPL_SKILL="skills/para-impl/SKILL.md"
if [ ! -f "$PARA_IMPL_SKILL" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("${PARA_IMPL_SKILL} が無く判定不能")
  echo "  NG - ${PARA_IMPL_SKILL} が無く判定不能"
else
  for token in "${PARA_IMPL_GATE_REFS[@]}"; do
    # 参照ファイルの実体が在ることも同時に確かめる（(xi) と重複するが、
    # ここは「ゲートが届くか」の検査なので実体消失も判定不能として扱う）
    if [ ! -f "skills/para-impl/${token}" ]; then
      gate_delivery_report="${gate_delivery_report}skills/para-impl/${token}: 参照ファイルの実体が無い
"
      continue
    fi
    gate_refs_checked=$((gate_refs_checked + 1))
    while IFS= read -r problem; do
      [ -z "$problem" ] && continue
      gate_delivery_report="${gate_delivery_report}${PARA_IMPL_SKILL}:${problem}
"
    done <<<"$(gate_delivery_violations "$token" <"$PARA_IMPL_SKILL")"
  done

  if [ "$gate_refs_checked" -ne "${#PARA_IMPL_GATE_REFS[@]}" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("para-impl のゲート参照を全数走査できず判定不能")
    echo "  NG - para-impl のゲート参照を全数走査できず判定不能（${gate_refs_checked}/${#PARA_IMPL_GATE_REFS[@]} 件）"
    print_indented "$gate_delivery_report"
  elif [ -n "$gate_delivery_report" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("para-impl のゲート参照が配送経路で読み出されていない")
    echo "  NG - para-impl のゲート参照が配送経路で読み出されていない（読めなければゲートが無効化される）"
    print_indented "$gate_delivery_report"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - para-impl のゲート参照（${gate_refs_checked} 本）は配送経路を第一手にしており、Read はフォールバック明示に限る"
  fi
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
    'skills/create-ticket/references/requirement-mode.md' \
    '正本は `<base>/../create-ticket/references/requirement-mode.md`'
  assert_resolves 'エージェント側の <...base>/../<skill>/ も解決する' '' \
    'skills/create-ticket/references/requirement-mode.md' \
    '`<tdd-implのbase>/../create-ticket/references/requirement-mode.md` で解決して Read する'
  assert_resolves 'プラグインルート相対のフルパスをそのまま扱う' 'guarantee-audit' \
    'skills/guarantee-audit/references/bootstrap-mode.md' \
    'read-plugin-doc "skills/guarantee-audit/references/bootstrap-mode.md"'
  assert_resolves '裸の templates/ も owner で解決する' 'init-project' \
    'skills/init-project/templates/detection-report.md' '`templates/detection-report.md` を Read し'
  assert_resolves 'owner の無いファイルからの裸の参照は解決不能として報告する' '' \
    'UNRESOLVED references/nonexistent-ref.md' '正本は `references/nonexistent-ref.md`'
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
# 照合は **owner を含むフルパスへ解決した結果**（(xi-a) の resolve_ref_tokens の出力）で行う。
# `references/<basename>` の素朴な照合だと (a) 別スキルが同名ファイルを参照しているだけで
# 「参照済み」に見え、(b) 参照ファイルが本文中に自分の名前を書いていれば自分で自分を
# 証明してしまう（grep の探索対象に自分自身が入るため）。どちらも空虚に真になる。
cited_targets=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    skills/*) owner="$(printf '%s' "$f" | cut -d/ -f2)" ;;
    *) owner="" ;;
  esac
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    case "$target" in "UNRESOLVED "*) continue ;; esac
    # 自己言及を証明に使わない: 参照元と参照先が同一ファイルなら cite として数えない
    [ "$target" = "$f" ] && continue
    cited_targets="${cited_targets}${target}
"
  done <<<"$(resolve_ref_tokens "$(cat "$f")" "$owner")"
done <<<"$(find skills agents -name '*.md' | sort)"

ref_orphans=""
ref_files_checked=0
while IFS= read -r target; do
  [ -z "$target" ] && continue
  [ -f "$target" ] || continue
  ref_files_checked=$((ref_files_checked + 1))
  if ! printf '%s' "$cited_targets" | grep -Fxq "$target"; then
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
echo "=== (xii) 正本コメントの隣接重複チェック ==="

# 定型注記の末尾に置く開発者向けの出典コメント（`<!-- 正本: ... -->`）が、
# **直前の行と同一のまま2行並んでいないこと**。
# 同一ファイル内に複数の正本コメントが在ること自体は正常（注記ブロックごとに1つ）で、
# 違反は「隣り合って同じ行が並ぶ」場合だけ。
#
# なぜ要るか: 注記本体だけを差し替える一括置換は、置換テンプレート側にも正本コメントを
# 含めていると**既存のコメント行を残したまま**もう1行足してしまう。実際に本 PR の移行で
# 10箇所中9箇所に重複を作った（注記本体1行を「新しい注記＋新しいコメント」の2行へ
# 置換した結果、直後にあった既存のコメント行が残った）。
# 見た目の些細な崩れだが、同じ掃引が同じ重複を再び作れる状態を残さないために機械で止める。
#
# 比較は bash の文字列比較（バイト厳密）で行う。macOS 標準 awk の `==` は非 ASCII 文字列で
# 誤判定しうるため使わない（scripts/README.md「テスト」節）。正本コメントは「正本」という
# 非 ASCII を含むので、この点は本検査に直接効く。

# stdin: ファイルの内容。stdout: 隣接重複を「<前の行番号>-<行番号>」の形で1行1件。
# 空行は読み飛ばす（間に空行が挟まっていても同一コメントの重複であることに変わりはない）。
find_adjacent_dup_source_comments() {
  local raw line prev="" lineno=0 prev_lineno=0
  while IFS= read -r raw; do
    lineno=$((lineno + 1))
    # 前後の空白と Markdown の引用記号 `> ` を剥がしてから比較する。
    # 注記は `>` 引用ブロックや箇条書きの中に置かれるため、行頭固定で見ると
    # インデントされた重複（`  <!-- 正本: ... -->` の2連）を見逃す。
    line="$raw"
    while :; do
      case "$line" in
        ' '*) line="${line# }" ;;
        "$(printf '\t')"*) line="${line#"$(printf '\t')"}" ;;
        '> ') line="" ;;
        '>'*) line="${line#>}" ;;
        *) break ;;
      esac
    done
    line="${line%"${line##*[! ]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      '<!-- 正本: '*' -->')
        if [ "$line" = "$prev" ]; then
          printf '%s-%s\n' "$prev_lineno" "$lineno"
        fi
        ;;
    esac
    prev="$line"
    prev_lineno="$lineno"
  done
}

# --- (xii-a) 検出器自体の自己検査 ---
# 検出できることだけでなく、**正常形を違反と誤検出しないこと**（同一ファイル内の
# 非連続な正本コメントは正常）も確認する。誤検出する検出器は、正しい記述を壊す方向の
# 是正を誘発するため、見逃しと同じくらい危険。
assert_dup_detection() {
  local description="$1" expected="$2" sample="$3"
  local actual
  actual="$(printf '%s\n' "$sample" | find_adjacent_dup_source_comments | tr '\n' ',' | sed 's/,$//')"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("正本コメント重複検出器の自己検査: ${description}")
    echo "  NG - ${description}（expected='${expected}' actual='${actual}'）"
  fi
}

assert_dup_detection '違反: 同一の正本コメントが連続している' '2-3' \
'> **注記**: 本文
<!-- 正本: docs/plugin-path-conventions.md -->
<!-- 正本: docs/plugin-path-conventions.md -->'

assert_dup_detection '違反: 空行を挟んだ同一の正本コメントも検出する' '2-4' \
'> **注記**: 本文
<!-- 正本: docs/plugin-path-conventions.md -->

<!-- 正本: docs/plugin-path-conventions.md -->'

assert_dup_detection '正当: 同一ファイル内の非連続な正本コメントは検出しない' '' \
'> **注記1**: 本文
<!-- 正本: docs/plugin-path-conventions.md -->

## 別の見出し

> **注記2**: 本文
<!-- 正本: docs/plugin-path-conventions.md -->'

assert_dup_detection '正当: 正本が異なるコメントの連続は検出しない' '' \
'<!-- 正本: docs/plugin-path-conventions.md -->
<!-- 正本: docs/script-launcher.md -->'

assert_dup_detection '正当: 正本コメント以外の同一行の連続は対象外' '' \
'同じ本文行
同じ本文行'

assert_dup_detection '正当: 正本コメントが1つだけなら検出しない' '' \
'> **注記**: 本文
<!-- 正本: docs/plugin-path-conventions.md -->'

# 注記は `>` 引用ブロックや箇条書きの中に置かれるため、行頭固定で見ると
# インデント／引用記号つきの重複を見逃す。剥がしてから比較していることを確認する。
assert_dup_detection '違反: インデントされた同一コメントの重複も検出する' '2-3' \
'> **注記**: 本文
  <!-- 正本: docs/plugin-path-conventions.md -->
  <!-- 正本: docs/plugin-path-conventions.md -->'

assert_dup_detection '違反: 引用記号つきの同一コメントの重複も検出する' '2-3' \
'> **注記**: 本文
> <!-- 正本: docs/plugin-path-conventions.md -->
> <!-- 正本: docs/plugin-path-conventions.md -->'

assert_dup_detection '違反: インデントの有無が違っても同一コメントなら検出する' '2-3' \
'> **注記**: 本文
<!-- 正本: docs/plugin-path-conventions.md -->
    <!-- 正本: docs/plugin-path-conventions.md -->'

# --- (xii-b) 実ファイルの走査 ---
dup_source_violations=""
dup_files_checked=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  dup_files_checked=$((dup_files_checked + 1))
  dups="$(find_adjacent_dup_source_comments <"$f")"
  if [ -n "$dups" ]; then
    while IFS= read -r range; do
      [ -z "$range" ] && continue
      dup_source_violations="${dup_source_violations}${f}:${range}: 正本コメントが隣接重複している
"
    done <<<"$dups"
  fi
done <<<"$(find skills agents -name '*.md' | sort)"

if [ "$dup_files_checked" -eq 0 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("正本コメント重複チェックの対象ファイルを1件も列挙できず判定不能")
  echo "  NG - 対象ファイルを1件も列挙できず判定不能（検出器が壊れている可能性）"
elif [ -n "$dup_source_violations" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("正本コメントが隣接重複している")
  echo "  NG - 正本コメントが隣接重複している"
  print_indented "$dup_source_violations"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 正本コメントの隣接重複は無い（${dup_files_checked} ファイル走査）"
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
