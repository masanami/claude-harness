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
#  (B) SKILL.md の契約文（正準文）の存在検査と構造不変条件
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
SKILL_FILE="${REPO_ROOT}/skills/promote-verify/SKILL.md"

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
# (B) SKILL.md の契約文（正準文）の存在検査
# ---------------------------------------------------------------------------
echo ""
echo "=== (B-1) Step 5.5 の発動判定とスクリプト実行形 ==="

assert_skill_contains "発動判定はランチャー経由の detect-dev-phase" \
  "claude-harness-run detect-dev-phase"
assert_skill_contains "索引整合はランチャー経由の guarantee-index-check" \
  "claude-harness-run guarantee-index-check"
assert_skill_contains "フェーズ判定はスクリプト出力のみ（CLAUDE.md を独自に grep しない）" \
  '`CLAUDE.md` を自分で grep しないこと'
assert_skill_contains "意味整合は guarantee-auditor への fan-out" \
  "subagent_type: 'claude-harness:guarantee-auditor'"
assert_skill_contains "fan-out のチャンクサイズは Step 4 と同じ10件" \
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
assert_skill_contains "GDD期に台帳が無い場合は skipped にしない" \
  '**`skipped` にしない**'
assert_skill_contains "台帳欠落は運用前提の破れとして扱う" \
  "GDD期を宣言しているのに駆動文書が無い"
assert_skill_contains "Step 7 でも skipped を sdd 以外へ広げないことを明記" \
  '**Step 5.5-1 のフェーズ判定が `sdd` として確定した場合だけ**である'

echo ""
echo "=== (B-4) 検査不能≠0件 ==="

assert_skill_contains "索引整合の exit 2・パース不能・実行不能は fail 扱い" \
  '`guaranteeCheck.index = { "status": "fail", "error": "<stderr のメッセージ>" }` とする'
assert_skill_contains "索引整合の実行不能を pass・検査対象なしに読み替えない" \
  '**`pass` や「検査対象なし」に読み替えない**'
assert_skill_contains "検査不能は問題0件と同じではない" \
  "検査不能は「問題0件」と同じではない"
assert_skill_contains "保証節を抽出できない場合に対象0件として進めない" \
  "**対象0件（空配列）として先へ進めないこと**"
assert_skill_contains "空配列で allConsistent が真になる罠を明記" \
  '**保証を1件も検証していないのに `allConsistent: true` が成立する**'
assert_skill_contains "報告では未検証を0件と書かない" \
  "「0件」ではなく「未検証」と書くこと"

echo ""
echo "=== (B-5) allConsistent が false になる各ケース（skipped へ変換しない） ==="

assert_skill_contains "drifted/uncertain/verification_failed/not_registered/結果の欠落は allConsistent:false" \
  '- **`drifted` / `uncertain` / `verification_failed` / `not_registered` / 結果の欠落は、いずれも `allConsistent: false`** とし、**`skipped` へ変換しない**'
assert_skill_contains "検証失敗（構造化応答なし）は verification_failed として積む" \
  '`verdict: "verification_failed"` / `evidence: "guarantee-auditor agent failed"` として積む'
assert_skill_contains "検証失敗を consistent にも skipped にも変換しない" \
  '**`consistent` にも `skipped` にも変換しない**'
assert_skill_contains "台帳未追記は not_registered（検証済み・スキップにしない）" \
  '**未追記を「検証済み」にも「スキップ」にもしない**'
assert_skill_contains "未追記の保証を targets から取り除かない" \
  '**未追記の保証を `targets` から取り除いて件数を合わせない**'
assert_skill_contains "台帳登録確認は ID の完全一致（前方一致で取り違えない）" \
  '前方一致で `G-158-1` と `G-158-10` を取り違えないこと'
assert_skill_contains "新規宣言の意味検証は親Issueの（裁可された）約束文を正とする" \
  '**`statement` は、新規宣言なら親Issueの保証節の約束文（裁可された文言が正）'
assert_skill_contains "台帳の約束文が親Issueの約束文と食い違う場合は drifted" \
  '**新規宣言で、台帳に登録された約束文が親Issueの約束文と食い違っている場合は、その不一致自体を `verdict: "drifted"` として記録する**'
assert_skill_contains "(a) の突き合わせは件数だけでなく ID で行う" \
  "(a) targets の各 guarantee_id に対応する結果が guarantees に1件ずつ存在する（件数だけでなく ID を突き合わせる）"

echo ""
echo "=== (B-5b) 早期失敗経路の出力契約（未検査フィールドの明示的初期化と報告） ==="

# fail-closed の早期分岐（フェーズ invalid / 台帳欠落 / 保証節がパース不能）は
# index・guarantees を実施できないまま Step 9 へ進む。これらを未定義のまま残すと
# 報告テンプレートが未定義値を読み、実行主体（LLM）が値を捏造することになるため、
# 経路ごとに null で初期化し、報告側でも null を「未検査」として書き分けさせる。
assert_skill_contains "早期失敗は未実施フィールドを null で明示的に初期化する" \
  '**早期失敗（5.5-1〜5.5-3 で以降の手順を実行せずに Step 6 へ進む経路）の `guaranteeCheck` は、実施できなかったフィールドを `null` で明示的に初期化する**'
assert_skill_contains "未検査を {} / [] / 0件 で埋めない" \
  '**`{}` や `[]`・`0件` で埋めないこと**'
assert_skill_contains "早期失敗では humanReview を必ず1件以上入れる" \
  '早期失敗の経路では `humanReview` を必ず1件以上入れる'

assert_skill_contains "経路1（フェーズ invalid）の guaranteeCheck が index/guarantees を初期化" \
  '`{ skipped: false, phase: "invalid", allConsistent: false, index: null, guarantees: null, humanReview: [{ kind: "phase_invalid"'
assert_skill_contains "経路2（台帳欠落）の guaranteeCheck が index/guarantees を初期化" \
  '`guaranteeCheck = { skipped: false, phase: "gdd", allConsistent: false, index: null, guarantees: null, humanReview: [{ kind: "ledger_missing"'
assert_skill_contains "経路3（保証節がパース不能）の guaranteeCheck が index/guarantees を初期化" \
  '`guaranteeCheck = { skipped: false, phase: "gdd", allConsistent: false, index: null, guarantees: null, humanReview: [{ kind: "guarantee_section_missing"'

assert_skill_contains "index: null / オブジェクトの意味が定義されている" \
  '**`index` の意味**: `null` = 索引整合チェックを**実行していない**'
assert_skill_contains "guarantees: null / 配列の意味が定義されている" \
  '**`guarantees` の意味**: `null` = 検証対象を**確定できていない**'
assert_skill_contains "空配列を使ってよいのは保証節が「なし」と明示された場合だけ" \
  '**空配列を使ってよいのは、親Issueの保証節が「なし」と明示していた場合（＝検査した結果の0件）だけ**'

assert_skill_contains "報告: index が null のときは未検査と書く" \
  '{index === null ? `⚠️ 未検査（索引整合チェックを実行していません。理由は下の「要人間判定」を参照）`'
assert_skill_contains "報告: guarantees の状態で書き分ける（未検査を空表・0件にしない）" \
  '保証ごとの判定は `guarantees` の状態で書き分ける（**未検査を空表・0件として描かない**）'
assert_skill_contains "報告: guarantees が null のときは表を出さず未検査行を出す" \
  '**`guarantees === null`（未検査。フェーズ不正・台帳欠落・保証節を抽出できなかった経路）** → 表を出さず'
assert_skill_contains "報告: 未検査を「保証 0 件」「問題なし」と書かない" \
  '**この状態を「保証 0 件」「問題なし」と書かないこと**'
assert_skill_contains "報告: 空配列（保証節が「なし」）は対象0件として書く" \
  '**`guarantees` が空配列**（親Issueの保証節が「なし」と明示していた場合のみ）'
assert_skill_contains "報告: 早期失敗では humanReview の一覧を必ず示す" \
  "早期失敗の経路ではこの一覧が唯一の理由の提示先になる"

echo ""
echo "=== (B-5c) 台帳・Issue本文の読み取り規則（散文とスクリプトの規則一致） ==="

assert_skill_contains "読み取り規則を台帳・Issue本文の共通規約として置いている" \
  '**読み取り規則（台帳・親Issue本文に共通。5.5-3 / 5.5-5 / 5.5-6 はこの規則に従う）**'
assert_skill_contains "台帳はスクリプトと同じ規則で読む" \
  '**同じ規則で読む**'
assert_skill_contains "同じ台帳を2つの規則で読む状態を欠陥として明記" \
  "**同じ台帳を2つの規則で読む**"
assert_skill_contains "パース規約の正本は guarantee-index-check の spec" \
  '`scripts/specs/guarantee-index-check.md`「パースの規約」'
assert_skill_contains "コードフェンスの内側は判定対象にしない" \
  '**コードフェンス（``` / ~~~。行頭スペース3個まで）の内側は、台帳・親Issue本文とも一切の判定対象にしない**'
assert_skill_contains "保証は「保証」節の中だけを見る" \
  '**保証は「保証」節の中だけを見る**'
assert_skill_contains "節の外の見出しは登録済みとみなさない" \
  '**節の外にある `### G-...` は登録済みとみなさない**'
assert_skill_contains "保証見出しは ### 見出し行・ID 完全一致・区切りは半角/全角コロン" \
  '**保証見出しは `### ` で始まる見出し行**であり、ID は `G-<数字>-<枝番>` の完全一致、直後の区切りは半角 `:` または全角 `：`'

assert_skill_contains "5.5-5: Grep のヒット自体は登録済みの根拠にならない" \
  '**ヒットしたこと自体は「登録済み」の根拠にならない**'
assert_skill_contains "5.5-5: 条件1 フェンスの外" \
  '1. **コードフェンスの外にある**'
assert_skill_contains "5.5-5: 条件2 「保証」節の中" \
  '2. **「保証」節の中にある**'
assert_skill_contains "5.5-5: 条件3 見出し行かつ ID 完全一致" \
  '3. **`### ` で始まる見出し行**であり、ID が完全一致している'
assert_skill_contains "5.5-5: 記入例・節外・言及だけなら not_registered" \
  "満たさない（見出しが無い／フェンス内の記入例だけ／「保証」節の外／見出しでない本文中の言及だけ）"

assert_skill_contains "5.5-3: Issue本文もフェンス内を対象にしない" \
  '**上記の読み取り規則に従い、コードフェンスの内側にある記述は対象にしない**'
assert_skill_contains "5.5-6: test_refs は読み取り規則で読んだ行だけを転記する" \
  '**上記の読み取り規則で読み取った、当該保証見出し直下の `- テスト:` 行のものだけ**'
assert_skill_contains "5.5-6: 維持の statement も読み取り規則を満たす見出しの文言" \
  "維持なら台帳の約束文（読み取り規則を満たす保証見出しの文言）"

assert_skill_contains "独立2経路の件数突き合わせを義務づけている" \
  '**読み取り規則の突き合わせ（独立2経路の食い違い検出）**'
assert_skill_contains "件数が食い違ったら片方だけ採用して進めない" \
  '**どちらか一方の数字だけを採用して先へ進めない**'
assert_skill_contains "食い違いは ledger_read_mismatch として要人間判定に積む" \
  '`{ kind: "ledger_read_mismatch", detail:'
assert_skill_contains "ledger_read_mismatch が humanReview の語彙に入っている" \
  '`index_error` / `ledger_read_mismatch` / `verification_failed`'

echo ""
echo "=== (B-6) 部分成功≠完全成功 ==="

assert_skill_contains "一部だけ検証できた状態を allConsistent:true にしない" \
  '**対象の一部だけ検証できた状態を `allConsistent: true` にしない**'
assert_skill_contains "(a) の突き合わせは「調べた結果の0件」でのみ満たされる" \
  "(a) の突き合わせを満たせるのは「調べた結果の0件」だけであり、「調べられなかった」では満たされない"
assert_skill_contains "索引の error 非 null 時の空 broken を「問題なし」と読ませない" \
  "「壊れた参照が無い」を意味しない"

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
step55="$(skill_section "### Step 5.5:" "### Step 6:")"
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
