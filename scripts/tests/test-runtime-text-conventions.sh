#!/bin/bash
# test-runtime-text-conventions.sh
# 実行時テキストと docs の書き分け規約（`docs/plugin-path-conventions.md` (h)）の
# 構造不変条件テスト。
#
# 本規約が判定に使うのは「この文を削るとモデルの振る舞いが変わるか」であり、これは文の意味に
# 依存するため決定的スクリプトでは検査できない（境界は (h)「機械が検査できる水準の境界」）。
# したがって本テストが固定するのは**規約の遵守**ではなく**規約が成立するための構造**である:
#   (R-1) 正本節 (h) が在り、(f)（参照禁止）より前に置かれている
#   (R-2) 配送用の定型文を正本から切り出せる（切り出し失敗を pass にしない）
#   (R-3) 定型文の不変コア（判定軸／書く側／書かない側／分量では判定しない／一括掃引を
#         しない／対象は変更が触った文）が揃っている。意味を反転しても部分一致は通る
#         ため、可変部を含まない**一文まるごと**で照合する
#   (R-4) **反転語彙の不在**。「重複しているから正本1箇所へ集約する」という読み替えは
#         到達性を失わせる（規約が headless 委譲で1バイトも届かなくなる）ため、この
#         読み替えが正本へ混入することを機械で止める
#   (R-5)(R-6) 「適用先」表と、実際にコピーを持つファイルの**双方向一致**。表に在るのに
#         コピーが無い（横展開の取りこぼし）／コピーが在るのに表に無い（例外への誤コピー）
#   (R-7) 「置かない範囲」に挙げたファイルが定型文を**持たない**。規則の横展開は例外の
#         見落としで別種の欠陥を作るため、例外側も機械で固定する
#   (R-8) 規約が強制を委ねている先（生成側 `feature-implementer` Phase 3-1 と、検出側
#         `code-reviewer` 観点G）が実在する。正本は「強制はこの2箇所が担う」と書いている
#         だけなので、どちらかが消えると規約がその分だけ宙に浮く
#   (R-9) 正本コメントが**純粋なポインタ**であり、規範を1文字も持たないこと。実行時ファイルの
#         HTML コメントがモデルへ配送されないことは保証された挙動ではないため、「配送されない」
#         側に賭けず、**配送されても失われる規範が無い**側で成立させる（(f) の
#         「規範は常にコメントの直前にインラインで書き切る」の機械化）
#
# 逐語照合は正本から抜き出した文字列で行い、**テストに定型文の literal を置かない**
# （置くと正本を変えてもテストだけが古い値で通り続ける。3つ目のコピーになる）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。比較は bash の文字列比較と grep -F で行う。
#
# 実行方法: bash scripts/tests/test-runtime-text-conventions.sh

set -u

RT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${RT_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CONV_FILE="${REPO_ROOT}/docs/plugin-path-conventions.md"
REVIEWER_FILE="${REPO_ROOT}/agents/code-reviewer.md"
IMPLEMENTER_FILE="${REPO_ROOT}/agents/feature-implementer.md"

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

echo "=== (R-0) count_block の自己検査（検出器が壊れていたら以降の照合は無意味） ==="

RT_TMP="$(mktemp -d)"
trap 'rm -rf "$RT_TMP"' EXIT
printf 'alpha\nbeta\ngamma\nbeta\ngamma\n' > "${RT_TMP}/fixture.txt"
assert_eq "(R-0) 連続する2行ブロックを2回検出する" "2" \
  "$(count_block "${RT_TMP}/fixture.txt" "$(printf 'beta\ngamma')")"
assert_eq "(R-0) 行は在るが連続していないブロックは検出しない" "0" \
  "$(count_block "${RT_TMP}/fixture.txt" "$(printf 'alpha\ngamma')")"
assert_eq "(R-0) 1行違うだけのブロックは検出しない（バイト厳密）" "0" \
  "$(count_block "${RT_TMP}/fixture.txt" "$(printf 'beta\ngammaX')")"

echo ""
echo "=== (R-1) 正本節 (h) が在る ==="

for f in "$CONV_FILE" "$REVIEWER_FILE" "$IMPLEMENTER_FILE"; do
  assert_eq "(R-1) 検査対象を読める（読めない状態を pass にしない）: $(basename "$f")" \
    "true" "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

assert_file_contains "(R-1) 書き分け節の見出しが在る" "$CONV_FILE" \
  '## (h) 実行時テキストと docs の書き分け（「行動を変えるか」で決める）'

H_LINE="$(awk '/^## \(h\) / { print NR; exit }' "$CONV_FILE")"
F_LINE="$(awk '/^## \(f\) / { print NR; exit }' "$CONV_FILE")"
assert_eq "(R-1) (h) は (f)（参照禁止）より前に在る" "true" \
  "$(if [ -n "$H_LINE" ] && [ -n "$F_LINE" ] && [ "$H_LINE" -lt "$F_LINE" ]; then echo true; else echo false; fi)"

assert_file_contains "(R-1) 判定軸が1問として提示されている" "$CONV_FILE" \
  '**判定軸**: **この文を削ると、次に読むモデルの振る舞いが変わるか。**'
assert_file_contains "(R-1) 分量ではないことが節として明示されている" "$CONV_FILE" \
  '### この規約は「分量を減らせ」ではない（最重要）'
assert_file_contains "(R-1) 理由を経緯と混同しない節が在る" "$CONV_FILE" \
  '### 「理由」は経緯ではない（削る側に倒さない）'
assert_file_contains "(R-1) 機械が検査できる水準の境界が明示されている" "$CONV_FILE" \
  '### 機械が検査できる水準の境界'
assert_file_contains "(R-1) 前向き適用（既存の一括掃引を要求しない）" "$CONV_FILE" \
  '**本規約は新たに書く／変更する文に適用する。**'
assert_file_contains "(R-1) 参照禁止 (f) から書き分け (h) へ委譲している" "$CONV_FILE" \
  '何が「置かない経緯」で、何が「残す規範の一部としての理由」かの判定軸は **(h)**'

echo ""
echo "=== (R-2) 配送用の定型文を正本から切り出せる ==="

# (h) の中の ```text フェンス（＝各実行時ファイルへコピーする定型文）だけを取り出す。
CANON_BOILERPLATE="$(awk '
  /^## \(h\) / { insec = 1; next }
  insec && /^## \(/ { exit }
  insec && /^```text$/ && !started { started = 1; next }
  started && /^```$/ { exit }
  started { print }
' "$CONV_FILE")"

assert_eq "(R-2) 定型文を切り出せる（切り出し失敗を pass にしない）" "true" \
  "$(if [ -n "$CANON_BOILERPLATE" ]; then echo true; else echo false; fi)"

CANON_MARKER='<!-- 正本: docs/plugin-path-conventions.md (h) -->'
assert_eq "(R-2) 切り出した定型文が正本コメントで終わる" "true" \
  "$(if [ "${CANON_BOILERPLATE##*$'\n'}" = "$CANON_MARKER" ]; then echo true; else echo false; fi)"
assert_eq "(R-2) 定型文は正本のフェンス内に1回だけ現れる" "1" \
  "$(count_block "$CONV_FILE" "$CANON_BOILERPLATE")"

echo ""
echo "=== (R-3) 定型文の不変コア（可変部を含まない一文まるごとで照合） ==="

rt_core() {
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

rt_core "(R-3) 対象は実行時に配送されるテキストであると定義している" \
  '**実行時にモデルへ配送されるテキスト**'
rt_core "(R-3) 判定軸（消したとき操作が変わるか）を1文ずつ適用する" \
  'を書く・変更するときは、**その文を消したとき、次に読むモデルが違う操作を選びうるか**で1文ずつ判定する'
rt_core "(R-3) 残す側の列挙（契約を含む）" \
  '**選びうるなら書く／残す**（何をするか・してはいけないか・どう判断するか・契約〔状態名・exit code・出力書式〕'
rt_core "(R-3) 理由は残す側であると明示している" \
  '**その形でなければ壊れる理由**——理由は後続の一括是正が規約を書き換えるのを止めるため、行動を変える文である'
rt_core "(R-3) 指摘する側の列挙（番号・出典・経緯・言い換え・既知前提）" \
  '**選ばないなら書かない**（Issue・PR・ADR の番号、出典、「〜が決定しており」といった宣言の経緯、用語の言い換え、読み手が既に知っている前提の再説明）'
rt_core "(R-3) 置き先（人間が読む面）を示している" \
  'これらは人間が読む面（設計文書・PR 本文・コミットメッセージ）に置く。'
rt_core "(R-3) 分量では判定しない（逐語コピーそれ自体は指摘しない）" \
  '**分量では判定しない**——同じ規約の逐語コピーが複数箇所に在ること自体は違反ではない'
rt_core "(R-3) 集約すると届かなくなる理由を併記している" \
  '参照ファイルへ集約すると実行時に読めないことがあり、規約が届かなくなる'
rt_core "(R-3) 既存箇所の一括掃引を求めない" \
  '**既存箇所の一括掃引はしない**——出典と規範が同じ文に同居している箇所があり、番号だけを機械的に削ると規範ごと落ちる'
rt_core "(R-3) 対象を変更が触った文に限っている" \
  '対象は**その変更が追加・変更した文**に限る'

echo ""
echo "=== (R-4) 反転語彙の不在（#179 の誤り〈集約せよ〉の再生産を止める） ==="

# 一文まるごとの照合（R-3）が主で、本検査は「別の言い回しで反転を書き足す」経路への
# 予備の歯止め。走査対象は正本節 (h) と、コピーを持つ実行時ファイルの両方。
CANON_SECTION="$(awk '
  /^## \(h\) / { insec = 1 }
  insec && /^## \(f\) / { exit }
  insec { print }
' "$CONV_FILE")"

assert_eq "(R-4) 正本節を切り出せる（切り出し失敗を pass にしない）" "true" \
  "$(if [ -n "$CANON_SECTION" ]; then echo true; else echo false; fi)"

for inverted in '分量で判定する' '重複を正本1箇所へ集約' '逐語コピーを減らす' '既存箇所を一括で掃引する' '冗長なので削る'; do
  found="false"
  printf '%s\n' "$CANON_SECTION" | grep -qF -- "$inverted" && found="true"
  assert_eq "(R-4) 正本節に反転語彙が無い: ${inverted}" "false" "$found"
  found="false"
  grep -rqF -- "$inverted" skills agents && found="true"
  assert_eq "(R-4) 実行時テキストに反転語彙が無い: ${inverted}" "false" "$found"
done

echo ""
echo "=== (R-5) 「適用先」表から読み取れる／各ファイルに逐語コピーが在る ==="

APPLY_ROW="$(grep -m1 -F -- '| 実行時テキストに補足を混ぜない |' "$CONV_FILE")"
APPLY_ROW_RC=$?
assert_eq "(R-5) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$APPLY_ROW_RC" -le 1 ]; then echo true; else echo false; fi)"
assert_eq "(R-5) 適用先表に「実行時テキストに補足を混ぜない」の行が在る" "true" \
  "$(if [ -n "$APPLY_ROW" ]; then echo true; else echo false; fi)"

DECLARED_TARGETS="$(printf '%s\n' "$APPLY_ROW" | grep -o '`[^`]*`' | tr -d '`' | sort -u)"
DECLARED_COUNT="$(printf '%s\n' "$DECLARED_TARGETS" | grep -c '[^[:space:]]')"
assert_eq "(R-5) 適用先を1件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$DECLARED_COUNT" -ge 1 ]; then echo true; else echo false; fi)"

while IFS= read -r target; do
  [ -z "$target" ] && continue
  if [ ! -r "${REPO_ROOT}/${target}" ]; then
    assert_eq "(R-5) 適用先が実在する: ${target}" "true" "false"
    continue
  fi
  assert_eq "(R-5) 定型文が逐語で1回だけ存在する: ${target}" "1" \
    "$(count_block "${REPO_ROOT}/${target}" "$CANON_BOILERPLATE")"
done <<<"$DECLARED_TARGETS"

echo ""
echo "=== (R-6) 表と実際のコピーの双方向一致（取りこぼし・誤コピーの両方を見る） ==="

ACTUAL_TARGETS="$(grep -rlF -- "$CANON_MARKER" skills agents)"
ACTUAL_RC=$?
assert_eq "(R-6) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$ACTUAL_RC" -le 1 ]; then echo true; else echo false; fi)"
ACTUAL_TARGETS="$(printf '%s\n' "$ACTUAL_TARGETS" | grep '[^[:space:]]' | sort -u)"

assert_eq "(R-6) 正本コメントを持つファイルの集合が適用先表と一致する" \
  "$DECLARED_TARGETS" "$ACTUAL_TARGETS"

echo ""
echo "=== (R-7) 「置かない範囲」に挙げたファイルは定型文を持たない ==="

# 表の**1列目（置かない対象）**だけを見る。理由列に例示として現れるパスを
# 例外対象と取り違えないため。
EXCLUDED_TARGETS="$(awk '
  /^#### 定型文を置かない範囲/ { insec = 1; next }
  insec && /^#### / { exit }
  insec && /^### /  { exit }
  insec && /^## /   { exit }
  insec && /^\| / { print }
' "$CONV_FILE" | awk -F'|' '{ print $2 }' | grep -o '`[^`]*`' | tr -d '`' | grep -E '\.(md|sh)$' | sort -u)"

EXCLUDED_COUNT="$(printf '%s\n' "$EXCLUDED_TARGETS" | grep -c '[^[:space:]]')"
assert_eq "(R-7) 例外表からファイルを3件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$EXCLUDED_COUNT" -ge 3 ]; then echo true; else echo false; fi)"

while IFS= read -r excluded; do
  [ -z "$excluded" ] && continue
  assert_eq "(R-7) 例外に挙げたファイルが実在する: ${excluded}" "true" \
    "$(if [ -r "${REPO_ROOT}/${excluded}" ]; then echo true; else echo false; fi)"
  [ -r "${REPO_ROOT}/${excluded}" ] || continue
  assert_eq "(R-7) 例外に挙げたファイルは定型文を持たない: ${excluded}" "0" \
    "$(count_block "${REPO_ROOT}/${excluded}" "$CANON_BOILERPLATE")"
done <<<"$EXCLUDED_TARGETS"

# 生成側・検出側の両方に置く理由が明記されていること（検出側だけに戻る退行を止める）
assert_file_contains "(R-7) 生成側・検出側の両方に置くことが明記されている" "$CONV_FILE" \
  '**書く時点（生成側）と読む時点（検出側）の両方に置く。**'

echo ""
echo "=== (R-8) 規約が強制を委ねている先（生成側 Phase 3-1 / 検出側 観点G）が実在する ==="

# 正本は「強制は観点Gが担う」と書いているだけなので、観点Gが消えると規約が
# 誰にも強制されないまま残る。
assert_file_contains "(R-8) 生成側に実行時テキスト節の見出しが在る" "$IMPLEMENTER_FILE" \
  '### 3-1. 実装対象が実行時テキストを含む場合'
assert_file_contains "(R-8) 生成側が書く時点での判定を求めている" "$IMPLEMENTER_FILE" \
  '判定は**書く時点**で通す（レビューでの指摘待ちにしない）'
assert_file_contains "(R-8) 正本が強制の所在として生成側を指している" "$CONV_FILE" \
  '`agents/feature-implementer.md` Phase 3-1'
assert_file_contains "(R-8) 検出側に観点G の見出しが在る" "$REVIEWER_FILE" \
  '### 観点G: 実行時テキストの書き分け（対象差分が実行時テキストを含む場合）'
assert_file_contains "(R-8) 検出側が補足の混入をチェック項目にしている" "$REVIEWER_FILE" \
  '**行動を変えない補足の混入**'
assert_file_contains "(R-8) 検出側が規範の巻き添え削除をチェック項目にしている" "$REVIEWER_FILE" \
  '**規範の巻き添え削除**'
assert_file_contains "(R-8) 正本が強制の所在として観点G を指している" "$CONV_FILE" \
  '`agents/code-reviewer.md` 観点G'
assert_file_contains "(R-8) 正本が「遵守は機械で検査できない」と明示している" "$CONV_FILE" \
  '**検査できない**（「行動を変えるか」は文の意味に依存する）'

echo ""
echo "=== (R-9) 正本コメントは純粋なポインタであり規範を持たない ==="

# 実行時ファイルの HTML コメントがモデルへ配送されないことは保証された挙動ではない。
# したがって「配送されない」前提に賭けず、**配送されても害が無い**形で成立させる:
#   (1) コメント行はポインタの書式ちょうどであること（規範を紛れ込ませられない）
#   (2) コメント行を取り除いても、定型文の規範が丸ごと残っていること
CANON_BODY="${CANON_BOILERPLATE%$'\n'*}"

assert_eq "(R-9) 定型文はコメント行以外の本体を持つ" "true" \
  "$(if [ -n "$CANON_BODY" ] && [ "$CANON_BODY" != "$CANON_BOILERPLATE" ]; then echo true; else echo false; fi)"

# (1) `<!-- 正本: <パス> (<節>) -->` ちょうどの形。説明・規範を足すと落ちる。
# 照合は**正本から切り出した実際のコメント行**に対して行う（テスト側の literal に掛けると、
# 正本とテストを同時に書き換える掃引を素通りさせる＝検査がタウトロジーになる）。
CANON_MARKER_ACTUAL="${CANON_BOILERPLATE##*$'\n'}"
assert_eq "(R-9) 正本コメントがポインタの書式ちょうどである（規範を含められない）" "true" \
  "$(if printf '%s' "$CANON_MARKER_ACTUAL" | grep -qE '^<!-- 正本: [A-Za-z0-9_./-]+\.md \([a-z]\) -->$'; then echo true; else echo false; fi)"

# (2) 規範はコメントの外に在る（コメントが読まれなくても規約が成立する）
assert_eq "(R-9) コメントを除いた本体だけで判定軸が読み取れる" "true" \
  "$(if printf '%s\n' "$CANON_BODY" | grep -qF -- '**その文を消したとき、次に読むモデルが違う操作を選びうるか**'; then echo true; else echo false; fi)"

assert_file_contains "(R-9) 正本がこの不変条件（コメントは配送されても害が無い形）を明記している" "$CONV_FILE" \
  '**正本コメントは純粋なポインタにする。**'

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
