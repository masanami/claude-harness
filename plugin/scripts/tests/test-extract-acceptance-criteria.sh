#!/bin/bash
# test-extract-acceptance-criteria.sh
# scripts/extract-acceptance-criteria.sh のパース関数（parse_acceptance_criteria）を
# gh API を呼ばずに直接テストする。
#
# 実行方法: bash scripts/tests/test-extract-acceptance-criteria.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../extract-acceptance-criteria.sh"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# --- アサーションヘルパー ---

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

# --- フィクスチャ: feature-spec.md 由来（## 受入基準） ---

read -r -d '' FIXTURE_FEATURE_SPEC <<'EOF'
# サンプル機能

## 概要

サンプル機能の概要。

## 受入基準

- [ ] ユーザーはログインできる
- [x] ログイン失敗時にエラーメッセージが表示される

## 参照

- 何かのリンク
EOF

# --- フィクスチャ: implementation-ticket.md 由来（## 完了条件） ---

read -r -d '' FIXTURE_IMPLEMENTATION_TICKET <<'EOF'
# タスク名

Parent: #100

## 概要

タスクの概要。

## 完了条件

- [ ] APIエンドポイントが実装されている
- [ ] 単体テストが追加されている
- [x] 既存テストがパスする

## 技術的な指示

### 変更対象ファイル

- `src/foo.ts`（新規作成）
EOF

# --- フィクスチャ: チェックリストが無い本文 ---

read -r -d '' FIXTURE_NO_CHECKLIST <<'EOF'
# 手書きIssue

## 背景

チェックリストの無い、手で書かれたIssue本文。

## やること

よしなに直す。
EOF

read -r -d '' FIXTURE_BOTH_SECTIONS <<'EOF'
# 機能 + 実装タスク

## 受入基準

- [ ] ユーザーがログインできる
- [x] エラーが表示される

## 完了条件

- [ ] APIが実装されている
- [ ] テストが追加されている
EOF

echo "=== test: 受入基準セクション（feature-spec形式）からのチェックリスト抽出 ==="
parse_acceptance_criteria "$FIXTURE_FEATURE_SPEC"
assert_eq "parse_status が ok" "ok" "$PARSE_STATUS"
assert_eq "criteria が2件" "2" "$(jq 'length' <<<"$CRITERIA_JSON")"
assert_eq "1件目のid が AC-1" "AC-1" "$(jq -r '.[0].id' <<<"$CRITERIA_JSON")"
assert_eq "1件目のtext" "ユーザーはログインできる" "$(jq -r '.[0].text' <<<"$CRITERIA_JSON")"
assert_eq "2件目のid が AC-2" "AC-2" "$(jq -r '.[1].id' <<<"$CRITERIA_JSON")"

echo "=== test: 完了条件セクション（implementation-ticket形式）からのチェックリスト抽出 ==="
parse_acceptance_criteria "$FIXTURE_IMPLEMENTATION_TICKET"
assert_eq "parse_status が ok" "ok" "$PARSE_STATUS"
assert_eq "criteria が3件" "3" "$(jq 'length' <<<"$CRITERIA_JSON")"
assert_eq "1件目のtext" "APIエンドポイントが実装されている" "$(jq -r '.[0].text' <<<"$CRITERIA_JSON")"

echo "=== test: checked/uncheckedフィールドが正しい ==="
parse_acceptance_criteria "$FIXTURE_FEATURE_SPEC"
assert_eq "1件目（- [ ]）は checked=false" "false" "$(jq -r '.[0].checked' <<<"$CRITERIA_JSON")"
assert_eq "2件目（- [x]）は checked=true" "true" "$(jq -r '.[1].checked' <<<"$CRITERIA_JSON")"

parse_acceptance_criteria "$FIXTURE_IMPLEMENTATION_TICKET"
assert_eq "3件目（- [x]）は checked=true" "true" "$(jq -r '.[2].checked' <<<"$CRITERIA_JSON")"
assert_eq "2件目（- [ ]）は checked=false" "false" "$(jq -r '.[1].checked' <<<"$CRITERIA_JSON")"

echo "=== test: チェックリストが無い本文で no_checklist_found ==="
parse_acceptance_criteria "$FIXTURE_NO_CHECKLIST"
assert_eq "parse_status が no_checklist_found" "no_checklist_found" "$PARSE_STATUS"
assert_eq "criteria が空配列" "0" "$(jq 'length' <<<"$CRITERIA_JSON")"

echo "=== test: IDがAC-1からの安定連番であること ==="
parse_acceptance_criteria "$FIXTURE_IMPLEMENTATION_TICKET"
assert_eq "全件のidが順にAC-1,AC-2,AC-3" "AC-1 AC-2 AC-3" "$(jq -r '[.[].id] | join(" ")' <<<"$CRITERIA_JSON")"

echo "=== test: 両セクション混在時に通しIDが振られること ==="
parse_acceptance_criteria "$FIXTURE_BOTH_SECTIONS"
assert_eq "parse_status が ok" "ok" "$PARSE_STATUS"
assert_eq "criteria が4件" "4" "$(jq 'length' <<<"$CRITERIA_JSON")"
assert_eq "全件のidが順にAC-1,AC-2,AC-3,AC-4" "AC-1 AC-2 AC-3 AC-4" "$(jq -r '[.[].id] | join(" ")' <<<"$CRITERIA_JSON")"
assert_eq "セクション跨ぎでもtextが正しい（3件目=完了条件の1件目）" "APIが実装されている" "$(jq -r '.[2].text' <<<"$CRITERIA_JSON")"

echo "=== test: CRLF改行の本文でも text にCRが混入しない ==="
FIXTURE_CRLF=$(printf '## 受入基準\r\n\r\n- [ ] ログインできる\r\n- [x] エラーが表示される\r\n')
parse_acceptance_criteria "$FIXTURE_CRLF"
assert_eq "parse_status が ok" "ok" "$PARSE_STATUS"
assert_eq "1件目のtextにCRが混入していない" "ログインできる" "$(jq -r '.[0].text' <<<"$CRITERIA_JSON")"
assert_eq "2件目のtextにCRが混入していない" "エラーが表示される" "$(jq -r '.[1].text' <<<"$CRITERIA_JSON")"

echo "=== test: CLIレベル（--stdin, ghを呼ばない）での統合確認 ==="
CLI_OUTPUT=$(printf '%s' "$FIXTURE_FEATURE_SPEC" | "$TARGET_SCRIPT" --stdin)
CLI_EXIT=$?
assert_eq "exit code が 0" "0" "$CLI_EXIT"
assert_eq "issueフィールドがnull" "null" "$(jq -r '.issue' <<<"$CLI_OUTPUT")"
assert_eq "parse_statusがok" "ok" "$(jq -r '.parse_status' <<<"$CLI_OUTPUT")"
assert_eq "criteriaが2件" "2" "$(jq '.criteria | length' <<<"$CLI_OUTPUT")"

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
