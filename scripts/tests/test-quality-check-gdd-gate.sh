#!/bin/bash
# test-quality-check-gdd-gate.sh
# GDD P3・quality-check 系統（保証索引ゲートの統合。Issue #158）の回帰テスト。2部構成:
#
#  (A) 統合が依存するスクリプト契約の回帰テスト
#      /quality-check の SKILL.md は detect-dev-phase.sh / guarantee-index-check.sh の
#      exit code と JSON フィールドの語彙に依存して分岐する（GDD期のみ索引ゲートを発動・
#      invalid は fail-closed で中断・exit 2 や実行不能は fail 扱い）。この契約が変わると
#      SKILL.md 側の手順が黙って壊れるため、統合が前提にする最小契約を3面
#      （GDD期の検査実行 / SDD期の不変 / invalid の fail-closed）のフィクスチャで固定する。
#      各スクリプト単体の網羅は test-detect-dev-phase.sh / test-guarantee-index-check.sh の
#      担当であり、ここでは重複させない。
#
#  (B) SKILL.md の契約文（正準文）の存在検査
#      フェーズ分岐と出力契約は skills/quality-check/SKILL.md の手順として実装されている
#      （設計判断 D-15: quality-check-runner.sh 本体は変更しない）ため、正準文が逐語で
#      存在することを grep で検査し、手順のドリフト（更新漏れ・緩和）を機械検出する
#      （test-skeptic-discipline.sh と同じ方式）。あわせて runner がフェーズ非依存の
#      ままであること（D-15 の不変条件）も検査する。
#
# 実行方法: bash scripts/tests/test-quality-check-gdd-gate.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # 正準文・フィクスチャ内のバッククォートは Markdown のリテラル
# （SKILL.md の逐語検査対象）であり、シェル展開を意図していない
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DETECT_SCRIPT="${REPO_ROOT}/scripts/detect-dev-phase.sh"
GIC_SCRIPT="${REPO_ROOT}/scripts/guarantee-index-check.sh"
RUNNER_SCRIPT="${REPO_ROOT}/scripts/quality-check-runner.sh"
SKILL_FILE="${REPO_ROOT}/skills/quality-check/SKILL.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "NG - jq が見つからないためテストを実行できません（検査不能を pass にはしない）" >&2
  exit 1
fi

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

# SKILL.md に正準文（固定文字列）が逐語で存在することを検査する。
assert_skill_contains() {
  local description="$1" phrase="$2"
  if grep -qF -- "$phrase" "$SKILL_FILE"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${SKILL_FILE}"
    echo "       phrase: ${phrase}"
  fi
}

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

# ---------------------------------------------------------------------------
# フィクスチャ: 導入先プロジェクトを模したワークスペース
# ---------------------------------------------------------------------------

WS="${TMP_ROOT}/project"
mkdir -p "${WS}/docs" "${WS}/tests"

# 索引ゲートの参照先になる実在テストファイル
cat >"${WS}/tests/example.test.sh" <<'EOF'
test_contact_returns_400() {
  echo "sample test body"
}
EOF

# 健全な台帳（全参照が実在）
cat >"${WS}/docs/guarantees-ok.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

### G-158-1: サンプルの保証

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #158

## Gaps（テストのない公開面）
EOF

# 部分的に壊れた台帳（1件は健全・1件は参照先ファイルが無い）
cat >"${WS}/docs/guarantees-broken.md" <<'EOF'
# 保証台帳

## 保証（Guarantees）

### G-158-1: サンプルの保証

- 種別: API契約
- テスト: `tests/example.test.sh::test_contact_returns_400`
- 宣言元: #158

### G-158-2: 壊れた参照を持つ保証

- 種別: API契約
- テスト: `tests/missing.test.sh::test_never_exists`
- 宣言元: #158

## Gaps（テストのない公開面）
EOF

# 「保証」節を持たない壊れた台帳（検査不能ケース）
cat >"${WS}/docs/guarantees-no-section.md" <<'EOF'
# 保証台帳

## メモ

- 節名が規約と異なる
EOF

claude_md_gdd() {
  printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: GDD期\n- 駆動文書: docs/guarantees.md\n'
}

claude_md_sdd_declared() {
  printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: SDD期\n'
}

claude_md_no_declaration() {
  printf '# プロジェクト\n\n## 技術スタック\n\n- bash\n'
}

claude_md_invalid() {
  printf '# プロジェクト\n\n## 開発フェーズ\n\n- **フェーズ**: GDD\n'
}

# ---------------------------------------------------------------------------
# (A-1) SDD期の不変: 発動判定が sdd を返し、追加ゲートは発動しない
# ---------------------------------------------------------------------------
echo "=== (A-1) SDD期の不変: 発動判定が sdd を返す ==="

claude_md_no_declaration >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "宣言なし: exit 0（SDD期として確定）" "0" "$code"
assert_eq "宣言なし: phase は sdd（guarantee_index ゲートを発動しない入力）" \
  "sdd" "$(printf '%s' "$out" | jq -r '.phase')"

claude_md_sdd_declared >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "SDD期宣言: exit 0" "0" "$code"
assert_eq "SDD期宣言: phase は sdd" "sdd" "$(printf '%s' "$out" | jq -r '.phase')"

# SDD期の最終出力は runner の JSON そのもの（guarantee_index フィールドは存在しない）。
# runner の出力に guarantee_index が混入しないことは (B) の D-15 不変条件検査で固定し、
# ここでは runner の出力スキーマがトップレベル {result, auto_fix, gates} のままである
# ことを確認する（フィールドが増えると SDD期の「挙動完全不変」が破れる）。
out="$(cd "$WS" && bash "$RUNNER_SCRIPT" --test "true" 2>/dev/null)"
code=$?
assert_eq "runner 単体: exit 0（pass）" "0" "$code"
assert_eq "runner 単体: トップレベルのフィールドは result/auto_fix/gates のみ（SDD期の出力不変）" \
  "auto_fix,gates,result" "$(printf '%s' "$out" | jq -r 'keys | sort | join(",")')"

# ---------------------------------------------------------------------------
# (A-2) GDD期の検査実行: 発動判定が gdd を返し、索引ゲートが実行できる
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-2) GDD期の検査実行: gdd 判定と索引ゲートの実行 ==="

claude_md_gdd >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "GDD期宣言: exit 0" "0" "$code"
assert_eq "GDD期宣言: phase は gdd（guarantee_index ゲートを発動する入力）" \
  "gdd" "$(printf '%s' "$out" | jq -r '.phase')"

out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-ok.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "健全な台帳: exit 0" "0" "$code"
assert_eq "健全な台帳: status は pass" "pass" "$(printf '%s' "$out" | jq -r '.status')"
assert_eq "健全な台帳: broken は 0 件" "0" "$(printf '%s' "$out" | jq -r '.counts.broken')"

# 部分成功≠完全成功: 健全な参照が1件あっても、壊れた参照が1件でもあれば fail
out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-broken.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "部分的に壊れた台帳: exit 1（部分成功を成功にしない）" "1" "$code"
assert_eq "部分的に壊れた台帳: status は fail" "fail" "$(printf '%s' "$out" | jq -r '.status')"
assert_eq "部分的に壊れた台帳: broken に壊れた参照が列挙される" \
  "G-158-2" "$(printf '%s' "$out" | jq -r '.broken[0].guarantee_id')"
assert_eq "部分的に壊れた台帳: reason が特定されている" \
  "test_file_not_found" "$(printf '%s' "$out" | jq -r '.broken[0].reason')"

# ---------------------------------------------------------------------------
# (A-3) invalid の fail-closed: 不正宣言は sdd に化けず exit 1 / phase invalid
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-3) invalid の fail-closed: 不正宣言は sdd へフォールバックしない ==="

claude_md_invalid >"${WS}/CLAUDE.md"
out="$(bash "$DETECT_SCRIPT" "${WS}/CLAUDE.md" 2>/dev/null)"
code=$?
assert_eq "不正宣言: exit 1（quality-check は中断して要人間判定にする入力）" "1" "$code"
assert_eq "不正宣言: phase は invalid（sdd に読み替え不可）" \
  "invalid" "$(printf '%s' "$out" | jq -r '.phase')"

# ---------------------------------------------------------------------------
# (A-4) 検査不能≠0件: 索引ゲートが検査できないとき pass を出力しない
# ---------------------------------------------------------------------------
echo ""
echo "=== (A-4) 検査不能≠0件: 索引ゲートの実行前提欠落は pass にならない ==="

# stdout（空を含む）に status:pass が現れないことを判定するヘルパ。
# 「stdout が空」も「pass が出ていない」として no-pass 側に倒す（検査不能を pass にしない）。
stdout_pass_marker() {
  if printf '%s' "$1" | grep -qE '"status":[[:space:]]*"pass"'; then
    echo "pass"
  else
    echo "no-pass"
  fi
}

out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-missing.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "台帳ファイルが無い: exit 2（SKILL.md はこれを fail 扱いにする）" "2" "$code"
assert_eq "台帳ファイルが無い: stdout に status:pass の JSON を出力しない" \
  "no-pass" "$(stdout_pass_marker "$out")"

out="$(bash "$GIC_SCRIPT" "${WS}/docs/guarantees-no-section.md" --base "$WS" 2>/dev/null)"
code=$?
assert_eq "「保証」節が無い台帳: exit 2（全保証が黙って未検査になる素通りを防ぐ）" "2" "$code"
assert_eq "「保証」節が無い台帳: stdout に status:pass の JSON を出力しない" \
  "no-pass" "$(stdout_pass_marker "$out")"

# ---------------------------------------------------------------------------
# (B) SKILL.md の契約文（正準文）の存在検査
# ---------------------------------------------------------------------------
echo ""
echo "=== (B) SKILL.md の契約文の存在検査 ==="

# GDD期の検査実行（発動判定と索引ゲートがランチャー形式で記載されている）
assert_skill_contains "発動判定はランチャー経由の detect-dev-phase" \
  "claude-harness-run detect-dev-phase"
assert_skill_contains "索引ゲートはランチャー経由の guarantee-index-check" \
  "claude-harness-run guarantee-index-check"
assert_skill_contains "索引ゲートは gdd 判定のときだけ実行する" \
  '手順2の判定が `gdd` の場合のみ実行する'
assert_skill_contains "フェーズ判定はスクリプト出力のみ（CLAUDE.md を独自に grep しない）" \
  '`CLAUDE.md` を自分で grep しない'

# SDD期の不変（default-OFF）
assert_skill_contains "SDD期は guarantee_index フィールド自体を出力しない" \
  '`guarantee_index` フィールド自体を出力に含めない'
assert_skill_contains "SDD期の挙動・出力は従来と完全に同一" \
  "本スキルの挙動・最終出力は従来と完全に同一"

# invalid の fail-closed
assert_skill_contains "invalid を sdd に読み替えない" \
  '`sdd` に読み替えない'
assert_skill_contains "invalid は中断して要人間判定として報告する" \
  "要人間判定"

# 検査不能≠0件（スキップへの変換禁止）
assert_skill_contains "索引ゲートの実行不能は skip/pass に変換しない" \
  'スキップ（`skip`）や `pass` に変換しない'

# 部分成功≠完全成功（出力契約）
assert_skill_contains "索引ゲート失敗が result:pass に見える経路を作らない" \
  '索引ゲートの失敗が `result: "pass"` に見える出力経路は存在させない'
assert_skill_contains "総合 result は runner pass かつ guarantee_index pass のときのみ pass" \
  '「手順3の runner の `result` が `"pass"`」かつ「`guarantee_index.status` が `"pass"`」の場合のみ'

# D-15 の不変条件: runner 本体はフェーズ非依存のまま（quality-check-runner.sh に
# フェーズ判定・索引ゲートを組み込まない。組み込むと SDD期の出力不変が破れる）
runner_phase_hits="$(grep -nE "guarantee_index|guarantee-index-check|detect-dev-phase" "$RUNNER_SCRIPT")"
runner_phase_exit=$?
if [ "$runner_phase_exit" -ge 2 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("runner フェーズ非依存チェックの grep 実行に失敗")
  echo "  NG - grep 実行エラー（exit ${runner_phase_exit}）のため判定不能"
elif [ -n "$runner_phase_hits" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("quality-check-runner.sh にフェーズ依存の記述が混入（D-15 違反）")
  echo "  NG - quality-check-runner.sh にフェーズ依存の記述が混入（D-15 違反）"
  echo "       ${runner_phase_hits}"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - quality-check-runner.sh はフェーズ非依存のまま（D-15 の不変条件）"
fi

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
