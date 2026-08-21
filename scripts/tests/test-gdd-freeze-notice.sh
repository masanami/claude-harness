#!/bin/bash
# test-gdd-freeze-notice.sh
# GDD レジームの凍結（`docs/ai-driven-development-strategy.md` 5 章冒頭・ADR 0002）の構造不変条件テスト。
#
# 凍結は「削除しないが現役の規約でもない」という**読み手への表示**が本体であり、散文には型検査も
# テストも効かない。そこで規約そのものではなく**凍結が読み手へ届くための構造**を固定する:
#   (F-1) 正本（5 章）の見出しと冒頭バナーが凍結・不採用と ADR 0002 を明示している
#   (F-2) 各実行時ファイルへ配る凍結注記の定型文を正本から切り出せる（切り出し失敗を pass にしない）
#   (F-3)(F-4) 「凍結対象の実行時ファイル」表と、実際に注記を持つファイルの**双方向一致**。
#         表に在るのに注記が無い（貼り忘れ）／注記が在るのに表に無い（誤コピー）の両方を検出する
#   (F-5) 5.1〜5.7 の**各節**が節レベルの凍結注記を持つ。読み手は grep で節だけを読むため、
#         章冒頭のバナーだけでは「同じものを2つの規則で読む」状態が残る
#   (F-6) **凍結≠削除**。GDD 固有のスキル・スクリプト・テストが実在し続けていること
#         （凍結を口実に機構を消すと、GDD期を宣言済みのプロジェクトが壊れる）
#   (F-7) 既定フロー（4.4）が 5 章より前に在り、「保守する」と「正しさは担保しない」を**両方**
#         書いている。片方だけになると「非権威＝破棄してよい」と読める
#   (F-8) フェーズ判定（detect-dev-phase）には注記を置かないという例外が正本に明記されている
#
# 逐語照合は正本から抜き出した文字列で行い、**テストに定型文の literal を置かない**
# （置くと正本を変えてもテストだけが古い値で通り続ける）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。比較は bash の文字列比較と grep -F で行う。
#
# 実行方法: bash scripts/tests/test-gdd-freeze-notice.sh

set -u

GF_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${GF_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

STRATEGY_FILE="${REPO_ROOT}/docs/ai-driven-development-strategy.md"
ADR_FILE="${REPO_ROOT}/docs/adr/0002-gdd-not-adopted-salvage-instruments.md"

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

# 複数行ブロックが、ファイル内に**連続した行**として何回現れるかを数える。
count_block() {
  local file="$1" block="$2"
  local -a blines=() flines=()
  local l
  while IFS= read -r l; do blines+=("$l"); done <<<"$block"
  while IFS= read -r l; do flines+=("$l"); done < "$file"
  local n=${#blines[@]} total=${#flines[@]} i j ok found=0
  if [ "$n" -eq 0 ] || [ "$total" -lt "$n" ]; then
    printf '0'
    return 0
  fi
  for ((i = 0; i + n <= total; i++)); do
    ok=1
    for ((j = 0; j < n; j++)); do
      if [ "${flines[i + j]}" != "${blines[j]}" ]; then ok=0; break; fi
    done
    [ "$ok" -eq 1 ] && found=$((found + 1))
  done
  printf '%s' "$found"
}

echo "=== (F-0) 検出器の自己検査（検出器が壊れていたら以降の照合は無意味） ==="

GF_TMP="$(mktemp -d)"
trap 'rm -rf "$GF_TMP"' EXIT
printf 'alpha\nbeta\ngamma\nbeta\ngamma\n' > "${GF_TMP}/fixture.txt"
assert_eq "(F-0) 連続する2行ブロックを2回検出する" "2" \
  "$(count_block "${GF_TMP}/fixture.txt" "$(printf 'beta\ngamma')")"
assert_eq "(F-0) 行は在るが連続していないブロックは検出しない" "0" \
  "$(count_block "${GF_TMP}/fixture.txt" "$(printf 'alpha\ngamma')")"
assert_eq "(F-0) 1行違うだけのブロックは検出しない（バイト厳密）" "0" \
  "$(count_block "${GF_TMP}/fixture.txt" "$(printf 'beta\ngammaX')")"

echo ""
echo "=== (F-1) 正本（5 章）が凍結・不採用を明示している ==="

for f in "$STRATEGY_FILE" "$ADR_FILE"; do
  assert_eq "(F-1) 検査対象を読める（読めない状態を pass にしない）: $(basename "$f")" \
    "true" "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

assert_file_contains "(F-1) 5 章の見出し自体に凍結が出ている（節だけを読む読み手に届く）" "$STRATEGY_FILE" \
  '## 5.【凍結】開発フェーズとドキュメントライフサイクル（GDD レジーム・不採用）'
assert_file_contains "(F-1) 冒頭バナーが「既定フローの規約ではない」と言い切っている" "$STRATEGY_FILE" \
  '**GDD（Guarantee-Driven Development）レジーム——保証台帳を正とする開発フロー——の記述であり、既定フローの規約ではない**'
assert_file_contains "(F-1) 食い違いの優先順位（4.4 が優先）が明示されている" "$STRATEGY_FILE" \
  '**既定の開発フローは 4.4 が正本**であり、本章の記述と食い違う場合は 4.4 が優先する'
assert_file_contains "(F-1) 決定の出所が ADR 0002 として示されている" "$STRATEGY_FILE" \
  '0002-gdd-not-adopted-salvage-instruments.md'
assert_file_contains "(F-1) 凍結＝削除ではないと明示されている" "$STRATEGY_FILE" \
  '**削除しない・動作も変えない**'
assert_file_contains "(F-1) ADR 側の決定が「凍結」である（正本が引いている決定が実在する）" "$ADR_FILE" \
  '**凍結**する'

echo ""
echo "=== (F-2) 凍結注記の定型文を正本から切り出せる ==="

# 「凍結注記の定型文」節の中の ```text フェンスだけを取り出す。
CANON_NOTICE="$(awk '
  /^#### 凍結注記の定型文/ { insec = 1 }
  insec && /^### 5\.1 / { exit }
  insec && /^```text$/ && !started { started = 1; next }
  started && /^```$/ { exit }
  started { print }
' "$STRATEGY_FILE")"

assert_eq "(F-2) 定型文を切り出せる（切り出し失敗を pass にしない）" "true" \
  "$(if [ -n "$CANON_NOTICE" ]; then echo true; else echo false; fi)"

NOTICE_MARKER='<!-- 凍結注記の正本: docs/ai-driven-development-strategy.md 5 章冒頭 ／ 決定と根拠: docs/adr/0002-gdd-not-adopted-salvage-instruments.md -->'
assert_eq "(F-2) 切り出した定型文が正本コメントで終わる" "true" \
  "$(if [ "${CANON_NOTICE##*$'\n'}" = "$NOTICE_MARKER" ]; then echo true; else echo false; fi)"
assert_eq "(F-2) 定型文は正本のフェンス内に1回だけ現れる" "1" \
  "$(count_block "$STRATEGY_FILE" "$CANON_NOTICE")"
assert_eq "(F-2) 定型文が2行以上ある（1行に潰れた形を pass にしない）" "true" \
  "$(if [ "$(printf '%s\n' "$CANON_NOTICE" | grep -c '[^[:space:]]')" -ge 2 ]; then echo true; else echo false; fi)"

echo ""
echo "=== (F-3) 「凍結対象の実行時ファイル」表の各ファイルが実在し、注記を逐語で持つ ==="

# 表の行からバッククォート囲みのパスを取り出す（テスト側に一覧を literal で持たない）。
FROZEN_TARGETS="$(awk '
  /^\*\*凍結対象の実行時ファイル\*\*/ { insec = 1; next }
  insec && /^#### / { exit }
  insec && /^\| / { print }
' "$STRATEGY_FILE" | grep -o '`[^`]*`' | tr -d '`' | grep -E '\.(md|sh)$' | sort -u)"

FROZEN_COUNT="$(printf '%s\n' "$FROZEN_TARGETS" | grep -c '[^[:space:]]')"
assert_eq "(F-3) 表からファイルを5件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$FROZEN_COUNT" -ge 5 ]; then echo true; else echo false; fi)"

while IFS= read -r target; do
  [ -z "$target" ] && continue
  if [ ! -r "${REPO_ROOT}/${target}" ]; then
    assert_eq "(F-3) 表に挙げたファイルが実在する: ${target}" "true" "false"
    continue
  fi
  assert_eq "(F-3) 凍結注記が逐語で1回だけ存在する: ${target}" "1" \
    "$(count_block "${REPO_ROOT}/${target}" "$CANON_NOTICE")"
done <<<"$FROZEN_TARGETS"

echo ""
echo "=== (F-4) 表と実際の注記の双方向一致（貼り忘れ・誤コピーの両方を見る） ==="

# 正本（戦略ドキュメント）自身は配送元なので除外する。`scripts/tests/` 配下も除外する
# （テストはマーカーを**検出キー**として持つのであって、凍結対象の実行時ファイルではない）。
ACTUAL_FROZEN="$(grep -rlF -- "$NOTICE_MARKER" docs skills agents scripts)"
ACTUAL_RC=$?
assert_eq "(F-4) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$ACTUAL_RC" -le 1 ]; then echo true; else echo false; fi)"
ACTUAL_FROZEN="$(printf '%s\n' "$ACTUAL_FROZEN" | grep '[^[:space:]]' \
  | grep -vFx 'docs/ai-driven-development-strategy.md' \
  | grep -v '^scripts/tests/' | sort -u)"

assert_eq "(F-4) 凍結注記を持つファイルの集合が表と一致する" \
  "$FROZEN_TARGETS" "$ACTUAL_FROZEN"

echo ""
echo "=== (F-5) 5.1〜5.7 の各節が節レベルの凍結注記を持つ ==="

# 節見出しの直後（空行を挟んだ次の非空行）が凍結注記であること。章冒頭のバナーだけでは
# 節単位で grep する読み手に届かない。
SECTION_HEADINGS="$(grep -c '^### 5\.[1-7] ' "$STRATEGY_FILE")"
assert_eq "(F-5) 5.1〜5.7 の節見出しが7個ある" "7" "$SECTION_HEADINGS"

SECTION_NOTE_PREFIX='> **凍結（→ 5 章冒頭）**:'
missing_section_note=""
while IFS= read -r heading_line; do
  [ -z "$heading_line" ] && continue
  head_no="$(printf '%s' "$heading_line" | cut -d: -f1)"
  next_nonblank="$(awk -v s="$head_no" 'NR > s && $0 ~ /[^[:space:]]/ { print; exit }' "$STRATEGY_FILE")"
  case "$next_nonblank" in
    "$SECTION_NOTE_PREFIX"*) ;;
    *) missing_section_note="${missing_section_note}$(printf '%s' "$heading_line" | cut -d: -f2-) " ;;
  esac
done <<<"$(grep -n '^### 5\.[1-7] ' "$STRATEGY_FILE")"
assert_eq "(F-5) すべての節の見出し直後に凍結注記が在る" "" "$missing_section_note"

assert_file_contains "(F-5) 節レベルの注記を置く理由が正本に書かれている" "$STRATEGY_FILE" \
  'grep で節だけを読む読み手に届かせるため'

echo ""
echo "=== (F-6) 凍結≠削除（GDD 固有の機構が実在し続けている） ==="

# ADR 0002 は「削除はせず experimental を明示し、追加投資しない」と決めている。
# 凍結を口実に機構を消すと、GDD期を宣言済みのプロジェクトが壊れる。
for kept in \
  'skills/guarantee-audit/SKILL.md' \
  'skills/guarantee-audit/references/bootstrap-mode.md' \
  'skills/guarantee-audit/references/drift-mode.md' \
  'agents/guarantee-auditor.md' \
  'scripts/guarantee-index-check.sh' \
  'scripts/detect-dev-phase.sh' \
  'scripts/tests/test-guarantee-granularity.sh' \
  'scripts/tests/test-guarantee-index-check.sh' \
  'scripts/tests/test-detect-dev-phase.sh'; do
  assert_eq "(F-6) 削除されていない: ${kept}" "true" \
    "$(if [ -r "${REPO_ROOT}/${kept}" ]; then echo true; else echo false; fi)"
done

echo ""
echo "=== (F-7) 既定フロー（4.4）が 5 章より前に在り、保守と非権威を両方書いている ==="

SEC44_LINE="$(awk '/^### 4\.4 /  { print NR; exit }' "$STRATEGY_FILE")"
SEC5_LINE="$(awk '/^## 5\./     { print NR; exit }' "$STRATEGY_FILE")"
assert_eq "(F-7) 4.4 の見出しを見つけられる" "true" \
  "$(if [ -n "$SEC44_LINE" ]; then echo true; else echo false; fi)"
assert_eq "(F-7) 4.4 は凍結章（5 章）より前に在る" "true" \
  "$(if [ -n "$SEC44_LINE" ] && [ -n "$SEC5_LINE" ] && [ "$SEC44_LINE" -lt "$SEC5_LINE" ]; then echo true; else echo false; fi)"

# 「非権威」を「破棄してよい」と読ませないための対の記述。片方が消えたら落とす。
assert_file_contains "(F-7) 機能仕様を保守すると書いている" "$STRATEGY_FILE" \
  '**保守する（破棄しない）**: 機能仕様は機能の追加・変更のたびに更新する。'
assert_file_contains "(F-7) 短命な作業文書として扱わないと明記している" "$STRATEGY_FILE" \
  '**リリース後に破棄する短命な作業文書としては扱わない**'
assert_file_contains "(F-7) 正しさを担保しない（非権威）と書いている" "$STRATEGY_FILE" \
  '**正しさは担保しない（非権威）**'
assert_file_contains "(F-7) 乖離それ自体を欠陥として扱わないと書いている" "$STRATEGY_FILE" \
  '**機能仕様とコードの乖離それ自体を欠陥として扱わない**'
assert_file_contains "(F-7) 非権威を「更新しなくてよい」と読まないよう釘を刺している" "$STRATEGY_FILE" \
  '**非権威であることは、機能仕様の更新を省いてよい理由にはならない。**'
assert_file_contains "(F-7) ドリフト検出の担い手（定期のテスト監査）が書かれている" "$STRATEGY_FILE" \
  '#### ドリフトの検出は定期のテスト監査が担う'
assert_file_contains "(F-7) 診断ツールへの再位置づけが未実施であると明示している" "$STRATEGY_FILE" \
  '**再位置づけ自体は未実施**'

# 実行時ファイル側（軽量化ガイド）が「破棄前提」に戻っていないこと
DF_SKILL="${REPO_ROOT}/skills/define-feature/SKILL.md"
assert_eq "(F-7) define-feature の参照ファイルを読める" "true" \
  "$(if [ -r "$DF_SKILL" ]; then echo true; else echo false; fi)"
assert_eq "(F-7) 軽量化ガイドが「リリースまでの作業文書」に戻っていない" "false" \
  "$(if grep -qF -- '機能仕様ドキュメントは**リリースまでの作業文書**であり' "$DF_SKILL"; then echo true; else echo false; fi)"
assert_file_contains "(F-7) 軽量化ガイドが保守する文書だと書いている" "$DF_SKILL" \
  '機能仕様ドキュメントは**機能の追加・変更のたびに保守する文書**である'

echo ""
echo "=== (F-8) フェーズ判定を凍結注記の対象外とする例外が明記されている ==="

assert_file_contains "(F-8) 例外の記述が在る" "$STRATEGY_FILE" \
  '**フェーズ判定（`detect-dev-phase`）には凍結注記を置かない**'
assert_file_contains "(F-8) フェーズ分岐を持つ共通スキルも凍結対象外だと明記している" "$STRATEGY_FILE" \
  '上表の凍結対象は **GDD 専用のファイル**に限る'
# 5.2 のフェーズ判定の共通文言は SDD期でも通る現役の規約である。節ごと凍結と読まれると、
# 各実行時ファイルへ配った定型文（invalid を sdd に読み替えない規律）まで無効に見える。
assert_file_contains "(F-8) 5.2 のフェーズ判定の共通文言は凍結対象外だと明記している" "$STRATEGY_FILE" \
  '**ただし本節の「フェーズ判定の共通文言」（`detect-dev-phase` の呼び出しと、`invalid`・実行不能を `sdd` に読み替えない規律）は凍結の対象外であり、現役の規約である**'
assert_eq "(F-8) 例外どおり detect-dev-phase の仕様に注記が無い" "0" \
  "$(count_block "${REPO_ROOT}/scripts/specs/detect-dev-phase.md" "$CANON_NOTICE")"

# 新規の GDD期 宣言を提案しない、という凍結の帰結が初期設定スキルに反映されている
INIT_SKILL="${REPO_ROOT}/skills/init-project/SKILL.md"
assert_file_contains "(F-8) 正本が「新規の GDD期 宣言は提案しない」と決めている" "$STRATEGY_FILE" \
  '`/init-project` は保証台帳を検出しても GDD期 を候補として提示しない'
assert_file_contains "(F-8) init-project が GDD期 を候補として提示しない" "$INIT_SKILL" \
  '**`GDD期` を候補として提示しない**'
assert_eq "(F-8) init-project に旧規定（同意を得て GDD期 を確定する）が残っていない" "false" \
  "$(if grep -qF -- '**`GDD期` を候補として提示し、ユーザーの明示的な同意を得る**' "$INIT_SKILL"; then echo true; else echo false; fi)"

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
