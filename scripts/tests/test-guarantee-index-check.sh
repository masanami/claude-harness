#!/bin/bash
# test-guarantee-index-check.sh
# scripts/guarantee-index-check.sh の台帳パース（保証見出し・テスト参照・GAP・ID 重複）と
# CLI 契約（stdout JSON / exit code / 参照解決の基準ディレクトリ）をテストする。gh 非依存。
#
# 実行方法: bash scripts/tests/test-guarantee-index-check.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # フィクスチャ内のバッククォート（テスト参照の囲み・コードフェンス）は
# Markdown のリテラルであり、シェル展開を意図していない
set -u

GIC_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${GIC_TEST_DIR}/../guarantee-index-check.sh"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

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

# GIC_ISSUES 内で指定した理由コードが何件あるかを数える。
count_reason() {
  local reason="$1"
  local entry
  local count=0
  if [ "${#GIC_ISSUES[@]}" -eq 0 ]; then
    printf '%s' "0"
    return 0
  fi
  for entry in "${GIC_ISSUES[@]}"; do
    if [ "${entry##*$'\t'}" = "$reason" ]; then
      count=$((count + 1))
    fi
  done
  printf '%s' "$count"
}

# 指定した理由コードの最初の1件の保証IDを返す（無ければ空文字）。
first_id_for_reason() {
  local reason="$1"
  local entry
  if [ "${#GIC_ISSUES[@]}" -eq 0 ]; then
    return 0
  fi
  for entry in "${GIC_ISSUES[@]}"; do
    if [ "${entry##*$'\t'}" = "$reason" ]; then
      printf '%s' "${entry%%$'\t'*}"
      return 0
    fi
  done
  return 0
}

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

# 検査対象の実ファイルを持つフィクスチャリポジトリ
FIXTURE_REPO="${TMP_ROOT}/fixture-repo"
mkdir -p "${FIXTURE_REPO}/docs" "${FIXTURE_REPO}/e2e" "${FIXTURE_REPO}/tests"
printf 'test("redirects unauthenticated user to login", async () => {});\n' > "${FIXTURE_REPO}/e2e/auth.spec.ts"
printf 'it("returns 400 for invalid json", () => {});\n' > "${FIXTURE_REPO}/tests/contact.test.ts"
(
  cd "$FIXTURE_REPO" || exit 1
  git init -q
)

echo "=== test: 健全な台帳のパース ==="
gic_scan "$(printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-123-1: 約束A\n\n- 種別: API契約\n- テスト: `tests/contact.test.ts::returns 400 for invalid json`\n- 宣言元: #123\n\n### G-130-1: 約束B\n\n- テスト: `e2e/auth.spec.ts::redirects unauthenticated user to login`\n- 宣言元: #130\n\n## Gaps（テストのない公開面）\n\n- [ ] GAP-001: 未整備の公開面\n')"
assert_eq "保証節を検出する" "true" "$GIC_HAS_GUARANTEE_SECTION"
assert_eq "保証を2件数える" "2" "$GIC_GUARANTEE_COUNT"
assert_eq "テスト参照を2件数える" "2" "$GIC_REF_COUNT"
assert_eq "GAP を1件数える" "1" "$GIC_GAP_COUNT"
assert_eq "書式の問題は無い" "0" "${#GIC_ISSUES[@]}"

echo "=== test: 1つの保証に複数のテスト参照を持てる ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `a.test.ts::name one`\n- テスト: `b.test.ts::name two`\n- 宣言元: #1\n')"
assert_eq "テスト参照を2件数える" "2" "$GIC_REF_COUNT"
assert_eq "書式の問題は無い" "0" "${#GIC_ISSUES[@]}"

echo "=== test: ID 重複の検出（採番の単一経路が破れたときの検知） ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-123-1: 約束A\n\n- テスト: `a.test.ts::x`\n- 宣言元: #123\n\n### G-123-1: 約束B（ID が重複）\n\n- テスト: `b.test.ts::y`\n- 宣言元: #123\n')"
assert_eq "duplicate_guarantee_id を1件検出" "1" "$(count_reason duplicate_guarantee_id)"
assert_eq "重複した ID を報告する" "G-123-1" "$(first_id_for_reason duplicate_guarantee_id)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n\n## Gaps\n\n- [ ] GAP-001: ひとつめ\n- [ ] GAP-001: 重複\n')"
assert_eq "duplicate_gap_id を1件検出" "1" "$(count_reason duplicate_gap_id)"

echo "=== test: 書式違反の GAP ID を黙って読み飛ばさない ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n\n## Gaps\n\n- [ ] GAP-?-1: 仮 ID が残っている\n')"
assert_eq "仮 ID の GAP 行を malformed_gap_id として検出" "1" "$(count_reason malformed_gap_id)"
assert_eq "書式違反の行は GAP 件数に数えない" "0" "$GIC_GAP_COUNT"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n\n## Gaps\n\n- [ ] ID を書き忘れた公開面\n')"
assert_eq "ID の無いチェックリスト行も malformed_gap_id" "1" "$(count_reason malformed_gap_id)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n\n## Gaps（テストのない公開面）\n\nこの節はテスト未整備の公開面を並べる。\n\n- [ ] GAP-001: 正しい書式\n')"
assert_eq "チェックリストでない散文は書式違反にしない" "0" "$(count_reason malformed_gap_id)"
assert_eq "正しい書式の GAP は数える" "1" "$GIC_GAP_COUNT"

echo "=== test: 書式違反の検出 ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-?-1: 裁可待ちの仮 ID が残っている\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n')"
assert_eq "malformed_guarantee_id を検出" "1" "$(count_reason malformed_guarantee_id)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- 種別: API契約\n- 宣言元: #1\n')"
assert_eq "テスト参照ゼロ件の保証を検出" "1" "$(count_reason missing_test_ref)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `a.test.ts`\n- 宣言元: #1\n')"
assert_eq '区切り（::）を含まない参照は malformed_test_ref' "1" "$(count_reason malformed_test_ref)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `::name only`\n- 宣言元: #1\n')"
assert_eq "パスが空の参照は malformed_test_ref" "1" "$(count_reason malformed_test_ref)"

echo "=== test: 保証節の外に置かれた保証見出しを黙って無視しない ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n\n## 補足\n\n### G-2-1: 節の外に置かれた保証\n\n- テスト: `b.test.ts::y`\n')"
assert_eq "guarantee_outside_section を検出" "1" "$(count_reason guarantee_outside_section)"
assert_eq "節内の保証だけを数える" "1" "$GIC_GUARANTEE_COUNT"

echo "=== test: バッククォート無しの参照も受け付ける（装飾の欠落では落とさない） ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: a.test.ts::some name\n- 宣言元: #1\n')"
assert_eq "参照として1件記録する" "1" "$GIC_REF_COUNT"
assert_eq "書式違反にはしない" "0" "$(count_reason malformed_test_ref)"

echo "=== test: 太字・全角コロンの許容 ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- **テスト**：`a.test.ts::x`\n- **宣言元**：#1\n')"
assert_eq "太字＋全角コロンのテスト行を拾う" "1" "$GIC_REF_COUNT"

echo "=== test: コードフェンス内の記述は検査対象外 ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n\n```markdown\n### G-999-1: 書式例（実在しない保証）\n\n- テスト: `example.test.ts::example`\n- 宣言元: #999\n```\n')"
assert_eq "フェンス内の保証は数えない" "1" "$GIC_GUARANTEE_COUNT"
assert_eq "フェンス内のテスト参照も拾わない" "1" "$GIC_REF_COUNT"

echo "=== test: 保証節が無い台帳 ==="
gic_scan "$(printf '# 保証台帳\n\n## 概要\n\n- まだ何も無い\n')"
assert_eq "保証節が無いことを検出する" "false" "$GIC_HAS_GUARANTEE_SECTION"

echo "=== test: CRLF 改行でもパースできる ==="
gic_scan "$(printf '## 保証（Guarantees）\r\n\r\n### G-1-1: 約束\r\n\r\n- テスト: `a.test.ts::x`\r\n- 宣言元: #1\r\n')"
assert_eq "保証を1件数える" "1" "$GIC_GUARANTEE_COUNT"
assert_eq "テスト参照を1件数える" "1" "$GIC_REF_COUNT"
assert_eq "書式の問題は無い" "0" "${#GIC_ISSUES[@]}"

echo "=== test: gic_check_refs（実ファイルの検査） ==="
gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 実在する参照\n\n- テスト: `e2e/auth.spec.ts::redirects unauthenticated user to login`\n- 宣言元: #1\n\n### G-2-1: ファイルが無い\n\n- テスト: `e2e/missing.spec.ts::x`\n- 宣言元: #2\n\n### G-3-1: テスト名が無い\n\n- テスト: `e2e/auth.spec.ts::this name does not exist`\n- 宣言元: #3\n')"
gic_check_refs "$FIXTURE_REPO"
assert_eq "test_file_not_found を1件検出" "1" "$(count_reason test_file_not_found)"
assert_eq "test_name_not_found を1件検出" "1" "$(count_reason test_name_not_found)"
assert_eq "実在する参照は問題にしない" "2" "${#GIC_ISSUES[@]}"


echo "=== test: 宣言元行の検査（存在・書式・重複） ==="

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 宣言元あり\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n')"
assert_eq "宣言元が #<数字> なら問題にしない" "0" "${#GIC_ISSUES[@]}"
assert_eq "provenance の kind は issue" "issue" "$(printf '%s' "${GIC_GUARANTEES[0]}" | cut -f4)"
assert_eq "provenance の Issue 番号を取り出す" "1" "$(printf '%s' "${GIC_GUARANTEES[0]}" | cut -f5)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 裁可待ち\n\n- テスト: `a.test.ts::x`\n- 宣言元: 裁可待ち\n')"
assert_eq "裁可待ちは書式違反にしない（ドラフトの規約値）" "0" "${#GIC_ISSUES[@]}"
assert_eq "provenance の kind は pending" "pending" "$(printf '%s' "${GIC_GUARANTEES[0]}" | cut -f4)"
assert_eq "pending の Issue 番号は空" "" "$(printf '%s' "${GIC_GUARANTEES[0]}" | cut -f5)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 宣言元なし\n\n- テスト: `a.test.ts::x`\n')"
assert_eq "宣言元行が無ければ missing_provenance" "1" "$(count_reason missing_provenance)"
assert_eq "provenance の kind は missing" "missing" "$(printf '%s' "${GIC_GUARANTEES[0]}" | cut -f4)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 宣言元が壊れている\n\n- テスト: `a.test.ts::x`\n- 宣言元: あとで書く\n')"
assert_eq "#<数字> でも裁可待ちでもない値は malformed_provenance" "1" "$(count_reason malformed_provenance)"
assert_eq "provenance の kind は malformed" "malformed" "$(printf '%s' "${GIC_GUARANTEES[0]}" | cut -f4)"
assert_eq "malformed でも missing は立てない（1件ずつ数える）" "0" "$(count_reason missing_provenance)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 宣言元が空\n\n- テスト: `a.test.ts::x`\n- 宣言元:\n')"
assert_eq "値が空の宣言元は malformed_provenance（missing に丸めない）" "1" "$(count_reason malformed_provenance)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 宣言元が2行\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n- 宣言元: #2\n')"
assert_eq "宣言元が2行あれば duplicate_provenance" "1" "$(count_reason duplicate_provenance)"
assert_eq "重複時は先頭の読み取り結果を保持する" "1" "$(printf '%s' "${GIC_GUARANTEES[0]}" | cut -f5)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 太字・全角コロン\n\n- テスト: `a.test.ts::x`\n- **宣言元**：#42\n')"
assert_eq "太字＋全角コロンの宣言元行も拾う" "0" "${#GIC_ISSUES[@]}"
assert_eq "太字＋全角コロンでも Issue 番号を取り出す" "42" "$(printf '%s' "${GIC_GUARANTEES[0]}" | cut -f5)"

gic_scan "$(printf '## 保証（Guarantees）\n\n### G-1-1: 実在\n\n- テスト: `a.test.ts::x`\n- 宣言元: #1\n\n```markdown\n### G-999-1: 記入例\n\n- 宣言元: こわれた値\n```\n')"
assert_eq "フェンス内の宣言元は検査しない" "0" "${#GIC_ISSUES[@]}"

echo "=== test: guarantees 配列（台帳の読み取り結果を呼び出し側へ渡す） ==="

GUARANTEES_LEDGER="${FIXTURE_REPO}/docs/guarantees-list.md"
cat > "$GUARANTEES_LEDGER" <<'LEDGER'
# 保証台帳

## 保証（Guarantees）

### G-123-1: 約束A（複数参照）

- 種別: API契約
- テスト: `tests/contact.test.ts::returns 400 for invalid json`
- テスト: `e2e/auth.spec.ts::redirects unauthenticated user to login`
- 宣言元: #123

### 見出しだけで ID 書式を満たさない

- テスト: `tests/contact.test.ts::returns 400 for invalid json`
- 宣言元: #999

## Gaps（テストのない公開面）
LEDGER
LIST_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/guarantees-list.md 2>/dev/null)"
assert_eq "guarantees には ID 書式を満たす見出しだけが並ぶ" \
  "1" "$(jq -r '.guarantees | length' <<<"$LIST_OUT")"
assert_eq "guarantees の guarantee_id" "G-123-1" "$(jq -r '.guarantees[0].guarantee_id' <<<"$LIST_OUT")"
assert_eq "guarantees の statement は区切りより後ろ" \
  "約束A（複数参照）" "$(jq -r '.guarantees[0].statement' <<<"$LIST_OUT")"
assert_eq "guarantees の tests は台帳の記載どおり全件" \
  "2" "$(jq -r '.guarantees[0].tests | length' <<<"$LIST_OUT")"
assert_eq "guarantees の tests の1件目" \
  "tests/contact.test.ts::returns 400 for invalid json" "$(jq -r '.guarantees[0].tests[0]' <<<"$LIST_OUT")"
assert_eq "guarantees の provenance" "123" "$(jq -r '.guarantees[0].provenance.issue' <<<"$LIST_OUT")"
assert_eq "ID 書式違反の見出しは malformed_guarantee_id として broken に出る" \
  "1" "$(jq -r '[.broken[] | select(.reason == "malformed_guarantee_id")] | length' <<<"$LIST_OUT")"

# 不変条件: counts.guarantees = guarantees の要素数 + malformed_guarantee_id の件数
# （counts は ID 書式を満たさない見出しも数えるため、guarantees|length を見出し総数に使えない）
assert_eq "counts.guarantees は guarantees の件数と malformed_guarantee_id の合計と一致する" \
  "$(jq -r '.counts.guarantees' <<<"$LIST_OUT")" \
  "$(jq -r '(.guarantees | length) + ([.broken[] | select(.reason == "malformed_guarantee_id")] | length)' <<<"$LIST_OUT")"

# 節の外の見出しは guarantees に入らない（呼び出し側が「登録済み」と読まないため）
OUTSIDE_LEDGER="${FIXTURE_REPO}/docs/guarantees-outside.md"
cat > "$OUTSIDE_LEDGER" <<'LEDGER'
# 保証台帳

## 保証（Guarantees）

### G-1-1: 節の中

- テスト: `tests/contact.test.ts::returns 400 for invalid json`
- 宣言元: #1

## 補足

### G-2-1: 節の外

- テスト: `tests/contact.test.ts::returns 400 for invalid json`
- 宣言元: #2
LEDGER
OUTSIDE_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/guarantees-outside.md 2>/dev/null)"
assert_eq "節の外の保証は guarantees に入らない" \
  "G-1-1" "$(jq -r '[.guarantees[].guarantee_id] | join(",")' <<<"$OUTSIDE_OUT")"
assert_eq "節の外の保証は guarantee_outside_section として broken に出る" \
  "1" "$(jq -r '[.broken[] | select(.reason == "guarantee_outside_section")] | length' <<<"$OUTSIDE_OUT")"

# フェンス内の記入例は guarantees に入らない（散文が「登録済み」と誤認する経路を塞ぐ）
FENCED_LEDGER="${FIXTURE_REPO}/docs/guarantees-fenced.md"
cat > "$FENCED_LEDGER" <<'LEDGER'
# 保証台帳

書式の記入例:

```markdown
### G-999-1: 記入例（実在しない）

- テスト: `tests/contact.test.ts::returns 400 for invalid json`
- 宣言元: #999
```

## 保証（Guarantees）

### G-1-1: 実在する保証

- テスト: `tests/contact.test.ts::returns 400 for invalid json`
- 宣言元: #1
LEDGER
FENCED_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/guarantees-fenced.md 2>/dev/null)"
assert_eq "フェンス内の記入例は guarantees に入らない" \
  "G-1-1" "$(jq -r '[.guarantees[].guarantee_id] | join(",")' <<<"$FENCED_OUT")"
assert_eq "フェンス内の記入例がある台帳でも status は pass" \
  "pass" "$(jq -r '.status' <<<"$FENCED_OUT")"

echo "=== test: CLI（健全な台帳は exit 0・status pass） ==="
cat > "${FIXTURE_REPO}/docs/guarantees.md" <<'LEDGER'
# 保証台帳

## 保証（Guarantees）

### G-123-1: 約束A

- 種別: API契約
- テスト: `tests/contact.test.ts::returns 400 for invalid json`
- 宣言元: #123

### G-130-1: 約束B

- テスト: `e2e/auth.spec.ts::redirects unauthenticated user to login`
- 宣言元: #130

## Gaps（テストのない公開面）

- [ ] GAP-001: 未整備の公開面
LEDGER
PASS_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/guarantees.md 2>/dev/null)"
PASS_EXIT=$?
assert_eq "exit code が 0" "0" "$PASS_EXIT"
assert_eq "status が pass" "pass" "$(jq -r '.status' <<<"$PASS_OUT")"
assert_eq "broken が空配列" "0" "$(jq -r '.broken | length' <<<"$PASS_OUT")"
assert_eq "counts.guarantees が 2" "2" "$(jq -r '.counts.guarantees' <<<"$PASS_OUT")"
assert_eq "counts.gaps が 1" "1" "$(jq -r '.counts.gaps' <<<"$PASS_OUT")"

echo "=== test: CLI（引数省略時は docs/guarantees.md を見る） ==="
DEFAULT_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" 2>/dev/null)"
DEFAULT_EXIT=$?
assert_eq "exit code が 0" "0" "$DEFAULT_EXIT"
assert_eq "ledger が既定パス" "docs/guarantees.md" "$(jq -r '.ledger' <<<"$DEFAULT_OUT")"

echo "=== test: CLI（壊れた索引は exit 1 かつ stdout に JSON を返す） ==="
cat > "${FIXTURE_REPO}/docs/broken.md" <<'LEDGER'
# 保証台帳

## 保証（Guarantees）

### G-123-1: 参照先が無い

- テスト: `tests/gone.test.ts::nope`
- 宣言元: #123
LEDGER
BROKEN_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/broken.md 2>/dev/null)"
BROKEN_EXIT=$?
assert_eq "exit code が 1" "1" "$BROKEN_EXIT"
assert_eq "status が fail" "fail" "$(jq -r '.status' <<<"$BROKEN_OUT")"
assert_eq "broken の reason" "test_file_not_found" "$(jq -r '.broken[0].reason' <<<"$BROKEN_OUT")"
assert_eq "broken の guarantee_id" "G-123-1" "$(jq -r '.broken[0].guarantee_id' <<<"$BROKEN_OUT")"
assert_eq "broken の ref" "tests/gone.test.ts::nope" "$(jq -r '.broken[0].ref' <<<"$BROKEN_OUT")"

echo "=== test: CLI（参照を伴わない問題の ref は JSON の null になる） ==="
cat > "${FIXTURE_REPO}/docs/no-ref.md" <<'LEDGER'
# 保証台帳

## 保証（Guarantees）

### G-500-1: テスト参照を書き忘れた保証

- 種別: API契約
- 宣言元: #500
LEDGER
NOREF_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/no-ref.md 2>/dev/null)"
NOREF_EXIT=$?
assert_eq "exit code が 1" "1" "$NOREF_EXIT"
assert_eq "reason が missing_test_ref" "missing_test_ref" "$(jq -r '.broken[0].reason' <<<"$NOREF_OUT")"
assert_eq "ref が null（空文字ではない）" "true" "$(jq -r '.broken[0].ref == null' <<<"$NOREF_OUT")"

echo "=== test: CLI（保証節が無い台帳は pass にせず exit 2） ==="
printf '# 保証台帳\n\n## 概要\n\n- 節名を間違えた台帳\n' > "${FIXTURE_REPO}/docs/no-section.md"
NOSEC_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/no-section.md 2>/dev/null)"
NOSEC_EXIT=$?
assert_eq "exit code が 2" "2" "$NOSEC_EXIT"
assert_eq "stdout は空（pass として返さない）" "" "$NOSEC_OUT"

echo "=== test: CLI（実行前提の欠落は exit 2 で stdout は空） ==="
MISSING_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/nonexistent.md 2>/dev/null)"
MISSING_EXIT=$?
assert_eq "台帳が無い場合は exit 2" "2" "$MISSING_EXIT"
assert_eq "stdout は空" "" "$MISSING_OUT"

UNKNOWN_OPT_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" --bogus 2>/dev/null)"
UNKNOWN_OPT_EXIT=$?
assert_eq "未知オプションは exit 2" "2" "$UNKNOWN_OPT_EXIT"
assert_eq "未知オプション時の stdout は空" "" "$UNKNOWN_OPT_OUT"

TOO_MANY_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/guarantees.md extra 2>/dev/null)"
TOO_MANY_EXIT=$?
assert_eq "引数が多すぎる場合は exit 2" "2" "$TOO_MANY_EXIT"
assert_eq "引数過多時の stdout は空" "" "$TOO_MANY_OUT"

BAD_BASE_OUT="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/guarantees.md --base "${TMP_ROOT}/nonexistent" 2>/dev/null)"
BAD_BASE_EXIT=$?
assert_eq "--base のディレクトリが無い場合は exit 2" "2" "$BAD_BASE_EXIT"
assert_eq "その場合の stdout は空" "" "$BAD_BASE_OUT"

echo "=== test: CLI（サブディレクトリからの実行でもリポジトリルート基準で参照を解決する） ==="
mkdir -p "${FIXTURE_REPO}/src/deep"
SUBDIR_OUT="$(cd "${FIXTURE_REPO}/src/deep" && bash "$TARGET_SCRIPT" ../../docs/guarantees.md 2>/dev/null)"
SUBDIR_EXIT=$?
assert_eq "exit code が 0（参照を見失わない）" "0" "$SUBDIR_EXIT"
assert_eq "base がリポジトリルート" "$(cd "$FIXTURE_REPO" && pwd -P)" "$(jq -r '.base' <<<"$SUBDIR_OUT")"

echo "=== test: CLI（--base で参照解決の基準を明示できる） ==="
EXPLICIT_BASE_OUT="$(bash "$TARGET_SCRIPT" "${FIXTURE_REPO}/docs/guarantees.md" --base "$FIXTURE_REPO" 2>/dev/null)"
EXPLICIT_BASE_EXIT=$?
assert_eq "exit code が 0" "0" "$EXPLICIT_BASE_EXIT"
assert_eq "status が pass" "pass" "$(jq -r '.status' <<<"$EXPLICIT_BASE_OUT")"

echo "=== test: 受理方向（正本の書式例がそのまま pass する） ==="

# 生成側の正規形（docs/ai-driven-development-strategy.md 5.3 の書式例）を検証側が受理すること。
# 「拒否すべきものを拒否する」だけでなく「受理すべきものを受理する」を固定する
# （検査を足したときに、正しい台帳まで落とすようになっていないかの受理方向テスト）。
STRATEGY_FILE="${GIC_TEST_DIR}/../../docs/ai-driven-development-strategy.md"
if [ ! -r "$STRATEGY_FILE" ]; then
  echo "  NG - 戦略ドキュメントを読めません（検査不能を pass にはしない）: ${STRATEGY_FILE}" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("戦略ドキュメントを読めない")
else
  # 5.3 の書式例（最初の markdown フェンス）を切り出す
  canonical_example="$(awk '
    /^### 5.3 保証台帳/ { section = 1 }
    section && /^```markdown$/ && !started { started = 1; next }
    started && /^```$/ { exit }
    started { print }
  ' "$STRATEGY_FILE")"
  assert_eq "正本から書式例を切り出せる（切り出し失敗を pass にしない）" \
    "true" "$(if printf '%s' "$canonical_example" | grep -qF '## 保証（Guarantees）'; then echo true; else echo false; fi)"

  CANON_WS="${TMP_ROOT}/canonical"
  mkdir -p "${CANON_WS}/docs" "${CANON_WS}/tests" "${CANON_WS}/e2e"
  printf 'it("returns 400 for invalid json", () => {});\n' > "${CANON_WS}/tests/contact.test.ts"
  printf 'test("redirects unauthenticated user to login", async () => {});\n' > "${CANON_WS}/e2e/auth.spec.ts"
  # 書式例のパスをフィクスチャの実ファイルへ合わせる（検査対象は書式であってパスではない）
  printf '%s\n' "$canonical_example" | sed 's#tests/api/contact.test.ts#tests/contact.test.ts#' > "${CANON_WS}/docs/guarantees.md"

  CANON_OUT="$(cd "$CANON_WS" && bash "$TARGET_SCRIPT" docs/guarantees.md --base "$CANON_WS" 2>/dev/null)"
  CANON_EXIT=$?
  assert_eq "正本の書式例は exit 0（正規形を落とさない）" "0" "$CANON_EXIT"
  assert_eq "正本の書式例は status pass" "pass" "$(jq -r '.status' <<<"$CANON_OUT")"
  assert_eq "正本の書式例から保証を2件読み取る" "2" "$(jq -r '.guarantees | length' <<<"$CANON_OUT")"
  assert_eq "正本の書式例の宣言元を数値で読み取る" "123,130" \
    "$(jq -r '[.guarantees[].provenance.issue | tostring] | join(",")' <<<"$CANON_OUT")"
  assert_eq "正本の書式例の provenance.kind はすべて issue" "issue,issue" \
    "$(jq -r '[.guarantees[].provenance.kind] | join(",")' <<<"$CANON_OUT")"
  assert_eq "正本の書式例から GAP を1件数える" "1" "$(jq -r '.counts.gaps' <<<"$CANON_OUT")"
fi

echo "=== test: 節未検出エラーの節見出しが書式仕様と食い違わない ==="

# Issue #182: 保証節が見つからないエラーは「節が違う」ことしか伝えず、正しい節名を教えなかった。
# 台帳の書式仕様はプラグイン配下にあり headless 委譲では到達できないため、そこが唯一の
# 自己回復不能点になっていた。エラーへ期待する節見出しを載せて解消したが、**節名がスクリプトと
# 書式仕様の2箇所に現れる**ため、片方だけ直っても誰も検出しない状態になりうる（散文の
# 「一致させること」では守られない）。ここで4者の一致を固定する:
#   1. 正本: docs/ai-driven-development-strategy.md 5.3 の書式例
#   2. スクリプト仕様: scripts/specs/guarantee-index-check.md「パースの規約」の書式例
#   3. 参照ファイル: skills/guarantee-audit/references/bootstrap-mode.md のドラフト書式
#   4. 節未検出エラー（stderr）が提示する期待見出し
# 節見出しはテストにも直書きせず**正本から抜き出して**突き合わせる（ここに literal を置くと
# 5つ目のコピーになり、正本を変えてもテストだけが古い値で通り続ける）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md 既出）。抜き出しは grep、比較は文字列一致で行う。

# フェンス内の書式例から、`## 保証` / `## Gaps` で始まる H2 行の**最初の1本**を取り出す。
# 接頭辞一致は保証節の識別規則（正本 5.3）そのものであり、ここでの literal はその接頭辞だけ。
heading_from() {
  local file="$1" prefix="$2" found rc
  found="$(grep -m1 -E "^${prefix}" "$file")"
  rc=$?
  if [ "$rc" -ge 2 ]; then
    printf '%s' "grep-error(${rc})"
    return 0
  fi
  printf '%s' "$found"
}

SPEC_FILE="${GIC_TEST_DIR}/../specs/guarantee-index-check.md"
BOOTSTRAP_REF="${GIC_TEST_DIR}/../../skills/guarantee-audit/references/bootstrap-mode.md"

for f in "$STRATEGY_FILE" "$SPEC_FILE" "$BOOTSTRAP_REF"; do
  assert_eq "書式仕様を読める（読めない状態を pass にしない）: $(basename "$f")" \
    "true" "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

CANON_GUARANTEE_HEADING="$(heading_from "$STRATEGY_FILE" '## 保証')"
CANON_GAPS_HEADING="$(heading_from "$STRATEGY_FILE" '## Gaps')"

# 抜き出し自体が空振りしていないこと（空文字どうしの比較は何も検証しないため）
assert_eq "正本から保証節の見出しを抜き出せる" "true" \
  "$(if [ -n "$CANON_GUARANTEE_HEADING" ]; then echo true; else echo false; fi)"
assert_eq "正本から Gaps 節の見出しを抜き出せる" "true" \
  "$(if [ -n "$CANON_GAPS_HEADING" ]; then echo true; else echo false; fi)"

# (1)=(2), (1)=(3): 書式仕様のコピーどうしが一致していること
assert_eq "スクリプト仕様の保証節見出しが正本と一致" \
  "$CANON_GUARANTEE_HEADING" "$(heading_from "$SPEC_FILE" '## 保証')"
assert_eq "スクリプト仕様の Gaps 節見出しが正本と一致" \
  "$CANON_GAPS_HEADING" "$(heading_from "$SPEC_FILE" '## Gaps')"
assert_eq "参照ファイル（bootstrap-mode）の保証節見出しが正本と一致" \
  "$CANON_GUARANTEE_HEADING" "$(heading_from "$BOOTSTRAP_REF" '## 保証')"
assert_eq "参照ファイル（bootstrap-mode）の Gaps 節見出しが正本と一致" \
  "$CANON_GAPS_HEADING" "$(heading_from "$BOOTSTRAP_REF" '## Gaps')"

# (1)=(4): スクリプトが持つ定数が正本と一致していること（source 済みの変数を直接見る）
assert_eq "スクリプトの GIC_GUARANTEE_HEADING が正本と一致" \
  "$CANON_GUARANTEE_HEADING" "$GIC_GUARANTEE_HEADING"
assert_eq "スクリプトの GIC_GAPS_HEADING が正本と一致" \
  "$CANON_GAPS_HEADING" "$GIC_GAPS_HEADING"

# (4): 実際の stderr に載ること（定数を持っていても出力に載せ忘れれば行き止まりのまま）
NOSEC_ERR="$(cd "$FIXTURE_REPO" && bash "$TARGET_SCRIPT" docs/no-section.md 2>&1 >/dev/null)"
NOSEC_ERR_EXIT=$?
assert_eq "節未検出は exit 2 のまま（実行前提の欠落。意味を変えない）" "2" "$NOSEC_ERR_EXIT"
assert_eq "stderr に期待する保証節の見出しが載る" "true" \
  "$(if printf '%s' "$NOSEC_ERR" | grep -qF -- "$CANON_GUARANTEE_HEADING"; then echo true; else echo false; fi)"
assert_eq "stderr に期待する Gaps 節の見出しが載る" "true" \
  "$(if printf '%s' "$NOSEC_ERR" | grep -qF -- "$CANON_GAPS_HEADING"; then echo true; else echo false; fi)"
assert_eq "stderr のエラー JSON の error 値は変えない（下流の分岐キー）" "true" \
  "$(if printf '%s' "$NOSEC_ERR" | grep -qF -- '"error":"guarantee section not found"'; then echo true; else echo false; fi)"

# 受理方向: 提示した見出しをそのまま使った台帳は節として認識される
# （「エラーが教えた形」と「検証器が受理する形」の食い違いを残さない）。
HINT_WS="${TMP_ROOT}/hint"
mkdir -p "${HINT_WS}/docs" "${HINT_WS}/tests"
printf 'it("x", () => {});\n' > "${HINT_WS}/tests/a.test.ts"
{
  printf '# 保証台帳\n\n'
  printf '%s\n\n' "$CANON_GUARANTEE_HEADING"
  printf '### G-1-1: 約束\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: #1\n\n'
  printf '%s\n\n' "$CANON_GAPS_HEADING"
  printf -- '- [ ] GAP-001: 未整備の公開面\n'
} > "${HINT_WS}/docs/guarantees.md"
HINT_OUT="$(cd "$HINT_WS" && bash "$TARGET_SCRIPT" docs/guarantees.md --base "$HINT_WS" 2>/dev/null)"
HINT_EXIT=$?
assert_eq "エラーが提示した見出しで書いた台帳は exit 0" "0" "$HINT_EXIT"
assert_eq "エラーが提示した Gaps 見出しは Gaps 節として数えられる" "1" \
  "$(jq -r '.counts.gaps' <<<"$HINT_OUT")"



echo "=== test: 値にタブが含まれても列がずれない（出力契約の維持） ==="

# 台帳由来の値は任意の文字を含みうる。タブ区切りの受け渡しでエスケープしていないと、
# 列がずれて jq が別のフィールドを読む・型変換に失敗して stdout が空になる
# （＝正当な台帳が不透明に落ちる）。エスケープ・復元の往復を固定する。
TAB_WS="${TMP_ROOT}/tabws"
mkdir -p "${TAB_WS}/docs" "${TAB_WS}/tests"
printf 'it("case a", () => {});\n' > "${TAB_WS}/tests/a.test.ts"

printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: 約束A\t続き\n\n- テスト: `tests/a.test.ts::case a`\n- 宣言元: #1\n' > "${TAB_WS}/docs/tab-statement.md"
TAB_OUT="$(cd "$TAB_WS" && bash "$TARGET_SCRIPT" docs/tab-statement.md --base "$TAB_WS" 2>/dev/null)"
TAB_EXIT=$?
assert_eq "約束文にタブがあっても exit 0（正当な台帳を落とさない）" "0" "$TAB_EXIT"
assert_eq "約束文にタブがあっても stdout に JSON を出す（空にならない）" \
  "pass" "$(jq -r '.status' <<<"$TAB_OUT")"
assert_eq "約束文のタブは台帳の記載どおり復元される" \
  "$(printf '約束A\t続き')" "$(jq -r '.guarantees[0].statement' <<<"$TAB_OUT")"
assert_eq "タブがあっても宣言元の列がずれない" "1" "$(jq -r '.guarantees[0].provenance.issue' <<<"$TAB_OUT")"

printf 'it("case\ta", () => {});\n' > "${TAB_WS}/tests/b.test.ts"
printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: 約束A\n\n- テスト: `tests/b.test.ts::case\ta`\n- 宣言元: #1\n' > "${TAB_WS}/docs/tab-ref.md"
TABREF_OUT="$(cd "$TAB_WS" && bash "$TARGET_SCRIPT" docs/tab-ref.md --base "$TAB_WS" 2>/dev/null)"
assert_eq "テスト参照にタブがあっても実検査は通る" "pass" "$(jq -r '.status' <<<"$TABREF_OUT")"
assert_eq "tests[] はタブを含む参照を切り詰めずに返す（実検査が使った値と同一）" \
  "$(printf 'tests/b.test.ts::case\ta')" "$(jq -r '.guarantees[0].tests[0]' <<<"$TABREF_OUT")"

printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### 壊れた\t見出し\n\n- テスト: `tests/a.test.ts::case a`\n- 宣言元: #1\n' > "${TAB_WS}/docs/tab-heading.md"
TABHEAD_OUT="$(cd "$TAB_WS" && bash "$TARGET_SCRIPT" docs/tab-heading.md --base "$TAB_WS" 2>/dev/null)"
assert_eq "書式違反の見出しにタブがあっても reason 列がずれない" \
  "malformed_guarantee_id" "$(jq -r '.broken[0].reason' <<<"$TABHEAD_OUT")"
assert_eq "書式違反の見出しはタブを含めて記載どおり返す" \
  "$(printf '壊れた\t見出し')" "$(jq -r '.broken[0].guarantee_id' <<<"$TABHEAD_OUT")"

# バックスラッシュはエスケープの導入で壊れやすい。往復で不変であることを固定する
printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: path C:\\tmp\\x と \\t を含む\n\n- テスト: `tests/a.test.ts::case a`\n- 宣言元: #1\n' > "${TAB_WS}/docs/backslash.md"
BS_OUT="$(cd "$TAB_WS" && bash "$TARGET_SCRIPT" docs/backslash.md --base "$TAB_WS" 2>/dev/null)"
assert_eq "バックスラッシュ・リテラルの \\t を含む約束文が往復で不変" \
  'path C:\tmp\x と \t を含む' "$(jq -r '.guarantees[0].statement' <<<"$BS_OUT")"

echo "=== test: 保証節が2つ以上ある台帳（黙って併合しない） ==="

DUP_WS="${TMP_ROOT}/dupsec"
mkdir -p "${DUP_WS}/docs" "${DUP_WS}/tests"
printf 'it("x", () => {});\n' > "${DUP_WS}/tests/a.test.ts"
printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: A\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: #1\n\n## 保証ポリシー\n\n### G-1-2: B\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: #1\n' > "${DUP_WS}/docs/two-sections.md"
DUP_OUT="$(cd "$DUP_WS" && bash "$TARGET_SCRIPT" docs/two-sections.md --base "$DUP_WS" 2>/dev/null)"
DUP_EXIT=$?
assert_eq "保証節が2つある台帳は exit 1（併合して pass にしない）" "1" "$DUP_EXIT"
assert_eq "duplicate_guarantee_section を報告する" \
  "1" "$(jq -r '[.broken[] | select(.reason == "duplicate_guarantee_section")] | length' <<<"$DUP_OUT")"
assert_eq "2つ目の節の見出しを guarantee_id に入れる" \
  "保証ポリシー" "$(jq -r '[.broken[] | select(.reason == "duplicate_guarantee_section") | .guarantee_id][0]' <<<"$DUP_OUT")"

# 受理方向: 節が1つなら当然 pass（過剰に落とさない）
printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: A\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: #1\n\n## Gaps（テストのない公開面）\n' > "${DUP_WS}/docs/one-section.md"
ONE_OUT="$(cd "$DUP_WS" && bash "$TARGET_SCRIPT" docs/one-section.md --base "$DUP_WS" 2>/dev/null)"
assert_eq "保証節が1つなら pass（過剰に落とさない）" "pass" "$(jq -r '.status' <<<"$ONE_OUT")"
# フェンス内の「## 保証」見出しは節として数えない
printf '# 保証台帳\n\n```markdown\n## 保証（Guarantees）\n```\n\n## 保証（Guarantees）\n\n### G-1-1: A\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: #1\n' > "${DUP_WS}/docs/fenced-section.md"
FENSEC_OUT="$(cd "$DUP_WS" && bash "$TARGET_SCRIPT" docs/fenced-section.md --base "$DUP_WS" 2>/dev/null)"
assert_eq "フェンス内の「## 保証」見出しは2つ目の節として数えない" "pass" "$(jq -r '.status' <<<"$FENSEC_OUT")"

echo "=== test: 正本台帳に残った「裁可待ち」を警告する（status は落とさない） ==="

PEND_WS="${TMP_ROOT}/pending"
mkdir -p "${PEND_WS}/docs" "${PEND_WS}/tests"
printf 'it("x", () => {});\n' > "${PEND_WS}/tests/a.test.ts"
printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: A\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: 裁可待ち\n\n### G-1-2: B\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: #1\n' > "${PEND_WS}/docs/pending.md"
PEND_OUT="$(cd "$PEND_WS" && bash "$TARGET_SCRIPT" docs/pending.md --base "$PEND_WS" 2>"${PEND_WS}/stderr.txt")"
PEND_EXIT=$?
assert_eq "裁可待ちは書式として正当なので exit 0" "0" "$PEND_EXIT"
assert_eq "裁可待ちは broken に積まない" "0" "$(jq -r '.broken | length' <<<"$PEND_OUT")"
assert_eq "裁可待ちは stderr で警告する（黙って通さない）" "1" \
  "$(grep -c '裁可待ち」のままの保証' "${PEND_WS}/stderr.txt")"
assert_eq "警告に該当 ID を含める" "1" "$(grep -c 'G-1-1' "${PEND_WS}/stderr.txt")"
assert_eq "裁可待ちでない保証は警告に出さない" "0" "$(grep -c 'G-1-2' "${PEND_WS}/stderr.txt")"

# 列位置を見ない部分一致だと、**約束文が pending の保証**にも誤って一致する
# （`*<TAB>pending<TAB>*` は約束文の列にも当たる）。宣言元 kind の列で厳密比較する。
printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: pending\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: #1\n' > "${PEND_WS}/docs/statement-pending.md"
STMT_OUT="$(cd "$PEND_WS" && bash "$TARGET_SCRIPT" docs/statement-pending.md --base "$PEND_WS" 2>"${PEND_WS}/stderr3.txt")"
assert_eq "約束文が pending でも provenance.kind は issue" \
  "issue" "$(jq -r '.guarantees[0].provenance.kind' <<<"$STMT_OUT")"
assert_eq "約束文が pending でも「裁可待ち」警告を出さない（列位置を見ない一致で誤検知しない）" \
  "0" "$(grep -c '裁可待ち」のままの保証' "${PEND_WS}/stderr3.txt")"

# テスト参照に pending を含む場合も同様（別の列への誤一致）
printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: 約束\n\n- テスト: `tests/a.test.ts::pending`\n- 宣言元: #1\n' > "${PEND_WS}/docs/ref-pending.md"
printf 'it("pending", () => {});\n' > "${PEND_WS}/tests/a.test.ts"
(cd "$PEND_WS" && bash "$TARGET_SCRIPT" docs/ref-pending.md --base "$PEND_WS" >/dev/null 2>"${PEND_WS}/stderr4.txt")
assert_eq "テスト参照に pending を含んでも「裁可待ち」警告を出さない" \
  "0" "$(grep -c '裁可待ち」のままの保証' "${PEND_WS}/stderr4.txt")"
printf 'it("x", () => {});\n' > "${PEND_WS}/tests/a.test.ts"

# 裁可待ちが1件も無ければ警告を出さない（常時警告で意味を失わせない）
printf '# 保証台帳\n\n## 保証（Guarantees）\n\n### G-1-1: A\n\n- テスト: `tests/a.test.ts::x`\n- 宣言元: #1\n' > "${PEND_WS}/docs/no-pending.md"
(cd "$PEND_WS" && bash "$TARGET_SCRIPT" docs/no-pending.md --base "$PEND_WS" >/dev/null 2>"${PEND_WS}/stderr2.txt")
assert_eq "裁可待ちが無ければ警告を出さない" "0" "$(grep -c '裁可待ち」のままの保証' "${PEND_WS}/stderr2.txt")"


echo ""
echo "=== base リビジョンの台帳の読み取り（/para-impl の登録済み判定が依存する契約） ==="

# 台帳のパスは引数で受けるため、`git show <ref>:docs/guarantees.md` を一時ファイルへ書き出せば
# 作業ツリー以外のリビジョンの台帳も同じ規則で読める（スクリプト側の変更なしで成立する）。
# ここではその契約と、既存呼び出し元（台帳パス1引数のみ）の後方互換を固定する。
REV_REPO="${TMP_ROOT}/revrepo"
mkdir -p "${REV_REPO}/docs" "${REV_REPO}/tests"
printf 'alpha\n' > "${REV_REPO}/tests/a.test.ts"
printf 'beta\n' > "${REV_REPO}/tests/b.test.ts"
cat > "${REV_REPO}/docs/guarantees.md" <<'REVEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha promise

- 種別: API契約
- テスト: `tests/a.test.ts::alpha`
- 宣言元: #1

### G-2-1: beta promise

- 種別: API契約
- テスト: `tests/b.test.ts::beta`
- 宣言元: #2

## Gaps（テストのない公開面）

- [ ] GAP-001: nothing
REVEOF
(
  cd "$REV_REPO" || exit 1
  git init -q .
  git add -A
  git -c user.email=t@example.com -c user.name=t commit -qm init
) >/dev/null 2>&1
# macOS の /var は /private/var へのシンボリックリンクであり、スクリプトは `cd ... && pwd` で
# 解決した実パスを返す。比較側も実パスに揃える（別物どうしを不一致と誤判定しないため）。
REV_REPO_REAL="$(cd "$REV_REPO" && pwd -P)"
mkdir -p "${REV_REPO}/sub"

# 後方互換: 台帳パス1引数だけの呼び出し（quality-check / guarantee-audit / promote-verify の形）は
# 従来どおり台帳のあるリポジトリのルートを base に解決する。
COMPAT_OUT="$(cd "$REV_REPO" && bash "$TARGET_SCRIPT" docs/guarantees.md 2>/dev/null)"
COMPAT_CODE=$?
assert_eq "後方互換: 台帳パスのみの呼び出しは exit 0（pass）" "0" "$COMPAT_CODE"
assert_eq "後方互換: base は台帳のあるリポジトリのルートへ自動解決される" "$REV_REPO_REAL" \
  "$(printf '%s' "$COMPAT_OUT" | jq -r '.base')"
# サブディレクトリから呼んでも、台帳のパスが repo 内なら base はリポジトリルートのままになる
COMPAT_SUB_OUT="$(cd "${REV_REPO}/sub" && bash "$TARGET_SCRIPT" "${REV_REPO}/docs/guarantees.md" 2>/dev/null)"
assert_eq "後方互換: サブディレクトリから呼んでも base はリポジトリルート" "$REV_REPO_REAL" \
  "$(printf '%s' "$COMPAT_SUB_OUT" | jq -r '.base')"
assert_eq "後方互換: guarantees が2件返る" "2" \
  "$(printf '%s' "$COMPAT_OUT" | jq -r '.guarantees | length')"

# 作業ツリー側の台帳だけを書き換える（コミットしない）
perl -pi -e 's/beta promise/beta promise v2/' "${REV_REPO}/docs/guarantees.md"

REV_LEDGER="${TMP_ROOT}/base-ledger.md"
(cd "$REV_REPO" && git show "HEAD:docs/guarantees.md") > "$REV_LEDGER" 2>/dev/null
assert_eq "git show で base リビジョンの台帳を取り出せる" "0" "$?"

# /para-impl の登録済み判定は **--base を指定しない**（消費する guarantees は参照検査より前に
# 確定するため --base に影響されず、指定は exit 2 の停止経路を増やすだけ）。まずその経路を検査する。
REV_NOBASE_OUT="$(cd "${REV_REPO}/sub" && bash "$TARGET_SCRIPT" "$REV_LEDGER" 2>/dev/null)"
REV_NOBASE_CODE=$?
assert_eq "--base 無しでも base リビジョンの台帳を検査できる（exit 0/1 のいずれか）" "true" \
  "$(if [ "$REV_NOBASE_CODE" -le 1 ]; then echo true; else echo false; fi)"
assert_eq "--base 無しでも guarantees[].guarantee_id が取れる" "G-1-1 G-2-1" \
  "$(printf '%s' "$REV_NOBASE_OUT" | jq -r '[.guarantees[].guarantee_id] | join(" ")')"

# **サブディレクトリから実行する**: cwd をリポジトリルートにすると、--base が無視されても
# gic_resolve_base のフォールバック（cwd）が同じ値を返してしまい、--base が効いていることを
# 検査できない（--base の削除で落ちないテストになる）。
REV_OUT="$(cd "${REV_REPO}/sub" && bash "$TARGET_SCRIPT" "$REV_LEDGER" --base "$REV_REPO" 2>/dev/null)"
REV_CODE=$?
assert_eq "リポジトリ外の一時ファイルを台帳として検査できる（exit 0）" "0" "$REV_CODE"
assert_eq "一時ファイル経路でも guarantees[].guarantee_id が取れる" "G-1-1 G-2-1" \
  "$(printf '%s' "$REV_OUT" | jq -r '[.guarantees[].guarantee_id] | join(" ")')"
assert_eq "読み取れるのは base リビジョンの約束文（作業ツリーの変更が混ざらない）" "beta promise" \
  "$(printf '%s' "$REV_OUT" | jq -r '.guarantees[] | select(.guarantee_id == "G-2-1") | .statement')"
# --base を明示した場合は渡した値をそのまま正規化する（git 由来の実パス化は行わない）。
# cwd はサブディレクトリなので、この値になるのは --base が効いている場合だけである。
assert_eq "--base の明示が cwd フォールバックより優先される（サブディレクトリから実行）" "$REV_REPO" \
  "$(printf '%s' "$REV_OUT" | jq -r '.base')"
assert_eq "--base が効いているのでテスト参照が解決でき status は pass" "pass" \
  "$(printf '%s' "$REV_OUT" | jq -r '.status')"

# 作業ツリー側は別の内容を返す（2つのリビジョンが混ざっていないことの対称な確認）
WT_OUT="$(cd "$REV_REPO" && bash "$TARGET_SCRIPT" docs/guarantees.md 2>/dev/null)"
assert_eq "作業ツリー側は改訂後の約束文を返す" "beta promise v2" \
  "$(printf '%s' "$WT_OUT" | jq -r '.guarantees[] | select(.guarantee_id == "G-2-1") | .statement')"

# --base 未指定で repo 外の一時ファイルを渡すと、台帳の位置からリポジトリルートを解決できず
# 基準が **cwd** へ倒れる。base の値は変わるが **guarantees は変わらない** — これが
# 「/para-impl は --base を指定しない」という規約の根拠である。
assert_eq "--base 未指定・repo 外の台帳は基準が cwd へ倒れる（base の値は変わる）" "${REV_REPO}/sub" \
  "$(printf '%s' "$REV_NOBASE_OUT" | jq -r '.base')"
assert_eq "guarantees は --base の指定有無で同一（--base を必須にしない根拠）" "true" \
  "$(if [ "$(printf '%s' "$REV_NOBASE_OUT" | jq -c '[.guarantees[].guarantee_id]')" \
        = "$(printf '%s' "$REV_OUT" | jq -c '[.guarantees[].guarantee_id]')" ]; then echo true; else echo false; fi)"
assert_eq "guarantees[].statement も --base の指定有無で同一" "true" \
  "$(if [ "$(printf '%s' "$REV_NOBASE_OUT" | jq -c '[.guarantees[].statement]')" \
        = "$(printf '%s' "$REV_OUT" | jq -c '[.guarantees[].statement]')" ]; then echo true; else echo false; fi)"

# 一方で --base の解決失敗は exit 2 で stdout ごと失われる（消費結果に効かない指定が
# 停止経路だけを増やす、という判断の根拠）。
BADBASE_REV_OUT="$(cd "${REV_REPO}/sub" && bash "$TARGET_SCRIPT" "$REV_LEDGER" --base "${REV_REPO}/does-not-exist" 2>/dev/null)"
BADBASE_REV_CODE=$?
assert_eq "--base のディレクトリ不在は exit 2（guarantees ごと失われる）" "2" "$BADBASE_REV_CODE"
assert_eq "その場合 stdout は空（登録済み判定の入力が消える）" "" "$BADBASE_REV_OUT"

# status が fail（exit 1）でも guarantees は stdout に出る。登録済み判定は exit 1 でも成立する。
FAILSTATE_LEDGER="${TMP_ROOT}/failstate-ledger.md"
cat > "$FAILSTATE_LEDGER" <<'FSEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha promise

- 種別: API契約
- テスト: `tests/does-not-exist.test.ts::alpha`
- 宣言元: #1
FSEOF
FAILSTATE_OUT="$(bash "$TARGET_SCRIPT" "$FAILSTATE_LEDGER" --base "$REV_REPO" 2>/dev/null)"
FAILSTATE_CODE=$?
assert_eq "参照が壊れていれば exit 1（status=fail）" "1" "$FAILSTATE_CODE"
assert_eq "exit 1（status=fail）でも guarantees は stdout に出る" "G-1-1" \
  "$(printf '%s' "$FAILSTATE_OUT" | jq -r '[.guarantees[].guarantee_id] | join(" ")')"

echo ""
echo "=== guarantees と counts の関係（下流の完全性判定が依存する不変条件） ==="

# (1) counts.refs と guarantees[].tests の総数は**常に一致する**（実装上、ID 書式違反の見出し
#     配下のテスト参照はどちらにも数えられない）。この突き合わせは空虚に真であり、
#     参照集合の完全性の根拠にならない——drift モード D3 がこれを根拠にしない理由。
# (2) 完全性の根拠になるのは counts.guarantees と guarantees の件数の差分だけである。
MALFORMED_LEDGER="${TMP_ROOT}/malformed-ledger.md"
cat > "$MALFORMED_LEDGER" <<'MFEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha promise

- 種別: API契約
- テスト: `tests/a.test.ts::alpha`
- 宣言元: #1

### G-2-x: malformed id

- 種別: API契約
- テスト: `tests/b.test.ts::beta`
- 宣言元: #2
MFEOF
MF_OUT="$(bash "$TARGET_SCRIPT" "$MALFORMED_LEDGER" --base "$REV_REPO" 2>/dev/null)"
assert_eq "ID 書式違反の見出しも counts.guarantees には数える" "2" \
  "$(printf '%s' "$MF_OUT" | jq -r '.counts.guarantees')"
assert_eq "ID 書式違反の見出しは guarantees には入らない" "1" \
  "$(printf '%s' "$MF_OUT" | jq -r '.guarantees | length')"
assert_eq "差分（counts.guarantees - guarantees の件数）が取りこぼし件数になる" "1" \
  "$(printf '%s' "$MF_OUT" | jq -r '.counts.guarantees - (.guarantees | length)')"
assert_eq "書式違反の見出し配下のテスト参照は参照集合に現れない（D4 が誤検出する根拠）" "0" \
  "$(printf '%s' "$MF_OUT" | jq -r '[.guarantees[].tests[] | select(. == "tests/b.test.ts::beta")] | length')"
assert_eq "counts.refs も書式違反の見出し配下の参照を数えない（突き合わせが空虚に真になる）" "true" \
  "$(printf '%s' "$MF_OUT" | jq -r '(.counts.refs == ([.guarantees[].tests | length] | add))')"
assert_eq "正常な台帳でも counts.refs == guarantees[].tests の総数（常に一致する）" "true" \
  "$(printf '%s' "$COMPAT_OUT" | jq -r '(.counts.refs == ([.guarantees[].tests | length] | add))')"

echo ""
echo "=== 消費側4箇所が依存する不変条件（broken の区分と件数差分の関係） ==="

# 仕様の正本は scripts/specs/guarantee-index-check.md「`reason` の分類」。
# **件数差分（counts.guarantees - len(guarantees)）に現れない不完全さがある**ことを
# 実挙動で固定する。ここが崩れると: drift D3 が正常な台帳を not_analyzed にする／
# create-ticket が維持候補を落として差分を「ID 書式違反」と誤報する／
# feature-implementer が「退役・改番」で停止する／para-impl が重複割当を起こす。
INV_WS="${TMP_ROOT}/invariants"
mkdir -p "${INV_WS}/tests"
printf 'test_alpha\ntest_outside\n' > "${INV_WS}/tests/a.py"

# 差分と broken の関係を1行で取り出す
inv_probe() {
  bash "$TARGET_SCRIPT" "$1" --base "$INV_WS" 2>/dev/null \
    | jq -r --arg r "$2" '[(.counts.guarantees - (.guarantees|length)),
                           ([.broken[] | select(.reason == $r)] | length),
                           (.guarantees|length),
                           ([.guarantees[].tests[]] | length)] | @tsv'
}

# (1) **テスト参照を持たない保証も guarantees に含まれ、件数差分は 0 のまま**。
#     4つの移譲先すべてがこの不変条件に依存する（区分 (II) の missing_test_ref）。
cat > "${INV_WS}/noref.md" <<'INVEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha

- テスト: `tests/a.py::test_alpha`
- 宣言元: #1

### G-2-1: beta（テストが未整備）

- 種別: API契約
- 宣言元: #2
INVEOF
assert_eq "テスト参照0件の保証も guarantees に含まれる（落とさない）" "2" \
  "$(bash "$TARGET_SCRIPT" "${INV_WS}/noref.md" --base "$INV_WS" 2>/dev/null | jq -r '.guarantees | length')"
assert_eq "テスト参照0件の保証の tests は空配列（null でも欠落でもない）" "0" \
  "$(bash "$TARGET_SCRIPT" "${INV_WS}/noref.md" --base "$INV_WS" 2>/dev/null | jq -r '.guarantees[] | select(.guarantee_id == "G-2-1") | .tests | length')"
assert_eq "テスト参照0件の保証があっても件数差分は 0 のまま（不完全ではない）" "0	1	2	1" \
  "$(inv_probe "${INV_WS}/noref.md" missing_test_ref)"

# (2) 区分 (I) のうち **件数差分に現れる**のは malformed_guarantee_id だけである
cat > "${INV_WS}/malformed.md" <<'INVEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha

- テスト: `tests/a.py::test_alpha`
- 宣言元: #1

### G-2-x: 枝番が数値でない

- テスト: `tests/a.py::test_outside`
- 宣言元: #2
INVEOF
assert_eq "malformed_guarantee_id は件数差分に現れる（差分1 / reason1）" "1	1	1	1" \
  "$(inv_probe "${INV_WS}/malformed.md" malformed_guarantee_id)"
assert_eq "件数差分は malformed_guarantee_id の件数と一致する（相互検査の不変条件）" "true" \
  "$(bash "$TARGET_SCRIPT" "${INV_WS}/malformed.md" --base "$INV_WS" 2>/dev/null \
     | jq -r '(.counts.guarantees - (.guarantees|length)) == ([.broken[] | select(.reason == "malformed_guarantee_id")] | length)')"

# (3) 区分 (I) の残り4つは **件数差分 0** のまま参照集合を壊す（差分だけでは検出できない）
cat > "${INV_WS}/outside.md" <<'INVEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha

- テスト: `tests/a.py::test_alpha`
- 宣言元: #1

## 廃止候補

### G-200-1: 節の外に置かれた保証

- テスト: `tests/a.py::test_outside`
- 宣言元: #200
INVEOF
assert_eq "guarantee_outside_section は件数差分 0（差分では検出できない）" "0	1	1	1" \
  "$(inv_probe "${INV_WS}/outside.md" guarantee_outside_section)"
assert_eq "節の外の保証のテスト参照は参照集合に現れない（D4 が誤検出する根拠）" "0" \
  "$(bash "$TARGET_SCRIPT" "${INV_WS}/outside.md" --base "$INV_WS" 2>/dev/null \
     | jq -r '[.guarantees[].tests[] | select(. == "tests/a.py::test_outside")] | length')"

cat > "${INV_WS}/dupsection.md" <<'INVEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha

- テスト: `tests/a.py::test_alpha`
- 宣言元: #1

## 保証（旧・移行前）

### G-2-1: 退役予定の節のエントリ

- テスト: `tests/a.py::test_outside`
- 宣言元: #2
INVEOF
assert_eq "duplicate_guarantee_section は件数差分 0（差分では検出できない）" "0	1	2	2" \
  "$(inv_probe "${INV_WS}/dupsection.md" duplicate_guarantee_section)"
assert_eq "2つの節は黙って併合され、両節のエントリが guarantees に並ぶ" "G-1-1 G-2-1" \
  "$(bash "$TARGET_SCRIPT" "${INV_WS}/dupsection.md" --base "$INV_WS" 2>/dev/null \
     | jq -r '[.guarantees[].guarantee_id] | join(" ")')"

cat > "${INV_WS}/dupid.md" <<'INVEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha

- テスト: `tests/a.py::test_alpha`
- 宣言元: #1

### G-1-1: 同じ ID の2件目

- テスト: `tests/a.py::test_outside`
- 宣言元: #1
INVEOF
assert_eq "duplicate_guarantee_id は件数差分 0（差分では検出できない）" "0	1	2	2" \
  "$(inv_probe "${INV_WS}/dupid.md" duplicate_guarantee_id)"
assert_eq "同一 ID が2件並ぶ（ID をキーにした join が一意にならない）" "2" \
  "$(bash "$TARGET_SCRIPT" "${INV_WS}/dupid.md" --base "$INV_WS" 2>/dev/null \
     | jq -r '[.guarantees[] | select(.guarantee_id == "G-1-1")] | length')"

cat > "${INV_WS}/malref.md" <<'INVEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha

- テスト: `tests/a.py`
- 宣言元: #1
INVEOF
assert_eq "malformed_test_ref は件数差分 0（差分では検出できない）" "0	1	1	1" \
  "$(inv_probe "${INV_WS}/malref.md" malformed_test_ref)"
assert_eq "書式違反の参照は tests にそのまま入る（<パス>::<テスト名> として突き合わせられない）" "tests/a.py" \
  "$(bash "$TARGET_SCRIPT" "${INV_WS}/malref.md" --base "$INV_WS" 2>/dev/null | jq -r '.guarantees[0].tests[0]')"

# (4) 区分 (II) の参照整合系は guarantees の完全性を損なわない
cat > "${INV_WS}/notfound.md" <<'INVEOF'
# 保証台帳

## 保証（Guarantees）

### G-1-1: alpha

- テスト: `tests/does-not-exist.py::test_alpha`
- 宣言元: #1
INVEOF
assert_eq "test_file_not_found は件数差分 0・参照は tests に正しく入る" "0	1	1	1" \
  "$(inv_probe "${INV_WS}/notfound.md" test_file_not_found)"

echo ""
echo "=== ledger の同一性（消費側が「別の台帳を読んでいない」ことを確認する契約） ==="

# 件数の突き合わせを撤去した後、渡したパスと読まれた台帳の同一性を確認する唯一の手段。
assert_eq "ledger は渡した引数をそのまま返す（絶対パス）" "${INV_WS}/noref.md" \
  "$(bash "$TARGET_SCRIPT" "${INV_WS}/noref.md" --base "$INV_WS" 2>/dev/null | jq -r '.ledger')"
mkdir -p "${INV_WS}/pkg/docs"
cp "${INV_WS}/noref.md" "${INV_WS}/pkg/docs/guarantees.md"
assert_eq "引数を省略すると ledger は相対パスの既定値になる（引数省略を検出できる）" "docs/guarantees.md" \
  "$(cd "${INV_WS}/pkg" && bash "$TARGET_SCRIPT" 2>/dev/null | jq -r '.ledger')"
assert_eq "相対パスで渡すと ledger も相対パスのまま（正規化しない）" "docs/guarantees.md" \
  "$(cd "${INV_WS}/pkg" && bash "$TARGET_SCRIPT" docs/guarantees.md 2>/dev/null | jq -r '.ledger')"

echo ""
echo "=== 仕様の reason 分類が語彙と実挙動に整合している（消費側2箇所がこの分類に依存する） ==="

# `/create-ticket` の ledger_uninterpretable と `/guarantee-audit drift` の D4 実行可否は、
# どちらも仕様書の「`reason` の分類」を正本にしている。分類を1行いじると両方の判定が
# 静かに変わるため、**分類表を語彙表と実挙動の両方に突き合わせて**固定する。
SPEC_FILE="${GIC_TEST_DIR}/../specs/guarantee-index-check.md"
assert_eq "仕様書を読める" "true" "$(if [ -r "$SPEC_FILE" ]; then echo true; else echo false; fi)"

# ledger の同一性は、件数の突き合わせを撤去した後に消費側3箇所が使う唯一の確認手段。
# 仕様側の記述と実挙動の両方を固定する（片方だけだと規約と実装がずれても落ちない）。
assert_eq "仕様が ledger は引数をそのまま返すと定めている" "1" \
  "$(grep -cF -- '**渡した引数をそのまま返す**' "$SPEC_FILE")"
assert_eq "仕様が ledger で別の台帳を読んでいないことを確認できると定めている" "1" \
  "$(grep -cF -- '**`ledger` が自分の渡したパスと一致することを確認できる**' "$SPEC_FILE")"

# 語彙表（`broken[].reason` の語彙）の reason 一覧
spec_vocab_reasons="$(awk '
  /^`broken\[\]\.reason` の語彙:/ { intable = 1; next }
  intable && /^\|/ { print; next }
  intable && /^$/ { next }
  intable && !/^\|/ { exit }
' "$SPEC_FILE" | grep -oE '^\| `[a-z_]+`' | tr -d '|` ' | sort -u)"

# 分類表の reason 一覧（区分列を伴う行）
spec_class_rows="$(awk '
  /^#### `reason` の分類/ { intable = 1; next }
  intable && /^\|/ { print; next }
  intable && /^####/ { exit }
' "$SPEC_FILE" | grep -E '^\|.*\| ?\(?I?I?\)?')"

# 「reason<TAB>区分」を取り出す（1つのセルに `a` / `b` と2つ並ぶ行は展開する）
spec_class_pairs="$(printf '%s\n' "$spec_class_rows" | awk -F'|' '
  {
    cls = $2; gsub(/[^IIIIII]/, "", cls)
    n = split($3, cells, "/")
    for (i = 1; i <= n; i++) {
      if (match(cells[i], /`[a-z_]+`/)) {
        r = substr(cells[i], RSTART + 1, RLENGTH - 2)
        print r "\t" cls
      }
    }
  }' | sort -u)"

spec_class_reasons="$(printf '%s\n' "$spec_class_pairs" | cut -f1 | sort -u | grep -c .)"
assert_eq "分類表が語彙表の reason をすべて覆っている（未分類の reason を残さない）" \
  "$(printf '%s\n' "$spec_vocab_reasons" | grep -c .)" "$spec_class_reasons"
assert_eq "分類表に語彙表に無い reason が混ざっていない" "" \
  "$(comm -13 <(printf '%s\n' "$spec_vocab_reasons") <(printf '%s\n' "$spec_class_pairs" | cut -f1 | sort -u) | tr '\n' ' ' | sed 's/ *$//')"

# 区分の割り当てを reason ごとに固定する（1件でも動かすと落ちる）
spec_class_of() {
  printf '%s\n' "$spec_class_pairs" | awk -F'\t' -v r="$1" '$1 == r { print $2; exit }'
}
for r in malformed_guarantee_id guarantee_outside_section duplicate_guarantee_section duplicate_guarantee_id malformed_test_ref; do
  assert_eq "区分 (I): ${r}（guarantees の完全性・一意性を壊す）" "I" "$(spec_class_of "$r")"
done
for r in test_file_not_found test_name_not_found missing_test_ref missing_provenance malformed_provenance duplicate_provenance duplicate_gap_id malformed_gap_id; do
  assert_eq "区分 (II): ${r}（guarantees の完全性を損なわない）" "II" "$(spec_class_of "$r")"
done

# 分類が実挙動と一致していること: 区分 (I) の5つのうち、件数差分に現れるのは
# malformed_guarantee_id だけである（上の不変条件節で実測済みの値と突き合わせる）
assert_eq "実挙動: 区分 (I) で件数差分に現れるのは malformed_guarantee_id だけ" "1 0 0 0 0" \
  "$(for f in malformed outside dupsection dupid malref; do
       bash "$TARGET_SCRIPT" "${INV_WS}/${f}.md" --base "$INV_WS" 2>/dev/null \
         | jq -r '(.counts.guarantees - (.guarantees|length)) | if . > 0 then 1 else 0 end'
     done | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "実挙動: 区分 (II) の missing_test_ref / test_file_not_found は差分 0" "0 0" \
  "$(for f in noref notfound; do
       bash "$TARGET_SCRIPT" "${INV_WS}/${f}.md" --base "$INV_WS" 2>/dev/null \
         | jq -r '(.counts.guarantees - (.guarantees|length)) | if . > 0 then 1 else 0 end'
     done | tr '\n' ' ' | sed 's/ *$//')"

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
