#!/bin/bash
# test-spec-slices.sh
# 「スライス（出荷の単位）」規約の構造不変条件テスト。
#
# /define-feature が仕様を出荷の単位（スライス）に切り、既定を最小スライス S1 にし、
# /create-ticket 要件モードが実装対象スライスだけを起票する、という規約は散文（SKILL.md・
# テンプレート・エージェント定義・references）にしか無く型検査が効かない。本テストは規約の
# 遵守ではなく、**規約が成立するための構造**を固定する:
#   (S-1) テンプレートに2つの必須節（スライス／やらないこと）が在り、受入基準の前に置かれ、
#         スライス表の列名と `実装対象:` 行が固定の形で在る（呼び出し側が読み写せる契約）
#   (S-2) define-feature 手順 2 の**節内**に「最小の縦切り」を問う規定と「既定は S1 のみ」が在る。
#         手順 6 の節内に必須節の削除禁止が在る。手順 6.5 は観点の所在として spec-critic を指す
#   (S-3) spec-critic の `internal-consistency` レンズの**節内**に、受入基準が実装対象スライスの
#         範囲に収まっているかの観点と、必須節の欠落を needs_user_input とする観点が在る
#   (S-4) create-ticket 要件モードの Step 1 の節内に「実装対象スライスのみ起票」「後続の起票
#         トリガーは前スライスの PR マージ後」「起票主体は人間または呼び出し側フロー」「スライス表
#         の無い仕様は従来どおり1チケット」が在る。Step 2 の節内に Issue 本文の範囲宣言が在る
#   (S-5) 否定検査: /pr-merge と実装分解モードにはスライス起票の規定が**無い**（起票主体は
#         人間または呼び出し側フローと決定済み。粒度基準はスライスと別軸のまま変更しない）
#   (S-6) スライスと粒度の関係を書いた references が在り、粒度基準の正本（ticket-decomposer の
#         マーカー）を参照している。参照先のマーカーが実在する
#   (S-7) spec-lint の template_placeholders 検査が、新節に残ったプレースホルダを拾う
#
# 節の切り出しに失敗した状態を pass にしない（切り出し結果が空なら NG）。全文 grep は否定検査
# のみに使う（肯定検査を全文 grep にすると、節から削っても別の節の一致で通る）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。比較は bash の文字列比較と grep -F で行う。
#
# 実行方法: bash scripts/tests/test-spec-slices.sh

set -u

SS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SS_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

TEMPLATE_FILE="skills/define-feature/templates/feature-spec.md"
DEFINE_SKILL_FILE="skills/define-feature/SKILL.md"
CRITIC_FILE="agents/spec-critic.md"
REQ_MODE_FILE="skills/create-ticket/references/requirement-mode.md"
DECOMPOSE_MODE_FILE="skills/create-ticket/references/decompose-mode.md"
RELATION_FILE="skills/create-ticket/references/slice-vs-granularity.md"
DECOMPOSER_FILE="agents/ticket-decomposer.md"
PR_MERGE_DIR="skills/pr-merge"
SPEC_LINT_SCRIPT="scripts/spec-lint.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

assert_eq() {
  local description="$1" expected="$2" actual="$3"
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

# 文字列 $2 の中に phrase $3 が含まれるか（切り出した節に対する肯定検査に使う）
assert_text_contains() {
  local description="$1" text="$2" phrase="$3"
  if printf '%s\n' "$text" | grep -qF -- "$phrase"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       phrase: ${phrase}"
  fi
}

# 見出し行（grep -F で完全一致する固定文字列）から、次の見出し（正規表現。ASCII のみ）の
# 直前までを切り出す。見出しが無ければ空を返す（呼び出し側で空を NG にする）。
extract_section() {
  local file="$1" heading="$2" next_heading_re="$3"
  local start rel_end
  start="$(grep -nF -- "$heading" "$file" | head -1 | cut -d: -f1)"
  [ -z "$start" ] && return 0
  rel_end="$(tail -n +"$((start + 1))" "$file" | grep -nE -- "$next_heading_re" | head -1 | cut -d: -f1)"
  if [ -n "$rel_end" ]; then
    sed -n "${start},$((start + rel_end - 1))p" "$file"
  else
    tail -n +"$start" "$file"
  fi
}

line_of() {
  local file="$1" heading="$2"
  grep -nF -- "$heading" "$file" | head -1 | cut -d: -f1
}

nonempty() {
  if [ -n "$1" ]; then echo true; else echo false; fi
}

echo "=== (S-0) extract_section の自己検査（切り出しが壊れていたら以降は無意味） ==="

SS_TMP="$(mktemp -d)"
trap 'rm -rf "$SS_TMP"' EXIT
printf '## A\nalpha\n### A-1\nbeta\n## B\ngamma\n' > "${SS_TMP}/fixture.md"
assert_eq "(S-0) 見出しから次の H2 手前までを切り出す（H3 は含む）" "$(printf '## A\nalpha\n### A-1\nbeta')" \
  "$(extract_section "${SS_TMP}/fixture.md" '## A' '^## ')"
assert_eq "(S-0) 末尾の節は EOF まで切り出す" "$(printf '## B\ngamma')" \
  "$(extract_section "${SS_TMP}/fixture.md" '## B' '^## ')"
assert_eq "(S-0) 無い見出しは空を返す" "" "$(extract_section "${SS_TMP}/fixture.md" '## Z' '^## ')"

for f in "$TEMPLATE_FILE" "$DEFINE_SKILL_FILE" "$CRITIC_FILE" "$REQ_MODE_FILE" "$DECOMPOSE_MODE_FILE" "$RELATION_FILE" "$DECOMPOSER_FILE" "$SPEC_LINT_SCRIPT"; do
  assert_eq "(S-0) 検査対象を読める: ${f}" "true" "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

echo ""
echo "=== (S-1) テンプレート: 必須節2つが受入基準の前に在り、表の列名と実装対象行が固定 ==="

SLICE_HEADING='## スライス（出荷の単位）'
EXCLUDE_HEADING='## やらないこと'
AC_HEADING='## 受入基準'
SLICE_LINE="$(line_of "$TEMPLATE_FILE" "$SLICE_HEADING")"
EXCLUDE_LINE="$(line_of "$TEMPLATE_FILE" "$EXCLUDE_HEADING")"
AC_LINE="$(line_of "$TEMPLATE_FILE" "$AC_HEADING")"
assert_eq "(S-1) スライス節の見出しが在る" "true" "$(nonempty "$SLICE_LINE")"
assert_eq "(S-1) やらないこと節の見出しが在る" "true" "$(nonempty "$EXCLUDE_LINE")"
assert_eq "(S-1) 受入基準節の見出しが在る" "true" "$(nonempty "$AC_LINE")"
assert_eq "(S-1) 節の順序: スライス → やらないこと → 受入基準" "true" \
  "$(if [ -n "$SLICE_LINE" ] && [ -n "$EXCLUDE_LINE" ] && [ -n "$AC_LINE" ] \
      && [ "$SLICE_LINE" -lt "$EXCLUDE_LINE" ] && [ "$EXCLUDE_LINE" -lt "$AC_LINE" ]; then echo true; else echo false; fi)"

SLICE_SECTION="$(extract_section "$TEMPLATE_FILE" "$SLICE_HEADING" '^## ')"
assert_eq "(S-1) スライス節を切り出せる" "true" "$(nonempty "$SLICE_SECTION")"
assert_text_contains "(S-1) スライス表の列名が固定（呼び出し側が読み写す契約）" "$SLICE_SECTION" \
  '| スライス | 内容 | 触るファイル数（概算） | 出荷条件 |'
assert_text_contains "(S-1) S1（最小）の行が在る" "$SLICE_SECTION" '| S1（最小） |'
assert_text_contains "(S-1) S2 の出荷条件は前スライスのマージ後" "$SLICE_SECTION" 'S1 がマージされてから'
assert_eq "(S-1) 実装対象行が S1 を既定とする形で在る" "1" \
  "$(printf '%s\n' "$SLICE_SECTION" | grep -cE '^実装対象: S1$')"
assert_text_contains "(S-1) スライス節は必須節（削除しない）" "$SLICE_SECTION" '必須節。削除しない'
assert_text_contains "(S-1) 触るファイル数の書式が固定（単一値か範囲）" "$SLICE_SECTION" '半角数字の単一値か `下限-上限` の範囲'

EXCLUDE_SECTION="$(extract_section "$TEMPLATE_FILE" "$EXCLUDE_HEADING" '^## ')"
assert_eq "(S-1) やらないこと節を切り出せる" "true" "$(nonempty "$EXCLUDE_SECTION")"
assert_text_contains "(S-1) やらないこと節は必須節（削除しない）" "$EXCLUDE_SECTION" '必須節。削除しない'
assert_text_contains "(S-1) 範囲外を明示列挙する（書いていないことを範囲外とみなさない）" "$EXCLUDE_SECTION" \
  '書いていないことを範囲外とみなさない'
assert_eq "(S-1) やらないこと節に列挙のプレースホルダが1件以上在る" "true" \
  "$(if [ "$(printf '%s\n' "$EXCLUDE_SECTION" | grep -cE '^- \{')" -ge 1 ]; then echo true; else echo false; fi)"

AC_SECTION="$(extract_section "$TEMPLATE_FILE" "$AC_HEADING" '^## ')"
assert_text_contains "(S-1) 受入基準は実装対象スライスの範囲に収める" "$AC_SECTION" '実装対象'

echo ""
echo "=== (S-2) define-feature: 手順 2 の節内に S1 の問い、手順 6 に必須節の規定、6.5 に観点の所在 ==="

STEP2="$(extract_section "$DEFINE_SKILL_FILE" '### 2. 要件ヒアリング' '^### ')"
assert_eq "(S-2) 手順 2 の節を切り出せる" "true" "$(nonempty "$STEP2")"
assert_text_contains "(S-2) 手順 2 に最小の縦切り（S1）を確定する小節が在る" "$STEP2" '#### 2-1. 最小の縦切り（S1）の確定'
assert_text_contains "(S-2) 問いは人間でもエージェントでも同じ形で出す" "$STEP2" '同じ問いを同じ形で出す'
assert_text_contains "(S-2) 最小の縦切りを問う文が在る" "$STEP2" '最小の縦切り（S1）**は何ですか'
assert_text_contains "(S-2) 既定の実装対象は S1 のみ" "$STEP2" '**既定の実装対象は S1 のみ**'
assert_text_contains "(S-2) 後続スライスの起票は前スライスのマージ後" "$STEP2" '前スライスの PR がマージされた後'
assert_text_contains "(S-2) やらないことは明示列挙（1件以上）" "$STEP2" '「やらないこと」は範囲外を**明示列挙**する（1件以上）'

STEP6="$(extract_section "$DEFINE_SKILL_FILE" '### 6. 機能仕様ドキュメント作成' '^### ')"
assert_eq "(S-2) 手順 6 の節を切り出せる" "true" "$(nonempty "$STEP6")"
assert_text_contains "(S-2) 手順 6 の記述ルールに必須節の削除禁止が在る" "$STEP6" \
  '**例外として `## スライス（出荷の単位）` と `## やらないこと` は必須節であり削除しない**'
assert_text_contains "(S-2) 手順 6 で実装対象行を要求する" "$STEP6" '`実装対象: S1` の行を必ず持ち'

STEP65="$(extract_section "$DEFINE_SKILL_FILE" '### 6.5 仕様クリティーク' '^### ')"
assert_eq "(S-2) 手順 6.5 の節を切り出せる" "true" "$(nonempty "$STEP65")"
assert_text_contains "(S-2) 6.5 はスコープの観点の所在として spec-critic を指す（定義は複製しない）" "$STEP65" \
  '受入基準が実装対象スライスの範囲に収まっているか'
assert_eq "(S-2) 6.5 はスコープ観点の定義本文（severity の割当）を複製していない" "0" \
  "$(printf '%s\n' "$STEP65" | grep -cF -- '「やらないこと」の列挙が0件')"

echo ""
echo "=== (S-3) spec-critic: internal-consistency レンズの節内にスコープの観点が在る ==="

IC_SECTION="$(extract_section "$CRITIC_FILE" '### `internal-consistency`' '^### |^## ')"
assert_eq "(S-3) internal-consistency の節を切り出せる" "true" "$(nonempty "$IC_SECTION")"
assert_text_contains "(S-3) 受入基準が実装対象スライスの内容に収まっているかを照合する" "$IC_SECTION" \
  '「## 受入基準」の各項目が `実装対象:` 行のスライス（既定 S1）の「内容」に収まっているか'
assert_text_contains "(S-3) 後続スライス・範囲外を検証する受入基準は blocker 候補" "$IC_SECTION" \
  '「やらないこと」に挙げた範囲外を検証する受入基準は blocker 候補'
assert_text_contains "(S-3) 必須節の欠落・空の列挙は needs_user_input" "$IC_SECTION" \
  '「やらないこと」の列挙が0件・「特になし」のみ**なら `needs_user_input`'
assert_text_contains "(S-3) 節削除への配慮に必須節の例外が在る" "$IC_SECTION" '**例外は次項の2つの必須節**'

echo ""
echo "=== (S-4) create-ticket 要件モード: 1スライス = 1チケット・起票トリガー・起票主体・後方互換 ==="

REQ_STEP1="$(extract_section "$REQ_MODE_FILE" '### Step 1: 機能仕様ドキュメントの読み込み' '^### ')"
assert_eq "(S-4) Step 1 の節を切り出せる" "true" "$(nonempty "$REQ_STEP1")"
assert_text_contains "(S-4) Step 1 が必須節（スライス）を前提に含める" "$REQ_STEP1" '**スライス（出荷の単位）**'
assert_text_contains "(S-4) Step 1 が必須節（やらないこと）を前提に含める" "$REQ_STEP1" '**やらないこと**'
assert_text_contains '(S-4) 実装対象は `実装対象:` 行のスライス（既定 S1）' "$REQ_STEP1" '`実装対象:` 行のスライス ID（既定 `S1`）'
assert_text_contains "(S-4) 起票は実装対象スライスの1件のみ" "$REQ_STEP1" '**起票するのは実装対象スライスの要件チケット1件のみ**'
assert_text_contains "(S-4) 後続スライスは起票しない" "$REQ_STEP1" '後続スライス（S2 以降）のチケットは起票しない'
assert_text_contains "(S-4) 後続の起票トリガーは前スライスの PR マージ後" "$REQ_STEP1" \
  '**後続スライスの起票トリガーは「前スライスの PR がマージされた後」**'
assert_text_contains "(S-4) 起票主体は人間の手動または呼び出し側フロー" "$REQ_STEP1" '**人間の手動、または呼び出し側フロー**'
assert_text_contains "(S-4) pr-merge は自動起票しない" "$REQ_STEP1" '`/pr-merge` も自動では起票しない'
assert_text_contains "(S-4) スライス表の無い仕様は従来どおり1チケット（後方互換）" "$REQ_STEP1" \
  '**従来どおり仕様全体を1チケット**として起票する'

REQ_STEP2="$(extract_section "$REQ_MODE_FILE" '### Step 2: Issue 本文の構成' '^### ')"
assert_eq "(S-4) Step 2 の節を切り出せる" "true" "$(nonempty "$REQ_STEP2")"
assert_text_contains "(S-4) Issue 本文の冒頭にスライスの範囲宣言を置く" "$REQ_STEP2" '> スライス: {実装対象スライス ID}'
assert_text_contains "(S-4) 本文は削らずそのまま貼る（実装分解モードの入力契約を変えない）" "$REQ_STEP2" \
  '本文は後続スライスの行を含めてそのまま貼り付け、削らない'

echo ""
echo "=== (S-5) 否定検査: pr-merge と実装分解モードにスライス起票の規定が無い ==="

PR_MERGE_HITS="$(grep -rlF -- 'スライス' "$PR_MERGE_DIR" 2>/dev/null | grep -c '[^[:space:]]')"
assert_eq "(S-5) /pr-merge 配下にスライスの規定が無い（起票主体は人間または呼び出し側フロー）" "0" "$PR_MERGE_HITS"
assert_eq "(S-5) 実装分解モードは出荷単位のスライスを扱わない（vertical-slice レンズ名のみ）" "0" \
  "$(grep -cF -- 'スライス（出荷の単位）' "$DECOMPOSE_MODE_FILE")"
assert_eq "(S-5) 実装分解モードに起票トリガーの規定が無い" "0" \
  "$(grep -cF -- '前スライスの PR がマージされた後' "$DECOMPOSE_MODE_FILE")"
assert_eq "(S-5) ticket-decomposer の粒度基準は出荷単位のスライスを扱わない" "0" \
  "$(grep -cF -- 'スライス（出荷の単位）' "$DECOMPOSER_FILE")"

echo ""
echo "=== (S-6) スライスと粒度の関係を書いた references が在り、粒度基準の正本を指す ==="

assert_eq "(S-6) 関係を書いた references が在る" "true" "$(if [ -r "$RELATION_FILE" ]; then echo true; else echo false; fi)"
RELATION_TEXT="$(cat "$RELATION_FILE" 2>/dev/null)"
assert_text_contains "(S-6) 粒度基準の正本（ticket-decomposer）を参照している" "$RELATION_TEXT" '`agents/ticket-decomposer.md`'
assert_text_contains "(S-6) 粒度基準のマーカーを参照している" "$RELATION_TEXT" '<!-- granularity-criteria:start -->'
assert_text_contains "(S-6) 1 スライス = 1 要件チケットの対応を書いている" "$RELATION_TEXT" '**1 スライス = 1 要件チケット（親 Issue）**'
assert_text_contains "(S-6) 起票主体（人間または呼び出し側フロー）を書いている" "$RELATION_TEXT" '**人間の手動、または呼び出し側フロー**'
assert_eq "(S-6) 参照先のマーカー（start）が ticket-decomposer に実在する" "1" \
  "$(grep -cF -- '<!-- granularity-criteria:start -->' "$DECOMPOSER_FILE")"
assert_eq "(S-6) 参照先のマーカー（end）が ticket-decomposer に実在する" "1" \
  "$(grep -cF -- '<!-- granularity-criteria:end -->' "$DECOMPOSER_FILE")"
assert_eq "(S-6) 要件モードが関係文書へのポインタを持つ" "1" \
  "$(grep -cF -- 'skills/create-ticket/references/slice-vs-granularity.md' "$REQ_MODE_FILE")"

echo ""
echo "=== (S-7) spec-lint の template_placeholders 検査が新節のプレースホルダを拾う ==="

# shellcheck source=/dev/null
source "$SPEC_LINT_SCRIPT"
PLACEHOLDERS_JSON="[]"
detect_template_placeholders "$(printf '%s\n%s\n' "$SLICE_SECTION" "$EXCLUDE_SECTION")"
PH_COUNT="$(jq 'length' <<<"$PLACEHOLDERS_JSON" 2>/dev/null || echo 0)"
assert_eq "(S-7) 新節のプレースホルダを1件以上検出する" "true" \
  "$(if [ "$PH_COUNT" -ge 1 ]; then echo true; else echo false; fi)"
assert_eq "(S-7) やらないこと節の列挙プレースホルダを検出する" "true" \
  "$(if jq -e 'map(.text) | index("{範囲外1}")' <<<"$PLACEHOLDERS_JSON" >/dev/null 2>&1; then echo true; else echo false; fi)"

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
