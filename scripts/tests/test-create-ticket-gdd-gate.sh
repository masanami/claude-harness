#!/bin/bash
# test-create-ticket-gdd-gate.sh
# GDD P3・create-ticket 系統（要件モードの保証節・裁可ラベル、実装分解モードの保証参照。
# Issue #158）の回帰テスト。2部構成:
#
#  (A) 統合が依存するスクリプト契約・書式の回帰テスト
#      /create-ticket の SKILL.md と references/guarantee-section.md は
#      detect-dev-phase.sh の exit code と phase の語彙、guarantee-index-check.sh の
#      counts.guarantees の数え方（フェンス内・節外を数えない）に依存して分岐する。
#      さらに、本スキルが**書き出す**保証節は下流の /promote-verify（Step 5.5-3）が
#      **読む**ため、書式が食い違うと保証が検証対象から黙って落ちる。ここでは
#      「散文が前提にしている読み取り規則」を参照実装として固定し、スクリプトの実挙動・
#      参照ファイルに載っている保証節テンプレートの双方に掛けて突き合わせる。
#      各スクリプト単体の網羅は test-detect-dev-phase.sh / test-guarantee-index-check.sh の
#      担当であり、ここでは重複させない。
#
#  (B) SKILL.md / 参照ファイル / テンプレートの契約文（正準文）の存在検査と構造不変条件
#      フェーズ分岐・前提未充足での中断・保証 ID の確定手順・裁可ラベルの運用は
#      skills/create-ticket 配下の手順として実装されている（コード側の強制ではない）ため、
#      正準文が逐語で存在することを grep で検査し、手順のドリフト（更新漏れ・緩和）を
#      機械検出する（test-quality-check-gdd-gate.sh / test-promote-verify-gdd-gate.sh と
#      同じ方式）。あわせて default-OFF の構造不変条件（GDD 依存の記述がモード別参照ファイルの
#      GDD 専用ブロック以外へ漏れていないこと）と、エージェントが裁可（guarantee:approved の
#      付与）を行う記述が混入していないことを検査する。
#
# 実行方法: bash scripts/tests/test-create-ticket-gdd-gate.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # 正準文・フィクスチャ内のバッククォートは Markdown のリテラル
# （参照ファイルの逐語検査対象）であり、シェル展開を意図していない
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DETECT_SCRIPT="${REPO_ROOT}/scripts/detect-dev-phase.sh"
GIC_SCRIPT="${REPO_ROOT}/scripts/guarantee-index-check.sh"
SKILL_FILE="${REPO_ROOT}/skills/create-ticket/SKILL.md"
REF_FILE="${REPO_ROOT}/skills/create-ticket/references/guarantee-section.md"
REQ_FILE="${REPO_ROOT}/skills/create-ticket/references/requirement-mode.md"
DEC_FILE="${REPO_ROOT}/skills/create-ticket/references/decompose-mode.md"
TPL_FILE="${REPO_ROOT}/skills/create-ticket/templates/implementation-ticket.md"
# 下流の消費側（保証節を読む側）。書式の食い違いを cross-file で検出するために参照する。
CONSUMER_FILE="${REPO_ROOT}/skills/promote-verify/references/guarantee-consistency.md"
# 規律の正本（中断理由コード・裁可ラベル・フェーズ判定の定型文の列挙が置かれる）。
STRATEGY_FILE="${REPO_ROOT}/docs/ai-driven-development-strategy.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "NG - jq が見つからないためテストを実行できません（検査不能を pass にはしない）" >&2
  exit 1
fi

for f in "$SKILL_FILE" "$REF_FILE" "$REQ_FILE" "$DEC_FILE" "$TPL_FILE" "$CONSUMER_FILE" "$STRATEGY_FILE"; do
  if [ ! -r "$f" ]; then
    echo "NG - 検査対象ファイルを読めません（検査不能を pass にはしない）: ${f}" >&2
    exit 1
  fi
done

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

assert_eq() {
  local description="$1"
  local expected="$2"
  local actual="$3"

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

# 指定ファイルに正準文（固定文字列）が逐語で存在することを検査する。
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

assert_file_not_contains() {
  local description="$1" file="$2" phrase="$3"
  if grep -qF -- "$phrase" "$file"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${file}"
    echo "       phrase: ${phrase}"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  fi
}

assert_skill_contains() { assert_file_contains "$1" "$SKILL_FILE" "$2"; }
assert_ref_contains() { assert_file_contains "$1" "$REF_FILE" "$2"; }

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

# ---------------------------------------------------------------------------
# 参照実装: 散文（guarantee-section.md 共通-2 / 要件-1）が前提にしている読み取り規則。
# スクリプト（guarantee-index-check.sh）と下流の消費側（promote-verify 5.5-3）の
# 両方に同じ規則で掛け、結果が一致することを (A-4) / (A-6) で突き合わせる。
# ---------------------------------------------------------------------------

# 正規表現はいったん変数へ入れてから `=~` の右辺に置く（バッククォートを含むパターンを
# [[ ]] へ直接書くとコマンド置換として解釈される余地があるため）。
CT_FENCE_RE='^[[:space:]]{0,3}(`{3,}|~{3,})[[:space:]]*(.*)$'
CT_H12_RE='^#{1,2}[[:space:]]'
CT_SECTION_RE='^##[[:space:]]+保証'
CT_H3_RE='^###[[:space:]]+(.+)$'
CT_GUARANTEE_HEADING_RE='^###[[:space:]]+(G-[0-9]+-[0-9]+)[[:space:]]*(:|：)'
CT_NEW_ITEM_RE='^[[:space:]]*[-*][[:space:]]+\[[[:space:]xX]\][[:space:]]+(G-[0-9]+-[0-9]+)[[:space:]]*(:|：)'
CT_KEEP_ITEM_RE='^[[:space:]]*[-*][[:space:]]+(\[[[:space:]xX]\][[:space:]]+)?(G-[0-9]+-[0-9]+)'
CT_NONE_ITEM_RE='^[[:space:]]*[-*][[:space:]]+なし[[:space:]]*$'

# Issue 本文（または台帳）から「## 保証（Guarantees）」節を読み、
# 1行1トークンで結果を返す参照実装。
#   NO_SECTION            : 節が無い（フェンス内の引用は節とみなさない）
#   NEW <ID> / KEEP <ID>  : 新たに宣言する保証 / 維持する保証
#   NEW_NONE / KEEP_NONE  : 「- なし」が明示されている（検査した結果の0件）
ct_extract_guarantee_section() {
  local body="$1"
  local line marker_run marker fence_info title
  local fence_marker="" fence_len=0
  local in_section="false" sub="" saw_section="false"

  body="${body//$'\r'/}"

  while IFS= read -r line; do
    if [[ "$line" =~ $CT_FENCE_RE ]]; then
      marker_run="${BASH_REMATCH[1]}"
      fence_info="${BASH_REMATCH[2]}"
      marker="${marker_run:0:1}"
      if [ -z "$fence_marker" ]; then
        fence_marker="$marker"
        fence_len="${#marker_run}"
      elif [ "$fence_marker" = "$marker" ] && [ "${#marker_run}" -ge "$fence_len" ] && [ -z "$fence_info" ]; then
        fence_marker=""
        fence_len=0
      fi
      continue
    fi
    [ -n "$fence_marker" ] && continue

    if [[ "$line" =~ $CT_SECTION_RE ]]; then
      in_section="true"
      saw_section="true"
      sub=""
      continue
    fi
    if [[ "$line" =~ $CT_H12_RE ]]; then
      in_section="false"
      sub=""
      continue
    fi
    [ "$in_section" = "true" ] || continue

    if [[ "$line" =~ $CT_H3_RE ]]; then
      title="${BASH_REMATCH[1]}"
      title="${title%"${title##*[![:space:]]}"}"
      case "$title" in
        "新たに宣言する保証") sub="new" ;;
        "維持する保証") sub="keep" ;;
        *) sub="" ;;
      esac
      continue
    fi

    [ -n "$sub" ] || continue

    if [[ "$line" =~ $CT_NONE_ITEM_RE ]]; then
      if [ "$sub" = "new" ]; then echo "NEW_NONE"; else echo "KEEP_NONE"; fi
      continue
    fi
    if [ "$sub" = "new" ] && [[ "$line" =~ $CT_NEW_ITEM_RE ]]; then
      echo "NEW ${BASH_REMATCH[1]}"
      continue
    fi
    if [ "$sub" = "keep" ] && [[ "$line" =~ $CT_KEEP_ITEM_RE ]]; then
      echo "KEEP ${BASH_REMATCH[2]}"
      continue
    fi
  done <<<"$body"

  if [ "$saw_section" = "false" ]; then
    echo "NO_SECTION"
  fi
}

# 台帳の保証見出し（`## 保証` 節内・フェンス外の `### G-...`）を数える参照実装。
# guarantee-index-check.sh の counts.guarantees と一致しなければならない（共通-2 の突き合わせ）。
ct_count_ledger_headings() {
  local body="$1"
  local line marker_run marker fence_info
  local fence_marker="" fence_len=0
  local in_section="false"
  local count=0

  body="${body//$'\r'/}"

  while IFS= read -r line; do
    if [[ "$line" =~ $CT_FENCE_RE ]]; then
      marker_run="${BASH_REMATCH[1]}"
      fence_info="${BASH_REMATCH[2]}"
      marker="${marker_run:0:1}"
      if [ -z "$fence_marker" ]; then
        fence_marker="$marker"
        fence_len="${#marker_run}"
      elif [ "$fence_marker" = "$marker" ] && [ "${#marker_run}" -ge "$fence_len" ] && [ -z "$fence_info" ]; then
        fence_marker=""
        fence_len=0
      fi
      continue
    fi
    [ -n "$fence_marker" ] && continue

    if [[ "$line" =~ $CT_SECTION_RE ]]; then
      in_section="true"
      continue
    fi
    if [[ "$line" =~ $CT_H12_RE ]]; then
      in_section="false"
      continue
    fi
    [ "$in_section" = "true" ] || continue
    # スクリプト（gic_scan）は「保証」節内の `###` 見出しを ID 書式によらず 1 件として数える。
    # 散文側の突き合わせも同じ規則にする（共通-2）。
    if [[ "$line" =~ $CT_H3_RE ]]; then
      count=$((count + 1))
    fi
  done <<<"$body"

  printf '%s' "$count"
}

# 台帳の保証見出しのうち、ID 書式（G-<数字>-<枝番>）を満たすものだけを列挙する参照実装。
# 「維持する保証」に転記してよいのはこの集合だけ（共通-2）。
ct_list_guarantee_ids() {
  local body="$1"
  local line marker_run marker fence_info
  local fence_marker="" fence_len=0
  local in_section="false"

  body="${body//$'\r'/}"

  while IFS= read -r line; do
    if [[ "$line" =~ $CT_FENCE_RE ]]; then
      marker_run="${BASH_REMATCH[1]}"
      fence_info="${BASH_REMATCH[2]}"
      marker="${marker_run:0:1}"
      if [ -z "$fence_marker" ]; then
        fence_marker="$marker"
        fence_len="${#marker_run}"
      elif [ "$fence_marker" = "$marker" ] && [ "${#marker_run}" -ge "$fence_len" ] && [ -z "$fence_info" ]; then
        fence_marker=""
        fence_len=0
      fi
      continue
    fi
    [ -n "$fence_marker" ] && continue

    if [[ "$line" =~ $CT_SECTION_RE ]]; then
      in_section="true"
      continue
    fi
    if [[ "$line" =~ $CT_H12_RE ]]; then
      in_section="false"
      continue
    fi
    [ "$in_section" = "true" ] || continue
    if [[ "$line" =~ $CT_GUARANTEE_HEADING_RE ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done <<<"$body"
}

# 文字列に部分一致するかを返す（case を command substitution へ直接書かない）。
ct_contains() {
  local haystack="$1" needle="$2"
  if [ "${haystack#*"${needle}"}" != "$haystack" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# 要件-2 の ID 確定手順の参照実装。
ct_resolve_placeholder() {
  local body="$1" number="$2"
  printf '%s' "${body//\{ISSUE_NUMBER\}/${number}}"
}

ct_has_unresolved_placeholder() {
  case "$1" in
    *"{ISSUE_NUMBER}"*) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# 要件-2 の置換の参照実装（スコープ限定）。
# 「### 新たに宣言する保証」配下・フェンス外の、生成した ID を持つチェックリスト行だけを置換する。
# 転記された機能仕様（保証節の外・フェンス内）の `{ISSUE_NUMBER}` には触れない。
CT_NEW_PLACEHOLDER_RE='^[[:space:]]*[-*][[:space:]]+\[[[:space:]xX]\][[:space:]]+G-\{ISSUE_NUMBER\}-'

ct_resolve_placeholder_scoped() {
  local body="$1" number="$2"
  local line marker_run marker fence_info title
  local fence_marker="" fence_len=0
  local in_section="false" in_new="false"
  local out=""

  body="${body//$'\r'/}"

  while IFS= read -r line; do
    if [[ "$line" =~ $CT_FENCE_RE ]]; then
      marker_run="${BASH_REMATCH[1]}"
      fence_info="${BASH_REMATCH[2]}"
      marker="${marker_run:0:1}"
      if [ -z "$fence_marker" ]; then
        fence_marker="$marker"
        fence_len="${#marker_run}"
      elif [ "$fence_marker" = "$marker" ] && [ "${#marker_run}" -ge "$fence_len" ] && [ -z "$fence_info" ]; then
        fence_marker=""
        fence_len=0
      fi
      out="${out}${line}"$'\n'
      continue
    fi
    if [ -n "$fence_marker" ]; then
      out="${out}${line}"$'\n'
      continue
    fi

    if [[ "$line" =~ $CT_SECTION_RE ]]; then
      in_section="true"
      in_new="false"
    elif [[ "$line" =~ $CT_H12_RE ]]; then
      in_section="false"
      in_new="false"
    elif [ "$in_section" = "true" ] && [[ "$line" =~ $CT_H3_RE ]]; then
      title="${BASH_REMATCH[1]}"
      title="${title%"${title##*[![:space:]]}"}"
      if [ "$title" = "新たに宣言する保証" ]; then in_new="true"; else in_new="false"; fi
    elif [ "$in_new" = "true" ] && [[ "$line" =~ $CT_NEW_PLACEHOLDER_RE ]]; then
      line="${line//\{ISSUE_NUMBER\}/${number}}"
    fi

    out="${out}${line}"$'\n'
  done <<<"$body"

  printf '%s' "$out"
}

# 新規宣言の ID が親（＝この Issue）のスコープかを判定する（ハイフンまで含めて比較）。
ct_id_scope_matches() {
  local id="$1" number="$2"
  case "$id" in
    "G-${number}-"*) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# 裁可状態の参照実装（要件-4 の表の真理値表）。
# 引数: <(i)(ii) 違反 1/0> <(iii) ID 文法違反 1/0> <(v) ラベル欠落 1/0> <判定保留件数> [<(iv) 枝番違反 1/0>]
ct_approval_status() {
  local placeholder="$1" scope="$2" label="$3" pending="$4" branch="${5:-0}"
  if [ "$placeholder" = "1" ] || [ "$scope" = "1" ] || [ "$label" = "1" ] || [ "$branch" = "1" ]; then
    printf '未完了'
    return 0
  fi
  if [ "$pending" -gt 0 ]; then
    printf '要人間判定あり'
    return 0
  fi
  printf '裁可可'
}

# 要件-2 検証(iii) の参照実装: 完全な ID 文法 `G-<N>-<枝番>`（枝番は1文字以上の数字）に一致するか。
# 接頭辞 `G-<N>-` の一致だけで通さない（`G-158-x` / `G-158-` を弾く）。
ct_id_grammar_matches() {
  local id="$1" number="$2"
  local re="^G-${number}-[0-9]+$"
  if [[ "$id" =~ $re ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# 旧実装（接頭辞のみ）。指摘Bの欠陥を再現し、完全文法との差を固定するために残す。
ct_id_prefix_matches() {
  local id="$1" number="$2"
  case "$id" in
    "G-${number}-"*) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# 要件-2 検証(iv) の参照実装: 枝番が 1 から始まる連番で重複が無いか。
# 引数: 枝番の並び（例: 1 2 3）
ct_branch_numbers_ok() {
  local expected=1 branch
  for branch in "$@"; do
    [ "$branch" = "$expected" ] || { printf 'false'; return 0; }
    expected=$((expected + 1))
  done
  [ "$#" -gt 0 ] || { printf 'false'; return 0; }
  printf 'true'
}

# guarantee-section.md 内の ```markdown ブロックのうち、保証節テンプレートを取り出す。
ct_extract_template_block() {
  awk '
    /^```markdown$/ && inblock == 0 { inblock = 1; buf = ""; next }
    inblock == 1 && /^```[[:space:]]*$/ {
      if (done == 0 && index(buf, "## 保証") > 0) { printf "%s", buf; done = 1 }
      inblock = 0; buf = ""; next
    }
    inblock == 1 { buf = buf $0 "\n" }
  ' "$REF_FILE"
}

# ---------------------------------------------------------------------------
# フィクスチャ: 導入先プロジェクトを模したワークスペース
# ---------------------------------------------------------------------------

WS="${TMP_ROOT}/project"
mkdir -p "${WS}/docs" "${WS}/tests"

cat >"${WS}/tests/example.test.sh" <<'EOF'
test_contact_returns_400() {
  echo "sample test body"
}
EOF

# フェーズ宣言なし（SDD期・後方互換）
cat >"${WS}/CLAUDE-none.md" <<'EOF'
# サンプルプロジェクト

## 概要

フェーズ宣言を持たない既存プロジェクト。
EOF

cat >"${WS}/CLAUDE-gdd.md" <<'EOF'
# サンプルプロジェクト

## 開発フェーズ

- **フェーズ**: GDD期
- 駆動文書: docs/guarantees.md
EOF

cat >"${WS}/CLAUDE-invalid.md" <<'EOF'
# サンプルプロジェクト

## 開発フェーズ

- **フェーズ**: GDD
EOF

# 台帳: 書式例をフェンスで引用しつつ、実在の保証を2件持ち、節の外にも見出しが1件ある
cat >"${WS}/docs/guarantees.md" <<'EOF'
# 保証台帳

書式の例（引用。実在の保証ではない）:

```markdown
### G-999-1: 例として引用しただけの保証

- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #999
```

## 保証（Guarantees）

### G-101-2: POST /api/contact は JSON パース不能時に 400 を返す

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #101

### G-115-1: 未認証ユーザーは /admin からログイン画面へリダイレクトされる

- 種別: 認可
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #115

## Gaps（テストのない公開面）

### G-777-1: 節の外に置かれた保証（登録済みとみなさない）

- テスト: `tests/example.test.sh::test_contact_returns_400`
EOF

# 台帳: 「保証」節内に ID 書式を満たさない見出しがある（件数はスクリプトと一致するが、
# 維持する保証の候補には入らない）
cat >"${WS}/docs/guarantees-malformed.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

### G-101-2: POST /api/contact は JSON パース不能時に 400 を返す

- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #101

### 補足（ID 書式を満たさない見出し）

- テスト: `tests/example.test.sh::test_contact_returns_400`

## Gaps（テストのない公開面）
EOF

# 台帳: 保証節はあるが保証が0件（＝検査した結果の0件。未検査と区別する）
cat >"${WS}/docs/guarantees-empty.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

（まだ1件も登録されていない）

## Gaps（テストのない公開面）
EOF

echo "=== (A-1) SDD期の不変: フェーズ判定が sdd を返す（GDD 追加手順は発動しない） ==="

out="$(cd "$WS" && bash "$DETECT_SCRIPT" CLAUDE-none.md 2>/dev/null)"
code=$?
assert_eq "(A-1) 宣言なしは phase=sdd" "sdd" "$(printf '%s' "$out" | jq -r '.phase')"
assert_eq "(A-1) 宣言なしは reason=no_phase_section" "no_phase_section" "$(printf '%s' "$out" | jq -r '.reason')"
assert_eq "(A-1) 宣言なしの exit code は 0" "0" "$code"

echo ""
echo "=== (A-2) GDD期の発動: phase=gdd（exit 0） ==="

out="$(cd "$WS" && bash "$DETECT_SCRIPT" CLAUDE-gdd.md 2>/dev/null)"
code=$?
assert_eq "(A-2) GDD期宣言は phase=gdd" "gdd" "$(printf '%s' "$out" | jq -r '.phase')"
assert_eq "(A-2) GDD期宣言の exit code は 0" "0" "$code"

echo ""
echo "=== (A-3) invalid の fail-closed: 不正宣言は sdd へフォールバックしない ==="

out="$(cd "$WS" && bash "$DETECT_SCRIPT" CLAUDE-invalid.md 2>/dev/null)"
code=$?
assert_eq "(A-3) 許容値以外は phase=invalid" "invalid" "$(printf '%s' "$out" | jq -r '.phase')"
assert_eq "(A-3) invalid の exit code は 1（sdd の 0 と区別できる）" "1" "$code"

echo ""
echo "=== (A-4) 台帳の読み取り規則: 散文の規則とスクリプトの counts.guarantees が一致する ==="

gic_out="$(cd "$WS" && bash "$GIC_SCRIPT" docs/guarantees.md 2>/dev/null)"
gic_code=$?
script_count="$(printf '%s' "$gic_out" | jq -r '.counts.guarantees')"
ref_count="$(ct_count_ledger_headings "$(cat "${WS}/docs/guarantees.md")")"
assert_eq "(A-4) スクリプトはフェンス内の記入例・節外の見出しを数えない（2件）" "2" "$script_count"
assert_eq "(A-4) 散文の読み取り規則の参照実装もスクリプトと同じ件数になる" "$script_count" "$ref_count"

naive_count="$(grep -c '^### G-' "${WS}/docs/guarantees.md")"
assert_eq "(A-4) 素の grep は 4 件と数える（規則を揃えないと食い違う）" "4" "$naive_count"

assert_eq "(A-4) 節外の見出しは broken に guarantee_outside_section として現れる" "guarantee_outside_section" \
  "$(printf '%s' "$gic_out" | jq -r '.broken[0].reason')"
assert_eq "(A-4) 節外の見出しがあると status は fail（既存ドリフト。作成可否には使わない）" "fail" \
  "$(printf '%s' "$gic_out" | jq -r '.status')"
assert_eq "(A-4) status=fail でも exit code は 1（件数は取得できている）" "1" "$gic_code"

assert_eq "(A-4) 台帳の維持候補は ID 書式を満たす見出しだけ（節外・フェンス内は除く）" "G-101-2
G-115-1" "$(ct_list_guarantee_ids "$(cat "${WS}/docs/guarantees.md")")"

# ID 書式を満たさない見出し: 件数には入る（スクリプトと同じ）が、維持候補には入らない
mal_out="$(cd "$WS" && bash "$GIC_SCRIPT" docs/guarantees-malformed.md 2>/dev/null)"
assert_eq "(A-4) ID 書式違反の見出しもスクリプトは 1 件として数える" "2" \
  "$(printf '%s' "$mal_out" | jq -r '.counts.guarantees')"
assert_eq "(A-4) 散文の件数規則も同じ 2 件になる（ここで食い違うと ledger_read_mismatch で中断する）" "2" \
  "$(ct_count_ledger_headings "$(cat "${WS}/docs/guarantees-malformed.md")")"
assert_eq "(A-4) ID 書式違反の見出しは維持候補に入らない" "G-101-2" \
  "$(ct_list_guarantee_ids "$(cat "${WS}/docs/guarantees-malformed.md")")"
assert_eq "(A-4) ID 書式違反は broken に malformed_guarantee_id として報告される" "malformed_guarantee_id" \
  "$(printf '%s' "$mal_out" | jq -r '[.broken[].reason] | unique | join(",")')"

# 保証0件の台帳: 「検査した結果の0件」として counts.guarantees=0 が取れる
empty_out="$(cd "$WS" && bash "$GIC_SCRIPT" docs/guarantees-empty.md 2>/dev/null)"
assert_eq "(A-4) 保証0件の台帳は counts.guarantees=0（未検査と区別できる）" "0" \
  "$(printf '%s' "$empty_out" | jq -r '.counts.guarantees')"
assert_eq "(A-4) 保証0件の台帳でも status は pass" "pass" \
  "$(printf '%s' "$empty_out" | jq -r '.status')"

# 台帳が読めない: 件数を取得できない（0件に読み替えない）
missing_out="$(cd "$WS" && bash "$GIC_SCRIPT" docs/does-not-exist.md 2>/dev/null)"
missing_code=$?
assert_eq "(A-4) 台帳が読めないときの exit code は 2（実行前提の欠落）" "2" "$missing_code"
assert_eq "(A-4) exit 2 では stdout に件数を持つ JSON が返らない（0 件に読み替えない）" "" "$missing_out"

echo ""
echo "=== (A-5) 保証 ID の確定: プレースホルダ置換とスコープ比較 ==="

body_tpl='## 保証（Guarantees）

### 新たに宣言する保証

- [ ] G-{ISSUE_NUMBER}-1: 約束文A（受入基準 AC-1 に対応）
- [ ] G-{ISSUE_NUMBER}-2: 約束文B（受入基準 AC-2 に対応）

### 維持する保証

- なし'

assert_eq "(A-5) 置換前はプレースホルダが検出される" "true" "$(ct_has_unresolved_placeholder "$body_tpl")"
resolved="$(ct_resolve_placeholder "$body_tpl" 158)"
assert_eq "(A-5) 置換後はプレースホルダが残らない" "false" "$(ct_has_unresolved_placeholder "$resolved")"
assert_eq "(A-5) 置換後の新規宣言 ID は G-158-1 / G-158-2" "NEW G-158-1
NEW G-158-2
KEEP_NONE" "$(ct_extract_guarantee_section "$resolved")"

assert_eq "(A-5) G-158-1 は親#158 のスコープ" "true" "$(ct_id_scope_matches "G-158-1" 158)"
assert_eq "(A-5) G-158-10 も親#158 のスコープ（枝番2桁）" "true" "$(ct_id_scope_matches "G-158-10" 158)"
assert_eq "(A-5) G-1580-1 は親#158 のスコープではない（前方一致で取り違えない）" "false" "$(ct_id_scope_matches "G-1580-1" 158)"
assert_eq "(A-5) G-15-1 は親#158 のスコープではない" "false" "$(ct_id_scope_matches "G-15-1" 158)"
assert_eq "(A-5) G-999-1 は親#158 のスコープではない（他 Issue の ID を宣言しない）" "false" "$(ct_id_scope_matches "G-999-1" 158)"

echo ""
echo "=== (A-6) 相互運用: 参照ファイルの保証節テンプレートを下流の抽出規則で読める ==="

template_block="$(ct_extract_template_block)"
assert_eq "(A-6) 参照ファイルから保証節テンプレートを取り出せる" "true" \
  "$(ct_contains "$template_block" "## 保証")"

tpl_resolved="$(ct_resolve_placeholder "$template_block" 158)"
assert_eq "(A-6) テンプレートの新規宣言・維持が期待どおり抽出できる" "NEW G-158-1
NEW G-158-2
KEEP G-101-2
KEEP G-115-1" "$(ct_extract_guarantee_section "$tpl_resolved")"

# 「なし」を明示した版: 検査した結果の0件として読める（空欄にしないことの担保）
none_body="$(printf '%s\n' '## 保証（Guarantees）' '' '### 新たに宣言する保証' '' '- なし' '' '### 維持する保証' '' '- なし' '' '### 判定保留（要人間判定）' '' '- なし')"
assert_eq "(A-6) 「- なし」は対象0件として明示的に読める" "NEW_NONE
KEEP_NONE" "$(ct_extract_guarantee_section "$none_body")"

# 空欄（見出しだけ）: 0件と区別が付かない状態になる（＝規約が「- なし」を必須にしている理由）
blank_body="$(printf '%s\n' '## 保証（Guarantees）' '' '### 新たに宣言する保証' '' '### 維持する保証')"
assert_eq "(A-6) 見出しだけで中身が無いと「なし」の明示が得られない" "" "$(ct_extract_guarantee_section "$blank_body")"

# チェック済みの行も等しく抽出される（チェック状態で対象を絞らない）
checked_body="$(printf '%s\n' '## 保証（Guarantees）' '' '### 新たに宣言する保証' '' '- [x] G-158-1: 完了済みの保証' '- [ ] G-158-2: 未完了の保証' '' '### 維持する保証' '' '- なし')"
assert_eq "(A-6) チェック済み・未チェックを等しく抽出する" "NEW G-158-1
NEW G-158-2
KEEP_NONE" "$(ct_extract_guarantee_section "$checked_body")"

# 参照ファイル全体（テンプレートはフェンス内）: 保証 ID の宣言としては1件も拾わない
assert_eq "(A-6) 参照ファイル自身のテンプレート引用から保証 ID を拾わない（フェンス規則）" "" \
  "$(ct_extract_guarantee_section "$(cat "$REF_FILE")" | grep -E '^(NEW|KEEP) ')"

# Issue 本文がテンプレートを引用しているだけのケース
quoted_body="$(printf '%s\n' '# 要件' '' '保証節の書式は次のとおり:' '' '```markdown' '## 保証（Guarantees）' '' '### 新たに宣言する保証' '' '- [ ] G-158-1: 引用しただけの保証' '```')"
assert_eq "(A-6) フェンス内に引用された保証節を実在の宣言として数えない" "NO_SECTION" \
  "$(ct_extract_guarantee_section "$quoted_body")"

echo ""
echo "=== (A-7) 書式の cross-file 一致: 書き出す側と読む側で見出し文字列が同一 ==="

for heading in '## 保証（Guarantees）' '### 新たに宣言する保証' '### 維持する保証'; do
  produced="false"
  consumed="false"
  grep -qF -- "$heading" "$REF_FILE" && produced="true"
  grep -qF -- "$heading" "$CONSUMER_FILE" && consumed="true"
  assert_eq "(A-7) 「${heading}」を create-ticket 側が書き出す規約として持つ" "true" "$produced"
  assert_eq "(A-7) 「${heading}」を promote-verify 側が読む規約として持つ" "true" "$consumed"
done

echo ""
echo "=== (A-8) 文法の分離: 正しく生成された親Issueが分解モードでパース可能 ==="

# 要件-1 が書き出す形の親Issue本文（機能仕様の転記＋フェンス内のコード例＋保証節）
parent_body="$(printf '%s\n' \
  '> 機能仕様: docs/features/contact.md' \
  '' \
  '## 概要' \
  '' \
  '問い合わせ API を追加する。' \
  '' \
  '```ts' \
  'const id = `G-{ISSUE_NUMBER}-1`; // 仕様中のコード例' \
  '```' \
  '' \
  '## 受入基準' \
  '' \
  '- [ ] AC-1: 不正な JSON で 400 を返す' \
  '' \
  '## 保証（Guarantees）' \
  '' \
  '### 新たに宣言する保証' \
  '' \
  '- [ ] G-158-1: POST /api/contact は JSON パース不能時に 400 を返す（受入基準 AC-1 に対応）' \
  '' \
  '### 維持する保証' \
  '' \
  '- G-101-2: 既存の約束文' \
  '' \
  '### 判定保留（要人間判定）' \
  '' \
  '- なし')"

assert_eq "(A-8) 親Issue文法では新規宣言・維持が抽出できる（分解-1 がパース可能と判定する）" "NEW G-158-1
KEEP G-101-2" "$(ct_extract_guarantee_section "$parent_body")"

# 台帳文法を親Issueへ当てるとどうなるか（誤適用の再発検出）
assert_eq "(A-8) 台帳文法を親Issueへ当てると保証 ID を1件も拾えない（誤適用の証跡）" "" \
  "$(ct_list_guarantee_ids "$parent_body")"
assert_eq "(A-8) 台帳文法の件数規則ではカテゴリ見出し3件を保証と数えてしまう" "3" \
  "$(ct_count_ledger_headings "$parent_body")"

# 台帳側は逆に親Issue文法では読めない（両文法が別物であることの対称な確認）
assert_eq "(A-8) 台帳に親Issue文法を当てても新規宣言・維持は抽出されない" "" \
  "$(ct_extract_guarantee_section "$(cat "${WS}/docs/guarantees.md")" | grep -E '^(NEW|KEEP) ')"

# 判定保留は抽出対象にしない
assert_eq "(A-8) 判定保留カテゴリからは保証を抽出しない" "0" \
  "$(ct_extract_guarantee_section "$parent_body" | grep -c '判定保留')"

echo ""
echo "=== (A-9) 親Issue文法が下流（promote-verify 5.5-3）と逐語で一致している ==="

for phrase in \
  '「### 新たに宣言する保証」配下のチェックリスト行 `- [ ] G-<宣言元番号>-<枝番>: <約束文>`' \
  '**`- [x]` / `- [X]` のチェック済み行も等しく対象にする**' \
  '「### 維持する保証」配下に列挙された既存の保証 ID' \
  '箇条書き・チェックリストのいずれの書き方でも、またチェック状態によらず対象にする'; do
  produced="false"
  consumed="false"
  grep -qF -- "$phrase" "$REF_FILE" && produced="true"
  grep -qF -- "$phrase" "$CONSUMER_FILE" && consumed="true"
  assert_eq "(A-9) create-ticket 側が親Issue文法「${phrase:0:24}…」を持つ" "true" "$produced"
  assert_eq "(A-9) promote-verify 側も同じ文言を持つ「${phrase:0:24}…」" "true" "$consumed"
done

# 構造不変条件: 親Issue文法のブロックに台帳専用の概念（counts.guarantees）を持ち込まない
parent_grammar_block="$(awk '/^#### \(c\) 親Issue本文の文法/{f=1;next} f && /^### /{f=0} f' "$REF_FILE")"
assert_eq "(A-9) 親Issue文法ブロックに台帳固有の counts.guarantees が混入していない" "0" \
  "$(printf '%s\n' "$parent_grammar_block" | grep -c 'counts.guarantees')"
assert_eq "(A-9) 親Issue文法ブロックはカテゴリ見出しとリスト行を定義している" "1" \
  "$(printf '%s\n' "$parent_grammar_block" | grep -c '保証 ID は見出し行ではなく、カテゴリ配下のリスト行にある')"

# 適用範囲表: 台帳の文法は親Issueへ「適用しない」
assert_ref_contains "適用範囲表が台帳の文法を親Issueへ適用しないと定めている" \
  '| (b) 台帳の文法 | 適用する | **適用しない** |'
assert_ref_contains "適用範囲表が親Issue文法を台帳へ適用しないと定めている" \
  '| (c) 親Issue本文の文法 | 適用しない | 適用する |'

echo ""
echo "=== (A-10) 置換のスコープ: 転記した機能仕様を書き換えない ==="

spec_body="$(printf '%s\n' \
  '> 機能仕様: docs/features/ticket-template.md' \
  '' \
  '## 概要' \
  '' \
  'Issue テンプレートの `{ISSUE_NUMBER}` プレースホルダを扱う機能。' \
  '' \
  '```text' \
  'G-{ISSUE_NUMBER}-1 の形式で採番する（仕様中の例）' \
  '```' \
  '' \
  '## 保証（Guarantees）' \
  '' \
  '### 新たに宣言する保証' \
  '' \
  '- [ ] G-{ISSUE_NUMBER}-1: テンプレートの採番規則を守る（受入基準 AC-1 に対応）' \
  '' \
  '### 維持する保証' \
  '' \
  '- なし')"

scoped="$(ct_resolve_placeholder_scoped "$spec_body" 200)"
naive="$(ct_resolve_placeholder "$spec_body" 200)"

assert_eq "(A-10) スコープ限定の置換で新規宣言の ID が解決される" "NEW G-200-1
KEEP_NONE" "$(ct_extract_guarantee_section "$scoped")"
assert_eq "(A-10) 転記した散文中の {ISSUE_NUMBER} が残る（逐語保存）" "1" \
  "$(printf '%s\n' "$scoped" | grep -c 'テンプレートの `{ISSUE_NUMBER}` プレースホルダを扱う機能。')"
assert_eq "(A-10) 転記したコード例中の {ISSUE_NUMBER} が残る（逐語保存）" "1" \
  "$(printf '%s\n' "$scoped" | grep -c 'G-{ISSUE_NUMBER}-1 の形式で採番する（仕様中の例）')"

# 差分は新規宣言の行だけ（(i-2) の検証の機械化）
diff_lines="$(diff <(printf '%s\n' "$spec_body") <(printf '%s\n' "$scoped") | grep -E '^[<>]' | grep -c .)"
assert_eq "(A-10) 置換前後の差分は新規宣言の1行だけ（2行分の < > 表示）" "2" "$diff_lines"

# 一括置換なら転記部分が壊れる（欠陥の再現。この差が (A-10) の存在理由）
assert_eq "(A-10) 本文全体への一括置換は転記した散文を書き換えてしまう" "0" \
  "$(printf '%s\n' "$naive" | grep -c 'テンプレートの `{ISSUE_NUMBER}` プレースホルダを扱う機能。')"
assert_eq "(A-10) 本文全体への一括置換は転記したコード例も書き換えてしまう" "0" \
  "$(printf '%s\n' "$naive" | grep -c 'G-{ISSUE_NUMBER}-1 の形式で採番する（仕様中の例）')"

echo ""
echo "=== (A-14) 台帳パスの解決: サブディレクトリからでもリポジトリルートの台帳を見つける ==="

# git リポジトリを模したワークスペース（ルートに CLAUDE.md と台帳、サブディレクトリから起動する）
WS2="${TMP_ROOT}/repo"
mkdir -p "${WS2}/docs" "${WS2}/tests" "${WS2}/packages/api"
git init -q "$WS2" 2>/dev/null || git -C "$WS2" init -q
cat >"${WS2}/CLAUDE.md" <<'EOF'
# サンプルプロジェクト

## 開発フェーズ

- **フェーズ**: GDD期
- 駆動文書: docs/guarantees.md
EOF
cat >"${WS2}/tests/example.test.sh" <<'EOF'
test_contact_returns_400() {
  echo "sample test body"
}
EOF
cat >"${WS2}/docs/guarantees.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

### G-101-2: POST /api/contact は JSON パース不能時に 400 を返す

- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #101

## Gaps（テストのない公開面）
EOF

# サブディレクトリからのフェーズ判定は gdd（リポジトリルートの CLAUDE.md を見つける）
sub_phase="$(cd "${WS2}/packages/api" && bash "$DETECT_SCRIPT" 2>/dev/null)"
assert_eq "(A-14) サブディレクトリからでもフェーズ判定は gdd を返す" "gdd" \
  "$(printf '%s' "$sub_phase" | jq -r '.phase')"

# 引数なしの索引チェックは cwd 相対で解決するため、サブディレクトリでは台帳を見つけられない
sub_default_out="$(cd "${WS2}/packages/api" && bash "$GIC_SCRIPT" 2>/dev/null)"
sub_default_code=$?
assert_eq "(A-14) 引数なしはサブディレクトリで実行前提の欠落（exit 2）になる" "2" "$sub_default_code"
assert_eq "(A-14) 引数なしでは件数を得られない（この経路が index_check_unavailable の中断になる）" "" "$sub_default_out"

# リポジトリルートを解決して台帳パスを渡せば、サブディレクトリからでも検査できる
sub_root="$(cd "${WS2}/packages/api" && git rev-parse --show-toplevel 2>/dev/null)"
assert_eq "(A-14) git rev-parse --show-toplevel でリポジトリルートを解決できる" "$(cd "$WS2" && pwd -P)" \
  "$(cd "$sub_root" && pwd -P)"
sub_explicit_out="$(cd "${WS2}/packages/api" && bash "$GIC_SCRIPT" "${sub_root}/docs/guarantees.md" 2>/dev/null)"
sub_explicit_code=$?
assert_eq "(A-14) ルート基準の台帳パスを渡せばサブディレクトリからも pass する" "pass" \
  "$(printf '%s' "$sub_explicit_out" | jq -r '.status')"
assert_eq "(A-14) ルート基準なら exit code は 0" "0" "$sub_explicit_code"
assert_eq "(A-14) ルート基準なら保証件数を取得できる" "1" \
  "$(printf '%s' "$sub_explicit_out" | jq -r '.counts.guarantees')"
assert_eq "(A-14) テスト参照の基準ディレクトリは台帳の位置からリポジトリルートに解決される（--base 不要）" \
  "$(cd "$WS2" && pwd -P)" "$(cd "$(printf '%s' "$sub_explicit_out" | jq -r '.base')" && pwd -P)"

assert_ref_contains "台帳パスをリポジトリルート基準で解決する規約がある" \
  '**台帳のパスはリポジトリルート基準で解決する（引数を省略しない）**'
assert_ref_contains "ルート解決を detect-dev-phase と同じ考え方だと明示している" \
  '`git rev-parse --show-toplevel` で解決し（`detect-dev-phase` がサブディレクトリからでもリポジトリルートの `CLAUDE.md` を見つけるのと同じ考え方）'
assert_ref_contains "cwd 相対で探さない・引数なしで呼ばないと明示している" \
  '**cwd 相対で台帳を探さない・索引チェックを引数なしで呼ばない**'
assert_ref_contains "食い違いの帰結（台帳が実在するのに中断）を明示している" \
  '**台帳が実在するのに `index_check_unavailable` で中断する**'
assert_ref_contains "ルートを解決できない場合の扱いを定めている" \
  '黙って cwd 相対へ倒さない'
assert_ref_contains "ランチャー呼び出しに台帳パスを渡している" \
  '`claude-harness-run guarantee-index-check <リポジトリルート>/docs/guarantees.md`'
assert_ref_contains "フォールバック形にも台帳パスを渡している" \
  '`bash "<プラグインルート>/scripts/guarantee-index-check.sh" "<リポジトリルート>/docs/guarantees.md"`'
assert_ref_contains "前提の確認表もルート基準のパスを指している" \
  '| 保証台帳が存在し読める | リポジトリルートを解決し `<リポジトリルート>/docs/guarantees.md` を Read する（下記） |'

echo ""
echo "=== (A-15) 保証 ID は完全文法で検証する（接頭辞一致で通さない） ==="

assert_eq "(A-15) G-158-1 は完全文法に一致" "true" "$(ct_id_grammar_matches "G-158-1" 158)"
assert_eq "(A-15) G-158-10 は完全文法に一致（枝番2桁）" "true" "$(ct_id_grammar_matches "G-158-10" 158)"
assert_eq "(A-15) G-158-x は完全文法に不一致（枝番が数値でない）" "false" "$(ct_id_grammar_matches "G-158-x" 158)"
assert_eq "(A-15) G-158- は完全文法に不一致（枝番が無い）" "false" "$(ct_id_grammar_matches "G-158-" 158)"
assert_eq "(A-15) G-158-1a は完全文法に不一致（数字以外の混入）" "false" "$(ct_id_grammar_matches "G-158-1a" 158)"
assert_eq "(A-15) G-1580-1 は完全文法に不一致（別 Issue スコープ）" "false" "$(ct_id_grammar_matches "G-1580-1" 158)"
assert_eq "(A-15) G-15-1 は完全文法に不一致" "false" "$(ct_id_grammar_matches "G-15-1" 158)"
assert_eq "(A-15) G-999-1 は完全文法に不一致" "false" "$(ct_id_grammar_matches "G-999-1" 158)"

# 接頭辞のみの検証だと壊れた ID が通ってしまう（指摘Bの欠陥の再現）
assert_eq "(A-15) 接頭辞のみの検証は G-158-x を通してしまう" "true" "$(ct_id_prefix_matches "G-158-x" 158)"
assert_eq "(A-15) 接頭辞のみの検証は G-158- も通してしまう" "true" "$(ct_id_prefix_matches "G-158-" 158)"

# 壊れた ID は親Issue文法（下流）から黙って消える
mixed_body="$(printf '%s\n' '## 保証（Guarantees）' '' '### 新たに宣言する保証' '' \
  '- [ ] G-158-1: 正しい宣言' '- [ ] G-158-x: 枝番が数値でない宣言' '' '### 維持する保証' '' '- なし')"
assert_eq "(A-15) 枝番が数値でない宣言は親Issue文法で抽出されず黙って消える" "NEW G-158-1
KEEP_NONE" "$(ct_extract_guarantee_section "$mixed_body")"
assert_eq "(A-15) それでも節はパースでき guarantee_section_missing にならない（＝黙って抜ける）" "0" \
  "$(ct_extract_guarantee_section "$mixed_body" | grep -c 'NO_SECTION')"

echo ""
echo "=== (A-16) 枝番の連番・一意性 ==="

assert_eq "(A-16) 1 2 3 は連番・一意" "true" "$(ct_branch_numbers_ok 1 2 3)"
assert_eq "(A-16) 1 のみは連番・一意" "true" "$(ct_branch_numbers_ok 1)"
assert_eq "(A-16) 1 3 は非連番（欠番）で不可" "false" "$(ct_branch_numbers_ok 1 3)"
assert_eq "(A-16) 1 1 は重複で不可" "false" "$(ct_branch_numbers_ok 1 1)"
assert_eq "(A-16) 2 は 1 始まりでないため不可" "false" "$(ct_branch_numbers_ok 2)"
assert_eq "(A-16) 2 1 は順序が崩れており不可" "false" "$(ct_branch_numbers_ok 2 1)"

# 裁可状態への接続（成功に丸めない）
assert_eq "(A-16) ID 文法違反があれば裁可可にしない" "未完了" "$(ct_approval_status 0 1 0 0 0)"
assert_eq "(A-16) 枝番違反があれば裁可可にしない" "未完了" "$(ct_approval_status 0 0 0 0 1)"
assert_eq "(A-16) 判定保留0件でも ID 文法違反なら裁可可にしない" "未完了" "$(ct_approval_status 0 1 0 0 0)"
assert_eq "(A-16) すべて満たし判定保留0件のときだけ裁可可" "裁可可" "$(ct_approval_status 0 0 0 0 0)"

echo ""
echo "=== (A-11) ヘッダ行の並び: テンプレートと散文が一致している ==="

# テンプレートのヘッダ行の並び（Parent → Base → 保証）
tpl_header_order="$(grep -E '^(Parent|Base|保証):' "$TPL_FILE" | sed -E 's/^([^:]+):.*/\1/' | tr '\n' ',' | sed 's/,$//')"
assert_eq "(A-11) テンプレートのヘッダ行は Parent → Base → 保証 の順" "Parent,Base,保証" "$tpl_header_order"
assert_ref_contains "分解-2 がテンプレートの並びに従うと明示している" \
  '**位置はテンプレート `implementation-ticket.md` の並び（`Parent:` → `Base:`（`--base` 指定時のみ）→ `保証:`）に従う**'
assert_ref_contains "Base 行がある場合の位置を明示している" \
  '（`Base:` 行がある場合はその直下、無い場合は `Parent:` 行の直下）'
assert_file_contains "実装分解モードのフックもテンプレートの並びを指す" "$DEC_FILE" \
  '位置はテンプレート `implementation-ticket.md` の並び `Parent:` → `Base:`（`--base` 指定時のみ）→ `保証:` に従う'
assert_file_not_contains "分解-2 に Parent 直下という旧指定が残っていない" "$REF_FILE" \
  '`Parent:` 行の直下として次の1行を含める'
assert_file_not_contains "フックに Parent 直下という旧指定が残っていない" "$DEC_FILE" \
  '`Parent: #{親Issue番号}` 行の直下に'

echo ""
echo "=== (A-12) 語彙の閉包: 裁可ラベル名が2種以外に増えていない ==="

label_names="$(grep -rho -E 'guarantee:[a-z][a-z-]*' "${REPO_ROOT}/skills" "${REPO_ROOT}/docs" "${REPO_ROOT}/agents" | sort -u | tr '\n' ',' | sed 's/,$//')"
assert_eq "(A-12) 裁可ラベルは guarantee:approved / guarantee:proposed の2種だけ" \
  "guarantee:approved,guarantee:proposed" "$label_names"
assert_file_contains "戦略ドキュメントが裁可ラベルの意味と付ける主体を定義している" "$STRATEGY_FILE" \
  '| `guarantee:proposed` | 保証節は書かれたが、まだ承認されていない（裁可待ち） |'

echo ""
echo "=== (A-13) フェーズ判定の定型文が正本と逐語一致している ==="

phase_boilerplate='フェーズは必ず `claude-harness-run detect-dev-phase` の出力だけで判定し、`CLAUDE.md` を自分で grep しないこと（判定規約の重複実装を防ぐため）'
assert_skill_contains "SKILL.md が定型文の中核文を持つ" "$phase_boilerplate"
assert_file_contains "戦略ドキュメント（定型文の正本）にも同じ文が存在する" "$STRATEGY_FILE" "$phase_boilerplate"
assert_file_contains "戦略ドキュメントの適用先に /create-ticket が適用済みとして登録されている" "$STRATEGY_FILE" \
  '`/create-ticket`（適用済み）'

# 掃引の再発防止: skills/ 配下でフェーズ判定を CLAUDE.md 側で行うと読める表現を検出する
phase_grep_leak="$(grep -rn -E 'CLAUDE\.md (の)?(フェーズ)?宣言が (GDD期|SDD期)' "${REPO_ROOT}/skills" || true)"
assert_eq "(A-13) skills/ にフェーズ判定を CLAUDE.md 直読みで行うと読める表現が無い" "" "$phase_grep_leak"
if printf '%s\n' 'CLAUDE.md のフェーズ宣言が GDD期' | grep -qE 'CLAUDE\.md (の)?(フェーズ)?宣言が (GDD期|SDD期)'; then
  leak_detector="works"
else
  leak_detector="broken"
fi
assert_eq "(A-13) 上記の検出パターンが既知の違反形を検出できる（自己検査）" "works" "$leak_detector"

echo ""
echo "=== (B-1) SKILL.md のフェーズ判定と分岐（default-OFF の入口） ==="

assert_skill_contains "SKILL.md がフェーズ判定の定型文を持つ（独自 grep を禁じる）" \
  'フェーズは必ず `claude-harness-run detect-dev-phase` の出力だけで判定し、`CLAUDE.md` を自分で grep しないこと'
assert_skill_contains "SKILL.md が gdd のときだけ追加挙動を行うと明示している" \
  'フェーズ依存の追加挙動は **`phase` が `gdd` のときだけ**行い、`sdd`（宣言なしを含む）では一切挙動を変えない'
assert_skill_contains "SKILL.md が invalid・実行不能を sdd とみなさないと明示している" \
  '`sdd` とみなさない'
assert_skill_contains "SKILL.md が SDD期の完全な不変を明示している" \
  '**本スキルの挙動・作成される Issue・報告は従来と完全に同一**'
assert_skill_contains "SKILL.md が SDD期に追加要素を足さないと明示している" \
  'GDD期の追加手順を**一切実行しない**（保証節・裁可ラベル・保証参照行のいずれも足さない）'
assert_skill_contains "SKILL.md が invalid で Issue を作成しない（fail-closed）と明示している" \
  '**Issue を1件も作成せずに中断**'
assert_skill_contains "SKILL.md が GDD 参照ファイルのプラグイン配下パスを示している" \
  '`${CLAUDE_PLUGIN_ROOT}/skills/create-ticket/references/guarantee-section.md`'
assert_skill_contains "SKILL.md が GDD 参照ファイルをモード別参照ファイルと併読させている" \
  'モード別参照ファイルと**両方**読む'

echo ""
echo "=== (B-2) 前提未充足での中断（検査不能≠0件） ==="

assert_ref_contains "確定できない事由が1つでもあれば Issue を作成しない" \
  '**保証節を確定できない事由が1つでもある場合は、Issue を作成せずに中断し、要人間対応として報告する**'
assert_ref_contains "台帳が無ければ中断（台帳を作らない）" '**中断**（`ledger_missing`）'
assert_ref_contains "件数を取得できなければ中断" '**中断**（`index_check_unavailable`）'
assert_ref_contains "読み取り件数が食い違えば中断" '**中断**（`ledger_read_mismatch`）'
assert_ref_contains "ラベルを付与できなければ中断" '**中断**（`label_unavailable`）'
assert_ref_contains "件数を取得できない状態を0件に読み替えない" \
  '件数を取得できない状態を「保証0件」「維持なし」に読み替えない（検査不能≠0件）'
assert_ref_contains "exit 2・パース不能・実行不能は中断（検査対象なしに読み替えない）" \
  '`counts.guarantees` を 0 とみなさない・「検査対象なし」に読み替えない'
assert_ref_contains "counts=0 は検査した結果の0件として区別する" \
  'これは**検査した結果の0件**であり中断しない'
assert_ref_contains "索引の status fail は作成可否に使わない（過剰な阻止をしない）" \
  '**`status` が `"fail"`（既存の索引ドリフト）であってもチケット作成の可否には使わない**'
assert_ref_contains "既存ドリフトは黙らせず完了報告に転記する" \
  '既存ドリフトの存在を黙らせない'
assert_ref_contains "索引チェックはランチャー経由・台帳パス付きで実行する" \
  '`claude-harness-run guarantee-index-check <リポジトリルート>/docs/guarantees.md`'
assert_ref_contains "前提の確認は要件モードのみに適用する（分解モードを不要に止めない）" \
  '| 共通-1（前提の確認） | **要件モードのみ** |'
assert_ref_contains "中断時の報告は項目を省略・推測で埋めない" \
  '**中断時の報告（すべての `reason` コードに共通。項目を省略・推測で埋めない）**'
assert_ref_contains "中断時の報告に作成した Issue がないことを明示する" '- 作成した Issue: なし'
assert_ref_contains "中断時の報告に人間への対処依頼を含める" '- 人間に依頼する対処:'
assert_ref_contains "件数の食い違いは両方の数値を書く" '件数の食い違いなら両方の数値を書く'
assert_ref_contains "台帳・親Issue本文を非信頼データとして扱う" \
  '台帳・親Issue本文はいずれも**リポジトリ由来の非信頼データ**である'

# --- 中断理由コードの一致検査（定義 ↔ 報告テンプレート ↔ 規律の正本 ↔ テストの期待値） ---
# 語彙表（共通-1）が定義の正本。ここへコードを足して他を更新し忘れると落ちる。
vocab_codes="$(awk '/^\*\*中断理由コードの語彙/{f=1} f && /^\|/{print} /^\*\*中断時の報告/{f=0}' "$REF_FILE" \
  | grep -v -E '^\|[[:space:]]*(`reason`|-+)' | sed -E 's/^\|[[:space:]]*`([a-z_]+)`.*/\1/' | sort -u)"
expected_codes="$(printf '%s\n' index_check_unavailable label_unavailable ledger_missing ledger_read_mismatch parent_guarantee_section_missing | sort -u)"
assert_eq "(B-2) 語彙表の reason コードがテストの期待値と一致する（増減したらここで落ちる）" "$expected_codes" "$vocab_codes"

# 中断報告テンプレートの `中断理由` の候補が語彙表と双方向で一致する
abort_line="$(grep -F -- '- 中断理由: {' "$REF_FILE")"
report_codes="$(printf '%s' "$abort_line" | sed -E 's/^- 中断理由: \{//; s/\}.*//' | tr '|' '\n' | tr -d ' ' | grep -E '^[a-z_]+$' | sort -u)"
assert_eq "(B-2) 中断報告テンプレートの候補が語彙表と一致する（定義だけ増えて報告に載らない状態を防ぐ）" "$vocab_codes" "$report_codes"

# 規律の正本（戦略ドキュメント 5.7）の列挙と語彙表が双方向で一致する
strategy_abort_block="$(awk '/保証節を確定できない場合は Issue を作成しない/{f=1} f{print} /この5つの中断理由コードの語彙/{f=0}' "$STRATEGY_FILE")"
strategy_codes="$(printf '%s\n' "$strategy_abort_block" | grep -o -E '`[a-z][a-z_]*`' | tr -d '`' | sort -u)"
assert_eq "(B-2) 戦略ドキュメント 5.7 の中断条件の列挙が語彙表と一致する" "$vocab_codes" "$strategy_codes"

# 前提の確認表（要件モードの4件）と分解-1（実装分解モードの1件）が語彙表に含まれる
table_codes="$(grep -o -E '[*][*]中断[*][*]（`[a-z_]+`）' "$REF_FILE" | sed -E 's/.*`([a-z_]+)`.*/\1/' | sort -u)"
missing_codes=""
for code in $table_codes; do
  printf '%s\n' "$vocab_codes" | grep -qx -- "$code" || missing_codes="${missing_codes}${code} "
done
assert_eq "(B-2) 前提の確認表の reason コードがすべて語彙表に定義されている" "" "$missing_codes"
table_code_count="$(printf '%s\n' "$table_codes" | grep -c .)"
assert_eq "(B-2) 前提の確認表の reason コードは4件（要件モード分）" "4" "$table_code_count"
assert_ref_contains "分解-1 の中断理由が語彙表の一員として書かれている" \
  '`中断理由` は共通-1 の語彙表にある `parent_guarantee_section_missing`'
assert_ref_contains "コード増減時に語彙表と報告テンプレートを同時更新する規律がある" \
  '**コードを増減するときは、この表と下記の中断報告テンプレートの `中断理由` を必ず同時に更新する**'
assert_file_contains "戦略ドキュメントが語彙の正本の所在を示している" "$STRATEGY_FILE" \
  '**この5つの中断理由コードの語彙は `skills/create-ticket/references/guarantee-section.md` 共通-1 の表が正本**'

echo ""
echo "=== (B-3) 読み取り規則の一致（同じファイルを2つの規則で読まない） ==="

assert_ref_contains "台帳をスクリプトと同じ規則で読むと明示している" \
  '台帳は索引チェック（`guarantee-index-check`）と**同じ規則で読む**こと'
assert_ref_contains "台帳の文法を親Issue本文へ適用しないと明示している" \
  '**台帳の文法（後述の (b)）を親Issue本文に適用しないこと**'
assert_ref_contains "誤適用すると正常な親Issueが全件はじかれると明示している" \
  '**正しく作られた親Issueが「書式を解釈できない」「件数不一致」と誤判定され、分解-1 が実装チケットの作成を全件止めてしまう**'
assert_ref_contains "件数の突き合わせは台帳にだけ行うと明示している" \
  '**親Issue本文に対してこの突き合わせを行わない**'
assert_ref_contains "親Issueの ### 見出しはカテゴリ見出しであると明示している" \
  '**「保証」節内の `### ` 見出しはカテゴリ見出し**'
assert_ref_contains "親Issueの保証 ID はリスト行にあると明示している" \
  '**保証 ID は見出し行ではなく、カテゴリ配下のリスト行にある**'
assert_ref_contains "カテゴリ見出しが ID を持たないことを解釈不能の理由にしない" \
  '**カテゴリ見出しが保証 ID を持たないことを理由に「解釈できない」と判定しない**'
assert_ref_contains "解釈できないと判定してよい条件を限定している" \
  '**「書式を解釈できない」と判定してよいのは**'
assert_ref_contains "親Issue文法が promote-verify 5.5-3 と同一だと明示している" \
  '下流の `/promote-verify`（Step 5.5-3）が親Issueを読む規則と同一'
assert_file_contains "分解-1 が台帳の文法を適用しないと明示している" "$REF_FILE" \
  '**(b) 台帳の文法は適用しない**'
assert_file_contains "promote-verify 側も親Issueへの適用範囲を限定している" "$CONSUMER_FILE" \
  '**親Issueへ適用してよいのはフェンス・節の範囲・チェックリスト行の扱いだけ**'
assert_ref_contains "2つの規則で読む状態が危険であると明示している" \
  '**同じファイルを2つの規則で読む**状態になる'
assert_ref_contains "フェンス内は判定対象外" \
  '**コードフェンス（``` / ~~~。行頭スペース3個まで）の内側は、台帳・Issue 本文とも一切の判定対象にしない**'
assert_ref_contains "保証は「保証」節の中だけを見る" '**保証は「保証」節の中だけを見る**'
assert_ref_contains "節外の見出しは登録済みとみなさない" '**節の外にある `### G-...` は登録済みとみなさない**'
assert_ref_contains "件数の突き合わせは節内の ### 見出しの総数で行う" \
  '**件数の突き合わせに使うのは「保証」節内の `### ` 見出しの総数**である'
assert_ref_contains "維持に挙げてよいのは ID 書式を満たす見出しだけ" \
  '**維持する保証に挙げてよいのは ID 書式を満たす見出しだけ**'
assert_ref_contains "チェック状態で対象を絞らない" \
  'チェック状態を対象の絞り込みにも判定にも使わない'
assert_ref_contains "食い違ったらどちらかを採用して進めない" \
  '**多い方・少ない方のどちらかを採用して先に進めない**'
assert_ref_contains "パース規約の正本を spec で示している" \
  '`scripts/specs/guarantee-index-check.md`'

echo ""
echo "=== (B-4) 保証節の書式と組み立て（空虚な真のガード） ==="

assert_ref_contains "3見出しをすべて置き、該当が無ければ「- なし」を書く" \
  '**該当が無い見出しには `- なし` の1行を書く**'
assert_ref_contains "空欄が「調べていない」と「0件」を区別できないと明示している" \
  '空欄は「調べていない」と「調べた結果0件」を区別できず'
assert_ref_contains "新規宣言は受入基準 AC-n に対応付ける" '受入基準の ID（`AC-n`）を書き'
assert_ref_contains "宣言できるのは自 Issue スコープの ID だけ" \
  '**この Issue が宣言できるのは `G-<この Issue の番号>-` で始まる ID だけ**'
assert_ref_contains "他 Issue の番号の ID を書かない" '他 Issue の番号を使った ID をここに書かない'
assert_ref_contains "維持の突き合わせは台帳の全件を対象にする" \
  '**突き合わせは台帳の全件を対象にする**'
assert_ref_contains "一部だけ見て「なし」と書かない（部分成功≠完全成功）" \
  '一部だけ見て「なし」と書かない'
assert_ref_contains "迷ったら維持側に入れる（安全側）" '影響しうるか判断に迷うものは**維持側に入れる**'
assert_ref_contains "約束文の正は常に台帳" '**約束文の正は常に台帳**'
assert_ref_contains "台帳に存在しない ID を書かない" '**台帳に存在しない ID を書かない**'
assert_ref_contains "判定保留は下流の機械処理が読まないと明示している" \
  '**この節は下流の機械処理（`/promote-verify` の保証整合チェック）が読まない**'
assert_ref_contains "判定保留が1件でもあれば裁可状態へ反映する" \
  '**1件でもある場合は、完了報告の裁可状態を `要人間判定あり` にする**'
assert_ref_contains "迷ったものをどちらかへ倒さない" '**判定に迷うものはどちらかへ倒さない**'
assert_ref_contains "単独タスクの起票にも同じ規約を適用する" \
  '**単独タスク（バグ修正・ドキュメント更新など、親要件チケットを伴わない起票）を要件モードに準じて作成する場合も、本節の規約をそのまま適用する**'

echo ""
echo "=== (B-5) 保証 ID の確定手順と異常系の出力契約 ==="

assert_ref_contains "作成→置換→検証の3ステップを必ず通す" \
  '**作成 → 置換 → 検証の3ステップを必ず通す**（仮 ID を残したまま完了にしない）'
assert_ref_contains "ラベルは作成と同じ呼び出しで付ける" '**ラベルは作成と同じ呼び出しで付ける**'
assert_ref_contains "検証(i) 新規宣言配下にプレースホルダが残っていないこと" \
  '(i) 「### 新たに宣言する保証」配下に `{ISSUE_NUMBER}` が**1箇所も残っていない**'
assert_ref_contains "検証(i) 保証節の外の {ISSUE_NUMBER} は転記であり残っていて正しい" \
  '保証節の外に残っている `{ISSUE_NUMBER}` は機能仕様からの転記であり、**残っていることが正しい**'
assert_ref_contains "検証(ii) 差分が新規宣言の行だけであることを確認する" \
  '(ii) **置換前後の本文の差分が、「### 新たに宣言する保証」配下の行だけである**'
assert_ref_contains "置換対象は生成した ID に限定する" \
  '**置換してよいのは「### 新たに宣言する保証」配下で自分が生成した ID の `{ISSUE_NUMBER}` だけ**'
assert_ref_contains "本文全体への一括置換を禁じている" '**本文全体への一括置換をしないこと**'
assert_ref_contains "転記部分は1文字も変更しない" '**転記部分（保証節より前の本文）は1文字も変更しない**'
assert_ref_contains "プレースホルダを新規宣言の行以外に書かない" \
  '**このプレースホルダを本節の新規宣言の行以外に書かないこと**'
assert_file_not_contains "本文中を「すべて」置換する旧記述が残っていない" "$REF_FILE" \
  '本文中の `{ISSUE_NUMBER}` を**すべて**'
assert_ref_contains "検証(iii) 完全な ID 文法に一致すること" \
  '(iii) 新規宣言の各 ID が**完全な ID 文法 `G-<N>-<枝番>` に一致する**'
assert_ref_contains "検証(iii) 枝番は1文字以上の数字だけ" \
  '`<枝番>` は**1文字以上の数字だけ**'
assert_ref_contains "検証(iii) 接頭辞一致だけで通さない" \
  '**接頭辞 `G-<N>-` の一致だけで通さない**'
assert_ref_contains "検証(iii) はハイフンまで含めて比較する" \
  '比較はハイフンまで含めて行い `G-1580-` / `G-15-` と取り違えない'
assert_ref_contains "検証(iv) 枝番の連番・一意性を確認する" \
  '(iv) 枝番が **1 から始まる連番**で、**重複が無い**'
assert_ref_contains "検証(v) proposed ラベルが付いていること" \
  '(v) `guarantee:proposed` ラベルが付いている'
assert_ref_contains "接頭辞一致で済ませない理由（黙って抜け落ちる）を明示している" \
  '**壊れた保証が黙って検証対象から抜け落ちたまま「裁可可」と報告される**'
assert_ref_contains "要件-1 が枝番の連番・一意を課している" \
  '**枝番は 1 から始まる連番の整数**（`-1`, `-2`, …）とし、**重複させない**'
assert_ref_contains "失敗時の報告に ID 文法・枝番の結果を含める" \
  '| ID の文法・枝番 | (iii)(iv) の結果'
assert_ref_contains "失敗時は成功として報告しない" '**2 または 3 が失敗した場合の扱い（成功として報告しない）**'
assert_ref_contains "失敗時の報告項目をすべて埋める（推測で埋めない）" \
  '次の項目を**すべて埋めて**要人間対応として報告する（埋められない項目を省略・推測で埋めない）'
assert_ref_contains "検証できなかった項目は「確認できず」と書く" '「確認できず」と書く'
assert_ref_contains "未確定の状態では裁可しないよう明記する" '**裁可しないでください**'

echo ""
echo "=== (B-6) 裁可ラベルの運用（D-12・エージェントは裁可しない） ==="

assert_ref_contains "proposed はエージェントが Issue 作成時に付与する" \
  '本スキルが Issue 作成時に付与する'
assert_ref_contains "approved は人間が付け替える" \
  '人間が `guarantee:proposed` を外して付け替える'
assert_ref_contains "エージェントは approved を付けない" \
  '**エージェントは `guarantee:approved` を付けない**'
assert_ref_contains "裁可ゲートの強制は para-impl の責務" \
  '**裁可ゲートの強制（`guarantee:approved` が無ければ実装を始めない）は `/para-impl` 側の責務**であり、本スキルは強制しない'
assert_ref_contains "ラベル存在確認は完全一致で行う" \
  '`name` の**完全一致**で `guarantee:proposed` の存在を確認する（部分一致検索に頼らない）'
assert_ref_contains "already exists は存在扱いにする（打ち切り対策）" \
  '**既に存在する旨のエラーは「存在する」として扱う**'
assert_ref_contains "proposed を用意できなければ中断する" \
  'それ以外のエラーで作成できなければ `label_unavailable` として中断する'
assert_ref_contains "approved のラベル定義の用意は裁可を意味しない" \
  '**定義を用意することは裁可を意味しない**（付与は人間だけが行う）'
assert_ref_contains "approved の定義を用意できなくても中断しない" \
  'こちらは用意できなくても**中断しない**'

echo ""
echo "=== (B-7) 完了報告の裁可状態（要人間判定を判定式へ接続する） ==="

assert_ref_contains "裁可状態を必ず書く" \
  '**`裁可状態` は必ず書く**（判定保留を記録だけして報告に出さない、という状態を作らない）'
assert_ref_contains "裁可状態の3値以外を作らない" '`裁可状態` の値の決め方（この対応以外の値を作らない）'
assert_ref_contains "裁可可の条件（検証5項目＋判定保留0件）" \
  '要件-2 の検証(i)(ii)(iii)(iv)(v)をすべて満たし、**かつ**判定保留が0件'

# 完全性 join: 要件-2 が定義する検証項目と、裁可状態の表が参照する項目が一致する
# （検証項目を足して裁可条件へ接続し忘れると落ちる）
verify_labels="$(awk '/^3\. \*\*検証\*\*/{f=1} /^\*\*2 または 3 が失敗した場合/{f=0} f && /^   - \(/{print}' "$REF_FILE" \
  | sed -E 's/^   - \(([iv]+)\).*/\1/' | tr '\n' ',' | sed 's/,$//')"
approve_labels="$(grep -F -- '| `裁可可` |' "$REF_FILE" | grep -o -E '\([iv]+\)' | tr -d '()' | tr '\n' ',' | sed 's/,$//')"
pending_labels="$(grep -F -- '| `要人間判定あり` |' "$REF_FILE" | grep -o -E '\([iv]+\)' | tr -d '()' | tr '\n' ',' | sed 's/,$//')"
assert_eq "(B-7) 要件-2 の検証項目は (i)〜(v) の5件" "i,ii,iii,iv,v" "$verify_labels"
assert_eq "(B-7) 裁可可の条件が検証項目を全件参照している" "$verify_labels" "$approve_labels"
assert_eq "(B-7) 要人間判定ありの条件も検証項目を全件参照している" "$verify_labels" "$pending_labels"
assert_ref_contains "検証の件数が本文と一致している" '次の5点を確認する'
assert_ref_contains "要人間判定ありの条件" '判定保留が1件以上ある'
assert_ref_contains "未完了の条件" '要件-2 の検証のいずれかを満たさない'
assert_ref_contains "完了報告に索引整合チェックの結果を転記する" '- 索引整合チェック: status='
assert_ref_contains "完了報告に人間の次操作を書く" \
  '承認するならラベルを guarantee:proposed → guarantee:approved に付け替える'

assert_eq "(B-7) 検証全通過・判定保留0件 → 裁可可" "裁可可" "$(ct_approval_status 0 0 0 0)"
assert_eq "(B-7) 検証全通過でも判定保留1件 → 要人間判定あり（黙って裁可可にしない）" "要人間判定あり" "$(ct_approval_status 0 0 0 1)"
assert_eq "(B-7) プレースホルダ残存 → 未完了" "未完了" "$(ct_approval_status 1 0 0 0)"
assert_eq "(B-7) ID スコープ不一致 → 未完了" "未完了" "$(ct_approval_status 0 1 0 0)"
assert_eq "(B-7) ラベル欠落 → 未完了" "未完了" "$(ct_approval_status 0 0 1 0)"
assert_eq "(B-7) 判定保留0件でも検証未通過なら未完了（0件が通過の根拠にならない）" "未完了" "$(ct_approval_status 1 0 0 0)"

echo ""
echo "=== (B-8) 実装分解モードの保証参照（裁可の単位は親Issue） ==="

assert_ref_contains "親に保証節が無ければ1件も作成せず中断する" \
  '**節が無い／書式を解釈できない場合は、実装チケットを1件も作成せずに中断する**'
assert_ref_contains "親Issue本文のフェンス内引用を節の存在とみなさない" \
  '**Issue 本文がテンプレートや台帳の書式例を引用している場合、フェンス内の `## 保証（Guarantees）` を節の存在とみなさない**'
assert_ref_contains "親の裁可状態を取得して完了報告に転記する" \
  '**本スキルは裁可の有無で分解を止めない**（裁可ゲートの強制は `/para-impl` の責務）'
assert_ref_contains "実装チケットには保証参照の1行を入れる" '保証: 親#{親Issue番号} の保証節参照'
assert_ref_contains "親の保証節の内容を子へ転記しない" \
  '**親の保証節の内容（ID・約束文）を実装チケット本文へ転記しない**'
assert_ref_contains "実装チケットには裁可ラベルを付けない" \
  '**実装チケットには裁可ラベル（`guarantee:proposed` / `guarantee:approved`）を付けない**'
assert_ref_contains "裁可未了なら para-impl の前に人間の裁可が必要と書く" \
  '`/para-impl` の前に人間の裁可が必要である旨を明記する'

echo ""
echo "=== (B-9) モード別参照ファイルとテンプレート（GDD 専用ブロックへの封じ込め） ==="

assert_file_contains "要件モードに保証節の GDD フックがある" "$REQ_FILE" \
  '「## 保証（Guarantees）」節を**必須**で含める'
assert_file_contains "要件モードに裁可ラベルの GDD フックがある" "$REQ_FILE" \
  '`--label "guarantee:proposed"`（裁可待ちの表示）を加え'
assert_file_contains "要件モードの完了報告に GDD フックがある" "$REQ_FILE" '「## 保証（GDD期）」節'
assert_file_contains "実装分解モードに親の保証節確認のフックがある" "$DEC_FILE" \
  '**実装チケットを1件も作成せずに中断する**'
assert_file_contains "実装分解モードに保証参照行のフックがある" "$DEC_FILE" \
  '`保証: 親#{親Issue番号} の保証節参照` の1行を含める'
assert_file_contains "実装分解モードが子に裁可ラベルを付けないと明示している" "$DEC_FILE" \
  '**実装チケットには裁可ラベル（`guarantee:proposed` / `guarantee:approved`）を付けない**'
assert_file_contains "テンプレートに保証参照行がある" "$TPL_FILE" '保証: 親#{親チケット番号} の保証節参照'
assert_file_contains "テンプレートの保証参照行が gdd 判定時限定であると注記している" "$TPL_FILE" \
  '開発フェーズの判定が gdd のときのみ、次行を残して親Issue番号を記入'
assert_file_contains "テンプレートが判定手段を detect-dev-phase に限定している" "$TPL_FILE" \
  '判定は detect-dev-phase の'
assert_file_contains "テンプレートが CLAUDE.md の自前 grep を禁じている" "$TPL_FILE" \
  'CLAUDE.md を自分で grep しない'
assert_file_contains "テンプレートが sdd 判定時に行を削除すると注記している" "$TPL_FILE" \
  '判定が sdd（フェーズ宣言なしを含む）のときはこの行を削除する。'
assert_file_not_contains "テンプレートに CLAUDE.md を直接読む判定表現が残っていない" "$TPL_FILE" \
  'CLAUDE.md のフェーズ宣言が GDD期'
assert_file_contains "テンプレートが子にラベルを付けないと注記している" "$TPL_FILE" \
  '実装チケットにはラベルを付けない。'

# 構造不変条件: GDD 固有の記述は「> **GDD期のみ」で始まる行だけに閉じ込める（default-OFF）
gdd_leak=""
hook_count_req=0
hook_count_dec=0
missing_sdd_note=""
for mode_file in "$REQ_FILE" "$DEC_FILE"; do
  while IFS= read -r leaked; do
    [ -n "$leaked" ] || continue
    gdd_leak="${gdd_leak}${mode_file}:${leaked} "
  done <<<"$(grep -n -E '保証節|保証: 親#|guarantee:|guarantee-section\.md|保証（Guarantees）' "$mode_file" | grep -v -E '^[0-9]+:> \*\*GDD期のみ' | cut -d: -f1)"

  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    if ! printf '%s' "$hook" | grep -qF -- '`sdd`（フェーズ宣言なしを含む）では本項を実行せず'; then
      missing_sdd_note="${missing_sdd_note}${mode_file} "
    fi
    if [ "$mode_file" = "$REQ_FILE" ]; then
      hook_count_req=$((hook_count_req + 1))
    else
      hook_count_dec=$((hook_count_dec + 1))
    fi
  done <<<"$(grep -E '^> \*\*GDD期のみ' "$mode_file")"
done

assert_eq "(B-9) GDD 固有の記述がモード別手順の本体へ漏れていない" "" "$gdd_leak"
assert_eq "(B-9) 要件モードの GDD フックは3箇所（本文・作成・完了報告）" "3" "$hook_count_req"
assert_eq "(B-9) 実装分解モードの GDD フックは3箇所（親確認・チケット作成・完了報告）" "3" "$hook_count_dec"
assert_eq "(B-9) 全 GDD フックが SDD期の不変を明記している" "" "$missing_sdd_note"

echo ""
echo "=== (B-10) 構造不変条件: エージェントが裁可しない / 表の欠落を検出する ==="

# エージェントが guarantee:approved を付与する指示が skills/ 配下に存在しない
approve_cmd="$(grep -rn -E '(--label|--add-label)[[:space:]]+"?guarantee:approved' "${REPO_ROOT}/skills" || true)"
assert_eq "(B-10) approved ラベルを付与する指示が skills/ 配下に無い" "" "$approve_cmd"

# 検出パターン自体の自己検査（grep は「マッチなし」と「パターンが壊れた」を区別しないため）
violating_sample='gh issue edit 1 --add-label "guarantee:approved"'
if printf '%s\n' "$violating_sample" | grep -qE '(--label|--add-label)[[:space:]]+"?guarantee:approved'; then
  detector="works"
else
  detector="broken"
fi
assert_eq "(B-10) 上記の検出パターンが既知の違反形を検出できる（自己検査）" "works" "$detector"

legit_sample='人間が `gh issue edit --add-label` で裁可する際にラベル定義が無いと失敗するため'
if printf '%s\n' "$legit_sample" | grep -qE '(--label|--add-label)[[:space:]]+"?guarantee:approved'; then
  detector_fp="false-positive"
else
  detector_fp="clean"
fi
assert_eq "(B-10) 検出パターンが正当な言及を誤検出しない（自己検査）" "clean" "$detector_fp"

# 中断条件表: 4行すべてに reason コードと「中断」がある（行を足して reason を書き忘れると落ちる）
abort_table="$(awk '/^### 共通-1\./{f=1} /^\*\*中断理由コードの語彙/{f=0} f && /^\|/{print}' "$REF_FILE" | grep -v -E '^\|[[:space:]]*(前提|-+)')"
abort_rows="$(printf '%s\n' "$abort_table" | grep -c '^|')"
abort_rows_with_reason="$(printf '%s\n' "$abort_table" | grep -c -E '\*\*中断\*\*（`[a-z_]+`）')"
assert_eq "(B-10) 前提の確認表は4行ある" "4" "$abort_rows"
assert_eq "(B-10) 前提の確認表の全行に中断と reason コードがある" "$abort_rows" "$abort_rows_with_reason"

# 失敗時の報告項目表: 5行すべてに内容が埋まっている（空セルを許さない）
report_table="$(awk '/^\*\*2 または 3 が失敗した場合の扱い/{f=1} f && /^\|/{print} /^### 要件-3\./{f=0}' "$REF_FILE" | grep -v -E '^\|[[:space:]]*(報告項目|-+)')"
report_rows="$(printf '%s\n' "$report_table" | grep -c '^|')"
report_empty="$(printf '%s\n' "$report_table" | grep -c -E '\|[[:space:]]*\|')"
assert_eq "(B-10) 失敗時の報告項目表は6行ある" "6" "$report_rows"
assert_eq "(B-10) 失敗時の報告項目表に空セルが無い（未定義のまま残さない）" "0" "$report_empty"

# 裁可状態の表: 3行・値は3種のみ
status_table="$(awk '/^`裁可状態` の値の決め方/{f=1} f && /^\|/{print} /^---$/{f=0}' "$REF_FILE" | grep -v -E '^\|[[:space:]]*(値|-+)')"
status_rows="$(printf '%s\n' "$status_table" | grep -c '^|')"
assert_eq "(B-10) 裁可状態の表は3行ある" "3" "$status_rows"
status_values="$(printf '%s\n' "$status_table" | sed -E 's/^\|[[:space:]]*`?([^`|]+)`?[[:space:]]*\|.*/\1/' | tr '\n' ',' | sed 's/,$//')"
assert_eq "(B-10) 裁可状態の値は3種のみ" "裁可可,要人間判定あり,未完了" "$status_values"

# 参照ファイルの節構成（手順の欠落検出）
missing_sections=""
for heading in "### 共通-1." "### 共通-2." "### 共通-3." "### 要件-1." "### 要件-2." "### 要件-3." "### 要件-4." "### 分解-1." "### 分解-2."; do
  grep -qF -- "$heading" "$REF_FILE" || missing_sections="${missing_sections}${heading} "
done
assert_eq "(B-10) 参照ファイルに全サブステップの見出しが存在する" "" "$missing_sections"

assert_ref_contains "参照ファイルは SKILL.md 側で完了している前提を明示している" "**本ファイルの前提**"
assert_ref_contains "参照ファイルは SKILL.md が正本の規律を複製しないと明示している" "本ファイルには複製しない"
assert_ref_contains "参照ファイルはモード別手順に上乗せする位置づけを明示している" \
  '**本ファイルの手順は、モード別参照ファイル（`requirement-mode.md` / `decompose-mode.md`）の手順に上乗せする**'

# 緩和の再発防止（あってはならない文言）
assert_file_not_contains "SKILL.md に invalid を sdd へ倒す文言が無い" "$SKILL_FILE" 'sdd とみなす'
assert_file_not_contains "実装分解モードが子へ裁可ラベルを付ける指示を持たない" "$DEC_FILE" \
  '--label "guarantee:proposed"'

# ---------------------------------------------------------------------------
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
