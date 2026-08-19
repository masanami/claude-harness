#!/bin/bash
# test-para-impl-join-gate.sh
# para-impl の「合流ゲート（最終応答前の未合流確認）」（Issue #167）の回帰テスト。
#
# 背景: headless（`claude -p`）では最終応答の確定と同時にプロセス群ごと終了するため、
# 未合流のサブエージェントを残したままリードがテキスト応答を確定すると、起動済み
# エージェントが道連れで強制終了され未コミット差分だけが残る（recurrence 3 の実測）。
# 呼び出し側ブリーフの禁止文言では防げないことが実測済みのため、skill 本体に
# 合流ゲート（起動台帳・ターン維持・最終応答前の決定表・中断報告の出力契約）を置いた。
#
# ゲートは散文の手順としてスキルに実装されている（コード側の強制ではない）ため、
# 本テストは test-create-ticket-gdd-gate.sh (B) と同じ方式で固定する:
#   - 正準文（固定文字列）の逐語存在検査（手順のドリフト・緩和の機械検出）
#   - 構造不変条件: ゲート定義が SKILL.md にちょうど1箇所であり参照ファイルが
#     独自定義を持たないこと（同じ規律を2つの正本で読まない）・決定表の状態空間の
#     完全性（行の列挙とリテラル件数一致）・下流（Phase 10 / star 型の返却処理表）への
#     接続検査（未合流状態が判定経路に接続されていること）
#   - 決定表の参照実装による真理値表（空集合＝起動0件を正常経路とするケースを必須で含む。
#     検査不能（台帳突き合わせ不能）を0件に丸めないこと・部分合流を全合流と
#     みなさないことを実行可能な形で固定する）
#
# 実行方法: bash scripts/tests/test-para-impl-join-gate.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # 正準文内のバッククォートは Markdown のリテラル
# （スキル本文の逐語検査対象）であり、シェル展開を意図していない
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SKILL_FILE="${REPO_ROOT}/skills/para-impl/SKILL.md"
STAR_FILE="${REPO_ROOT}/skills/para-impl/references/star-parallel.md"

for f in "$SKILL_FILE" "$STAR_FILE"; do
  if [ ! -r "$f" ]; then
    echo "NG - 検査対象ファイルを読めません（検査不能を pass にはしない）: ${f}" >&2
    exit 1
  fi
done

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

# 指定ファイルに正準文（固定文字列）が逐語で存在することを検査する。
assert_file_contains() {
  local description="$1" file="$2" phrase="$3"
  if grep -qF -- "$phrase" "$file"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${file}"
    echo "       phrase: ${phrase}"
  fi
}

assert_file_not_contains() {
  local description="$1" file="$2" phrase="$3"
  if grep -qF -- "$phrase" "$file"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${file}"
    echo "       phrase: ${phrase}"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  fi
}

assert_skill_contains() { assert_file_contains "$1" "$SKILL_FILE" "$2"; }
assert_star_contains() { assert_file_contains "$1" "$STAR_FILE" "$2"; }

GATE_TITLE='合流ゲート（最終応答前の未合流確認）'
GATE_HEADING="## ${GATE_TITLE}"

echo "=== (1) ゲート定義の所在と一意性（同じ規律を2つの正本で読まない） ==="

skill_heading_count="$(grep -cF -- "$GATE_HEADING" "$SKILL_FILE")"
assert_eq "(1) SKILL.md にゲート見出しがちょうど1箇所ある" "1" "$skill_heading_count"

# star 側は見出しではなくタイトル（「…」（SKILL.md）の形）で参照する
star_title_count="$(grep -cF -- "$GATE_TITLE" "$STAR_FILE" || true)"
# star 側の出現はすべて参照（「…」（SKILL.md）の形）であり、見出し（行頭 ##）としては現れない
star_own_heading="$(grep -cE '^##[[:space:]]+合流ゲート' "$STAR_FILE" || true)"
assert_eq "(1) star-parallel.md はゲートを見出しとして定義しない（参照のみ）" "0" "$star_own_heading"
assert_file_not_contains "(1) star-parallel.md はゲートの決定表手順を複製しない" "$STAR_FILE" \
  '### 手順（最終応答の直前）'
assert_skill_contains "(1) SKILL.md が定義の正本であることを明示している" \
  '本ゲートの定義の正本はこのセクションである'
if [ "$star_title_count" -lt 1 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("(1) star-parallel.md がゲートを正式名称で参照している")
  echo "  NG - (1) star-parallel.md がゲートを正式名称で参照している（0箇所）"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - (1) star-parallel.md がゲートを正式名称で参照している（${star_title_count}箇所）"
fi

# 見出し改名時に参照側の更新漏れを検出する（SKILL.md の実見出し文字列で star 側を引く）
actual_heading="$(grep -E '^##[[:space:]]+合流ゲート' "$SKILL_FILE" | head -1 | sed -E 's/^##[[:space:]]+//')"
assert_file_contains "(1) star-parallel.md の参照名が SKILL.md の実見出しと一致する" "$STAR_FILE" \
  "$actual_heading"

echo ""
echo "=== (2) 適用条件と headless の根拠（分岐の明示・モード検出に依存しない） ==="

assert_skill_contains "(2) 最終応答前の通過を必須にしている（完了報告・中断報告を含む）" \
  '最終応答（Phase 10 の完了報告・中断報告を含む、あらゆるテキスト応答の確定）の前に本ゲートを必ず通過する'
assert_skill_contains "(2) headless では最終応答の確定＝プロセス群の終了と明示している" \
  'headless（`claude -p`）では最終応答の確定と同時にプロセス群ごと終了し'
assert_skill_contains "(2) 挙動差が headless でのみ顕在化することを明示している" \
  'この差は headless でのみ顕在化する'
assert_skill_contains "(2) ゲートはモード検出に依存せず常時適用する" \
  '本ゲートは実行モードの検出に依存せず常に適用する'
assert_skill_contains "(2) モード判定を独自に行わないことを明示している" \
  'headless か対話かの判定を独自に行わない'

echo ""
echo "=== (3) spawn 時手順（ターン維持を注意書きでなく手順として置く） ==="

assert_skill_contains "(3) 起動のたびに起動台帳へ追記する" \
  'その場で起動台帳に追記する'
assert_skill_contains "(3) 起動直後にテキストで応答を確定しない" \
  '**起動直後にテキストで応答を確定しない**'
assert_skill_contains "(3) 待機宣言を手順違反として扱う（注意書きに格下げしない）" \
  '待機宣言は注意書きではなく**手順違反**として扱う'
assert_skill_contains "(3) 合流までツール呼び出しでターンを維持する" \
  'ツール呼び出しを続けてターンを維持する'
assert_skill_contains "(3) ターン維持の具体手段（ブロッキング待機・ポーリング）を示している" \
  '結果取得ツールでのブロッキング待機、または状態確認のポーリングを合流まで繰り返す'
assert_skill_contains "(3) 「起動に成功した」を合流とみなさない（用語の定義）" \
  '「起動に成功した」「完了通知が来るはず」は合流ではない'
assert_skill_contains "(3) 合流済みの定義は最終返却の受領である" \
  '最終返却（結果）をこのセッションで受領した'

echo ""
echo "=== (4) 決定表の状態空間（行の列挙・リテラル件数一致） ==="

# 決定表の第1列（状態）を抽出する。ヘッダ行・区切り行は除く。
gate_states="$(awk '/^### 手順（最終応答の直前）/{f=1; next} /^### /{f=0} f && /^\|/{print}' "$SKILL_FILE" \
  | grep -vE '^\|[[:space:]]*(状態|-+)[[:space:]]*\|' \
  | sed -E 's/^\|[[:space:]]*//; s/[[:space:]]*\|.*$//')"
expected_states='起動台帳が空（1つも起動していない）
未合流 0件（起動したものはすべて合流済み）
未合流 1件以上
合流を試みても受領できない（結果取得の失敗・再試行上限到達）
起動台帳と実状態を突き合わせられない（台帳の欠落・コンテキスト要約による消失・台帳に載っていない合流記録がある〔合流済み件数が起動台帳件数を上回る〕等）'
assert_eq "(4) 決定表の状態が5件・期待の列挙と完全一致する（増減・改変で落ちる）" \
  "$expected_states" "$gate_states"

# 状態→動作の対応（行単位の逐語検査）
assert_skill_contains "(4) 起動0件（空集合）はゲート通過の正常経路である" \
  '| 起動台帳が空（1つも起動していない） | ゲート通過。そのまま最終応答へ |'
assert_skill_contains "(4) 未合流0件はゲート通過の正常経路である" \
  '| 未合流 0件（起動したものはすべて合流済み） | ゲート通過。そのまま最終応答へ |'
assert_skill_contains "(4) 未合流1件以上は応答を確定せず合流を続け、合流後にゲートを再実行する" \
  '| 未合流 1件以上 | 最終応答を確定せず、ツール呼び出しで合流を続ける。合流できたら本ゲートを最初から再実行する |'
assert_skill_contains "(4) 合流断念は完了報告ではなく中断報告へ倒す" \
  '合流を断念し、完了報告ではなく**中断報告**（下記の出力契約）へ倒す'
assert_skill_contains "(4) 台帳突き合わせ不能を0件に丸めない（検査不能≠0件）" \
  '未合流 0件とみなさず、**中断報告**へ倒す（検査不能を0件に丸めない）'

echo ""
echo "=== (5) 空集合の正常経路と部分合流（空虚な真・部分成功のガード） ==="

assert_skill_contains "(5) 未合流0件（起動0件を含む）は正常経路と明示している" \
  '未合流 0件（起動台帳が空の場合を含む）は**正常経路**である'
assert_skill_contains "(5) 0件を検査不能・失敗と混同しない" \
  '0件であることを検査不能・失敗と混同しない'
assert_skill_contains "(5) 未合流が1体でも残ればゲートは通過しない（部分合流≠全合流）" \
  '**一部のエージェントが合流済みでも、未合流が1体でも残っていればゲートは通過しない**'
assert_skill_contains "(5) 部分合流を全合流と報告しない" \
  '（部分合流を全合流と報告しない）'

echo ""
echo "=== (6) 決定表の参照実装（真理値表・空集合ケース必須） ==="

# 決定表の参照実装。引数: <起動台帳件数> <合流済み件数> <台帳突き合わせ可 true/false>
#                     <合流試行の上限到達 true/false>
# 出力: pass（ゲート通過）/ continue_join（応答を確定せず合流継続）/ abort_report（中断報告）
jg_gate() {
  local ledger="$1" joined="$2" reconcilable="$3" exhausted="$4"
  local unjoined
  if [ "$reconcilable" != "true" ]; then
    # 台帳と実状態を突き合わせられない場合は 0件とみなさない（検査不能≠0件）
    printf 'abort_report'
    return 0
  fi
  unjoined=$((ledger - joined))
  if [ "$unjoined" -lt 0 ]; then
    # 合流済み件数が起動台帳件数を上回る＝台帳に載っていない合流記録がある。
    # 台帳と実状態が突き合っていないため、0件（正常）に丸めず中断報告へ倒す
    printf 'abort_report'
    return 0
  fi
  if [ "$unjoined" -eq 0 ]; then
    # 空集合（起動0件）も未合流0件も正常経路
    printf 'pass'
    return 0
  fi
  if [ "$exhausted" = "true" ]; then
    printf 'abort_report'
  else
    printf 'continue_join'
  fi
}

assert_eq "(6) 起動0件・突き合わせ可はゲート通過（空集合＝正常経路）" "pass" "$(jg_gate 0 0 true false)"
assert_eq "(6) 起動0件では合流試行の上限は無関係にゲート通過" "pass" "$(jg_gate 0 0 true true)"
assert_eq "(6) 全数合流済み（8/8）はゲート通過" "pass" "$(jg_gate 8 8 true false)"
assert_eq "(6) 部分合流（5/6）はゲート通過にならず合流継続（部分成功≠完全成功）" \
  "continue_join" "$(jg_gate 6 5 true false)"
assert_eq "(6) 部分合流（5/6）で合流試行が尽きたら中断報告" "abort_report" "$(jg_gate 6 5 true true)"
assert_eq "(6) 全数未合流（0/8）で合流試行が尽きたら中断報告" "abort_report" "$(jg_gate 8 0 true true)"
assert_eq "(6) 台帳突き合わせ不能は起動0件でも pass にしない（検査不能を0件に丸めない）" \
  "abort_report" "$(jg_gate 0 0 false false)"
assert_eq "(6) 台帳突き合わせ不能は全数合流済みに見えても pass にしない" \
  "abort_report" "$(jg_gate 3 3 false true)"
assert_eq "(6) 合流済みが台帳件数を上回る（台帳3・合流4）は pass にしない（台帳に無い合流記録＝突合不能）" \
  "abort_report" "$(jg_gate 3 4 true false)"
assert_eq "(6) 台帳が空なのに合流記録がある（台帳0・合流1）も空集合の正常経路に丸めない" \
  "abort_report" "$(jg_gate 0 1 true true)"

echo ""
echo "=== (7) 中断報告の出力契約（異常系の出力契約が未定義でないこと） ==="

assert_skill_contains "(7) 中断報告の必須項目をすべて含める" \
  '次の項目を**すべて**含む中断報告を最終応答にする'
assert_skill_contains "(7) 不明項目は「不明」と書き、省略・推測で埋めない" \
  '不明な項目は「不明」と書く。省略・推測で埋めない'

# 必須項目の列挙（リテラル件数一致）
abort_items="$(awk '/^### 中断報告の出力契約/{f=1; next} /^(---|## )/{f=0} f && /^- /{print}' "$SKILL_FILE")"
abort_item_count="$(printf '%s\n' "$abort_items" | grep -c .)"
assert_eq "(7) 中断報告の必須項目は4件" "4" "$abort_item_count"
assert_skill_contains "(7) 必須項目: 未合流の一覧（種別・担当Issue・指示概要）" \
  '- 未合流のサブエージェント・処理の一覧（種別・担当Issue・起動時の指示概要）'
assert_skill_contains "(7) 必須項目: 未コミット差分の所在（worktree パス・作業ブランチ）" \
  '- 未コミット差分の所在（worktree パス・作業ブランチ）'
assert_skill_contains "(7) 必須項目: 合流済みの成果と未合流分の切り分け" \
  '- 合流済みエージェントの成果（PR URL 等）と未合流分の切り分け'
assert_skill_contains "(7) 必須項目: 回収手段（再開・差分確認の手順）" \
  '- 回収手段（`--resume` での再開・worktree 内の差分確認手順など、次に人間または親セッションが取るべき手順）'

echo ""
echo "=== (8) 接続検査（ゲートが判定経路に接続されていること） ==="

assert_skill_contains "(8) 単一Issueの Phase 10 が完了報告の前提としてゲートを参照している" \
  '**完了報告の前に「合流ゲート」（上記セクション）を通過すること**'
assert_skill_contains "(8) Phase 10 の前提でも起動0件を正常経路と明示している" \
  '1つも起動していない場合の0件も正常経路としてゲート通過'
assert_star_contains "(8) star 型の spawn 後にターン維持（spawn 時手順）を課している" \
  '各 worker の返却を受領するまでツール呼び出しを続けてターンを維持する'
assert_star_contains "(8) star 型でも待機宣言での応答確定を禁じている" \
  '「完了を待ちます」等の待機宣言をテキスト応答として出力して応答を確定しない'
assert_star_contains "(8) spawn 時手順の正本が SKILL.md にあることを示している" \
  '（SKILL.md 本文の同名セクションが定義の正本）'
assert_star_contains "(8) worker 以外のサブエージェント（衝突予測等）も起動台帳の対象である" \
  'その他のサブエージェント（`issue-conflict-predictor` 等）'

# 返却処理表: 未合流状態が表に接続されている（要判定状態が判定式に未接続にならない）
assert_star_contains "(8) 返却処理表に「返却未受領（未合流のまま）」の行がある" \
  '| 返却未受領（未合流のまま） |'
assert_star_contains "(8) 未合流は返却処理表のどの完了経路にも該当しないと明示している" \
  '**この表のどの行にも該当しない＝処理完了ではない**'
assert_star_contains "(8) 未合流行がゲートの決定表へ誘導している" \
  'の決定表に従い、ツール呼び出しで合流を続けるか、断念して中断報告へ倒す'

return_rows="$(awk '/^### worker からの返却の処理/{f=1; next} /^---/{f=0} f && /^\|/{print}' "$STAR_FILE" \
  | grep -cvE '^\|[[:space:]]*(worker の返却|-+)[[:space:]]*\|')"
assert_eq "(8) 返却処理表は5行（既存4経路＋未合流）" "5" "$return_rows"

assert_star_contains "(8) star 型の Phase 10 が完了報告の前提としてゲートを参照している" \
  '**完了報告の前に「合流ゲート（最終応答前の未合流確認）」（SKILL.md）を通過すること**'
assert_star_contains "(8) star 型の Phase 10 は全 worker・全サブエージェントを突き合わせ対象にする" \
  '未合流が0件であることを起動台帳と突き合わせて確認する'
assert_star_contains "(8) star 型の Phase 10 は未合流残・突き合わせ不能で完了報告を出さない" \
  '未合流が残る場合・突き合わせ不能の場合は完了報告を出さず'

echo ""
echo "=============================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "結果: ${PASS_COUNT}/${TOTAL} passed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "失敗したテスト:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi
exit 0
