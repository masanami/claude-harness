#!/bin/bash
# test-guarantee-granularity.sh
# 保証の粒度規約（`docs/ai-driven-development-strategy.md` 5.3「保証の粒度」）の構造不変条件テスト。
#
# 散文の規約は型検査もテストも効かないため、規約そのものではなく**規約が成立するための構造**を固定する:
#   (G-1) 正本に粒度節が 5.3 の中に在る
#   (G-2) 配送用の定型文を正本から切り出せる（切り出し失敗を pass にしない）
#   (G-3) 定型文の不変コア（停止条件 S1〜S3 / 網羅の対象 / 機械の保証水準 / 前向き適用）が揃っている。
#         意味を反転しても部分一致は通るため、可変部を含まない**一文まるごと**で照合する
#   (G-4)(G-5)(G-6) 「定型文の適用先」表と、実際にコピーを持つファイルの**双方向一致**。
#         表に在るのにコピーが無い（横展開の取りこぼし）／コピーが在るのに表に無い（例外への誤コピー）の両方を検出する
#   (G-7) 「適用しない範囲」に挙げたファイルが定型文を**持たない**。規則の横展開は適用範囲の例外を
#         見落として別種の欠陥を作る（PR #176 の回帰と同型）ため、例外側も機械で固定する
#   (G-8) 規約が強制を委ねている先（`guarantee-auditor` の `verify` の網羅判定）が実在する。
#         正本は「網羅の強制は verify が担う」と書いているだけなので、verify 側が消えると規約が宙に浮く
#   (G-9) スクリプト仕様に保証水準の境界が書かれている（`pass` が粒度・網羅性を主張しないこと）
#
# 逐語照合は正本から抜き出した文字列で行い、**テストに定型文の literal を置かない**
# （置くと正本を変えてもテストだけが古い値で通り続ける。3つ目のコピーになる）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。awk は正規表現マッチと print にのみ使い、比較は bash の
# 文字列比較（バイト厳密）と grep -F で行う。
#
# 実行方法: bash scripts/tests/test-guarantee-granularity.sh

set -u

GG_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${GG_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

STRATEGY_FILE="${REPO_ROOT}/docs/ai-driven-development-strategy.md"
SPEC_FILE="${REPO_ROOT}/scripts/specs/guarantee-index-check.md"
AUDITOR_FILE="${REPO_ROOT}/agents/guarantee-auditor.md"

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

# 指定ファイルに固定文字列が逐語で存在することを検査する（1行分の照合）。
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
# grep -F は行単位でしか見ないため、連続性（＝逐語のブロック）を確かめられない。
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

echo "=== (G-0) count_block の自己検査（検出器が壊れていたら以降の照合は無意味） ==="

GG_TMP="$(mktemp -d)"
trap 'rm -rf "$GG_TMP"' EXIT
printf 'alpha\nbeta\ngamma\nbeta\ngamma\n' > "${GG_TMP}/fixture.txt"
assert_eq "(G-0) 連続する2行ブロックを2回検出する" "2" \
  "$(count_block "${GG_TMP}/fixture.txt" "$(printf 'beta\ngamma')")"
assert_eq "(G-0) 行は在るが連続していないブロックは検出しない" "0" \
  "$(count_block "${GG_TMP}/fixture.txt" "$(printf 'alpha\ngamma')")"
assert_eq "(G-0) 存在しないブロックは 0" "0" \
  "$(count_block "${GG_TMP}/fixture.txt" "$(printf 'delta')")"
assert_eq "(G-0) 1行違うだけのブロックは検出しない（バイト厳密）" "0" \
  "$(count_block "${GG_TMP}/fixture.txt" "$(printf 'beta\ngammaX')")"

echo ""
echo "=== (G-1) 正本に粒度節が在る（5.3 の中） ==="

for f in "$STRATEGY_FILE" "$SPEC_FILE" "$AUDITOR_FILE"; do
  assert_eq "(G-1) 検査対象を読める（読めない状態を pass にしない）: $(basename "$f")" \
    "true" "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

assert_file_contains "(G-1) 粒度節の見出しが在る" "$STRATEGY_FILE" \
  '#### 保証の粒度（1保証 = 1約束。各実行時ファイルへコピーする定型文）'

# 5.3 の中に在ること（5.4 より手前）。行番号は awk の正規表現マッチで取る。
GRAN_LINE="$(awk '/^#### 保証の粒度/ { print NR; exit }' "$STRATEGY_FILE")"
SEC53_LINE="$(awk '/^### 5\.3 /  { print NR; exit }' "$STRATEGY_FILE")"
SEC54_LINE="$(awk '/^### 5\.4 /  { print NR; exit }' "$STRATEGY_FILE")"
assert_eq "(G-1) 5.3 の見出しを見つけられる" "true" \
  "$(if [ -n "$SEC53_LINE" ]; then echo true; else echo false; fi)"
assert_eq "(G-1) 5.4 の見出しを見つけられる" "true" \
  "$(if [ -n "$SEC54_LINE" ]; then echo true; else echo false; fi)"
assert_eq "(G-1) 粒度節は 5.3 と 5.4 の間に在る" "true" \
  "$(if [ -n "$GRAN_LINE" ] && [ -n "$SEC53_LINE" ] && [ -n "$SEC54_LINE" ] \
      && [ "$GRAN_LINE" -gt "$SEC53_LINE" ] && [ "$GRAN_LINE" -lt "$SEC54_LINE" ]; then echo true; else echo false; fi)"

assert_file_contains "(G-1) 書式の規約から粒度節へ導線が張られている" "$STRATEGY_FILE" \
  '- **粒度**: **1つの保証に書く約束は1つだけ**（複合文にしない）。'

echo ""
echo "=== (G-2) 配送用の定型文を正本から切り出せる ==="

# 粒度節の中の ```text フェンス（＝各実行時ファイルへコピーする定型文）だけを取り出す。
# 節の範囲を限定しないと、5.3 に並ぶ他の定型文フェンスを拾ってしまう。
CANON_BOILERPLATE="$(awk '
  /^#### 保証の粒度/ { insec = 1 }
  insec && /^#### 保証節の識別規則/ { exit }
  insec && /^```text$/ && !started { started = 1; next }
  started && /^```$/ { exit }
  started { print }
' "$STRATEGY_FILE")"

assert_eq "(G-2) 定型文を切り出せる（切り出し失敗を pass にしない）" "true" \
  "$(if [ -n "$CANON_BOILERPLATE" ]; then echo true; else echo false; fi)"

CANON_MARKER='<!-- 正本: docs/ai-driven-development-strategy.md 5.3「保証の粒度」 -->'
assert_eq "(G-2) 切り出した定型文が正本コメントで終わる" "true" \
  "$(if [ "${CANON_BOILERPLATE##*$'\n'}" = "$CANON_MARKER" ]; then echo true; else echo false; fi)"
assert_eq "(G-2) 定型文は正本のフェンス内に1回だけ現れる" "1" \
  "$(count_block "$STRATEGY_FILE" "$CANON_BOILERPLATE")"

echo ""
echo "=== (G-3) 定型文の不変コア（可変部を含まない一文まるごとで照合） ==="

# 反転・削除されると規約が意味を失う節だけを固定する。全文のバイト一致は要求しない
# （呼び出し箇所ごとに正当に異なる部分を潰すと回帰を作る。docs/skill-note-inventory.md §1）。
gg_core() {
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

gg_core "(G-3) 1保証 = 1約束の原則" '**1つの保証に書く約束は1つだけ**にする'
gg_core "(G-3) 複合文の禁止" '**複合文を1保証にまとめない**'
gg_core "(G-3) 1約束の数え方（撤回可能性で数える）" \
  '**1約束 ＝ それ単独で撤回・変更でき、撤回すれば消費者の観測が変わる公開面の言明**'
gg_core "(G-3) 停止条件が「それ以上割らない」条件として提示されている" \
  '**次の2つのいずれかに当たれば、それ以上割らない**（原子化の停止条件'
gg_core "(G-3) 停止条件が定義と同じ軸で判定されると明記している" \
  '**どちらも「独立に撤回・変更できるか」という定義と同じ軸で判定する**'
gg_core "(G-3) 停止条件 S1（同一規則の実例）" '**(S1) 同一規則の実例**'
gg_core "(G-3) S1 は規則を1約束とし実例は約束文に列挙する" \
  '**規則を1約束とし、実例は約束文の中で列挙する**'
gg_core "(G-3) S1 は「単文の見出し＋多数の引用」を正常形と認める" \
  '**見出しが単文で引用が多数**なのは S1 の正常な形であり、複合文の証拠ではない'
gg_core "(G-3) 停止条件 S2（条件と結果を切り離さない）" \
  '**(S2) 条件と結果を切り離すと「何が・どういう条件で・どうなる」の1文として成り立たなくなる**'
gg_core "(G-3) 割りすぎの検算がある" '割った断片の**すべてが同じ1テストケースを引く**なら割りすぎ'
gg_core "(G-3) 引用は代表か網羅かが明示されている" \
  '**引用は「約束文に対して網羅」であり「テストスイートに対して網羅」ではない**'
gg_core "(G-3) 約束文の全事実を引用する（代表テストだけを引かない）" \
  '**そのすべてについて裏付けるテストを引用する**（代表テストだけを引かない）'
gg_core "(G-3) 約束文が述べていない振る舞いは引用しない（台帳肥大の防止）" \
  '**約束文が述べていない振る舞いは、関連するテストがあっても引用しない**'
gg_core "(G-3) over-claim 禁止（引用済み・実装で用意できる見込みの両方を認める）" \
  '**引用できるか、実装前ならそのテストを用意できる見込みがある**場合にのみ書き'
gg_core "(G-3) こぼれた範囲の回送先（宣言時点は要人間判定）" \
  '**いずれも見込めないときだけ**約束を実担保範囲へ狭め、こぼれた範囲を Gaps（宣言の時点なら要人間判定）へ回す'
gg_core "(G-3) 同時観測はまとめる理由にならない（P1: 定義と別の軸を混ぜない）" \
  '**同時に観測できること**——1つの応答の**ステータスとボディ**は同時に現れても `400` を保ったままエラースキーマだけ変えられるため**別の保証**にする'
gg_core "(G-3) 引用が無いことはまとめる理由にならない（網羅の問題であって粒度の問題ではない）" \
  '**いま引用できるテストが無いこと**——それは粒度ではなく網羅の問題であり、**まとめ直さずにテストを足すか約束を狭める**'
gg_core "(G-3) 引用の有無だけを理由に約束を狭めない（P2-2: 実装前の手順で前倒し判定しない）" \
  '**「いま引用できるテストが無い」ことだけを理由に約束を狭めない**'
gg_core "(G-3) 索引チェックはこの規約を検査できないと明記している" \
  '**索引チェック（`guarantee-index-check`）はこの規約を検査できない**'
gg_core "(G-3) missing_test_ref の保証水準（引用ゼロしか見ない）" \
  '`missing_test_ref` が見るのは「引用が1本も無い」ことだけで、「約束の数より引用が少ない」は検出できない'
gg_core "(G-3) pass は粒度・網羅性の充足を主張しない" \
  '**`status: "pass"` は粒度・網羅性の充足を主張しない**'
gg_core "(G-3) 前向き適用（既存台帳の一括再分割を要求しない）" \
  '**本規約は新たに書く約束文に適用する**（既存台帳の一括再分割は要求しない'
gg_core "(G-3) エージェントの自発的な一括再分割を禁じている" \
  '**エージェントが自発的に台帳を一括再分割しない**'

echo ""
echo "=== (G-4) 「定型文の適用先」表から粒度の行を読み取れる ==="

APPLY_ROW="$(grep -m1 -F -- '| 保証の粒度 |' "$STRATEGY_FILE")"
APPLY_ROW_RC=$?
assert_eq "(G-4) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$APPLY_ROW_RC" -le 1 ]; then echo true; else echo false; fi)"
assert_eq "(G-4) 適用先表に「保証の粒度」の行が在る" "true" \
  "$(if [ -n "$APPLY_ROW" ]; then echo true; else echo false; fi)"

# 行内のバッククォート囲みを適用先のパスとして取り出す。
DECLARED_TARGETS="$(printf '%s\n' "$APPLY_ROW" | grep -o '`[^`]*`' | tr -d '`' | sort)"
DECLARED_COUNT="$(printf '%s\n' "$DECLARED_TARGETS" | grep -c '[^[:space:]]')"
assert_eq "(G-4) 適用先を1件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$DECLARED_COUNT" -ge 1 ]; then echo true; else echo false; fi)"

echo ""
echo "=== (G-5) 表に挙がった各ファイルに定型文が逐語で存在する ==="

while IFS= read -r target; do
  [ -z "$target" ] && continue
  if [ ! -r "${REPO_ROOT}/${target}" ]; then
    assert_eq "(G-5) 適用先が実在する: ${target}" "true" "false"
    continue
  fi
  assert_eq "(G-5) 定型文が逐語で1回だけ存在する: ${target}" "1" \
    "$(count_block "${REPO_ROOT}/${target}" "$CANON_BOILERPLATE")"
done <<<"$DECLARED_TARGETS"

echo ""
echo "=== (G-6) 表と実際のコピーの双方向一致（取りこぼし・誤コピーの両方を見る） ==="

ACTUAL_TARGETS="$(grep -rlF -- "$CANON_MARKER" skills agents)"
ACTUAL_RC=$?
assert_eq "(G-6) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$ACTUAL_RC" -le 1 ]; then echo true; else echo false; fi)"
ACTUAL_TARGETS="$(printf '%s\n' "$ACTUAL_TARGETS" | grep '[^[:space:]]' | sort)"

assert_eq "(G-6) 正本コメントを持つファイルの集合が適用先表と一致する" \
  "$DECLARED_TARGETS" "$ACTUAL_TARGETS"

echo ""
echo "=== (G-7) 「適用しない範囲」に挙げたファイルは定型文を持たない ==="

# 例外表の行から、実在するファイルパス（バッククォート囲み）を取り出す。
# 例外の一覧をテスト側に literal で持つと、正本から例外が消えてもテストが古い前提で通り続ける。
EXCLUDED_TARGETS="$(awk '
  /^##### 粒度規約を適用しない範囲/ { insec = 1; next }
  insec && /^#### / { exit }
  insec && /^\| / { print }
' "$STRATEGY_FILE" | grep -o '`[^`]*`' | tr -d '`' | grep -E '\.(md|sh)$' | sort -u)"

EXCLUDED_COUNT="$(printf '%s\n' "$EXCLUDED_TARGETS" | grep -c '[^[:space:]]')"
assert_eq "(G-7) 例外表からファイルを3件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$EXCLUDED_COUNT" -ge 3 ]; then echo true; else echo false; fi)"

while IFS= read -r excluded; do
  [ -z "$excluded" ] && continue
  assert_eq "(G-7) 例外に挙げたファイルが実在する: ${excluded}" "true" \
    "$(if [ -r "${REPO_ROOT}/${excluded}" ]; then echo true; else echo false; fi)"
  [ -r "${REPO_ROOT}/${excluded}" ] || continue
  assert_eq "(G-7) 例外に挙げたファイルは定型文を持たない: ${excluded}" "0" \
    "$(count_block "${REPO_ROOT}/${excluded}" "$CANON_BOILERPLATE")"
done <<<"$EXCLUDED_TARGETS"

# 判定側の2ファイルが例外として明示されていること（例外表が空洞化していないことの確認）
assert_file_contains "(G-7) 台帳追記（転記）が例外に挙がっている" "$STRATEGY_FILE" \
  '`agents/feature-implementer.md` 2-5 の3（台帳追記）'
assert_file_contains "(G-7) 判定側（guarantee-auditor の verify）が例外に挙がっている" "$STRATEGY_FILE" \
  '`agents/guarantee-auditor.md` の `verify`'

echo ""
echo "=== (G-8) 規約が強制を委ねている先（verify の網羅判定）が実在する ==="

# 正本は「網羅の強制は guarantee-auditor の verify が担う」と書いているだけなので、
# verify 側からこの判定規則が消えると、規約が誰にも強制されないまま残る。
assert_file_contains "(G-8) verify が「約束のほうが広い」を判定軸に持つ" "$AUDITOR_FILE" \
  '**約束のほうが広い**'
assert_file_contains "(G-8) verify がそれを drifted とする" "$AUDITOR_FILE" \
  '場合は `drifted` です'
assert_file_contains "(G-8) 裏付けの無い部分がある約束を「確認できない」とする根拠が残っている" "$AUDITOR_FILE" \
  '裏付けの無い部分がある約束は「守られていることが確認できない」状態です'
assert_file_contains "(G-8) 正本が強制の所在として verify を指している" "$STRATEGY_FILE" \
  '`guarantee-auditor` の `verify`（`drifted`）／`/promote-verify` Step 5.5'

echo ""
echo "=== (G-9) スクリプト仕様に保証水準の境界が書かれている ==="

assert_file_contains "(G-9) 境界の節が在る" "$SPEC_FILE" \
  '## 約束の粒度・引用の網羅性は検査しない（保証水準の境界）'
assert_file_contains "(G-9) missing_test_ref が「引用ゼロ」しか見ないと明記している" "$SPEC_FILE" \
  '`missing_test_ref` が検出するのは「**テスト参照が1本も無い**保証」だけであり'
assert_file_contains "(G-9) 複合文＋代表1本は pass すると明記している" "$SPEC_FILE" \
  '**複合文の保証に代表テスト1本だけを引いた台帳は `pass` する**'
assert_file_contains "(G-9) pass が主張する範囲を限定している" "$SPEC_FILE" \
  '「保証が1約束に割れていること」「約束の全事実が裏付けられていること」は**主張しない**'
assert_file_contains "(G-9) 規約の正本の所在を示している" "$SPEC_FILE" \
  '`docs/ai-driven-development-strategy.md` 5.3「保証の粒度」'
assert_file_contains "(G-9) スクリプトへ粒度検査を足す解決を否定している" "$SPEC_FILE" \
  '**本スクリプトへ粒度の検査を足すことで解決しない**'
assert_file_contains "(G-9) 正本側にも境界の表が在る" "$STRATEGY_FILE" \
  '| 保証が1約束であること（複合文でない） | **検査できない**'

echo ""
echo "=== (G-10) 停止条件が定義と同じ軸である（PR #191 の P1 再発防止） ==="

# 定義は「独立に撤回・変更できるか」、旧 S1 は「同時にしか観測できるか」という**別の軸**だった。
# HTTP のステータスとボディは同時に観測されるが独立に変更でき（`400` を保ったままエラー
# スキーマだけ変える改訂は普通に起こる）、旧 S1 はこれを1保証に留め置いた。テストが
# ステータスしかアサートしていない場合、ボディの約束が裏付けの無いまま残る——本規約が
# 防ごうとしている「代表テストだけを引く」形そのものである。
# ここでは (a) 旧規則が復活していないこと、(b) 代わりに「まとめる理由にならないもの」として
# 明示されていることを、正本と全コピーについて固定する。

OLD_S1_RULE='同時にしか観測できない構成要素'
for target_file in "$STRATEGY_FILE" $(printf '%s\n' "$DECLARED_TARGETS"); do
  case "$target_file" in
    "$STRATEGY_FILE") check_path="$target_file" ;;
    *) check_path="${REPO_ROOT}/${target_file}" ;;
  esac
  [ -r "$check_path" ] || continue
  has_old="false"
  grep -qF -- "$OLD_S1_RULE" "$check_path" && has_old="true"
  assert_eq "(G-10) 「同時にしか観測できない」を停止条件にしていない: $(basename "$check_path")" \
    "false" "$has_old"
done

assert_file_contains "(G-10) 「まとめる理由にならないもの」の節が在る" "$STRATEGY_FILE" \
  '##### まとめる理由にならないもの（停止条件と混同しない）'
assert_file_contains "(G-10) 停止条件は定義と同じ軸だと明記している" "$STRATEGY_FILE" \
  '**停止条件は定義と同じ軸（独立に撤回・変更できるか）でなければならない。**'
assert_file_contains "(G-10) 同時観測がまとめる理由にならないと表に在る" "$STRATEGY_FILE" \
  '| **同時に観測できること**（1つの応答に同居する・1画面に同時に出る） |'
assert_file_contains "(G-10) ステータスとボディは別の保証だと明記している" "$STRATEGY_FILE" \
  '**別の規則＝別の保証**である'
assert_file_contains "(G-10) 旧規則の実害（裏付けの無いボディの留め置き）を記録している" "$STRATEGY_FILE" \
  '**ボディの約束を裏付けの無いまま同じ保証へ留め置く**'
assert_file_contains "(G-10) 引用ゼロがまとめる理由にならないと表に在る" "$STRATEGY_FILE" \
  '| **いま引用できるテストが無いこと** |'
assert_file_contains "(G-10) 割りすぎの検算が引用ゼロへ誤適用されないよう限定されている" "$STRATEGY_FILE" \
  '**この検算が働くのは「どの断片も同じ1本を引く」場合に限る**'
# 判定側の drifted 例が、この結論の根拠として実在していること（(G-8) と同じ強制点）
assert_file_contains "(G-10) 判定側が status+body の複合を drifted の例にしている" "$AUDITOR_FILE" \
  'テストはステータスしか見ていない）場合は `drifted` です'

echo ""
echo "=== (G-11) 正本の台帳書式例が、粒度規約に違反していない ==="

# 書式例が複合文（ステータス＋ボディ）のままだと、正本が自分の規約に反する見本を配ることになる。
# 例文はテストに直書きせず、正本とスクリプト仕様の**両方から抜き出して突き合わせる**
# （どちらかだけ直しても気付けない状態を残さない）。
CANON_EXAMPLE_HEADING="$(grep -m1 -- '^### G-123-1' "$STRATEGY_FILE")"
SPEC_EXAMPLE_HEADING="$(grep -m1 -- '^### G-123-1' "$SPEC_FILE")"
assert_eq "(G-11) 正本から書式例の保証見出しを抜き出せる" "true" \
  "$(if [ -n "$CANON_EXAMPLE_HEADING" ]; then echo true; else echo false; fi)"
assert_eq "(G-11) スクリプト仕様から書式例の保証見出しを抜き出せる" "true" \
  "$(if [ -n "$SPEC_EXAMPLE_HEADING" ]; then echo true; else echo false; fi)"
assert_eq "(G-11) 正本とスクリプト仕様の書式例が同一の約束文である" \
  "$CANON_EXAMPLE_HEADING" "$SPEC_EXAMPLE_HEADING"
# ステータスとボディの複合に戻っていないこと（旧形の再出現検出）
assert_eq "(G-11) 書式例がステータスとボディの複合文に戻っていない" "false" \
  "$(if printf '%s' "$CANON_EXAMPLE_HEADING" | grep -qF 'invalid_json'; then echo true; else echo false; fi)"

echo ""
echo "=== (G-12) bootstrap の Step B5 テンプレートが正規化後の約束文を受け取る ==="

# 旧テンプレートは `{behavior_ja をそのまま約束文にしたもの}` であり、S1（同一規則の実例を
# 1見出しへまとめる）とは**相互排他**だった（まとめは behavior_ja の書き換えを必然的に伴う）。
# テンプレートに従う限り実例ごとに1保証が生まれ、S1 に違反し続ける。
BOOTSTRAP_FILE="${REPO_ROOT}/skills/guarantee-audit/references/bootstrap-mode.md"
assert_eq "(G-12) bootstrap の参照ファイルを読める" "true" \
  "$(if [ -r "$BOOTSTRAP_FILE" ]; then echo true; else echo false; fi)"
assert_eq "(G-12) テンプレートが behavior_ja の逐語コピーを指示していない" "false" \
  "$(if grep -qF -- '{behavior_ja をそのまま約束文にしたもの}' "$BOOTSTRAP_FILE"; then echo true; else echo false; fi)"
assert_file_contains "(G-12) テンプレートの見出しが正規化後の約束文を受け取る" "$BOOTSTRAP_FILE" \
  '### {正規化した約束文（後述「見出し（約束文）の粒度」で整えたもの。`behavior_ja` の逐語コピーとは限らない）}'
assert_file_contains "(G-12) まとめた実例の test_ref を並べる形がテンプレートに在る" "$BOOTSTRAP_FILE" \
  '- テスト: `{同一規則の実例をまとめた場合は、まとめた分の test_ref をこの形で並べる}`'
assert_file_contains "(G-12) テンプレートと正規化が相互排他にならない旨を明記している" "$BOOTSTRAP_FILE" \
  '**Step B5 のテンプレートの見出しは、ここで整えた後の約束文を受け取る**'
assert_file_contains "(G-12) まとめた場合に引用を落とさない規律が在る" "$BOOTSTRAP_FILE" \
  '**同一規則の実例（S1）を1つの見出しへまとめた場合**は、`- テスト:` 行を複数行並べる'

echo ""
echo "=== (G-13) /create-ticket が実装前に「引用できるテスト」を条件にしない ==="

# /create-ticket は実装より前に走り、保証節の行にテスト参照の欄が無い。引用の有無を宣言の
# 条件にすると、「すべての列挙値を拒否する」のような正当な新規要件が必ず狭められる。
CT_FILE="${REPO_ROOT}/skills/create-ticket/references/guarantee-section.md"
assert_eq "(G-13) create-ticket の参照ファイルを読める" "true" \
  "$(if [ -r "$CT_FILE" ]; then echo true; else echo false; fi)"
assert_eq "(G-13) 旧規定（引用できないことを狭める条件にする）が残っていない" "false" \
  "$(if grep -qF -- 'それを固定するテストを裏付けとして書けない場合は' "$CT_FILE"; then echo true; else echo false; fi)"
assert_file_contains "(G-13) 実装より前に走ることを前提に置いている" "$CT_FILE" \
  '**本スキルは実装より前に走る**。保証節の行に**テスト参照の欄は無く**'
assert_file_contains "(G-13) 引用が無いことを狭める理由にしないと明記している" "$CT_FILE" \
  '**「いま引用できるテストが無い」ことを理由に約束を狭めない・判定保留へ送らない**'
assert_file_contains "(G-13) ここで確認するのは予定テストの用意可否だと明記している" "$CT_FILE" \
  '**その全称を固定するテストを実装で用意できる見込みがあるか**'
assert_file_contains "(G-13) 見込みがあれば全称のまま宣言してよい" "$CT_FILE" \
  '**見込みがあるなら全称のまま宣言してよい**'
assert_file_contains "(G-13) 網羅の実検査の所在（引用が作られる段階）を示している" "$CT_FILE" \
  '**引用が約束文を網羅しているかの実検査は本スキルでは行わない**'
assert_file_contains "(G-13) 正本にも実検査の所在が書かれている" "$STRATEGY_FILE" \
  '**引用が約束文を網羅しているかの実検査は、テストと台帳の引用が作られる段階**'

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
