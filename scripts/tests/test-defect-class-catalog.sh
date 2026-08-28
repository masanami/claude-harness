#!/bin/bash
# test-defect-class-catalog.sh
#
# 欠陥クラスのカタログ（`docs/defect-class-catalog.md`）と、それを使う掃引モード
# （`agents/defect-sweeper.md` / `skills/self-review/references/defect-sweep.md`）の
# 構造不変条件テスト。
#
# 「掃引者が本当に差分の全体を読んだか」「クラスの選定が実害の観測に基づくか」は散文の規約で
# あり、決定的スクリプトでは検査できない（境界は正本 §7）。本テストが固定するのは**規約が
# 成立するための構造**である:
#   (E-0) 抽出器・照合器の自己検査（検出器が壊れていたら以降の照合は無意味）
#   (E-1) 正本に2つの定型文ブロックが**ちょうど1つずつ**在り、抽出できる（抽出失敗を
#         pass にしない）。実行時ファイルはマーカーを持たない（正本は1箇所）
#   (E-2)(E-3) 「適用先」表と、実際にコピーを持つファイルの**双方向一致**。表に在るのに
#         コピーが無い（横展開の取りこぼし）／コピーが在るのに表に無い（例外への誤コピー）
#   (E-4) 掃引の規律の不変コア（好意的解釈をしない／全体を掃引する／実行して自己検証する／
#         検出0件でも掃引範囲を報告する／掃引できなかった対象を0件に丸めない）。意味を
#         反転しても部分一致は通るため、可変部を含まない**一文まるごと**で照合する
#   (E-5) **索引とクラス定義の ID 集合・題名の一致**（語彙駆動）。クラスを増減させたときに
#         片方だけを更新すると落ちる。ID の重複・書式ずれも見る
#   (E-6) **反転語彙の不在**。「検出0件のクラスは報告から省略してよい」という読み替えは
#         掃引の網羅性の主張そのものを空虚にするため、機械で止める
#   (E-7) **`sweepOutcome` 真理値表の完全性と参照実装との一致**。3入力の全8組合せが重複なく
#         1回ずつ現れ、各行が参照実装と一致する。**掃引した対象が空のケース**（空虚な真の
#         入口）を表から落とせないようにする
#   (E-8) **既存の軽い使い方が壊れていないこと**。引数なし＝標準モードであり、掃引モードへは
#         完全一致でしか入らない、が規定として在る
#   (E-9) 掃引モードが委ねている先（掃引エージェント・`finding-verifier`・報告契約）が実在し、
#         接続されている。あわせて **severity 語彙の第2リストの不在**（しきい値の正本は
#         `skills/self-review/SKILL.md` の `convergence-canon` ブロックに1つだけ）
#
# 逐語照合は正本から抜き出した文字列で行い、**テストに定型文の literal を置かない**
# （置くと正本を変えてもテストだけが古い値で通り続ける。3つ目のコピーになる）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。比較は bash の文字列比較と grep -F で行う。
# 同じ理由で **`sort -u` に非 ASCII の行を渡さない**（macOS 標準 sort はロケール次第で
# 相異なる日本語行を等価と判定する）。(E-7) の組合せキーは ASCII だけで持つ。
#
# 実行方法: bash scripts/tests/test-defect-class-catalog.sh

set -u

DC_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DC_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CANON_FILE="docs/defect-class-catalog.md"
SWEEP_REF="skills/self-review/references/defect-sweep.md"
SELF_REVIEW="skills/self-review/SKILL.md"
CANON_MARKER='<!-- 正本: docs/defect-class-catalog.md -->'

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
  if [ -r "$file" ] && grep -qF -- "$phrase" "$file"; then
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

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# マーカー間の行を取り出し、配送用フェンス（```text ... ```）を剥がす。
extract_block() {
  local file="$1" start="$2" end="$3"
  awk -v s="$start" -v e="$end" '
    index($0, s) == 1 { inb = 1; next }
    index($0, e) == 1 { inb = 0; next }
    inb { print }
  ' "$file" | awk '
    { lines[NR] = $0 }
    END {
      first = 1; last = NR
      if (lines[first] == "```text") first++
      if (lines[last] == "```") last--
      for (i = first; i <= last; i++) print lines[i]
    }
  '
}

count_marker() { grep -cF -- "$2" "$1" | tr -d ' '; }

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

yn() { case "$1" in あり) printf '1' ;; なし) printf '0' ;; *) printf '?' ;; esac; }

echo "=== (E-0) 抽出器・照合器の自己検査 ==="

DC_TMP="$(mktemp -d)"
trap 'rm -rf "$DC_TMP"' EXIT
printf 'x\n<!-- b:start -->\n```text\nalpha\nbeta\n```\n<!-- b:end -->\ny\nalpha\nbeta\n' > "${DC_TMP}/fx.md"
assert_eq "(E-0) マーカー間からフェンスを剥がして抽出する" "$(printf 'alpha\nbeta')" \
  "$(extract_block "${DC_TMP}/fx.md" '<!-- b:start -->' '<!-- b:end -->')"
assert_eq "(E-0) マーカーが無ければ空を返す（空を pass にしない根拠）" "" \
  "$(extract_block "${DC_TMP}/fx.md" '<!-- z:start -->' '<!-- z:end -->')"
printf 'alpha\nbeta\ngamma\nbeta\ngamma\n' > "${DC_TMP}/fixture.txt"
assert_eq "(E-0) 連続する2行ブロックを2回検出する" "2" \
  "$(count_block "${DC_TMP}/fixture.txt" "$(printf 'beta\ngamma')")"
assert_eq "(E-0) 行は在るが連続していないブロックは検出しない" "0" \
  "$(count_block "${DC_TMP}/fixture.txt" "$(printf 'alpha\ngamma')")"
assert_eq "(E-0) 1行違うだけのブロックは検出しない（バイト厳密）" "0" \
  "$(count_block "${DC_TMP}/fixture.txt" "$(printf 'beta\ngammaX')")"

echo ""
echo "=== (E-1) 正本に2つの定型文ブロックがちょうど1つずつ在り、抽出できる ==="

for f in "$CANON_FILE" "$SWEEP_REF" "$SELF_REVIEW" "agents/defect-sweeper.md"; do
  assert_eq "(E-1) 検査対象を読める（読めない状態を pass にしない）: ${f}" "true" \
    "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

CAT_START='<!-- defect-class-catalog:start -->'
CAT_END='<!-- defect-class-catalog:end -->'
IDX_START='<!-- defect-class-index:start -->'
IDX_END='<!-- defect-class-index:end -->'

assert_eq "(E-1) カタログ開始マーカーが正本にちょうど1本" "1" "$(count_marker "$CANON_FILE" "$CAT_START")"
assert_eq "(E-1) カタログ終了マーカーが正本にちょうど1本" "1" "$(count_marker "$CANON_FILE" "$CAT_END")"
assert_eq "(E-1) 索引開始マーカーが正本にちょうど1本" "1" "$(count_marker "$CANON_FILE" "$IDX_START")"
assert_eq "(E-1) 索引終了マーカーが正本にちょうど1本" "1" "$(count_marker "$CANON_FILE" "$IDX_END")"

CATALOG_BLOCK="$(extract_block "$CANON_FILE" "$CAT_START" "$CAT_END")"
INDEX_BLOCK="$(extract_block "$CANON_FILE" "$IDX_START" "$IDX_END")"
assert_eq "(E-1) カタログブロックを抽出できる（抽出失敗を pass にしない）" "true" \
  "$(if [ -n "$CATALOG_BLOCK" ]; then echo true; else echo false; fi)"
assert_eq "(E-1) 索引ブロックを抽出できる（抽出失敗を pass にしない）" "true" \
  "$(if [ -n "$INDEX_BLOCK" ]; then echo true; else echo false; fi)"

for marker in "$CAT_START" "$IDX_START"; do
  holders="$(grep -rlF -- "$marker" skills agents | sort | tr '\n' ' ')"
  assert_eq "(E-1) 実行時ファイルはブロックマーカーを持たない: ${marker}" "" "$(trim "$holders")"
done

echo ""
echo "=== (E-2) 「適用先」表から読み取れる／各ファイルに逐語コピーが在る ==="

# §5 の表の本文行だけを見る（マーカー列と適用先列を持つ行）。
APPLY_ROWS="$(awk '
  /^## 5\. / { insec = 1; next }
  insec && /^## / { exit }
  insec && /^\| / && !/^\| 定型文 / && !/^\|---/ { print }
' "$CANON_FILE")"
APPLY_COUNT="$(printf '%s\n' "$APPLY_ROWS" | grep -c '^|')"
assert_eq "(E-2) 適用先表から2行以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$APPLY_COUNT" -ge 2 ]; then echo true; else echo false; fi)"

DECLARED_TARGETS=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  marker_name="$(printf '%s' "$row" | awk -F'|' '{ print $3 }' | grep -o '`[^`]*`' | tr -d '`')"
  target="$(printf '%s' "$row" | awk -F'|' '{ print $4 }' | grep -o '`[^`]*`' | tr -d '`')"
  assert_eq "(E-2) 行からマーカー名と適用先を取り出せる: ${row}" "true" \
    "$(if [ -n "$marker_name" ] && [ -n "$target" ]; then echo true; else echo false; fi)"
  [ -n "$marker_name" ] && [ -n "$target" ] || continue
  DECLARED_TARGETS="${DECLARED_TARGETS}${target}"$'\n'

  if [ ! -r "$target" ]; then
    assert_eq "(E-2) 適用先が実在する: ${target}" "true" "false"
    continue
  fi
  block="$(extract_block "$CANON_FILE" "<!-- ${marker_name}:start -->" "<!-- ${marker_name}:end -->")"
  assert_eq "(E-2) マーカーからブロックを引ける: ${marker_name}" "true" \
    "$(if [ -n "$block" ]; then echo true; else echo false; fi)"
  [ -n "$block" ] || continue
  assert_eq "(E-2) 定型文が逐語で1回だけ存在する: ${target} <- ${marker_name}" "1" \
    "$(count_block "$target" "$block")"
  assert_file_contains "(E-2) コピー側が正本コメントを持つ: ${target}" "$target" "$CANON_MARKER"
done <<<"$APPLY_ROWS"

DECLARED_TARGETS="$(printf '%s' "$DECLARED_TARGETS" | grep '[^[:space:]]' | LC_ALL=C sort -u)"

echo ""
echo "=== (E-3) 表と実際のコピーの双方向一致（取りこぼし・誤コピーの両方を見る） ==="

ACTUAL_TARGETS="$(grep -rlF -- "$CANON_MARKER" skills agents)"
ACTUAL_RC=$?
assert_eq "(E-3) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$ACTUAL_RC" -le 1 ]; then echo true; else echo false; fi)"
ACTUAL_TARGETS="$(printf '%s\n' "$ACTUAL_TARGETS" | grep '[^[:space:]]' | LC_ALL=C sort -u)"
assert_eq "(E-3) 正本コメントを持つ実行時ファイルの集合が適用先表と一致する" \
  "$DECLARED_TARGETS" "$ACTUAL_TARGETS"

echo ""
echo "=== (E-4) 掃引の規律の不変コア（可変部を含まない一文まるごとで照合） ==="

dc_core() {
  local description="$1" phrase="$2"
  if printf '%s\n' "$CATALOG_BLOCK" | grep -qF -- "$phrase"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       phrase: ${phrase}"
  fi
}

dc_core "(E-4) 好意的解釈をしない（文字通りに従う実装をシミュレートする）" \
  '**文字通りに従う実装をシミュレートする。** 書き手の意図を補って読まない（好意的解釈をしない）'
dc_core "(E-4) 1クラスで差分の全体を掃引する（拾い読みの禁止）" \
  '**割り当てられた1クラスで、渡された差分の全体を掃引する。** そのクラスに該当しそうな箇所だけを拾い読みしない'
dc_core "(E-4) 実行して自己検証し、確証と未確証を区別する" \
  '**各件を実行して自己検証する。** 実際に走らせて再現できた指摘だけを「確証」とし、読んだだけの推測は「未確証」として明示的に区別する'
dc_core "(E-4) 検出0件でも掃引範囲を報告する（空虚な真の防止）" \
  '**検出が0件でも、掃引した対象範囲を必ず報告する。** 「検出なし」は掃引した範囲の上でしか主張できない'
dc_core "(E-4) 掃引できなかった対象を0件に丸めない" \
  '**掃引できなかった対象を「0件」に丸めない。** 読めなかった・実行できなかった対象は、掃引した対象とは別に列挙する'

echo ""
echo "=== (E-5) 索引とクラス定義の ID 集合・題名が一致する（語彙駆動） ==="

CATALOG_IDS="$(printf '%s\n' "$CATALOG_BLOCK" | sed -n 's/^### \(D-[0-9][0-9]\) \(.*\)$/\1\t\2/p')"
INDEX_IDS="$(printf '%s\n' "$INDEX_BLOCK" | sed -n 's/^| \(D-[0-9][0-9]\) | \(.*\) |$/\1\t\2/p')"
CATALOG_COUNT="$(printf '%s\n' "$CATALOG_IDS" | grep -c '[^[:space:]]')"
INDEX_COUNT="$(printf '%s\n' "$INDEX_IDS" | grep -c '[^[:space:]]')"

assert_eq "(E-5) カタログからクラスを1件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$CATALOG_COUNT" -ge 1 ]; then echo true; else echo false; fi)"
assert_eq "(E-5) 索引からクラスを1件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$INDEX_COUNT" -ge 1 ]; then echo true; else echo false; fi)"
assert_eq "(E-5) 索引とカタログの ID・題名が完全に一致する" "$CATALOG_IDS" "$INDEX_IDS"

DUP_IDS="$(printf '%s\n' "$CATALOG_IDS" | cut -f1 | LC_ALL=C sort | uniq -d | tr '\n' ' ')"
assert_eq "(E-5) クラス ID が重複していない" "" "$(trim "$DUP_IDS")"

# 掃引エージェント側でも、全クラスの見出しが逐語で存在する（(E-2) の逐語一致の裏取り。
# クラスを足したときに、エージェント側の更新漏れが ID 単位で見える）。
while IFS=$'\t' read -r cid ctitle; do
  [ -z "$cid" ] && continue
  assert_file_contains "(E-5) 掃引エージェントがクラス定義を持つ: ${cid}" \
    "agents/defect-sweeper.md" "### ${cid} ${ctitle}"
  assert_file_contains "(E-5) オーケストレータが索引にクラスを持つ: ${cid}" \
    "$SWEEP_REF" "| ${cid} | ${ctitle} |"
done <<<"$CATALOG_IDS"

echo ""
echo "=== (E-6) 反転語彙が実行時テキストに無い（掃引の網羅性の主張を空虚にする読み替え） ==="

INVERTED=(
  '検出が0件のクラスは省略'
  '検出なしのクラスは報告しない'
  '掃引できなかった対象は0件として扱う'
  '未確証の指摘は報告しない'
  '掃引モードは前方一致で判定する'
)
for phrase in "${INVERTED[@]}"; do
  hits="$(grep -rlF -- "$phrase" skills agents | LC_ALL=C sort | tr '\n' ' ')"
  assert_eq "(E-6) 反転語彙が実行時テキストに無い: ${phrase}" "" "$(trim "$hits")"
done

echo ""
echo "=== (E-7) sweepOutcome 真理値表の完全性と参照実装との一致 ==="

OUTCOME_BLOCK="$(extract_block "$SWEEP_REF" '<!-- sweep-outcome-canon:start -->' '<!-- sweep-outcome-canon:end -->')"
assert_eq "(E-7) 真理値表ブロックを抽出できる（抽出失敗を pass にしない）" "true" \
  "$(if [ -n "$OUTCOME_BLOCK" ]; then echo true; else echo false; fi)"

TABLE_ROWS="$(printf '%s\n' "$OUTCOME_BLOCK" \
  | grep '^|' \
  | grep -vF -- '---' \
  | grep -vF -- '`sweepOutcome` |')"
ROW_COUNT="$(printf '%s\n' "$TABLE_ROWS" | grep -c '^|')"
assert_eq "(E-7) 真理値表の本文行を取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$ROW_COUNT" -ge 1 ]; then echo true; else echo false; fi)"

COMBOS=""
TABLE_MISMATCH=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  IFS='|' read -r _ c_resp c_scope c_find c_out _rest <<<"$row"
  c_resp="$(trim "$c_resp")"; c_scope="$(trim "$c_scope")"
  c_find="$(trim "$c_find")"; c_out="$(trim "$c_out")"

  resp_vals="$c_resp"; scope_vals="$c_scope"; find_vals="$c_find"
  [ "$c_resp" = "（問わない）" ] && resp_vals="あり なし"
  [ "$c_scope" = "（問わない）" ] && scope_vals="あり なし"
  [ "$c_find" = "（問わない）" ] && find_vals="あり なし"

  for resp in $resp_vals; do
    for scope in $scope_vals; do
      for find in $find_vals; do
        # 参照実装: 構造化応答を受領していない、または掃引した対象が空なら掃引は成立していない。
        # 成立していれば、指摘の有無で found / none に分かれる。
        if [ "$resp" = "なし" ] || [ "$scope" = "なし" ]; then
          expected='`not_sweepable`'
        elif [ "$find" = "あり" ]; then
          expected='`found`'
        else
          expected='`none`'
        fi
        if [ "$c_out" != "$expected" ]; then
          TABLE_MISMATCH="${TABLE_MISMATCH}[resp=${resp} scope=${scope} find=${find}] table=${c_out} ref=${expected} "
        fi
        COMBOS="${COMBOS}$(yn "$resp")$(yn "$scope")$(yn "$find")"$'\n'
      done
    done
  done
done <<<"$TABLE_ROWS"

assert_eq "(E-7) 表の各行の sweepOutcome が参照実装と一致する" "" "$TABLE_MISMATCH"
COMBO_TOTAL="$(printf '%s' "$COMBOS" | grep -c '[^[:space:]]')"
COMBO_UNIQUE="$(printf '%s' "$COMBOS" | grep '[^[:space:]]' | LC_ALL=C sort -u | wc -l | tr -d ' ')"
UNMAPPED="$(printf '%s' "$COMBOS" | grep -c '?')"
assert_eq "(E-7) 表の欄が あり/なし/（問わない） 以外の語を含まない" "0" "$UNMAPPED"
assert_eq "(E-7) 3入力の全8組合せを網羅している" "8" "$COMBO_UNIQUE"
assert_eq "(E-7) 同じ組合せを2回書いていない（重複行が無い）" "8" "$COMBO_TOTAL"

echo ""
echo "=== (E-8) 既存の軽い使い方が壊れていない（引数なし＝標準モード） ==="

assert_file_contains "(E-8) 引数が空なら標準モードであると明記している" "$SELF_REVIEW" \
  '**引数が空の場合は標準モードである。** 既存の `/self-review`（引数なし）の振る舞いは掃引モードの追加によって変わらない'
assert_file_contains "(E-8) 掃引モードへは完全一致でしか入らない" "$SELF_REVIEW" \
  '**モードの判定は `sweep` の完全一致だけで行う。** 前方一致・部分一致・大文字小文字の揺れ・語を含むかどうかで掃引モードへ入らない'
assert_file_contains "(E-8) 未知の引数を黙って標準モードで走らせない" "$SELF_REVIEW" \
  '**入力を標準モードとして解釈した旨を報告の冒頭に明示する**'
assert_file_contains "(E-8) 標準モードの手順が残っている（Step 1〜7）" "$SELF_REVIEW" \
  '## 標準モードの手順'
for step in '### Step 1: diff収集' '### Step 2: 並列レビュー' '### Step 4: 修正 → 反復' '### Step 6: 結果の報告'; do
  assert_file_contains "(E-8) 標準モードの節が残っている: ${step}" "$SELF_REVIEW" "$step"
done

echo ""
echo "=== (E-9) 掃引モードの接続先が実在する／severity 語彙の第2リストが無い ==="

assert_file_contains "(E-9) SKILL.md が掃引モードの参照ファイルを配送経路で指している" "$SELF_REVIEW" \
  'claude-harness-run read-plugin-doc "skills/self-review/references/defect-sweep.md"'
assert_file_contains "(E-9) オーケストレータが掃引エージェントを名前空間つきで呼ぶ" "$SWEEP_REF" \
  "subagent_type: 'claude-harness:defect-sweeper'"
assert_file_contains "(E-9) オーケストレータが finding-verifier を再利用する" "$SWEEP_REF" \
  "subagent_type: 'claude-harness:finding-verifier'"
assert_file_contains "(E-9) 掃引エージェントの定義が存在する（name）" "agents/defect-sweeper.md" \
  'name: defect-sweeper'
assert_file_contains "(E-9) 掃引エージェントが編集系ツールを持たない（tools 行）" "agents/defect-sweeper.md" \
  'tools: Read, Glob, Grep, Bash'
assert_file_contains "(E-9) 報告契約: カバレッジ表は全クラス分の行を持つ" "$SWEEP_REF" \
  '**行数はカタログのクラス数と一致する。**'
assert_file_contains "(E-9) 報告契約: 指摘が空でもカバレッジ表を出す" "$SWEEP_REF" \
  'ただし下の掃引カバレッジ表は**必ず出す**'
assert_file_contains "(E-9) 受領検査: クラス数と一致しなければ停止する" "$SWEEP_REF" \
  '**カタログのクラス数と要素数が一致しない場合は、報告を出さずに欠落したクラスを明示して停止する**'
assert_file_contains "(E-9) 掃引側に severity を付けさせない（しきい値の正本を1つに保つ）" "$SWEEP_REF" \
  '**`severity` を返させない**'
assert_file_contains "(E-9) 掃引エージェント側にも severity を付けない規律が在る" "agents/defect-sweeper.md" \
  '**`severity` を付けない。**'

# severity の値の literal が掃引モード側に現れたら、それが2つ目のしきい値になる。
for sev in '`high`' '`medium`' '`low`' '"high"' '"medium"' '"low"'; do
  for f in "$SWEEP_REF" "agents/defect-sweeper.md"; do
    found="false"
    grep -qF -- "$sev" "$f" && found="true"
    assert_eq "(E-9) severity の値が掃引モード側に無い: ${f} ${sev}" "false" "$found"
  done
done

echo ""
echo "=== (E-10) 「適用しない範囲」に挙げたファイルは定型文を持たない ==="

EXCLUDED_TARGETS="$(awk '
  /^## 6\. / { insec = 1; next }
  insec && /^## / { exit }
  insec && /^\| / { print }
' "$CANON_FILE" | awk -F'|' '{ print $2 }' | grep -o '`[^`]*`' | tr -d '`' | grep -E '\.md$' | LC_ALL=C sort -u)"
EXCLUDED_COUNT="$(printf '%s\n' "$EXCLUDED_TARGETS" | grep -c '[^[:space:]]')"
assert_eq "(E-10) 例外表からファイルを3件以上取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$EXCLUDED_COUNT" -ge 3 ]; then echo true; else echo false; fi)"

while IFS= read -r excluded; do
  [ -z "$excluded" ] && continue
  assert_eq "(E-10) 例外に挙げたファイルが実在する: ${excluded}" "true" \
    "$(if [ -r "$excluded" ]; then echo true; else echo false; fi)"
  [ -r "$excluded" ] || continue
  assert_eq "(E-10) 例外に挙げたファイルはカタログを持たない: ${excluded}" "0" \
    "$(count_block "$excluded" "$CATALOG_BLOCK")"
done <<<"$EXCLUDED_TARGETS"

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
