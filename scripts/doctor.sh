#!/bin/bash
# doctor.sh
# 使い方: doctor.sh [--project <dir>] [--target <path>] [--claude-md <path>]
#                   [--pm <pm>] [--test <fw>]... [--infra <infra>]... [--input <file|->]
# 導入先プロジェクトが claude-harness の現行版を使うための前提を満たしているかを診断し、
# {status, project, settings, claudeMd, counts, checks, findings} の JSON を stdout に1個返す。
# 仕様の正本は scripts/specs/doctor.md を参照。
#
# なぜあるか（実装を読む人向けの注記）:
# - /init-project は生成物のテンプレート追従を持たないため、harness が要求する呼び出し形を
#   変えても既に scaffold されたプロジェクトは追従できない。allow 漏れで headless 委譲が
#   ブロックされる実害が4回再発している（Issue #154 / #178）。
# - 本スクリプトは**何も書き換えない**。エージェントは .claude/settings.json を原理的に
#   書けない（headless はパス保護・対話 auto mode は分類器がブロック）ため、価値は検出と
#   「人間がそのまま実行できるコマンド」の提示にある。読み取り専用であることは実行前後の
#   バイト一致で機械的に検算できる（書き込みを持つと非破壊の検算が空虚に真になりうる）。
# - 期待 allow は generate-settings.sh の合成関数を source して導出する。一覧をここへ
#   書き写すと2つのリストの同期が要り、ずれても誰も気付かない（生成器が allow を足しても
#   診断が要求しなくなり、追従漏れの検出という目的が静かに失われる）。
# - severity は下の表で固定し、実行時に判定しない。実行時に決める形にすると
#   「赤を避けたい」方向へ静かに漂う。表と仕様の双方向一致は test-doctor.sh が固定する。

set -u

DOCTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR_PLUGIN_ROOT="$(cd "${DOCTOR_DIR}/.." && pwd -P)"
DOCTOR_GENERATE_SETTINGS="${DOCTOR_PLUGIN_ROOT}/skills/init-project/scripts/generate-settings.sh"
DOCTOR_CLAUDE_MD_TEMPLATE="${DOCTOR_PLUGIN_ROOT}/skills/init-project/templates/CLAUDE.md.template"

# 終了コード（scripts/specs/doctor.md と一致させること）
DOCTOR_EX_OK=0     # status が ok または warn
DOCTOR_EX_FAIL=1   # blocking の finding が1件以上（status: fail）
DOCTOR_EX_PREREQ=2 # 実行前提の欠落（stdout には何も出さない）

DOCTOR_LAUNCHER_NAME="claude-harness-run"
# 唯一の blocking な allow ルール。この文字列が generate-settings.sh のベース allow に
# 含まれ続けることを test-doctor.sh が検査する（片方だけ変わると落ちる）。
DOCTOR_LAUNCHER_ALLOW_RULE="Bash(claude-harness-run:*)"
# 運用 allow の要件を満たす置き場。project（tracked の .claude/settings.json）に加え、
# オペレータ層（ユーザー設定 / settings.local.json）に在る allow も要件を満たすとみなす。
# 根拠は docs/settings-governance.md §2 の実測: ユーザー設定の allow は worktree 内の
# headless 起動でも効き、settings.local.json は main checkout ルートのファイルが worktree
# からも読まれる（Claude Code v2.1.211 以降）。ここから外した層に在っても blocking のまま。
DOCTOR_ALLOW_SCOPES="project user local"
DOCTOR_DOC_MAP_HEADING="## ドキュメントマップ"
# 「宣言どおりまだ無い」を表す状態語。skills/init-project/SKILL.md ステップ4 が書き込む語彙。
DOCTOR_DOC_MAP_PENDING_STATE="作成予定"

# generate-settings.sh の合成関数（gs_*）を読み込む。BASH_SOURCE ガードにより main は
# 走らない。欠損時はここで落とさず doctor_main の前提チェックで exit 2 にする
# （source されるテストを巻き添えにしないため）。
if [ -f "$DOCTOR_GENERATE_SETTINGS" ]; then
  # shellcheck source=/dev/null
  source "$DOCTOR_GENERATE_SETTINGS"
fi

# ------------------------------------------------------------------
# 検査項目表（severity の正本はここと scripts/specs/doctor.md の表）
# ------------------------------------------------------------------

doctor_severity_table() {
  cat <<'EOF'
launcher_on_path|blocking
launcher_plugin_root|blocking
settings_launcher_allow|blocking
settings_base_allow|advisory
claude_md_sections|advisory
claude_md_placeholders|advisory
claude_md_doc_map|advisory
EOF
}

doctor_check_ids() {
  doctor_severity_table | cut -d'|' -f1
}

# 引数: 検査 id。未知の id は非0で返す（黙って advisory に丸めない）。
doctor_severity_of() {
  local id="$1" key value
  while IFS='|' read -r key value; do
    [ -z "$key" ] && continue
    if [ "$key" = "$id" ]; then
      printf '%s' "$value"
      return 0
    fi
  done <<EOF
$(doctor_severity_table)
EOF
  return 1
}

# ------------------------------------------------------------------
# 小さなヘルパー（純粋関数）
# ------------------------------------------------------------------

doctor_trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# 改行区切りの標準入力を JSON 文字列配列にする（空行は落とす）。
doctor_lines_to_json_array() {
  jq -R -s 'split("\n") | map(select(length > 0))'
}

# ------------------------------------------------------------------
# 期待 allow（generate-settings.sh から導出。ここに一覧を持たない）
# ------------------------------------------------------------------

# 引数: pm, testFWカンマ区切り, infraカンマ区切り
# deny の正本（base-deny.json）は渡さない。診断は allow しか見ないため、
# base-deny.json の欠損で診断そのものが落ちて allow の検査まで巻き添えになるのを避ける。
doctor_expected_allow_json() {
  local pm="$1" test_csv="$2" infra_csv="$3"
  gs_build_generated_settings_json "$pm" "$test_csv" "$infra_csv" '[]' | jq -c '.permissions.allow'
}

# 引数: 期待 allow(JSON配列), 実際の allow(JSON配列) → 不足分(JSON配列)
doctor_missing_rules_json() {
  jq -n --argjson expected "$1" --argjson actual "$2" '$expected - $actual'
}

# 引数: settings ファイルパス, フィールド名(allow/deny/ask)
# ファイル不在・当該フィールド不在・型不一致はいずれも空配列（呼び出し側が
# ファイルの存在を別途 exists として報告するため、ここでは区別しない）。
doctor_settings_field_json() {
  local file="$1" field="$2" out
  if [ ! -f "$file" ]; then
    echo '[]'
    return 0
  fi
  out="$(jq -c --arg f "$field" \
    '(.permissions[$f] // []) | if type == "array" then map(select(type == "string")) else [] end' \
    "$file" 2>/dev/null)"
  if [ -z "$out" ]; then echo '[]'; else printf '%s\n' "$out"; fi
}

# 引数: ルール文字列, deny(JSON配列), ask(JSON配列)
# **完全一致の shadowing のみ**を検出する。前置き一致どうしの打ち消しの意味論は
# 本リポジトリに実測記録が無いため検出対象外（scripts/specs/doctor.md の明示的な仮定）。
doctor_shadowed_by_json() {
  local rule="$1" deny_json="$2" ask_json="$3"
  jq -n --arg rule "$rule" --argjson deny "$deny_json" --argjson ask "$ask_json" '
    [ (if ($deny | index($rule)) != null then "deny" else empty end),
      (if ($ask  | index($rule)) != null then "ask"  else empty end) ]'
}

# 引数: scope 名, プロジェクトルート → その scope の settings ファイルパス
doctor_scope_path() {
  local scope="$1" project="$2"
  case "$scope" in
    project) printf '%s' "${project}/.claude/settings.json" ;;
    user) printf '%s' "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json" ;;
    local) printf '%s' "${project}/.claude/settings.local.json" ;;
    *) return 1 ;;
  esac
}

# 引数: ルール文字列, プロジェクトルート, project の allow(JSON配列; --target で差し替え可能なため渡す)
# 戻り値: ルールが在る置き場の一覧 [{scope, path}]。DOCTOR_ALLOW_SCOPES の順。
# どの層で満たされたかを出力に残すのは、「対話セッションでは効いているのに missing と
# 言われた」と「チームに共有されていない」を、利用者が区別できるようにするため。
doctor_rule_locations_json() {
  local rule="$1" project="$2" project_allow="$3"
  local result='[]' scope path allow
  for scope in $DOCTOR_ALLOW_SCOPES; do
    path="$(doctor_scope_path "$scope" "$project")"
    if [ "$scope" = "project" ]; then
      allow="$project_allow"
    else
      allow="$(doctor_settings_field_json "$path" allow)"
    fi
    if [ "$(jq -r --arg r "$rule" 'index($r) != null' <<<"$allow")" = "true" ]; then
      result="$(jq -c --arg s "$scope" --arg p "$path" '. + [{scope: $s, path: $p}]' <<<"$result")"
    fi
  done
  printf '%s\n' "$result"
}

# ------------------------------------------------------------------
# CLAUDE.md（期待値はテンプレートから実行時に抽出する。一覧を持たない）
# ------------------------------------------------------------------

# テンプレートの H2 見出しのうち、プレースホルダを含まないもの。
doctor_template_sections() {
  grep '^## ' "$1" 2>/dev/null | grep -v '{' || true
}

# テンプレートに現れる {TOKEN} の一覧（重複除去）。
# テンプレート由来のトークンだけを対象にすることで、利用者が本文へ書いた {...} を誤検出しない。
doctor_template_placeholders() {
  grep -o '{[A-Za-z0-9_]*}' "$1" 2>/dev/null | LC_ALL=C sort -u || true
}

# 引数: テンプレート, 対象 CLAUDE.md → 欠けている見出し行
doctor_missing_sections() {
  local template="$1" target="$2" section
  while IFS= read -r section; do
    [ -z "$section" ] && continue
    if ! grep -Fxq "$section" "$target" 2>/dev/null; then
      printf '%s\n' "$section"
    fi
  done <<EOF
$(doctor_template_sections "$template")
EOF
}

# 引数: テンプレート, 対象 CLAUDE.md → 未置換で残っているプレースホルダ
doctor_remaining_placeholders() {
  local template="$1" target="$2" placeholder
  while IFS= read -r placeholder; do
    [ -z "$placeholder" ] && continue
    if grep -Fq "$placeholder" "$target" 2>/dev/null; then
      printf '%s\n' "$placeholder"
    fi
  done <<EOF
$(doctor_template_placeholders "$template")
EOF
}

# 引数: CLAUDE.md → ドキュメントマップ節の本文（見出しの次行から次の H2 の手前まで）。
# 節が無ければ非0。日本語の一致判定に awk を使わない（macOS 標準 awk は非ASCII の
# == を誤って真にする。scripts/README.md「テスト」節）ため grep -Fxn で行番号を採る。
doctor_doc_map_section() {
  local file="$1" start offset
  [ -f "$file" ] || return 1
  start="$(grep -Fxn "$DOCTOR_DOC_MAP_HEADING" "$file" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -z "$start" ] && return 1
  offset="$(tail -n +"$((start + 1))" "$file" | grep -n '^## ' | head -1 | cut -d: -f1)"
  if [ -n "$offset" ]; then
    sed -n "$((start + 1)),$((start + offset - 1))p" "$file"
  else
    tail -n +"$((start + 1))" "$file"
  fi
}

# 引数: CLAUDE.md → "パス|状態" の行。表の見出し行・区切り行・対象外の行は落とす。
# 見出し行を語彙（「パス」等）で落とすと第2の語彙リストになるため、**形の制約**で落とす:
# ドキュメントのパスは必ず "/" か "." を含む（docs/x.md・README.md・docs/adr/）。
doctor_doc_map_rows() {
  local file="$1" line path state
  doctor_doc_map_section "$file" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      '|'*) : ;;
      *) continue ;;
    esac
    path="$(doctor_trim "$(printf '%s' "$line" | cut -d'|' -f3 | tr -d '`')")"
    state="$(doctor_trim "$(printf '%s' "$line" | cut -d'|' -f4)")"
    [ -z "$path" ] && continue
    case "$path" in
      *'{'*) continue ;;      # 未置換プレースホルダ（claude_md_placeholders が扱う）
      http*) continue ;;      # 外部 URL
      *[!-:]*) : ;;           # 区切り行（- と : だけ）を落とす
      *) continue ;;
    esac
    case "$path" in
      */*|*.*) : ;;
      *) continue ;;          # パスの形をしていない（表の見出し行など）
    esac
    printf '%s|%s\n' "$path" "$state"
  done
}

# 引数: プロジェクトルート, CLAUDE.md → findings の items 相当の JSON 配列。
#   missing       : 状態が「作成予定」以外で実在しない（整備済みと書いてあるのに実体が無い）
#   stale_pending : 状態が「作成予定」なのに実在する（状態の更新漏れ）
# 「作成予定」かつ実在しないのは宣言どおりの正常であり指摘しない
# （未整備のドキュメントで恒久的に warn を出し続けないため）。
doctor_doc_map_items_json() {
  local project="$1" file="$2" row path state kind resolved result='[]'
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    path="${row%%|*}"
    state="${row#*|}"
    case "$path" in
      /*) resolved="$path" ;;
      *) resolved="${project}/${path}" ;;
    esac
    kind=""
    case "$state" in
      *"${DOCTOR_DOC_MAP_PENDING_STATE}"*)
        [ -e "$resolved" ] && kind="stale_pending"
        ;;
      *)
        [ -e "$resolved" ] || kind="missing"
        ;;
    esac
    [ -z "$kind" ] && continue
    result="$(jq -c --arg p "$path" --arg s "$state" --arg k "$kind" \
      '. + [{path: $p, state: $s, kind: $k}]' <<<"$result")"
  done <<EOF
$(doctor_doc_map_rows "$file")
EOF
  printf '%s\n' "$result"
}

# ------------------------------------------------------------------
# 判定（純粋関数）
# ------------------------------------------------------------------

# 引数: findings(JSON配列) → status 文字列
doctor_status_of_findings() {
  jq -r 'if length == 0 then "ok"
         elif any(.severity == "blocking") then "fail"
         else "warn" end' <<<"$1"
}

# 引数: status → 終了コード
doctor_exit_code_of_status() {
  case "$1" in
    fail) printf '%s' "$DOCTOR_EX_FAIL" ;;
    *) printf '%s' "$DOCTOR_EX_OK" ;;
  esac
}

# ------------------------------------------------------------------
# main（外部I/O）
# ------------------------------------------------------------------

doctor_print_usage() {
  cat >&2 <<'EOF'
使い方: doctor.sh [--project <dir>] [--target <path>] [--claude-md <path>]
                  [--pm <pm>] [--test <fw>]... [--infra <infra>]... [--input <file|->]
EOF
}

doctor_fail_prereq() {
  local message="$1"
  echo "Error: ${message}" >&2
  jq -nc --arg msg "$message" '{status:"error", error:$msg}' >&2 2>/dev/null \
    || printf '{"status":"error"}\n' >&2
  exit "$DOCTOR_EX_PREREQ"
}

doctor_main() {
  local project="" target="" claude_md=""
  local pm="" test_csv="" infra_csv="" input_arg=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project|--target|--claude-md|--pm|--test|--infra|--input)
        if [ "$#" -lt 2 ]; then
          echo "Error: $1 requires a value" >&2
          doctor_print_usage
          exit "$DOCTOR_EX_PREREQ"
        fi
        ;;
    esac
    case "$1" in
      --project) project="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --claude-md) claude_md="$2"; shift 2 ;;
      --pm) pm="$2"; shift 2 ;;
      --test)
        if [ -z "$test_csv" ]; then test_csv="$2"; else test_csv="${test_csv},$2"; fi
        shift 2 ;;
      --infra)
        if [ -z "$infra_csv" ]; then infra_csv="$2"; else infra_csv="${infra_csv},$2"; fi
        shift 2 ;;
      --input) input_arg="$2"; shift 2 ;;
      *)
        echo "Error: unknown argument: $1" >&2
        doctor_print_usage
        exit "$DOCTOR_EX_PREREQ"
        ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || doctor_fail_prereq "jq is required but was not found in PATH"
  command -v gs_build_generated_settings_json >/dev/null 2>&1 \
    || doctor_fail_prereq "generate-settings.sh not found or not loadable: ${DOCTOR_GENERATE_SETTINGS} (installation broken)"
  [ -f "$DOCTOR_CLAUDE_MD_TEMPLATE" ] \
    || doctor_fail_prereq "CLAUDE.md.template not found: ${DOCTOR_CLAUDE_MD_TEMPLATE} (installation broken)"

  [ -z "$project" ] && project="."
  [ -d "$project" ] || doctor_fail_prereq "--project is not a directory: ${project}"
  project="$(cd "$project" && pwd -P)"
  [ -z "$target" ] && target="${project}/.claude/settings.json"
  [ -z "$claude_md" ] && claude_md="${project}/CLAUDE.md"

  if [ -n "$input_arg" ]; then
    local input_str
    if [ "$input_arg" = "-" ]; then
      input_str="$(cat)"
    else
      [ -f "$input_arg" ] || doctor_fail_prereq "--input file not found: ${input_arg}"
      input_str="$(cat "$input_arg")"
    fi
    jq -e . >/dev/null 2>&1 <<<"$input_str" || doctor_fail_prereq "--input is not valid JSON"
    gs_validate_analyze_input_schema "$input_str" \
      || doctor_fail_prereq "--input does not match expected schema (.pm must be a string, .stack.test/.stack.infra must be string arrays)"
    local input_pm input_test_csv input_infra_csv
    input_pm="$(gs_extract_pm_from_input "$input_str")"
    input_test_csv="$(gs_extract_test_csv_from_input "$input_str")"
    input_infra_csv="$(gs_extract_infra_csv_from_input "$input_str")"
    [ -z "$pm" ] && pm="$input_pm"
    if [ -n "$input_test_csv" ]; then
      if [ -z "$test_csv" ]; then test_csv="$input_test_csv"; else test_csv="${test_csv},${input_test_csv}"; fi
    fi
    if [ -n "$input_infra_csv" ]; then
      if [ -z "$infra_csv" ]; then infra_csv="$input_infra_csv"; else infra_csv="${infra_csv},${input_infra_csv}"; fi
    fi
  fi

  local settings_exists="false" claude_md_exists="false"
  [ -f "$target" ] && settings_exists="true"
  [ -f "$claude_md" ] && claude_md_exists="true"

  # 既存 settings が JSON として読めない場合は診断そのものが成立しない
  # （allow が「無い」のかファイルが壊れているのか区別できず、誤った是正へ誘導する）。
  if [ "$settings_exists" = "true" ] && ! jq -e . >/dev/null 2>&1 <"$target"; then
    doctor_fail_prereq "existing target is not valid JSON: ${target}"
  fi

  local checks='[]' findings='[]'

  # --- launcher_on_path / launcher_plugin_root ---
  local launcher_path="" launcher_ok="false"
  launcher_path="$(command -v "$DOCTOR_LAUNCHER_NAME" 2>/dev/null || true)"
  local install_cmd="mkdir -p ~/.local/bin && install -m 0755 \"${DOCTOR_PLUGIN_ROOT}/bin/${DOCTOR_LAUNCHER_NAME}\" ~/.local/bin/${DOCTOR_LAUNCHER_NAME}"
  if [ -n "$launcher_path" ]; then
    launcher_ok="true"
    checks="$(jq -c --arg id launcher_on_path --arg sev "$(doctor_severity_of launcher_on_path)" \
      '. + [{id: $id, severity: $sev, result: "ok"}]' <<<"$checks")"
  else
    checks="$(jq -c --arg id launcher_on_path --arg sev "$(doctor_severity_of launcher_on_path)" \
      '. + [{id: $id, severity: $sev, result: "finding"}]' <<<"$checks")"
    findings="$(jq -c --arg sev "$(doctor_severity_of launcher_on_path)" --arg cmd "$install_cmd" \
      --arg name "$DOCTOR_LAUNCHER_NAME" \
      '. + [{check: "launcher_on_path", severity: $sev,
             summary: ($name + " が PATH 上に見つからない。スキルからのスクリプト実行と参照ファイルの配送が届かなくなる"),
             items: [], remediation: $cmd}]' <<<"$findings")"
  fi

  if [ "$launcher_ok" != "true" ]; then
    checks="$(jq -c --arg id launcher_plugin_root --arg sev "$(doctor_severity_of launcher_plugin_root)" \
      --arg reason "ランチャーが PATH 上に無いため解決先を比較できない" \
      '. + [{id: $id, severity: $sev, result: "skipped", reason: $reason}]' <<<"$checks")"
  else
    local resolved_root="" resolve_failed="false"
    resolved_root="$("$DOCTOR_LAUNCHER_NAME" --plugin-root 2>/dev/null)" || resolve_failed="true"
    if [ "$resolve_failed" != "true" ] && [ -n "$resolved_root" ] && [ -d "$resolved_root" ]; then
      resolved_root="$(cd "$resolved_root" && pwd -P)"
    fi
    if [ "$resolve_failed" != "true" ] && [ "$resolved_root" = "$DOCTOR_PLUGIN_ROOT" ]; then
      checks="$(jq -c --arg id launcher_plugin_root --arg sev "$(doctor_severity_of launcher_plugin_root)" \
        '. + [{id: $id, severity: $sev, result: "ok"}]' <<<"$checks")"
    else
      checks="$(jq -c --arg id launcher_plugin_root --arg sev "$(doctor_severity_of launcher_plugin_root)" \
        '. + [{id: $id, severity: $sev, result: "finding"}]' <<<"$checks")"
      findings="$(jq -c --arg sev "$(doctor_severity_of launcher_plugin_root)" \
        --arg resolved "$resolved_root" --arg own "$DOCTOR_PLUGIN_ROOT" --arg cmd "$install_cmd" \
        '. + [{check: "launcher_plugin_root", severity: $sev,
               summary: "PATH 上のランチャーが別のプラグインルートを解決している（旧版と新版の混成が起きる）",
               items: [{resolved: $resolved, expected: $own}], remediation: $cmd}]' <<<"$findings")"
    fi
  fi

  # --- settings_launcher_allow / settings_base_allow ---
  local actual_allow actual_deny actual_ask expected_allow
  actual_allow="$(doctor_settings_field_json "$target" allow)"
  actual_deny="$(doctor_settings_field_json "$target" deny)"
  actual_ask="$(doctor_settings_field_json "$target" ask)"
  expected_allow="$(doctor_expected_allow_json "$pm" "$test_csv" "$infra_csv")"

  # 是正コマンドには診断に使った条件をすべて載せる。--test / --infra を落とすと、
  # 提示したコマンドを実行しても不足として報告した allow が入らない。
  local regenerate_cmd item
  regenerate_cmd="claude-harness-run skills/init-project/scripts/generate-settings.sh --target \"${target}\""
  [ -n "$pm" ] && regenerate_cmd="${regenerate_cmd} --pm \"${pm}\""
  if [ -n "$test_csv" ]; then
    while IFS= read -r item; do
      [ -z "$item" ] && continue
      regenerate_cmd="${regenerate_cmd} --test \"${item}\""
    done <<EOF
$(printf '%s' "$test_csv" | tr ',' '\n')
EOF
  fi
  if [ -n "$infra_csv" ]; then
    while IFS= read -r item; do
      [ -z "$item" ] && continue
      regenerate_cmd="${regenerate_cmd} --infra \"${item}\""
    done <<EOF
$(printf '%s' "$infra_csv" | tr ',' '\n')
EOF
  fi

  # 是正の第一候補はユーザー設定への追記（チーム共有が不要ならそれで足りる。
  # docs/settings-governance.md §4）。tracked に揃えたい場合の再生成コマンドを併記する。
  local user_settings_path allow_remediation
  user_settings_path="$(doctor_scope_path user "$project")"
  allow_remediation="ユーザー設定 ${user_settings_path} の permissions.allow に不足しているルールを追記する（チーム共有が不要ならユーザー設定でよい）。tracked の settings に揃える場合: ${regenerate_cmd}"

  local launcher_found_in shadowed_by
  launcher_found_in="$(doctor_rule_locations_json "$DOCTOR_LAUNCHER_ALLOW_RULE" "$project" "$actual_allow")"
  shadowed_by="$(doctor_shadowed_by_json "$DOCTOR_LAUNCHER_ALLOW_RULE" "$actual_deny" "$actual_ask")"
  if [ "$(jq -r 'length' <<<"$launcher_found_in")" != "0" ] && [ "$(jq -r 'length' <<<"$shadowed_by")" = "0" ]; then
    checks="$(jq -c --arg id settings_launcher_allow --arg sev "$(doctor_severity_of settings_launcher_allow)" \
      --argjson found "$launcher_found_in" \
      '. + [{id: $id, severity: $sev, result: "ok", satisfied_by: [$found[].scope]}]' <<<"$checks")"
  else
    local summary
    if [ "$(jq -r 'length' <<<"$launcher_found_in")" != "0" ]; then
      summary="ランチャーの allow が deny / ask の同一ルールで打ち消されている"
    elif [ "$settings_exists" = "true" ]; then
      summary="ランチャーの allow がプロジェクト settings・ユーザー設定・settings.local.json のいずれにも無い。headless 委譲でスクリプト実行が拒否される"
    else
      summary="プロジェクト settings が存在せず、ランチャーの allow がユーザー設定・settings.local.json にも無い。headless 委譲でスクリプト実行が拒否される"
    fi
    checks="$(jq -c --arg id settings_launcher_allow --arg sev "$(doctor_severity_of settings_launcher_allow)" \
      '. + [{id: $id, severity: $sev, result: "finding"}]' <<<"$checks")"
    findings="$(jq -c --arg sev "$(doctor_severity_of settings_launcher_allow)" --arg sum "$summary" \
      --arg rule "$DOCTOR_LAUNCHER_ALLOW_RULE" --argjson found "$launcher_found_in" \
      --argjson shadowed "$shadowed_by" --arg cmd "$allow_remediation" \
      '. + [{check: "settings_launcher_allow", severity: $sev, summary: $sum,
             items: [{rule: $rule, found_in: $found, shadowed_by: $shadowed}],
             remediation: $cmd}]' <<<"$findings")"
  fi

  # project に無いルールでも、オペレータ層に在れば不足としない（satisfied_by に層を残す）。
  local expected_base project_missing base_missing='[]' base_satisfied_by='[]' rule found_in
  expected_base="$(jq -c --arg r "$DOCTOR_LAUNCHER_ALLOW_RULE" 'map(select(. != $r))' <<<"$expected_allow")"
  project_missing="$(doctor_missing_rules_json "$expected_base" "$actual_allow" | jq -c .)"
  if [ "$(jq -r 'length' <<<"$expected_base")" -gt "$(jq -r 'length' <<<"$project_missing")" ]; then
    base_satisfied_by='["project"]'
  fi
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    found_in="$(doctor_rule_locations_json "$rule" "$project" '[]')"
    if [ "$(jq -r 'length' <<<"$found_in")" = "0" ]; then
      base_missing="$(jq -c --arg r "$rule" '. + [{rule: $r, found_in: []}]' <<<"$base_missing")"
    else
      base_satisfied_by="$(jq -c --argjson f "$found_in" '. + [$f[].scope]' <<<"$base_satisfied_by")"
    fi
  done <<EOF
$(jq -r '.[]' <<<"$project_missing")
EOF
  base_satisfied_by="$(jq -c 'unique' <<<"$base_satisfied_by")"
  if [ "$(jq -r 'length' <<<"$base_missing")" = "0" ]; then
    checks="$(jq -c --arg id settings_base_allow --arg sev "$(doctor_severity_of settings_base_allow)" \
      --argjson sat "$base_satisfied_by" \
      '. + [{id: $id, severity: $sev, result: "ok", satisfied_by: $sat}]' <<<"$checks")"
  else
    checks="$(jq -c --arg id settings_base_allow --arg sev "$(doctor_severity_of settings_base_allow)" \
      '. + [{id: $id, severity: $sev, result: "finding"}]' <<<"$checks")"
    findings="$(jq -c --arg sev "$(doctor_severity_of settings_base_allow)" --argjson items "$base_missing" \
      --arg cmd "$allow_remediation" \
      '. + [{check: "settings_base_allow", severity: $sev,
             summary: ("期待される allow のうち " + ($items | length | tostring) + " 件がプロジェクト settings・ユーザー設定・settings.local.json のいずれにも無い"),
             items: $items, remediation: $cmd}]' <<<"$findings")"
  fi

  # --- claude_md_sections / claude_md_placeholders / claude_md_doc_map ---
  local doc_hint="CLAUDE.md を /init-project で生成するか、不足している節を手で追記する"
  if [ "$claude_md_exists" != "true" ]; then
    checks="$(jq -c --arg id claude_md_sections --arg sev "$(doctor_severity_of claude_md_sections)" \
      '. + [{id: $id, severity: $sev, result: "finding"}]' <<<"$checks")"
    findings="$(jq -c --arg sev "$(doctor_severity_of claude_md_sections)" --arg path "$claude_md" \
      '. + [{check: "claude_md_sections", severity: $sev,
             summary: "CLAUDE.md が存在しない", items: [{path: $path}],
             remediation: "/init-project を実行する"}]' <<<"$findings")"
    local reason="CLAUDE.md が存在しない"
    checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_placeholders)" --arg reason "$reason" \
      '. + [{id: "claude_md_placeholders", severity: $sev, result: "skipped", reason: $reason}]' <<<"$checks")"
    checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_doc_map)" --arg reason "$reason" \
      '. + [{id: "claude_md_doc_map", severity: $sev, result: "skipped", reason: $reason}]' <<<"$checks")"
  else
    local missing_sections_json
    missing_sections_json="$(doctor_missing_sections "$DOCTOR_CLAUDE_MD_TEMPLATE" "$claude_md" | doctor_lines_to_json_array)"
    if [ "$(jq -r 'length' <<<"$missing_sections_json")" = "0" ]; then
      checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_sections)" \
        '. + [{id: "claude_md_sections", severity: $sev, result: "ok"}]' <<<"$checks")"
    else
      checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_sections)" \
        '. + [{id: "claude_md_sections", severity: $sev, result: "finding"}]' <<<"$checks")"
      findings="$(jq -c --arg sev "$(doctor_severity_of claude_md_sections)" \
        --argjson sections "$missing_sections_json" --arg hint "$doc_hint" \
        '. + [{check: "claude_md_sections", severity: $sev,
               summary: ("テンプレートの節のうち " + ($sections | length | tostring) + " 件が CLAUDE.md に無い"),
               items: [$sections[] | {section: .}], remediation: $hint}]' <<<"$findings")"
    fi

    local remaining_json
    remaining_json="$(doctor_remaining_placeholders "$DOCTOR_CLAUDE_MD_TEMPLATE" "$claude_md" | doctor_lines_to_json_array)"
    if [ "$(jq -r 'length' <<<"$remaining_json")" = "0" ]; then
      checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_placeholders)" \
        '. + [{id: "claude_md_placeholders", severity: $sev, result: "ok"}]' <<<"$checks")"
    else
      checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_placeholders)" \
        '. + [{id: "claude_md_placeholders", severity: $sev, result: "finding"}]' <<<"$checks")"
      findings="$(jq -c --arg sev "$(doctor_severity_of claude_md_placeholders)" \
        --argjson placeholders "$remaining_json" \
        '. + [{check: "claude_md_placeholders", severity: $sev,
               summary: ("未置換のテンプレートプレースホルダが " + ($placeholders | length | tostring) + " 件残っている"),
               items: [$placeholders[] | {placeholder: .}],
               remediation: "該当箇所を実際の値で置き換える"}]' <<<"$findings")"
    fi

    if ! doctor_doc_map_section "$claude_md" >/dev/null 2>&1; then
      checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_doc_map)" \
        --arg reason "CLAUDE.md にドキュメントマップ節が無い" \
        '. + [{id: "claude_md_doc_map", severity: $sev, result: "skipped", reason: $reason}]' <<<"$checks")"
    else
      local doc_items
      doc_items="$(doctor_doc_map_items_json "$project" "$claude_md")"
      if [ "$(jq -r 'length' <<<"$doc_items")" = "0" ]; then
        checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_doc_map)" \
          '. + [{id: "claude_md_doc_map", severity: $sev, result: "ok"}]' <<<"$checks")"
      else
        checks="$(jq -c --arg sev "$(doctor_severity_of claude_md_doc_map)" \
          '. + [{id: "claude_md_doc_map", severity: $sev, result: "finding"}]' <<<"$checks")"
        findings="$(jq -c --arg sev "$(doctor_severity_of claude_md_doc_map)" --argjson items "$doc_items" \
          '. + [{check: "claude_md_doc_map", severity: $sev,
                 summary: ("ドキュメントマップの " + ($items | length | tostring) + " 行が実ファイルと一致しない"),
                 items: $items,
                 remediation: "実体を作成するか、CLAUDE.md のドキュメントマップの状態を更新する"}]' <<<"$findings")"
      fi
    fi
  fi

  local status
  status="$(doctor_status_of_findings "$findings")"

  local output
  output="$(jq -n \
    --arg status "$status" --arg project "$project" \
    --arg settings_path "$target" --argjson settings_exists "$settings_exists" \
    --arg claude_md_path "$claude_md" --argjson claude_md_exists "$claude_md_exists" \
    --argjson checks "$checks" --argjson findings "$findings" \
    '{
      status: $status,
      project: $project,
      settings: {path: $settings_path, exists: $settings_exists},
      claudeMd: {path: $claude_md_path, exists: $claude_md_exists},
      counts: {
        checks: ($checks | length),
        ok: ([$checks[] | select(.result == "ok")] | length),
        finding: ([$checks[] | select(.result == "finding")] | length),
        skipped: ([$checks[] | select(.result == "skipped")] | length),
        blocking: ([$findings[] | select(.severity == "blocking")] | length),
        advisory: ([$findings[] | select(.severity == "advisory")] | length)
      },
      checks: $checks,
      findings: $findings
    }')"

  # 純粋関数の組み立て誤り・jq の失敗で空の stdout を返さないための最終防衛線
  # （空を返すと呼び出し側には「指摘0件」と区別が付かない）。
  if [ -z "$output" ] || ! jq -e '.status' >/dev/null 2>&1 <<<"$output"; then
    doctor_fail_prereq "failed to build the result JSON (this is a bug)"
  fi
  printf '%s\n' "$output"

  printf 'doctor: status=%s blocking=%s advisory=%s (%s)\n' \
    "$status" \
    "$(jq -r '[.[] | select(.severity == "blocking")] | length' <<<"$findings")" \
    "$(jq -r '[.[] | select(.severity == "advisory")] | length' <<<"$findings")" \
    "$project" >&2

  exit "$(doctor_exit_code_of_status "$status")"
}

# `source` された場合は doctor_main を実行しない（テストからの関数直接呼び出しを可能にするため）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  doctor_main "$@"
fi
