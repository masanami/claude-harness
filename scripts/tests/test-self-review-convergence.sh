#!/bin/bash
# test-self-review-convergence.sh
#
# `/self-review` の収束条件（`skills/self-review/SKILL.md` の `convergence-canon` ブロック）の
# 構造不変条件テスト。
#
# 収束条件そのもの（「モデルが実行時にこの規律を守るか」）は決定的スクリプトでは検査できない。
# 本テストが固定するのは**規約が成立するための構造**である:
#   (C-0) ブロック抽出器の自己検査（抽出器が壊れていたら以降の照合は無意味）
#   (C-1) 正本ブロックが `skills/self-review/SKILL.md` に**ちょうど1つ**在り、抽出できる
#         （抽出失敗を pass にしない）。他の実行時ファイルは正本ブロックを持たない
#   (C-2) 正本の不変コア（severity の順序／fail-closed の既定／検証しきい値／修正しきい値／
#         しきい値未満は自動修正しない／`converged: true` でも残指摘は残りうる）。可変部を
#         含まない**一文まるごと**で照合する（部分一致は意味を反転しても通るため）
#   (C-3) **severity 語彙の第2リストの不在**。しきい値は「`medium` 以上」という1点で決まるが、
#         これを複数箇所に列挙すると必ずずれる。severity の値（`high`/`medium`/`low`）の
#         literal が正本ブロックの**外**に現れないことを機械で止める
#   (C-4) **真理値表の完全性と参照実装との一致**。表の3入力の全8組合せが重複なく1回ずつ現れ、
#         各行の `converged` が参照実装（`quality-check` 失敗が無く、かつ修正しきい値以上の
#         残指摘が無いときだけ `true`）と一致する。散文と表がずれることを止める
#   (C-5) **旧収束条件の語彙の不在**（掃引の網羅性）。「指摘がゼロになるまで」を前提にした
#         記述が `skills/` `agents/` のどこにも残っていないことを機械で示す
#   (C-6) **消費側への到達性の双方向一致**。`residualFindings` を消費する実行時ファイルが
#         「`converged` の値に関わらず全件を転記する」を規定していること／`residualFindings`
#         を持つ実行時ファイルの集合が下記の登録表と一致すること（新しい消費側が登録されずに
#         増えると、そこだけ残指摘を落とす）
#
# 消費側の登録表（新しい消費側を足すときは、この表と CONSUMERS 配列の両方に追加する）:
#
#   | ファイル | 役割 |
#   |---|---|
#   | `agents/feature-implementer.md` | `/self-review` の呼び出し元。残指摘を返却内容へ転記する |
#   | `skills/para-impl/SKILL.md`     | 返却を受け取り、PR 本文へ転記する |
#   | `agents/ticket-worker.md`       | 並列実装の worker。返却をリードへ転記する |
#
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。比較は bash の文字列比較と grep -F で行う。
# 同じ理由で **`sort -u` に非 ASCII の行を渡さない**（macOS 標準 sort はロケール次第で
# 相異なる日本語行を等価と判定し、重複除去が全行を1行へ潰す）。(C-4) の組合せキーは
# `あり`/`なし` を `1`/`0` へ写して ASCII だけで持つ。
#
# 実行方法: bash scripts/tests/test-self-review-convergence.sh

set -u

SRC_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SRC_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CANON_FILE="skills/self-review/SKILL.md"
CONSUMERS=(
  "agents/feature-implementer.md"
  "skills/para-impl/SKILL.md"
  "agents/ticket-worker.md"
)

BLOCK_START='<!-- convergence-canon:start -->'
BLOCK_END='<!-- convergence-canon:end -->'

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

# extract_block: 開始マーカーと終了マーカーに挟まれた行（マーカー行を除く）を出力する。
extract_block() {
  local file="$1" start="$2" end="$3"
  awk -v s="$start" -v e="$end" '
    index($0, s) == 1 { inb = 1; next }
    index($0, e) == 1 { inb = 0; next }
    inb { print }
  ' "$file"
}

# count_marker: 固定文字列で始まる行の本数を数える。
count_marker() {
  local file="$1" marker="$2"
  grep -cF -- "$marker" "$file"
}

# yn: `あり`/`なし` を ASCII の `1`/`0` へ写す（それ以外は `?`。取りこぼしを黙って通さない）。
yn() {
  case "$1" in
    "あり") printf '1' ;;
    "なし") printf '0' ;;
    *) printf '?' ;;
  esac
}

# trim: 前後の空白を落とす。
trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

echo "=== (C-0) extract_block の自己検査（検出器が壊れていたら以降の照合は無意味） ==="

SRC_TMP="$(mktemp -d)"
trap 'rm -rf "$SRC_TMP"' EXIT
printf 'before\n%s\ninside-1\ninside-2\n%s\nafter\n' "$BLOCK_START" "$BLOCK_END" > "${SRC_TMP}/fixture.md"
assert_eq "(C-0) マーカー間の行だけを抽出する" "$(printf 'inside-1\ninside-2')" \
  "$(extract_block "${SRC_TMP}/fixture.md" "$BLOCK_START" "$BLOCK_END")"
printf 'before\nafter\n' > "${SRC_TMP}/nomarker.md"
assert_eq "(C-0) マーカーが無ければ空を返す（空を pass にしない根拠）" "" \
  "$(extract_block "${SRC_TMP}/nomarker.md" "$BLOCK_START" "$BLOCK_END")"
assert_eq "(C-0) 開始マーカーを1本と数える" "1" \
  "$(count_marker "${SRC_TMP}/fixture.md" "$BLOCK_START")"

echo ""
echo "=== (C-1) 正本ブロックがちょうど1つ在り、抽出できる ==="

assert_eq "(C-1) 正本ファイルを読める（読めない状態を pass にしない）" "true" \
  "$(if [ -r "$CANON_FILE" ]; then echo true; else echo false; fi)"

assert_eq "(C-1) 開始マーカーが正本にちょうど1本" "1" "$(count_marker "$CANON_FILE" "$BLOCK_START")"
assert_eq "(C-1) 終了マーカーが正本にちょうど1本" "1" "$(count_marker "$CANON_FILE" "$BLOCK_END")"

CANON_BLOCK="$(extract_block "$CANON_FILE" "$BLOCK_START" "$BLOCK_END")"
assert_eq "(C-1) 正本ブロックを抽出できる（抽出失敗を pass にしない）" "true" \
  "$(if [ -n "$CANON_BLOCK" ]; then echo true; else echo false; fi)"

OTHER_HOLDERS="$(grep -rlF -- "$BLOCK_START" skills agents | grep -vxF "$CANON_FILE" | sort)"
assert_eq "(C-1) 正本ブロックを持つ実行時ファイルは正本1つだけ" "" "$OTHER_HOLDERS"

echo ""
echo "=== (C-2) 正本の不変コア（可変部を含まない一文まるごとで照合） ==="

src_core() {
  local description="$1" phrase="$2"
  if printf '%s\n' "$CANON_BLOCK" | grep -qF -- "$phrase"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       phrase: ${phrase}"
  fi
}

src_core "(C-2) severity を書く箇所が正本だけであると宣言している" \
  '本スキル内で severity の値を書く箇所はここだけ'
src_core "(C-2) severity の順序を定義している" \
  '**順序**: `high` > `medium` > `low`'
src_core "(C-2) 未知・欠落の severity を fail-closed で最も重い側へ倒す" \
  'すべて `high` として扱う'
src_core "(C-2) 検証しきい値を定義している" \
  '**検証しきい値** = `high`'
src_core "(C-2) 修正しきい値を定義している" \
  '**修正しきい値** = `medium` 以上'
src_core "(C-2) しきい値未満は自動修正しないと定義している" \
  '**修正しきい値未満の指摘は自動修正しない**'
src_core "(C-2) しきい値未満の残指摘は converged を false にしない" \
  '`converged` を `false` にしない'
src_core "(C-2) しきい値未満の解消をループの終了条件にしない" \
  '**これらの解消をループの終了条件にしない**'
src_core "(C-2) converged: true が残指摘ゼロを意味しないと明示している" \
  '**`converged: true` は「残指摘が無い」を意味しない**'
src_core "(C-2) 報告を converged で分岐させないと明示している" \
  '`converged` の値に関わらず、`residualFindings` は Step 6 で必ず全件報告する'

echo ""
echo "=== (C-3) severity 語彙の第2リストの不在（正本ブロックの外に severity の値が無い） ==="

# 正本ブロックを取り除いた残りを作る。ここに severity の値が現れたら、それが2つ目のリストになる。
CANON_OUTSIDE="$(awk -v s="$BLOCK_START" -v e="$BLOCK_END" '
  index($0, s) == 1 { inb = 1; next }
  index($0, e) == 1 { inb = 0; next }
  !inb { print }
' "$CANON_FILE")"

assert_eq "(C-3) 正本ブロック外の本文を取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ -n "$CANON_OUTSIDE" ]; then echo true; else echo false; fi)"

for sev in '`high`' '`medium`' '`low`' '"high"' '"medium"' '"low"'; do
  found="false"
  printf '%s\n' "$CANON_OUTSIDE" | grep -qF -- "$sev" && found="true"
  assert_eq "(C-3) 正本ブロックの外に severity の値が無い: ${sev}" "false" "$found"
done

# 逆側: 正本ブロックの中には3値すべてが在る（片方向だけの検査にしない）
for sev in '`high`' '`medium`' '`low`'; do
  found="false"
  printf '%s\n' "$CANON_BLOCK" | grep -qF -- "$sev" && found="true"
  assert_eq "(C-3) 正本ブロックの中に severity の値が在る: ${sev}" "true" "$found"
done

echo ""
echo "=== (C-4) 真理値表の完全性と参照実装との一致 ==="

# 正本ブロックから真理値表の本文行だけを取り出す（ヘッダ行・区切り行を除く）。
TABLE_ROWS="$(printf '%s\n' "$CANON_BLOCK" \
  | grep '^|' \
  | grep -vF -- '---' \
  | grep -vF -- '`converged` |')"

ROW_COUNT="$(printf '%s\n' "$TABLE_ROWS" | grep -c '^|')"
assert_eq "(C-4) 真理値表の本文行を取り出せる（取り出し失敗を pass にしない）" "true" \
  "$(if [ "$ROW_COUNT" -ge 1 ]; then echo true; else echo false; fi)"

COMBOS=""
TABLE_MISMATCH=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  IFS='|' read -r _ c_qc c_above c_below c_conv _rest <<<"$row"
  c_qc="$(trim "$c_qc")"; c_above="$(trim "$c_above")"
  c_below="$(trim "$c_below")"; c_conv="$(trim "$c_conv")"

  # `（問わない）` はその欄が両方の値を取りうることを表す → 展開する
  qc_vals="$c_qc"; above_vals="$c_above"; below_vals="$c_below"
  [ "$c_qc" = "（問わない）" ] && qc_vals="あり なし"
  [ "$c_above" = "（問わない）" ] && above_vals="あり なし"
  [ "$c_below" = "（問わない）" ] && below_vals="あり なし"

  for qc in $qc_vals; do
    for above in $above_vals; do
      for below in $below_vals; do
        # 参照実装: quality-check 失敗が無く、かつ修正しきい値以上の残指摘が無いときだけ true
        if [ "$qc" = "なし" ] && [ "$above" = "なし" ]; then
          expected='`true`'
        else
          expected='`false`'
        fi
        if [ "$c_conv" != "$expected" ]; then
          TABLE_MISMATCH="${TABLE_MISMATCH}[qc=${qc} above=${above} below=${below}] table=${c_conv} ref=${expected} "
        fi
        # 組合せキーは ASCII だけで持つ（非 ASCII を sort -u に渡さないため）
        COMBOS="${COMBOS}$(yn "$qc")$(yn "$above")$(yn "$below")"$'\n'
      done
    done
  done
done <<<"$TABLE_ROWS"

assert_eq "(C-4) 表の各行の converged が参照実装と一致する" "" "$TABLE_MISMATCH"

COMBO_TOTAL="$(printf '%s' "$COMBOS" | grep -c '[^[:space:]]')"
COMBO_UNIQUE="$(printf '%s' "$COMBOS" | grep '[^[:space:]]' | sort -u | wc -l | tr -d ' ')"
UNMAPPED="$(printf '%s' "$COMBOS" | grep -c '?')"
assert_eq "(C-4) 表の欄が あり/なし/（問わない） 以外の語を含まない" "0" "$UNMAPPED"
assert_eq "(C-4) 3入力の全8組合せを網羅している" "8" "$COMBO_UNIQUE"
assert_eq "(C-4) 同じ組合せを2回書いていない（重複行が無い）" "8" "$COMBO_TOTAL"

echo ""
echo "=== (C-5) 旧収束条件の語彙が実行時テキストに残っていない（掃引の網羅性） ==="

# 「指摘がゼロになるまで」を前提にした旧記述。1つでも残っていれば、そこだけ旧規約で動く。
OBSOLETE=(
  'findings.length === 0'
  '指摘が0件になった時点'
  '収束（残指摘なし）'
  '残指摘の有無'
  '残指摘（収束しなかった場合）'
  '`toFix` = `trusted` ∪'
  '`severity: "medium"`/`"low"` の指摘'
  '`converged: false` の場合、`residualFindings` を上記の表で提示'
)
for phrase in "${OBSOLETE[@]}"; do
  hits="$(grep -rlF -- "$phrase" skills agents | sort | tr '\n' ' ')"
  assert_eq "(C-5) 旧語彙が実行時テキストに無い: ${phrase}" "" "$(trim "$hits")"
done

echo ""
echo "=== (C-6) 消費側への到達性（登録表と実ファイルの双方向一致） ==="

for consumer in "${CONSUMERS[@]}"; do
  assert_eq "(C-6) 登録した消費側が実在する: ${consumer}" "true" \
    "$(if [ -r "$consumer" ]; then echo true; else echo false; fi)"
  [ -r "$consumer" ] || continue
  assert_file_contains "(C-6) 消費側が residualFindings を名前で受け取る: ${consumer}" \
    "$consumer" '`residualFindings`'
  assert_file_contains "(C-6) 消費側が全件の転記を規定している: ${consumer}" \
    "$consumer" '全件'
done

# 消費側ごとの「converged で分岐しない」規定（受け渡しが converged 依存に戻る退行を止める）
assert_file_contains "(C-6) 呼び出し元が converged で分岐しないと明記している" \
  "agents/feature-implementer.md" '**残指摘の受け取りは `converged` の値で分岐させない。**'
assert_file_contains "(C-6) PR 本文への転記が converged: true でも省略されない" \
  "skills/para-impl/SKILL.md" '`converged: true` でも省略しない'
assert_file_contains "(C-6) worker の転記が converged で分岐しない" \
  "agents/ticket-worker.md" '`converged` で分岐せず空でなければ全件転記する'

# 双方向: residualFindings を持つ実行時ファイルの集合 == 正本 + 登録した消費側
EXPECTED_HOLDERS="$(printf '%s\n' "$CANON_FILE" "${CONSUMERS[@]}" | sort -u)"
ACTUAL_HOLDERS="$(grep -rlF -- 'residualFindings' skills agents | sort -u)"
assert_eq "(C-6) residualFindings を持つ実行時ファイルの集合が登録表と一致する" \
  "$EXPECTED_HOLDERS" "$ACTUAL_HOLDERS"

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
