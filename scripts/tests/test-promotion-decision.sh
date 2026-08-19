#!/bin/bash
# test-promotion-decision.sh
# scripts/promotion-decision.sh の判定式（allConsistent の4項 / readyForPromotion の6項）を
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
    all-consistent) field="allConsistent" ;;
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
# all-consistent: 入力ビルダー
#   引数: <a: targets/guarantees の対応> <b: index> <c: verdict> <d: humanReview>
#   各引数は 1（真になる材料）/ 0（偽になる材料）
# ---------------------------------------------------------------------------
ac_input() {
  local a="$1" b="$2" c="$3" d="$4"
  local targets guarantees index human
  if [ "$a" = "1" ]; then
    targets='["G-158-1"]'
  else
    # targets にあるのに guarantees に結果が無い（部分成功≠完全成功）
    targets='["G-158-1","G-158-2"]'
  fi
  if [ "$c" = "1" ]; then
    guarantees='[{"guarantee_id":"G-158-1","verdict":"consistent"}]'
  else
    guarantees='[{"guarantee_id":"G-158-1","verdict":"drifted"}]'
  fi
  if [ "$b" = "1" ]; then
    index='{"status":"pass","error":null}'
  else
    index='{"status":"fail","error":null}'
  fi
  if [ "$d" = "1" ]; then
    human='[]'
  else
    human='[{"kind":"ledger_read_mismatch","detail":"..."}]'
  fi
  printf '{"targets":%s,"guarantees":%s,"index":%s,"humanReview":%s}' \
    "$targets" "$guarantees" "$index" "$human"
}

# ready-for-promotion: 入力ビルダー
#   引数: <1: allMerged> <2: criteria status> <3: criteria needsHumanReview> <4: QC> <5: E2E> <6: 保証整合>
rp_input() {
  local m="$1" s="$2" h="$3" q="$4" e="$5" g="$6"
  local merged criteria quality e2e guarantee status_value review_value
  if [ "$m" = "1" ]; then merged="true"; else merged="false"; fi
  if [ "$s" = "1" ]; then status_value='"consistent"'; else status_value='"inconsistent"'; fi
  if [ "$h" = "1" ]; then review_value="false"; else review_value="true"; fi
  criteria="[{\"id\":\"AC-1\",\"status\":${status_value},\"needsHumanReview\":${review_value}}]"
  if [ "$q" = "1" ]; then quality='{"skipped":false,"result":"pass"}'; else quality='{"skipped":false,"result":"fail"}'; fi
  if [ "$e" = "1" ]; then e2e='{"skipped":false,"passed":true}'; else e2e='{"skipped":false,"passed":false}'; fi
  if [ "$g" = "1" ]; then guarantee='{"skipped":false,"allConsistent":true}'; else guarantee='{"skipped":false,"allConsistent":false}'; fi
  printf '{"allMerged":%s,"criteria":%s,"qualityCheck":%s,"e2e":%s,"guaranteeCheck":%s}' \
    "$merged" "$criteria" "$quality" "$e2e" "$guarantee"
}

echo "=== (1) all-consistent の真理値表（4項の全16通り） ==="

AC_TERM_NAMES=(targetsCovered indexPass allVerdictsConsistent noHumanReview)
ac_failures=0
for a in 1 0; do
  for b in 1 0; do
    for c in 1 0; do
      for d in 1 0; do
        expected="false"
        [ "$a$b$c$d" = "1111" ] && expected="true"
        actual="$(decide all-consistent "$(ac_input "$a" "$b" "$c" "$d")")"
        if [ "$actual" != "$expected" ]; then
          ac_failures=$((ac_failures + 1))
          echo "       (a,b,c,d)=(${a},${b},${c},${d}) expected=${expected} actual=${actual}"
        fi
      done
    done
  done
done
assert_eq "allConsistent は4項すべてが真のときだけ true（16通りを網羅）" "0" "$ac_failures"

# 各項が独立に効いていること（項を1つだけ偽にすると必ず落ちる = 飾りの項が無い）
assert_eq "(a) だけ偽 → false" "false" "$(decide all-consistent "$(ac_input 0 1 1 1)")"
assert_eq "(b) だけ偽 → false" "false" "$(decide all-consistent "$(ac_input 1 0 1 1)")"
assert_eq "(c) だけ偽 → false" "false" "$(decide all-consistent "$(ac_input 1 1 0 1)")"
assert_eq "(d) だけ偽 → false" "false" "$(decide all-consistent "$(ac_input 1 1 1 0)")"
assert_eq "すべて真 → true（安全側に倒しすぎて常に false ではない）" \
  "true" "$(decide all-consistent "$(ac_input 1 1 1 1)")"

# 落ちた項が terms に正しく反映される（どの項で落ちたかが表に出る）
assert_eq "(b) が偽なら terms.indexPass は false" \
  "false" "$(term_of all-consistent "$(ac_input 1 0 1 1)" indexPass)"
assert_eq "(b) が偽でも terms.targetsCovered は true（項が混線していない）" \
  "true" "$(term_of all-consistent "$(ac_input 1 0 1 1)" targetsCovered)"

echo ""
echo "=== (2) 空集合ケース: 「調べた結果の0件」と「調べられなかった」を分ける ==="

empty_ok='{"targets":[],"guarantees":[],"index":{"status":"pass","error":null},"humanReview":[]}'
assert_eq "targets 空配列（保証節が「なし」と明示）＋索引 pass ＋要人間判定なし → true" \
  "true" "$(decide all-consistent "$empty_ok")"

empty_with_review='{"targets":[],"guarantees":[],"index":{"status":"pass","error":null},"humanReview":[{"kind":"ledger_read_mismatch"}]}'
assert_eq "targets 空でも要人間判定があれば false（空虚な真で素通りしない）" \
  "false" "$(decide all-consistent "$empty_with_review")"
assert_eq "その場合の blockers は human_review_present" \
  "human_review_present" "$(blockers_of all-consistent "$empty_with_review")"

empty_with_bad_index='{"targets":[],"guarantees":[],"index":{"status":"fail","error":null},"humanReview":[]}'
assert_eq "targets 空でも索引が fail なら false" \
  "false" "$(decide all-consistent "$empty_with_bad_index")"

null_targets='{"targets":null,"guarantees":null,"index":null,"humanReview":[{"kind":"phase_invalid"}]}'
assert_eq "早期失敗（targets/guarantees/index が null）は false" \
  "false" "$(decide all-consistent "$null_targets")"
assert_eq "早期失敗では (a) を空虚に真にしない" \
  "false" "$(term_of all-consistent "$null_targets" targetsCovered)"
assert_eq "早期失敗では (c) を空虚に真にしない" \
  "false" "$(term_of all-consistent "$null_targets" allVerdictsConsistent)"

# null と空配列の差が判定に効いていること（検査不能≠0件の実装上の担保）
null_only_targets='{"targets":null,"guarantees":[],"index":{"status":"pass","error":null},"humanReview":[]}'
assert_eq "targets が null なら、他がすべて真でも false（空配列とは別扱い）" \
  "false" "$(decide all-consistent "$null_only_targets")"
assert_eq "その blockers は targets_unknown" \
  "targets_unknown" "$(blockers_of all-consistent "$null_only_targets")"

null_only_guarantees='{"targets":[],"guarantees":null,"index":{"status":"pass","error":null},"humanReview":[]}'
assert_eq "guarantees が null なら false（未検査を0件に丸めない）" \
  "false" "$(decide all-consistent "$null_only_guarantees")"

echo ""
echo "=== (3) all-consistent の個別規則 ==="

partial='{"targets":["G-158-1","G-158-2"],"guarantees":[{"guarantee_id":"G-158-1","verdict":"consistent"}],"index":{"status":"pass","error":null},"humanReview":[]}'
assert_eq "部分成功≠完全成功: targets の一部しか結果が無ければ false" \
  "false" "$(decide all-consistent "$partial")"
assert_eq "その blockers は targets_not_covered" \
  "targets_not_covered" "$(blockers_of all-consistent "$partial")"

extra='{"targets":["G-158-1"],"guarantees":[{"guarantee_id":"G-158-1","verdict":"consistent"},{"guarantee_id":"G-999-1","verdict":"consistent"}],"index":{"status":"pass","error":null},"humanReview":[]}'
assert_eq "targets に無い ID が guarantees にあれば false（件数だけでなく ID を突き合わせる）" \
  "false" "$(decide all-consistent "$extra")"

dup_targets='{"targets":["G-158-1","G-158-1"],"guarantees":[{"guarantee_id":"G-158-1","verdict":"consistent"}],"index":{"status":"pass","error":null},"humanReview":[]}'
assert_eq "targets に重複があれば「1件ずつ」を定義できないので false" \
  "false" "$(decide all-consistent "$dup_targets")"
assert_eq "その blockers は targets_duplicated" \
  "targets_duplicated" "$(blockers_of all-consistent "$dup_targets")"

index_err='{"targets":["G-158-1"],"guarantees":[{"guarantee_id":"G-158-1","verdict":"consistent"}],"index":{"status":"pass","error":"status=pass と exit code=1 が食い違う"},"humanReview":[]}'
assert_eq "index.error が非 null なら status が pass でも (b) は偽" \
  "false" "$(decide all-consistent "$index_err")"
assert_eq "その blockers は index_error" \
  "index_error" "$(blockers_of all-consistent "$index_err")"

# verdict 語彙のうち consistent 以外はすべて false になること（丸め込みが無い）
verdict_failures=0
for verdict in drifted uncertain verification_failed not_registered; do
  body="{\"targets\":[\"G-158-1\"],\"guarantees\":[{\"guarantee_id\":\"G-158-1\",\"verdict\":\"${verdict}\"}],\"index\":{\"status\":\"pass\",\"error\":null},\"humanReview\":[]}"
  if [ "$(decide all-consistent "$body")" != "false" ]; then
    verdict_failures=$((verdict_failures + 1))
    echo "       verdict=${verdict} で false にならない"
  fi
done
assert_eq "consistent 以外の verdict（4種）はすべて false に落ちる" "0" "$verdict_failures"

missing_verdict='{"targets":["G-158-1"],"guarantees":[{"guarantee_id":"G-158-1"}],"index":{"status":"pass","error":null},"humanReview":[]}'
assert_eq "verdict フィールドの不在を「問題なし」に読み替えない" \
  "false" "$(decide all-consistent "$missing_verdict")"

# humanReview の kind は問わない（(d) は非空そのものを見る＝ kind 追加時の接続漏れが起きない）
kind_failures=0
for kind in phase_invalid ledger_missing guarantee_section_missing index_error ledger_read_mismatch guarantee_id_scope_mismatch guarantee_provenance_mismatch verification_failed; do
  body="{\"targets\":[\"G-158-1\"],\"guarantees\":[{\"guarantee_id\":\"G-158-1\",\"verdict\":\"consistent\"}],\"index\":{\"status\":\"pass\",\"error\":null},\"humanReview\":[{\"kind\":\"${kind}\"}]}"
  if [ "$(decide all-consistent "$body")" != "false" ]; then
    kind_failures=$((kind_failures + 1))
    echo "       kind=${kind} で false にならない"
  fi
done
assert_eq "humanReview のすべての kind（8種）で false になる（理由コードごとの接続漏れが無い）" \
  "0" "$kind_failures"

echo ""
echo "=== (4) ready-for-promotion の真理値表（6項の全64通り） ==="

rp_failures=0
for m in 1 0; do
  for s in 1 0; do
    for h in 1 0; do
      for q in 1 0; do
        for e in 1 0; do
          for g in 1 0; do
            expected="false"
            [ "$m$s$h$q$e$g" = "111111" ] && expected="true"
            actual="$(decide ready-for-promotion "$(rp_input "$m" "$s" "$h" "$q" "$e" "$g")")"
            if [ "$actual" != "$expected" ]; then
              rp_failures=$((rp_failures + 1))
              echo "       (m,s,h,q,e,g)=(${m},${s},${h},${q},${e},${g}) expected=${expected} actual=${actual}"
            fi
          done
        done
      done
    done
  done
done
assert_eq "readyForPromotion は6項すべてが真のときだけ true（64通りを網羅）" "0" "$rp_failures"

assert_eq "allMerged だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 0 1 1 1 1 1)")"
assert_eq "criterion status だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 0 1 1 1 1)")"
assert_eq "criterion needsHumanReview だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 1 0 1 1 1)")"
assert_eq "QC だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 1 1 0 1 1)")"
assert_eq "E2E だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 1 1 1 0 1)")"
assert_eq "保証整合だけ偽 → false" "false" "$(decide ready-for-promotion "$(rp_input 1 1 1 1 1 0)")"
assert_eq "すべて真 → true" "true" "$(decide ready-for-promotion "$(rp_input 1 1 1 1 1 1)")"

echo ""
echo "=== (5) ready-for-promotion の「スキップは OK 扱い」の意味論 ==="

skipped_all='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true,"reason":"..."},"e2e":{"skipped":true,"reason":"..."},"guaranteeCheck":{"skipped":true,"reason":"SDD期"}}'
assert_eq "QC/E2E/保証整合がすべて明示スキップなら true（スキップは OK 扱い）" \
  "true" "$(decide ready-for-promotion "$skipped_all")"

qc_no_result='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":false},"e2e":{"skipped":true},"guaranteeCheck":{"skipped":true}}'
assert_eq "スキップでないのに result が無い QC は true にしない" \
  "false" "$(decide ready-for-promotion "$qc_no_result")"
assert_eq "その blockers は quality_result_missing" \
  "quality_result_missing" "$(blockers_of ready-for-promotion "$qc_no_result")"

e2e_no_result='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":false},"guaranteeCheck":{"skipped":true}}'
assert_eq "スキップでないのに passed が無い E2E は true にしない" \
  "false" "$(decide ready-for-promotion "$e2e_no_result")"

gc_no_result='{"allMerged":true,"criteria":[{"id":"AC-1","status":"consistent","needsHumanReview":false}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true},"guaranteeCheck":{"skipped":false}}'
assert_eq "スキップでないのに allConsistent が無い保証整合は true にしない" \
  "false" "$(decide ready-for-promotion "$gc_no_result")"
assert_eq "その blockers は guarantee_result_missing" \
  "guarantee_result_missing" "$(blockers_of ready-for-promotion "$gc_no_result")"

echo ""
echo "=== (6) ready-for-promotion の空集合ケース（受入基準ゼロ件） ==="

criteria_empty='{"allMerged":true,"criteria":[],"qualityCheck":{"skipped":true},"e2e":{"skipped":true},"guaranteeCheck":{"skipped":true}}'
assert_eq "受入基準が空配列なら false（全称条件を空虚に真にしない）" \
  "false" "$(decide ready-for-promotion "$criteria_empty")"
assert_eq "その blockers は criteria_empty" \
  "criteria_empty" "$(blockers_of ready-for-promotion "$criteria_empty")"
assert_eq "空配列では criteriaConsistent を真にしない" \
  "false" "$(term_of ready-for-promotion "$criteria_empty" criteriaConsistent)"
assert_eq "空配列では criteriaNoHumanReview も真にしない" \
  "false" "$(term_of ready-for-promotion "$criteria_empty" criteriaNoHumanReview)"

criteria_null='{"allMerged":true,"criteria":null,"qualityCheck":{"skipped":true},"e2e":{"skipped":true},"guaranteeCheck":{"skipped":true}}'
assert_eq "受入基準が null なら false" "false" "$(decide ready-for-promotion "$criteria_null")"
assert_eq "その blockers は criteria_unknown" \
  "criteria_unknown" "$(blockers_of ready-for-promotion "$criteria_null")"

criteria_no_status='{"allMerged":true,"criteria":[{"id":"AC-1"}],"qualityCheck":{"skipped":true},"e2e":{"skipped":true},"guaranteeCheck":{"skipped":true}}'
assert_eq "status フィールドの無い基準があれば false" \
  "false" "$(decide ready-for-promotion "$criteria_no_status")"

echo ""
echo "=== (7) CLI 契約（exit code と JSON の一致・実行前提の欠落） ==="

assert_eq "判定 true なら exit 0" "0" "$(run_exit all-consistent "$(ac_input 1 1 1 1)")"
assert_eq "判定 false なら exit 1" "1" "$(run_exit all-consistent "$(ac_input 1 1 1 0)")"
assert_eq "ready の判定 true なら exit 0" "0" "$(run_exit ready-for-promotion "$(rp_input 1 1 1 1 1 1)")"
assert_eq "ready の判定 false なら exit 1" "1" "$(run_exit ready-for-promotion "$(rp_input 1 1 1 1 1 0)")"

# exit code と JSON の真偽が食い違わないこと（呼び出し側の突き合わせが成立する）
mismatch=0
for combo in "1 1 1 1" "0 1 1 1" "1 0 1 1" "1 1 0 1" "1 1 1 0"; do
  # shellcheck disable=SC2086 # combo は意図的に単語分割して4引数として渡す
  body="$(ac_input $combo)"
  json_value="$(decide all-consistent "$body")"
  exit_code="$(run_exit all-consistent "$body")"
  expected_exit="1"
  [ "$json_value" = "true" ] && expected_exit="0"
  [ "$exit_code" != "$expected_exit" ] && mismatch=$((mismatch + 1))
done
assert_eq "exit code と JSON の判定値が全経路で一致する" "0" "$mismatch"

missing_key_out="$(printf '%s' '{"guarantees":null}' | bash "$TARGET_SCRIPT" all-consistent 2>/dev/null)"
missing_key_exit=$?
assert_eq "必須キーの欠落は exit 2（false ではない）" "2" "$missing_key_exit"
assert_eq "必須キーの欠落時の stdout は空（未検査を判定結果に見せない）" "" "$missing_key_out"

bad_json_out="$(printf '%s' 'not a json' | bash "$TARGET_SCRIPT" all-consistent 2>/dev/null)"
bad_json_exit=$?
assert_eq "JSON としてパースできない入力は exit 2" "2" "$bad_json_exit"
assert_eq "その場合の stdout は空" "" "$bad_json_out"

empty_out="$(printf '%s' '' | bash "$TARGET_SCRIPT" all-consistent 2>/dev/null)"
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

too_many_exit="$(printf '%s' '{}' | bash "$TARGET_SCRIPT" all-consistent extra >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "引数が多すぎる場合は exit 2" "2" "$too_many_exit"

unknown_opt_exit="$(printf '%s' '{}' | bash "$TARGET_SCRIPT" --bogus >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "未知オプションは exit 2" "2" "$unknown_opt_exit"

# --input でファイルからも読める
TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() { rm -rf "$TMP_ROOT"; }
trap cleanup_tmp_root EXIT
printf '%s' "$(ac_input 1 1 1 1)" > "${TMP_ROOT}/input.json"
file_out="$(bash "$TARGET_SCRIPT" all-consistent --input "${TMP_ROOT}/input.json" 2>/dev/null)"
assert_eq "--input のファイルからも判定できる" "true" "$(printf '%s' "$file_out" | jq -r '.allConsistent')"
bad_input_exit="$(bash "$TARGET_SCRIPT" all-consistent --input "${TMP_ROOT}/nope.json" >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "--input のファイルが無い場合は exit 2" "2" "$bad_input_exit"

echo ""
echo "=== (8) spec との整合（項の表・blockers 語彙の逐語照合） ==="

# terms のキーが spec の項の表に逐語で載っていること（項を足して spec を更新し忘れると落ちる）
spec_term_failures=""
for term in "${AC_TERM_NAMES[@]}"; do
  grep -qF -- "\`${term}\`" "$SPEC_FILE" || spec_term_failures="${spec_term_failures}${term} "
done
for term in allMerged criteriaConsistent criteriaNoHumanReview qualityOk e2eOk guaranteeOk; do
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
  "34" "$(printf '%s\n' "$impl_blockers" | grep -c .)"

spec_blocker_failures=""
for code in targets_unknown targets_invalid targets_duplicated guarantees_unknown guarantees_invalid \
  guarantee_id_missing targets_not_covered index_missing index_invalid index_error index_not_pass \
  verdict_missing verdict_not_consistent human_review_invalid human_review_present \
  not_all_merged criteria_unknown criteria_invalid criteria_empty criteria_status_missing \
  criteria_not_consistent criteria_needs_human_review quality_check_missing quality_check_invalid \
  quality_result_missing quality_not_pass e2e_missing e2e_invalid e2e_result_missing e2e_not_passed \
  guarantee_check_missing guarantee_check_invalid guarantee_result_missing guarantee_not_consistent; do
  grep -qF -- "\`${code}\`" "$SPEC_FILE" || spec_blocker_failures="${spec_blocker_failures}${code} "
  grep -qF -- "\"${code}\"" "$TARGET_SCRIPT" || spec_blocker_failures="${spec_blocker_failures}${code}(impl) "
done
assert_eq "blockers の語彙が spec と実装の双方に存在する" "" "$spec_blocker_failures"

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
