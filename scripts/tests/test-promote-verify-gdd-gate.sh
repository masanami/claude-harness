#!/bin/bash
# test-promote-verify-gdd-gate.sh
# GDD P3・promote-verify 系統（Step 5.5 保証整合チェックと readyForPromotion の拡張。
# Issue #158）の回帰テスト。2部構成:
#
#  (A) 統合が依存するスクリプト契約の回帰テスト
#      /promote-verify の SKILL.md は detect-dev-phase.sh / guarantee-index-check.sh の
#      exit code と JSON フィールドの語彙に依存して分岐する（GDD期のみ Step 5.5 を実行・
#      SDD期は不変・invalid は fail-closed・exit 2 や実行不能は fail 扱い）。この契約が
#      変わると SKILL.md 側の手順が黙って壊れるため、統合が前提にする最小契約を
#      フィクスチャで固定する。各スクリプト単体の網羅は test-detect-dev-phase.sh /
#      test-guarantee-index-check.sh の担当であり、ここでは重複させない。
#
#  (B) SKILL.md / 参照ファイルの契約文（正準文）の存在検査と構造不変条件
#      Step 5.5 の手順の本体は skills/promote-verify/references/guarantee-consistency.md
#      へ分割されている（SKILL.md 側には分岐の要点のみ）。検査は文言が実際に置かれている
#      ファイルに対して行い（assert_skill_contains / assert_ref_contains）、構造不変条件は
#      両者の結合テキストに対して掛けることで、分割前と同じ強度を保つ。
#      Step 5.5 の分岐・フェイルセーフ規律・readyForPromotion の論理式は
#      skills/promote-verify/SKILL.md の手順として実装されているため、正準文が逐語で
#      存在することを grep で検査し、手順のドリフト（更新漏れ・緩和）を機械検出する
#      （test-skeptic-discipline.sh / test-quality-check-gdd-gate.sh と同じ方式）。
#      あわせて default-OFF の構造不変条件（GDD 依存の記述が Step 5.5 / Step 7 の1項 /
#      Step 9 の保証整合セクション以外へ漏れていないこと）と、`skipped` を sdd 以外へ
#      広げる記述が混入していないことを検査する。
#
# 実行方法: bash scripts/tests/test-promote-verify-gdd-gate.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # 正準文・フィクスチャ内のバッククォートは Markdown のリテラル
# （SKILL.md の逐語検査対象）であり、シェル展開を意図していない
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DETECT_SCRIPT="${REPO_ROOT}/scripts/detect-dev-phase.sh"
GIC_SCRIPT="${REPO_ROOT}/scripts/guarantee-index-check.sh"
EAC_SCRIPT="${REPO_ROOT}/scripts/extract-acceptance-criteria.sh"
SKILL_FILE="${REPO_ROOT}/skills/promote-verify/SKILL.md"
REF_FILE="${REPO_ROOT}/skills/promote-verify/references/guarantee-consistency.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "NG - jq が見つからないためテストを実行できません（検査不能を pass にはしない）" >&2
  exit 1
fi

if [ ! -r "$SKILL_FILE" ] || [ ! -r "$REF_FILE" ]; then
  echo "NG - SKILL.md または参照ファイルを読めません（検査不能を pass にはしない）: ${SKILL_FILE} / ${REF_FILE}" >&2
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

# SKILL.md に正準文（固定文字列）が逐語で存在することを検査する。
assert_skill_contains() {
  local description="$1" phrase="$2"
  if grep -qF -- "$phrase" "$SKILL_FILE"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${SKILL_FILE}"
    echo "       phrase: ${phrase}"
  fi
}

# SKILL.md の指定セクション（開始見出し行から終了見出し行の直前まで）を取り出す。
skill_section() {
  local start="$1" end="$2"
  awk -v s="$start" -v e="$end" '
    index($0, s) == 1 { inside = 1; next }
    inside && index($0, e) == 1 { inside = 0 }
    inside { print }
  ' "$SKILL_FILE"
}

# 参照ファイル（Step 5.5 の手順の正本）に正準文が逐語で存在することを検査する。
assert_ref_contains() {
  local description="$1" phrase="$2"
  if grep -qF -- "$phrase" "$REF_FILE"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${REF_FILE}"
    echo "       phrase: ${phrase}"
  fi
}

# 参照ファイルに「あってはならない文言」が無いことを検査する（緩和の再発防止）。
assert_ref_not_contains() {
  local description="$1" phrase="$2"
  if grep -qF -- "$phrase" "$REF_FILE"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${REF_FILE}"
    echo "       phrase: ${phrase}"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  fi
}

# 5.5-7 の算出式（(a) AND (b) AND (c) AND (d)）の AND 結合を評価する。
# 算出式の項が (a)〜(d) の4本であること・(d) が humanReview を参照していることは
# (B-10) の構造検査で文書側から確認しており、本関数はその真理値表を固定する。
eval_all_consistent() {
  # 引数: a b c d（1=真 / 0=偽）。1つでも 0 なら false。
  local operand
  for operand in "$@"; do
    if [ "$operand" != "1" ]; then
      echo "false"
      return 0
    fi
  done
  echo "true"
}

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

# ---------------------------------------------------------------------------
# フィクスチャ: 導入先プロジェクトを模したワークスペース
# ---------------------------------------------------------------------------

WS="${TMP_ROOT}/project"
mkdir -p "${WS}/docs" "${WS}/tests"

cat >"${WS}/tests/example.test.sh" <<'EOF'
test_contact_returns_400() {
  echo "sample test body"
}
EOF

# 健全な台帳（全参照が実在）
cat >"${WS}/docs/guarantees-ok.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

### G-158-1: サンプルの保証

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #158

## Gaps（テストのない公開面）
EOF

# 部分的に壊れた台帳（1件は健全・1件は参照先ファイルが無い）
cat >"${WS}/docs/guarantees-broken.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

### G-158-1: サンプルの保証

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #158

### G-158-2: 壊れた参照を持つ保証

- 種別: API契約
- テスト: `tests/missing.test.sh::test_never_exists`
- 宣言元: #158

## Gaps（テストのない公開面）
EOF

# 「保証」節を持たない壊れた台帳（検査不能ケース）
cat >"${WS}/docs/guarantees-no-section.md" <<'EOF'
# 保証台帳

## メモ

- 節名が規約と異なる
EOF

# コードフェンス内に記入例を持つ台帳（フェンス外の実在保証は1件だけ）。
# スクリプトはフェンス内を検査対象にしないため、散文側が素の文字列一致で読むと
# 「記入例を登録済みと誤認するが索引チェックは pass のまま」という食い違いが起きる。
cat >"${WS}/docs/guarantees-fenced-example.md" <<'EOF'
# 保証台帳

書式の記入例（実在の保証ではない）:

```markdown
### G-158-9: フェンス内の記入例

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #158
```

## 保証（Guarantees）

### G-158-1: 実在する保証

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #158

## Gaps（テストのない公開面）
EOF

# 「保証」節の外に保証見出しを持つ台帳
cat >"${WS}/docs/guarantees-outside-section.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

### G-158-1: 実在する保証

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #158

## メモ

### G-158-8: 節の外に置かれた保証

- テスト: `tests/example.test.sh::test_contact_returns_400`

## Gaps（テストのない公開面）
EOF

# 枝番の前方一致（G-158-1 と G-158-10 の併存）を持つ台帳
cat >"${WS}/docs/guarantees-prefix.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

### G-158-10: 枝番が2桁の保証

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #158

## Gaps（テストのない公開面）
EOF

claude_md_gdd() {
  printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n- 駆動文書: docs/guarantees.md\n'
}

claude_md_sdd_declared() {
  printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: SDD期\n'
}

claude_md_no_declaration() {
  printf '# プロジェクト\n\n## 技術スタック\n\n- bash\n'
}

claude_md_invalid() {
  printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: GDD\n'
}

# ---------------------------------------------------------------------------
# (A-1) SDD期の不変: Step 5.5 を発動させない入力になる
# ---------------------------------------------------------------------------
echo "=== (A-1) SDD期の不変: 発動判定が sdd を返す ==="

claude_md_no_declaration >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "宣言なし: exit 0（SDD期として確定）" "0" "$code"
assert_eq "宣言なし: phase は sdd（guaranteeCheck.skipped=true になる唯一の入力）" \
  "sdd" "$(printf '%s' "$out" | jq -r '.phase')"

claude_md_sdd_declared >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "SDD期宣言: exit 0" "0" "$code"
assert_eq "SDD期宣言: phase は sdd" "sdd" "$(printf '%s' "$out" | jq -r '.phase')"

# ---------------------------------------------------------------------------
# (A-2) GDD期の検査実行: gdd 判定と索引整合（5.5-4）の実行
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-2) GDD期の検査実行: gdd 判定と索引整合の実行 ==="

claude_md_gdd >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "GDD期宣言: exit 0" "0" "$code"
assert_eq "GDD期宣言: phase は gdd（Step 5.5 を発動する入力）" \
  "gdd" "$(printf '%s' "$out" | jq -r '.phase')"

out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-ok.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "健全な台帳: exit 0" "0" "$code"
assert_eq "健全な台帳: status は pass（allConsistent の条件 (b) を満たす入力）" \
  "pass" "$(printf '%s' "$out" | jq -r '.status')"

# 部分成功≠完全成功: 健全な参照が1件あっても、壊れた参照が1件でもあれば fail
out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-broken.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "部分的に壊れた台帳: exit 1（部分成功を成功にしない）" "1" "$code"
assert_eq "部分的に壊れた台帳: status は fail（allConsistent は false になる）" \
  "fail" "$(printf '%s' "$out" | jq -r '.status')"
assert_eq "部分的に壊れた台帳: broken に壊れた参照が列挙される" \
  "G-158-2" "$(printf '%s' "$out" | jq -r '.broken[0].guarantee_id')"

# ---------------------------------------------------------------------------
# (A-3) invalid の fail-closed: 不正宣言は sdd に化けない
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-3) invalid の fail-closed: 不正宣言は sdd へフォールバックしない ==="

claude_md_invalid >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "不正宣言: exit 1（skipped ではなく allConsistent:false にする入力）" "1" "$code"
assert_eq "不正宣言: phase は invalid（sdd に読み替え不可）" \
  "invalid" "$(printf '%s' "$out" | jq -r '.phase')"

# ---------------------------------------------------------------------------
# (A-4) 検査不能≠0件: 索引整合が検査できないとき pass を出力しない
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-4) 検査不能≠0件: 索引整合の実行前提欠落は pass にならない ==="

# stdout（空を含む）に status:pass が現れないことを判定するヘルパ。
stdout_pass_marker() {
  if printf '%s' "$1" | grep -qE '"status":[[:space:]]*"pass"'; then
    echo "pass"
  else
    echo "no-pass"
  fi
}

# GDD期なのに台帳が無いケース（5.5-2 が allConsistent:false にする状況の裏付け）
out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-missing.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "台帳ファイルが無い: exit 2（SKILL.md はこれを fail 扱いにする）" "2" "$code"
assert_eq "台帳ファイルが無い: stdout に status:pass の JSON を出力しない" \
  "no-pass" "$(stdout_pass_marker "$out")"

out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-no-section.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "「保証」節が無い台帳: exit 2（全保証が黙って未検査になる素通りを防ぐ）" "2" "$code"
assert_eq "「保証」節が無い台帳: stdout に status:pass の JSON を出力しない" \
  "no-pass" "$(stdout_pass_marker "$out")"

# ---------------------------------------------------------------------------
# (A-5) 5.5-5（新規宣言の台帳登録確認）が前方一致で誤判定しないこと
#       SKILL.md は「ID の完全一致で判定し、前方一致で G-158-1 と G-158-10 を
#       取り違えない」と規定している。その判定手段（見出し `### <ID>:` の完全一致）が
#       実際に取り違えを避けられることをフィクスチャで固定する。
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-5) 台帳登録確認: 枝番の前方一致で取り違えない ==="

assert_eq "G-158-10 だけの台帳を G-158-1 の登録済み判定に使わない（完全一致）" \
  "0" "$(grep -cF -- '### G-158-1:' "${WS}/docs/guarantees-prefix.md")"
assert_eq "G-158-10 自身は完全一致で検出できる" \
  "1" "$(grep -cF -- '### G-158-10:' "${WS}/docs/guarantees-prefix.md")"

# 5.5-3 の ID スコープ検証（`G-<親Issue番号>-` の完全一致）が、別スコープの ID と
# 桁違いの Issue 番号を取り違えないこと。親Issue #158 を想定した比較を固定する。
id_in_scope() {
  # 引数: <親Issue番号> <保証ID>。スコープ一致なら in-scope、そうでなければ out-of-scope。
  case "$2" in
    "G-${1}-"*) echo "in-scope" ;;
    *) echo "out-of-scope" ;;
  esac
}
assert_eq "親Issue #158 の新規宣言 G-158-1 はスコープ一致" \
  "in-scope" "$(id_in_scope 158 "G-158-1")"
assert_eq "親Issue #158 の新規宣言 G-158-10（枝番2桁）もスコープ一致" \
  "in-scope" "$(id_in_scope 158 "G-158-10")"
assert_eq "別 Issue スコープの G-999-1 は弾かれる" \
  "out-of-scope" "$(id_in_scope 158 "G-999-1")"
assert_eq "桁違いの G-1580-1 をハイフンまでの比較で取り違えない" \
  "out-of-scope" "$(id_in_scope 158 "G-1580-1")"
assert_eq "前方一致の G-15-1 も取り違えない" \
  "out-of-scope" "$(id_in_scope 158 "G-15-1")"

# ---------------------------------------------------------------------------
# (A-6) 台帳の読み取り規則の一致（散文側とスクリプト側で同じ台帳を同じ規則で読む）
#       5.5-5 の登録確認は SKILL.md の散文が指示する規則で行われるため、その規則が
#       guarantee-index-check.sh の実装（フェンス内は対象外・「保証」節内のみ）と
#       食い違うと、記入例を「登録済み」と誤認しても索引チェックは pass のままになる。
#       ここではスクリプトの実挙動を固定したうえで、散文の3条件をそのまま適用した
#       参照実装が同じ結果になることを突き合わせる。
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-6) 台帳の読み取り規則: フェンス内の記入例を保証として数えない ==="

# SKILL.md 5.5-5 の3条件（フェンス外・「保証」節内・`### ` 見出し）をそのまま適用した参照実装。
# フィクスチャは列0のフェンス・見出しのみを使う（完全な CommonMark 実装ではなく、
# 目的は「散文の規則がスクリプトと同じ結果を出すか」の突き合わせ）。
ref_impl_guarantee_headings() {
  awk '
    /^(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^## / { section = ($0 ~ /^## 保証/) ? 1 : 0; next }
    /^# /  { section = 0; next }
    section && /^### / { print }
  ' "$1"
}

# スクリプトの実挙動: フェンス内の `### G-158-9:` と `- テスト:` は一切数えない
out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-fenced-example.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "フェンス内に記入例がある台帳: exit 0（記入例は検査対象外）" "0" "$code"
assert_eq "フェンス内の記入例は保証として数えない（guarantees は1件）" \
  "1" "$(printf '%s' "$out" | jq -r '.counts.guarantees')"
assert_eq "フェンス内のテスト参照も数えない（refs は1件）" \
  "1" "$(printf '%s' "$out" | jq -r '.counts.refs')"
assert_eq "フェンス内の記入例があっても status は pass（＝スクリプト側からは食い違いが見えない）" \
  "pass" "$(printf '%s' "$out" | jq -r '.status')"

# 素の文字列一致（散文が Grep だけで判定した場合）は記入例にヒットする＝誤認の再現
assert_eq "素の Grep は記入例にヒットする（Grep のヒットを登録済みの根拠にできない）" \
  "1" "$(grep -cF -- '### G-158-9:' "${WS}/docs/guarantees-fenced-example.md")"

# 散文の3条件を適用した参照実装は記入例を除外し、実在の保証だけを返す
ref_headings="$(ref_impl_guarantee_headings "${WS}/docs/guarantees-fenced-example.md")"
assert_eq "3条件を適用すると記入例 G-158-9 は登録済みにならない" \
  "0" "$(printf '%s\n' "$ref_headings" | grep -cF -- 'G-158-9')"
assert_eq "3条件を適用すると実在の G-158-1 だけが登録済みになる" \
  "1" "$(printf '%s\n' "$ref_headings" | grep -cF -- 'G-158-1')"

# 独立2経路の突き合わせ（5.5-5 が指示する件数一致）が実際に成立すること
assert_eq "散文の規則とスクリプトの件数が一致する（フェンス入り台帳）" \
  "$(printf '%s' "$out" | jq -r '.counts.guarantees')" \
  "$(printf '%s\n' "$ref_headings" | grep -c .)"

ok_out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-ok.md" --base "$WS" 2>/dev/null)"
assert_eq "散文の規則とスクリプトの件数が一致する（健全な台帳）" \
  "$(printf '%s' "$ok_out" | jq -r '.counts.guarantees')" \
  "$(ref_impl_guarantee_headings "${WS}/docs/guarantees-ok.md" | grep -c .)"

# 「保証」節の外の見出しは登録済みとみなさない。スクリプトは黙って無視せず broken に出す
out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-outside-section.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "「保証」節の外の見出し: exit 1（黙って未検査にしない）" "1" "$code"
assert_eq "「保証」節の外の見出しは guarantee_outside_section として報告される" \
  "guarantee_outside_section" "$(printf '%s' "$out" | jq -r '.broken[0].reason')"
assert_eq "「保証」節の外の見出しは保証件数に数えない" \
  "1" "$(printf '%s' "$out" | jq -r '.counts.guarantees')"
assert_eq "3条件を適用しても節の外の G-158-8 は登録済みにならない" \
  "0" "$(ref_impl_guarantee_headings "${WS}/docs/guarantees-outside-section.md" | grep -cF -- 'G-158-8')"

# ---------------------------------------------------------------------------
# (A-7) チェックリストのマーカー状態で対象を絞らないこと
#       5.5-3 の保証節の抽出は「既存の受入基準抽出と同じ扱い」を規定している。その基準に
#       なる extract-acceptance-criteria.sh の実挙動（`- [ ]` / `- [x]` / `- [X]` を等しく
#       抽出し、チェック状態は checked として記録するだけで絞り込みに使わない）を固定する。
#       実装が進めばチェックは付くため、未チェックだけを拾う規則にすると完了した項目ほど
#       黙って対象から外れる（codex P1 指摘と同型の欠陥）。
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-7) チェックリスト: チェック済み・未チェックを等しく対象にする ==="

mixed_body="$(printf '## 受入基準\n\n- [ ] 未チェックの項目\n- [x] 小文字でチェック済みの項目\n- [X] 大文字でチェック済みの項目\n')"
out="$(printf '%s' "$mixed_body" | bash "$EAC_SCRIPT" --stdin 2>/dev/null)"
code=$?
assert_eq "混在チェックリスト: exit 0" "0" "$code"
assert_eq "混在チェックリスト: 3件すべてを抽出する（チェック状態で絞らない）" \
  "3" "$(printf '%s' "$out" | jq -r '.criteria | length')"
assert_eq "混在チェックリスト: - [x] の項目も抽出される" \
  "1" "$(printf '%s' "$out" | jq -r '[.criteria[] | select(.text == "小文字でチェック済みの項目")] | length')"
assert_eq "混在チェックリスト: - [X]（大文字）の項目も抽出される" \
  "1" "$(printf '%s' "$out" | jq -r '[.criteria[] | select(.text == "大文字でチェック済みの項目")] | length')"
assert_eq "混在チェックリスト: チェック状態は checked として記録されるだけ（除外に使われない）" \
  "false,true,true" "$(printf '%s' "$out" | jq -r '[.criteria[].checked | tostring] | join(",")')"

# チェック済みだけの節でも全件が対象になる（「完了したら対象が消える」ことがない）
all_checked="$(printf '## 受入基準\n\n- [x] 完了した項目A\n- [x] 完了した項目B\n')"
out="$(printf '%s' "$all_checked" | bash "$EAC_SCRIPT" --stdin 2>/dev/null)"
assert_eq "全件チェック済み: 2件とも抽出される（完了により対象が消えない）" \
  "2" "$(printf '%s' "$out" | jq -r '.criteria | length')"
assert_eq "全件チェック済み: parse_status は ok（no_checklist_found にならない）" \
  "ok" "$(printf '%s' "$out" | jq -r '.parse_status')"

# ---------------------------------------------------------------------------
# (B) SKILL.md の契約文（正準文）の存在検査
# ---------------------------------------------------------------------------
echo ""
echo "=== (B-1) Step 5.5 の発動判定とスクリプト実行形 ==="

assert_skill_contains "発動判定はランチャー経由の detect-dev-phase" \
  "claude-harness-run detect-dev-phase"
assert_ref_contains "索引整合はランチャー経由の guarantee-index-check" \
  "claude-harness-run guarantee-index-check"
assert_skill_contains "フェーズ判定はスクリプト出力のみ（CLAUDE.md を独自に grep しない）" \
  '`CLAUDE.md` を自分で grep しないこと'
assert_ref_contains "意味整合は guarantee-auditor への fan-out" \
  "subagent_type: 'claude-harness:guarantee-auditor'"
assert_ref_contains "fan-out のチャンクサイズは Step 4 と同じ10件" \
  "Step 4 と同じく **10件ずつ**のチャンクに区切り"

echo ""
echo "=== (B-2) SDD期の不変（default-OFF） ==="

assert_skill_contains "SDD期は 5.5-2 以降を実行せず挙動・報告が従来と完全に同一" \
  "**SDD期（フェーズ宣言なしを含む）では 5.5-2 以降を実行せず、本スキルの挙動・報告は従来と完全に同一**"
assert_skill_contains "SDD期は保証整合セクション自体を報告に出さない" \
  "Step 9 の報告に保証整合セクション自体を出さない"
assert_skill_contains "SDD期は ⊘ スキップ行としても出さない" \
  '`⊘ スキップ` の行としても出さない'

echo ""
echo "=== (B-3) skipped の適用範囲（フェイルセーフ規律） ==="

assert_skill_contains "skipped:true にしてよいのはフェーズ判定が sdd のときだけ" \
  '**`skipped: true` にしてよいのは、フェーズ判定が `sdd` として確定した場合のみ**'
assert_skill_contains "invalid を sdd に読み替えない" \
  '`sdd` に読み替えない'
assert_skill_contains "判定不能・実行不能を skipped へ倒さない" \
  '判定できなかった・実行できなかったものを `skipped` へ倒さないこと'
assert_ref_contains "GDD期に台帳が無い場合は skipped にしない" \
  '**`skipped` にしない**'
assert_ref_contains "台帳欠落は運用前提の破れとして扱う" \
  "GDD期を宣言しているのに駆動文書が無い"
assert_skill_contains "Step 7 でも skipped を sdd 以外へ広げないことを明記" \
  '**Step 5.5-1 のフェーズ判定が `sdd` として確定した場合だけ**である'

echo ""
echo "=== (B-4) 検査不能≠0件 ==="

assert_ref_contains "索引整合の exit 2・パース不能・実行不能は fail 扱い" \
  '`guaranteeCheck.index = { "status": "fail", "ledger": null, "base": null, "counts": null, "broken": null, "error": "<stderr のメッセージ>" }`'
assert_ref_contains "索引整合の実行不能を pass・検査対象なしに読み替えない" \
  '**`pass` や「検査対象なし」に読み替えない**'
assert_ref_contains "検査不能は問題0件と同じではない" \
  "検査不能は「問題0件」と同じではない"
assert_ref_contains "保証節を抽出できない場合に対象0件として進めない" \
  "**対象0件（空配列）として先へ進めないこと**"
assert_ref_contains "空配列で allConsistent が真になる罠を明記" \
  '**保証を1件も検証していないのに `allConsistent: true` が成立する**'
assert_ref_contains "報告では未検証を0件と書かない" \
  "「0件」ではなく「未検証」と書くこと"

echo ""
echo "=== (B-5) allConsistent が false になる各ケース（skipped へ変換しない） ==="

assert_ref_contains "drifted/uncertain/verification_failed/not_registered/結果の欠落は allConsistent:false" \
  '- **`drifted` / `uncertain` / `verification_failed` / `not_registered` / 結果の欠落は、いずれも `allConsistent: false`** とし、**`skipped` へ変換しない**'
assert_ref_contains "検証失敗（構造化応答なし）は verification_failed として積む" \
  '`verdict: "verification_failed"` / `evidence: "guarantee-auditor agent failed"` として積む'
assert_ref_contains "検証失敗を consistent にも skipped にも変換しない" \
  '**`consistent` にも `skipped` にも変換しない**'
assert_ref_contains "台帳未追記は not_registered（検証済み・スキップにしない）" \
  '**未追記を「検証済み」にも「スキップ」にもしない**'
assert_ref_contains "未追記の保証を targets から取り除かない" \
  '**未追記の保証を `targets` から取り除いて件数を合わせない**'
assert_ref_contains "台帳登録確認は ID の完全一致（前方一致で取り違えない）" \
  '前方一致で `G-158-1` と `G-158-10` を取り違えないこと'
assert_ref_contains "新規宣言の意味検証は親Issueの（裁可された）約束文を正とする" \
  '**`statement` は、新規宣言なら親Issueの保証節の約束文（裁可された文言が正）'
assert_ref_contains "台帳の約束文が親Issueの約束文と食い違う場合は drifted" \
  '**新規宣言で、台帳に登録された約束文が親Issueの約束文と食い違っている場合は、その不一致自体を `verdict: "drifted"` として記録する**'
assert_ref_contains "(a) の突き合わせは件数だけでなく ID で行う" \
  "(a) targets の各 guarantee_id に対応する結果が guarantees に1件ずつ存在する（件数だけでなく ID を突き合わせる）"

echo ""
echo "=== (B-5b) 早期失敗経路の出力契約（未検査フィールドの明示的初期化と報告） ==="

# fail-closed の早期分岐（フェーズ invalid / 台帳欠落 / 保証節がパース不能）は
# index・guarantees を実施できないまま Step 9 へ進む。これらを未定義のまま残すと
# 報告テンプレートが未定義値を読み、実行主体（LLM）が値を捏造することになるため、
# 経路ごとに null で初期化し、報告側でも null を「未検査」として書き分けさせる。
assert_ref_contains "早期失敗は未実施フィールドを null で明示的に初期化する" \
  '**早期失敗（5.5-1〜5.5-3 で以降の手順を実行せずに Step 6 へ進む経路）の `guaranteeCheck` は、実施できなかったフィールドを `null` で明示的に初期化する**'
assert_ref_contains "未検査を {} / [] / 0件 で埋めない" \
  '**`{}` や `[]`・`0件` で埋めないこと**'
assert_ref_contains "早期失敗では humanReview を必ず1件以上入れる" \
  '早期失敗の経路では `humanReview` を必ず1件以上入れる'

assert_skill_contains "経路1（フェーズ invalid）の guaranteeCheck が index/guarantees を初期化" \
  '`{ skipped: false, phase: "invalid", allConsistent: false, index: null, guarantees: null, humanReview: [{ kind: "phase_invalid"'
assert_ref_contains "経路2（台帳欠落）の guaranteeCheck が index/guarantees を初期化" \
  '`guaranteeCheck = { skipped: false, phase: "gdd", allConsistent: false, index: null, guarantees: null, humanReview: [{ kind: "ledger_missing"'
assert_ref_contains "経路3（保証節がパース不能）の guaranteeCheck が index/guarantees を初期化" \
  '`guaranteeCheck = { skipped: false, phase: "gdd", allConsistent: false, index: null, guarantees: null, humanReview: [{ kind: "guarantee_section_missing"'

assert_ref_contains "index: null / オブジェクトの意味が定義されている" \
  '**`index` の意味**（形の正本は 5.5-4 の経路表）: `null` = 索引整合チェックを**実行していない**'
assert_ref_contains "guarantees: null / 配列の意味が定義されている" \
  '**`guarantees` の意味**: `null` = 検証対象を**確定できていない**'
assert_ref_contains "空配列を使ってよいのは保証節が「なし」と明示された場合だけ" \
  '**空配列を使ってよいのは、親Issueの保証節が「なし」と明示していた場合（＝検査した結果の0件）だけ**'

assert_ref_contains "報告: index が null のときは未検査と書く" \
  '{index === null ? `⚠️ 未検査（索引整合チェックを実行していません。理由は下の「要人間判定」を参照）`'
assert_ref_contains "報告: guarantees の状態で書き分ける（未検査を空表・0件にしない）" \
  '保証ごとの判定は `guarantees` の状態で書き分ける（**未検査を空表・0件として描かない**）'
assert_ref_contains "報告: guarantees が null のときは表を出さず未検査行を出す" \
  '**`guarantees === null`（未検査。フェーズ不正・台帳欠落・保証節を抽出できなかった経路）** → 表を出さず'
assert_ref_contains "報告: 未検査を「保証 0 件」「問題なし」と書かない" \
  '**この状態を「保証 0 件」「問題なし」と書かないこと**'
assert_ref_contains "報告: 空配列（保証節が「なし」）は対象0件として書く" \
  '**`guarantees` が空配列**（親Issueの保証節が「なし」と明示していた場合のみ）'
assert_ref_contains "報告: 早期失敗では humanReview の一覧を必ず示す" \
  "早期失敗の経路ではこの一覧が唯一の理由の提示先になる"

echo ""
echo "=== (B-5c) 台帳・Issue本文の読み取り規則（散文とスクリプトの規則一致） ==="

assert_ref_contains "読み取り規則を台帳・Issue本文の共通規約として置いている" \
  '**読み取り規則（台帳・親Issue本文に共通。5.5-3 / 5.5-5 / 5.5-6 はこの規則に従う）**'
assert_ref_contains "台帳はスクリプトと同じ規則で読む" \
  '**同じ規則で読む**'
assert_ref_contains "同じ台帳を2つの規則で読む状態を欠陥として明記" \
  "**同じ台帳を2つの規則で読む**"
assert_ref_contains "パース規約の正本は guarantee-index-check の spec" \
  '`scripts/specs/guarantee-index-check.md`「パースの規約」'
assert_ref_contains "コードフェンスの内側は判定対象にしない" \
  '**コードフェンス（``` / ~~~。行頭スペース3個まで）の内側は、台帳・親Issue本文とも一切の判定対象にしない**'
assert_ref_contains "保証は「保証」節の中だけを見る" \
  '**保証は「保証」節の中だけを見る**'
assert_ref_contains "節の外の見出しは登録済みとみなさない" \
  '**節の外にある `### G-...` は登録済みとみなさない**'
assert_ref_contains "保証見出しは ### 見出し行・ID 完全一致・区切りは半角/全角コロン" \
  '**保証見出しは `### ` で始まる見出し行**であり、ID は `G-<数字>-<枝番>` の完全一致、直後の区切りは半角 `:` または全角 `：`'

assert_ref_contains "5.5-5: Grep のヒット自体は登録済みの根拠にならない" \
  '**ヒットしたこと自体は「登録済み」の根拠にならない**'
assert_ref_contains "5.5-5: 条件1 フェンスの外" \
  '1. **コードフェンスの外にある**'
assert_ref_contains "5.5-5: 条件2 「保証」節の中" \
  '2. **「保証」節の中にある**'
assert_ref_contains "5.5-5: 条件3 見出し行かつ ID 完全一致" \
  '3. **`### ` で始まる見出し行**であり、ID が完全一致している'
assert_ref_contains "5.5-5: 記入例・節外・言及だけなら not_registered" \
  "満たさない（見出しが無い／フェンス内の記入例だけ／「保証」節の外／見出しでない本文中の言及だけ）"

assert_ref_contains "5.5-3: Issue本文もフェンス内を対象にしない" \
  '**上記の読み取り規則に従い、コードフェンスの内側にある記述は対象にしない**'
assert_ref_contains "5.5-6: test_refs は読み取り規則で読んだ行だけを転記する" \
  '**上記の読み取り規則で読み取った、当該保証見出し直下の `- テスト:` 行のものだけ**'
assert_ref_contains "5.5-6: 維持の statement も読み取り規則を満たす見出しの文言" \
  "維持なら台帳の約束文（読み取り規則を満たす保証見出しの文言）"

assert_ref_contains "独立2経路の件数突き合わせを義務づけている" \
  '**読み取り規則の突き合わせ（独立2経路の食い違い検出）**'
assert_ref_contains "件数が食い違ったら片方だけ採用して進めない" \
  '**どちらか一方の数字だけを採用して先へ進めない**'
assert_ref_contains "食い違いは ledger_read_mismatch として要人間判定に積む" \
  '`{ kind: "ledger_read_mismatch", detail:'
assert_ref_contains "ledger_read_mismatch が humanReview の語彙に入っている" \
  '`index_error` / `ledger_read_mismatch` / `guarantee_id_scope_mismatch` / `guarantee_provenance_mismatch` / `verification_failed`'

echo ""
echo "=== (B-6) 部分成功≠完全成功 ==="

assert_ref_contains "一部だけ検証できた状態を allConsistent:true にしない" \
  '**対象の一部だけ検証できた状態を `allConsistent: true` にしない**'
assert_ref_contains "(a) の突き合わせは「調べた結果の0件」でのみ満たされる" \
  "(a) の突き合わせを満たせるのは「調べた結果の0件」だけであり、「調べられなかった」では満たされない"
assert_ref_contains "索引の error 非 null 時の空 broken を「問題なし」と読ませない" \
  "「壊れた参照が無い」ことの根拠にならない"

echo ""
echo "=== (B-7) readyForPromotion の論理式 ==="

assert_skill_contains "readyForPromotion に保証整合の1項が追加されている" \
  "AND (guaranteeCheck.skipped === true OR guaranteeCheck.allConsistent === true)"

# 論理式ブロックの AND 項が過不足なく5項（allMerged + 4 つの AND）であること。
# 項が消える・重複するといった書き換えを検出する。
formula_block="$(awk '/^readyForPromotion =$/ {inside=1} inside {print} inside && /^```$/ {exit}' "$SKILL_FILE")"
assert_eq "readyForPromotion の AND 行は5つ（criterion status / needsHumanReview / QC / E2E / 保証整合）" \
  "5" "$(printf '%s\n' "$formula_block" | grep -c '^  AND ')"
assert_eq "保証整合の項は1つだけ（重複記載しない）" \
  "1" "$(printf '%s\n' "$formula_block" | grep -cF 'guaranteeCheck')"

echo ""
echo "=== (B-8) 構造不変条件: GDD 依存の記述が既存ステップへ漏れていない ==="

# default-OFF の担保。GDD 依存の記述が許されるのは
# 「導入部（スキルの説明）」「Step 5.5」「Step 7 の追加1項」「Step 9 の保証整合セクション」だけ。
# Step 1〜5・Step 6・Step 8 に混入すると、SDD期のワークスペースでも挙動が変わりうる。
GDD_TOKEN_RE='guaranteeCheck|guarantee-index-check|detect-dev-phase|guarantee-auditor|保証整合|保証台帳|guarantees\.md|開発フェーズ'

check_section_free_of_gdd() {
  local description="$1" start="$2" end="$3"
  local section hits
  section="$(skill_section "$start" "$end")"
  if [ -z "$section" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("${description}（セクションを切り出せず判定不能）")
    echo "  NG - ${description}: セクション（${start} 〜 ${end}）を切り出せず判定不能"
    return
  fi
  hits="$(printf '%s\n' "$section" | grep -nE "$GDD_TOKEN_RE")"
  local grep_exit=$?
  if [ "$grep_exit" -ge 2 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("${description}（grep 実行エラーで判定不能）")
    echo "  NG - ${description}: grep 実行エラー（exit ${grep_exit}）のため判定不能"
  elif [ -n "$hits" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       ${hits}"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  fi
}

check_section_free_of_gdd "Step 1〜5 に GDD 依存の記述が無い" "## 実行手順" "### Step 5.5:"
check_section_free_of_gdd "Step 6（品質フェーズ）に GDD 依存の記述が無い" "### Step 6:" "### Step 7:"
check_section_free_of_gdd "Step 8（後始末）に GDD 依存の記述が無い" "### Step 8:" "### Step 9:"

# Step 5.5 セクション内で `skipped: true` を sdd 以外の状況へ広げる記述が無いこと
# （「台帳が無い場合は skipped: true」のような緩和が入り込むと、未検査のまま
#  readyForPromotion が true になりうる）。
# 検査対象は「SKILL.md の Step 5.5」と「参照ファイル全体」の結合テキスト。
# 手順の本体が参照ファイルへ分割されたため、片方だけを見ると検査強度が落ちる。
step55="$(skill_section "### Step 5.5:" "### Step 6:")"
if [ -n "$step55" ] && [ -r "$REF_FILE" ]; then
  step55="${step55}
$(cat "$REF_FILE")"
fi
if [ -z "$step55" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("Step 5.5 セクションを切り出せず判定不能")
  echo "  NG - Step 5.5 セクションを切り出せず判定不能"
else
  skipped_lines="$(printf '%s\n' "$step55" | grep -F -e 'skipped": true' -e 'skipped: true')"
  skipped_grep_exit=$?
  skipped_violations=""
  if [ "$skipped_grep_exit" -ge 2 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("skipped 記述チェックの grep 実行に失敗")
    echo "  NG - skipped 記述チェックの grep 実行エラー（exit ${skipped_grep_exit}）のため判定不能"
    skipped_lines=""
    step55=""
  elif [ -z "$skipped_lines" ]; then
    # Step 5.5 に `skipped: true` の記述が1件も無いのは、SDD期の扱いが
    # 抜け落ちた状態（= 正準文の消失）なので、違反として扱う。
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("Step 5.5 に skipped: true の記述が1件も無い")
    echo "  NG - Step 5.5 に skipped: true の記述が1件も無い（SDD期の扱いが消えている）"
    step55=""
  else
    skipped_violations="$(printf '%s\n' "$skipped_lines" | grep -vE 'sdd|SDD期|しない|してよいのは')"
  fi
fi

if [ -n "$step55" ]; then
  if [ -n "$skipped_violations" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("Step 5.5 に skipped を sdd 以外へ広げる記述が混入")
    echo "  NG - Step 5.5 に skipped を sdd 以外へ広げる記述が混入"
    echo "       ${skipped_violations}"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - Step 5.5 の skipped は sdd 確定時に限定されたまま"
  fi
fi

# 素の Grep 指示の再発防止。Step 5.5 内で Grep に言及する行は、必ず読み取り規則
# （フェンス・節の範囲）で制約されていなければならない。素の文字列一致で台帳を読む
# 指示が入ると、スクリプトが無視する記入例を「登録済み」と誤認する経路が再び開く。
if [ -n "$step55" ]; then
  grep_lines="$(printf '%s\n' "$step55" | grep -F 'Grep')"
  grep_lines_exit=$?
  if [ "$grep_lines_exit" -ge 2 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("Grep 指示チェックの grep 実行に失敗")
    echo "  NG - Grep 指示チェックの grep 実行エラー（exit ${grep_lines_exit}）のため判定不能"
  elif [ -z "$grep_lines" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - Step 5.5 に Grep の指示は無い（制約すべき箇所が存在しない）"
  else
    unconstrained="$(printf '%s\n' "$grep_lines" | grep -vE '読み取り規則|フェンス|根拠にならない')"
    if [ -n "$unconstrained" ]; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("Step 5.5 に読み取り規則で制約されていない Grep 指示がある")
      echo "  NG - Step 5.5 に読み取り規則で制約されていない Grep 指示がある"
      echo "       ${unconstrained}"
    else
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok - Step 5.5 の Grep 指示はすべて読み取り規則で制約されている"
    fi
  fi
fi

# 早期失敗オブジェクトの初期化漏れ検査（将来 fail-closed の経路が増えたときの再発防止）。
# Step 5.5 内で `allConsistent: false` と `humanReview:` を同時に含む行は早期失敗の
# guaranteeCheck リテラルであり、いずれも `index: null, guarantees: null` を持たねばならない
# （持たないと Step 9 のテンプレートが未定義値を読み、実行主体が値を捏造することになる）。
if [ -n "$step55" ]; then
  early_lines="$(printf '%s\n' "$step55" | grep -F 'allConsistent: false' | grep -F 'humanReview:')"
  early_grep_exit=$?
  if [ "$early_grep_exit" -ge 2 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("早期失敗オブジェクトの初期化検査の grep 実行に失敗")
    echo "  NG - 早期失敗オブジェクトの初期化検査の grep 実行エラー（exit ${early_grep_exit}）のため判定不能"
  elif [ -z "$early_lines" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("Step 5.5 に早期失敗の guaranteeCheck リテラルが1件も無い")
    echo "  NG - Step 5.5 に早期失敗の guaranteeCheck リテラルが1件も無い（fail-closed 経路の記述が消えている）"
  else
    early_total="$(printf '%s\n' "$early_lines" | grep -c .)"
    early_initialized="$(printf '%s\n' "$early_lines" | grep -cF 'index: null, guarantees: null')"
    assert_eq "早期失敗の guaranteeCheck は全経路が index/guarantees を null 初期化（${early_total} 経路）" \
      "$early_total" "$early_initialized"
  fi
fi

echo ""
echo "=== (B-5d) チェック状態で対象を絞らない（完了した保証が黙って抜けない） ==="

assert_ref_contains "チェックリスト行は [ ] / [x] / [X] を等しく対象にする" \
  '**チェックリスト行は `- [ ]` / `- [x]` / `- [X]` を等しく対象にする**'
assert_ref_contains "既存の受入基準抽出と同じ扱いであることを明示" \
  '既存の受入基準抽出 `extract-acceptance-criteria` と同じ扱い'
assert_ref_contains "チェック状態を絞り込みにも判定にも使わない" \
  '**チェック状態を対象の絞り込みにも判定にも使わないこと**'
assert_ref_contains "未チェックだけを拾うと完了した保証が黙って抜けると明記" \
  '**完了した保証ほど登録確認・意味検証から黙って抜け落ちる**'
assert_ref_contains "targets から外れた保証は (a) にも現れないと明記" \
  '`targets` から外れた保証は (a) の突き合わせにも現れないため、検証されないまま `allConsistent` が真になりうる'
assert_ref_contains "人間のチェックは検証結果の代用にならない" \
  '**人間が付けたチェックは検証結果の代用にならない**'
assert_ref_contains "5.5-3 の新規宣言はチェック済み行も等しく対象にする" \
  '**`- [x]` / `- [X]` のチェック済み行も等しく対象にする**'
assert_ref_contains "5.5-3 の維持もチェック状態によらず対象にする" \
  "またチェック状態によらず対象にする"

# 構造不変条件: 抽出規則をチェック状態で絞る書き方（未チェックだけを挙げる記述）が
# 混入していないこと。`- [ ]` を書いている行は、必ずチェック済みの表記も併記していること。
unchecked_only=""
marker_grep_failed=""
for f in "$SKILL_FILE" "$REF_FILE"; do
  hits="$(grep -nF -- '- [ ]' "$f")"
  hits_exit=$?
  if [ "$hits_exit" -ge 2 ]; then
    marker_grep_failed="${marker_grep_failed}${f} "
    continue
  fi
  [ -z "$hits" ] && continue
  bad="$(printf '%s\n' "$hits" | grep -vF -e '[x]' -e '[X]')"
  if [ -n "$bad" ]; then
    unchecked_only="${unchecked_only}${f}: ${bad}
"
  fi
done
if [ -n "$marker_grep_failed" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("チェックリストマーカー検査の grep 実行に失敗")
  echo "  NG - チェックリストマーカー検査の grep 実行に失敗: ${marker_grep_failed}"
elif [ -n "$unchecked_only" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("未チェックのマーカーだけを対象にする記述がある")
  echo "  NG - 未チェックのマーカーだけを対象にする記述がある（完了した項目が黙って抜ける）"
  echo "       ${unchecked_only}"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - チェックリストの記述はすべてチェック済み・未チェックを併記している"
fi

# チェック済みの保証が未登録・不整合だったときに算出式が落ちること（(c) が偽になる経路）
assert_eq "チェック済み保証が not_registered/drifted なら allConsistent は false" \
  "false" "$(eval_all_consistent 1 1 0 1)"
assert_eq "チェック済み保証が targets から落ちて (a) が偽なら allConsistent は false" \
  "false" "$(eval_all_consistent 0 1 1 1)"

echo ""
echo "=== (B-5e) index の形は全経路で定義済み（報告テンプレートが未定義値を読まない） ==="

# 索引整合チェックの結果を index に落とす経路は複数ある（正常 pass / 正常 fail /
# status と exit code の食い違い / exit 2 / パース不能 / 実行不能 / 早期失敗）。
# 報告テンプレートは index.error / index.counts.broken を読むため、経路ごとに形が
# 定義されていないと実行主体が未定義値を読む（＝値を捏造する）ことになる。
assert_ref_contains "index の形を経路によらず定義済みにする方針が明記されている" \
  '**`index` の形は経路によらず定義済みにする**'
assert_ref_contains "食い違い時は取得した JSON を破棄せず保持する" \
  '取得できた JSON は**破棄せずそのまま保持**し、`status` を `"fail"` へ上書き'
assert_ref_contains "食い違い時も counts/broken/ledger/base を捨てない" \
  '**`counts` / `broken` / `ledger` / `base` は取得できているので捨てない**'
assert_ref_contains "食い違いは humanReview に積み (d) で allConsistent が false になる" \
  '5.5-7 の (d) により `allConsistent` は `false` になる'
assert_ref_contains "実行不能系は counts/broken を null で明示初期化する" \
  '`guaranteeCheck.index = { "status": "fail", "ledger": null, "base": null, "counts": null, "broken": null, "error": "<stderr のメッセージ>" }`'
assert_ref_contains "broken を [] ・counts を 0 で埋めない" \
  '**`broken` を `[]`、`counts` を 0 で埋めない**'
assert_ref_contains "報告は counts の null / 非 null で文言が変わると明記" \
  '**`error` が非 null の経路では、`counts` が `null`（＝検査自体が走っていない）か、非 null（＝走ったが結果を採用しない）かで報告の文言が変わる**'
assert_ref_contains "報告テンプレートに counts === null の分岐がある" \
  'index.error && index.counts === null ?'
assert_ref_contains "報告テンプレートに参考値（食い違い）の分岐がある" \
  '⚠️ 結果を採用できません'
assert_ref_contains "参考値を pass の根拠にしないと明記" \
  "この値は検証していない参考値であり、pass の根拠にしない"
assert_ref_contains "guarantees の各要素も全フィールドを必ず埋める" \
  '**配列の各要素は `{guarantee_id, kind, registered, verdict, evidence, needsHumanReview}` の全フィールドを必ず埋める**'
assert_ref_contains "not_registered でも evidence を空にしない" \
  'fan-out に掛けなかった `not_registered` の要素でも `evidence` を空にせず'

# 構造不変条件: 経路表の行数と、形が定義されている行数が一致すること。
# 経路を足したのに形を書かない（セルが空・欠落）と落ちる。
table_rows="$(awk '/^\| 経路 \| `index` 全体 \|/ {inside=1; next} inside && /^\|---/ {next} inside && /^\|/ {print} inside && !/^\|/ {exit}' "$REF_FILE")"
row_total="$(printf '%s\n' "$table_rows" | grep -c .)"
# 各行が6セル（経路 + index全体 + status + error + counts + broken）すべて非空であること
defined_rows="$(printf '%s\n' "$table_rows" | awk -F'|' '{
  ok = 1
  for (i = 2; i <= 7; i++) {
    cell = $i
    gsub(/^[ \t]+|[ \t]+$/, "", cell)
    if (cell == "") { ok = 0 }
  }
  if (ok && NF >= 7) { count++ }
} END { print count + 0 }')"
assert_eq "index の経路表は7経路を列挙している（正常2 / 食い違い / exit2 / パース不能 / 実行不能 / 早期失敗）" \
  "7" "$row_total"
assert_eq "経路表の全行で形が定義されている（空セルが無い）" \
  "$row_total" "$defined_rows"

# 食い違い経路: humanReview に積まれる → (d) が偽 → allConsistent は false
assert_eq "status と exit code の食い違いがあれば allConsistent は false" \
  "false" "$(eval_all_consistent 1 1 1 0)"

echo ""
echo "=== (B-5f) 新規宣言の ID スコープと出自（D-11 の強制） ==="

# 保証 ID は宣言元 Issue 番号をスコープに持つ（D-11）。親Issue が新たに宣言できるのは
# G-<親Issue番号>- で始まる ID だけだが、guarantee-index-check は ID の一般形しか
# 検証しないため、別 Issue スコープの ID（例: G-999-1）は台帳に見出しがあり参照テストが
# 整合していれば索引・意味検証の両方を通過してしまう。散文側で targets に入れる前に弾く。
assert_ref_contains "新規宣言は G-<親Issue番号>- で始まる ID だけであることを明記" \
  '**親Issue が新たに宣言できるのは `G-<親Issue番号>-` で始まる ID だけ**'
assert_ref_contains "ID スコープ検証は targets に入れる前に行う" \
  '**新規宣言の ID スコープ検証（`targets` に入れる前に行う）**'
assert_ref_contains "スコープ不一致は targets に入れない" \
  '**`targets` に入れない**'
assert_ref_contains "スコープ不一致は guarantee_id_scope_mismatch として積む" \
  '`{ kind: "guarantee_id_scope_mismatch", detail:'
assert_ref_contains "スコープ不一致を targets に入れて通す経路を作らない" \
  '**`targets` に入れて検証を通す経路を作らないこと**'
assert_ref_contains "index-check はスコープの誤りを捕まえられないと明記" \
  '`guarantee-index-check` は ID の一般形しか検証せず、スコープの誤りは捕まえられない'
assert_ref_contains "ハイフンまで含めて比較する（前方一致の取り違え防止）" \
  '`G-158-` と `G-1580-` を前方一致で取り違えないよう、ハイフンまで含めて比較する'
assert_ref_contains "スコープ制約は新規宣言にだけ課す" \
  '**この制約は新規宣言にだけ課す**'
assert_ref_contains "維持する保証は他 Issue 由来が正常でありスコープ検証の対象外" \
  '**「維持する保証」は他 Issue 由来の既存保証を挙げるのが正常な運用**'
assert_ref_contains "宣言元の突き合わせ手順がある" \
  '**新規宣言の出自の突き合わせ（`宣言元` 行）**'
assert_ref_contains "宣言元の不一致は guarantee_provenance_mismatch として積む" \
  '`{ kind: "guarantee_provenance_mismatch", detail:'
assert_ref_contains "宣言元が無い場合は弾かないが「確認した」とも書かない" \
  '**「宣言元の一致を確認した」とは書かない**'
assert_ref_contains "宣言元が無い場合の evidence の書き方が定義されている" \
  '台帳に `宣言元` の記載が無く突き合わせ不能（ID スコープ検査は通過）'
assert_ref_contains "維持する保証には宣言元の突き合わせを行わない" \
  '**維持する保証には `宣言元` の突き合わせを行わない**'
assert_ref_contains "読み取り規則に宣言元行の書式がある" \
  '**宣言元は保証見出し直下の `- 宣言元: #<番号>` 行**'

# ①別スコープの ID → humanReview に積まれる → (d) が偽 → allConsistent は false
assert_eq "①別スコープの新規宣言 ID があれば allConsistent は false" \
  "false" "$(eval_all_consistent 1 1 1 0)"
# ②正しいスコープで他の条件も満たすなら true（過剰に落とさない）
assert_eq "②正しいスコープの ID なら他の条件次第で true になりうる" \
  "true" "$(eval_all_consistent 1 1 1 1)"
# ③維持する保証は他 Issue 由来でも弾かれない（スコープ検証の対象外である旨は上の正準文で担保）
assert_ref_not_contains "維持する保証にスコープ検証を課す記述が無い" \
  '維持する保証も `G-<親Issue番号>-`'

echo ""
echo "=== (B-10) 要人間判定と allConsistent の接続（安全機構が算出式に入っていること） ==="

# humanReview に理由が記録されるのに算出式へ反映されない項目があると、
# 「安全機構が働いたのに allConsistent が true」になりうる。特に targets が空のときは
# (a)(c) が空虚に真・(b) も真になり、読み取り不一致があっても素通りする（codex P1 指摘）。
# 個別の理由コードごとに項を足すのではなく humanReview の非空そのものを項にすることで、
# 将来 kind が増えても接続漏れが起きない形にしている。
assert_ref_contains "算出式に (d) humanReview が空である の項がある" \
  '(d) guaranteeCheck.humanReview が空である（1件でもあれば allConsistent は false）'
assert_ref_contains "不変条件: humanReview に理由が入るなら allConsistent は必ず false" \
  '**不変条件**: `humanReview` に1件でも理由が入るなら、`allConsistent` は必ず `false` になる'
assert_ref_contains "理由コードごとに項を足す方式を採らない理由が明記されている" \
  '**理由コードを追加したときに算出式へ接続し忘れる事故**'
assert_ref_contains "humanReview は昇格を止める理由だけを入れる場所である" \
  '**要人間判定＝昇格を止める理由だけ**'
assert_ref_contains "targets が空でも安全側に倒れることを明記" \
  '**空集合でも安全側に倒れる**'
assert_ref_contains "空 targets で (a)(c) が空虚に真になることを明記" \
  '**(a)(c) は0件について空虚に真になる**'
assert_ref_contains "読み取り不一致は算出式の (d) として反映されると明記" \
  '**この不一致は 5.5-7 の算出式の (d) として反映される**'
assert_ref_not_contains "空 targets を「(b) だけで決まる」と書いていない（緩和の再発防止）" \
  '(b) の索引整合だけで決まる'
assert_skill_contains "Step 7 の注意に読み取り不一致（humanReview 非空）が含まれる" \
  '台帳の読み取り件数がスクリプトと食い違っている（`humanReview` に理由が1件でもある）'

# 算出式ブロックの構造検査: 項は (a)〜(d) の4本で、(d) が humanReview を参照していること
ac_block="$(awk '/^guaranteeCheck.allConsistent =$/ {inside=1} inside {print} inside && /^```$/ {exit}' "$REF_FILE")"
assert_eq "allConsistent の項は4本（(a) 突き合わせ / (b) 索引 / (c) verdict / (d) humanReview）" \
  "4" "$(printf '%s\n' "$ac_block" | grep -cE '^ +(AND )?\([a-d]\) ')"
assert_eq "(d) の項が humanReview を参照している" \
  "1" "$(printf '%s\n' "$ac_block" | grep -E '^ +AND \(d\) ' | grep -cF 'humanReview')"

# 真理値表の評価はファイル冒頭で定義した eval_all_consistent を使う
# （構造検査で「項が (a)〜(d) の4本であること」を文書側から確認したうえで AND 結合を評価する）。
assert_eq "①読み取り不一致あり（(a)(b)(c) は真）→ allConsistent は false" \
  "false" "$(eval_all_consistent 1 1 1 0)"
assert_eq "②targets が空で (a)(c) が空虚に真・索引 pass でも、不一致があれば false" \
  "false" "$(eval_all_consistent 1 1 1 0)"
assert_eq "③すべて満たすときだけ true（安全側に倒しすぎて常に false ではない）" \
  "true" "$(eval_all_consistent 1 1 1 1)"

# ③の構造版: 語彙にあるすべての kind について、humanReview に入れば false になること。
# (d) は kind を問わない項のため、語彙を1件ずつ回して漏れが無いことを確認する
# （将来 kind が追加されても、語彙行に足すだけで本検査の対象になる）。
kinds_line="$(grep -F '`humanReview[].kind` の語彙:' "$REF_FILE")"
kinds="$(printf '%s' "$kinds_line" | grep -oE '`[a-z_]+`' | tr -d '`' | grep -v '^humanReview$')"
kind_total="$(printf '%s\n' "$kinds" | grep -c .)"
if [ "$kind_total" -lt 5 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("humanReview の語彙行を解析できない（kind が ${kind_total} 件しか取れない）")
  echo "  NG - humanReview の語彙行を解析できない（kind が ${kind_total} 件しか取れない）"
else
  kind_failures=0
  for kind in $kinds; do
    # humanReview に kind が1件でも入っている状態 = (d) が偽
    if [ "$(eval_all_consistent 1 1 1 0)" != "false" ]; then
      kind_failures=$((kind_failures + 1))
      echo "       kind=${kind} で allConsistent が false にならない"
    fi
  done
  assert_eq "語彙のすべての kind（${kind_total} 件）で humanReview 非空 → allConsistent は false" \
    "0" "$kind_failures"
fi

echo ""
echo "=== (B-9) 分割の整合（SKILL.md ↔ 参照ファイル） ==="

# Step 5.5 の手順は参照ファイルへ分割されている。参照が「必要なら読む」ではなく
# 「これに従って実行する」形で書かれていること、および手順の本体が SKILL.md 側へ
# 二重に残っていないこと（更新漏れによる二重管理の防止）を検査する。
assert_skill_contains "SKILL.md は手順の正本が参照ファイルであることを明示している" \
  '**手順の正本は参照ファイル `references/guarantee-consistency.md`**'
assert_skill_contains "SKILL.md は参照ファイルを Read してその手順に従わせる" \
  '参照ファイルを Read し、その手順・形式に従って `guaranteeCheck` を組み立てる'
assert_skill_contains "SKILL.md に参照ファイルのプラグイン配下パスが書かれている" \
  '`${CLAUDE_PLUGIN_ROOT}/skills/promote-verify/references/guarantee-consistency.md`'
assert_skill_contains "SKILL.md に Base directory 起点の解決手順が書かれている" \
  '`<base>/references/guarantee-consistency.md`'
assert_skill_contains "Step 9 は保証整合セクションの中身を参照ファイルの報告形式に従わせる" \
  '「保証整合セクションの報告形式」に従う'
assert_ref_contains "参照ファイルは SKILL.md 側で完了している前提を明示している" \
  "**本ファイルの前提**"
assert_ref_contains "参照ファイルは SKILL.md が正本の規律を複製しないと明示している" \
  "本ファイルには複製しない"

# 手順本体（サブステップ見出し）は参照ファイルにだけ存在し、SKILL.md には残っていない
dup_violations=""
missing_headings=""
for heading in "### 5.5-2." "### 5.5-3." "### 5.5-4." "### 5.5-5." "### 5.5-6." "### 5.5-7."; do
  if ! grep -qF -- "$heading" "$REF_FILE"; then
    missing_headings="${missing_headings}${heading} "
  fi
  if grep -qF -- "#$heading" "$SKILL_FILE" || grep -qF -- "$heading" "$SKILL_FILE"; then
    dup_violations="${dup_violations}${heading} "
  fi
done
assert_eq "サブステップ見出しは参照ファイルにすべて存在する" "" "$missing_headings"
assert_eq "サブステップ見出しは SKILL.md 側に残っていない（二重管理の防止）" "" "$dup_violations"

# ---------------------------------------------------------------------------
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
