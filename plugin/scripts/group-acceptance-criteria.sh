#!/bin/bash
# group-acceptance-criteria.sh
# 使い方: group-acceptance-criteria.sh --max-per-group <N> [--input <file>]
# /promote-verify の Step 3-5 が呼ぶ。受入基準を「1 体のエージェントが受け持つまとまり」へ分ける。
# 材料（基準の一覧・子 Issue ごとの受け持ち）は stdin の JSON（または --input のファイル）で受け取り、
# まとまりの一覧・重なり・無視した ID を stdout に JSON で1個返す。
# 仕様の正本は scripts/specs/group-acceptance-criteria.md を参照。
#
# なぜスクリプトに切り出すか（実装を読む人向けの注記）:
# - まとまりの作り方（手がかりの優先・上限での分割・重なりの寄せ先）を散文のままにすると、
#   試験が効かない（判定式を promotion-decision.sh へ出しているのと同じ理由）。
# - 「どの基準もちょうど 1 つのまとまりに入る」ことを、出力の前に実装として確かめる
#   （取りこぼし・二重の受け持ちを黙って通さない）。
# - 上限の既定値はここに持たない。正本は skills/promote-verify/SKILL.md の 1 か所で、
#   引数 --max-per-group で受け取る（2 か所に書くと食い違う）。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 2
}

# 終了コード（scripts/specs/group-acceptance-criteria.md と一致させること）
GROUP_AC_EX_OK=0     # まとまりを作れた（基準 0 件の status: "no_criteria" を含む）
GROUP_AC_EX_PREREQ=2 # 実行前提の欠落（jq 不在・引数不正・入力が JSON でない・入力の形が違う）

# まとまりを作る jq プログラム。$max（数値）を引数に取る。
# 入力の形が違うときは {error, detail} を返し、main() が exit 2 にする。
read -r -d '' GROUP_AC_JQ <<'JQPROG'
# 配列を、キーの初出順を保ったまま、キーごとの配列へ分ける（jq の group_by は並べ替えるので使わない）。
def group_stable(f):
  reduce .[] as $x ({keys: [], m: {}};
    ($x | f | tojson) as $k
    | if .m | has($k) then .m[$k] += [$x] else .keys += [$k] | .m[$k] = [$x] end)
  | . as $s
  | [$s.keys[] | $s.m[.]];

# 配列を、並び順のまま $n 件ごとに割る。
def chunk($n): . as $a | [range(0; length; $n) | $a[.:(. + $n)]];

# 配列の重複を、初出順を保ったまま除く。
def uniq_stable: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);

# 1 つのまとまり候補（同じ節の基準の配列）を上限で割り、まとまりの形にする。
def to_groups($cue; $child; $max):
  .[0].section as $section
  | (if $cue == "subheading" then .[0].subheading else null end) as $subheading
  | (map(.id) | chunk($max)) as $parts
  | [range(0; $parts | length) as $i
     | { cue: $cue, childIssue: $child, section: $section, subheading: $subheading,
         part: ($i + 1), parts: ($parts | length), criteria: $parts[$i] }];

. as $in
| if (type != "object") then { error: "input must be a JSON object" }
  elif (has("criteria") | not) then { error: "missing required key", detail: "criteria" }
  elif (.criteria | type) != "array" then { error: "criteria must be an array" }
  elif ([.criteria[] | select((type != "object") or ((.id? | type) != "string") or ((.id | length) == 0))] | length) > 0
    then { error: "each criterion must be an object with a non-empty string id" }
  elif ([.criteria[] | select((.section? | type) as $t | ($t != "string" and $t != "null"))] | length) > 0
    then { error: "criterion.section must be a string or null" }
  elif ([.criteria[] | select((.subheading? | type) as $t | ($t != "string" and $t != "null"))] | length) > 0
    then { error: "criterion.subheading must be a string or null" }
  elif ((.criteria | map(.id)) as $ids | ($ids | length) != ($ids | unique | length))
    then { error: "criteria ids must be unique" }
  elif ((.children? // []) | type) != "array" then { error: "children must be an array" }
  elif ([(.children? // [])[] | select(
          (type != "object")
          or ((.number? | type) != "number") or (.number != (.number | floor)) or (.number < 1)
          or ((.criteria? | type) != "array")
          or ([.criteria[]? | select(type != "string")] | length) > 0)] | length) > 0
    then { error: "each child must be an object with a positive integer number and a criteria array of strings" }
  elif (((.children? // []) | map(.number)) as $ns | ($ns | length) != ($ns | unique | length))
    then { error: "children numbers must be unique" }
  else
    # 空文字の section・subheading は「無い」（null）にそろえる。
    ($in.criteria | map({
        id,
        section: (if ((.section? // "") == "") then null else .section end),
        subheading: (if ((.subheading? // "") == "") then null else .subheading end)
      })) as $crit
    | (reduce $crit[] as $c ({}; .[$c.id] = true)) as $known
    # 子は番号の小さい順。子の中の ID は重複を除く（同じ子の行に 2 回書かれた ID は 1 回に数える）。
    | (($in.children? // []) | sort_by(.number) | map({number, criteria: (.criteria | uniq_stable)})) as $children
    # 親に無い ID は無視して記録に残す。
    | [ $children[] | .number as $n | .criteria[] | select($known[.] | not) | { id: ., childIssue: $n } ] as $ignored
    # 基準の ID → その基準を挙げた子の番号（小さい順）。
    | (reduce ($children[] | .number as $n | .criteria[] | select($known[.]) | { id: ., n: $n }) as $e
        ({}; .[$e.id] += [$e.n])) as $claims
    # 重なり: 複数の子が挙げた基準は、番号の小さい子のまとまりに 1 回だけ入れる。
    | [ $crit[] | .id as $id | select(($claims[$id] // []) | length > 1)
        | { id: $id, assignedTo: $claims[$id][0], alsoIn: $claims[$id][1:] } ] as $overlaps
    # 手がかり 1（子 Issue の受け持ち）: 並びは親の Issue の並び順。節が違えば分ける。上限で割る。
    | [ $children[] | .number as $n
        | [ $crit[] | select(($claims[.id] // [])[0] == $n) ]
        | group_stable(.section)[]
        | to_groups("child_issue"; $n; $max)[] ] as $child_groups
    # 残り（どの子の受け持ちにも無い基準）。
    | [ $crit[] | select($claims[.id] | not) ] as $rest
    # 手がかり 2 を使えるか: 基準の一覧に小見出しが 1 つでもあるか。
    | ([ $crit[] | select(.subheading != null) ] | length > 0) as $has_subheading
    | (if $has_subheading
       # 手がかり 2（小見出し）: 節と小見出しごと。小見出しの無い基準は節ごとに 1 まとまり。
       then [ $rest | group_stable([.section, .subheading])[] | to_groups("subheading"; null; $max)[] ]
       # 手がかり 3（並び順）: 節ごとに、並び順のまま。
       else [ $rest | group_stable(.section)[] | to_groups("order"; null; $max)[] ]
       end) as $rest_groups
    | ($child_groups + $rest_groups) as $all
    | [ range(0; $all | length) as $i | { index: ($i + 1) } + $all[$i] ] as $groups
    # 自己検査: どの基準も、ちょうど 1 つのまとまりに入っていること。
    | ([ $groups[].criteria[] ] | sort) as $placed
    | if $placed != ($crit | map(.id) | sort) then
        { error: "internal error: grouping lost or duplicated criteria" }
      else
        { status: (if ($crit | length) == 0 then "no_criteria" else "ok" end),
          maxPerGroup: $max,
          groups: $groups,
          overlaps: $overlaps,
          ignoredIds: $ignored,
          summary: {
            criteria: ($crit | length),
            groups: ($groups | length),
            byCue: {
              child_issue: ([ $groups[] | select(.cue == "child_issue") ] | length),
              subheading: ([ $groups[] | select(.cue == "subheading") ] | length),
              order: ([ $groups[] | select(.cue == "order") ] | length)
            }
          } }
      end
  end
JQPROG

print_usage() {
  local prog
  prog="$(basename "$0")"
  {
    echo "Usage: ${prog} --max-per-group <N> [--input <file>]"
    echo "  --max-per-group <N>  1 つのまとまりに入れる基準の件数の上限（1 以上の整数。必須。既定値は持たない）"
    echo "  --input <file>       材料の JSON を読むファイル。省略時は stdin から読む"
    echo "  材料の JSON: {\"criteria\": [{id, section, subheading}], \"children\": [{number, criteria: [id]}]}"
  } >&2
}

# 前提の欠落を stderr（メッセージ＋エラー JSON）に出して exit 2 する。
group_ac_fail() {
  local message="$1" code="$2"
  echo "Error: ${message}" >&2
  jq -n -c --arg error "$code" '{status: "error", error: $error}' >&2 2>/dev/null ||
    printf '%s\n' '{"status":"error","error":"prerequisite failed"}' >&2
  exit "$GROUP_AC_EX_PREREQ"
}

main() {
  local max=""
  local input_file=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        print_usage
        exit 0
        ;;
      --max-per-group)
        if [ "$#" -lt 2 ]; then
          print_usage
          group_ac_fail "--max-per-group requires a value" "--max-per-group requires a value"
        fi
        max="$2"
        shift 2
        ;;
      --input)
        if [ "$#" -lt 2 ]; then
          print_usage
          group_ac_fail "--input requires a value" "--input requires a value"
        fi
        input_file="$2"
        shift 2
        ;;
      *)
        print_usage
        group_ac_fail "unknown argument: $1" "unknown argument"
        ;;
    esac
  done

  if ! check_jq '{"status":"error","error":"jq not found"}'; then
    exit "$GROUP_AC_EX_PREREQ"
  fi

  if [ -z "$max" ]; then
    print_usage
    group_ac_fail "--max-per-group を指定してください（既定値は持たない。正本は skills/promote-verify/SKILL.md）" "--max-per-group is required"
  fi
  if ! [[ "$max" =~ ^[1-9][0-9]*$ ]]; then
    group_ac_fail "--max-per-group は 1 以上の整数で指定してください: '${max}'" "--max-per-group must be a positive integer"
  fi

  local input
  if [ -n "$input_file" ]; then
    if [ ! -f "$input_file" ] || [ ! -r "$input_file" ]; then
      group_ac_fail "入力ファイルが読めません: ${input_file}" "input not readable"
    fi
    input="$(cat "$input_file")"
  else
    input="$(cat)"
  fi

  if [ -z "$input" ]; then
    group_ac_fail "材料（JSON）が渡されていません" "empty input"
  fi

  # 入力がちょうど 1 つの JSON 値であること（値が 2 つ以上あると、jq は値ごとに評価して
  # JSON を複数出してしまう。「stdout には JSON を1個だけ」の規約を守る）。
  local value_count
  if ! value_count="$(jq -s 'length' <<<"$input" 2>/dev/null)"; then
    group_ac_fail "材料が JSON として読めません" "input is not valid JSON"
  fi
  if [ "$value_count" != "1" ]; then
    group_ac_fail "材料は JSON オブジェクト 1 つで渡してください（値の数: ${value_count}）" "input must be exactly one JSON value"
  fi

  local output
  if ! output="$(jq --argjson max "$max" "$GROUP_AC_JQ" <<<"$input" 2>/dev/null)"; then
    group_ac_fail "まとまりを作る処理に失敗しました" "grouping failed"
  fi

  if jq -e 'has("error")' >/dev/null 2>&1 <<<"$output"; then
    echo "Error: $(jq -r '.error + (if .detail then ": " + .detail else "" end)' <<<"$output")" >&2
    jq -c '{status: "error", error: .error}' <<<"$output" >&2
    exit "$GROUP_AC_EX_PREREQ"
  fi

  printf '%s\n' "$output"
  exit "$GROUP_AC_EX_OK"
}

# `source` された場合は main を実行しない（テストからの読み込みを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
