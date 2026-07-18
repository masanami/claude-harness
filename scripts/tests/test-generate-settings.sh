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

# テスト全体で共有する一時ディレクトリ。固定の /tmp パスを使うと並列テスト間で
# 衝突したりシンボリックリンク経由で別ファイルを追跡する恐れがあるため、
# すべての一時ファイル・ディレクトリはこの配下に作成する。
# mktemp 失敗時にそのまま進むと TGS_TMP_DIR が空文字列のままになり、
# 後続の "${TGS_TMP_DIR}/xxx" が意図せずルート直下（/xxx）を指してしまうため、
# 失敗時は直ちに終了する。
if ! TGS_TMP_DIR="$(mktemp -d)"; then
  echo "Failed to create test temporary directory" >&2
  exit 1
fi
trap 'rm -rf "$TGS_TMP_DIR"' EXIT

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

# base-deny.json が破損/不正形式(スキーマ違反)の場合は、有効なJSONであっても
# フォールバックへ degrade することを確認する（CodeRabbit Major指摘: 有効なJSONでも
# 型が契約と異なると下流のjqが失敗し、既存設定の空ファイル化に繋がりうるため）。
TGS_BAD_DENY_DIR="${TGS_TMP_DIR}/bad-deny-object"
mkdir -p "$TGS_BAD_DENY_DIR"
echo '{"not":"an array"}' > "${TGS_BAD_DENY_DIR}/base-deny.json"
BAD_DENY_RESULT_OBJ="$(gs_load_base_deny_json "$TGS_BAD_DENY_DIR")"
assert_eq "gs_load_base_deny_json: オブジェクト形式のbase-deny.jsonはフォールバックにdegradeする" \
  "$(jq -cS '.' <<<"$(gs_fallback_base_deny_json)")" "$(jq -cS '.' <<<"$BAD_DENY_RESULT_OBJ")"

TGS_BAD_DENY_DIR2="${TGS_TMP_DIR}/bad-deny-nonstring"
mkdir -p "$TGS_BAD_DENY_DIR2"
echo '["ok", 1, 2]' > "${TGS_BAD_DENY_DIR2}/base-deny.json"
BAD_DENY_RESULT_NONSTR="$(gs_load_base_deny_json "$TGS_BAD_DENY_DIR2")"
assert_eq "gs_load_base_deny_json: 要素に非文字列を含む配列はフォールバックにdegradeする" \
  "$(jq -cS '.' <<<"$(gs_fallback_base_deny_json)")" "$(jq -cS '.' <<<"$BAD_DENY_RESULT_NONSTR")"

# ============================================================
# gs_validate_settings_schema: JSON境界のスキーマ検証(構文だけでなく型契約を検証)
# ============================================================
echo "=== test: gs_validate_settings_schema ==="
assert_true "正常なsettings jsonはvalid" \
  "$(gs_validate_settings_schema '{"permissions":{"allow":["Bash(a:*)"],"deny":[]}}' && echo true || echo false)"
assert_true "permissions省略でもvalid" "$(gs_validate_settings_schema '{}' && echo true || echo false)"
assert_true "allow/deny省略でもvalid" "$(gs_validate_settings_schema '{"permissions":{}}' && echo true || echo false)"
assert_eq "allowが文字列でなく配列でない場合はinvalid" "false" \
  "$(gs_validate_settings_schema '{"permissions":{"allow":"not-array"}}' && echo true || echo false)"
assert_eq "allow要素に非文字列が混じる場合はinvalid" "false" \
  "$(gs_validate_settings_schema '{"permissions":{"allow":[1,2]}}' && echo true || echo false)"
assert_eq "denyが配列でない場合はinvalid" "false" \
  "$(gs_validate_settings_schema '{"permissions":{"deny":{"a":1}}}' && echo true || echo false)"
assert_eq "ルートが配列の場合はinvalid" "false" \
  "$(gs_validate_settings_schema '[1,2,3]' && echo true || echo false)"
assert_eq "permissionsがオブジェクトでない場合はinvalid" "false" \
  "$(gs_validate_settings_schema '{"permissions":"nope"}' && echo true || echo false)"

# ============================================================
# gs_validate_analyze_input_schema: --input のスキーマ検証
# ============================================================
echo "=== test: gs_validate_analyze_input_schema ==="
assert_true "正常なanalyze-project.sh出力はvalid" \
  "$(gs_validate_analyze_input_schema '{"status":"ok","pm":"pnpm","stack":{"test":["playwright","vitest"],"infra":["Dockerfile"]}}' && echo true || echo false)"
assert_eq "pmが文字列でない場合はinvalid" "false" \
  "$(gs_validate_analyze_input_schema '{"pm":123}' && echo true || echo false)"
assert_eq "stack.testが配列でない場合はinvalid" "false" \
  "$(gs_validate_analyze_input_schema '{"pm":"npm","stack":{"test":"playwright"}}' && echo true || echo false)"
assert_eq "stack.infra要素に非文字列が混じる場合はinvalid" "false" \
  "$(gs_validate_analyze_input_schema '{"stack":{"infra":["docker",1]}}' && echo true || echo false)"
assert_true "pm/stack省略でもvalid" "$(gs_validate_analyze_input_schema '{}' && echo true || echo false)"

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

# --- (a) 既存settings.jsonの独自allowエントリが保持される ---
TGS_TARGET1="${TGS_TMP_DIR}/case-a/.claude/settings.json"
mkdir -p "$(dirname "$TGS_TARGET1")"
cat > "$TGS_TARGET1" <<'EOF'
{"permissions":{"allow":["Bash(custom-cmd:*)"],"deny":[]}}
EOF
"$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET1" >"${TGS_TMP_DIR}/case-a-stdout.json" 2>"${TGS_TMP_DIR}/case-a-stderr.log"
CASE_A_EXIT=$?
assert_eq "CLI: (a) exit code 0" "0" "$CASE_A_EXIT"
assert_true "CLI: (a) 既存の独自allowエントリが保持される" "$(json_contains "$(jq -c '.permissions.allow' "$TGS_TARGET1")" 'Bash(custom-cmd:*)')"
assert_true "CLI: (a) 生成されたpm権限も追加される" "$(json_contains "$(jq -c '.permissions.allow' "$TGS_TARGET1")" 'Bash(npm:*)')"

# --- (b) 同じ引数で2回連続実行しても差分が出ない(冪等) ---
TGS_TARGET2="${TGS_TMP_DIR}/case-b/.claude/settings.json"
"$TGS_TARGET_SCRIPT" --pm npm --test playwright --infra docker --target "$TGS_TARGET2" >/dev/null 2>"${TGS_TMP_DIR}/case-b-1-stderr.log"
FIRST_RUN="$(jq -cS '.' "$TGS_TARGET2")"
"$TGS_TARGET_SCRIPT" --pm npm --test playwright --infra docker --target "$TGS_TARGET2" >/dev/null 2>"${TGS_TMP_DIR}/case-b-2-stderr.log"
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
"$TGS_TARGET_SCRIPT" --input "$TGS_INPUT_FILE" --target "$TGS_TARGET3" >/dev/null 2>"${TGS_TMP_DIR}/case-c-stderr.log"
assert_eq "CLI: --input 経由でも --pm/--test/--infra 相当の結果になる(allow一致)" \
  "$(jq -cS '.permissions.allow' "$TGS_TARGET2")" "$(jq -cS '.permissions.allow' "$TGS_TARGET3")"

# --- .claude/ ディレクトリが無ければ作成される ---
assert_true "CLI: .claude/ ディレクトリが存在しなくても作成される" "$([ -d "$(dirname "$TGS_TARGET3")" ] && echo true || echo false)"

# ============================================================
# CLI: --input / 既存targetのスキーマ検証(型不一致でエラー終了・上書きしない)
# ============================================================
echo "=== test: --input のスキーマ検証(型不一致でエラー終了) ==="

TGS_BAD_INPUT_PM="${TGS_TMP_DIR}/bad-input-pm.json"
echo '{"pm":123}' > "$TGS_BAD_INPUT_PM"
TGS_TARGET_BAD_INPUT_PM="${TGS_TMP_DIR}/case-bad-input-pm/.claude/settings.json"
if "$TGS_TARGET_SCRIPT" --input "$TGS_BAD_INPUT_PM" --target "$TGS_TARGET_BAD_INPUT_PM" \
    >"${TGS_TMP_DIR}/bad-input-pm-stdout.json" 2>"${TGS_TMP_DIR}/bad-input-pm-stderr.log"; then
  FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TESTS+=("--input: .pmが文字列でない場合にexit非0")
  echo "  NG - --input: .pmが文字列でない場合にexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - --input: .pmが文字列でない場合にexit非0"
fi
assert_true "--input: .pmが文字列でない場合はtargetファイルが生成されない" \
  "$([ ! -f "$TGS_TARGET_BAD_INPUT_PM" ] && echo true || echo false)"
assert_true "--input: .pmが文字列でない場合はstdoutが空(status:okを返さない)" \
  "$([ ! -s "${TGS_TMP_DIR}/bad-input-pm-stdout.json" ] && echo true || echo false)"

TGS_BAD_INPUT_TEST="${TGS_TMP_DIR}/bad-input-stacktest.json"
echo '{"pm":"npm","stack":{"test":"playwright"}}' > "$TGS_BAD_INPUT_TEST"
TGS_TARGET_BAD_INPUT_TEST="${TGS_TMP_DIR}/case-bad-input-test/.claude/settings.json"
if "$TGS_TARGET_SCRIPT" --input "$TGS_BAD_INPUT_TEST" --target "$TGS_TARGET_BAD_INPUT_TEST" \
    >/dev/null 2>"${TGS_TMP_DIR}/bad-input-test-stderr.log"; then
  FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TESTS+=("--input: stack.testが配列でない場合にexit非0")
  echo "  NG - --input: stack.testが配列でない場合にexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - --input: stack.testが配列でない場合にexit非0"
fi

echo "=== test: 既存targetのスキーマ検証(型不一致でエラー終了・上書きしない) ==="
TGS_TARGET_BAD_EXISTING="${TGS_TMP_DIR}/case-bad-existing/.claude/settings.json"
mkdir -p "$(dirname "$TGS_TARGET_BAD_EXISTING")"
echo '{"permissions":{"allow":"not-an-array"}}' > "$TGS_TARGET_BAD_EXISTING"
TGS_ORIGINAL_BAD_CONTENT="$(cat "$TGS_TARGET_BAD_EXISTING")"
if "$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET_BAD_EXISTING" \
    >"${TGS_TMP_DIR}/bad-existing-stdout.json" 2>"${TGS_TMP_DIR}/bad-existing-stderr.log"; then
  FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TESTS+=("既存targetのスキーマ不正でexit非0")
  echo "  NG - 既存targetのスキーマ不正でexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 既存targetのスキーマ不正でexit非0"
fi
assert_eq "既存targetのスキーマ不正時は元のファイルを書き換えない" \
  "$TGS_ORIGINAL_BAD_CONTENT" "$(cat "$TGS_TARGET_BAD_EXISTING")"
assert_true "既存targetのスキーマ不正時はstdoutが空(status:okを返さない)" \
  "$([ ! -s "${TGS_TMP_DIR}/bad-existing-stdout.json" ] && echo true || echo false)"

# ============================================================
# CLI: 一時ファイル生成の安全性と書き込み失敗時の挙動
# ============================================================
echo "=== test: 一時ファイル生成の安全性と書き込み失敗時の挙動 ==="

# 成功時: ターゲットディレクトリ配下に一時ファイルが残留しない
# (予測可能な ${target}.tmp.$$ ではなく mktemp + trap によるクリーンアップの確認)
TGS_TARGET_CLEANUP="${TGS_TMP_DIR}/case-cleanup/.claude/settings.json"
"$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET_CLEANUP" >/dev/null 2>"${TGS_TMP_DIR}/cleanup-stderr.log"
TGS_LEFTOVER_COUNT="$(find "$(dirname "$TGS_TARGET_CLEANUP")" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "成功時に一時ファイルが残留しない" "0" "$TGS_LEFTOVER_COUNT"

# target 自体が symlink の場合、mv によるアトミック置換は symlink 先の元ファイルを
# 書き換えず、symlink を通常ファイルで置き換えることを確認する
# (symlink追跡を避けるというレビュー指摘の主眼を直接ロックするテスト)
TGS_SYMLINK_CASE_DIR="${TGS_TMP_DIR}/case-symlink"
mkdir -p "$TGS_SYMLINK_CASE_DIR"
TGS_SYMLINK_REAL_FILE="${TGS_SYMLINK_CASE_DIR}/real-outside-file.json"
echo '{"untouched":true}' > "$TGS_SYMLINK_REAL_FILE"
TGS_SYMLINK_TARGET="${TGS_SYMLINK_CASE_DIR}/settings.json"
ln -s "$TGS_SYMLINK_REAL_FILE" "$TGS_SYMLINK_TARGET"
"$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_SYMLINK_TARGET" >/dev/null 2>"${TGS_TMP_DIR}/symlink-stderr.log"
assert_true "symlink先の元ファイルは書き換えられない" \
  "$(jq -e '.untouched == true' "$TGS_SYMLINK_REAL_FILE" >/dev/null 2>&1 && echo true || echo false)"
assert_true "targetのsymlinkは通常ファイルに置き換わる" \
  "$([ ! -L "$TGS_SYMLINK_TARGET" ] && echo true || echo false)"
assert_true "置き換え後のtargetにpm権限が入る" \
  "$(json_contains "$(jq -c '.permissions.allow' "$TGS_SYMLINK_TARGET")" 'Bash(npm:*)')"

# 書き込み失敗時: status:okを返さずexit非0になることを確認する。
# chmod 555 によるパーミッション依存は root 実行(コンテナ等)では書き込みが
# ブロックされず偽 pass するため使わない。PATHの先頭に mv を必ず失敗させる
# スタブを差し込み、権限に関係なく決定的に書き込み失敗を再現する。
TGS_FAIL_MV_BIN="${TGS_TMP_DIR}/fail-mv-bin"
mkdir -p "$TGS_FAIL_MV_BIN"
cat > "${TGS_FAIL_MV_BIN}/mv" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${TGS_FAIL_MV_BIN}/mv"

TGS_TARGET_ROFAIL_DIR="${TGS_TMP_DIR}/case-rofail/.claude"
mkdir -p "$TGS_TARGET_ROFAIL_DIR"
TGS_TARGET_ROFAIL="${TGS_TARGET_ROFAIL_DIR}/settings.json"
if PATH="${TGS_FAIL_MV_BIN}:${PATH}" "$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET_ROFAIL" \
    >"${TGS_TMP_DIR}/rofail-stdout.json" 2>"${TGS_TMP_DIR}/rofail-stderr.log"; then
  FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TESTS+=("mv失敗時にexit非0")
  echo "  NG - mv失敗時にexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - mv失敗時にexit非0"
fi
assert_true "mv失敗時はstdoutが空(status:okを返さない)" \
  "$([ ! -s "${TGS_TMP_DIR}/rofail-stdout.json" ] && echo true || echo false)"
assert_true "mv失敗時はtargetファイルが生成されない" \
  "$([ ! -f "$TGS_TARGET_ROFAIL" ] && echo true || echo false)"

# --- targetがディレクトリの場合はエラー拒否する(mvがtmp_fileをディレクトリの
#     中へ移動して成功してしまい、意図したsettingsファイルを作らずstatus:okを
#     返す事故を防ぐ) ---
echo "=== test: --target にディレクトリを渡した場合はエラーで拒否する ==="
TGS_TARGET_IS_DIR="${TGS_TMP_DIR}/case-target-is-dir/.claude/settings.json"
mkdir -p "$TGS_TARGET_IS_DIR"
if "$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET_IS_DIR" \
    >"${TGS_TMP_DIR}/target-is-dir-stdout.json" 2>"${TGS_TMP_DIR}/target-is-dir-stderr.log"; then
  FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TESTS+=("targetがディレクトリの場合にexit非0")
  echo "  NG - targetがディレクトリの場合にexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - targetがディレクトリの場合にexit非0"
fi
assert_true "targetがディレクトリの場合はstdoutが空(status:okを返さない)" \
  "$([ ! -s "${TGS_TMP_DIR}/target-is-dir-stdout.json" ] && echo true || echo false)"
assert_true "targetがディレクトリの場合はディレクトリの中にファイルが作られない" \
  "$([ -z "$(ls -A "$TGS_TARGET_IS_DIR" 2>/dev/null)" ] && echo true || echo false)"

# --- targetがディレクトリを指すsymlinkの場合も同様に拒否する ---
TGS_TARGET_DIR_SYMLINK_REAL="${TGS_TMP_DIR}/case-target-dir-symlink-real"
mkdir -p "$TGS_TARGET_DIR_SYMLINK_REAL"
TGS_TARGET_DIR_SYMLINK="${TGS_TMP_DIR}/case-target-dir-symlink/.claude/settings.json"
mkdir -p "$(dirname "$TGS_TARGET_DIR_SYMLINK")"
ln -s "$TGS_TARGET_DIR_SYMLINK_REAL" "$TGS_TARGET_DIR_SYMLINK"
if "$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET_DIR_SYMLINK" \
    >"${TGS_TMP_DIR}/target-dir-symlink-stdout.json" 2>"${TGS_TMP_DIR}/target-dir-symlink-stderr.log"; then
  FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TESTS+=("targetがディレクトリsymlinkの場合にexit非0")
  echo "  NG - targetがディレクトリsymlinkの場合にexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - targetがディレクトリsymlinkの場合にexit非0"
fi
assert_true "targetがディレクトリsymlinkの場合はstdoutが空(status:okを返さない)" \
  "$([ ! -s "${TGS_TMP_DIR}/target-dir-symlink-stdout.json" ] && echo true || echo false)"
assert_true "targetがディレクトリsymlinkの場合は参照先ディレクトリの中にファイルが作られない" \
  "$([ -z "$(ls -A "$TGS_TARGET_DIR_SYMLINK_REAL" 2>/dev/null)" ] && echo true || echo false)"

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
if PATH="$TGS_NOJQ_BIN" "$TGS_TARGET_SCRIPT" --pm npm --target "$TGS_TARGET_NOJQ" >"${TGS_TMP_DIR}/nojq-stdout.json" 2>"${TGS_TMP_DIR}/nojq-stderr.log"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("jq不在時にexit非0")
  echo "  NG - jq不在時にexit非0"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - jq不在時にexit非0"
fi
assert_true "jq不在時にstdoutへJSONを出力しない(空)" "$([ ! -s "${TGS_TMP_DIR}/nojq-stdout.json" ] && echo true || echo false)"
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
"$TGS_TARGET_SCRIPT" --target "$TGS_TARGET_MISSING_VALUE" --pm >"${TGS_TMP_DIR}/missing-value-stdout.json" 2>"${TGS_TMP_DIR}/missing-value-stderr.log" &
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
