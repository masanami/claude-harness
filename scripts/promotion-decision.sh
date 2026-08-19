#!/bin/bash
# promotion-decision.sh
# 使い方: promotion-decision.sh <mode> [--input <file>]
#   mode: all-consistent | ready-for-promotion
# /promote-verify の2つの判定式（Step 5.5-7 の `allConsistent` と Step 7 の
# `readyForPromotion`）を決定的に評価する。判定の材料（各項の入力値）は stdin の JSON で
# 受け取り、総合判定・各項の真偽・落ちた理由コードを stdout に JSON で1個返す。
# 仕様の正本は scripts/specs/promotion-decision.md を参照。
#
# なぜスクリプトに切り出すか（実装を読む人向けの注記）:
# - 判定式が散文のままだと、型検査もテストも効かない。「要人間判定が算出式に接続されていない」
#   「対象0件で全称条件が空虚に真になる」といった論理の穴は、正準文の逐語検査では検出できない
#   （Issue #158 の promote-verify 実装で実際に起きた欠陥がこの2種）。
# - 判定式をここへ寄せることで、入力の組み合わせに対する真理値表テストが書ける
#   （scripts/tests/test-promotion-decision.sh）。散文側には「いつ呼ぶか」と結果の解釈だけが残る。
# - 「未検査」を「調べた結果の0件」に丸めない規律を、実装として強制する:
#   対象リストが null（未確定）・空配列（受入基準ゼロ件）は、全称条件を空虚に真にせず false にする。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 2
}

# 終了コード（scripts/specs/promotion-decision.md と一致させること）
PROMOTION_DECISION_EX_TRUE=0   # 判定が true（allConsistent / readyForPromotion）
PROMOTION_DECISION_EX_FALSE=1  # 判定が false（stdout には JSON を出す）
PROMOTION_DECISION_EX_PREREQ=2 # 実行前提の欠落（jq 不在・引数不正・入力が JSON でない・必須キー欠落）

PROMOTION_DECISION_MODES="all-consistent ready-for-promotion"

# all-consistent モードの判定式（5.5-7 の (a)〜(d)）。
# 項を増減するときは scripts/specs/promotion-decision.md の項の表と
# skills/promote-verify/references/guarantee-consistency.md の算出式も同時に更新すること。
read -r -d '' PROMOTION_DECISION_JQ_ALL_CONSISTENT <<'JQPROG'
. as $in
| (["targets", "guarantees", "index", "humanReview"]) as $required
| [ $required[] | . as $k | select(($in | has($k)) | not) ] as $missing
| if ($missing | length) > 0 then
    { error: "missing required keys", missing: $missing }
  else
    ($in.targets) as $targets
    | ($in.guarantees) as $gs
    | ($in.index) as $index
    | ($in.humanReview) as $hr
    | ( if $targets == null then ["targets_unknown"]
        elif ($targets | type) != "array" then ["targets_invalid"]
        elif ($targets | unique | length) != ($targets | length) then ["targets_duplicated"]
        elif $gs == null then ["guarantees_unknown"]
        elif ($gs | type) != "array" then ["guarantees_invalid"]
        elif ([$gs[] | select((type != "object") or (has("guarantee_id") | not))] | length) > 0 then ["guarantee_id_missing"]
        elif ($targets | sort) != ($gs | map(.guarantee_id) | sort) then ["targets_not_covered"]
        else [] end ) as $a_blockers
    | ( if $index == null then ["index_missing"]
        elif ($index | type) != "object" then ["index_invalid"]
        elif (($index.error) // null) != null then ["index_error"]
        elif ($index.status) != "pass" then ["index_not_pass"]
        else [] end ) as $b_blockers
    | ( if $gs == null then ["guarantees_unknown"]
        elif ($gs | type) != "array" then ["guarantees_invalid"]
        elif ([$gs[] | select((type != "object") or (has("verdict") | not))] | length) > 0 then ["verdict_missing"]
        elif ([$gs[] | select(.verdict != "consistent")] | length) > 0 then ["verdict_not_consistent"]
        else [] end ) as $c_blockers
    | ( if ($hr | type) != "array" then ["human_review_invalid"]
        elif ($hr | length) > 0 then ["human_review_present"]
        else [] end ) as $d_blockers
    | {
        mode: "all-consistent",
        allConsistent: ((($a_blockers + $b_blockers + $c_blockers + $d_blockers) | length) == 0),
        terms: {
          targetsCovered: (($a_blockers | length) == 0),
          indexPass: (($b_blockers | length) == 0),
          allVerdictsConsistent: (($c_blockers | length) == 0),
          noHumanReview: (($d_blockers | length) == 0)
        },
        blockers: (($a_blockers + $b_blockers + $c_blockers + $d_blockers) | unique)
      }
  end
JQPROG

# ready-for-promotion モードの判定式（Step 7 の6項）。
read -r -d '' PROMOTION_DECISION_JQ_READY <<'JQPROG'
. as $in
| (["allMerged", "criteria", "qualityCheck", "e2e", "guaranteeCheck"]) as $required
| [ $required[] | . as $k | select(($in | has($k)) | not) ] as $missing
| if ($missing | length) > 0 then
    { error: "missing required keys", missing: $missing }
  else
    ($in.criteria) as $criteria
    | ($in.qualityCheck) as $qc
    | ($in.e2e) as $e2e
    | ($in.guaranteeCheck) as $gc
    | ( if ($in.allMerged) == true then [] else ["not_all_merged"] end ) as $merged_blockers
    | ( if $criteria == null then ["criteria_unknown"]
        elif ($criteria | type) != "array" then ["criteria_invalid"]
        elif ($criteria | length) == 0 then ["criteria_empty"]
        elif ([$criteria[] | select((type != "object") or (has("status") | not))] | length) > 0 then ["criteria_status_missing"]
        elif ([$criteria[] | select(.status != "consistent")] | length) > 0 then ["criteria_not_consistent"]
        else [] end ) as $status_blockers
    | ( if $criteria == null then ["criteria_unknown"]
        elif ($criteria | type) != "array" then ["criteria_invalid"]
        elif ($criteria | length) == 0 then ["criteria_empty"]
        elif ([$criteria[] | select((type == "object") and (.needsHumanReview == true))] | length) > 0 then ["criteria_needs_human_review"]
        else [] end ) as $review_blockers
    | ( if $qc == null then ["quality_check_missing"]
        elif ($qc | type) != "object" then ["quality_check_invalid"]
        elif ($qc.skipped) == true then []
        elif ($qc | has("result") | not) then ["quality_result_missing"]
        elif ($qc.result) != "pass" then ["quality_not_pass"]
        else [] end ) as $qc_blockers
    | ( if $e2e == null then ["e2e_missing"]
        elif ($e2e | type) != "object" then ["e2e_invalid"]
        elif ($e2e.skipped) == true then []
        elif ($e2e | has("passed") | not) then ["e2e_result_missing"]
        elif ($e2e.passed) != true then ["e2e_not_passed"]
        else [] end ) as $e2e_blockers
    | ( if $gc == null then ["guarantee_check_missing"]
        elif ($gc | type) != "object" then ["guarantee_check_invalid"]
        elif ($gc.skipped) == true then []
        elif ($gc | has("allConsistent") | not) then ["guarantee_result_missing"]
        elif ($gc.allConsistent) != true then ["guarantee_not_consistent"]
        else [] end ) as $gc_blockers
    | ($merged_blockers + $status_blockers + $review_blockers + $qc_blockers + $e2e_blockers + $gc_blockers) as $all_blockers
    | {
        mode: "ready-for-promotion",
        readyForPromotion: (($all_blockers | length) == 0),
        terms: {
          allMerged: (($merged_blockers | length) == 0),
          criteriaConsistent: (($status_blockers | length) == 0),
          criteriaNoHumanReview: (($review_blockers | length) == 0),
          qualityOk: (($qc_blockers | length) == 0),
          e2eOk: (($e2e_blockers | length) == 0),
          guaranteeOk: (($gc_blockers | length) == 0)
        },
        blockers: ($all_blockers | unique)
      }
  end
JQPROG

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} <mode> [--input <file>]

  mode: ${PROMOTION_DECISION_MODES// / | }
  判定の材料は stdin（または --input のファイル）から JSON で1個受け取る。
  stdout に判定結果 JSON を1個出力する。
  exit code: ${PROMOTION_DECISION_EX_TRUE}=判定 true / ${PROMOTION_DECISION_EX_FALSE}=判定 false / ${PROMOTION_DECISION_EX_PREREQ}=実行前提の欠落
EOF
}

# 指定モードの jq プログラムを返す。
# 引数: <mode>
pd_program_for_mode() {
  case "$1" in
    all-consistent) printf '%s' "$PROMOTION_DECISION_JQ_ALL_CONSISTENT" ;;
    ready-for-promotion) printf '%s' "$PROMOTION_DECISION_JQ_READY" ;;
    *) return 1 ;;
  esac
  return 0
}

# 判定結果 JSON から真偽値のフィールド名を返す。
# 引数: <mode>
pd_decision_field_for_mode() {
  case "$1" in
    all-consistent) printf '%s' "allConsistent" ;;
    ready-for-promotion) printf '%s' "readyForPromotion" ;;
    *) return 1 ;;
  esac
  return 0
}

main() {
  local mode=""
  local input_file=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        print_usage
        exit 0
        ;;
      --input)
        if [ "$#" -lt 2 ]; then
          echo "Error: --input requires a value" >&2
          printf '%s\n' '{"status":"error","error":"--input requires a value"}' >&2
          exit "$PROMOTION_DECISION_EX_PREREQ"
        fi
        input_file="$2"
        shift 2
        ;;
      -*)
        echo "Error: unknown option: $1" >&2
        printf '%s\n' '{"status":"error","error":"unknown option"}' >&2
        print_usage
        exit "$PROMOTION_DECISION_EX_PREREQ"
        ;;
      *)
        if [ -n "$mode" ]; then
          echo "Error: too many arguments: $1" >&2
          printf '%s\n' '{"status":"error","error":"too many arguments"}' >&2
          print_usage
          exit "$PROMOTION_DECISION_EX_PREREQ"
        fi
        mode="$1"
        shift
        ;;
    esac
  done

  if ! check_jq '{"status":"error","error":"jq not found"}'; then
    exit "$PROMOTION_DECISION_EX_PREREQ"
  fi

  local program decision_field
  if ! program="$(pd_program_for_mode "$mode")"; then
    echo "Error: mode を指定してください（${PROMOTION_DECISION_MODES// / | }）: '${mode}'" >&2
    printf '%s\n' '{"status":"error","error":"unknown mode"}' >&2
    print_usage
    exit "$PROMOTION_DECISION_EX_PREREQ"
  fi
  decision_field="$(pd_decision_field_for_mode "$mode")"

  local input
  if [ -n "$input_file" ]; then
    if [ ! -f "$input_file" ] || [ ! -r "$input_file" ]; then
      echo "Error: 入力ファイルが読めません: ${input_file}" >&2
      printf '%s\n' '{"status":"error","error":"input not readable"}' >&2
      exit "$PROMOTION_DECISION_EX_PREREQ"
    fi
    input="$(cat "$input_file")"
  else
    input="$(cat)"
  fi

  if [ -z "$input" ]; then
    echo "Error: 判定の材料（JSON）が stdin から渡されていません" >&2
    printf '%s\n' '{"status":"error","error":"empty input"}' >&2
    exit "$PROMOTION_DECISION_EX_PREREQ"
  fi

  local result
  if ! result="$(printf '%s' "$input" | jq -c "$program" 2>/dev/null)"; then
    echo "Error: 入力を JSON として解析できません（または期待するオブジェクトではありません）" >&2
    printf '%s\n' '{"status":"error","error":"input is not valid JSON"}' >&2
    exit "$PROMOTION_DECISION_EX_PREREQ"
  fi

  # 必須キーの欠落は「判定できなかった」であり、false（判定した結果の否）とは別状態。
  # 実行前提の欠落として exit 2 にし、stdout は空にする（未検査を判定結果に見せない）。
  local missing
  missing="$(printf '%s' "$result" | jq -r 'if (.error // null) != null then (.missing // []) | join(",") else "" end')"
  if [ -n "$missing" ]; then
    echo "Error: 判定の材料に必須キーがありません: ${missing}" >&2
    printf '%s\n' "$(printf '%s' "$result" | jq -c '.')" >&2
    exit "$PROMOTION_DECISION_EX_PREREQ"
  fi

  printf '%s\n' "$result"

  if [ "$(printf '%s' "$result" | jq -r ".${decision_field}")" = "true" ]; then
    exit "$PROMOTION_DECISION_EX_TRUE"
  fi

  echo "Error: ${decision_field} は false です（blockers: $(printf '%s' "$result" | jq -r '.blockers | join(", ")')）。詳細は stdout の JSON を参照してください。" >&2
  exit "$PROMOTION_DECISION_EX_FALSE"
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
