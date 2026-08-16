#!/bin/bash
# test-detect-dev-phase.sh
# scripts/detect-dev-phase.sh のフェーズ判定（CLAUDE.md の宣言パース）と CLI 契約
# （stdout JSON / exit code / 判定対象ファイルの解決）をテストする。gh 非依存。
#
# 実行方法: bash scripts/tests/test-detect-dev-phase.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # フィクスチャ内のバッククォート（コードフェンス・値の囲み）は
# Markdown のリテラルであり、シェル展開を意図していない
set -u

DETECT_DEV_PHASE_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${DETECT_DEV_PHASE_TEST_DIR}/../detect-dev-phase.sh"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

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

# 本文を渡して {phase}/{reason} を検証するヘルパ。
assert_scan() {
  local description="$1"
  local expected_phase="$2"
  local expected_reason="$3"
  local body="$4"

  detect_dev_phase_scan "$body"
  assert_eq "${description}（phase）" "$expected_phase" "$DEV_PHASE_PHASE"
  assert_eq "${description}（reason）" "$expected_reason" "$DEV_PHASE_REASON"
}

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

echo "=== test: 宣言が無い CLAUDE.md は SDD期（後方互換） ==="
assert_scan "見出しごと無い" "sdd" "no_phase_section" \
  "$(printf '# プロジェクト\n\n## 技術スタック\n\n- Node.js\n')"
assert_scan "似た名前の見出し（開発フェーズの切り替え）は宣言ではない" "sdd" "no_phase_section" \
  "$(printf '# プロジェクト\n\n## 開発フェーズの切り替え\n\n- **フェーズ**: GDD期\n')"

echo "=== test: 有効な宣言 ==="
assert_scan "GDD期" "gdd" "declared_gdd" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: GDD期\n- 駆動文書: docs/guarantees.md\n')"
assert_scan "SDD期" "sdd" "declared_sdd" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: SDD期\n- 駆動文書: docs/features/\n')"
assert_scan "駆動文書行が欠落していても宣言は有効（判定に使わない）" "gdd" "declared_gdd" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: GDD期\n')"
assert_scan "太字なし・全角コロンも許容" "gdd" "declared_gdd" \
  "$(printf '## 開発フェーズ\n\n- フェーズ：GDD期\n')"
assert_scan "値がバッククォート囲みでも許容" "sdd" "declared_sdd" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: `SDD期`\n')"
assert_scan "装飾が入れ子でも許容（バッククォートの内側に太字）" "gdd" "declared_gdd" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: `**GDD期**`\n')"
assert_scan "装飾が入れ子でも許容（太字の内側にバッククォート）" "gdd" "declared_gdd" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: **`GDD期`**\n')"
assert_scan "宣言の後に別セクションが続いても判定できる" "gdd" "declared_gdd" \
  "$(printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n\n## テスト方針\n\n- テストを書く\n')"

echo "=== test: 不正な宣言は SDD期 へフォールバックせず invalid（D-16） ==="
assert_scan "許容値以外の値" "invalid" "unknown_phase_value" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: GDD\n')"
assert_scan "未置換のテンプレートプレースホルダ" "invalid" "unreplaced_placeholder" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: {DEV_PHASE}\n')"
assert_scan "見出しの複数出現" "invalid" "duplicate_phase_section" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: SDD期\n\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n')"
assert_scan "フェーズ行が無い（見出しと駆動文書行だけ）" "invalid" "missing_phase_field" \
  "$(printf '## 開発フェーズ\n\n- 駆動文書: docs/guarantees.md\n')"
assert_scan "フェーズ行の複数出現" "invalid" "duplicate_phase_field" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: SDD期\n- **フェーズ**: GDD期\n')"
assert_scan "見出し階層が ## ではない（宣言として認識されない書き間違い）" "invalid" "malformed_phase_heading" \
  "$(printf '# プロジェクト\n\n### 開発フェーズ\n\n- **フェーズ**: GDD期\n')"
assert_scan "セクション外（次の見出し以降）のフェーズ行は拾わない" "invalid" "missing_phase_field" \
  "$(printf '## 開発フェーズ\n\n## 補足\n\n- **フェーズ**: GDD期\n')"
assert_scan "サブ見出し配下のフェーズ行も拾わない" "invalid" "missing_phase_field" \
  "$(printf '## 開発フェーズ\n\n### 参考\n\n- **フェーズ**: GDD期\n')"

echo "=== test: コードフェンス内の記述は判定対象外 ==="
assert_scan "フェンス内の宣言例のみ → 宣言なし扱い" "sdd" "no_phase_section" \
  "$(printf '# プロジェクト\n\n宣言の書式例:\n\n```markdown\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n```\n')"
assert_scan "フェンス内の例があってもフェンス外の宣言が正" "sdd" "declared_sdd" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: SDD期\n\n## 参考\n\n```markdown\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n```\n')"
assert_scan "~~~ フェンスも対象" "sdd" "no_phase_section" \
  "$(printf '# プロジェクト\n\n~~~\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n~~~\n')"
assert_scan "フェンス内のフェーズ行だけを除外し宣言は有効に保つ" "gdd" "declared_gdd" \
  "$(printf '## 開発フェーズ\n\n- **フェーズ**: GDD期\n\n```\n- **フェーズ**: SDD期\n```\n')"
assert_scan "4個フェンスの内側の3個バッククォートでは閉じない（宣言なし扱いを維持）" "sdd" "no_phase_section" \
  "$(printf '# プロジェクト\n\n````markdown\n```\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n```\n````\n')"
assert_scan "情報文字列付きの行は閉じフェンスにならない" "sdd" "no_phase_section" \
  "$(printf '# プロジェクト\n\n```markdown\n```text\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n```\n')"
assert_scan "3個フェンスは4個の行でも閉じられる（開始以上の長さ）" "gdd" "declared_gdd" \
  "$(printf '# プロジェクト\n\n```\n- **フェーズ**: SDD期\n````\n\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n')"
assert_scan "異なる記号の行ではフェンスを閉じない" "sdd" "no_phase_section" \
  "$(printf '# プロジェクト\n\n```\n~~~\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n```\n')"

echo "=== test: CRLF 改行でも判定できる ==="
assert_scan "CRLF の CLAUDE.md" "gdd" "declared_gdd" \
  "$(printf '## 開発フェーズ\r\n\r\n- **フェーズ**: GDD期\r\n')"

echo "=== test: dev_phase_trim（値の正規化） ==="
assert_eq "前後の空白を除去" "GDD期" "$(dev_phase_trim "  GDD期  ")"
assert_eq "太字装飾を除去" "GDD期" "$(dev_phase_trim "**GDD期**")"
assert_eq "バッククォートを除去" "GDD期" "$(dev_phase_trim '`GDD期`')"
assert_eq "入れ子の装飾を除去順に依存せず除去（バッククォート→太字）" "GDD期" "$(dev_phase_trim '`**GDD期**`')"
assert_eq "入れ子の装飾を除去順に依存せず除去（太字→バッククォート）" "GDD期" "$(dev_phase_trim '**`GDD期`**')"

echo "=== test: CLI（cwd の CLAUDE.md を判定する） ==="
GDD_DIR="${TMP_ROOT}/gdd-project"
mkdir -p "$GDD_DIR"
printf '# P\n\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n- 駆動文書: docs/guarantees.md\n' > "${GDD_DIR}/CLAUDE.md"
CLI_OUT="$(cd "$GDD_DIR" && bash "$TARGET_SCRIPT" 2>/dev/null)"
CLI_EXIT=$?
assert_eq "exit code が 0" "0" "$CLI_EXIT"
assert_eq "phase が gdd" "gdd" "$(jq -r '.phase' <<<"$CLI_OUT")"
assert_eq "reason が declared_gdd" "declared_gdd" "$(jq -r '.reason' <<<"$CLI_OUT")"
assert_eq "source が cwd の CLAUDE.md" "CLAUDE.md" "$(jq -r '.source' <<<"$CLI_OUT")"

echo "=== test: CLI（invalid は exit 1 かつ stdout に JSON を返す） ==="
INVALID_DIR="${TMP_ROOT}/invalid-project"
mkdir -p "$INVALID_DIR"
printf '# P\n\n## 開発フェーズ\n\n- **フェーズ**: GDD\n' > "${INVALID_DIR}/CLAUDE.md"
INVALID_OUT="$(cd "$INVALID_DIR" && bash "$TARGET_SCRIPT" 2>/dev/null)"
INVALID_EXIT=$?
assert_eq "exit code が 1" "1" "$INVALID_EXIT"
assert_eq "phase が invalid" "invalid" "$(jq -r '.phase' <<<"$INVALID_OUT")"
assert_eq "reason が unknown_phase_value" "unknown_phase_value" "$(jq -r '.reason' <<<"$INVALID_OUT")"

echo "=== test: CLI（CLAUDE.md が無い場合は SDD期・source は null） ==="
NO_CLAUDE_DIR="${TMP_ROOT}/no-claude-md"
mkdir -p "$NO_CLAUDE_DIR"
NO_CLAUDE_OUT="$(cd "$NO_CLAUDE_DIR" && bash "$TARGET_SCRIPT" 2>/dev/null)"
NO_CLAUDE_EXIT=$?
assert_eq "exit code が 0" "0" "$NO_CLAUDE_EXIT"
assert_eq "phase が sdd" "sdd" "$(jq -r '.phase' <<<"$NO_CLAUDE_OUT")"
assert_eq "reason が no_claude_md" "no_claude_md" "$(jq -r '.reason' <<<"$NO_CLAUDE_OUT")"
assert_eq "source が null" "null" "$(jq -r '.source' <<<"$NO_CLAUDE_OUT")"

echo "=== test: CLI（引数で判定対象パスを明示できる） ==="
EXPLICIT_OUT="$(bash "$TARGET_SCRIPT" "${GDD_DIR}/CLAUDE.md" 2>/dev/null)"
EXPLICIT_EXIT=$?
assert_eq "exit code が 0" "0" "$EXPLICIT_EXIT"
assert_eq "phase が gdd" "gdd" "$(jq -r '.phase' <<<"$EXPLICIT_OUT")"
assert_eq "source が指定パスそのまま" "${GDD_DIR}/CLAUDE.md" "$(jq -r '.source' <<<"$EXPLICIT_OUT")"

echo "=== test: CLI（実行前提の欠落は exit 2 で stdout は空） ==="
MISSING_OUT="$(bash "$TARGET_SCRIPT" "${TMP_ROOT}/nonexistent/CLAUDE.md" 2>/dev/null)"
MISSING_EXIT=$?
assert_eq "存在しない明示パスは exit 2" "2" "$MISSING_EXIT"
assert_eq "stdout は空（SDD期 として返さない）" "" "$MISSING_OUT"

UNKNOWN_OPT_OUT="$(bash "$TARGET_SCRIPT" --bogus 2>/dev/null)"
UNKNOWN_OPT_EXIT=$?
assert_eq "未知オプションは exit 2" "2" "$UNKNOWN_OPT_EXIT"
assert_eq "未知オプション時の stdout は空" "" "$UNKNOWN_OPT_OUT"

TOO_MANY_OUT="$(bash "$TARGET_SCRIPT" "${GDD_DIR}/CLAUDE.md" extra 2>/dev/null)"
TOO_MANY_EXIT=$?
assert_eq "引数が多すぎる場合は exit 2" "2" "$TOO_MANY_EXIT"
assert_eq "引数過多時の stdout は空" "" "$TOO_MANY_OUT"

echo "=== test: CLI（サブディレクトリからの実行はリポジトリルートの CLAUDE.md を見る） ==="
GIT_DIR="${TMP_ROOT}/git-project"
mkdir -p "${GIT_DIR}/src/deep"
printf '# P\n\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n' > "${GIT_DIR}/CLAUDE.md"
(
  cd "$GIT_DIR" || exit 1
  git init -q
)
GIT_TOPLEVEL="$(cd "$GIT_DIR" && git rev-parse --show-toplevel)"
SUBDIR_OUT="$(cd "${GIT_DIR}/src/deep" && bash "$TARGET_SCRIPT" 2>/dev/null)"
SUBDIR_EXIT=$?
assert_eq "exit code が 0" "0" "$SUBDIR_EXIT"
assert_eq "phase が gdd（サブディレクトリでも宣言を見落とさない）" "gdd" "$(jq -r '.phase' <<<"$SUBDIR_OUT")"
assert_eq "source がリポジトリルートの CLAUDE.md" "${GIT_TOPLEVEL}/CLAUDE.md" "$(jq -r '.source' <<<"$SUBDIR_OUT")"

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
