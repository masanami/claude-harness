#!/bin/bash
# test-promotion-decision.sh
# scripts/promotion-decision.sh の判定式（readyForPromotion の5項）を
# 入力の組み合わせに対する真理値表として固定する。gh 非依存。
#
# 本テストの役割（散文の判定式では書けなかった検査）:
#  (1) 真理値表: 各項を1つずつ偽にしたとき、総合判定が必ず偽になること（項が判定へ接続されている）
#  (2) 空集合ケース: 対象リストが空配列（検査した結果の0件）と null（検査不能）で扱いが分かれること
#  (3) 各項の独立性（load-bearing 検査）: 項を1つ偽にすると必ず落ちる＝飾りの項が無いこと
#  (4) 契約: exit code と JSON の真偽が一致すること・必須キー欠落は false ではなく exit 2 になること
#  (5) 語彙の完全性: spec の blockers 表に載っているコードが実際に出力されうること
#
# 実行方法: bash scripts/tests/test-promotion-decision.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

PD_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PD_TEST_DIR}/../.." && pwd)"
TARGET_SCRIPT="${REPO_ROOT}/scripts/promotion-decision.sh"
SPEC_FILE="${REPO_ROOT}/scripts/specs/promotion-decision.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "NG - jq が見つからないためテストを実行できません（検査不能を pass にはしない）" >&2
  exit 1
fi

if [ ! -r "$SPEC_FILE" ]; then
  echo "NG - spec を読めません（検査不能を pass にはしない）: ${SPEC_FILE}" >&2
  exit 1
fi

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

# スクリプトを実行し、判定フィールドの値を返す（stdout の JSON から読む）。
# 引数: <mode> <入力JSON>
decide() {
  local mode="$1" input="$2" field out
  case "$mode" in
    ready-for-promotion) field="readyForPromotion" ;;
  esac
  out="$(printf '%s' "$input" | bash "$TARGET_SCRIPT" "$mode" 2>/dev/null)"
  printf '%s' "$out" | jq -r ".${field}"
}

# スクリプトを実行し、exit code を返す。
run_exit() {
  printf '%s' "$2" | bash "$TARGET_SCRIPT" "$1" >/dev/null 2>&1
  printf '%s' "$?"
}

# blockers を , 区切りで返す。
blockers_of() {
  printf '%s' "$2" | bash "$TARGET_SCRIPT" "$1" 2>/dev/null | jq -r '.blockers | join(",")'
}

# terms の指定キーを返す。
term_of() {
  printf '%s' "$2" | bash "$TARGET_SCRIPT" "$1" 2>/dev/null | jq -r ".terms.${3}"
}

# 検査ヘルパーの定義漏れ検出: 未定義の `assert_*` を呼んでも bash は
# 「command not found」を出して次の行へ進むだけであり、そのアサーションは
# 黙って実行されない（検査不能が pass に見える）。本ファイルが使う
# ヘルパーがすべて定義済みであることを、アサーションを走らせる前に確認する。
undefined_helpers=""
while IFS= read -r helper; do
  [ -z "$helper" ] && continue
  declare -F "$helper" >/dev/null 2>&1 || undefined_helpers="${undefined_helpers}${helper} "
done <<<"$(grep -ohE '\bassert_[a-z_]+' "${BASH_SOURCE[0]}" | sort -u)"
if [ -n "$undefined_helpers" ]; then
  echo "NG - 未定義の検査ヘルパーを参照しています（アサーションが黙って実行されません）: ${undefined_helpers}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# ready-for-promotion: 入力ビルダー
#   引数: <1: allMerged> <2: criteria status> <3: criteria needsHumanReview> <4: QC> <5: E2E>
rp_input() {
  local m="$1" s="$2" h="$3" q="$4" e="$5"
  local merged criteria quality e2e status_value review_value
  if [ "$m" = "1" ]; then merged="true"; else merged="false"; fi
  if [ "$s" = "1" ]; then status_value='"consistent"'; else status_value='"inconsistent"'; fi
  if [ "$h" = "1" ]; then review_value="false"; else review_value="true"; fi
  criteria="[{\"id\":\"AC-1\",\"status\":${status_value},\"needsHumanReview\":${review_value}}]"
  if [ "$q" = "1" ]; then quality='{"skipped":false,"result":"pass"}'; else quality='{"skipped":false,"result":"fail"}'; fi
  if [ "$e" = "1" ]; then e2e='{"skipped":false,"passed":true}'; else e2e='{"skipped":false,"passed":false}'; fi
  printf '{"allMerged":%s,"criteria":%s,"qualityCheck":%s,"e2e":%s}' \
    "$merged" "$criteria" "$quality" "$e2e"
}

echo ""
echo "=== (4) ready-for-promotion の真理値表（5項の全32通り） ==="

rp_failures=0
for m in 1 0; do
  for s in 1 0; do
    for h in 1 0; do
      for q in 1 0; do
        for e in 1 0; do
          expected="false"
          [ "$m$s$h$q$e" = "11111" ] && expected="true"
          actual="$(decide ready-for-promotion "$(rp_input "$m" "$s" "$h" "$q" "$e")")"
          if [ "$actual" != "$expected" ]; then
            rp_failures=$((rp_failures + 1))
            echo "       (m,s,h,q,e)=(${m},${s},${h},${q},${e}) expected=${expected} actual=${actual}"
          fi
        done
      done
    done
  done
done
assert_eq "readyForPromotion は5項すべてが真のときだけ true（32通りを網羅）" "0" "$rp_failures"

assert_eq "allMerged だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 0 1 1 1 1)")"
assert_eq "criterion status だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 0 1 1 1)")"
assert_eq "criterion needsHumanReview だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 1 0 1 1)")"
assert_eq "QC だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 1 1 0 1)")"
assert_eq "E2E だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 1 1 1 0)")"
assert_eq "すべて真 → true" "true" "$(decide ready-for-promotion "$(rp_input 1 1 1 1 1)")"

echo ""
echo "=== (5) ready-for-promotion の「スキップは OK 扱い」の意味論 ==="

skipped_all='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true,"reason":"..."},"e2e":{"skipped":true,"reason":"..."}}'
assert_eq "QC/E2E がともに明示スキップなら true（スキップは OK 扱い）" \
  "true" "$(decide ready-for-promotion "$skipped_all")"

qc_no_result='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":false},"e2e":{"skipped":true}}'
assert_eq "スキップでないのに result が無い QC は true にしない" \
  "false" "$(decide ready-for-promotion "$qc_no_result")"
assert_eq "その blockers は quality_result_missing" \
  "quality_result_missing" "$(blockers_of ready-for-promotion "$qc_no_result")"

e2e_no_result='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":false}}'
assert_eq "スキップでないのに passed が無い E2E は true にしない" \
  "false" "$(decide ready-for-promotion "$e2e_no_result")"

echo ""
echo "=== (6) ready-for-promotion の空集合ケース（受入基準ゼロ件） ==="

criteria_empty='{"allMerged":true,"criteria":[],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
assert_eq "受入基準が空配列なら false（全称条件を空虚に真にしない）" \
  "false" "$(decide ready-for-promotion "$criteria_empty")"
assert_eq "その blockers は criteria_empty" \
  "criteria_empty" "$(blockers_of ready-for-promotion "$criteria_empty")"
assert_eq "空配列では criteriaConsistent を真にしない" \
  "false" "$(term_of ready-for-promotion "$criteria_empty" criteriaConsistent)"
assert_eq "空配列では criteriaNoHumanReview も真にしない" \
  "false" "$(term_of ready-for-promotion "$criteria_empty" criteriaNoHumanReview)"

criteria_null='{"allMerged":true,"criteria":null,"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
assert_eq "受入基準が null なら false" "false" "$(decide ready-for-promotion "$criteria_null")"
assert_eq "その blockers は criteria_unknown" \
  "criteria_unknown" "$(blockers_of ready-for-promotion "$criteria_null")"

criteria_no_status='{"allMerged":true,"criteria":[{"id":"AC-1"}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
assert_eq "status フィールドの無い基準があれば false" \
  "false" "$(decide ready-for-promotion "$criteria_no_status")"

# needsHumanReview の不在・非boolean を「要人間判定なし」に丸めない
# （status には has() 検査があるのに項3だけ抜けていると、要人間判定の付いた基準を
#  渡し忘れた呼び出しがそのまま readyForPromotion: true になる）
criteria_no_review='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent"}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
assert_eq "needsHumanReview が無い基準は true にしない（不在を「なし」に読み替えない）" \
  "false" "$(decide ready-for-promotion "$criteria_no_review")"
assert_eq "その blockers は criteria_review_missing" \
  "criteria_review_missing" "$(blockers_of ready-for-promotion "$criteria_no_review")"
assert_eq "その場合 criteriaNoHumanReview は false" \
  "false" "$(term_of ready-for-promotion "$criteria_no_review" criteriaNoHumanReview)"

criteria_null_review='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":null}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
assert_eq "needsHumanReview が null の基準は true にしない" \
  "false" "$(decide ready-for-promotion "$criteria_null_review")"
assert_eq "その blockers は criteria_review_invalid" \
  "criteria_review_invalid" "$(blockers_of ready-for-promotion "$criteria_null_review")"

criteria_str_review='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":"yes"}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
assert_eq "needsHumanReview が非boolean（文字列）の基準は true にしない" \
  "false" "$(decide ready-for-promotion "$criteria_str_review")"
assert_eq "その blockers は criteria_review_invalid" \
  "criteria_review_invalid" "$(blockers_of ready-for-promotion "$criteria_str_review")"

# 対称性: status と needsHumanReview の欠落は同じ強度で落ちる（同一 jq 内の非対称を作らない）
assert_eq "status 欠落と needsHumanReview 欠落はどちらも false（検査の非対称が無い）" \
  "false,false" \
  "$(printf '%s,%s' "$(decide ready-for-promotion "$criteria_no_status")" "$(decide ready-for-promotion "$criteria_no_review")")"

# 受理方向: boolean で明示されていれば従来どおり通る
criteria_ok_review='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
assert_eq "needsHumanReview: false は従来どおり true になる（過剰に落とさない）" \
  "true" "$(decide ready-for-promotion "$criteria_ok_review")"


echo ""
echo "=== (7) CLI 契約（exit code と JSON の一致・実行前提の欠落） ==="

assert_eq "判定 true なら exit 0" "0" "$(run_exit ready-for-promotion "$(rp_input 1 1 1 1 1)")"
assert_eq "判定 false なら exit 1" "1" "$(run_exit ready-for-promotion "$(rp_input 1 1 1 1 0)")"

# exit code と JSON の真偽が食い違わないこと（呼び出し側の突き合わせが成立する）
mismatch=0
for combo in "1 1 1 1 1" "0 1 1 1 1" "1 0 1 1 1" "1 1 0 1 1" "1 1 1 0 1" "1 1 1 1 0"; do
  # shellcheck disable=SC2086 # combo は意図的に単語分割して5引数として渡す
  body="$(rp_input $combo)"
  json_value="$(decide ready-for-promotion "$body")"
  exit_code="$(run_exit ready-for-promotion "$body")"
  expected_exit="1"
  [ "$json_value" = "true" ] && expected_exit="0"
  [ "$exit_code" != "$expected_exit" ] && mismatch=$((mismatch + 1))
done
assert_eq "exit code と JSON の判定値が全経路で一致する" "0" "$mismatch"

missing_key_out="$(printf '%s' '{"guarantees":null}' | bash "$TARGET_SCRIPT" ready-for-promotion 2>/dev/null)"
missing_key_exit=$?
assert_eq "必須キーの欠落は exit 2（false ではない）" "2" "$missing_key_exit"
assert_eq "必須キーの欠落時の stdout は空（未検査を判定結果に見せない）" "" "$missing_key_out"

bad_json_out="$(printf '%s' 'not a json' | bash "$TARGET_SCRIPT" ready-for-promotion 2>/dev/null)"
bad_json_exit=$?
assert_eq "JSON としてパースできない入力は exit 2" "2" "$bad_json_exit"
assert_eq "その場合の stdout は空" "" "$bad_json_out"

empty_out="$(printf '%s' '' | bash "$TARGET_SCRIPT" ready-for-promotion 2>/dev/null)"
empty_exit=$?
assert_eq "入力が空なら exit 2" "2" "$empty_exit"
assert_eq "その場合の stdout は空" "" "$empty_out"

unknown_mode_out="$(printf '%s' '{}' | bash "$TARGET_SCRIPT" bogus-mode 2>/dev/null)"
unknown_mode_exit=$?
assert_eq "未知の mode は exit 2" "2" "$unknown_mode_exit"
assert_eq "その場合の stdout は空" "" "$unknown_mode_out"

no_mode_out="$(printf '%s' '{}' | bash "$TARGET_SCRIPT" 2>/dev/null)"
no_mode_exit=$?
assert_eq "mode 無しは exit 2" "2" "$no_mode_exit"
assert_eq "その場合の stdout は空" "" "$no_mode_out"

too_many_exit="$(printf '%s' '{}' | bash "$TARGET_SCRIPT" ready-for-promotion extra >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "引数が多すぎる場合は exit 2" "2" "$too_many_exit"

unknown_opt_exit="$(printf '%s' '{}' | bash "$TARGET_SCRIPT" --bogus >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "未知オプションは exit 2" "2" "$unknown_opt_exit"

# --input でファイルからも読める
TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() { rm -rf "$TMP_ROOT"; }
trap cleanup_tmp_root EXIT
printf '%s' "$(rp_input 1 1 1 1 1)" > "${TMP_ROOT}/input.json"
file_out="$(bash "$TARGET_SCRIPT" ready-for-promotion --input "${TMP_ROOT}/input.json" 2>/dev/null)"
assert_eq "--input のファイルからも判定できる" "true" "$(printf '%s' "$file_out" | jq -r '.readyForPromotion')"
bad_input_exit="$(bash "$TARGET_SCRIPT" ready-for-promotion --input "${TMP_ROOT}/nope.json" >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "--input のファイルが無い場合は exit 2" "2" "$bad_input_exit"

echo ""
echo "=== (8) spec との整合（項の表・blockers 語彙の逐語照合） ==="

# terms のキーが spec の項の表に逐語で載っていること（項を足して spec を更新し忘れると落ちる）
spec_term_failures=""
for term in allMerged criteriaConsistent criteriaNoHumanReview qualityOk e2eOk; do
  grep -qF -- "\`${term}\`" "$SPEC_FILE" || spec_term_failures="${spec_term_failures}${term} "
done
assert_eq "すべての terms キーが spec の項の表に載っている" "" "$spec_term_failures"

# 実装が出力しうる blockers を jq プログラムの配列リテラル（`["code"]`）から抽出する。
# 語彙表に無いコードを実装が返しうる状態（spec の更新漏れ）を、方向を変えて検出する
# （下のループは「表にあるコードが実装にある」＝逆方向しか見ないため）。
impl_blockers="$(grep -oE '\["[a-z0-9_]+"\]' "$TARGET_SCRIPT" | tr -d '\[\]"' | sort -u)"
undocumented=""
while IFS= read -r code; do
  [ -z "$code" ] && continue
  grep -qF -- "\`${code}\`" "$SPEC_FILE" || undocumented="${undocumented}${code} "
done <<<"$impl_blockers"
assert_eq "実装が返しうる blockers はすべて spec の語彙表に載っている（表の更新漏れ検出）" "" "$undocumented"
assert_eq "実装が返しうる blockers の総数（語彙表と一致）" \
  "19" "$(printf '%s\n' "$impl_blockers" | grep -c .)"

spec_blocker_failures=""
for code in not_all_merged criteria_unknown criteria_invalid criteria_empty criteria_status_missing \
  criteria_not_consistent criteria_review_missing criteria_review_invalid criteria_needs_human_review \
  criteria_id_missing criteria_id_invalid \
  quality_check_missing quality_check_invalid \
  quality_result_missing quality_not_pass e2e_missing e2e_invalid e2e_result_missing e2e_not_passed; do
  grep -qF -- "\`${code}\`" "$SPEC_FILE" || spec_blocker_failures="${spec_blocker_failures}${code} "
  grep -qF -- "\"${code}\"" "$TARGET_SCRIPT" || spec_blocker_failures="${spec_blocker_failures}${code}(impl) "
done
assert_eq "blockers の語彙が spec と実装の双方に存在する" "" "$spec_blocker_failures"

echo ""
echo "=== (11) criteria[].id の妥当性（契約フィールドを無検査で通さない） ==="

rp_with_id() {
  printf '{"allMerged":true,"criteria":[{"id":%s,"status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}' "$1"
}
criteria_id_no_key='{"allMerged":true,"criteria":[{"status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
assert_eq "criteria[].id が無ければ false" "false" "$(decide ready-for-promotion "$criteria_id_no_key")"
assert_eq "その blockers は criteria_id_missing" \
  "criteria_id_missing" "$(blockers_of ready-for-promotion "$criteria_id_no_key")"
bad_criteria_id_failures=0
for bad in 'null' '""' '123' '{}'; do
  if [ "$(decide ready-for-promotion "$(rp_with_id "$bad")")" != "false" ]; then
    bad_criteria_id_failures=$((bad_criteria_id_failures + 1))
    echo "       criteria id=${bad} で false にならない"
  fi
done
assert_eq "criteria[].id が非空文字列でなければ false（4種）" "0" "$bad_criteria_id_failures"
assert_eq "criteria[].id が非空文字列なら通る（過剰に落とさない）" \
  "true" "$(decide ready-for-promotion "$(rp_with_id '"AC-1"')")"

echo ""
echo "=== (12) 同型の掃引: 存在検査だけで値を見ない箇所が無い ==="

# 「不正な値が真として読まれる」経路が残っていないことを、全フィールドの不正値で固定する。
# 等値比較で fail-closed になるフィールドも、将来の書き換えで真側へ倒れないようここで押さえる。
sweep_failures=""
sweep_check() {
  local label="$1" mode="$2" body="$3"
  if [ "$(decide "$mode" "$body")" != "false" ]; then
    sweep_failures="${sweep_failures}${label} "
  fi
}

RP_TAIL='"qualityCheck":{"skipped":true},"e2e":{"skipped":true}'
sweep_check "allMerged=\"true\""   ready-for-promotion "{\"allMerged\":\"true\",\"criteria\":[{\"id\":\"AC-1\",\"status\":\"consistent\",\"needsHumanReview\":false}],${RP_TAIL}}"
sweep_check "allMerged=1"          ready-for-promotion "{\"allMerged\":1,\"criteria\":[{\"id\":\"AC-1\",\"status\":\"consistent\",\"needsHumanReview\":false}],${RP_TAIL}}"
sweep_check "allMerged=null"       ready-for-promotion "{\"allMerged\":null,\"criteria\":[{\"id\":\"AC-1\",\"status\":\"consistent\",\"needsHumanReview\":false}],${RP_TAIL}}"
sweep_check "status=null"          ready-for-promotion "{\"allMerged\":true,\"criteria\":[{\"id\":\"AC-1\",\"status\":null,\"needsHumanReview\":false}],${RP_TAIL}}"
sweep_check "status=123"           ready-for-promotion "{\"allMerged\":true,\"criteria\":[{\"id\":\"AC-1\",\"status\":123,\"needsHumanReview\":false}],${RP_TAIL}}"
sweep_check "qc.skipped=\"true\""  ready-for-promotion '{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":"true"},"e2e":{"skipped":true}}'
sweep_check "qc.result=null"       ready-for-promotion '{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":false,"result":null},"e2e":{"skipped":true}}'
sweep_check "e2e.passed=\"true\""  ready-for-promotion '{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":false,"passed":"true"}}'
sweep_check "e2e.passed=1"         ready-for-promotion '{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":false,"passed":1}}'
assert_eq "全フィールドの不正値が真として読まれない（掃引8ケース）" "" "$sweep_failures"

echo ""
echo "=== (13) 入力はちょうど1つの JSON オブジェクト（1入力1出力の契約） ==="

RP_ONE='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true}}'
multi_out="$(printf '%s %s' "$RP_ONE" "$RP_ONE" | bash "$TARGET_SCRIPT" ready-for-promotion 2>/dev/null)"
multi_exit=$?
assert_eq "JSON 値が2つある入力は exit 2（判定 false と誤報告しない）" "2" "$multi_exit"
assert_eq "その場合の stdout は空（判定結果を2個出さない）" "" "$multi_out"

multi_nl_exit="$(printf '%s\n%s\n' "$RP_ONE" "$RP_ONE" | bash "$TARGET_SCRIPT" ready-for-promotion >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "改行区切りで2つ並べた入力も exit 2" "2" "$multi_nl_exit"

# 単一値は従来どおり（過剰に落とさない）。末尾改行・前後空白も受理する
assert_eq "単一値は従来どおり true" "true" "$(decide ready-for-promotion "$RP_ONE")"
trailing_nl_exit="$(printf '%s\n' "$RP_ONE" | bash "$TARGET_SCRIPT" ready-for-promotion >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "末尾に改行がある単一値は受理する" "0" "$trailing_nl_exit"

for bad_type in '[1,2]' '"text"' '123' 'null' 'true'; do
  bad_out="$(printf '%s' "$bad_type" | bash "$TARGET_SCRIPT" ready-for-promotion 2>/dev/null)"
  bad_exit=$?
  assert_eq "オブジェクトでない入力（${bad_type}）は exit 2" "2" "$bad_exit"
  assert_eq "オブジェクトでない入力（${bad_type}）の stdout は空" "" "$bad_out"
done

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
