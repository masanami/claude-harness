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
