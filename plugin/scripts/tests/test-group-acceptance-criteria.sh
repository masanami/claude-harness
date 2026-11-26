#!/bin/bash
# test-group-acceptance-criteria.sh
# scripts/group-acceptance-criteria.sh（/promote-verify が受入基準をまとまりへ分けるスクリプト）を
# CLI として呼び、手がかりの優先・上限での分割・重なり・親に無い ID の扱いを固定する（#423）。
# 末尾で、スキルの本文（skills/promote-verify/SKILL.md）とエージェント定義が、まとまり単位の
# 手順と食い違っていないことも固定する（散文と実装の食い違いの再発防止）。
#
# 実行方法: bash scripts/tests/test-group-acceptance-criteria.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../group-acceptance-criteria.sh"
EXTRACT_SCRIPT="${SCRIPT_DIR}/../extract-acceptance-criteria.sh"
SPEC_FILE="${SCRIPT_DIR}/../specs/group-acceptance-criteria.md"
PV_SKILL="${REPO_ROOT}/skills/promote-verify/SKILL.md"
DOC_VERIFIER="${REPO_ROOT}/agents/doc-verifier.md"
FINDING_VERIFIER="${REPO_ROOT}/agents/finding-verifier.md"

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

# 材料の JSON と上限を渡してスクリプトを呼び、stdout を返す（stderr は捨てる）。
group() {
  local max="$1" input="$2"
  bash "$TARGET_SCRIPT" --max-per-group "$max" <<<"$input" 2>/dev/null
}

# まとまりを「手がかり:子の番号:節:小見出し:part/parts=ID,ID」の形で 1 行 1 まとまりにする。
shape() {
  jq -r '.groups[] | "\(.cue):\(.childIssue // "-"):\(.section // "-"):\(.subheading // "-"):\(.part)/\(.parts)=\(.criteria | join(","))"'
}

# 基準 n 件（AC-1..AC-n）を、節・小見出しを指定して作る。引数: 開始番号 終了番号 節 小見出し（"" は null）
crit_range() {
  local from="$1" to="$2" section="$3" subheading="$4"
  jq -n -c --argjson from "$from" --argjson to "$to" --arg section "$section" --arg sub "$subheading" \
    '[range($from; $to + 1) | {id: "AC-\(.)", text: "t\(.)", checked: false, section: $section, subheading: (if $sub == "" then null else $sub end)}]'
}

echo "=== (1) 手がかり 1: 子 Issue の受け持ちでまとめる ==="

C6="$(crit_range 1 6 受入基準 "")"
IN1="$(jq -n -c --argjson c "$C6" '{criteria: $c, children: [{number: 20, criteria: ["AC-4", "AC-5"]}, {number: 10, criteria: ["AC-1", "AC-2", "AC-3"]}]}')"
OUT1="$(group 10 "$IN1")"
assert_eq "子ごとに 1 まとまり（番号の小さい子が先）。残りは別のまとまり" \
  "child_issue:10:受入基準:-:1/1=AC-1,AC-2,AC-3
child_issue:20:受入基準:-:1/1=AC-4,AC-5
order:-:受入基準:-:1/1=AC-6" "$(shape <<<"$OUT1")"
assert_eq "index は 1 からの通し番号" "1 2 3" "$(jq -r '[.groups[].index] | join(" ")' <<<"$OUT1")"
assert_eq "status は ok" "ok" "$(jq -r '.status' <<<"$OUT1")"
assert_eq "maxPerGroup は渡した上限" "10" "$(jq -r '.maxPerGroup' <<<"$OUT1")"
assert_eq "summary: 基準 6 件・まとまり 3・手がかりごとの数" \
  '{"criteria":6,"groups":3,"byCue":{"child_issue":2,"subheading":0,"order":1}}' "$(jq -c '.summary' <<<"$OUT1")"

echo ""
echo "=== (2) 手がかり 1 のまとまりの中の並びは、親の Issue の並び順（子の行に書かれた順ではない） ==="

IN2="$(jq -n -c --argjson c "$C6" '{criteria: $c, children: [{number: 10, criteria: ["AC-5", "AC-1", "AC-3"]}]}')"
assert_eq "子の行が AC-5, AC-1, AC-3 でも、まとまりは AC-1, AC-3, AC-5" \
  "AC-1,AC-3,AC-5" "$(group 10 "$IN2" | jq -r '.groups[0].criteria | join(",")')"

echo ""
echo "=== (3) 重なり: 複数の子が挙げた基準は、番号の小さい子に 1 回だけ入れて記録に残す ==="

IN3="$(jq -n -c --argjson c "$C6" '{criteria: $c, children: [{number: 30, criteria: ["AC-2", "AC-3"]}, {number: 10, criteria: ["AC-1", "AC-2"]}, {number: 20, criteria: ["AC-2"]}]}')"
OUT3="$(group 10 "$IN3")"
assert_eq "AC-2 は番号の小さい子（#10）のまとまりだけに入る。全部が重なった子（#20）はまとまりを作らない" \
  "child_issue:10:受入基準:-:1/1=AC-1,AC-2
child_issue:30:受入基準:-:1/1=AC-3
order:-:受入基準:-:1/1=AC-4,AC-5,AC-6" "$(shape <<<"$OUT3")"
assert_eq "重なりを記録する（入れた子・ほかに挙げた子）" \
  '[{"id":"AC-2","assignedTo":10,"alsoIn":[20,30]}]' "$(jq -c '.overlaps' <<<"$OUT3")"
assert_eq "AC-2 がまとまりに入るのは 1 回だけ" "1" "$(jq '[.groups[].criteria[] | select(. == "AC-2")] | length' <<<"$OUT3")"

IN3B="$(jq -n -c --argjson c "$C6" '{criteria: $c, children: [{number: 10, criteria: ["AC-1", "AC-1", "AC-2"]}]}')"
OUT3B="$(group 10 "$IN3B")"
assert_eq "同じ子の行に 2 回書かれた ID は 1 回に数える（重なりにしない）" \
  "AC-1,AC-2|[]" "$(jq -r '(.groups[0].criteria | join(",")) + "|" + (.overlaps | tojson)' <<<"$OUT3B")"

echo ""
echo "=== (4) 親に無い ID は無視して記録に残す。受け持ちの無い子はまとまりを作らない ==="

IN4="$(jq -n -c --argjson c "$C6" '{criteria: $c, children: [{number: 10, criteria: ["AC-1", "AC-99"]}, {number: 20, criteria: []}, {number: 30, criteria: ["AC-77"]}]}')"
OUT4="$(group 10 "$IN4")"
assert_eq "親に無い ID はまとまりに入らない。「なし」の子（空の配列）・無視した ID だけの子はまとまりを作らない" \
  "child_issue:10:受入基準:-:1/1=AC-1
order:-:受入基準:-:1/1=AC-2,AC-3,AC-4,AC-5,AC-6" "$(shape <<<"$OUT4")"
assert_eq "無視した ID を、挙げた子の番号つきで記録する" \
  '[{"id":"AC-99","childIssue":10},{"id":"AC-77","childIssue":30}]' "$(jq -c '.ignoredIds' <<<"$OUT4")"

echo ""
echo "=== (5) 手がかり 2: どの子の受け持ちにも無い基準を、節と小見出しごとにまとめる ==="

C_SUB="$(jq -n -c '[
  {id: "AC-1", section: "受入基準", subheading: null},
  {id: "AC-2", section: "受入基準", subheading: "ログイン"},
  {id: "AC-3", section: "受入基準", subheading: "ログイン"},
  {id: "AC-4", section: "受入基準", subheading: "通知"},
  {id: "AC-5", section: "受入基準", subheading: "ログイン"},
  {id: "AC-6", section: "受入基準", subheading: null}
]')"
IN5="$(jq -n -c --argjson c "$C_SUB" '{criteria: $c, children: []}')"
OUT5="$(group 10 "$IN5")"
assert_eq "小見出しごと（初出順）。小見出しの無い基準は「小見出し無し」の 1 まとまり。小さいまとまりを混ぜない" \
  "subheading:-:受入基準:-:1/1=AC-1,AC-6
subheading:-:受入基準:ログイン:1/1=AC-2,AC-3,AC-5
subheading:-:受入基準:通知:1/1=AC-4" "$(shape <<<"$OUT5")"

IN5B="$(jq -n -c --argjson c "$C_SUB" '{criteria: $c}')"
assert_eq "children を省いても同じ（子の Issue に分けていない仕事）" \
  "$(shape <<<"$OUT5")" "$(group 10 "$IN5B" | shape)"

echo ""
echo "=== (6) 手がかりの優先: 1 → 2。子の受け持ちにある基準は、小見出しのまとまりに入れない ==="

IN6="$(jq -n -c --argjson c "$C_SUB" '{criteria: $c, children: [{number: 7, criteria: ["AC-2", "AC-4"]}]}')"
OUT6="$(group 10 "$IN6")"
assert_eq "子のまとまりは小見出しをまたぐ（subheading は null）。残りだけを小見出しでまとめる" \
  "child_issue:7:受入基準:-:1/1=AC-2,AC-4
subheading:-:受入基準:-:1/1=AC-1,AC-6
subheading:-:受入基準:ログイン:1/1=AC-3,AC-5" "$(shape <<<"$OUT6")"

IN6B="$(jq -n -c --argjson c "$C_SUB" '{criteria: $c, children: [{number: 7, criteria: ["AC-2", "AC-3", "AC-4", "AC-5"]}]}')"
assert_eq "残りが小見出しの前の基準だけでも、親に小見出しがあれば手がかり 2（小見出し無しのまとまり）" \
  "child_issue:7:受入基準:-:1/1=AC-2,AC-3,AC-4,AC-5
subheading:-:受入基準:-:1/1=AC-1,AC-6" "$(group 10 "$IN6B" | shape)"

echo ""
echo "=== (7) 手がかり 3: 小見出しが 1 つも無いときは並び順 ==="

IN7="$(jq -n -c --argjson c "$(crit_range 1 5 受入基準 "")" '{criteria: $c, children: []}')"
assert_eq "並び順のまま 1 まとまり（上限以内）" \
  "order:-:受入基準:-:1/1=AC-1,AC-2,AC-3,AC-4,AC-5" "$(group 10 "$IN7" | shape)"
assert_eq "並び順のまま上限ごとに割る" \
  "order:-:受入基準:-:1/3=AC-1,AC-2
order:-:受入基準:-:2/3=AC-3,AC-4
order:-:受入基準:-:3/3=AC-5" "$(group 2 "$IN7" | shape)"

echo ""
echo "=== (8) 上限での分割: どの手がかりでも、並び順のまま上限ごとに割る ==="

C25="$(crit_range 1 25 受入基準 "")"
IN8="$(jq -n -c --argjson c "$C25" '{criteria: $c, children: [{number: 5, criteria: [range(1; 24) | "AC-\(.)"]}]}')"
OUT8="$(group 10 "$IN8")"
assert_eq "手がかり 1 のまとまり（23 件）は 10・10・3 に割る。残り（2 件）を端数のまとまりに混ぜない" \
  "child_issue:5:1/3:10 child_issue:5:2/3:10 child_issue:5:3/3:3 order:-:1/1:2" \
  "$(jq -r '[.groups[] | "\(.cue):\(.childIssue // "-"):\(.part)/\(.parts):\(.criteria | length)"] | join(" ")' <<<"$OUT8")"
assert_eq "割ったまとまりの中身は並び順のまま（2 つ目は AC-11 から AC-20）" \
  "AC-11 AC-20" "$(jq -r '.groups[1].criteria | "\(.[0]) \(.[-1])"' <<<"$OUT8")"
assert_eq "どのまとまりも上限以内" "0" "$(jq '[.groups[] | select((.criteria | length) > 10)] | length' <<<"$OUT8")"
assert_eq "ちょうど上限の件数は割らない" "1" \
  "$(group 10 "$(jq -n -c --argjson c "$(crit_range 1 10 受入基準 "")" '{criteria: $c}')" | jq '.groups | length')"
assert_eq "上限 +1 件は 2 つに割る（10・1）" "10,1" \
  "$(group 10 "$(jq -n -c --argjson c "$(crit_range 1 11 受入基準 "")" '{criteria: $c}')" | jq -r '[.groups[].criteria | length] | join(",")')"

C_SUB12="$(jq -n -c '[range(1; 13) | {id: "AC-\(.)", section: "受入基準", subheading: (if . <= 11 then "大きい" else "小さい" end)}]')"
assert_eq "手がかり 2 のまとまりも上限で割る。割った端数（1 件）と次の小見出し（1 件）を混ぜない" \
  "subheading:-:受入基準:大きい:1/2=AC-1,AC-2,AC-3,AC-4,AC-5,AC-6,AC-7,AC-8,AC-9,AC-10
subheading:-:受入基準:大きい:2/2=AC-11
subheading:-:受入基準:小さい:1/1=AC-12" "$(group 10 "$(jq -n -c --argjson c "$C_SUB12" '{criteria: $c}')" | shape)"

echo ""
echo "=== (9) 節が違う基準を同じまとまりにしない（どの手がかりでも） ==="

C_SEC="$(jq -n -c '[
  {id: "AC-1", section: "受入基準", subheading: null},
  {id: "AC-2", section: "受入基準", subheading: null},
  {id: "AC-3", section: "完了条件", subheading: null},
  {id: "AC-4", section: "完了条件", subheading: null}
]')"
assert_eq "手がかり 3: 節ごとに分ける" \
  "order:-:受入基準:-:1/1=AC-1,AC-2
order:-:完了条件:-:1/1=AC-3,AC-4" "$(group 10 "$(jq -n -c --argjson c "$C_SEC" '{criteria: $c}')" | shape)"
assert_eq "手がかり 1: 1 つの子が両方の節の基準を持っていても、節ごとに分ける" \
  "child_issue:9:受入基準:-:1/1=AC-2
child_issue:9:完了条件:-:1/1=AC-3
order:-:受入基準:-:1/1=AC-1
order:-:完了条件:-:1/1=AC-4" \
  "$(group 10 "$(jq -n -c --argjson c "$C_SEC" '{criteria: $c, children: [{number: 9, criteria: ["AC-2", "AC-3"]}]}')" | shape)"
C_SEC_SUB="$(jq -n -c '[
  {id: "AC-1", section: "受入基準", subheading: "同じ名前"},
  {id: "AC-2", section: "完了条件", subheading: "同じ名前"},
  {id: "AC-3", section: "完了条件", subheading: null}
]')"
assert_eq "手がかり 2: 小見出しの文が同じでも、節が違えば分ける。小見出し無しも節ごと" \
  "subheading:-:受入基準:同じ名前:1/1=AC-1
subheading:-:完了条件:同じ名前:1/1=AC-2
subheading:-:完了条件:-:1/1=AC-3" "$(group 10 "$(jq -n -c --argjson c "$C_SEC_SUB" '{criteria: $c}')" | shape)"

echo ""
echo "=== (10) 完全性: どの基準も、ちょうど 1 つのまとまりに入る ==="

completeness_failures=""
for max in 1 2 3 7 10; do
  for input in "$IN1" "$IN3" "$IN4" "$IN5" "$IN6" "$IN8"; do
    out="$(group "$max" "$input")"
    expected="$(jq -c '[.criteria[].id] | sort' <<<"$input")"
    actual="$(jq -c '[.groups[].criteria[]] | sort' <<<"$out")"
    [ "$expected" = "$actual" ] || completeness_failures="${completeness_failures}max=${max} "
    over="$(jq --argjson max "$max" '[.groups[] | select((.criteria | length) > $max or (.criteria | length) == 0)] | length' <<<"$out")"
    [ "$over" = "0" ] || completeness_failures="${completeness_failures}max=${max}(size) "
  done
done
assert_eq "上限 1・2・3・7・10 × 6 つの材料で、全件がちょうど 1 回ずつ入り、空・上限超えのまとまりが無い" "" "$completeness_failures"

echo ""
echo "=== (11) 抜き出しのスクリプトの出力を、そのまま材料にできる ==="

read -r -d '' FIXTURE_PARENT <<'EOF'
## 受入基準

- [ ] 小見出しの前の基準

### ログイン

- [ ] ログインできる
- [x] 失敗時にエラーが出る

### 通知

- [ ] 通知が届く

## 補足
EOF
EXTRACTED="$(bash "$EXTRACT_SCRIPT" --stdin <<<"$FIXTURE_PARENT")"
IN11="$(jq -c '{criteria: .criteria, children: [{number: 3, criteria: ["AC-4"]}]}' <<<"$EXTRACTED")"
assert_eq "extract-acceptance-criteria の criteria（id・text・checked・section・subheading）を渡してまとまりを作れる" \
  "child_issue:3:受入基準:-:1/1=AC-4
subheading:-:受入基準:-:1/1=AC-1
subheading:-:受入基準:ログイン:1/1=AC-2,AC-3" "$(group 10 "$IN11" | shape)"

echo ""
echo "=== (12) 基準 0 件・古い形の材料 ==="

OUT12="$(group 10 '{"criteria":[],"children":[{"number":1,"criteria":["AC-1"]}]}')"
assert_eq "基準 0 件は status: no_criteria・まとまり無し（exit 0）" \
  "no_criteria|0" "$(jq -r '.status + "|" + (.groups | length | tostring)' <<<"$OUT12")"
assert_eq "基準 0 件でも、親に無い ID は記録に残す" '[{"id":"AC-1","childIssue":1}]' "$(jq -c '.ignoredIds' <<<"$OUT12")"
assert_eq "section・subheading の無い材料（id だけ）は、節なし・小見出し無しとして並び順でまとめる" \
  "order:-:-:-:1/1=AC-1,AC-2" "$(group 10 '{"criteria":[{"id":"AC-1"},{"id":"AC-2"}]}' | shape)"
assert_eq "空文字の subheading は小見出し無しと同じに扱う" \
  "order:-:受入基準:-:1/1=AC-1" "$(group 10 '{"criteria":[{"id":"AC-1","section":"受入基準","subheading":""}]}' | shape)"

echo ""
echo "=== (13) 実行前提の欠落は exit 2・stdout に何も出さない ==="

prereq_failures=""
check_prereq() {
  local label="$1" input="$2"
  shift 2
  local out code
  out="$(bash "$TARGET_SCRIPT" "$@" <<<"$input" 2>/dev/null)"
  code=$?
  if [ "$code" != "2" ] || [ -n "$out" ]; then
    prereq_failures="${prereq_failures}${label}(exit=${code}) "
  fi
}
VALID='{"criteria":[{"id":"AC-1"}]}'
check_prereq "上限なし" "$VALID"
check_prereq "上限が 0" "$VALID" --max-per-group 0
check_prereq "上限が負" "$VALID" --max-per-group -1
check_prereq "上限が数でない" "$VALID" --max-per-group ten
check_prereq "上限が小数" "$VALID" --max-per-group 1.5
check_prereq "上限の値なし" "$VALID" --max-per-group
check_prereq "知らない引数" "$VALID" --max-per-group 10 --unknown
check_prereq "読めない入力ファイル" "$VALID" --max-per-group 10 --input /nonexistent/gac-input.json
check_prereq "空の入力" "" --max-per-group 10
check_prereq "JSON でない" "not json" --max-per-group 10
check_prereq "JSON が 2 つ" '{"criteria":[]} {"criteria":[]}' --max-per-group 10
check_prereq "オブジェクトでない" '[]' --max-per-group 10
check_prereq "criteria が無い" '{"children":[]}' --max-per-group 10
check_prereq "criteria が配列でない" '{"criteria":"AC-1"}' --max-per-group 10
check_prereq "基準の id が無い" '{"criteria":[{"text":"x"}]}' --max-per-group 10
check_prereq "基準の id が空" '{"criteria":[{"id":""}]}' --max-per-group 10
check_prereq "基準の id が重複" '{"criteria":[{"id":"AC-1"},{"id":"AC-1"}]}' --max-per-group 10
check_prereq "section が文字列でない" '{"criteria":[{"id":"AC-1","section":1}]}' --max-per-group 10
check_prereq "section が false" '{"criteria":[{"id":"AC-1","section":false}]}' --max-per-group 10
check_prereq "subheading が false" '{"criteria":[{"id":"AC-1","subheading":false}]}' --max-per-group 10
check_prereq "subheading が文字列でない" '{"criteria":[{"id":"AC-1","subheading":["x"]}]}' --max-per-group 10
check_prereq "children が配列でない" '{"criteria":[{"id":"AC-1"}],"children":{}}' --max-per-group 10
check_prereq "子の番号が無い" '{"criteria":[{"id":"AC-1"}],"children":[{"criteria":["AC-1"]}]}' --max-per-group 10
check_prereq "子の番号が文字列" '{"criteria":[{"id":"AC-1"}],"children":[{"number":"10","criteria":["AC-1"]}]}' --max-per-group 10
check_prereq "子の番号が 0" '{"criteria":[{"id":"AC-1"}],"children":[{"number":0,"criteria":["AC-1"]}]}' --max-per-group 10
check_prereq "子の criteria が無い" '{"criteria":[{"id":"AC-1"}],"children":[{"number":10}]}' --max-per-group 10
check_prereq "子の criteria が文字列（行のまま）" '{"criteria":[{"id":"AC-1"}],"children":[{"number":10,"criteria":"AC-1, AC-3"}]}' --max-per-group 10
check_prereq "子の criteria の要素が文字列でない" '{"criteria":[{"id":"AC-1"}],"children":[{"number":10,"criteria":[1]}]}' --max-per-group 10
check_prereq "子の番号が重複" '{"criteria":[{"id":"AC-1"}],"children":[{"number":10,"criteria":[]},{"number":10,"criteria":[]}]}' --max-per-group 10
assert_eq "実行前提の欠落 29 種は、どれも exit 2 で stdout が空" "" "$prereq_failures"

ERR_JSON="$(bash "$TARGET_SCRIPT" --max-per-group 10 <<<'{"criteria":"x"}' 2>&1 >/dev/null | tail -1)"
assert_eq "失敗時は stderr の末尾にエラー JSON（status: error）を出す" "error" "$(jq -r '.status' <<<"$ERR_JSON" 2>/dev/null)"

TMP_INPUT="$(mktemp "${TMPDIR:-/tmp}/gac-test-input.XXXXXX")"
printf '%s' "$IN1" >"$TMP_INPUT"
assert_eq "--input のファイルからも読める（stdin と同じ結果）" \
  "$(shape <<<"$OUT1")" "$(bash "$TARGET_SCRIPT" --max-per-group 10 --input "$TMP_INPUT" </dev/null 2>/dev/null | shape)"
rm -f "$TMP_INPUT"

HELP_CODE=0
bash "$TARGET_SCRIPT" --help >/dev/null 2>&1 || HELP_CODE=$?
assert_eq "--help は exit 0" "0" "$HELP_CODE"

echo ""
echo "=== (14) 仕様（spec）と実装の語彙が食い違っていない ==="

assert_eq "spec を読める（読めない状態を pass にしない）" "true" \
  "$(if [ -r "$SPEC_FILE" ]; then echo true; else echo false; fi)"
spec_failures=""
for word in child_issue subheading order childIssue maxPerGroup overlaps assignedTo alsoIn ignoredIds no_criteria byCue; do
  grep -qF -- "$word" "$SPEC_FILE" || spec_failures="${spec_failures}${word} "
  grep -qF -- "$word" "$TARGET_SCRIPT" || spec_failures="${spec_failures}${word}(impl) "
done
assert_eq "出力の項目と値の語彙が spec と実装の双方にある" "" "$spec_failures"

echo ""
echo "=== (15) 呼び出し側の散文（/promote-verify）が、まとまり単位の手順と食い違っていない ==="

assert_eq "/promote-verify の SKILL.md を読める（読めない状態を pass にしない）" "true" \
  "$(if [ -r "$PV_SKILL" ]; then echo true; else echo false; fi)"

count_fixed() { grep -cF -- "$1" "$2"; }
has_fixed() { if grep -qF -- "$1" "$2"; then echo true; else echo false; fi; }

# (a) 上限の正本は 1 か所。スクリプトへは引数で渡す。
# shellcheck disable=SC2016 # バッククォートは照合する文字（シェル展開の対象ではない）
assert_eq "1 体が受け持つ件数の上限の正本（MAX_CRITERIA_PER_GROUP = 10）は、本文に 1 行だけ" "1" \
  "$(grep -cE 'MAX_CRITERIA_PER_GROUP` *= *`?[0-9]+' "$PV_SKILL")"
# shellcheck disable=SC2016
assert_eq "上限の既定は 10" "1" "$(grep -cE 'MAX_CRITERIA_PER_GROUP` *= *`10`' "$PV_SKILL")"
assert_eq "上限をまとまりのスクリプトへ引数で渡す" "true" \
  "$(has_fixed 'claude-harness-run group-acceptance-criteria --max-per-group' "$PV_SKILL")"
assert_eq "スクリプトへ渡す上限を、数の直書きにしていない（正本を 2 か所にしない）" "0" \
  "$(grep -cE -- '--max-per-group +[0-9]' "$PV_SKILL")"
assert_eq "スクリプトの側に上限の既定値を持たない（引数が無ければ exit 2）" "2" \
  "$(bash "$TARGET_SCRIPT" <<<"$VALID" >/dev/null 2>&1; echo $?)"
assert_eq "古い正本（10件ずつのチャンク・チャンクサイズの正本）が残っていない" "0" \
  "$(grep -cE '10件ずつ|チャンクサイズの正本' "$PV_SKILL")"

# (b) 同時に起動する体数の歯止めは、別の値として残す。
# shellcheck disable=SC2016
assert_eq "同時に起動する体数の歯止め（MAX_PARALLEL_AGENTS = 10）は、本文に 1 行だけ" "1" \
  "$(grep -cE 'MAX_PARALLEL_AGENTS` *= *`10`' "$PV_SKILL")"
assert_eq "前の組の結果が揃ってから次の組を始める（バリア）" "true" \
  "$(has_fixed '前の組の全 Task の結果が揃ってから次の組を開始する' "$PV_SKILL")"

# (c) 「基準 1 件につき 1 体」の記述を残さない。
assert_eq "「基準1件につき1体」の記述が残っていない" "0" \
  "$(grep -cE '基準 ?1 ?件につき ?1 ?体' "$PV_SKILL")"
assert_eq "Step 4: 1 まとまりを 1 体の doc-verifier に渡す" "true" \
  "$(has_fixed '**1 まとまりにつき 1 体**' "$PV_SKILL")"
assert_eq "Step 5: Step 4 と同じまとまりのまま渡し、詰め直さない" "true" \
  "$(has_fixed '**Step 4 と同じまとまりのまま**' "$PV_SKILL")"
assert_eq "Step 5: 詰め直さないことを明示している" "true" "$(has_fixed '詰め直さない' "$PV_SKILL")"
# shellcheck disable=SC2016 # バッククォートは照合する文字（シェル展開の対象ではない）
assert_eq "Step 5: consistent が 0 件のまとまりは起動しない" "true" \
  "$(has_fixed '`consistent` が 0 件のまとまりは起動しない' "$PV_SKILL")"

# (d) 手がかりの順と、小さいまとまりを混ぜないこと。
assert_eq "手がかり 1 → 2 → 3 の順で作ることを書いている" "true" \
  "$(has_fixed '手がかり 1 → 2 → 3 の順' "$PV_SKILL")"
assert_eq "小さいまとまりを混ぜないことを書いている" "true" \
  "$(has_fixed '小さいまとまりを、ほかのまとまりと混ぜない' "$PV_SKILL")"
assert_eq "子の Issue の行（対応する受入基準:）を読む手順がある" "true" \
  "$(has_fixed '対応する受入基準:' "$PV_SKILL")"
assert_eq "手がかり 1 のまとまりに、対応する PR の変更ファイルの一覧を添える手順がある" "true" \
  "$(has_fixed 'gh pr diff' "$PV_SKILL")"
# shellcheck disable=SC2016 # バッククォートは照合する文字（シェル展開の対象ではない）
assert_eq "mergedPr が無い・取得できない子は、全体の一覧（nameStatus）だけを渡す" "true" \
  "$(has_fixed '`prFiles` は添えず、全体の一覧（`nameStatus`）だけを渡す' "$PV_SKILL")"

# (e) 取りこぼしの検査（完全性 join）。
assert_eq "完全性 join を残している" "true" "$(has_fixed '完全性 join' "$PV_SKILL")"
assert_eq "応答に無い・形が違う基準は verification_failed にする" "true" \
  "$(has_fixed 'status: "verification_failed"' "$PV_SKILL")"
assert_eq "1 件の失敗で、同じまとまりのほかの基準の結果を捨てない" "true" \
  "$(has_fixed '同じまとまりのほかの基準の結果は捨てない' "$PV_SKILL")"
# shellcheck disable=SC2016 # バッククォートは照合する文字（シェル展開の対象ではない）
assert_eq "どのまとまりにも入っていない基準があれば中断する（材料の写し間違いで基準を落とさない）" "true" \
  "$(has_fixed 'Step 3-1 の `criteria` の全件が、ちょうど 1 回ずつ入っていること' "$PV_SKILL")"
assert_eq "渡していない ID が返ってきたら無視する" "true" \
  "$(has_fixed '渡していない ID' "$PV_SKILL")"

# (f) 非信頼データの区切りは、いまの方式を保つ。
assert_eq "デリミタ（生のダブルクォート入り）を保っている" "true" \
  "$(has_fixed '---"DATA-START"---' "$PV_SKILL")"
assert_eq "データブロックを JSON 文字列としてエンコードする方式を保っている" "true" \
  "$(has_fixed 'JSON文字列としてエンコードしてから' "$PV_SKILL")"

# (g) 報告: 表の列は変えず、まとまりの作り方を足す。
assert_eq "Step 9 の表の列は変えていない" "1" \
  "$(count_fixed '| # | 基準 | 整合状態 | 根拠 | 推奨対応 | 懐疑的検証 | 要人間精査 |' "$PV_SKILL")"
assert_eq "Step 9 に、まとまりをどの手がかりで作ったかを書く欄がある" "true" \
  "$(has_fixed '### まとまりの作り方' "$PV_SKILL")"

echo ""
echo "=== (16) エージェント定義が、複数の基準を受け取って基準ごとに返す形と食い違っていない ==="

assert_eq "doc-verifier.md を読める" "true" "$(if [ -r "$DOC_VERIFIER" ]; then echo true; else echo false; fi)"
assert_eq "finding-verifier.md を読める" "true" "$(if [ -r "$FINDING_VERIFIER" ]; then echo true; else echo false; fi)"
assert_eq "doc-verifier: 複数の対象を渡されたら、対象ごとに 1 件ずつ返す" "true" \
  "$(has_fixed '渡された全件について、対象ごとに1件ずつ' "$DOC_VERIFIER")"
assert_eq "finding-verifier: 「指摘ごとに独立した1体が並列起動されるだけ」と言い切る記述が残っていない" "0" \
  "$(count_fixed '複数の指摘が対象になる場合も、指摘ごとに独立した1体が並列起動されるだけ' "$FINDING_VERIFIER")"
# shellcheck disable=SC2016 # バッククォートは照合する文字（シェル展開の対象ではない）
assert_eq "finding-verifier: /promote-verify ではまとまりごとに 1 体であることを書いている" "true" \
  "$(has_fixed '`/promote-verify` は受入基準のまとまりごとに1体' "$FINDING_VERIFIER")"
assert_eq "finding-verifier: 1 件の判定を、同じ入力のほかの指摘の判定に引きずらせない" "true" \
  "$(has_fixed '指摘ごとに独立に判定' "$FINDING_VERIFIER")"

echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi
exit 0
