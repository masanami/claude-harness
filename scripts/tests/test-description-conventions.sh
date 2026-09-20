#!/bin/bash
# test-description-conventions.sh
# `description`（skills / agents の frontmatter）の基準（`docs/description-conventions.md`）の
# 構造不変条件テスト。
#
# この面の失敗は**沈黙する**: `description` から起動トリガー語を削ると、そのスキル／
# エージェントは「エラーにならずに、ただ起動されなくなる」。したがって機械で固定するのは
# 「基準に沿って書けているか」（文の意味に依存するため決定的スクリプトでは検査できない。
# 境界は正本 §6）ではなく、**起動が止まる変更が黙って通らないための構造**である:
#   (D-0) 検出器（値の抽出・トークン分割・構造検査）の自己検査。壊れた検出器で以降の
#         照合を pass にしない。正例と反例の両方を通す
#   (D-1) 正本が在り、判定軸を `docs/plugin-path-conventions.md` (h) から**逐語で**引いて
#         いること。および (h) 側から下位規定への**ポインタ**が在ること（双方向）。
#         判定軸が2箇所に別々の言葉で書かれる状態を機械で止める
#   (D-2) 3要素の構造 — ② `Triggers on:` がちょうど1つ在り、値の**末尾**に置かれ、
#         トークンが1件以上ある。①＋③が2文までである（分量の上限ではなく正規化の機械化。
#         理由は正本 §3）
#   (D-3) `Triggers on:` のスラッシュ語が**実在するスキル**を指していること。実在しない
#         ものは台帳の「別名」列で宣言されていること（リネームで起動が止まる事故の検出）
#   (D-4) 台帳と現物の一致。起動トリガー列は**双方向**（減らす変更も増やす変更も台帳の
#         編集を伴う）。保持語列は片方向（台帳外の語が在ること自体は欠陥ではない。
#         理由は正本 §5）。行の集合は `skills/` のディレクトリ名・`agents/` のファイル名
#         から**導出**した集合と完全一致（検査器に手書きの対象リストを持たせない）
#
# 逐語照合の文字列は**正本から抜き出して**使い、テストに基準文の literal を置かない
# （置くと正本を変えてもテストだけが古い値で通り続ける＝2本目のリストになる）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。比較は bash の文字列比較と grep -F で行い、awk は
# フィールド分割と行番号の算出に留める。
#
# 実行方法: bash scripts/tests/test-description-conventions.sh

set -u

DESC_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DESC_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CANON_DOC="${REPO_ROOT}/docs/description-conventions.md"
PARENT_DOC="${REPO_ROOT}/docs/plugin-path-conventions.md"

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
  if [ -n "$phrase" ] && grep -qF -- "$phrase" "$file"; then
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

# ---- 検出器（以降の全照合がこの3つに乗る） ----

# frontmatter の description の値を取り出す（YAML のクォートを剥がす）。
desc_value() {
  local f="$1" v
  v="$(sed -n 's/^description:[ ]*//p' "$f" | head -1)"
  case "$v" in '"'*'"') v="${v#\"}"; v="${v%\"}" ;; esac
  printf '%s' "$v"
}

# `Triggers on:` 以降の '...' トークンを1行1件で出す。
desc_triggers() {
  local v="$1" seg
  case "$v" in
    *"Triggers on: "*) seg="${v#*Triggers on: }" ;;
    *) return 0 ;;
  esac
  printf '%s' "$seg" | grep -o "'[^']*'" | sed "s/^'//; s/'\$//"
}

# 構造上の欠陥を1行1件で出す（欠陥が無ければ何も出さない）。
desc_struct_errors() {
  local v="$1" n_marker n_tok pre n_sentence
  n_marker="$(printf '%s' "$v" | grep -oF 'Triggers on: ' | grep -c .)"
  if [ "$n_marker" != "1" ]; then
    printf '%s\n' "Triggers on: の出現が1回ではない(${n_marker})"
    return 0
  fi
  case "$v" in *"'") ;; *) printf '%s\n' "値が起動トリガーで終わっていない（②は末尾に置く）" ;; esac
  n_tok="$(desc_triggers "$v" | grep -c '[^[:space:]]')"
  [ "$n_tok" -ge 1 ] || printf '%s\n' "起動トリガーのトークンが0件"
  desc_triggers "$v" | grep -c '^$' | grep -qx 0 || printf '%s\n' "空のトリガートークンが在る"
  pre="${v%%Triggers on: *}"
  printf '%s' "$pre" | grep -q '[^[:space:]]' || printf '%s\n' "①（何をするか）が空"
  n_sentence="$(printf '%s' "$pre" | grep -oF '。' | grep -c .)"
  if [ "$n_sentence" -lt 1 ] || [ "$n_sentence" -gt 2 ]; then
    printf '%s\n' "①＋③の文数が1〜2でない(${n_sentence})"
  fi
}

echo "=== (D-0) 検出器の自己検査（壊れた検出器で以降の照合を pass にしない） ==="

DESC_TMP="$(mktemp -d)"
trap 'rm -rf "$DESC_TMP"' EXIT

printf -- '---\nname: sample\ndescription: "何かをする。使わない条件。Triggers on: '"'"'/sample'"'"', '"'"'やって'"'"'"\nmodel: sonnet\n---\n' > "${DESC_TMP}/good.md"
assert_eq "(D-0) 値を取り出せる（クォートを剥がす）" \
  "何かをする。使わない条件。Triggers on: '/sample', 'やって'" "$(desc_value "${DESC_TMP}/good.md")"
assert_eq "(D-0) トリガーを2件に分割できる" "/sample
やって" "$(desc_triggers "$(desc_value "${DESC_TMP}/good.md")")"
assert_eq "(D-0) 正例に構造欠陥を出さない" "" "$(desc_struct_errors "$(desc_value "${DESC_TMP}/good.md")")"

# 反例（検出できなければ、以降の pass は「検査していない」ことの言い換えになる）
assert_eq "(D-0) 反例: Triggers on: が無いものを検出する" "true" \
  "$(if [ -n "$(desc_struct_errors 'ただの説明文。')" ]; then echo true; else echo false; fi)"
assert_eq "(D-0) 反例: 起動トリガーが末尾でないものを検出する" "true" \
  "$(if [ -n "$(desc_struct_errors "何かをする。Triggers on: '/x' なお補足もある。")" ]; then echo true; else echo false; fi)"
assert_eq "(D-0) 反例: ①＋③が3文以上のものを検出する" "true" \
  "$(if [ -n "$(desc_struct_errors "一文目。二文目。三文目。Triggers on: '/x'")" ]; then echo true; else echo false; fi)"
assert_eq "(D-0) 反例: トークンが0件のものを検出する" "true" \
  "$(if [ -n "$(desc_struct_errors '何かをする。Triggers on: なし')" ]; then echo true; else echo false; fi)"

# ---- 対象集合の導出（手書きの対象リストを持たない） ----
DERIVED="$(
  for d in skills/*/; do
    [ -f "${d}SKILL.md" ] && printf 'skill\t%s\n' "$(basename "$d")"
  done
  for f in agents/*.md; do
    [ -f "$f" ] && printf 'agent\t%s\n' "$(basename "$f" .md)"
  done
)"
DERIVED="$(printf '%s\n' "$DERIVED" | grep '[^[:space:]]' | sort)"
DERIVED_COUNT="$(printf '%s\n' "$DERIVED" | grep -c '[^[:space:]]')"

assert_eq "(D-0) 対象を導出できる（導出0件を pass にしない）" "true" \
  "$(if [ "$DERIVED_COUNT" -ge 2 ]; then echo true; else echo false; fi)"

# 面の名前とファイル配置の対応（リネーム時に台帳と現物が同時にずれるのを防ぐ）
surface_path() {
  case "$1" in
    skill) printf 'skills/%s/SKILL.md' "$2" ;;
    agent) printf 'agents/%s.md' "$2" ;;
  esac
}

echo ""
echo "=== (D-1) 正本が在り、判定軸を (h) から逐語で引いている（双方向） ==="

for f in "$CANON_DOC" "$PARENT_DOC"; do
  assert_eq "(D-1) 検査対象を読める（読めない状態を pass にしない）: $(basename "$f")" \
    "true" "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

# 判定軸の一文は (h) から抜き出す（テスト側の literal に掛けない）。
CRITERION_LINE="$(grep -m1 -- '^> \*\*判定軸\*\*: ' "$PARENT_DOC")"
assert_eq "(D-1) (h) から判定軸の一文を抜き出せる（抽出失敗を pass にしない）" "true" \
  "$(if [ -n "$CRITERION_LINE" ]; then echo true; else echo false; fi)"
assert_file_contains "(D-1) 正本が判定軸を (h) から逐語で引いている" "$CANON_DOC" "$CRITERION_LINE"

# (h) → 下位規定のポインタ。パスはテストに literal を置かず、正本のファイル名から作る。
CANON_DOC_REL="docs/$(basename "$CANON_DOC")"
assert_file_contains "(D-1) (h) 側に下位規定へのポインタが在る" "$PARENT_DOC" "$CANON_DOC_REL"
assert_file_contains "(D-1) 正本が親規約の所在を示している" "$CANON_DOC" \
  "docs/$(basename "$PARENT_DOC")"

# 実行時テキストは本文書を参照しない（(f)）。参照すると headless で読めない経路に規約が乗る。
REF_IN_RUNTIME="$(grep -rlF -- "$CANON_DOC_REL" skills agents 2>/dev/null | grep -c '[^[:space:]]')"
assert_eq "(D-1) 実行時テキスト（skills / agents）が本文書を参照していない" "0" "$REF_IN_RUNTIME"

echo ""
echo "=== (D-2) 3要素の構造（②の存在と位置・①＋③の文数） ==="

while IFS=$'\t' read -r surface name; do
  [ -z "${surface:-}" ] && continue
  path="$(surface_path "$surface" "$name")"
  if [ ! -r "${REPO_ROOT}/${path}" ]; then
    assert_eq "(D-2) 面のファイルが実在する: ${path}" "true" "false"
    continue
  fi
  # frontmatter の name が配置と一致していること（片方だけのリネームを止める）
  fm_name="$(sed -n 's/^name:[ ]*//p' "${REPO_ROOT}/${path}" | head -1 | tr -d '"'"'"' ')"
  assert_eq "(D-2) frontmatter の name が配置と一致する: ${path}" "$name" "$fm_name"
  assert_eq "(D-2) description がちょうど1行: ${path}" "1" \
    "$(grep -c '^description:' "${REPO_ROOT}/${path}")"
  val="$(desc_value "${REPO_ROOT}/${path}")"
  assert_eq "(D-2) 構造欠陥が無い: ${path}" "" "$(desc_struct_errors "$val")"
done <<<"$DERIVED"

echo ""
echo "=== (D-3) スラッシュ語が実在するスキルを指している（別名は台帳で宣言） ==="

# 台帳の行（面・名前・起動トリガー・保持語・別名）
LEDGER_ROWS="$(grep -E '^\| (skill|agent) \|' "$CANON_DOC")"
LEDGER_COUNT="$(printf '%s\n' "$LEDGER_ROWS" | grep -c '[^[:space:]]')"
assert_eq "(D-3) 台帳から行を取り出せる（抽出失敗を pass にしない）" "true" \
  "$(if [ "$LEDGER_COUNT" -ge 2 ]; then echo true; else echo false; fi)"

# セルの前後の空白を落とす。BSD sed の**ブラケット式では `\t` がタブとして解釈されない**
# （`[ \t]` は空白・バックスラッシュ・文字 `t` のいずれかに一致し、`commit` が `commi` に、
# `agent` が `agen` になる）。トリムは awk の正規表現で行う。
ledger_cell() { # row column_index -> セル
  printf '%s\n' "$1" | awk -F'|' -v c="$2" '{
    s = $c; gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); print s
  }'
}
ledger_items() { # セル -> バッククォート内の項目を1行1件（「—」は空）
  printf '%s' "$1" | grep -o '`[^`]*`' | tr -d '`'
}

DECLARED_ALIASES="$(
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    ledger_items "$(ledger_cell "$row" 6)"
  done <<<"$LEDGER_ROWS" | sort -u
)"

# 宣言した別名が実在スキルなら、その宣言は不要（宣言の腐りを止める）
while IFS= read -r alias; do
  [ -z "$alias" ] && continue
  assert_eq "(D-3) 別名の宣言が実在スキルと重複していない: ${alias}" "false" \
    "$(if [ -d "${REPO_ROOT}/skills/${alias#/}" ]; then echo true; else echo false; fi)"
done <<<"$DECLARED_ALIASES"

while IFS=$'\t' read -r surface name; do
  [ -z "${surface:-}" ] && continue
  path="$(surface_path "$surface" "$name")"
  [ -r "${REPO_ROOT}/${path}" ] || continue
  val="$(desc_value "${REPO_ROOT}/${path}")"
  # スキルは自分自身のスラッシュ語を必ず持つ（導出。手書きしない）
  if [ "$surface" = "skill" ]; then
    assert_eq "(D-3) 自分自身のスラッシュ語を持つ: ${path}" "true" \
      "$(if desc_triggers "$val" | grep -qFx -- "/${name}"; then echo true; else echo false; fi)"
  fi
  # トリガー語に現れるスラッシュ語はすべて実在スキル or 宣言済み別名
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    while IFS= read -r slash; do
      [ -z "$slash" ] && continue
      resolved="false"
      [ -d "${REPO_ROOT}/skills/${slash#/}" ] && resolved="true"
      printf '%s\n' "$DECLARED_ALIASES" | grep -qFx -- "$slash" && resolved="true"
      assert_eq "(D-3) スラッシュ語が解決する: ${path} [${slash}]" "true" "$resolved"
    done <<<"$(printf '%s' "$tok" | grep -o '/[A-Za-z][A-Za-z0-9-]*')"
  done <<<"$(desc_triggers "$val")"
done <<<"$DERIVED"

echo ""
echo "=== (D-4) 台帳と現物の一致（行集合＝導出集合／起動トリガーは双方向／保持語は片方向） ==="

LEDGER_TARGETS="$(
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    printf '%s\t%s\n' "$(ledger_cell "$row" 2)" "$(ledger_cell "$row" 3)"
  done <<<"$LEDGER_ROWS" | sort
)"

assert_eq "(D-4) 台帳の行集合が導出した対象集合と一致する" "$DERIVED" "$LEDGER_TARGETS"

while IFS= read -r row; do
  [ -z "$row" ] && continue
  surface="$(ledger_cell "$row" 2)"
  name="$(ledger_cell "$row" 3)"
  path="$(surface_path "$surface" "$name")"
  if [ ! -r "${REPO_ROOT}/${path}" ]; then
    assert_eq "(D-4) 台帳の面が実在する: ${surface}/${name}" "true" "false"
    continue
  fi
  val="$(desc_value "${REPO_ROOT}/${path}")"
  expected_trig="$(ledger_items "$(ledger_cell "$row" 4)" | sort)"
  actual_trig="$(desc_triggers "$val" | sort)"
  assert_eq "(D-4) 起動トリガーが台帳と完全一致: ${path}" "$expected_trig" "$actual_trig"
  while IFS= read -r keep; do
    [ -z "$keep" ] && continue
    assert_eq "(D-4) 保持語が description に残っている: ${path} [${keep}]" "true" \
      "$(if printf '%s' "$val" | grep -qF -- "$keep"; then echo true; else echo false; fi)"
  done <<<"$(ledger_items "$(ledger_cell "$row" 5)")"
done <<<"$LEDGER_ROWS"

echo ""
echo "=== 実測（正本 §7 の再現手段。単位はバイト数と文字数の両方を出す） ==="

measure() {
  local label="$1"; shift
  local n=0 tb=0 tc=0 mb=0 mc=0 mf="" f v b c
  for f in "$@"; do
    v="$(desc_value "$f")"
    b="$(printf '%s' "$v" | wc -c | tr -d ' ')"
    c="$(printf '%s' "$v" | wc -m | tr -d ' ')"
    tb=$((tb + b)); tc=$((tc + c)); n=$((n + 1))
    if [ "$b" -gt "$mb" ]; then mb="$b"; mf="$f"; fi
    [ "$c" -gt "$mc" ] && mc="$c"
  done
  [ "$n" -eq 0 ] && { echo "  ${label}: 対象0件"; return 0; }
  printf '  %s: 件数=%d 平均=%d バイト / %d 文字 最長=%d バイト / %d 文字 (%s) 合計=%d バイト / %d 文字\n' \
    "$label" "$n" "$((tb / n))" "$((tc / n))" "$mb" "$mc" "$mf" "$tb" "$tc"
}

measure "skills" skills/*/SKILL.md
measure "agents" agents/*.md
measure "合計  " skills/*/SKILL.md agents/*.md

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
