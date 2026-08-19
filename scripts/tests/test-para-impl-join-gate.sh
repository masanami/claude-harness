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
# star 構成が spawn する Task 持ちエージェント（ネスト伝播の防御第二層を検査する）
TW_FILE="${REPO_ROOT}/agents/ticket-worker.md"
FI_FILE="${REPO_ROOT}/agents/feature-implementer.md"

for f in "$SKILL_FILE" "$STAR_FILE" "$TW_FILE" "$FI_FILE"; do
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

assert_skill_contains "(2) 最終応答前のゲート評価を必須にしている（完了報告・中断報告を含む）" \
  '最終応答（Phase 10 の完了報告・中断報告を含む、あらゆるテキスト応答の確定）の前に本ゲートを必ず評価する'
assert_skill_contains "(2) ゲート通過は完了報告だけの要件である" \
  '完了報告を出せるのは、決定表で「ゲート通過」に該当した場合だけである'
assert_skill_contains "(2) 決定表が指示した中断報告はゲート通過を要件としない（自己矛盾の排除）" \
  '**決定表が中断報告へ倒した場合は、その中断報告の確定自体がゲートの評価結果であり、「ゲート通過」を要件としない**'
assert_skill_contains "(2) 通過状態を待つ永久再試行を禁じている" \
  '（通過状態を待って永遠に再試行しない）'
assert_skill_contains "(2) 手順違反は評価なしの最終応答だけである" \
  '手順違反となるのは、**ゲートを評価せずに確定する最終応答**だけである'
assert_file_not_contains "(2) 中断報告にも通過を求める旧不変条項が残っていない" "$SKILL_FILE" \
  'あらゆるテキスト応答の確定）の前に本ゲートを必ず通過する'
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
assert_skill_contains "(3) 起動時に有限タスク／常駐サービスの区別を記録する" \
  '**有限タスクか常駐サービスかの区別も記録する**'
assert_skill_contains "(3) 常駐サービスの定義（最終返却を産まない前提の起動）" \
  '**意図的に稼働し続け、最終返却を産まない前提**の起動（dev サーバ・watch プロセス等）'
assert_skill_contains "(3) 常駐サービスの最終返却を待たない（待つと永遠に合流できない）" \
  '**最終返却を待ってはならない**（待つと永遠に合流できず、ゲートを通過できない）'
assert_skill_contains "(3) 常駐サービスの合流相当は停止確認の台帳記録である" \
  '常駐サービスは**停止・後始末を実施し、停止を確認して台帳に記録した**状態（突合済み＝合流相当）'
assert_skill_contains "(3) 常駐サービスには返却待機を適用しない（spawn 時手順）" \
  '**常駐サービスにはこの待機を適用しない**'
assert_skill_contains "(3) 区別が記録されていない起動は fail-closed の既定に従う" \
  '区別が記録されていない・判別できない起動が残っている場合は、決定表の「どの行に該当するか判定できない場合」の既定（中断報告）に従う'
assert_skill_contains "(3) ネスト未解消の用語定義（条項(3)の報告つき返却）がある" \
  '有限タスクの返却は受領したが、その返却に合流ゲート伝播条項 (3) の未解消報告が含まれる状態'
assert_skill_contains "(3) ネスト未解消は合流済みとして扱わない" \
  '**合流済みとして扱わない**（台帳に「ネスト未解消」として記録する'
assert_skill_contains "(3) 未合流の定義がネスト未解消を第3の状態として区別している" \
  '起動台帳に載っており、合流済みでもネスト未解消でもないもの'
assert_skill_contains "(3) 起動直後にテキストで応答を確定しない" \
  '**起動直後にテキストで応答を確定しない**'
assert_skill_contains "(3) 待機宣言を手順違反として扱う（注意書きに格下げしない）" \
  '待機宣言は注意書きではなく**手順違反**として扱う'
assert_skill_contains "(3) 合流までツール呼び出しでターンを維持する" \
  'ツール呼び出しを続けてターンを維持する'
assert_skill_contains "(3) ターン維持の具体手段（ブロッキング待機・ポーリング）を示している" \
  '結果取得ツールでのブロッキング待機、または状態確認のポーリングを合流まで繰り返す'
assert_skill_contains "(3) 「起動に成功した」「稼働中である」を合流とみなさない（用語の定義）" \
  '「起動に成功した」「完了通知が来るはず」「稼働中である」は合流ではない'
assert_skill_contains "(3) 合流済みの定義は最終返却の受領である" \
  '最終返却（結果）をこのセッションで受領した'

echo ""
echo "=== (4) 決定表の状態空間（行の列挙・リテラル件数一致） ==="

# 決定表の第1列（状態）を抽出する。ヘッダ行・区切り行は除く。
gate_states="$(awk '/^### 手順（最終応答の直前）/{f=1; next} /^### /{f=0} f && /^\|/{print}' "$SKILL_FILE" \
  | grep -vE '^\|[[:space:]]*(状態|-+)[[:space:]]*\|' \
  | sed -E 's/^\|[[:space:]]*//; s/[[:space:]]*\|.*$//')"
expected_states='起動台帳が空（1つも起動していない）
未合流 0件かつネスト未解消 0件（起動台帳が1件以上あり、有限タスクはすべて正常受領済み・常駐サービスはすべて停止確認済み）
未合流の有限タスクが1件以上で、受領の見込みがある（稼働を確認できる、または結果取得の待機・タイムアウトが続いているだけ）
未合流の有限タスクが1件以上のまま、受領の見込みがない（稼働確認も結果取得もできない状態が、確認の再試行上限まで続いた）
未合流の有限タスクは0件で、停止確認の済んでいない常駐サービスが1件以上
未合流 0件のまま、ネスト未解消として記録された起動が1件以上
起動台帳と実状態を突き合わせられない（台帳の欠落・コンテキスト要約による消失・台帳に載っていない合流記録がある〔合流済み件数が起動台帳件数を上回る〕等）'
assert_eq "(4) 決定表の状態が7件・期待の列挙と完全一致する（増減・改変で落ちる）" \
  "$expected_states" "$gate_states"

# 排他性の宣言と判定不能時の fail-closed
assert_skill_contains "(4) 各行の状態が互いに排他であることを宣言している" \
  '**各行の状態は互いに排他であり、どの状態も高々1行にだけ該当する**'
assert_skill_contains "(4) 1〜6行目は突き合わせ成立が前提（最終行と重ならない）" \
  '1〜6行目は台帳と実状態の突き合わせが成立していることが前提'
assert_skill_contains "(4) 該当行を判定できない場合は中断報告へ倒す（fail-closed の既定）" \
  '**どの行に該当するか判定できない場合は、突き合わせ不能として最終行（中断報告）へ倒す**'
assert_skill_contains "(4) 受領の見込みは実状態の確認で判定する（回数・経過時間だけで判定しない）" \
  '受領の見込みは**実状態の確認で判定し、待機・ポーリングの回数や経過時間だけを根拠に判定しない**'
assert_skill_contains "(4) 取得タイムアウトを「結果がもう来ない」と同一視しない" \
  '結果取得のタイムアウトは「結果がもう来ない」ことを意味しない'
assert_skill_contains "(4) worker の長時間・多数回待機は正当な稼働であると明示している" \
  'Phase 4〜9 を実行中の worker は長時間・多数回の待機にまたがって正当に稼働し続ける'
assert_skill_contains "(4) 再試行上限は稼働確認も結果取得もできない場合の確認試行に限定する" \
  '再試行上限（**3回を目安**）は、**稼働確認も結果取得もできない場合の確認試行にだけ**適用する'
assert_file_not_contains "(4) 取得失敗を一律に回数へ数える旧規則が残っていない" "$SKILL_FILE" \
  '結果取得の失敗も回数に数える'

# 状態→動作の対応（行単位の逐語検査）
assert_skill_contains "(4) 起動0件（空集合）はゲート通過の正常経路である" \
  '| 起動台帳が空（1つも起動していない） | ゲート通過。そのまま最終応答へ |'
assert_skill_contains "(4) 未合流0件かつネスト未解消0件（台帳1件以上）はゲート通過の正常経路である（空台帳の行と重ねない）" \
  '| 未合流 0件かつネスト未解消 0件（起動台帳が1件以上あり、有限タスクはすべて正常受領済み・常駐サービスはすべて停止確認済み） | ゲート通過。そのまま最終応答へ |'
assert_skill_contains "(4) 未合流の有限タスク1件以上・受領見込みありは応答を確定せず合流を続け、合流後にゲートを再実行する" \
  '| 未合流の有限タスクが1件以上で、受領の見込みがある（稼働を確認できる、または結果取得の待機・タイムアウトが続いているだけ） | 最終応答を確定せず、ツール呼び出しで合流を続ける。合流できたら本ゲートを最初から再実行する（常駐サービスの停止は、有限タスクの合流がすべて済むまで行わない） |'
assert_skill_contains "(4) 未合流の有限タスク1件以上のまま受領見込みなしは中断報告へ倒す（合流継続の行と排他）" \
  '| 未合流の有限タスクが1件以上のまま、受領の見込みがない（稼働確認も結果取得もできない状態が、確認の再試行上限まで続いた） | 合流を断念し、完了報告ではなく**中断報告**（下記の出力契約）へ倒す |'
assert_skill_contains "(4) 常駐サービス残のみの状態は停止・確認・台帳記録のうえゲート再実行（返却を待たない）" \
  '| 未合流の有限タスクは0件で、停止確認の済んでいない常駐サービスが1件以上 | 常駐サービスを停止・後始末し、停止を確認して台帳に記録してから本ゲートを最初から再実行する。**最終返却は待たない**。停止を確認できない場合は**中断報告**へ倒す |'
assert_skill_contains "(4) ネスト未解消が残る状態はゲート通過にせず中断報告へエスカレーションする" \
  '| 未合流 0件のまま、ネスト未解消として記録された起動が1件以上 | ゲート通過にせず、**中断報告**へ倒す（委譲先が報告した未解消の一覧・実状態を転記してエスカレーションする） |'
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

# 決定表の参照実装。引数:
#   <有限タスク台帳件数> <有限タスク正常受領済み件数>
#   <常駐サービス台帳件数> <常駐サービス停止確認済み件数>
#   <ネスト未解消として記録された件数>
#   <台帳突き合わせ可 true/false> <受領見込みなし true/false>
# 第5引数は「返却は受領したが伝播条項 (3) の未解消報告を含む」有限タスクの件数
# （正常受領済みには数えない。合流済みとして扱わない第3の終端状態）。
# 第7引数は**有限タスクについて**「受領の見込みがない」ことが実状態の確認
# （稼働確認も結果取得もできない状態が確認の再試行上限まで続いた）で確定したかを表す。
# 待機・ポーリングの回数や経過時間だけでは true にならない（取得タイムアウトの継続は
# false のまま）。常駐サービスは最終返却を産まないため受領見込みの軸を持たず、
# 停止確認の有無だけで突合する。
# 出力: pass（ゲート通過）/ continue_join（応答を確定せず合流継続）/
#       stop_residents（常駐サービスを停止・確認・台帳記録してゲート再実行）/
#       abort_report（中断報告。ネスト未解消のエスカレーションを含む）
jg_gate() {
  local f_ledger="$1" f_joined="$2" r_ledger="$3" r_stopped="$4" nested_unresolved="$5" reconcilable="$6" no_prospect="$7"
  local f_unjoined r_unjoined
  if [ "$reconcilable" != "true" ] || [ $((f_joined + nested_unresolved)) -gt "$f_ledger" ] || [ "$r_stopped" -gt "$r_ledger" ]; then
    # 台帳と実状態を突き合わせられない（台帳に載っていない合流記録・停止記録を含む）
    # 場合は 0件とみなさない（検査不能≠0件）
    printf 'abort_report'
    return 0
  fi
  f_unjoined=$((f_ledger - f_joined - nested_unresolved))
  r_unjoined=$((r_ledger - r_stopped))
  if [ "$f_unjoined" -ge 1 ]; then
    # 未合流の有限タスクの解消を先にする（常駐サービスの停止・ネスト未解消の
    # エスカレーションはその後）
    if [ "$no_prospect" = "true" ]; then
      printf 'abort_report'
    else
      printf 'continue_join'
    fi
    return 0
  fi
  if [ "$r_unjoined" -ge 1 ]; then
    # 有限タスク0件・停止未確認の常駐サービスあり
    printf 'stop_residents'
    return 0
  fi
  if [ "$nested_unresolved" -ge 1 ]; then
    # 未合流0件でもネスト未解消が残っていれば通過にしない（握りつぶしの防止）
    printf 'abort_report'
    return 0
  fi
  # 空集合（起動0件）も、全区分解消済みの未合流0件も正常経路
  printf 'pass'
}

assert_eq "(6) 起動0件・突き合わせ可はゲート通過（空集合＝正常経路）" "pass" "$(jg_gate 0 0 0 0 0 true false)"
assert_eq "(6) 起動0件では受領見込みの判定は無関係にゲート通過" "pass" "$(jg_gate 0 0 0 0 0 true true)"
assert_eq "(6) 有限タスク全数正常受領済み（8/8）はゲート通過" "pass" "$(jg_gate 8 8 0 0 0 true false)"
assert_eq "(6) 部分合流（5/6）・受領見込みありはゲート通過にならず合流継続（部分成功≠完全成功）" \
  "continue_join" "$(jg_gate 6 5 0 0 0 true false)"
assert_eq "(6) 稼働確認できる限り取得タイムアウトが何度続いても合流継続（回数で中断へ倒さない）" \
  "continue_join" "$(jg_gate 6 5 0 0 0 true false)"
assert_eq "(6) 部分合流（5/6）で受領見込みなしが確定したら中断報告" "abort_report" "$(jg_gate 6 5 0 0 0 true true)"
assert_eq "(6) 全数未合流（0/8）で受領見込みなしが確定したら中断報告" "abort_report" "$(jg_gate 8 0 0 0 0 true true)"
assert_eq "(6) 台帳突き合わせ不能は起動0件でも pass にしない（検査不能を0件に丸めない）" \
  "abort_report" "$(jg_gate 0 0 0 0 0 false false)"
assert_eq "(6) 台帳突き合わせ不能は全数合流済みに見えても pass にしない" \
  "abort_report" "$(jg_gate 3 3 0 0 0 false true)"
assert_eq "(6) 受領済みが台帳件数を上回る（台帳3・受領4）は pass にしない（台帳に無い合流記録＝突合不能）" \
  "abort_report" "$(jg_gate 3 4 0 0 0 true false)"
assert_eq "(6) 台帳が空なのに合流記録がある（台帳0・受領1）も空集合の正常経路に丸めない" \
  "abort_report" "$(jg_gate 0 1 0 0 0 true true)"
assert_eq "(6) 常駐サービスのみ未停止（有限0件）は返却を待たず停止・確認へ" \
  "stop_residents" "$(jg_gate 0 0 1 0 0 true false)"
assert_eq "(6) 常駐サービスは受領見込みの軸を持たない（見込みなし扱いでも停止・確認へ）" \
  "stop_residents" "$(jg_gate 0 0 1 0 0 true true)"
assert_eq "(6) 常駐サービス停止確認済みはゲート通過" "pass" "$(jg_gate 0 0 1 1 0 true false)"
assert_eq "(6) 有限タスクの未合流が残る間は常駐サービスの停止より合流継続を先にする" \
  "continue_join" "$(jg_gate 6 5 1 0 0 true false)"
assert_eq "(6) 有限タスク受領見込みなしなら常駐サービスの状態によらず中断報告" \
  "abort_report" "$(jg_gate 6 5 1 0 0 true true)"
assert_eq "(6) 停止確認件数が常駐台帳件数を上回る（台帳1・停止2）は突合不能として中断報告" \
  "abort_report" "$(jg_gate 0 0 1 2 0 true false)"
assert_eq "(6) ネスト未解消が残る返却済み状態（台帳2・正常1・未解消1）はゲート通過にせず中断報告" \
  "abort_report" "$(jg_gate 2 1 0 0 1 true false)"
assert_eq "(6) ネスト未解消のみ（台帳1・正常0・未解消1）も中断報告（握りつぶしの防止）" \
  "abort_report" "$(jg_gate 1 0 0 0 1 true false)"
assert_eq "(6) ネスト未解消があっても未合流の有限タスクが残る間は合流継続を先にする" \
  "continue_join" "$(jg_gate 3 1 0 0 1 true false)"
assert_eq "(6) ネスト未解消があっても停止未確認の常駐サービスの停止を先にする" \
  "stop_residents" "$(jg_gate 2 1 1 0 1 true false)"
assert_eq "(6) 正常受領＋ネスト未解消が台帳件数を上回る（台帳1・正常1・未解消1）は突合不能" \
  "abort_report" "$(jg_gate 1 1 0 0 1 true false)"

echo ""
echo "=== (6b) 決定表の排他性（全状態で該当行がちょうど1行・動作の一貫性） ==="

# 決定表の各行の状態条件の参照実装（SKILL.md の状態列を述語に写したもの）。
# 引数: <行番号 1-7> <有限タスク台帳件数> <有限タスク正常受領済み件数>
#       <常駐サービス台帳件数> <常駐サービス停止確認済み件数>
#       <ネスト未解消として記録された件数>
#       <突き合わせ可 true/false> <受領見込みなし true/false>
# 第6・第8引数の意味は jg_gate と同じ（ネスト未解消は正常受領に数えない第3の終端状態。
# 受領見込みなしは有限タスクについて実状態の確認で確定したか。回数・経過時間だけでは
# true にならない）。
# 行7 は「突き合わせ不能」であり、reconcilable=false と「台帳に無い合流記録・停止記録
# （正常受領＋ネスト未解消・停止確認済みの件数が台帳件数を上回る）」の両方を含む。
# 行1〜6 は突き合わせ成立が前提。
jg_row_matches() {
  local row="$1" f_ledger="$2" f_joined="$3" r_ledger="$4" r_stopped="$5" nested_unresolved="$6" reconcilable="$7" no_prospect="$8"
  local sane="true"
  if [ "$reconcilable" != "true" ] || [ $((f_joined + nested_unresolved)) -gt "$f_ledger" ] || [ "$r_stopped" -gt "$r_ledger" ]; then
    sane="false"
  fi
  local f_unjoined=$((f_ledger - f_joined - nested_unresolved))
  local r_unjoined=$((r_ledger - r_stopped))
  case "$row" in
    1) [ "$sane" = "true" ] && [ $((f_ledger + r_ledger)) -eq 0 ] ;;
    2) [ "$sane" = "true" ] && [ $((f_ledger + r_ledger)) -ge 1 ] && [ "$f_unjoined" -eq 0 ] && [ "$r_unjoined" -eq 0 ] && [ "$nested_unresolved" -eq 0 ] ;;
    3) [ "$sane" = "true" ] && [ "$f_unjoined" -ge 1 ] && [ "$no_prospect" != "true" ] ;;
    4) [ "$sane" = "true" ] && [ "$f_unjoined" -ge 1 ] && [ "$no_prospect" = "true" ] ;;
    5) [ "$sane" = "true" ] && [ "$f_unjoined" -eq 0 ] && [ "$r_unjoined" -ge 1 ] ;;
    6) [ "$sane" = "true" ] && [ "$f_unjoined" -eq 0 ] && [ "$r_unjoined" -eq 0 ] && [ "$nested_unresolved" -ge 1 ] ;;
    7) [ "$sane" = "false" ] ;;
    *) false ;;
  esac
}

# 行番号→動作（決定表の動作列。1,2=ゲート通過 / 3=合流継続 / 4,6,7=中断報告 /
# 5=常駐サービスの停止・確認・台帳記録のうえゲート再実行）
jg_row_action() {
  case "$1" in
    1 | 2) printf 'pass' ;;
    3) printf 'continue_join' ;;
    4 | 6 | 7) printf 'abort_report' ;;
    5) printf 'stop_residents' ;;
    *) printf 'unknown' ;;
  esac
}

# 状態空間を列挙し、各状態で (a) 該当行がちょうど1行であること、
# (b) 該当行の動作が参照実装 jg_gate の出力と一致することを検査する。
# 受領済み・停止確認済みの件数は台帳件数の境界（0・1・全数・全数+1）を含めて振る。
exclusivity_violations=""
action_mismatches=""
state_count=0
for f_ledger in 0 2; do
  for f_joined in 0 1 2 3; do
    for nested_unresolved in 0 1 2; do
      [ $((f_joined + nested_unresolved)) -le $((f_ledger + 1)) ] || continue
      for r_ledger in 0 1; do
        for r_stopped in 0 1 2; do
          [ "$r_stopped" -le $((r_ledger + 1)) ] || continue
          for reconcilable in true false; do
            for no_prospect in true false; do
              state_count=$((state_count + 1))
              match_count=0
              matched_row=0
              for row in 1 2 3 4 5 6 7; do
                if jg_row_matches "$row" "$f_ledger" "$f_joined" "$r_ledger" "$r_stopped" "$nested_unresolved" "$reconcilable" "$no_prospect"; then
                  match_count=$((match_count + 1))
                  matched_row="$row"
                fi
              done
              state="F=${f_ledger}/${f_joined},U=${nested_unresolved},S=${r_ledger}/${r_stopped},R=${reconcilable},N=${no_prospect}"
              if [ "$match_count" -ne 1 ]; then
                exclusivity_violations="${exclusivity_violations}${state}=${match_count}行 "
              elif [ "$(jg_row_action "$matched_row")" != "$(jg_gate "$f_ledger" "$f_joined" "$r_ledger" "$r_stopped" "$nested_unresolved" "$reconcilable" "$no_prospect")" ]; then
                action_mismatches="${action_mismatches}${state} "
              fi
            done
          done
        done
      done
    done
  done
done
assert_eq "(6b) 列挙した状態数が想定どおり（境界の取りこぼしなし）" "240" "$state_count"
assert_eq "(6b) 全状態で該当行がちょうど1行（重なり・漏れなし）" "" "$exclusivity_violations"
assert_eq "(6b) 各状態の該当行の動作が参照実装 jg_gate と一致する" "" "$action_mismatches"

echo ""
echo "=== (7) 中断報告の出力契約（異常系の出力契約が未定義でないこと） ==="

assert_skill_contains "(7) 中断報告の必須項目をすべて含める" \
  '次の項目を**すべて**含む中断報告を最終応答にする'
assert_skill_contains "(7) 不明項目は「不明」と書き、省略・推測で埋めない" \
  '不明な項目は「不明」と書く。省略・推測で埋めない'

# 必須項目の列挙（リテラル件数一致）
abort_items="$(awk '/^### 中断報告の出力契約/{f=1; next} /^(---|## )/{f=0} f && /^- /{print}' "$SKILL_FILE")"
abort_item_count="$(printf '%s\n' "$abort_items" | grep -c .)"
assert_eq "(7) 中断報告の必須項目は6件" "6" "$abort_item_count"
assert_skill_contains "(7) 必須項目: 未合流の一覧（種別・担当Issue・指示概要）" \
  '- 未合流のサブエージェント・処理の一覧（種別・担当Issue・起動時の指示概要）'
assert_skill_contains "(7) 必須項目: 稼働したままの常駐サービスの一覧（0件は「なし」を明示）" \
  '- 稼働したままの常駐サービスの一覧（種別・停止と後始末の手順。無ければ「なし」と書く）'
assert_skill_contains "(7) 必須項目: 委譲先から報告されたネスト未解消の一覧（0件は「なし」を明示）" \
  '- 委譲先から報告されたネスト未解消の一覧（合流ゲート伝播条項 (3) の報告の転記。無ければ「なし」と書く）'
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
assert_star_contains "(8) star 型でも常駐サービスは台帳に常駐として記録し、返却を待たず停止確認で突合する" \
  '常駐サービス（dev サーバ等）を起動した場合も台帳に**常駐サービス**として記録し、同ゲートの規律に従う（**最終返却は待たず**、停止・後始末の確認をもって合流相当とする）'
assert_star_contains "(8) star 型の Phase 10 の突き合わせ対象に常駐サービスが含まれる" \
  '（衝突予測・`/explain-e2e` の独立検証委譲・dev サーバ等の常駐サービスを含む）'

# 返却処理表: 未合流状態が表に接続されている（要判定状態が判定式に未接続にならない）
assert_star_contains "(8) 返却処理表に「返却未受領（未合流のまま）」の行がある" \
  '| 返却未受領（未合流のまま） |'
assert_star_contains "(8) 未合流は返却処理表のどの完了経路にも該当しないと明示している" \
  '**この表のどの行にも該当しない＝処理完了ではない**'
assert_star_contains "(8) 未合流行がゲートの決定表へ誘導している" \
  'の決定表に従い、ツール呼び出しで合流を続けるか、断念して中断報告へ倒す'

return_rows="$(awk '/^### worker からの返却の処理/{f=1; next} /^---/{f=0} f && /^\|/{print}' "$STAR_FILE" \
  | grep -cvE '^\|[[:space:]]*(worker の返却|-+)[[:space:]]*\|')"
assert_eq "(8) 返却処理表は6行（既存4経路＋未合流＋ネスト未解消）" "6" "$return_rows"
assert_star_contains "(8) 未解消報告つき返却は合流済みとして扱わずネスト未解消として記録する" \
  '| 合流ゲート伝播条項 (3) の未解消報告を含む返却 | 当該 worker を**合流済みとして扱わず**、起動台帳に**ネスト未解消**として記録する。'
assert_star_contains "(8) ネスト未解消行は他 worker を止めず最終応答時にゲートが中断報告へ倒す" \
  '他 worker の処理は継続する。最終応答時に合流ゲートの決定表（ネスト未解消行）が中断報告へ倒し、worker が報告した未解消の一覧・実状態を転記する'

assert_star_contains "(8) star 型の Phase 10 が完了報告の前提としてゲートを参照している" \
  '**完了報告の前に「合流ゲート（最終応答前の未合流確認）」（SKILL.md）を通過すること**'
assert_star_contains "(8) star 型の Phase 10 は全 worker・全サブエージェントを突き合わせ対象にする" \
  '未合流が0件であることを起動台帳と突き合わせて確認する'
assert_star_contains "(8) star 型の Phase 10 は未合流残・突き合わせ不能で完了報告を出さない" \
  '未合流が残る場合・突き合わせ不能の場合は完了報告を出さず'

echo ""
echo "=== (9) ネストへの伝播（spawn プロンプト条項・agent 定義の防御第二層） ==="

# 条項の正本は SKILL.md の「ネストへの伝播」だけ（複製しない）
nest_heading_count="$(grep -cF -- '### ネストへの伝播（spawn プロンプト条項）' "$SKILL_FILE")"
assert_eq "(9) SKILL.md にネスト伝播の小節がちょうど1箇所ある" "1" "$nest_heading_count"
assert_skill_contains "(9) 台帳が検査できるのは直接起動分だけ（ネストは台帳で検査できない）" \
  '起動台帳が把握できるのは**自分が直接起動したものだけ**である'
assert_skill_contains "(9) spawn プロンプトへの逐語転記を必須にしている" \
  'サブエージェントへ委譲する spawn プロンプトには、次の**合流ゲート伝播条項**を逐語で含める'
assert_skill_contains "(9) 迷った場合は含める（適用側の fail-safe）" \
  '含めるか迷った場合は含める'
assert_skill_contains "(9) ネストの解消は委譲先が条項で保証する" \
  '**ネストの解消は各委譲先が本条項で保証する**'
assert_skill_contains "(9) 解消済みの含意は未解消報告を含まない正常返却に限定されている" \
  '委譲先からの**条項 (3) の未解消報告を含まない正常返却**の受領は、委譲先がネストを解消済みであることを含意する'
assert_skill_contains "(9) 未解消報告つき返却は合流済みとして扱わずネスト未解消として台帳に記録する" \
  '**未解消報告を含む返却は合流済みとして扱わず、台帳に「ネスト未解消」として記録する**'
assert_file_not_contains "(9) 返却受領を無条件に解消済みの含意とする旧文が残っていない" "$SKILL_FILE" \
  '委譲先からの返却の受領は、委譲先が本条項を守った'

# 条項本文の4項目（逐語）と件数
assert_skill_contains "(9) 条項見出しがある" '【合流ゲート伝播条項】'
assert_skill_contains "(9) 条項(1): 返却確定前の全解消（有限=未解消報告を含まない正常返却・常駐=停止確認）" \
  '(1) 最終返却を確定する前に、起動したものをすべて解消する（有限タスクは未解消報告を含まない正常返却の受領、常駐サービスは停止・後始末の確認）。'
assert_file_not_contains "(9) 条項(1)の解消定義を無条件の返却受領とする旧文が残っていない" "$SKILL_FILE" \
  '（有限タスクは返却の受領、常駐サービスは停止・後始末の確認）'
assert_skill_contains "(9) 条項(2): 待機宣言の禁止とターン維持（(3)の失敗返却を阻まない）" \
  '(2) 「完了を待ちます」等の待機宣言を最終返却にしない。解消が済むまで、または (3) の解消不能の判断に至るまで、ツール呼び出しを続けてターンを維持する。'
assert_skill_contains "(9) 条項(3): 解消不能時の出力契約（未解消一覧と実状態）" \
  '(3) 解消できない場合は、未解消の一覧と実状態（未コミット差分の所在を含む）を返却に明記する。'
assert_skill_contains "(9) 条項(4): 子の未解消報告のバブルアップ（解消済みとして扱わず転記して上へ伝える）" \
  '(4) 子の返却に (3) の未解消報告が含まれる場合は、その子を解消済みとして扱わず、自分の返却にその未解消の一覧・実状態を転記して上へ伝える（正常返却にしない）。'
assert_skill_contains "(9) 条項(5): 再帰伝播（さらに委譲する場合は条項をそのまま含める）" \
  '(5) さらに委譲する場合は、この条項を委譲プロンプトへそのまま含める。'
clause_item_count="$(awk '/【合流ゲート伝播条項】/{f=1; next} /^```/{f=0} f' "$SKILL_FILE" \
  | grep -cE '^\([0-9]+\) ')"
assert_eq "(9) 条項の項目は5件（リテラル件数一致）" "5" "$clause_item_count"

# リード側の含意（ネストへの伝播の本文）と条項(1)が同一の文言規則を使う（2規則化の防止）。
# 「未解消報告を含まない正常返却」は SKILL.md にちょうど2箇所（含意＋条項(1)）。
canon_rule_count="$(grep -cF -- '未解消報告を含まない正常返却' "$SKILL_FILE")"
assert_eq "(9) 「未解消報告を含まない正常返却」の文言規則がリード側含意と条項(1)の2箇所で一致する" \
  "2" "$canon_rule_count"

# 接続検査: 単一Issue（Phase 4-5）と star 型（spawn プロンプト必須項目）の双方から条項へ接続
assert_skill_contains "(9) 単一Issueの Phase 4-5 委譲プロンプトにも条項を含める" \
  '委譲プロンプトには**合流ゲート伝播条項**（「合流ゲート（最終応答前の未合流確認）」セクションの「ネストへの伝播」に定義。逐語で転記する）も含める'
assert_star_contains "(9) star 型の spawn プロンプト必須項目に条項の転記がある" \
  '- **合流ゲート伝播条項**（SKILL.md「合流ゲート」セクションの「ネストへの伝播」に定義された条項を**逐語で転記する**'
assert_star_contains "(9) 条項が無い場合の喪失経路（worker のネスト spawn）を明示している" \
  'worker は Phase 4-5 で `feature-implementer` をさらに spawn するため'
assert_file_not_contains "(9) star-parallel.md は条項本文を複製しない（正本は SKILL.md のみ）" "$STAR_FILE" \
  '【合流ゲート伝播条項】'

# agent 定義の防御第二層（spawn 時に自動伝播する行動規範側にも同じ規律を置く）
for agent_file in "$TW_FILE" "$FI_FILE"; do
  agent_name="$(basename "$agent_file")"
  bullet_count="$(grep -cF -- '**返却前の合流（合流ゲートの伝播）**' "$agent_file")"
  assert_eq "(9) ${agent_name} に「返却前の合流」規律がちょうど1箇所ある" "1" "$bullet_count"
  assert_file_contains "(9) ${agent_name}: 最終返却の確定前にネストを全解消する（有限=未解消報告を含まない正常返却）" "$agent_file" \
    '**最終返却を確定する前にすべて解消する**（有限タスクは**未解消報告を含まない正常返却**の受領・常駐サービスは停止と後始末の確認）'
  assert_file_not_contains "(9) ${agent_name}: 解消定義を無条件の返却受領とする旧文が残っていない" "$agent_file" \
    '（有限タスクは返却の受領・常駐サービスは停止と後始末の確認）'
  assert_file_contains "(9) ${agent_name}: 待機宣言を最終返却にしない（道連れ終了の明示）" "$agent_file" \
    '**待機宣言を最終返却にしない**（返却の確定でネストの処理は道連れで強制終了される）'
  assert_file_contains "(9) ${agent_name}: 解消不能時は未解消一覧と実状態を返却に明記する" "$agent_file" \
    '解消できない場合は未解消の一覧と実状態（未コミット差分の所在を含む）を返却に明記する'
  assert_file_contains "(9) ${agent_name}: 子の未解消報告をバブルアップする（正常返却にしない）" "$agent_file" \
    '**子の返却に未解消報告が含まれる場合は、その子を解消済みとして扱わず、自分の返却にその未解消の一覧・実状態を転記して上へ伝える（正常返却にしない）**'
  assert_file_contains "(9) ${agent_name}: 再帰伝播（さらに委譲する場合は規律を委譲プロンプトへ）" "$agent_file" \
    'さらに委譲する場合は**この規律を委譲プロンプトにも含める**'
done

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
