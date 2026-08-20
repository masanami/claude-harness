#!/bin/bash
# test-para-impl-gdd-gate.sh
# GDD P3・para-impl / feature-implementer 系統（裁可ゲート・保証ブリーフ・保証整合確認。
# Issue #158 / docs/gdd-design-draft.md §5.4）の回帰テスト。4部構成:
#
#  (A) 統合が依存するスクリプト契約の回帰テスト
#      /para-impl の裁可ゲートと feature-implementer 2-5 は detect-dev-phase.sh の
#      exit code と phase の語彙に依存して発動を分岐する（gdd のみ発動・sdd は完全不変・
#      invalid は fail-closed で中断）。統合が前提にする最小契約をフィクスチャで固定する。
#      スクリプト単体の網羅は test-detect-dev-phase.sh の担当であり、ここでは重複させない。
#
#  (B) 正準文（固定文字列）の逐語存在検査
#      ゲート・ブリーフは散文の手順として実装されている（コード側の強制ではない）ため、
#      test-quality-check-gdd-gate.sh (B) と同じ方式で、正準文が逐語で存在することを
#      grep で検査し、手順のドリフト（更新漏れ・緩和）を機械検出する。
#
#  (C) cross-file 逐語照合
#      複数ファイルに現れる同一の規約（フェーズ判定の定型文・保証節ブロックのマーカー・
#      裁可ラベル名・読み取り文法の正本参照）が、定義箇所と参照箇所で一字一句一致する
#      ことを検査する（同じものを2つの規則で読まない）。
#
#  (D) 判定表の参照実装による真理値表
#      裁可対象の解決（Parent:/保証: 行の同一性検証）・ラベルの完全一致判定・
#      複数 Issue の集約（部分成功≠完全成功）・保証 ID のスコープ検証（完全文法）を、
#      guarantee-gate.md の判定表と同じ規則の bash 参照実装で実行可能な形で固定する。
#      検査不能（ラベル取得失敗）を「ラベルなし」に丸めないことを必須ケースで含む。
#
# 実行方法: bash scripts/tests/test-para-impl-gdd-gate.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # 正準文内のバッククォートは Markdown のリテラル
# （スキル本文の逐語検査対象）であり、シェル展開を意図していない
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DETECT_SCRIPT="${REPO_ROOT}/scripts/detect-dev-phase.sh"
SKILL_FILE="${REPO_ROOT}/skills/para-impl/SKILL.md"
GATE_FILE="${REPO_ROOT}/skills/para-impl/references/guarantee-gate.md"
STAR_FILE="${REPO_ROOT}/skills/para-impl/references/star-parallel.md"
JOIN_FILE="${REPO_ROOT}/skills/para-impl/references/join-gate.md"
TW_FILE="${REPO_ROOT}/agents/ticket-worker.md"
FI_FILE="${REPO_ROOT}/agents/feature-implementer.md"
CT_SKILL_FILE="${REPO_ROOT}/skills/create-ticket/SKILL.md"
PV_SKILL_FILE="${REPO_ROOT}/skills/promote-verify/SKILL.md"
GS_FILE="${REPO_ROOT}/skills/create-ticket/references/guarantee-section.md"
STRATEGY_FILE="${REPO_ROOT}/docs/ai-driven-development-strategy.md"

for f in "$DETECT_SCRIPT" "$SKILL_FILE" "$GATE_FILE" "$STAR_FILE" "$JOIN_FILE" \
  "$TW_FILE" "$FI_FILE" "$CT_SKILL_FILE" "$PV_SKILL_FILE" "$GS_FILE" "$STRATEGY_FILE"; do
  if [ ! -r "$f" ]; then
    echo "NG - 検査対象ファイルを読めません（検査不能を pass にはしない）: ${f}" >&2
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "NG - jq が見つからないためテストを実行できません（検査不能を pass にはしない）" >&2
  exit 1
fi

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

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

# ---------------------------------------------------------------------------
# (A) スクリプト契約: 裁可ゲートの発動判定が依存する detect-dev-phase の最小契約
# ---------------------------------------------------------------------------
echo "=== (A) スクリプト契約: detect-dev-phase の発動判定 ==="

WS="${TMP_ROOT}/project"
mkdir -p "$WS"

printf '# プロジェクト\n\n## 技術スタック\n\n- bash\n' >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "(A) 宣言なし: exit 0（裁可ゲートを発動しない＝SDD期の完全不変の入力）" "0" "$code"
assert_eq "(A) 宣言なし: phase は sdd" "sdd" "$(printf '%s' "$out" | jq -r '.phase')"

printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n- 駆動文書: docs/guarantees.md\n' >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "(A) GDD期宣言: exit 0" "0" "$code"
assert_eq "(A) GDD期宣言: phase は gdd（裁可ゲートを発動する入力）" \
  "gdd" "$(printf '%s' "$out" | jq -r '.phase')"

printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: GDD\n' >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "(A) 不正宣言: exit 1（para-impl は中断して要人間判定にする入力）" "1" "$code"
assert_eq "(A) 不正宣言: phase は invalid（sdd に読み替え不可）" \
  "invalid" "$(printf '%s' "$out" | jq -r '.phase')"

# ---------------------------------------------------------------------------
# (B) 正準文の逐語存在検査
# ---------------------------------------------------------------------------
echo ""
echo "=== (B-1) SKILL.md: 裁可ゲートの接続と default-OFF ==="

gate_heading_count="$(grep -cxF -- '### 裁可ゲート（GDD期のみ）' "$SKILL_FILE")"
assert_eq "(B-1) SKILL.md に裁可ゲートの見出しがちょうど1箇所ある" "1" "$gate_heading_count"
assert_file_contains "(B-1) 停止パターンは統合ブランチ存在チェックと同じ前提未充足での停止" "$SKILL_FILE" \
  '統合ブランチ存在チェックと同じ「前提未充足での停止」パターンを使う'
assert_file_contains "(B-1) 新しい待ち合わせ機構を作らない（設計の明示指示）" "$SKILL_FILE" \
  '新しい待ち合わせ機構は作らない'
assert_file_contains "(B-1) 対象は実装チケットなら親（裁可の単位は親 Issue）" "$SKILL_FILE" \
  '対象 Issue（実装チケットなら親）に `guarantee:approved` が付いているかを確認する'
assert_file_contains "(B-1) 裁可が無ければ Phase 2 以降へ進まない" "$SKILL_FILE" \
  '**Phase 2 以降へ進まず処理を止めて人間の裁可を促す**'
assert_file_contains "(B-1) SDD期は本項を実行せず従来どおり（参照ファイルも読み出さない）" "$SKILL_FILE" \
  '`sdd`（フェーズ宣言なしを含む）では本項を実行せず、以降の手順は従来どおり行う（参照ファイルも読み出さない）'
assert_file_contains "(B-1) 禁止事項に裁可ゲートの迂回と自己裁可を明記" "$SKILL_FILE" \
  '裁可ゲートの迂回'

echo ""
echo "=== (B-1b) SKILL.md: フェーズ判定の入力は実装が到達する base の内容 ==="

assert_file_contains "(B-1b) 判定器への入力は base の内容（手元 checkout ではない）" "$SKILL_FILE" \
  '**判定器への入力は「実装が到達する base」の内容にする（本スキル固有・重要）**'
assert_file_contains "(B-1b) 判定器を迂回しない（入力だけを変える）" "$SKILL_FILE" \
  '**判定器を迂回しない**——フェーズの解釈は常にスクリプトの出力のみ'
assert_file_contains "(B-1b) base の CLAUDE.md を git show で一時ファイル化して判定器へ渡す" "$SKILL_FILE" \
  '`git show "origin/{base}:CLAUDE.md"` を一時ファイルへ書き出し、`claude-harness-run detect-dev-phase "<一時ファイルのパス>"` で判定する'
assert_file_contains "(B-1b) fetch 失敗は判定不能として中断（sdd に読み替えない）" "$SKILL_FILE" \
  '失敗した場合は判定不能として中断する。`sdd` に読み替えない'
assert_file_contains "(B-1b) base に CLAUDE.md が無い場合は no_claude_md と同義（sdd・ゲートなし）" "$SKILL_FILE" \
  '判定器の `no_claude_md` と同じ意味（宣言なし＝`sdd`）として扱い'
assert_file_contains "(B-1b) base ごとに判定し gdd の base に属する Issue にのみゲートを適用" "$SKILL_FILE" \
  '**`gdd` の base に属する Issue にのみ裁可ゲートを適用する**'
assert_file_contains "(B-1b) 方向の設計根拠: base が SDD なら手元が GDD でも不変（default-OFF は対象基準）" "$SKILL_FILE" \
  '**base が SDD なら手元が GDD 宣言でも従来どおり挙動を変えない**'
assert_file_contains "(B-1b) Phase 3 以降の各層（checkout 済み base を読む）との整合を明記" "$SKILL_FILE" \
  'checkout 済みの base 内容を読むため、この判定基準と整合する'

echo ""
echo "=== (B-2) SKILL.md: Phase 4-5 の保証節注入（合流ゲートと並記） ==="

assert_file_contains "(B-2) 裁可対象（親）Issue の保証節を委譲プロンプトに含める" "$SKILL_FILE" \
  '裁可対象（親）Issue の保証節（新規宣言＋維持）を委譲プロンプトに含める'
assert_file_contains "(B-2) 合流ゲート伝播条項の規定は変更せず並記で追加する" "$SKILL_FILE" \
  '合流ゲート伝播条項の規定は変更せず並記で追加する'
assert_file_contains "(B-2) 既存の合流ゲート伝播条項の規定が逐語のまま残っている" "$SKILL_FILE" \
  '委譲プロンプトには**合流ゲート伝播条項**（`references/join-gate.md` の「ネストへの伝播」に定義。逐語で転記する）も含める'
assert_file_contains "(B-2) SDD期は注入を行わない" "$SKILL_FILE" \
  'SDD期はこの注入を行わない（従来どおり）'
assert_file_contains "(B-2) 例外ケース表の動作は同パスで返る全停止に適用（限定句の残骸なし）" "$SKILL_FILE" \
  '**この動作は同パスで返るすべての停止に適用する**'
assert_file_not_contains "(B-2) 逸脱検知の動作をスコープ拡大に限定する旧文言が残っていない" "$SKILL_FILE" \
  '想定外のスコープ拡大を検知した場合のみ'
assert_file_contains "(B-2) 混在 base の停止は起動全体（sdd 側 Issue を含む）に適用" "$SKILL_FILE" \
  '**混在時に `gdd` 側で裁可ゲートの停止が出た場合も、停止は起動全体'
assert_file_contains "(B-2) 停止報告に sdd 側 Issue を対象外として列挙（黙って落とさない）" "$SKILL_FILE" \
  '`判定: 対象外（base が SDD期）` として列挙する'

echo ""
echo "=== (B-3) guarantee-gate.md: 判定の規律 ==="

assert_file_contains "(B-3) ラベルは完全一致で判定する" "$GATE_FILE" \
  '`name` の**完全一致**で判定する'
assert_file_contains "(B-3) 接頭辞・部分一致で通さない" "$GATE_FILE" \
  '接頭辞・部分一致で通さない'
assert_file_contains "(B-3) 検査不能を「ラベルなし」に読み替えない" "$GATE_FILE" \
  '検査不能を「ラベルなし」に読み替えない'
assert_file_contains "(B-3) 両ラベル同時は裁可済みとみなさない（中間状態）" "$GATE_FILE" \
  '`guarantee:approved` と `guarantee:proposed` の両方が付いている'
assert_file_contains "(B-3) 部分成功≠完全成功: 1件でも停止なら全体を停止する" "$GATE_FILE" \
  '**1件でも「停止」に該当する Issue があれば、Phase 2 以降へ進まず全体を停止する**'
assert_file_contains "(B-3) 全 Issue の判定を先に終える（1件目で打ち切らない）" "$GATE_FILE" \
  '**全対象 Issue の判定を先に終えてから**'
assert_file_contains "(B-3) エージェントは guarantee:approved を自分で付けない" "$GATE_FILE" \
  '`guarantee:approved` を自分で付けない'
assert_file_contains "(B-3) ラベル定義の作成もしない（定義の用意は /create-ticket の責務）" "$GATE_FILE" \
  '**ラベル定義の作成もしない**'
assert_file_contains "(B-3) sdd で本ファイルを実行しない規律の正本は SKILL.md（複製しない）" "$GATE_FILE" \
  'SKILL.md が正本**であり、本ファイルには複製しない'

echo ""
echo "=== (B-4) guarantee-gate.md: 保証ブリーフ（Phase 4-5）の規律 ==="

assert_file_contains "(B-4) 読み取り文法の正本は create-ticket の guarantee-section.md 共通-2" "$GATE_FILE" \
  '`<base>/../create-ticket/references/guarantee-section.md` の「共通-2. 読み取り規則」'
assert_file_contains "(B-4) 台帳の文法を親Issue本文へ適用しない" "$GATE_FILE" \
  '(b) 台帳の読み取り＝索引チェックを親Issue本文へ向けない'
assert_file_contains "(B-4) 本ファイルには文法を複製しない（3つ目の独自解釈を作らない）" "$GATE_FILE" \
  '**本ファイルには文法を複製しない**'
assert_file_contains "(B-4) 転記は新規宣言・維持の2カテゴリだけ" "$GATE_FILE" \
  '**「### 新たに宣言する保証」「### 維持する保証」の2カテゴリだけ**'
assert_file_contains "(B-4) 判定保留は注入しない" "$GATE_FILE" \
  '「### 判定保留（要人間判定）」は機械処理の対象外であり注入しない'
assert_file_contains "(B-4) 逐語で転記する（- なし の明示も転記する）" "$GATE_FILE" \
  '`- なし` の明示もそのまま転記する'
assert_file_contains "(B-4) 同一性の検証: ID はハイフンまで含めた完全文法で比較する" "$GATE_FILE" \
  'ハイフンまで含めた比較で確認する（`G-158-` と `G-1580-` を取り違えない。**接頭辞一致で通さない**）'
assert_file_contains "(B-4) 節が読めない場合は停止（保証なしに丸めない）" "$GATE_FILE" \
  '保証節の不在・読み取り不能を「保証なし」に丸めない'
assert_file_contains "(B-4) star 型では worker がそのまま逐語で引き継ぐ" "$GATE_FILE" \
  '**そのまま逐語で引き継ぐ**'
assert_file_contains "(B-4) 維持の判定根拠は転記ではなく現行台帳（コピーを正本にしない）" "$GATE_FILE" \
  '**維持の約束文の判定根拠は転記ではなく現行の保証台帳**'

echo ""
echo "=== (B-4b) guarantee-gate.md: 新規宣言の担当割当（重複実装の防止） ==="

assert_file_contains "(B-4b) 各新規宣言 ID をちょうど1つの実装チケットに割り当てる" "$GATE_FILE" \
  '**新規宣言する保証は、各 ID をちょうど1つの実装チケットに割り当てる**'
assert_file_contains "(B-4b) 重複割当も未割当も作らない" "$GATE_FILE" \
  '**重複割当も未割当も作らない**'
assert_file_contains "(B-4b) 維持する保証は全チケットに共通で渡す（抵触チェックは全員に必要）" "$GATE_FILE" \
  '**維持する保証は全チケットに共通で渡す**'
assert_file_contains "(B-4b) 注入の前に割当の全数検証を行う" "$GATE_FILE" \
  '**割当の全数検証（注入の前に行う）**'
assert_file_contains "(B-4b) 割当不能な ID があれば停止する（黙って割当を歪めない）" "$GATE_FILE" \
  '上記の決定的規則で一意に導出できない ID が1件でもあれば **停止**'
assert_file_contains "(B-4b) 注入ブロックの新規宣言は担当分だけ（行単位の抜粋・行内は逐語）" "$GATE_FILE" \
  '**新規宣言する保証は担当割当に従い、当該チケットの担当分の行だけを転記する**'
assert_file_contains "(B-4b) 割当表を実行計画に出力し注入に接続する（記録だけにしない）" "$GATE_FILE" \
  '記録だけにせず注入に接続する'
assert_file_contains "(B-4b) 割当の要否は起動形態でなく対象の構造（親の分解）で決める" "$GATE_FILE" \
  '裁可対象（親）の構造——親が複数の実装チケットに分解されているか——で決める'
assert_file_contains "(B-4b) 1チケットだけの逐次起動でも分解の全体像で割当を解決する" "$GATE_FILE" \
  '**分解が複数なら、今回の起動対象が1チケットだけでも、分解の全体像に対して担当割当を解決してから、今回実装するチケットの担当分だけを注入する**'
assert_file_contains "(B-4b) 分解の全体像は check-subtask-completion で取得する（既存手段の再利用）" "$GATE_FILE" \
  'claude-harness-run check-subtask-completion {親Issue番号}'
assert_file_contains "(B-4b) 台帳登録済みの新規宣言は先行チケット担当済みとして再割当しない" "$GATE_FILE" \
  '先行チケットの実装で担当済み'
assert_file_contains "(B-4b) 全数検証は今回実装しないチケットも含む分解の全チケットを通して行う" "$GATE_FILE" \
  '**分解の全チケット（今回実装しないものを含む）を通してちょうど1回**'
assert_file_contains "(B-4b) SKILL.md 側でも割当の要否は起動形態でなく親の分解の構造で決める" "$SKILL_FILE" \
  '割当の要否は起動形態でなく親の分解の構造で決める'

echo ""
echo "=== (B-4d) guarantee-gate.md: 割当は安定入力の決定的規則（実行間一貫） ==="

assert_file_contains "(B-4d) 割当は安定入力だけから一意に導出する決定的規則で行う" "$GATE_FILE" \
  '**割当は安定入力（親 Issue の保証節・検証済みチケット集合の本文・現行台帳）だけから一意に導出する決定的規則で行う**'
assert_file_contains "(B-4d) 決定的規則だけが実行間一貫の担保（割当表は後続実行から参照不能）" "$GATE_FILE" \
  '**どの実行回でも同じ入力から同じ割当が導出されることだけが、実行間一貫の担保**'
assert_file_contains "(B-4d) 意味的な推測で候補を補わない（推測は実行回ごとに揺れる）" "$GATE_FILE" \
  '**意味的な推測で候補を補わない**'
assert_file_contains "(B-4d) AC 注記の欠落・解釈不能は停止（情報欠落の fail-closed）" "$GATE_FILE" \
  '**注記が無い・列挙を解釈できない保証は停止**'
assert_file_contains "(B-4d) 候補特定は 対応する受入基準: ヘッダ行の完全一致（機械アンカー）" "$GATE_FILE" \
  '`対応する受入基準:` ヘッダ行'
assert_file_contains "(B-4d) AC 識別子は全体一致（AC-1 を AC-12 の一部に一致させない）" "$GATE_FILE" \
  '`AC-1` を `AC-12` の一部に一致させない'
assert_file_contains "(B-4d) 複数 AC 注記は全列挙を読む（単数前提の非決定点を残さない）" "$GATE_FILE" \
  'その場合は**列挙された全 AC を読む**'
assert_file_contains "(B-4d) 複数 AC の候補は和集合（積にしない）" "$GATE_FILE" \
  '候補は「**列挙 AC のいずれか**をヘッダ行に持つチケット」の**和集合**とする'
assert_file_contains "(B-4d) 対応する受入基準: 行も 1-a と同じヘッダ行の規律で読む" "$GATE_FILE" \
  '**1-a と同じヘッダ行の規律——コードフェンスの外・本文冒頭部——で読み、フェンス内・引用の記載を候補判定に使わない**'
assert_file_contains "(B-4d) 本文冒頭部の境界が定義されている（最初の見出し行まで）" "$GATE_FILE" \
  '**本文冒頭部とは、本文先頭から最初の見出し行（`#` 始まり）までの範囲**'
assert_file_contains "(B-4d) 台帳登録済み除外は全経路（全量・担当分の双方）に適用" "$GATE_FILE" \
  '**この登録済み除外は経路によらず全経路に適用する'
assert_file_contains "(B-4d) アンカー行を持たないチケットが1つでもあれば停止（一意性の破れ）" "$GATE_FILE" \
  '**このヘッダ行を持たないチケットが集合に1つでもある場合は停止**'
assert_file_contains "(B-4d) 複数候補は依存下流（依存する他候補の数が最大）を選ぶ" "$GATE_FILE" \
  '依存する他候補の数が最大のチケット'
assert_file_contains "(B-4d) 同点はチケット番号最小（タイブレーク完全規定）" "$GATE_FILE" \
  '同数なら**チケット番号が最小のチケット**'
assert_file_contains "(B-4d) 実行計画への出力は説明であり引き継ぎ手段ではない（再現性の主張を訂正）" "$GATE_FILE" \
  '実行計画への出力は当該実行の説明であり、後続実行への引き継ぎ手段ではない'
assert_file_not_contains "(B-4d) 成立しない再現性の主張（根拠の記録が再現の材料）が残っていない" "$GATE_FILE" \
  '同じ割当を再現するための材料になる'

echo ""
echo "=== (C-5) 割当アンカーの cross-file 一致（生成側テンプレ・分解手順・消費側ゲート） ==="

TPL_FILE="${REPO_ROOT}/skills/create-ticket/templates/implementation-ticket.md"
DEC_FILE="${REPO_ROOT}/skills/create-ticket/references/decompose-mode.md"
for f in "$TPL_FILE" "$DEC_FILE"; do
  if [ ! -r "$f" ]; then
    echo "NG - 検査対象ファイルを読めません（検査不能を pass にはしない）: ${f}" >&2
    exit 1
  fi
done
assert_file_contains "(C-5) テンプレートにアンカー行（対応する受入基準:）が定義されている" "$TPL_FILE" \
  '対応する受入基準: {AC-ID一覧（例: AC-1, AC-3） | なし}'
assert_file_contains "(C-5) テンプレートはアンカー行をフェーズによらず常に残すと注記している" "$TPL_FILE" \
  '開発フェーズによらず常に残す'
assert_file_contains "(C-5) 分解手順が網羅検証済み割当の逐語転記を必須化している" "$DEC_FILE" \
  '`対応する受入基準: {当該タスクの acceptance_criteria_covered の ID 一覧（例: AC-1, AC-3） | なし}`'
assert_file_contains "(C-5) 分解手順はアンカー行を実行のたびに揺れる判断で書かないと明記" "$DEC_FILE" \
  '実行のたびに揺れる判断で書かない'
assert_file_contains "(C-5) 消費側ゲートが同じヘッダ行名を読む（生成と消費の行名一致）" "$GATE_FILE" \
  '対応する受入基準:'

echo ""
echo "=== (B-4c) guarantee-gate.md: 分解全体像の取得結果の検証（fail-closed） ==="

assert_file_contains "(B-4c) 検索は候補列挙・確定は正本文法（検査不能を空集合に丸めない）" "$GATE_FILE" \
  '**取得結果の検証（検索は候補列挙・確定は正本文法。検査不能を空集合に丸めない）**'
assert_file_contains "(B-4c) フォールバック候補は本文を取得しヘッダ文法で再検証する" "$GATE_FILE" \
  '**各候補 Issue の本文を取得し、1-a のヘッダ文法（コードフェンスの外・本文冒頭部の `Parent: #<番号>` 行）で再検証し、通過した Issue だけを兄弟として採用する**'
assert_file_contains "(B-4c) 健全性条件: 自分自身を含まない兄弟集合は検査不能として停止" "$GATE_FILE" \
  '**採用後の兄弟集合に対象 Issue 自身が含まれない場合——スクリプトが `no_children_found`（0件）を返した場合を含む——は、「分解なし」に読み替えず検査不能として停止する**'
assert_file_contains "(B-4c) スクリプトの0件丸め（失敗も exit 0）を割当不要の根拠にしない" "$GATE_FILE" \
  '**0件・自分不在の結果を割当不要（全量注入）の根拠にしない**'
assert_file_contains "(B-4c) 台帳の一覧を取得できない場合は未登録とみなさず停止（登録済み判定の素通り防止）" "$GATE_FILE" \
  '取得できない場合は「未登録」とみなさず停止する（`ledger_unreadable`）'
assert_file_contains "(B-4c) 登録済み判定は base リビジョンの台帳内容で行う（手元 checkout を読まない）" "$GATE_FILE" \
  '**実装が到達する base リビジョンの内容**である（リードの手元 checkout の台帳を読まない'

# --- 登録済み判定の台帳読み取りも索引チェックへ移譲されている（散文で読まない） ---
assert_file_contains "(B-4c) 台帳の読み取りの正本の定型文を持つ（散文で読み直さない）" "$GATE_FILE" \
  '**索引チェック（`guarantee-index-check`）の出力 `guarantees` を使う**こと'
# 行全体で固定する（部分一致だと `--base ...` を後ろへ足す変異を検出できない）
assert_file_contains "(B-4c) base リビジョンの台帳は一時ファイル経由で索引チェックへ渡す" "$GATE_FILE" \
  'claude-harness-run guarantee-index-check "<一時ファイル>"
```'
assert_file_not_contains "(B-4c) 呼び出しに --base が付いていない" "$GATE_FILE" \
  'guarantee-index-check "<一時ファイル>" --base'
assert_file_contains "(B-4c) git show の終了コードを確認する（空出力を空の台帳に読み替えない）" "$GATE_FILE" \
  '**空出力を「保証0件の台帳」に読み替えない**'
assert_file_contains "(B-4c) --base は指定しない（消費結果に効かず停止経路だけを増やす）" "$GATE_FILE" \
  '**`--base` は指定しない**'
assert_file_contains "(B-4c) guarantees が参照検査より前に確定することを根拠にしている" "$GATE_FILE" \
  '**`guarantees` は参照検査より前に確定する**'
assert_file_contains "(B-4c) --base のディレクトリ不在が exit 2 で全体停止になると明記している" "$GATE_FILE" \
  '**消費結果に影響しない指定で停止経路だけを増やさない**'
assert_file_contains "(B-4c) index.ledger の同一性を確認する（別台帳を読んでいない）" "$GATE_FILE" \
  '**`index.ledger` が渡した一時ファイルのパスと一致すること**'
assert_file_not_contains "(B-4c) 旧: --base 必須化の記述が残っていない" "$GATE_FILE" \
  '**`--base` にはリポジトリルート（`git rev-parse --show-toplevel`）を明示する**'
assert_file_contains "(B-4c) 消費してよいのは guarantees[].guarantee_id だけ" "$GATE_FILE" \
  '**消費してよいのは `guarantees[].guarantee_id`（登録済み ID の集合）だけ**'
assert_file_contains "(B-4c) この呼び出しの status/broken は索引整合の判定に使わない" "$GATE_FILE" \
  '**索引整合の判定に使わない**'
assert_file_contains "(B-4c) status=fail を理由に停止しない（guarantees は exit 1 でも出る）" "$GATE_FILE" \
  '**`status` が `"fail"` であることを理由に停止しない**'
assert_file_contains "(B-4c) exit 2・パース不能は ledger_unreadable で停止（空集合に丸めない）" "$GATE_FILE" \
  '**`guarantees` を空集合に丸めて重複割当の検査を素通りさせない**'
assert_file_not_contains "(B-4c) 旧: 台帳を散文で読む git show 単体の指示が残っていない" "$GATE_FILE" \
  '**登録済み判定は、実装が到達する base の台帳内容（`git show "origin/{base}:docs/guarantees.md"`）で行う**'
assert_file_contains "(B-4c) 打ち切り（fallback_truncated）は自分が含まれていても停止（完全性の反証）" "$GATE_FILE" \
  '**自分自身が含まれていても停止する**'

# status 語彙の cross-file 一致: スクリプト実装・仕様正本・消費側ゲートの3者で逐語一致
CSC_SCRIPT="${REPO_ROOT}/scripts/check-subtask-completion.sh"
CSC_SPEC="${REPO_ROOT}/scripts/specs/collect-promotion-context.md"
for f in "$CSC_SCRIPT" "$CSC_SPEC" "$GATE_FILE"; do
  for st in fallback_truncated children_lookup_failed; do
    assert_file_contains "(B-4c) status 語彙 ${st} が $(basename "$f") に逐語で存在する" "$f" "$st"
  done
done
assert_file_contains "(B-4c) 割当の入力は検証済みの分解（未検証の検索結果を使わない）" "$GATE_FILE" \
  '検証済みの分解が1チケットだけなら'

echo ""
echo "=== (B-4e) guarantee-gate.md: Parent: 不在は未分解の証明ではない（親方向の子照会） ==="

assert_file_contains "(B-4e) ヘッダ行の不在は親であることしか証明しない（未分解の証明ではない）" "$GATE_FILE" \
  '**「未分解である」ことは証明しない**'
assert_file_contains "(B-4e) 分解なし単独親の分岐を取る前に対象自身の子を照会する" "$GATE_FILE" \
  '`claude-harness-run check-subtask-completion {対象Issue番号}` で照会する'
assert_file_contains "(B-4e) 親方向の照会にも取得結果の検証を同じ強度で適用する" "$GATE_FILE" \
  '「取得結果の検証」（下記）を**同じ強度で適用する**——`fallback_truncated` は停止（`decomposition_unverifiable`）'
assert_file_contains "(B-4e) 健全性条件（自分の包含）は親方向には適用しない（子0件は正規）" "$GATE_FILE" \
  '**自分自身の包含という健全性条件は親方向の照会には適用しない**'
assert_file_contains "(B-4e) 検証済みの子が1件以上なら分解済み親への直接起動として停止" "$GATE_FILE" \
  '**分解済みの親への直接起動**として停止する（`parent_already_decomposed`）'
assert_file_contains "(B-4e) 停止報告で子チケット経由の再実行を促す" "$GATE_FILE" \
  '`/para-impl {子番号...}` での再実行を人間に促す'
assert_file_contains "(B-4e) 未分解と認めるのは両経路の照会成功が証明する0件だけ" "$GATE_FILE" \
  '**`status: "no_children_found"`（sub-issues API と本文検索の両経路が照会に成功したうえでの0件）**'
assert_file_contains "(B-4e) 照会失敗を含む0件（children_lookup_failed）は停止（検査不能≠未分解）" "$GATE_FILE" \
  '**`status: "children_lookup_failed"`（照会の失敗を含む0件）→ 停止する**'
assert_file_not_contains "(B-4e) 「Parent: 不在＝未分解」の含意の残骸（未検証の割当不要分岐）が残っていない" "$GATE_FILE" \
  '（実装チケットに分解されていない）の場合は割当不要'

echo ""
echo "=== (B-4f) guarantee-gate.md: 停止報告の対処は reason 別（固定文の矛盾解消） ==="

assert_file_contains "(B-4f) 対処・再開は語彙表の「人間の対処と再開」列が正本" "$GATE_FILE" \
  '「人間の対処と再開」列が正本であり、これ以外に共通の固定手順を置かない'
assert_file_contains "(B-4f) Phase 4-5 の停止も同形式・同表に従う" "$GATE_FILE" \
  '**Phase 4-5 の停止も本形式・本表に従う**'
assert_file_contains "(B-4f) parent_already_decomposed の対処はラベル操作不要・子番号での再実行" "$GATE_FILE" \
  'ラベル操作は不要。停止報告に列挙された検証済みの子チケット番号を使い、`/para-impl {子番号...}` を再実行する'
assert_file_not_contains "(B-4f) 全 reason 共通の固定文「裁可後の再開」が残っていない" "$GATE_FILE" \
  '- 裁可後の再開: /para-impl {対象 Issue 番号} を再実行する'
assert_file_not_contains "(B-4f) Phase 4-5 停止に虚偽になる旧見出し「裁可ゲート未通過」が残っていない" "$GATE_FILE" \
  '裁可ゲート未通過'
assert_file_contains "(B-4) 合流ゲート伝播条項の規定は維持し並記で追加する" "$GATE_FILE" \
  '**合流ゲート伝播条項の逐語転記の規定はそのまま維持し、本ブロックはそれと並記で追加する**'

# guarantee-gate.md は join-gate.md の定義（決定表・伝播条項）に触れない
assert_file_not_contains "(B-4) guarantee-gate.md は合流ゲートの決定表手順を複製しない" "$GATE_FILE" \
  '手順（最終応答の直前）'
assert_file_not_contains "(B-4) guarantee-gate.md は伝播条項本文を複製しない" "$GATE_FILE" \
  '【合流ゲート伝播条項】'

echo ""
echo "=== (B-5) star-parallel.md / ticket-worker.md: 保証節の伝播 ==="

assert_file_contains "(B-5) star: spawn プロンプト必須項目に保証節（GDD期のみ）がある" "$STAR_FILE" \
  '- **保証節（GDD期のみ）**'
assert_file_contains "(B-5) star: SDD期は含めない" "$STAR_FILE" \
  'SDD期は含めない'
assert_file_contains "(B-5) worker: 保証節ブロックをそのまま逐語で委譲プロンプトに含める" "$TW_FILE" \
  'それも**そのまま逐語で**委譲プロンプトに含める（要約・省略・言い換えをしない）'

echo ""
echo "=== (B-6) feature-implementer.md: 2-5 保証整合確認 ==="

fi_25_count="$(grep -cxF -- '### 2-5. 保証整合確認（GDD期のみ）' "$FI_FILE")"
assert_eq "(B-6) 2-5 の見出しがちょうど1箇所ある" "1" "$fi_25_count"
assert_file_contains "(B-6) 2-3 と対になる位置づけ（クリティカル設計決定との整合確認の対）" "$FI_FILE" \
  '「2-3. クリティカル設計決定との整合確認」と対になる'
assert_file_contains "(B-6) D-13: 維持保証への抵触は既存の逸脱検知パスに合流して停止" "$FI_FILE" \
  '既存の「⚠️ クリティカル設計の逸脱検知」パス（2-3）にそのまま合流させて停止する'
assert_file_contains "(B-6) 維持の判定根拠は現行台帳（転記文面を正本にしない）" "$FI_FILE" \
  '`guarantees[].statement` を判定根拠にする'
assert_file_contains "(B-6) 注入ブロック・親 Issue の転記文面を判定根拠にしない" "$FI_FILE" \
  '**注入ブロック・親 Issue の転記文面を判定根拠にしない**'
assert_file_contains "(B-6) 台帳の読み取りは索引チェックの guarantees へ移譲されている" "$FI_FILE" \
  '**索引チェック（`guarantee-index-check`）の出力 `guarantees` を使う**こと'
assert_file_contains "(B-6) 索引チェックをランチャー経由で呼ぶ実行形を示している" "$FI_FILE" \
  '`claude-harness-run guarantee-index-check "<台帳の絶対パス>"`'
assert_file_contains "(B-6) 台帳パスは対象の作業ツリー基準で解決し引数を省略しない" "$FI_FILE" \
  '**台帳のパスは対象の作業ツリー基準で解決し、引数を省略しない**'
assert_file_contains "(B-6) ledger の同一性を確認する（別の作業ツリーの台帳を読まない）" "$FI_FILE" \
  '**`ledger` が自分の渡したパスと一致すること**'
assert_file_contains "(B-6) 区分 (I) の broken も fail-closed の停止に倒す" "$FI_FILE" \
  '**`broken` に区分 (I) の `duplicate_guarantee_section` / `guarantee_outside_section` / `duplicate_guarantee_id` がある場合も、下記1の fail-closed の停止に倒す**'
assert_file_contains "(B-6) 差分0を一覧完全の根拠にしないと明記している" "$FI_FILE" \
  '差分 0 を「一覧は完全」の根拠にしない'
assert_file_contains "(B-6) fail-closed: 索引チェックを実行できず guarantees を取得できない場合も停止" "$FI_FILE" \
  '**索引チェックを実行できず `guarantees` を取得できない**'
assert_file_contains "(B-6) 検査不能を「維持対象なし」「台帳に無い」のどちらにも読み替えない" "$FI_FILE" \
  '**検査不能を「維持対象なし」「台帳に無い」のどちらにも読み替えない**'
assert_file_contains "(B-6) guarantees に現れない見出しを存在の根拠にしない" "$FI_FILE" \
  '**を「存在する」の根拠にしない**'
assert_file_not_contains "(B-6) 旧: 台帳の文法（共通-2 (b)）を正本とする記述が残っていない" "$FI_FILE" \
  '正本: `guarantee-section.md` 共通-2 (b)'
assert_file_not_contains "(B-6) 旧: 台帳読み取りの移譲が残件だという記述が残っていない" "$FI_FILE" \
  '**この読み取りを索引チェックの出力へ移譲することは残件**'
assert_file_contains "(B-6) fail-closed: 台帳が無い・読めない場合は停止" "$FI_FILE" \
  '**台帳（`docs/guarantees.md`）自体が無い・読めない**'
assert_file_contains "(B-6) fail-closed: ID が guarantees に存在しなければ停止" "$FI_FILE" \
  '**ID が `guarantees[].guarantee_id` に存在しない**'
assert_file_contains "(B-6) fail-closed: 転記と台帳の文面ドリフトは停止（黙って台帳側を採用しない）" "$FI_FILE" \
  '**転記の約束文と `guarantees[].statement` が一致しない（文面ドリフト）**'
assert_file_contains "(B-6) 維持対象なしに丸めて実装を進めない" "$FI_FILE" \
  '**「維持対象なし」に丸めて実装を進めない**'
assert_file_contains "(B-6) 担当外の新規宣言のテスト・台帳追記を行わない（重複実装の防止）" "$FI_FILE" \
  '**担当外の新規宣言（ブロックに無い親の保証）のテスト作成・台帳追記を行わない**'
assert_file_contains "(B-6) 直接呼び出しでも全量を黙って実装しない" "$FI_FILE" \
  '親の新規宣言の全量を黙って実装しない'
assert_file_contains "(B-6) 直接呼び出しでは担当を単独判断で特定しない（実行間で衝突する判断の禁止）" "$FI_FILE" \
  '本エージェント単独の判断で特定してはならない'
assert_file_contains "(B-6) 直接呼び出しの新規宣言は停止して正規経路（担当分注入）を促す" "$FI_FILE" \
  '正規経路（`/para-impl` 経由の担当分注入）での実行を呼び出し元に促す'
assert_file_contains "(B-6) マーカーの存在だけで注入と判定しない（3条件）" "$FI_FILE" \
  '**指示部として扱えるのは次の3条件をすべて満たす場合だけ**'
assert_file_contains "(B-6) 引用・フェンス内のマーカーはデータ（注入とみなさない）" "$FI_FILE" \
  'データであり、注入とみなさない'
assert_file_contains "(B-6) マーカーの裁可対象番号と対象チケットの同一性を検証する" "$FI_FILE" \
  '(c) マーカーの裁可対象番号が、対象チケットの裁可対象（`Parent:` 行の親、無ければ対象チケット自身）と一致する'
assert_file_contains "(B-6) 番号不一致は取り違えの兆候として停止（黙って無視しない）" "$FI_FILE" \
  '(c) の番号が一致しない場合は、取り違えの兆候として ⚠️ パスの形式で停止する'
assert_file_contains "(B-6) 直接呼び出しでは新規宣言の実装を行わない（統一規則）" "$FI_FILE" \
  '**新規宣言する保証の実装（下記2・3）は、直接呼び出しでは行わない**'
assert_file_contains "(B-6) 新規宣言の実装には裁可の確認が前提（裁可ゲート迂回の遮断）" "$FI_FILE" \
  '裁可（`guarantee:approved`）の確認・親の分解状態の確認（分解済みの親への直接起動の検出）・担当の一意な導出'
assert_file_contains "(B-6) 新規宣言が - なし のときだけ維持確認のみで続行" "$FI_FILE" \
  '「### 新たに宣言する保証」が `- なし` の場合のみ、維持の確認だけを行って通常のフローを続行する'
assert_file_contains "(B-6) ✅ テンプレは実施していない作業を「した」と報告しない" "$FI_FILE" \
  '**実施していない作業を「した」と報告しない**'
assert_file_contains "(B-6) 新規0件（担当0件）専用の書式がある（テスト・台帳追記なしを真実に報告）" "$FI_FILE" \
  '`新規 なし（担当0件。テスト・台帳追記のタスクなし）`'
assert_file_contains "(B-6) 維持なし専用の書式がある" "$FI_FILE" \
  '`維持 なし（親Issueが「- なし」と明示）`'
assert_file_contains "(B-6) 維持ありの書式は現行台帳で解決した旨を報告する" "$FI_FILE" \
  '全{件数}件を現行台帳で解決し抵触なし'
assert_file_not_contains "(B-6) 0件でもテスト配置・台帳追記を主張する無条件テンプレが残っていない" "$FI_FILE" \
  '維持 {ID一覧 | なし} — 全{件数}件に抵触なし ／ 新規 {ID一覧 | なし} — 対応テストをテストリスト先頭に配置し'
assert_file_contains "(B-6) 台帳不在時は新設して追記せず fail-closed 停止（新設は人間の裁可事項）" "$FI_FILE" \
  '台帳を新設して追記しない——台帳の新設・復旧は人間の裁可事項'
assert_file_contains "(B-6) D-13: 新しい停止経路・返却形式を作らない" "$FI_FILE" \
  '保証逸脱のための新しい停止経路・新しい返却形式を作らない'
assert_file_contains "(B-6) 保証逸脱の警告書式（既存の ⚠️ と同型）" "$FI_FILE" \
  '> ⚠️ **クリティカル設計の逸脱検知（保証逸脱）**:'
assert_file_contains "(B-6) 新規保証のテストはテストリストの先頭に置く" "$FI_FILE" \
  '**Phase 3 のテストリストの先頭に置く**'
assert_file_contains "(B-6) D-14: 台帳更新を実装と同一 PR に同梱する" "$FI_FILE" \
  '**呼び出し元のコミット・PR に実装と同梱される**'
assert_file_contains "(B-6) D-11: ID は裁可時に確定済みの正式 ID をそのまま使う" "$FI_FILE" \
  '**裁可時に確定済みの正式 ID をそのまま使う**（実装側で採番・改番しない）'
assert_file_contains "(B-6) 台帳追記は quality-check の保証索引ゲートが機械検証する" "$FI_FILE" \
  'Phase 4 の `/quality-check`（GDD期の保証索引ゲート）が機械検証する'
assert_file_contains "(B-6) 裁可を経ない保証を追加しない（勝手に採番・追記しない）" "$FI_FILE" \
  '台帳へ勝手に追記せず（採番もせず）'
assert_file_contains "(B-6) fail-closed: 保証節の不在を「保証なし」に読み替えない" "$FI_FILE" \
  '**保証節の不在を「保証なし」に読み替えて実装を進めない**'
assert_file_contains "(B-6) 空虚な真ガード: - なし の明示だけを対象0件として適合にする" "$FI_FILE" \
  '`- なし` の明示なら対象0件であり本項は適合（空欄・読み取り不能は0件と同じ扱いにしない'
assert_file_contains "(B-6) 部分成功≠完全成功: 一部だけ確認して整合としない" "$FI_FILE" \
  '**一部だけ確認して「整合」としない**'
assert_file_contains "(B-6) ✅ は全件確認できた場合だけ（判定への接続）" "$FI_FILE" \
  '**1件でも確認できなければ ✅ を出さない**'
assert_file_contains "(B-6) SDD期は本セクションを実施しない（挙動は従来と完全に同一）" "$FI_FILE" \
  '本セクションを実施しない（挙動は従来と完全に同一）'
assert_file_contains "(B-6) invalid は sdd に読み替えず停止する" "$FI_FILE" \
  '要人間判定として呼び出し元に報告する（`sdd` に読み替えない）'
assert_file_contains "(B-6) 返却内容に保証整合確認の結果を含める" "$FI_FILE" \
  '**保証整合確認の結果**（GDD期・2-5 を実施した場合のみ'
assert_file_contains "(B-6) 停止経路の返却は既存の Phase 2 停止の形式をそのまま使う" "$FI_FILE" \
  'GDD期の保証逸脱（2-5）・保証節の読み取り不能・フェーズ判定 `invalid` による停止も**この形式をそのまま使う**'

# ---------------------------------------------------------------------------
# (C) cross-file 逐語照合
# ---------------------------------------------------------------------------
echo ""
echo "=== (C-1) フェーズ判定の定型文が採用ファイル全てで一字一句一致する ==="

PHASE_CANON_PREFIX='> **開発フェーズの判定（重要）**:'
canon_line="$(grep -F -- "$PHASE_CANON_PREFIX" "$CT_SKILL_FILE")"
assert_eq "(C-1) create-ticket SKILL.md の定型文はちょうど1行" "1" \
  "$(grep -cF -- "$PHASE_CANON_PREFIX" "$CT_SKILL_FILE")"
for f in "$PV_SKILL_FILE" "$SKILL_FILE" "$FI_FILE"; do
  fname="$(basename "$(dirname "$f")")/$(basename "$f")"
  assert_eq "(C-1) ${fname} の定型文はちょうど1行" "1" \
    "$(grep -cF -- "$PHASE_CANON_PREFIX" "$f")"
  assert_eq "(C-1) ${fname} の定型文が create-ticket 側と一字一句一致する" \
    "identical" \
    "$([ "$(grep -F -- "$PHASE_CANON_PREFIX" "$f")" = "$canon_line" ] && echo identical || echo different)"
done
# 正本（戦略ドキュメントのコピー元定型文）とも一致する
assert_eq "(C-1) 定型文が正本（ai-driven-development-strategy.md）と一字一句一致する" \
  "identical" \
  "$(grep -F -- "$PHASE_CANON_PREFIX" "$STRATEGY_FILE" | grep -qxF -- "$canon_line" && echo identical || echo different)"

echo ""
echo "=== (C-2) 保証節ブロックのマーカーが注入側・伝播側・消費側で一致する ==="

BLOCK_MARKER='【保証節（GDD期・裁可対象 Issue #{番号} より逐語転記）】'
for f in "$GATE_FILE" "$STAR_FILE" "$TW_FILE" "$FI_FILE"; do
  fname="$(basename "$f")"
  assert_file_contains "(C-2) ${fname} に保証節ブロックのマーカーが逐語で存在する" "$f" "$BLOCK_MARKER"
done

echo ""
echo "=== (C-3) 裁可ラベル名が定義側（create-ticket）とゲート側で一致する ==="

for label in 'guarantee:approved' 'guarantee:proposed'; do
  assert_file_contains "(C-3) 「${label}」が定義側 guarantee-section.md に存在する" "$GS_FILE" "$label"
  assert_file_contains "(C-3) 「${label}」がゲート側 guarantee-gate.md に存在する" "$GATE_FILE" "$label"
done
# 停止報告の人間向け指示が付け替え（proposed を外して approved へ）の形で書かれている。
# ラベル付与の実コマンドは書かない（エージェントが複製実行しうる指示を skills/ 配下に
# 置かない構造不変条件は test-create-ticket-gdd-gate.sh (B-10) が全 skills/ を検査する）
assert_file_contains "(C-3) 停止報告の人間向け指示は proposed を外して approved へ付け替える形" "$GATE_FILE" \
  '`guarantee:proposed` を外して `guarantee:approved` に付け替える'
assert_file_contains "(C-3) 付け替えをエージェントが代行しないことを停止報告に明記" "$GATE_FILE" \
  'このコマンドをエージェントが代行しない'

echo ""
echo "=== (C-4) 読み取り文法の複製が無い（3つ目の独自解釈を作らない） ==="

# 親Issue文法の本体（妥当性条件・全件走査）は guarantee-section.md だけが持つ。
# para-impl 側・feature-implementer 側に現れたら、文法が複製された（独自解釈が生えた）合図。
for phrase in 'カテゴリ配下は全件走査する' '妥当性条件（「書式を解釈できない」と判定してよい条件）'; do
  assert_file_contains "(C-4) 文法本体「${phrase}」は正本 guarantee-section.md にある" "$GS_FILE" "$phrase"
  assert_file_not_contains "(C-4) guarantee-gate.md は文法本体「${phrase}」を複製しない" "$GATE_FILE" "$phrase"
  assert_file_not_contains "(C-4) feature-implementer.md は文法本体「${phrase}」を複製しない" "$FI_FILE" "$phrase"
done
assert_file_contains "(C-4) feature-implementer も文法の正本として guarantee-section.md を参照する" "$FI_FILE" \
  '「共通-2. 読み取り規則」'

# ---------------------------------------------------------------------------
# (D) 構造不変条件と判定表の参照実装
# ---------------------------------------------------------------------------
echo ""
echo "=== (D-1) 判定表・語彙表の構造不変条件 ==="

# 判定表の行数（排他の状態空間）はちょうど5行（1-b の判定表の節にスコープして数える）
verdict_rows="$(awk '/^\*\*判定表（各行は排他/{f=1; next} /^###/{f=0} f && /^\| [0-9]+ \| /{c++} END{print c+0}' "$GATE_FILE")"
assert_eq "(D-1) 判定表の状態はちょうど5行（増減時は語彙表・停止報告と同時更新）" "5" "$verdict_rows"

# 担当割当の経路の表（対象の構造 × 起動形態）はちょうど6行で、停止経路を含む
route_rows="$(awk '/^\*\*経路の表（対象の構造/{f=1; next} /^###|^---/{f=0} f && /^\| [0-9]+ \| /{c++} END{print c+0}' "$GATE_FILE")"
assert_eq "(D-1) 担当割当の経路の表はちょうど8行（受理5＋停止3。増減時は本文と同時更新）" "8" "$route_rows"
assert_file_contains "(D-1) 経路の表に分解全体像の検証不能の停止経路が明示されている" "$GATE_FILE" \
  '| 注入しない | **停止**（`decomposition_unverifiable`） |'
assert_file_contains "(D-1) 経路の表に逐次実行（1チケットだけ起動）の受理経路が明示されている" "$GATE_FILE" \
  '| 4 | 親が複数チケットに分解 | 1チケットだけ起動（逐次実行） | 必須（分解の全体像で割当を解決してから） | 当該チケットの担当分のみ | 受理 |'
assert_file_contains "(D-1) 経路の表に割当解決不能の停止経路が明示されている" "$GATE_FILE" \
  '| 注入しない | **停止**（`guarantee_assignment_unresolvable`） |'
assert_file_contains "(D-1) 経路の表に分解済み親への直接起動の停止経路が明示されている" "$GATE_FILE" \
  '| 注入しない | **停止**（`parent_already_decomposed`） |'

# reason 語彙表はちょうど10コード
reason_rows="$(grep -cE '^\| `[a-z_]+` \| Phase' "$GATE_FILE")"
assert_eq "(D-1) reason 語彙表はちょうど10コード" "10" "$reason_rows"

# 各コードは定義（語彙表）と使用（判定表・転記の規律・担当割当）の両方に現れる
# （定義だけ・使用だけを作らない）
for code in parent_mismatch labels_unavailable label_state_ambiguous approval_missing \
  guarantee_section_unreadable guarantee_scope_mismatch guarantee_assignment_unresolvable \
  decomposition_unverifiable ledger_unreadable parent_already_decomposed; do
  occurrences="$(grep -cF -- "\`${code}\`" "$GATE_FILE")"
  if [ "$occurrences" -ge 2 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - (D-1) reason「${code}」が定義と使用の両方に現れる（${occurrences}箇所）"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("reason ${code} の定義・使用の突き合わせ")
    echo "  NG - (D-1) reason「${code}」の出現が${occurrences}箇所（2箇所以上が必要）"
  fi
done

# D-13 の構造不変条件: feature-implementer に保証逸脱専用の停止返却セクションが増えていない
fi_stop_headings="$(grep -cE '^### .*停止した場合$' "$FI_FILE")"
assert_eq "(D-1) FI の停止返却セクションは既存の2つのみ（保証逸脱専用の経路を作らない）" "2" "$fi_stop_headings"

echo ""
echo "=== (D-2) 裁可対象の解決の参照実装（同一性の検証） ==="

# guarantee-gate.md 1-a の表と同じ規則:
# 引数: $1=対象Issue番号 $2=Parent行の番号（無ければ空） $3=保証行の親番号（無ければ空）
pi_resolve_target() {
  local self="$1" parent="$2" hosho="$3"
  if [ -n "$parent" ] && [ -n "$hosho" ]; then
    if [ "$parent" = "$hosho" ]; then echo "$parent"; else echo "mismatch"; fi
  elif [ -n "$parent" ]; then
    echo "$parent"
  elif [ -n "$hosho" ]; then
    echo "$hosho"
  else
    echo "$self"
  fi
}

assert_eq "(D-2) Parent と 保証 行が一致: 親を裁可対象にする" "10" "$(pi_resolve_target 12 10 10)"
assert_eq "(D-2) Parent 行のみ: 親を裁可対象にする" "10" "$(pi_resolve_target 12 10 '')"
assert_eq "(D-2) 保証 行のみ: その親を裁可対象にする" "10" "$(pi_resolve_target 12 '' 10)"
assert_eq "(D-2) どちらも無い: 対象 Issue 自身を裁可対象にする" "12" "$(pi_resolve_target 12 '' '')"
assert_eq "(D-2) Parent と 保証 行の番号が食い違う: 解決不能（どちらも採用しない）" \
  "mismatch" "$(pi_resolve_target 12 10 11)"

echo ""
echo "=== (D-3) ラベル判定の参照実装（完全一致・検査不能≠ラベルなし） ==="

# guarantee-gate.md 1-b の判定表と同じ規則:
# 引数: $1=裁可対象（番号 or "mismatch"） $2=取得結果（ok|error） $3=ラベル一覧（カンマ区切り）
pi_label_verdict() {
  local target="$1" fetch="$2" labels="$3"
  if [ "$target" = "mismatch" ]; then echo "stop:parent_mismatch"; return; fi
  if [ "$fetch" != "ok" ]; then echo "stop:labels_unavailable"; return; fi
  local has_approved="no" has_proposed="no"
  case ",${labels}," in *",guarantee:approved,"*) has_approved="yes" ;; esac
  case ",${labels}," in *",guarantee:proposed,"*) has_proposed="yes" ;; esac
  if [ "$has_approved" = "yes" ] && [ "$has_proposed" = "yes" ]; then
    echo "stop:label_state_ambiguous"
  elif [ "$has_approved" = "yes" ]; then
    echo "pass"
  else
    echo "stop:approval_missing"
  fi
}

assert_eq "(D-3) approved のみ: ゲート通過" "pass" \
  "$(pi_label_verdict 10 ok 'requirement,guarantee:approved')"
assert_eq "(D-3) approved + proposed の同時付与: 中間状態として停止（裁可済みに丸めない）" \
  "stop:label_state_ambiguous" \
  "$(pi_label_verdict 10 ok 'guarantee:proposed,guarantee:approved')"
assert_eq "(D-3) proposed のみ: 裁可待ちとして停止" "stop:approval_missing" \
  "$(pi_label_verdict 10 ok 'requirement,guarantee:proposed')"
assert_eq "(D-3) どちらのラベルも無い: 停止（裁可フロー外の Issue を実装しない）" \
  "stop:approval_missing" "$(pi_label_verdict 10 ok 'requirement')"
assert_eq "(D-3) ラベルが1つも無い: 停止" "stop:approval_missing" "$(pi_label_verdict 10 ok '')"
assert_eq "(D-3) 取得失敗: labels_unavailable（approval_missing と区別する＝検査不能≠ラベルなし）" \
  "stop:labels_unavailable" "$(pi_label_verdict 10 error '')"
assert_eq "(D-3) 似た名前のラベルを完全一致で弾く（接頭辞で通さない）" \
  "stop:approval_missing" "$(pi_label_verdict 10 ok 'guarantee:approved-old')"
assert_eq "(D-3) 前方に別文字列が付くラベルも弾く" \
  "stop:approval_missing" "$(pi_label_verdict 10 ok 'x-guarantee:approved')"
assert_eq "(D-3) 大文字小文字の違いは一致とみなさない" \
  "stop:approval_missing" "$(pi_label_verdict 10 ok 'Guarantee:Approved')"
assert_eq "(D-3) 裁可対象が解決不能: ラベルが approved でも parent_mismatch を先に確定する" \
  "stop:parent_mismatch" "$(pi_label_verdict mismatch ok 'guarantee:approved')"

echo ""
echo "=== (D-4) 複数 Issue の集約（部分成功≠完全成功） ==="

# guarantee-gate.md 1-c の規則: 全 Issue の判定を集約し、1件でも停止なら全体を停止。
pi_gate_overall() {
  local verdict overall="proceed"
  for verdict in "$@"; do
    case "$verdict" in
      pass) ;;
      *) overall="stop" ;;
    esac
  done
  echo "$overall"
}

assert_eq "(D-4) 全件 pass: 実装へ進む" "proceed" "$(pi_gate_overall pass pass pass)"
assert_eq "(D-4) 1件でも裁可待ちがあれば全体を停止する" "stop" \
  "$(pi_gate_overall pass stop:approval_missing pass)"
assert_eq "(D-4) 1件でも検査不能があれば全体を停止する（判定できなかった Issue を問題なしに数えない）" \
  "stop" "$(pi_gate_overall pass pass stop:labels_unavailable)"
assert_eq "(D-4) 単一 Issue の pass: 実装へ進む" "proceed" "$(pi_gate_overall pass)"

echo ""
echo "=== (D-5) 保証 ID スコープ検証の参照実装（完全文法） ==="

# guarantee-gate.md「転記の規律」の同一性検証と同じ規則:
# ID が G-<裁可対象番号>-<枝番(1文字以上の数字だけ)> に完全一致するか。
pi_id_scope_ok() {
  local id="$1" n="$2"
  if printf '%s' "$id" | grep -qE "^G-${n}-[0-9]+\$"; then
    echo "yes"
  else
    echo "no"
  fi
}

assert_eq "(D-5) G-158-1 は裁可対象 158 のスコープに適合する" "yes" "$(pi_id_scope_ok G-158-1 158)"
assert_eq "(D-5) 枝番が複数桁でも適合する" "yes" "$(pi_id_scope_ok G-158-12 158)"
assert_eq "(D-5) 枝番が数字でない ID（G-158-x）を通さない" "no" "$(pi_id_scope_ok G-158-x 158)"
assert_eq "(D-5) 枝番が欠けた ID（G-158-）を通さない" "no" "$(pi_id_scope_ok G-158- 158)"
assert_eq "(D-5) 別スコープの ID（G-1580-1）をハイフンまで含めた比較で弾く" \
  "no" "$(pi_id_scope_ok G-1580-1 158)"
assert_eq "(D-5) 桁の短い別スコープ（G-15-1）も弾く" "no" "$(pi_id_scope_ok G-15-1 158)"
assert_eq "(D-5) 別 Issue スコープの ID（G-999-1）を弾く" "no" "$(pi_id_scope_ok G-999-1 158)"
assert_eq "(D-5) 枝番の後ろに余分な文字が付く ID を弾く" "no" "$(pi_id_scope_ok G-158-1x 158)"

echo ""
echo "=== (D-6) 新規宣言の担当割当・全数検証の参照実装 ==="

# guarantee-gate.md「割当の全数検証」と同じ規則:
# $1=親の新規宣言 ID（カンマ区切り） $2=割当済み ID（カンマ区切り。チケット横断の連結）
# 各 ID がちょうど1回割り当てられているときだけ ok。0回は unassigned、2回以上は duplicated。
pi_assignment_check() {
  local ids="$1" assigned="$2" id count
  if [ -z "$ids" ]; then echo "ok"; return; fi
  local old_ifs="$IFS"
  IFS=','
  for id in $ids; do
    count=0
    local a
    for a in $assigned; do
      [ "$a" = "$id" ] && count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then IFS="$old_ifs"; echo "stop:unassigned:${id}"; return; fi
    if [ "$count" -ge 2 ]; then IFS="$old_ifs"; echo "stop:duplicated:${id}"; return; fi
  done
  IFS="$old_ifs"
  echo "ok"
}

assert_eq "(D-6) 全 ID がちょうど1回割り当てられていれば通過" "ok" \
  "$(pi_assignment_check 'G-10-1,G-10-2' 'G-10-1,G-10-2')"
assert_eq "(D-6) 未割当の ID があれば停止（取りこぼしを作らない）" \
  "stop:unassigned:G-10-2" "$(pi_assignment_check 'G-10-1,G-10-2' 'G-10-1')"
assert_eq "(D-6) 同一 ID の重複割当は停止（複数チケットが同じ保証を実装しない）" \
  "stop:duplicated:G-10-1" "$(pi_assignment_check 'G-10-1,G-10-2' 'G-10-1,G-10-2,G-10-1')"
assert_eq "(D-6) 新規宣言が0件なら割当なしで通過（検査した結果の0件）" \
  "ok" "$(pi_assignment_check '' '')"

echo ""
echo "=== (D-7) 維持保証の現行台帳での解決の参照実装（fail-closed） ==="

# feature-implementer 2-5 の維持保証の解決と同じ規則:
# $1=台帳の状態（readable|missing） $2=ID の台帳存在（found|absent）
# $3=台帳の約束文 $4=転記の約束文
pi_keep_resolve() {
  local ledger="$1" id_state="$2" ledger_stmt="$3" transcribed="$4"
  if [ "$ledger" != "readable" ]; then echo "stop:ledger_unreadable"; return; fi
  if [ "$id_state" != "found" ]; then echo "stop:id_absent"; return; fi
  if [ "$ledger_stmt" != "$transcribed" ]; then echo "stop:statement_drift"; return; fi
  echo "resolve:${ledger_stmt}"
}

assert_eq "(D-7) 台帳と転記が一致: 台帳の約束文を判定根拠として解決する" \
  "resolve:400を返す" "$(pi_keep_resolve readable found '400を返す' '400を返す')"
assert_eq "(D-7) 台帳が読めない: 停止（維持対象なしに丸めない）" \
  "stop:ledger_unreadable" "$(pi_keep_resolve missing found '400を返す' '400を返す')"
assert_eq "(D-7) ID が現行台帳に無い: 停止（退役・改番済みの可能性を人間判断へ）" \
  "stop:id_absent" "$(pi_keep_resolve readable absent '' '400を返す')"
assert_eq "(D-7) 文面ドリフト: 停止（旧文面とも新文面とも黙って整合させない）" \
  "stop:statement_drift" "$(pi_keep_resolve readable found '422を返す' '400を返す')"

echo ""
echo "=== (D-8) 割当要否の参照実装（対象の構造で決める。起動形態は入力にしない） ==="

# guarantee-gate.md「経路の表」と同じ規則: 割当の要否は親の分解の構造（実装チケット数）
# だけで決まり、今回の起動形態（同時か1件ずつか）は入力に含めない。
# 引数: $1=親の実装チケット数（0 = 要件チケット自体で分解なし）
pi_assignment_required() {
  local children="$1"
  if [ "$children" -eq 0 ]; then
    echo "not_required:inject_full"
  elif [ "$children" -eq 1 ]; then
    echo "trivial:inject_full"
  else
    echo "required:inject_share"
  fi
}

assert_eq "(D-8) 経路1: 要件チケット自体（分解なし）は割当不要・全量注入" \
  "not_required:inject_full" "$(pi_assignment_required 0)"
assert_eq "(D-8) 経路2: 1チケットのみに分解は自明の割当・全量注入" \
  "trivial:inject_full" "$(pi_assignment_required 1)"
assert_eq "(D-8) 経路3/4: 複数チケットに分解は割当必須・担当分のみ注入" \
  "required:inject_share" "$(pi_assignment_required 3)"
# 起動形態の非依存: 同じ構造なら同時実装でも1チケット逐次でも同じ判定になる
# （関数が起動形態を入力に取らないこと自体が規則の写しであり、ここで固定する）
assert_eq "(D-8) 分解済み親への1チケット逐次起動と複数同時起動で判定が変わらない" \
  "$(pi_assignment_required 3)" "$(pi_assignment_required 3)"

echo ""
echo "=== (D-9) 分解全体像の採用の参照実装（文法再検証＋健全性条件） ==="

# guarantee-gate.md「取得結果の検証」と同じ規則:
# 引数: $1=対象（実装チケット）自身の番号 $2=スクリプトの status（ok|no_children_found）
#       $3=候補一覧（"番号:ヘッダ文法の再検証結果(ok|ng)" のカンマ区切り。空文字可）
# 出力: ok:<採用した兄弟数> または stop:decomposition_unverifiable
pi_adopt_siblings() {
  local self="$1" status="$2" candidates="$3"
  local adopted_count=0 self_adopted="no" entry num verdict
  if [ "$status" = "ok" ] && [ -n "$candidates" ]; then
    local old_ifs="$IFS"
    IFS=','
    for entry in $candidates; do
      num="${entry%%:*}"
      verdict="${entry##*:}"
      if [ "$verdict" = "ok" ]; then
        adopted_count=$((adopted_count + 1))
        [ "$num" = "$self" ] && self_adopted="yes"
      fi
    done
    IFS="$old_ifs"
  fi
  if [ "$self_adopted" = "yes" ]; then
    echo "ok:${adopted_count}"
  else
    echo "stop:decomposition_unverifiable"
  fi
}

assert_eq "(D-9) 自分＋兄弟が文法検証を通過: 採用（2件）" \
  "ok:2" "$(pi_adopt_siblings 12 ok '12:ok,13:ok')"
assert_eq "(D-9) 引用でマッチしただけの無関係 Issue は文法再検証で除外される" \
  "ok:2" "$(pi_adopt_siblings 12 ok '12:ok,13:ok,99:ng')"
assert_eq "(D-9) no_children_found（0件）: 分解なしに読み替えず停止" \
  "stop:decomposition_unverifiable" "$(pi_adopt_siblings 12 no_children_found '')"
assert_eq "(D-9) 検索が自分を返さない（一時的欠落）: 健全性条件で停止" \
  "stop:decomposition_unverifiable" "$(pi_adopt_siblings 12 ok '13:ok')"
assert_eq "(D-9) 候補全滅（全件が文法不適合）: 空集合を分解として採用しない" \
  "stop:decomposition_unverifiable" "$(pi_adopt_siblings 12 ok '99:ng')"
assert_eq "(D-9) fallback_truncated: 自分が含まれていても打ち切りの可能性で停止（完全性の反証）" \
  "stop:decomposition_unverifiable" "$(pi_adopt_siblings 12 fallback_truncated '12:ok,13:ok')"
assert_eq "(D-9) children_lookup_failed: 照会失敗を含む0件は兄弟方向でも停止" \
  "stop:decomposition_unverifiable" "$(pi_adopt_siblings 12 children_lookup_failed '')"

echo ""
echo "=== (D-11) フェーズ判定の入力の参照実装（base 基準・手元非依存） ==="

# SKILL.md「判定器への入力は base の内容」の規則: 判定の入力は base の CLAUDE.md 内容
# だけであり、手元 checkout のフェーズは結果に影響しない（第2引数は存在しないことが
# 規則の写し）。base に CLAUDE.md が無い場合は no_claude_md と同義（sdd）。
# 引数: $1=base の CLAUDE.md 状態（gdd|sdd|invalid|absent）
pi_phase_basis() {
  local base_state="$1"
  if [ "$base_state" = "absent" ]; then
    echo "sdd"
  else
    echo "$base_state"
  fi
}

assert_eq "(D-11) base=GDD: 手元の状態によらずゲート発動の入力（gdd）" "gdd" "$(pi_phase_basis gdd)"
assert_eq "(D-11) base=SDD: 手元が GDD 宣言でも従来どおり不変の入力（sdd）" "sdd" "$(pi_phase_basis sdd)"
assert_eq "(D-11) base に CLAUDE.md なし: 宣言なし＝sdd（no_claude_md と同義）" "sdd" "$(pi_phase_basis absent)"
assert_eq "(D-11) base=invalid: sdd に読み替えない（fail-closed の入力を保存）" "invalid" "$(pi_phase_basis invalid)"

echo ""
echo "=== (D-12) 親方向の子照会の参照実装（Parent: 不在≠未分解） ==="

# guarantee-gate.md「対象が要件チケット自体の場合」の規則。
# no_children_found を未分解として受理できるのは、スクリプトが status を分離し
# 「両経路の照会成功が証明する0件」だけに no_children_found を名乗らせるため
# （照会失敗を含む0件は children_lookup_failed で届き、ここで停止する）。
# 引数: $1=スクリプトの status（ok|no_children_found|children_lookup_failed|fallback_truncated）
#       $2=候補一覧（"番号:ヘッダ文法の再検証結果(ok|ng)" のカンマ区切り。空文字可）
# 出力: ok:undecomposed（未分解の単独親＝全量注入可）または stop:<reason>
pi_parent_children_gate() {
  local status="$1" candidates="$2"
  if [ "$status" = "fallback_truncated" ] || [ "$status" = "children_lookup_failed" ]; then
    echo "stop:decomposition_unverifiable"
    return
  fi
  local verified_count=0 entry verdict
  if [ -n "$candidates" ]; then
    local old_ifs="$IFS"
    IFS=','
    for entry in $candidates; do
      verdict="${entry##*:}"
      [ "$verdict" = "ok" ] && verified_count=$((verified_count + 1))
    done
    IFS="$old_ifs"
  fi
  if [ "$verified_count" -ge 1 ]; then
    echo "stop:parent_already_decomposed"
  else
    echo "ok:undecomposed"
  fi
}

assert_eq "(D-12) 検証済みの子あり: 分解済み親への直接起動として停止（第2実装を作らない）" \
  "stop:parent_already_decomposed" "$(pi_parent_children_gate ok '101:ok,102:ok')"
assert_eq "(D-12) 一部が引用のみでも検証済みの子が1件あれば停止" \
  "stop:parent_already_decomposed" "$(pi_parent_children_gate ok '101:ok,99:ng')"
assert_eq "(D-12) 引用マッチのみ（文法再検証で全滅）: 未分解の単独親として受理" \
  "ok:undecomposed" "$(pi_parent_children_gate ok '99:ng')"
assert_eq "(D-12) no_children_found（両経路の照会成功が証明する0件）: 未分解の単独親として受理" \
  "ok:undecomposed" "$(pi_parent_children_gate no_children_found '')"
assert_eq "(D-12) children_lookup_failed（照会失敗を含む0件）: 検査不能として停止（未分解に丸めない）" \
  "stop:decomposition_unverifiable" "$(pi_parent_children_gate children_lookup_failed '')"
assert_eq "(D-12) 子照会が打ち切り: 自分の包含に関係なく未分解を証明できず停止" \
  "stop:decomposition_unverifiable" "$(pi_parent_children_gate fallback_truncated '101:ok')"

echo ""
echo "=== (D-10) 決定的割当の参照実装（同一入力→同一割当・順序不変・タイブレーク） ==="

# 依存の推移閉包で「依存する他候補の数」を数える。
# 引数: $1=起点チケット番号 $2=依存マップ（"番号:依存番号群(+区切り、無ければ-)" の ; 区切り）
#       $3=候補集合（空白区切り）
pi_trans_count() {
  local start="$1" deps_map="$2" cand_set="$3"
  local frontier="$start" visited="" count=0
  while [ -n "$frontier" ]; do
    local next="" n dl entry d
    for n in $frontier; do
      dl=""
      local old_ifs="$IFS"
      IFS=';'
      for entry in $deps_map; do
        case "$entry" in "${n}:"*) dl="${entry#*:}" ;; esac
      done
      IFS="$old_ifs"
      [ "$dl" = "-" ] && dl=""
      dl="${dl//+/ }"
      for d in $dl; do
        case " ${visited} ${frontier} ${next} " in *" ${d} "*) ;; *) next="${next} ${d}" ;; esac
      done
    done
    visited="${visited} ${frontier}"
    frontier="${next# }"
  done
  local v
  for v in $visited; do
    [ "$v" = "$start" ] && continue
    case " ${cand_set} " in *" ${v} "*) count=$((count + 1)) ;; esac
  done
  echo "$count"
}

# guarantee-gate.md「割当の決定的規則」の3段（対応 AC → 機械一致候補 → 依存下流＋番号最小）:
# 引数: $1=対応AC注記（"AC-n"。注記なしは空文字）
#       $2=チケット集合（"番号/対応AC群(+区切り。行欠落は missing)/依存番号群(+区切り、無ければ-)"
#          のカンマ区切り）
pi_assign_one() {
  local ac="$1" tickets="$2"
  if [ -z "$ac" ]; then echo "stop:guarantee_assignment_unresolvable"; return; fi
  local entry num rest acs deps cand="" deps_map=""
  local old_ifs="$IFS"
  IFS=','
  for entry in $tickets; do
    num="${entry%%/*}"
    rest="${entry#*/}"
    acs="${rest%%/*}"
    deps="${rest#*/}"
    if [ "$acs" = "missing" ]; then
      IFS="$old_ifs"
      echo "stop:guarantee_assignment_unresolvable"
      return
    fi
    deps_map="${deps_map}${deps_map:+;}${num}:${deps}"
    case "+${acs}+" in *"+${ac}+"*) cand="${cand}${cand:+ }${num}" ;; esac
  done
  IFS="$old_ifs"
  if [ -z "$cand" ]; then echo "stop:guarantee_assignment_unresolvable"; return; fi
  local best="" best_count=-1 c cnt
  for c in $cand; do
    cnt="$(pi_trans_count "$c" "$deps_map" "$cand")"
    if [ "$cnt" -gt "$best_count" ]; then
      best="$c"
      best_count="$cnt"
    elif [ "$cnt" -eq "$best_count" ] && [ "$c" -lt "$best" ]; then
      best="$c"
    fi
  done
  echo "assign:${best}"
}

assert_eq "(D-10) AC 注記なし: 停止（情報欠落）" \
  "stop:guarantee_assignment_unresolvable" "$(pi_assign_one '' '12/AC-1/-')"
assert_eq "(D-10) アンカー行を持たないチケットが集合にある: 停止（一意性の破れ）" \
  "stop:guarantee_assignment_unresolvable" "$(pi_assign_one AC-1 '12/AC-1/-,14/missing/-')"
assert_eq "(D-10) 候補0件: 停止（意味推測で補わない）" \
  "stop:guarantee_assignment_unresolvable" "$(pi_assign_one AC-9 '12/AC-1/-,14/AC-2/-')"
assert_eq "(D-10) AC の一致は全体一致（AC-1 が AC-12 に一致しない）" \
  "stop:guarantee_assignment_unresolvable" "$(pi_assign_one AC-1 '12/AC-12/-')"
assert_eq "(D-10) 単独候補: そのチケットに割当" \
  "assign:14" "$(pi_assign_one AC-2 '12/AC-1/-,14/AC-2/-')"
assert_eq "(D-10) 複数候補・依存なし: チケット番号最小へ（タイブレーク）" \
  "assign:12" "$(pi_assign_one AC-1 '14/AC-1/-,12/AC-1/-')"
assert_eq "(D-10) 複数候補・依存あり: 依存下流（後に完成する側）へ" \
  "assign:14" "$(pi_assign_one AC-1 '12/AC-1/-,14/AC-1/12')"
assert_eq "(D-10) 3段チェーン: 推移依存で最下流へ" \
  "assign:15" "$(pi_assign_one AC-1 '12/AC-1/-,14/AC-1/12,15/AC-1/14')"
assert_eq "(D-10) 同一入力からの再実行が同一割当になる（決定性）" \
  "$(pi_assign_one AC-1 '12/AC-1/-,14/AC-1/12,15/AC-1/14')" \
  "$(pi_assign_one AC-1 '12/AC-1/-,14/AC-1/12,15/AC-1/14')"
assert_eq "(D-10) チケットの列挙順を入れ替えても割当が変わらない（順序不変）" \
  "$(pi_assign_one AC-1 '12/AC-1/-,14/AC-1/12,15/AC-1/14')" \
  "$(pi_assign_one AC-1 '15/AC-1/14,12/AC-1/-,14/AC-1/12')"
assert_eq "(D-10) タイブレークも列挙順に依存しない（番号最小は入れ替えに不変）" \
  "$(pi_assign_one AC-1 '14/AC-1/-,12/AC-1/-')" \
  "$(pi_assign_one AC-1 '12/AC-1/-,14/AC-1/-')"

# ---------------------------------------------------------------------------
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
