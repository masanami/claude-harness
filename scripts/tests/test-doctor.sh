#!/bin/bash
# test-doctor.sh
# scripts/doctor.sh の純粋関数・CLI 挙動・**非破壊性**をテストする。
# 仕様の正本は scripts/specs/doctor.md。
#
# 本テストが固定するもの:
#   (A) severity 表の双方向一致（スクリプト内の表 ↔ 仕様の表）。片方だけ増減すると落ちる。
#       severity を実行時に判定させない設計は、この一致が守られて初めて意味を持つ
#   (B) blocking の唯一のリテラル `Bash(claude-harness-run:*)` が generate-settings.sh の
#       ベース allow に含まれ続けること（生成器側で改名されたら落ちる＝fail-closed）
#   (C)-(I) 純粋関数の単体テスト（空集合ケース・否定検査・真理値表を必ず含める）
#   (J)-(M) CLI の契約（checks の全称性・status・exit code・stdout の有無）
#   (N)(O) **非破壊性**: 実行前後でフィクスチャがバイト一致すること／その検査が
#       「書き込む doctor」を実際に落とすこと（変異注入）
#   (P)(Q) generate-settings.sh の冪等マージが**既存 allow を1件も減らさない**こと／
#       その検算が「既存を捨てるマージ」を実際に落とすこと（変異注入）
#
# 変異注入は**原本を書き換えない**。同じディレクトリにコピーを作って変異を注入し、
# コピーを実行する（原本の復元に失敗して人間の記述を失う経路を作らないため）。
# コピーは trap で必ず削除する。
#
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。文字列一致は grep -F / bash の文字列比較で行う。
#
# 実行方法: bash scripts/tests/test-doctor.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

TD_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TD_REPO_ROOT="$(cd "${TD_TEST_DIR}/../.." && pwd -P)"
TD_DOCTOR="${TD_REPO_ROOT}/scripts/doctor.sh"
TD_SPEC="${TD_REPO_ROOT}/scripts/specs/doctor.md"
TD_GENERATE_SETTINGS="${TD_REPO_ROOT}/skills/init-project/scripts/generate-settings.sh"
TD_TEMPLATE="${TD_REPO_ROOT}/skills/init-project/templates/CLAUDE.md.template"

# doctor.sh を source すると generate-settings.sh の gs_* も読み込まれる（doctor 側が source するため）
# shellcheck source=/dev/null
source "$TD_DOCTOR"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

if ! TD_TMP_DIR="$(mktemp -d)"; then
  echo "Failed to create test temporary directory" >&2
  exit 1
fi
TD_MUTANTS=()
td_cleanup() {
  local m
  for m in "${TD_MUTANTS[@]:-}"; do
    [ -n "$m" ] && rm -f "$m"
  done
  rm -rf "$TD_TMP_DIR"
}
trap td_cleanup EXIT

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

assert_true() {
  local description="$1" condition="$2"
  assert_eq "$description" "true" "$condition"
}

# ------------------------------------------------------------------
# (A) severity 表の双方向一致（スクリプト ↔ 仕様）
# ------------------------------------------------------------------
echo "== (A) severity 表の双方向一致 =="

# 仕様側の表から "id|severity" を取り出す。行の形は `| \`id\` | 説明 | severity |`。
td_spec_severity_table() {
  local line id sev
  while IFS= read -r line; do
    case "$line" in '| `'*) : ;; *) continue ;; esac
    id="$(printf '%s' "$line" | cut -d'|' -f2 | tr -d '` ')"
    sev="$(printf '%s' "$line" | cut -d'|' -f4 | tr -d ' ')"
    case "$sev" in blocking|advisory) : ;; *) continue ;; esac
    printf '%s|%s\n' "$id" "$sev"
  done < "$TD_SPEC"
}

TD_SCRIPT_TABLE="$(doctor_severity_table | LC_ALL=C sort)"
TD_SPEC_TABLE="$(td_spec_severity_table | LC_ALL=C sort)"

assert_true "仕様側の severity 表が空でない（切り出し失敗を pass にしない）" \
  "$([ -n "$TD_SPEC_TABLE" ] && echo true || echo false)"
assert_true "スクリプト側の severity 表が空でない" \
  "$([ -n "$TD_SCRIPT_TABLE" ] && echo true || echo false)"
assert_eq "severity 表がスクリプトと仕様で完全一致する" "$TD_SCRIPT_TABLE" "$TD_SPEC_TABLE"
assert_eq "検査項目は7件" "7" "$(doctor_check_ids | grep -c .)"

# ------------------------------------------------------------------
# (B) blocking リテラルの fail-closed 連結
# ------------------------------------------------------------------
echo "== (B) blocking リテラルが生成器のベース allow に在る =="

assert_eq "DOCTOR_LAUNCHER_ALLOW_RULE が gs_base_allow_json に含まれる" "true" \
  "$(gs_base_allow_json | jq -r --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" 'index($r) != null')"
assert_eq "DOCTOR_LAUNCHER_ALLOW_RULE が期待 allow（合成後）にも含まれる" "true" \
  "$(doctor_expected_allow_json "" "" "" | jq -r --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" 'index($r) != null')"

# ------------------------------------------------------------------
# (C) doctor_severity_of（否定検査を含む）
# ------------------------------------------------------------------
echo "== (C) doctor_severity_of =="

assert_eq "launcher_on_path は blocking" "blocking" "$(doctor_severity_of launcher_on_path)"
assert_eq "claude_md_doc_map は advisory" "advisory" "$(doctor_severity_of claude_md_doc_map)"
if doctor_severity_of no_such_check >/dev/null 2>&1; then
  assert_true "未知の検査 id は非0で返る（黙って advisory に丸めない）" "false"
else
  assert_true "未知の検査 id は非0で返る（黙って advisory に丸めない）" "true"
fi

# ------------------------------------------------------------------
# (D) doctor_missing_rules_json（空集合ケースを含む）
# ------------------------------------------------------------------
echo "== (D) doctor_missing_rules_json =="

assert_eq "期待が空なら不足も空" "[]" "$(doctor_missing_rules_json '[]' '["Bash(x:*)"]' | jq -c .)"
assert_eq "実際が空なら期待がそのまま不足" '["a","b"]' "$(doctor_missing_rules_json '["a","b"]' '[]' | jq -c .)"
assert_eq "完全に揃っていれば不足なし" "[]" "$(doctor_missing_rules_json '["a","b"]' '["b","a","c"]' | jq -c .)"
assert_eq "一部だけ不足する" '["b"]' "$(doctor_missing_rules_json '["a","b"]' '["a"]' | jq -c .)"

# ------------------------------------------------------------------
# (E) doctor_shadowed_by_json（真理値表＋否定検査）
# ------------------------------------------------------------------
echo "== (E) doctor_shadowed_by_json =="

TD_RULE="Bash(claude-harness-run:*)"
assert_eq "deny にも ask にも無ければ空" "[]" "$(doctor_shadowed_by_json "$TD_RULE" '[]' '[]' | jq -c .)"
assert_eq "deny に完全一致で在れば deny" '["deny"]' "$(doctor_shadowed_by_json "$TD_RULE" "[\"$TD_RULE\"]" '[]' | jq -c .)"
assert_eq "ask に完全一致で在れば ask" '["ask"]' "$(doctor_shadowed_by_json "$TD_RULE" '[]' "[\"$TD_RULE\"]" | jq -c .)"
assert_eq "両方に在れば両方" '["deny","ask"]' "$(doctor_shadowed_by_json "$TD_RULE" "[\"$TD_RULE\"]" "[\"$TD_RULE\"]" | jq -c .)"
# 明示的な仮定の固定（否定検査）: 前置き一致どうしの打ち消しは検出対象外。
# 意味論の実測記録が無いため推測で実装しない、という仕様上の決定をここで固定する。
assert_eq "前置きが同じだけの別ルールは shadowing として検出しない（仕様上の明示的な仮定）" "[]" \
  "$(doctor_shadowed_by_json "$TD_RULE" '["Bash(claude-harness-run doctor)"]' '[]' | jq -c .)"

# ------------------------------------------------------------------
# (F) CLAUDE.md の節・プレースホルダ（空集合ケースを含む）
# ------------------------------------------------------------------
echo "== (F) 節とプレースホルダの抽出 =="

assert_true "テンプレートから節を抽出できる（切り出し失敗を pass にしない）" \
  "$([ "$(doctor_template_sections "$TD_TEMPLATE" | grep -c .)" -gt 0 ] && echo true || echo false)"
assert_true "テンプレートからプレースホルダを抽出できる" \
  "$([ "$(doctor_template_placeholders "$TD_TEMPLATE" | grep -c .)" -gt 0 ] && echo true || echo false)"
assert_true "抽出した節にプレースホルダを含む見出しが混ざらない" \
  "$(doctor_template_sections "$TD_TEMPLATE" | grep -q '{' && echo false || echo true)"

TD_FULL_MD="${TD_TMP_DIR}/full.md"
{
  echo "# demo"
  doctor_template_sections "$TD_TEMPLATE"
} > "$TD_FULL_MD"
assert_eq "全ての節を持つ CLAUDE.md では欠落0件（空集合ケース）" "0" \
  "$(doctor_missing_sections "$TD_TEMPLATE" "$TD_FULL_MD" | grep -c . | tr -d ' ')"
assert_eq "プレースホルダを含まない CLAUDE.md では残存0件（空集合ケース）" "0" \
  "$(doctor_remaining_placeholders "$TD_TEMPLATE" "$TD_FULL_MD" | grep -c . | tr -d ' ')"

TD_PARTIAL_MD="${TD_TMP_DIR}/partial.md"
printf '# demo\n\n## プロジェクト概要\n\n{QUALITY_POLICY}\n' > "$TD_PARTIAL_MD"
assert_eq "欠けている節が検出される" "true" \
  "$(doctor_missing_sections "$TD_TEMPLATE" "$TD_PARTIAL_MD" | grep -Fxq '## 品質方針' && echo true || echo false)"
assert_eq "在る節は検出されない（否定検査）" "false" \
  "$(doctor_missing_sections "$TD_TEMPLATE" "$TD_PARTIAL_MD" | grep -Fxq '## プロジェクト概要' && echo true || echo false)"
assert_eq "未置換プレースホルダが検出される" "{QUALITY_POLICY}" \
  "$(doctor_remaining_placeholders "$TD_TEMPLATE" "$TD_PARTIAL_MD")"

TD_CUSTOM_MD="${TD_TMP_DIR}/custom.md"
printf '# demo\n\n利用者が書いた {自作の記法} は対象外である\n' > "$TD_CUSTOM_MD"
assert_eq "テンプレート由来でない {..} は誤検出しない（否定検査）" "0" \
  "$(doctor_remaining_placeholders "$TD_TEMPLATE" "$TD_CUSTOM_MD" | grep -c . | tr -d ' ')"

# ------------------------------------------------------------------
# (G)(H) ドキュメントマップ
# ------------------------------------------------------------------
echo "== (G)(H) ドキュメントマップ =="

TD_MAP_MD="${TD_TMP_DIR}/map.md"
cat > "$TD_MAP_MD" <<'MD'
# demo

## ドキュメントマップ

| カテゴリ | パス | 状態 |
|---------|------|------|
| 規約 | `docs/exists.md` | 整備済み |
| 設計 | `docs/gone.md` | 整備済み |
| ADR | `docs/adr/` | 作成予定 |
| API | `docs/later.md` | 作成予定 |
| 外部 | https://example.com/x | 整備済み |
| 未置換 | {DOCUMENT_MAP} | 整備済み |

## 品質方針
MD
mkdir -p "${TD_TMP_DIR}/proj/docs/adr"
printf 'x\n' > "${TD_TMP_DIR}/proj/docs/exists.md"

TD_ROWS="$(doctor_doc_map_rows "$TD_MAP_MD")"
assert_eq "表の見出し行を落とす（形の制約で落ちる・否定検査）" "false" \
  "$(printf '%s\n' "$TD_ROWS" | grep -q 'パス' && echo true || echo false)"
assert_eq "区切り行を落とす（否定検査）" "false" \
  "$(printf '%s\n' "$TD_ROWS" | grep -q -- '---' && echo true || echo false)"
assert_eq "外部 URL を落とす（否定検査）" "false" \
  "$(printf '%s\n' "$TD_ROWS" | grep -q 'example.com' && echo true || echo false)"
assert_eq "未置換プレースホルダ行を落とす（否定検査）" "false" \
  "$(printf '%s\n' "$TD_ROWS" | grep -q '{DOCUMENT_MAP}' && echo true || echo false)"
assert_eq "対象となる行は4件" "4" "$(printf '%s\n' "$TD_ROWS" | grep -c .)"
assert_eq "節が無ければ非0で返る" "false" \
  "$(doctor_doc_map_section "$TD_PARTIAL_MD" >/dev/null 2>&1 && echo true || echo false)"

TD_ITEMS="$(doctor_doc_map_items_json "${TD_TMP_DIR}/proj" "$TD_MAP_MD")"
assert_eq "整備済みかつ実在 → 指摘しない（否定検査）" "0" \
  "$(jq -r '[.[] | select(.path == "docs/exists.md")] | length' <<<"$TD_ITEMS")"
assert_eq "整備済みかつ不在 → missing" "missing" \
  "$(jq -r '.[] | select(.path == "docs/gone.md") | .kind' <<<"$TD_ITEMS")"
assert_eq "作成予定かつ実在 → stale_pending" "stale_pending" \
  "$(jq -r '.[] | select(.path == "docs/adr/") | .kind' <<<"$TD_ITEMS")"
assert_eq "作成予定かつ不在 → 指摘しない（宣言どおり・否定検査）" "0" \
  "$(jq -r '[.[] | select(.path == "docs/later.md")] | length' <<<"$TD_ITEMS")"
assert_eq "指摘は2件のみ" "2" "$(jq -r 'length' <<<"$TD_ITEMS")"

# ------------------------------------------------------------------
# (I) status と exit code の真理値表
# ------------------------------------------------------------------
echo "== (I) status / exit code =="

assert_eq "findings が空なら ok" "ok" "$(doctor_status_of_findings '[]')"
assert_eq "advisory のみなら warn" "warn" "$(doctor_status_of_findings '[{"severity":"advisory"}]')"
assert_eq "blocking が1件でもあれば fail" "fail" \
  "$(doctor_status_of_findings '[{"severity":"advisory"},{"severity":"blocking"}]')"
assert_eq "ok の exit code は0" "0" "$(doctor_exit_code_of_status ok)"
assert_eq "warn の exit code は0" "0" "$(doctor_exit_code_of_status warn)"
assert_eq "fail の exit code は1" "1" "$(doctor_exit_code_of_status fail)"

# ------------------------------------------------------------------
# CLI テストの下ごしらえ
# ------------------------------------------------------------------

# ランチャーの有無を環境に依存させないためのスタブ。--plugin-root は本チェックアウトを返す。
td_make_launcher_stub_dir() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "${dir}/claude-harness-run" <<STUB
#!/bin/bash
if [ "\${1:-}" = "--plugin-root" ]; then
  printf '%s\n' "${TD_REPO_ROOT}"
  exit 0
fi
exit 0
STUB
  chmod +x "${dir}/claude-harness-run"
}

# ランチャーが「PATH に無い」状態を決定的に作るための最小 PATH。
# 実在する PATH からランチャーだけを外す方法が無いため、必要なコマンドだけを集めたディレクトリを作る。
td_make_minimal_bin_dir() {
  local dir="$1" cmd src
  mkdir -p "$dir"
  # bash 自身も含める（PATH を差し替えた状態で `PATH=... bash` を起動するため）
  for cmd in bash jq sed grep cut tail head tr sort cat dirname mkdir rm; do
    src="$(command -v "$cmd" 2>/dev/null)" || continue
    ln -sf "$src" "${dir}/${cmd}"
  done
}

TD_STUB_BIN="${TD_TMP_DIR}/stubbin"
td_make_launcher_stub_dir "$TD_STUB_BIN"
TD_MIN_BIN="${TD_TMP_DIR}/minbin"
td_make_minimal_bin_dir "$TD_MIN_BIN"

# 健全なプロジェクトのフィクスチャを作る。settings.json は**実際の生成器の出力**（deny 専用）に、
# チームが tracked に置くことを選んだ運用 allow（生成器がスニペットとして提示するもの）と
# 人間の追記（プロジェクト固有の allow / deny / 独自トップレベルキー）を混ぜたもの。
td_make_project() {
  local dir="$1"
  mkdir -p "${dir}/.claude" "${dir}/docs"
  bash "$TD_GENERATE_SETTINGS" --pm npm --target "${dir}/.claude/settings.json" >/dev/null 2>&1
  local tmp="${dir}/.claude/settings.merged.json"
  jq --argjson op "$(gs_build_user_settings_snippet_json npm "" "" | jq -c '.permissions.allow')" \
     '.permissions.allow = ((.permissions.allow + $op) | unique)
      | .permissions.allow += ["Bash(terraform plan:*)"]
      | .permissions.deny += ["Bash(terraform destroy:*)"]
      | .hooks = {"PostToolUse": []}' \
    "${dir}/.claude/settings.json" > "$tmp" && mv "$tmp" "${dir}/.claude/settings.json"
  {
    echo "# demo - Claude Code プロジェクトコンテキスト"
    echo
    doctor_template_sections "$TD_TEMPLATE" | sed 's/$/\
/'
    echo
    echo "| カテゴリ | パス | 状態 |"
    echo "|---------|------|------|"
    echo "| 規約 | \`docs/guide.md\` | 整備済み |"
  } > "${dir}/CLAUDE.md"
  printf 'guide\n' > "${dir}/docs/guide.md"
}

TD_PROJ="${TD_TMP_DIR}/healthy"
td_make_project "$TD_PROJ"

# ------------------------------------------------------------------
# (J) CLI: 健全なプロジェクト
# ------------------------------------------------------------------
echo "== (J) CLI（健全なプロジェクト） =="

TD_OUT="${TD_TMP_DIR}/out.json"
PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR" --project "$TD_PROJ" --pm npm > "$TD_OUT" 2>/dev/null
TD_EXIT=$?
assert_eq "健全なプロジェクトは exit 0" "0" "$TD_EXIT"
assert_eq "status は ok" "ok" "$(jq -r '.status' "$TD_OUT")"
assert_eq "checks は7件すべて出る（全称条件）" "7" "$(jq -r '.checks | length' "$TD_OUT")"
assert_eq "checks の id は重複しない" "7" "$(jq -r '[.checks[].id] | unique | length' "$TD_OUT")"
assert_eq "checks の id が severity 表と一致する" \
  "$(doctor_check_ids | LC_ALL=C sort | tr '\n' ' ')" \
  "$(jq -r '.checks[].id' "$TD_OUT" | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "各 check の severity が表と一致する" "0" \
  "$(jq -r --argjson t "$(doctor_severity_table | jq -R -s 'split("\n") | map(select(length>0)) | map(split("|")) | map({id: .[0], severity: .[1]})')" \
     '[.checks[] as $c | $t[] | select(.id == $c.id and .severity != $c.severity)] | length' "$TD_OUT")"
assert_eq "findings は空" "0" "$(jq -r '.findings | length' "$TD_OUT")"
assert_eq "counts.checks は checks の件数と一致" "true" \
  "$(jq -r '.counts.checks == (.checks | length)' "$TD_OUT")"

# ------------------------------------------------------------------
# (K) CLI: blocking（ランチャー allow 欠落・ランチャー不在・shadowing）
# ------------------------------------------------------------------
echo "== (K) CLI（blocking） =="

TD_PROJ_NOALLOW="${TD_TMP_DIR}/noallow"
td_make_project "$TD_PROJ_NOALLOW"
TD_TMPJSON="${TD_TMP_DIR}/x.json"
jq --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" '.permissions.allow |= map(select(. != $r))' \
  "${TD_PROJ_NOALLOW}/.claude/settings.json" > "$TD_TMPJSON" && mv "$TD_TMPJSON" "${TD_PROJ_NOALLOW}/.claude/settings.json"

PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR" --project "$TD_PROJ_NOALLOW" --pm npm > "$TD_OUT" 2>/dev/null
TD_EXIT=$?
assert_eq "ランチャー allow 欠落は exit 1" "1" "$TD_EXIT"
assert_eq "status は fail" "fail" "$(jq -r '.status' "$TD_OUT")"
assert_eq "settings_launcher_allow が finding" "finding" \
  "$(jq -r '.checks[] | select(.id == "settings_launcher_allow") | .result' "$TD_OUT")"
assert_eq "remediation に generate-settings.sh の再実行が出る" "true" \
  "$(jq -r '[.findings[] | select(.check == "settings_launcher_allow") | .remediation | contains("generate-settings.sh")] | all' "$TD_OUT")"

TD_PROJ_SHADOW="${TD_TMP_DIR}/shadow"
td_make_project "$TD_PROJ_SHADOW"
jq --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" '.permissions.deny += [$r]' \
  "${TD_PROJ_SHADOW}/.claude/settings.json" > "$TD_TMPJSON" && mv "$TD_TMPJSON" "${TD_PROJ_SHADOW}/.claude/settings.json"
PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR" --project "$TD_PROJ_SHADOW" --pm npm > "$TD_OUT" 2>/dev/null
assert_eq "allow が deny で打ち消されていれば fail" "fail" "$(jq -r '.status' "$TD_OUT")"
assert_eq "shadowed_by に deny が出る" "deny" \
  "$(jq -r '.findings[] | select(.check == "settings_launcher_allow") | .items[0].shadowed_by[0]' "$TD_OUT")"

PATH="$TD_MIN_BIN" bash "$TD_DOCTOR" --project "$TD_PROJ" --pm npm > "$TD_OUT" 2>/dev/null
TD_EXIT=$?
assert_eq "ランチャー不在は exit 1" "1" "$TD_EXIT"
assert_eq "launcher_on_path が finding" "finding" \
  "$(jq -r '.checks[] | select(.id == "launcher_on_path") | .result' "$TD_OUT")"
assert_eq "launcher_plugin_root は skipped で reason が付く" "true" \
  "$(jq -r '.checks[] | select(.id == "launcher_plugin_root") | (.result == "skipped" and (.reason | length > 0))' "$TD_OUT")"
assert_eq "ランチャー導入コマンドが remediation に出る" "true" \
  "$(jq -r '[.findings[] | select(.check == "launcher_on_path") | .remediation | contains("install -m 0755")] | all' "$TD_OUT")"

# 是正コマンドは診断に使った条件をすべて載せる（載せないと、実行しても不足が埋まらない）
TD_PROJ_COND="${TD_TMP_DIR}/cond"
td_make_project "$TD_PROJ_COND"
PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR" --project "$TD_PROJ_COND" \
  --pm npm --test pytest --infra docker > "$TD_OUT" 2>/dev/null
assert_eq "pytest の allow 不足が検出される" "true" \
  "$(jq -r '[.findings[] | select(.check == "settings_base_allow") | .items[].rule] | index("Bash(pytest:*)") != null' "$TD_OUT")"
assert_eq "是正コマンドに --test が載る" "true" \
  "$(jq -r '[.findings[] | select(.check == "settings_base_allow") | .remediation | contains("--test \"pytest\"")] | all' "$TD_OUT")"
assert_eq "是正コマンドに --infra が載る" "true" \
  "$(jq -r '[.findings[] | select(.check == "settings_base_allow") | .remediation | contains("--infra \"docker\"")] | all' "$TD_OUT")"
assert_eq "是正コマンドに --pm が載る" "true" \
  "$(jq -r '[.findings[] | select(.check == "settings_base_allow") | .remediation | contains("--pm \"npm\"")] | all' "$TD_OUT")"

# found_elsewhere: 要件を満たさない置き場に在った事実を出す
TD_PROJ_LOCAL="${TD_TMP_DIR}/localonly"
td_make_project "$TD_PROJ_LOCAL"
jq --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" '.permissions.allow |= map(select(. != $r))' \
  "${TD_PROJ_LOCAL}/.claude/settings.json" > "$TD_TMPJSON" && mv "$TD_TMPJSON" "${TD_PROJ_LOCAL}/.claude/settings.json"
printf '{"permissions":{"allow":["%s"]}}\n' "$DOCTOR_LAUNCHER_ALLOW_RULE" > "${TD_PROJ_LOCAL}/.claude/settings.local.json"
PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR" --project "$TD_PROJ_LOCAL" --pm npm > "$TD_OUT" 2>/dev/null
assert_eq "settings.local.json に在った事実は found_elsewhere に出る" "true" \
  "$(jq -r '[.findings[] | select(.check == "settings_launcher_allow") | .items[0].found_elsewhere[] | contains("settings.local.json")] | any' "$TD_OUT")"
assert_eq "found_elsewhere に在っても要件は満たさない（status は fail のまま）" "fail" "$(jq -r '.status' "$TD_OUT")"

# ------------------------------------------------------------------
# (L)(M) CLI: skipped と実行前提の欠落
# ------------------------------------------------------------------
echo "== (L)(M) CLI（skipped / prereq） =="

TD_PROJ_NOMD="${TD_TMP_DIR}/nomd"
td_make_project "$TD_PROJ_NOMD"
rm -f "${TD_PROJ_NOMD}/CLAUDE.md"
PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR" --project "$TD_PROJ_NOMD" --pm npm > "$TD_OUT" 2>/dev/null
TD_EXIT=$?
assert_eq "CLAUDE.md 不在でも checks は7件出る（未検査を黙って落とさない）" "7" "$(jq -r '.checks | length' "$TD_OUT")"
assert_eq "claude_md_doc_map は reason 付きで skipped" "true" \
  "$(jq -r '.checks[] | select(.id == "claude_md_doc_map") | (.result == "skipped" and (.reason | length > 0))' "$TD_OUT")"
assert_eq "CLAUDE.md 不在は advisory なので exit 0" "0" "$TD_EXIT"
assert_eq "status は warn" "warn" "$(jq -r '.status' "$TD_OUT")"

TD_PROJ_BROKEN="${TD_TMP_DIR}/broken"
td_make_project "$TD_PROJ_BROKEN"
printf 'not json' > "${TD_PROJ_BROKEN}/.claude/settings.json"
TD_STDOUT="$(PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR" --project "$TD_PROJ_BROKEN" 2>/dev/null)"
TD_EXIT=$?
assert_eq "settings が不正 JSON なら exit 2" "2" "$TD_EXIT"
assert_eq "exit 2 のとき stdout は空" "0" "$(printf '%s' "$TD_STDOUT" | wc -c | tr -d ' ')"

TD_STDOUT="$(bash "$TD_DOCTOR" --unknown-flag 2>/dev/null)"
TD_EXIT=$?
assert_eq "未知の引数は exit 2" "2" "$TD_EXIT"
TD_STDOUT="$(bash "$TD_DOCTOR" --project 2>/dev/null)"
TD_EXIT=$?
assert_eq "値の無いフラグは exit 2（無限ループにしない）" "2" "$TD_EXIT"

# ------------------------------------------------------------------
# (N)(O) 非破壊性と、その検算の変異注入
# ------------------------------------------------------------------
echo "== (N)(O) 非破壊性 =="

# フィクスチャ全体（settings.json / CLAUDE.md / docs/）をコピーと突き合わせる。
# 削除範囲を比較対象から除外しない＝ディレクトリまるごとの再帰比較で検算する。
td_snapshot_diff() {
  local project="$1" snapshot="$2"
  diff -r "$snapshot" "$project" >/dev/null 2>&1 && echo "same" || echo "changed"
}

TD_PROJ_NB="${TD_TMP_DIR}/nondestructive"
td_make_project "$TD_PROJ_NB"
# 人間が書き足した記述（生成器が知らない行）を混ぜる
printf '\n<!-- 運用注意: この節は手で書いた。機械に消させない -->\n' >> "${TD_PROJ_NB}/CLAUDE.md"
TD_SNAPSHOT="${TD_TMP_DIR}/nondestructive.snapshot"
cp -R "$TD_PROJ_NB" "$TD_SNAPSHOT"

PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR" --project "$TD_PROJ_NB" --pm npm >/dev/null 2>&1
assert_eq "doctor 実行後もフィクスチャがバイト一致（何も書き換えない）" "same" \
  "$(td_snapshot_diff "$TD_PROJ_NB" "$TD_SNAPSHOT")"

# 変異注入: 「書き込む doctor」を作り、上の検算が実際に落ちることを確認する。
# 原本は書き換えない（同じディレクトリにコピーを作り、コピーへ注入する）。
TD_DOCTOR_MUTANT="$(mktemp "${TD_REPO_ROOT}/scripts/.doctor.mutant.XXXXXX")"
TD_MUTANTS+=("$TD_DOCTOR_MUTANT")
awk '{ print }
     /^  local checks=/ && !injected { print "  printf \"mutated\\n\" >> \"$target\""; injected = 1 }' \
  "$TD_DOCTOR" > "$TD_DOCTOR_MUTANT"
assert_eq "変異注入が実際に1行入っている（注入失敗を pass にしない）" "1" \
  "$(grep -c 'printf "mutated' "$TD_DOCTOR_MUTANT" | tr -d ' ')"

TD_PROJ_MUT="${TD_TMP_DIR}/mutated"
td_make_project "$TD_PROJ_MUT"
TD_SNAPSHOT_MUT="${TD_TMP_DIR}/mutated.snapshot"
cp -R "$TD_PROJ_MUT" "$TD_SNAPSHOT_MUT"
PATH="${TD_STUB_BIN}:${PATH}" bash "$TD_DOCTOR_MUTANT" --project "$TD_PROJ_MUT" --pm npm >/dev/null 2>&1
assert_eq "書き込む doctor は非破壊の検算に落とされる（検算が空虚に真でない）" "changed" \
  "$(td_snapshot_diff "$TD_PROJ_MUT" "$TD_SNAPSHOT_MUT")"

# ------------------------------------------------------------------
# (P)(Q) 是正コマンド（generate-settings.sh の冪等マージ）の非破壊性
# ------------------------------------------------------------------
echo "== (P)(Q) 是正コマンドの非破壊性 =="

# doctor が提示する是正コマンドの一つは generate-settings.sh の再実行である（deny の不足を
# マージし、運用 allow はユーザー設定向けスニペットとして提示する）。それが**人間の記述を
# 消さない**ことを、既存要素の多重集合の差で検算する（削除範囲を比較対象から除外しない）。
td_lost_entries_count() {
  local before="$1" after="$2" field="$3"
  jq -n --argjson b "$before" --argjson a "$after" '($b - $a) | length'
}

TD_PROJ_MERGE="${TD_TMP_DIR}/merge"
td_make_project "$TD_PROJ_MERGE"
TD_SETTINGS="${TD_PROJ_MERGE}/.claude/settings.json"
jq --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" '.permissions.allow |= map(select(. != $r))' \
  "$TD_SETTINGS" > "$TD_TMPJSON" && mv "$TD_TMPJSON" "$TD_SETTINGS"
TD_ALLOW_BEFORE="$(jq -c '.permissions.allow' "$TD_SETTINGS")"
TD_DENY_BEFORE="$(jq -c '.permissions.deny' "$TD_SETTINGS")"
TD_HOOKS_BEFORE="$(jq -c '.hooks' "$TD_SETTINGS")"

TD_GS_STDOUT="${TD_TMP_DIR}/gs-stdout.json"
bash "$TD_GENERATE_SETTINGS" --pm npm --target "$TD_SETTINGS" >"$TD_GS_STDOUT" 2>/dev/null
TD_ALLOW_AFTER="$(jq -c '.permissions.allow' "$TD_SETTINGS")"
TD_DENY_AFTER="$(jq -c '.permissions.deny' "$TD_SETTINGS")"

assert_eq "既存 allow が1件も減っていない（多重集合の差が0）" "0" \
  "$(td_lost_entries_count "$TD_ALLOW_BEFORE" "$TD_ALLOW_AFTER" allow)"
assert_eq "既存 deny が1件も減っていない" "0" \
  "$(td_lost_entries_count "$TD_DENY_BEFORE" "$TD_DENY_AFTER" deny)"
assert_eq "permissions 以外の既存キー（hooks）が保持される" "$TD_HOOKS_BEFORE" "$(jq -c '.hooks' "$TD_SETTINGS")"
assert_eq "人間が足した allow（terraform plan）が残る" "true" \
  "$(jq -r 'index("Bash(terraform plan:*)") != null' <<<"$TD_ALLOW_AFTER")"
# 生成器はプロジェクト settings（deny 専用）へランチャー allow を足さない。不足は
# ユーザー設定向けスニペットとして stdout に提示される（書き込みは人間）。
assert_eq "是正コマンドはプロジェクト settings にランチャー allow を足さない（deny 専用）" "false" \
  "$(jq -r --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" 'index($r) != null' <<<"$TD_ALLOW_AFTER")"
assert_eq "是正コマンドの stdout にユーザー設定向けスニペットが出て、ランチャー allow を含む" "true" \
  "$(jq -r --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" '.user_settings_snippet.permissions.allow | index($r) != null' "$TD_GS_STDOUT")"

TD_GS_MUTANT="$(mktemp "${TD_REPO_ROOT}/skills/init-project/scripts/.generate-settings.mutant.XXXXXX")"
TD_MUTANTS+=("$TD_GS_MUTANT")
awk '{ if ($0 ~ /^  merged_allow=/) print "  merged_allow=\"$gen_allow\""; else print }' \
  "$TD_GENERATE_SETTINGS" > "$TD_GS_MUTANT"
assert_eq "変異注入が実際に効いている（注入失敗を pass にしない）" "1" \
  "$(grep -c '^  merged_allow="\$gen_allow"' "$TD_GS_MUTANT" | tr -d ' ')"

TD_PROJ_MERGE_MUT="${TD_TMP_DIR}/mergemut"
td_make_project "$TD_PROJ_MERGE_MUT"
TD_SETTINGS_MUT="${TD_PROJ_MERGE_MUT}/.claude/settings.json"
TD_ALLOW_BEFORE_MUT="$(jq -c '.permissions.allow' "$TD_SETTINGS_MUT")"
bash "$TD_GS_MUTANT" --pm npm --target "$TD_SETTINGS_MUT" >/dev/null 2>&1
TD_ALLOW_AFTER_MUT="$(jq -c '.permissions.allow' "$TD_SETTINGS_MUT")"
assert_true "既存を捨てるマージは検算に落とされる（検算が空虚に真でない）" \
  "$([ "$(td_lost_entries_count "$TD_ALLOW_BEFORE_MUT" "$TD_ALLOW_AFTER_MUT" allow)" -gt 0 ] && echo true || echo false)"

# ------------------------------------------------------------------
# 要約
# ------------------------------------------------------------------
echo ""
echo "==================================="
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "  失敗したテスト:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "    - ${t}"
  done
  echo "==================================="
  exit 1
fi
echo "==================================="
exit 0
