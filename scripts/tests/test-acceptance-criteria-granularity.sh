#!/bin/bash
# test-acceptance-criteria-granularity.sh
# 受入基準の粒度規約（`docs/ai-driven-development-strategy.md` 4.5「受入基準の粒度」）の
# 構造不変条件テスト。
#
# 本規約は保証台帳（5.3・凍結）で得た知見を、台帳用語から独立した形で既定フロー（SDD）の
# 受入基準へ移植したものである（ADR 0002「計装は回収する」）。散文の規約には型検査もテストも
# 効かないため、規約そのものではなく**規約が成立するための構造**を固定する:
#   (A-1) 正本に粒度節が 4.5 として在る（4.4 と 5 章の間）
#   (A-2) 配送用の定型文を正本から切り出せる（切り出し失敗を pass にしない）
#   (A-3) 定型文の不変コア（1主張の定義／停止条件 S1・S2／まとめる理由にならないもの／
#         網羅の対象／機械の保証水準／前向き適用）が揃っている。意味を反転しても部分一致は
#         通るため、可変部を含まない**一文まるごと**で照合する
#   (A-4) **台帳用語から独立している**。移植の要件そのものであり、GDD の語彙（保証台帳・
#         保証 ID・裁可・索引チェック）が定型文に混ざっていないことを機械で固定する
#   (A-5)(A-6) 「適用先」表と、実際にコピーを持つファイルの**双方向一致**。表に在るのに
#         コピーが無い（横展開の取りこぼし）／コピーが在るのに表に無い（例外への誤コピー）
#   (A-7) 「適用しない範囲」に挙げたファイルが定型文を**持たない**。規則の横展開は例外の
#         見落としで別種の欠陥を作る（PR #176 の回帰と同型）ため、例外側も機械で固定する
#   (A-8) 規約が強制を委ねている先（`spec-critic` の複合文判定）が実在する。正本は「強制は
#         spec-critic が担う」と書いているだけなので、判定側が消えると規約が宙に浮く
#
# 逐語照合は正本から抜き出した文字列で行い、**テストに定型文の literal を置かない**
# （置くと正本を変えてもテストだけが古い値で通り続ける。3つ目のコピーになる）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。比較は bash の文字列比較と grep -F で行う。
#
# 実行方法: bash scripts/tests/test-acceptance-criteria-granularity.sh

set -u

AG_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${AG_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

STRATEGY_FILE="${REPO_ROOT}/docs/ai-driven-development-strategy.md"
CRITIC_FILE="${REPO_ROOT}/agents/spec-critic.md"

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

echo "=== (A-0) count_block の自己検査（検出器が壊れていたら以降の照合は無意味） ==="

AG_TMP="$(mktemp -d)"
trap 'rm -rf "$AG_TMP"' EXIT
printf 'alpha\nbeta\ngamma\nbeta\ngamma\n' > "${AG_TMP}/fixture.txt"
assert_eq "(A-0) 連続する2行ブロックを2回検出する" "2" \
  "$(count_block "${AG_TMP}/fixture.txt" "$(printf 'beta\ngamma')")"
assert_eq "(A-0) 行は在るが連続していないブロックは検出しない" "0" \
  "$(count_block "${AG_TMP}/fixture.txt" "$(printf 'alpha\ngamma')")"
assert_eq "(A-0) 1行違うだけのブロックは検出しない（バイト厳密）" "0" \
  "$(count_block "${AG_TMP}/fixture.txt" "$(printf 'beta\ngammaX')")"

echo ""
echo "=== (A-1) 正本に粒度節が 4.5 として在る（4.4 と 5 章の間） ==="

for f in "$STRATEGY_FILE" "$CRITIC_FILE"; do
  assert_eq "(A-1) 検査対象を読める（読めない状態を pass にしない）: $(basename "$f")" \
    "true" "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

assert_file_contains "(A-1) 粒度節の見出しが在る" "$STRATEGY_FILE" \
  '### 4.5 受入基準の粒度（1基準 = 1主張 = 1検証）'

GRAN_LINE="$(awk '/^### 4\.5 / { print NR; exit }' "$STRATEGY_FILE")"
SEC44_LINE="$(awk '/^### 4\.4 / { print NR; exit }' "$STRATEGY_FILE")"
SEC5_LINE="$(awk '/^## 5\./    { print NR; exit }' "$STRATEGY_FILE")"
assert_eq "(A-1) 粒度節は 4.4 と 5 章（凍結章）の間に在る" "true" \
  "$(if [ -n "$GRAN_LINE" ] && [ -n "$SEC44_LINE" ] && [ -n "$SEC5_LINE" ] \
      && [ "$GRAN_LINE" -gt "$SEC44_LINE" ] && [ "$GRAN_LINE" -lt "$SEC5_LINE" ]; then echo true; else echo false; fi)"

assert_file_contains "(A-1) 出所（凍結した台帳の運用）と、台帳に依存しないことを明示している" "$STRATEGY_FILE" \
  '**出所は凍結した保証台帳（→ 5.3）の運用だが、規律そのものは台帳に依存しない**'
assert_file_contains "(A-1) 保証側の粒度規約と正本を二重に持たないと明示している" "$STRATEGY_FILE" \
  '**GDD期の保証節に適用する版は 5.3 が正本であり、二重に持たない**'

echo ""
echo "=== (A-2) 配送用の定型文を正本から切り出せる ==="

# 4.5 の中の ```text フェンス（＝各実行時ファイルへコピーする定型文）だけを取り出す。
CANON_BOILERPLATE="$(awk '
  /^### 4\.5 / { insec = 1 }
  insec && /^## 5\./ { exit }
  insec && /^```text$/ && !started { started = 1; next }
  started && /^```$/ { exit }
  started { print }
' "$STRATEGY_FILE")"

assert_eq "(A-2) 定型文を切り出せる（切り出し失敗を pass にしない）" "true" \
  "$(if [ -n "$CANON_BOILERPLATE" ]; then echo true; else echo false; fi)"

CANON_MARKER='<!-- 正本: docs/ai-driven-development-strategy.md 4.5「受入基準の粒度」 -->'
assert_eq "(A-2) 切り出した定型文が正本コメントで終わる" "true" \
  "$(if [ "${CANON_BOILERPLATE##*$'\n'}" = "$CANON_MARKER" ]; then echo true; else echo false; fi)"
assert_eq "(A-2) 定型文は正本のフェンス内に1回だけ現れる" "1" \
  "$(count_block "$STRATEGY_FILE" "$CANON_BOILERPLATE")"

echo ""
echo "=== (A-3) 定型文の不変コア（可変部を含まない一文まるごとで照合） ==="

ag_core() {
  local description="$1" phrase="$2"
  if printf '%s\n' "$CANON_BOILERPLATE" | grep -qF -- "$phrase"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       phrase: ${phrase}"
  fi
}

ag_core "(A-3) 1基準 = 1主張の原則" '**1つの受入基準に書く主張は1つだけ**にする'
ag_core "(A-3) 複合文の禁止" '**複合文を1基準にまとめない**'
ag_core "(A-3) 1主張の数え方（撤回可能性で数える）" \
  '**1主張 ＝ それ単独で撤回・変更でき、撤回すれば利用者の観測が変わる言明**'
ag_core "(A-3) 停止条件が「それ以上割らない」条件として提示されている" \
  '**次の2つのいずれかに当たれば、それ以上割らない**（原子化の停止条件'
ag_core "(A-3) 停止条件が定義と同じ軸で判定されると明記している" \
  '**どちらも「独立に撤回・変更できるか」という定義と同じ軸で判定する**'
ag_core "(A-3) 停止条件 S1（同一規則の実例）" '**(S1) 同一規則の実例**'
ag_core "(A-3) S1 は規則を1基準とし実例は基準文に列挙する" \
  '**規則を1基準とし、実例は基準文の中で列挙する**'
ag_core "(A-3) S1 は「単文の基準＋多数のテスト」を正常形と認める" \
  '**基準文が単文でテストが多数**なのは S1 の正常な形であり、複合文の証拠ではない'
ag_core "(A-3) 停止条件 S2（条件と結果を切り離さない）" \
  '**(S2) 条件と結果を切り離すと「何が・どういう条件で・どうなる」の1文として成り立たなくなる**'
ag_core "(A-3) 同時観測はまとめる理由にならない（定義と別の軸を混ぜない）" \
  '**同時に観測できること**——1つの応答の**ステータスとボディ**は同時に現れても `400` を保ったままエラースキーマだけ変えられるため**別の受入基準**にする'
ag_core "(A-3) テストが書けないことはまとめる理由にならない（網羅の問題であって粒度の問題ではない）" \
  '**いまテストを書けないこと**——それは粒度ではなく網羅の問題であり、**まとめ直さずにテストを足すか基準を狭める**'
ag_core "(A-3) 割りすぎの検算がある" '割った断片の**すべてが同じ1テストケースで検証される**なら割りすぎ'
ag_core "(A-3) 網羅の対象が基準文であることが明示されている" \
  '**検証は「基準文に対して網羅」であり「テストスイートに対して網羅」ではない**'
ag_core "(A-3) 基準文の全事実を裏付ける（代表1本で完了としない）" \
  '**そのすべてを裏付けるテストを用意する**（代表テスト1本で完了としない）'
ag_core "(A-3) 基準文が述べていない振る舞いを足さない（受入基準の肥大防止）" \
  '**基準文が述べていない振る舞いを受入基準に足さない**'
ag_core "(A-3) over-claim 禁止（実装で用意できる見込みを条件にする）" \
  '**実装で用意できる見込みがある**場合にのみ書き'
ag_core "(A-3) こぼれた範囲の回送先（要人間判定として仕様に残す）" \
  '**見込めないときだけ**基準を実担保範囲へ狭め、こぼれた範囲は「要人間判定」として仕様に残す'
ag_core "(A-3) テストが無いことだけを理由に基準を狭めない（実装前の手順で前倒し判定しない）" \
  '**「いまテストが無い」ことだけを理由に基準を狭めない**'
ag_core "(A-3) 機械（spec-lint）はこの規約を検査できないと明記している" \
  '**`spec-lint` はこの規約を検査できない**'
ag_core "(A-3) 前向き適用（既存の受入基準の一括再分割を要求しない）" \
  '**本規約は新たに書く受入基準に適用する**（既存の受入基準の一括再分割は要求しない）'

echo ""
echo "=== (A-4) 定型文が台帳用語から独立している（移植の要件そのもの） ==="

# 台帳レジーム（凍結）の語彙が混ざっていると、SDD の受入基準を書く手順が
# 存在しない台帳・裁可を前提にしてしまう。
for ledger_term in '保証台帳' '保証 ID' '裁可' 'guarantee-index-check' 'missing_test_ref' 'G-{' 'Gaps'; do
  found="false"
  printf '%s\n' "$CANON_BOILERPLATE" | grep -qF -- "$ledger_term" && found="true"
  assert_eq "(A-4) 定型文に台帳用語が混ざっていない: ${ledger_term}" "false" "$found"
done

echo ""
echo "=== (A-5) 「適用先」表から読み取れる／各ファイルに逐語コピーが在る ==="

APPLY_ROW="$(grep -m1 -F -- '| 受入基準の粒度 |' "$STRATEGY_FILE")"
APPLY_ROW_RC=$?
assert_eq "(A-5) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$APPLY_ROW_RC" -le 1 ]; then echo true; else echo false; fi)"
assert_eq "(A-5) 適用先表に「受入基準の粒度」の行が在る" "true" \
  "$(if [ -n "$APPLY_ROW" ]; then echo true; else echo false; fi)"

DECLARED_TARGETS="$(printf '%s\n' "$APPLY_ROW" | grep -o '`[^`]*`' | tr -d '`' | sort -u)"
DECLARED_COUNT="$(printf '%s\n' "$DECLARED_TARGETS" | grep -c '[^[:space:]]')"
assert_eq "(A-5) 適用先を1件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$DECLARED_COUNT" -ge 1 ]; then echo true; else echo false; fi)"

while IFS= read -r target; do
  [ -z "$target" ] && continue
  if [ ! -r "${REPO_ROOT}/${target}" ]; then
    assert_eq "(A-5) 適用先が実在する: ${target}" "true" "false"
    continue
  fi
  assert_eq "(A-5) 定型文が逐語で1回だけ存在する: ${target}" "1" \
    "$(count_block "${REPO_ROOT}/${target}" "$CANON_BOILERPLATE")"
done <<<"$DECLARED_TARGETS"

echo ""
echo "=== (A-6) 表と実際のコピーの双方向一致（取りこぼし・誤コピーの両方を見る） ==="

ACTUAL_TARGETS="$(grep -rlF -- "$CANON_MARKER" skills agents)"
ACTUAL_RC=$?
assert_eq "(A-6) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$ACTUAL_RC" -le 1 ]; then echo true; else echo false; fi)"
ACTUAL_TARGETS="$(printf '%s\n' "$ACTUAL_TARGETS" | grep '[^[:space:]]' | sort -u)"

assert_eq "(A-6) 正本コメントを持つファイルの集合が適用先表と一致する" \
  "$DECLARED_TARGETS" "$ACTUAL_TARGETS"

echo ""
echo "=== (A-7) 「適用しない範囲」に挙げたファイルは定型文を持たない ==="

# 表の**1列目（適用しない対象）**だけを見る。理由列に例示として現れるパス（下流スクリプト等）を
# 例外対象と取り違えないため。
EXCLUDED_TARGETS="$(awk '
  /^##### 受入基準の粒度を適用しない範囲/ { insec = 1; next }
  insec && /^#### / { exit }
  insec && /^## /  { exit }
  insec && /^\| / { print }
' "$STRATEGY_FILE" | awk -F'|' '{ print $2 }' | grep -o '`[^`]*`' | tr -d '`' | grep -E '\.(md|sh)$' | sort -u)"

EXCLUDED_COUNT="$(printf '%s\n' "$EXCLUDED_TARGETS" | grep -c '[^[:space:]]')"
assert_eq "(A-7) 例外表からファイルを3件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$EXCLUDED_COUNT" -ge 3 ]; then echo true; else echo false; fi)"

while IFS= read -r excluded; do
  [ -z "$excluded" ] && continue
  assert_eq "(A-7) 例外に挙げたファイルが実在する: ${excluded}" "true" \
    "$(if [ -r "${REPO_ROOT}/${excluded}" ]; then echo true; else echo false; fi)"
  [ -r "${REPO_ROOT}/${excluded}" ] || continue
  assert_eq "(A-7) 例外に挙げたファイルは定型文を持たない: ${excluded}" "0" \
    "$(count_block "${REPO_ROOT}/${excluded}" "$CANON_BOILERPLATE")"
done <<<"$EXCLUDED_TARGETS"

# 判定側・GDD 側が例外として明示されていること（例外表が空洞化していないことの確認）
assert_file_contains "(A-7) 判定側（spec-critic）が例外に挙がっている" "$STRATEGY_FILE" \
  '`agents/spec-critic.md`（`acceptance-criteria-testability`）'
assert_file_contains "(A-7) GDD の保証節（5.3 が正本）が例外に挙がっている" "$STRATEGY_FILE" \
  '**同じ規律を2つの正本から配らない**'

echo ""
echo "=== (A-8) 規約が強制を委ねている先（spec-critic の複合文判定）が実在する ==="

# 正本は「複合文の強制は spec-critic の acceptance-criteria-testability が担う」と書いて
# いるだけなので、判定側からこの規則が消えると規約が誰にも強制されないまま残る。
assert_file_contains "(A-8) 判定側が複合文を blocker 候補としている" "$CRITIC_FILE" \
  '**1項目に複数の主張が入った複合文は blocker 候補**'
assert_file_contains "(A-8) 判定側が「代表1件だけが検証される」を理由に挙げている" "$CRITIC_FILE" \
  '**代表1件だけが検証される形**'
assert_file_contains "(A-8) 判定側が S1（同一規則の実例）を割らせない例外を持つ" "$CRITIC_FILE" \
  '**ただし同一規則の実例の列挙は複合文ではない**'
assert_file_contains "(A-8) 判定側が生成側の正本（4.5）を出典コメントで指している" "$CRITIC_FILE" \
  '<!-- 生成側の規約の正本: docs/ai-driven-development-strategy.md 4.5「受入基準の粒度」 -->'
assert_file_contains "(A-8) 正本が強制の所在として spec-critic を指している" "$STRATEGY_FILE" \
  '`spec-critic` の `acceptance-criteria-testability`（`/define-feature` 6.5）'

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
