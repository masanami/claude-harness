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
assert_file_contains "(B-1) SDD期は本項を実行せず従来どおり（参照ファイルも Read しない）" "$SKILL_FILE" \
  '`sdd`（フェーズ宣言なしを含む）では本項を実行せず、以降の手順は従来どおり行う（参照ファイルも Read しない）'
assert_file_contains "(B-1) 禁止事項に裁可ゲートの迂回と自己裁可を明記" "$SKILL_FILE" \
  '裁可ゲートの迂回'

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
  '(b) 台帳の文法を親Issue本文へ適用しない'
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
  'どのチケットにも割り当てられない・単独で検証可能にできない ID が1件でもあれば **停止**'
assert_file_contains "(B-4b) 跨り保証は依存順で最後に完成するチケットへ割り当てる" "$GATE_FILE" \
  '依存順で最後に完成するチケットへ割り当てる'
assert_file_contains "(B-4b) 注入ブロックの新規宣言は担当分だけ（行単位の抜粋・行内は逐語）" "$GATE_FILE" \
  '**新規宣言する保証は担当割当に従い、当該チケットの担当分の行だけを転記する**'
assert_file_contains "(B-4b) 割当表を実行計画に出力し注入に接続する（記録だけにしない）" "$GATE_FILE" \
  '記録だけにせず注入に接続する'
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
  '台帳の約束文を判定根拠にする'
assert_file_contains "(B-6) 注入ブロック・親 Issue の転記文面を判定根拠にしない" "$FI_FILE" \
  '**注入ブロック・親 Issue の転記文面を判定根拠にしない**'
assert_file_contains "(B-6) 台帳の読み取りは台帳の文法の正本（共通-2 (b)）に従う" "$FI_FILE" \
  '`guarantee-section.md` 共通-2 (b)'
assert_file_contains "(B-6) fail-closed: 台帳が無い・読めない場合は停止" "$FI_FILE" \
  '**台帳（`docs/guarantees.md`）自体が無い・読めない**'
assert_file_contains "(B-6) fail-closed: ID が現行台帳に存在しなければ停止" "$FI_FILE" \
  '**ID が現行台帳に存在しない**'
assert_file_contains "(B-6) fail-closed: 転記と台帳の文面ドリフトは停止（黙って台帳側を採用しない）" "$FI_FILE" \
  '**転記の約束文と台帳の約束文が一致しない（文面ドリフト）**'
assert_file_contains "(B-6) 維持対象なしに丸めて実装を進めない" "$FI_FILE" \
  '**「維持対象なし」に丸めて実装を進めない**'
assert_file_contains "(B-6) 担当外の新規宣言のテスト・台帳追記を行わない（重複実装の防止）" "$FI_FILE" \
  '**担当外の新規宣言（ブロックに無い親の保証）のテスト作成・台帳追記を行わない**'
assert_file_contains "(B-6) 直接呼び出し時は担当分を特定し根拠を明記（全量を黙って実装しない）" "$FI_FILE" \
  '親の新規宣言の全量を黙って実装しない'
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

# 判定表の行数（排他の状態空間）はちょうど5行
verdict_rows="$(grep -cE '^\| [0-9]+ \| ' "$GATE_FILE")"
assert_eq "(D-1) 判定表の状態はちょうど5行（増減時は語彙表・停止報告と同時更新）" "5" "$verdict_rows"

# reason 語彙表はちょうど7コード
reason_rows="$(grep -cE '^\| `[a-z_]+` \| Phase' "$GATE_FILE")"
assert_eq "(D-1) reason 語彙表はちょうど7コード" "7" "$reason_rows"

# 各コードは定義（語彙表）と使用（判定表・転記の規律・担当割当）の両方に現れる
# （定義だけ・使用だけを作らない）
for code in parent_mismatch labels_unavailable label_state_ambiguous approval_missing \
  guarantee_section_unreadable guarantee_scope_mismatch guarantee_assignment_unresolvable; do
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
