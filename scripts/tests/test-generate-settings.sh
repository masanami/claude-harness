#!/bin/bash
# test-generate-settings.sh
# skills/init-project/scripts/generate-settings.sh の合成関数（gs_*）とCLI挙動を
# テストする。純粋関数はスクリプトを source して直接呼び出し、
# ファイルI/O・冪等マージはCLI実行（一時ディレクトリ）で検証する。
#
# 実行方法: bash scripts/tests/test-generate-settings.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

TGS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TGS_TARGET_SCRIPT="${TGS_TEST_DIR}/../../skills/init-project/scripts/generate-settings.sh"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TGS_TARGET_SCRIPT"

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

assert_true() {
  local description="$1"
  local condition="$2" # "true" or "false"

  if [ "$condition" = "true" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
  fi
}

# json配列に要素が含まれるか
json_contains() {
  local json="$1" needle="$2"
  if jq -e --arg n "$needle" 'index($n) != null' >/dev/null 2>&1 <<<"$json"; then
    echo "true"
  else
    echo "false"
  fi
}

# ============================================================
# gs_pm_allow_json: pm別の追加権限
# ============================================================
echo "=== test: gs_pm_allow_json ==="
assert_true "npm で Bash(npm:*) が入る" "$(json_contains "$(gs_pm_allow_json npm)" 'Bash(npm:*)')"
assert_true "pnpm で Bash(pnpm:*) が入る" "$(json_contains "$(gs_pm_allow_json pnpm)" 'Bash(pnpm:*)')"
assert_true "cargo で Bash(cargo:*) が入る" "$(json_contains "$(gs_pm_allow_json cargo)" 'Bash(cargo:*)')"
assert_true "pip で Bash(python3:*) が入る" "$(json_contains "$(gs_pm_allow_json pip)" 'Bash(python3:*)')"
assert_true "pip で Bash(pip:*) が入る" "$(json_contains "$(gs_pm_allow_json pip)" 'Bash(pip:*)')"
assert_true "bundler で Bash(bundle:*) が入る" "$(json_contains "$(gs_pm_allow_json bundler)" 'Bash(bundle:*)')"
assert_eq "未知のpmでは空配列" "[]" "$(gs_pm_allow_json unknown-pm)"

# ============================================================
# gs_test_allow_json: テストFW別の追加権限（pm依存あり）
# ============================================================
echo "=== test: gs_test_allow_json ==="
assert_true "pytest で Bash(pytest:*) が入る" "$(json_contains "$(gs_test_allow_json pytest "")" 'Bash(pytest:*)')"
assert_true "playwright + npm で Bash(npx playwright:*) が入る" "$(json_contains "$(gs_test_allow_json playwright npm)" 'Bash(npx playwright:*)')"
assert_true "playwright + pnpm で Bash(pnpm exec playwright:*) が入る" "$(json_contains "$(gs_test_allow_json playwright pnpm)" 'Bash(pnpm exec playwright:*)')"
assert_true "playwright + yarn で Bash(yarn playwright:*) が入る" "$(json_contains "$(gs_test_allow_json playwright yarn)" 'Bash(yarn playwright:*)')"
assert_eq "jest単体では追加権限なし" "[]" "$(gs_test_allow_json jest npm)"
assert_eq "vitest単体では追加権限なし" "[]" "$(gs_test_allow_json vitest npm)"

# ============================================================
# gs_infra_allow_json: infra別の追加権限
# ============================================================
echo "=== test: gs_infra_allow_json ==="
assert_true "docker で Bash(docker:*) が入る" "$(json_contains "$(gs_infra_allow_json docker)" 'Bash(docker:*)')"
assert_true "docker で Bash(docker compose:*) が入る" "$(json_contains "$(gs_infra_allow_json docker)" 'Bash(docker compose:*)')"
assert_true "Dockerfile 検出値(analyze-project.sh形式)でもdocker権限が入る" "$(json_contains "$(gs_infra_allow_json Dockerfile)" 'Bash(docker:*)')"
assert_eq "infra指定なしでは空配列" "[]" "$(gs_infra_allow_json "")"

# ============================================================
# gs_load_base_deny_json: base-deny.json 正本の読み込みとフォールバックの整合
# ============================================================
echo "=== test: gs_load_base_deny_json ==="
TGS_BASE_DENY_FILE="${TGS_TEST_DIR}/../../skills/init-project/scripts/base-deny.json"
assert_true "base-deny.json が存在する" "$([ -f "$TGS_BASE_DENY_FILE" ] && echo true || echo false)"
FROM_FILE="$(gs_load_base_deny_json "$(dirname "$TGS_BASE_DENY_FILE")")"
assert_eq "gs_load_base_deny_json はbase-deny.jsonの内容をそのまま返す" \
  "$(jq -cS '.' "$TGS_BASE_DENY_FILE")" "$(jq -cS '.' <<<"$FROM_FILE")"
# フォールバック(gs_fallback_base_deny_json)がbase-deny.jsonと内容drift していないことを保証する。
# (base-deny.jsonが読めない場合に備えたスクリプト内蔵の第二の正本のため、
#  片方だけ更新されるドリフトをここで検知する)
assert_eq "フォールバックdenyはbase-deny.jsonと内容が一致する(drift防止)" \
  "$(jq -cS '.' "$TGS_BASE_DENY_FILE")" "$(jq -cS '.' <<<"$(gs_fallback_base_deny_json)")"

# ============================================================
# gs_build_generated_settings_json: 合成結果
# ============================================================
echo "=== test: gs_build_generated_settings_json ==="
BASE_DENY='["Bash(rm -rf:*)","Bash(rm -r:*)"]'
GENERATED="$(gs_build_generated_settings_json npm playwright docker "$BASE_DENY")"
assert_true "生成結果に共通権限 Bash(git commit:*) が入る" "$(json_contains "$(jq -c '.permissions.allow' <<<"$GENERATED")" 'Bash(git commit:*)')"
assert_true "生成結果に pm 権限 Bash(npm:*) が入る" "$(json_contains "$(jq -c '.permissions.allow' <<<"$GENERATED")" 'Bash(npm:*)')"
assert_true "生成結果に test 権限 Bash(npx playwright:*) が入る" "$(json_contains "$(jq -c '.permissions.allow' <<<"$GENERATED")" 'Bash(npx playwright:*)')"
assert_true "生成結果に infra 権限 Bash(docker:*) が入る" "$(json_contains "$(jq -c '.permissions.allow' <<<"$GENERATED")" 'Bash(docker:*)')"
assert_eq "deny はベースdenyがそのまま入る" "$(jq -c 'sort' <<<"$BASE_DENY")" "$(jq -c '.permissions.deny | sort' <<<"$GENERATED")"

# ============================================================
# gs_merge_settings_json: 既存ファイルとの冪等マージ
# ============================================================
echo "=== test: gs_merge_settings_json ==="
EXISTING='{"permissions":{"allow":["Bash(custom-cmd:*)","Bash(git commit:*)"],"deny":["Bash(custom-deny:*)"]}}'
MERGED="$(gs_merge_settings_json "$EXISTING" "$GENERATED")"
assert_true "マージ結果に既存の独自allowが保持される" "$(json_contains "$(jq -c '.permissions.allow' <<<"$MERGED")" 'Bash(custom-cmd:*)')"
assert_true "マージ結果に既存の独自denyが保持される" "$(json_contains "$(jq -c '.permissions.deny' <<<"$MERGED")" 'Bash(custom-deny:*)')"
assert_true "マージ結果に生成側のallowも入る" "$(json_contains "$(jq -c '.permissions.allow' <<<"$MERGED")" 'Bash(npm:*)')"
assert_true "マージ結果に生成側のdenyも入る" "$(json_contains "$(jq -c '.permissions.deny' <<<"$MERGED")" 'Bash(rm -rf:*)')"

MERGED_TWICE="$(gs_merge_settings_json "$MERGED" "$GENERATED")"
assert_eq "同じ入力で2回マージしても差分が出ない(冪等)" "$(jq -cS '.' <<<"$MERGED")" "$(jq -cS '.' <<<"$MERGED_TWICE")"

# 既存settings.jsonの permissions.allow/deny 以外のキー(トップレベルのenv、
# permissions配下のask等)がマージ後も保持されることを確認する。
EXISTING_WITH_OTHER_KEYS='{"env":{"FOO":"bar"},"permissions":{"allow":["Bash(custom-cmd:*)"],"deny":[],"ask":["Bash(risky:*)"]}}'
MERGED_WITH_OTHER_KEYS="$(gs_merge_settings_json "$EXISTING_WITH_OTHER_KEYS" "$GENERATED")"
assert_eq "マージ結果で既存のトップレベルキー(env)が保持される" "bar" "$(jq -r '.env.FOO' <<<"$MERGED_WITH_OTHER_KEYS")"
assert_true "マージ結果で既存のpermissions.ask配下が保持される" "$(json_contains "$(jq -c '.permissions.ask' <<<"$MERGED_WITH_OTHER_KEYS")" 'Bash(risky:*)')"

# ============================================================
# gs_extract_*_from_input: analyze-project.sh 出力形式からの抽出
# ============================================================
echo "=== test: gs_extract_*_from_input ==="
ANALYZE_OUTPUT='{"status":"ok","pm":"pnpm","stack":{"test":["playwright","vitest"],"infra":["Dockerfile","docker-compose"]}}'
assert_eq "pmが .pm から抽出される" "pnpm" "$(gs_extract_pm_from_input "$ANALYZE_OUTPUT")"
assert_eq "testがstack.testから抽出される" "playwright,vitest" "$(gs_extract_test_csv_from_input "$ANALYZE_OUTPUT")"
assert_eq "infraがstack.infraから抽出される" "Dockerfile,docker-compose" "$(gs_extract_infra_csv_from_input "$ANALYZE_OUTPUT")"

# ============================================================
# CLI: 冪等マージ・pm/test/infra合成・--input 経由・jq不在
# ============================================================
echo "=== test: CLI 実行 ==="

TGS_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TGS_TMP_DIR"' EXIT

# --- (a) 既存settings.jsonの独自allowエントリが保持される ---
TGS_TARGET1="${TGS_TMP_DIR}/case-a/.claude/settings.json"
mkdir -p "$(dirname "$TGS_TARGET1")"
cat > "$TGS_TARGET1" <<'EOF'
{"permissions":{"allow":["Bash(custom-cmd:*)"],"deny":[]}}
EOF
"$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET1" >/tmp/tgs-case-a-stdout.json 2>/tmp/tgs-case-a-stderr.log
CASE_A_EXIT=$?
assert_eq "CLI: (a) exit code 0" "0" "$CASE_A_EXIT"
assert_true "CLI: (a) 既存の独自allowエントリが保持される" "$(json_contains "$(jq -c '.permissions.allow' "$TGS_TARGET1")" 'Bash(custom-cmd:*)')"
assert_true "CLI: (a) 生成されたpm権限も追加される" "$(json_contains "$(jq -c '.permissions.allow' "$TGS_TARGET1")" 'Bash(npm:*)')"

# --- (b) 同じ引数で2回連続実行しても差分が出ない(冪等) ---
TGS_TARGET2="${TGS_TMP_DIR}/case-b/.claude/settings.json"
"$TGS_TARGET_SCRIPT" --pm npm --test playwright --infra docker --target "$TGS_TARGET2" >/dev/null 2>/tmp/tgs-case-b-1-stderr.log
FIRST_RUN="$(jq -cS '.' "$TGS_TARGET2")"
"$TGS_TARGET_SCRIPT" --pm npm --test playwright --infra docker --target "$TGS_TARGET2" >/dev/null 2>/tmp/tgs-case-b-2-stderr.log
SECOND_RUN="$(jq -cS '.' "$TGS_TARGET2")"
assert_eq "CLI: (b) 2回連続実行しても内容が完全に同じ(冪等)" "$FIRST_RUN" "$SECOND_RUN"

# --- pm/test/infra別の条件付き権限が正しく合成される ---
assert_true "CLI: --pm npm で Bash(npm:*) が入る" "$(json_contains "$(jq -c '.permissions.allow' "$TGS_TARGET2")" 'Bash(npm:*)')"
assert_true "CLI: --test playwright --pm npm で Bash(npx playwright:*) が入る" "$(json_contains "$(jq -c '.permissions.allow' "$TGS_TARGET2")" 'Bash(npx playwright:*)')"
assert_true "CLI: --infra docker で Bash(docker:*) が入る" "$(json_contains "$(jq -c '.permissions.allow' "$TGS_TARGET2")" 'Bash(docker:*)')"
assert_true "CLI: --infra docker で Bash(docker compose:*) が入る" "$(json_contains "$(jq -c '.permissions.allow' "$TGS_TARGET2")" 'Bash(docker compose:*)')"

# --- --input で analyze-project.sh 形式のJSONを渡した場合に同等の結果になる ---
TGS_TARGET3="${TGS_TMP_DIR}/case-c/.claude/settings.json"
TGS_INPUT_FILE="${TGS_TMP_DIR}/analyze-output.json"
cat > "$TGS_INPUT_FILE" <<'EOF'
{"status":"ok","pm":"npm","stack":{"test":["playwright"],"infra":["Dockerfile"]}}
EOF
"$TGS_TARGET_SCRIPT" --input "$TGS_INPUT_FILE" --target "$TGS_TARGET3" >/dev/null 2>/tmp/tgs-case-c-stderr.log
assert_eq "CLI: --input 経由でも --pm/--test/--infra 相当の結果になる(allow一致)" \
  "$(jq -cS '.permissions.allow' "$TGS_TARGET2")" "$(jq -cS '.permissions.allow' "$TGS_TARGET3")"

# --- .claude/ ディレクトリが無ければ作成される ---
assert_true "CLI: .claude/ ディレクトリが存在しなくても作成される" "$([ -d "$(dirname "$TGS_TARGET3")" ] && echo true || echo false)"

# --- jq不在時のエラーハンドリング ---
echo "=== test: jq不在時のエラーハンドリング ==="
TGS_TARGET_NOJQ="${TGS_TMP_DIR}/case-nojq/.claude/settings.json"
# jq を含まない最小PATHを用意する(jqだけを隠す。cat/mkdir/dirname/trはスクリプトが使用する外部コマンド)
TGS_NOJQ_BIN="${TGS_TMP_DIR}/nojq-bin"
mkdir -p "$TGS_NOJQ_BIN"
for tgs_cmd in cat mkdir dirname tr; do
  tgs_cmd_path="$(command -v "$tgs_cmd")"
  [ -n "$tgs_cmd_path" ] && ln -s "$tgs_cmd_path" "${TGS_NOJQ_BIN}/${tgs_cmd}"
done
if PATH="$TGS_NOJQ_BIN" "$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET_NOJQ" >/tmp/tgs-nojq-stdout.json 2>/tmp/tgs-nojq-stderr.log; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("jq不在時にexit非0")
  echo "  NG - jq不在時にexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - jq不在時にexit非0"
fi
assert_true "jq不在時にstdoutへJSONを出力しない(空)" "$([ ! -s /tmp/tgs-nojq-stdout.json ] && echo true || echo false)"
assert_true "jq不在時にファイルが生成されない" "$([ ! -f "$TGS_TARGET_NOJQ" ] && echo true || echo false)"

# --- 値なしフラグ末尾指定でハングしない(コードレビュー指摘の再現テスト) ---
# `--pm` を値なしで渡すと `shift 2` が失敗して無限ループしうるバグの再現。
# ウォッチドッグで5秒後に強制killする安全策を敷きつつ、実際には
# 数秒未満でエラー終了することを検証する(ハングした場合はウォッチドッグの
# kill時刻=5秒付近になり、しきい値3秒未満のアサーションで検知できる)。
echo "=== test: 値なしフラグでハングしない ==="
TGS_TARGET_MISSING_VALUE="${TGS_TMP_DIR}/case-missing-value/.claude/settings.json"
TGS_START="$(date +%s)"
# `--pm` を最後尾・値なしで置く(値を取るはずの$2が無く$#が1のまま張り付く再現条件)
"$TGS_TARGET_SCRIPT" --target "$TGS_TARGET_MISSING_VALUE" --pm >/tmp/tgs-missing-value-stdout.json 2>/tmp/tgs-missing-value-stderr.log &
TGS_BG_PID=$!
( sleep 5; kill -9 "$TGS_BG_PID" 2>/dev/null ) &
TGS_WATCHDOG_PID=$!
wait "$TGS_BG_PID" 2>/dev/null
TGS_MISSING_VALUE_EXIT=$?
kill "$TGS_WATCHDOG_PID" 2>/dev/null
wait "$TGS_WATCHDOG_PID" 2>/dev/null
TGS_END="$(date +%s)"
TGS_ELAPSED=$((TGS_END - TGS_START))
assert_true "値なし--pmでexit非0(usageエラー)" "$([ "$TGS_MISSING_VALUE_EXIT" -ne 0 ] && echo true || echo false)"
assert_true "値なし--pmで3秒未満に終了する(ハングしない)" "$([ "$TGS_ELAPSED" -lt 3 ] && echo true || echo false)"
assert_true "値なし--pmでファイルが生成されない" "$([ ! -f "$TGS_TARGET_MISSING_VALUE" ] && echo true || echo false)"

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
