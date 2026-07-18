#!/bin/bash
# generate-settings.sh
# skills/init-project/SKILL.md Step 4b（.claude/settings.json 生成）を決定的に実行する。
#
# 使い方:
#   generate-settings.sh [--pm <pm>] [--test <framework>]... [--infra <infra>]...
#                         [--input <analyze-project.sh出力JSONファイル|->]
#                         [--target <出力先パス>]
#
#   --pm <pm>       パッケージマネージャ。analyze-project.sh の `pm` 出力語彙
#                    (npm/yarn/pnpm/bun/cargo/go/pip/bundler) を受け付ける。
#                    "python"/"ruby" もそれぞれ pip/bundler の別名として受け付ける。
#   --test <fw>     テストフレームワーク（pytest/vitest/jest/playwright）。複数回指定可。
#   --infra <infra> インフラ種別（"docker" を含む文字列。Dockerfile/docker-compose 等
#                    analyze-project.sh の stack.infra の値もそのまま渡せる）。複数回指定可。
#   --input <file>  analyze-project.sh の出力JSON（stdinの場合は "-"）。
#                    .pm / .stack.test[] / .stack.infra[] を抽出し、
#                    --pm/--test/--infra と合成する（--pm等が優先、test/infraは合算）。
#   --target <path> 出力先の .claude/settings.json パス（既定: ./.claude/settings.json）。
#
# 出力（stdout にJSON1個。scripts/README.md の出力規約に従う）:
#   {"status":"ok","target":"...","created":bool,"merged":bool,"allow_count":N,"deny_count":M}
#
# 挙動:
#   - `--target` が既存ファイルの場合、既存の permissions.allow/deny を保持しつつ
#     生成した allow/deny の非重複分のみ追加する（冪等マージ。同じ入力で再実行しても差分なし）
#   - `--target` が存在しない場合は新規作成する（親ディレクトリも作成する）
#   - ベース allow（共通権限）・ベース deny（single source of truth = base-deny.json）・
#     pm別/testFW別/infra別の条件付き allow を合成する
#   - jq 必須。jq 不在時は stderr にエラーメッセージ + エラーJSONを出し exit 非0（stdoutには何も出さない）
#
# テスト容易性のため、外部（ファイルシステム）を読み書きする main 相当の処理と、
# 引数だけから合成結果を組み立てる純粋な gs_*_json 系関数を分離している。
# このファイルを `source` すれば、`BASH_SOURCE` ガードにより main を自動実行せずに
# 純粋関数を直接テストできる。

set -u

# ------------------------------------------------------------------
# 共通ヘルパー
# ------------------------------------------------------------------

gs_check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"status":"error","error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# 配列JSON2つのunion（重複排除、順序はdecisive=jqのunique(ソート済み)に従う）
gs_union_unique_json() {
  local a="$1" b="$2"
  jq -n --argjson a "$a" --argjson b "$b" '($a + $b) | unique'
}

# ------------------------------------------------------------------
# ベース allow / deny（single source of truth）
# ------------------------------------------------------------------

# 共通権限（常に含める。約25項目）
gs_base_allow_json() {
  jq -n '[
    "Bash(git add:*)",
    "Bash(git commit:*)",
    "Bash(git push:*)",
    "Bash(git push origin:*)",
    "Bash(git push -u:*)",
    "Bash(git push --force-with-lease:*)",
    "Bash(git fetch:*)",
    "Bash(git checkout:*)",
    "Bash(git switch:*)",
    "Bash(git branch:*)",
    "Bash(git stash:*)",
    "Bash(git rebase:*)",
    "Bash(git merge:*)",
    "Bash(git worktree:*)",
    "Bash(git diff:*)",
    "Bash(git log:*)",
    "Bash(git show:*)",
    "Bash(git status:*)",
    "Bash(git rev-parse:*)",
    "Bash(git ls-remote:*)",
    "Bash(gh issue:*)",
    "Bash(gh pr:*)",
    "Bash(gh api:*)",
    "Bash(gh repo view:*)",
    "Bash(cd:*)"
  ]'
}

# ------------------------------------------------------------------
# スキーマ検証（純粋関数、exit code で判定。有効なJSONでも型契約が
# 異なると下流のjqが失敗し既存設定を破損させうるため、構文検証だけでなく
# 各JSON境界で型を検証する）
# ------------------------------------------------------------------

# 引数: JSON配列の文字列。全要素が文字列であることを検証する。
gs_validate_string_array_json() {
  local json="$1"
  jq -e '(type == "array") and (all(type == "string"))' >/dev/null 2>&1 <<<"$json"
}

# 引数: .claude/settings.json 相当のJSON文字列。
# ルートがオブジェクトで、permissions が省略またはオブジェクト、
# permissions.allow/deny が省略または文字列配列であることを検証する。
gs_validate_settings_schema() {
  local json="$1"
  jq -e '
    (type == "object")
    and ((.permissions == null) or (.permissions | type == "object"))
    and ((.permissions.allow == null) or ((.permissions.allow | type == "array") and (.permissions.allow | all(type == "string"))))
    and ((.permissions.deny == null) or ((.permissions.deny | type == "array") and (.permissions.deny | all(type == "string"))))
  ' >/dev/null 2>&1 <<<"$json"
}

# 引数: --input で渡される analyze-project.sh 出力相当のJSON文字列。
# .pm が省略または文字列、.stack.test/.stack.infra が省略または文字列配列であることを検証する。
gs_validate_analyze_input_schema() {
  local json="$1"
  jq -e '
    (type == "object")
    and ((.pm == null) or (.pm | type == "string"))
    and ((.stack == null) or (.stack | type == "object"))
    and ((.stack.test == null) or ((.stack.test | type == "array") and (.stack.test | all(type == "string"))))
    and ((.stack.infra == null) or ((.stack.infra | type == "array") and (.stack.infra | all(type == "string"))))
  ' >/dev/null 2>&1 <<<"$json"
}

# jq 内蔵のフォールバック（base-deny.json が読めない場合用）
gs_fallback_base_deny_json() {
  jq -n '[
    "Bash(rm -rf:*)",
    "Bash(rm -r:*)",
    "Bash(git push --force:*)",
    "Bash(git push -f:*)",
    "Bash(git clean -f:*)",
    "Bash(gh repo delete:*)"
  ]'
}

# ベースdenyの正本（base-deny.json）を読み込む。
# init-devcontainer 側もこのファイルを直接参照することで重複を排除している。
# 配置場所は「共有 scripts/config/」ではなく本スキルのローカルscripts/配下:
# このファイルの主たる所有者・更新者は generate-settings.sh（init-project）であり、
# init-devcontainer は${CLAUDE_PLUGIN_ROOT}経由のパス参照で読むだけの副次的な利用者のため。
# 引数: このスクリプトが置かれているディレクトリ（SCRIPT_DIR）
gs_load_base_deny_json() {
  local script_dir="$1"
  local deny_file="${script_dir}/base-deny.json"
  if [ -f "$deny_file" ]; then
    local content
    content="$(jq -c '.' "$deny_file" 2>/dev/null)"
    # 構文（valid JSON）だけでなく型契約（文字列配列）も検証する。
    # 有効なJSONでも型が違えば後続のunion/mergeでjqが失敗し、
    # 既存 .claude/settings.json の破損に繋がりうるため。
    if [ -n "$content" ] && gs_validate_string_array_json "$content"; then
      echo "$content"
      return 0
    fi
  fi
  gs_fallback_base_deny_json
}

# ------------------------------------------------------------------
# pm / test / infra 別の条件付き allow（純粋関数）
# ------------------------------------------------------------------

# 引数: pm文字列（npm/yarn/pnpm/bun/cargo/go/pip/python/bundler/ruby）
gs_pm_allow_json() {
  local pm="$1"
  case "$pm" in
    npm) echo '["Bash(npm:*)"]' ;;
    yarn) echo '["Bash(yarn:*)"]' ;;
    pnpm) echo '["Bash(pnpm:*)"]' ;;
    bun) echo '["Bash(bun:*)"]' ;;
    cargo) echo '["Bash(cargo:*)"]' ;;
    go) echo '["Bash(go:*)"]' ;;
    pip|python) echo '["Bash(python3:*)","Bash(pip:*)"]' ;;
    bundler|ruby) echo '["Bash(bundle:*)"]' ;;
    *) echo '[]' ;;
  esac
}

# 引数: testFWのカンマ区切り文字列（pytest,playwright等）, pm文字列
# playwrightはpmによって実行コマンドが変わるため合成時にpmを渡す。
# jest/vitestはpm権限でカバーされるため追加なし。
gs_test_allow_json() {
  local test_csv="$1" pm="${2:-}"
  local IFS=','
  # shellcheck disable=SC2206
  local -a items=($test_csv)
  local -a result=()
  local t

  for t in "${items[@]:-}"; do
    t="$(echo "$t" | tr -d '[:space:]')"
    case "$t" in
      pytest) result+=("Bash(pytest:*)") ;;
      playwright)
        case "$pm" in
          pnpm) result+=("Bash(pnpm exec playwright:*)") ;;
          yarn) result+=("Bash(yarn playwright:*)") ;;
          *) result+=("Bash(npx playwright:*)") ;;
        esac
        ;;
      *) : ;;
    esac
  done

  if [ "${#result[@]}" -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "${result[@]}" | jq -R -s 'split("\n") | map(select(length>0)) | unique'
  fi
}

# 引数: infraのカンマ区切り文字列（docker/Dockerfile/docker-compose等、大小無視で"docker"を含めば検出）
gs_infra_allow_json() {
  local infra_csv="$1"
  local IFS=','
  # shellcheck disable=SC2206
  local -a items=($infra_csv)
  local it lower has_docker="false"

  for it in "${items[@]:-}"; do
    lower="$(echo "$it" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      *docker*) has_docker="true" ;;
    esac
  done

  if [ "$has_docker" = "true" ]; then
    echo '["Bash(docker:*)","Bash(docker compose:*)"]'
  else
    echo '[]'
  fi
}

# ------------------------------------------------------------------
# 合成 / マージ（純粋関数、jqのみ使用）
# ------------------------------------------------------------------

# 引数: pm, testFWカンマ区切り, infraカンマ区切り, base_deny_json
# 戻り値: {"permissions":{"allow":[...],"deny":[...]}} の完全な settings JSON
gs_build_generated_settings_json() {
  local pm="$1" test_csv="$2" infra_csv="$3" base_deny_json="$4"
  local base_allow pm_allow test_allow infra_allow allow_all deny_all

  base_allow="$(gs_base_allow_json)"
  pm_allow="$(gs_pm_allow_json "$pm")"
  test_allow="$(gs_test_allow_json "$test_csv" "$pm")"
  infra_allow="$(gs_infra_allow_json "$infra_csv")"

  allow_all=$(jq -n \
    --argjson a "$base_allow" --argjson b "$pm_allow" \
    --argjson c "$test_allow" --argjson d "$infra_allow" \
    '($a + $b + $c + $d) | unique')
  deny_all=$(jq -n --argjson d "$base_deny_json" '$d | unique')

  jq -n --argjson allow "$allow_all" --argjson deny "$deny_all" \
    '{permissions: {allow: $allow, deny: $deny}}'
}

# 引数: 既存settings.jsonの内容(文字列), 生成したsettings.jsonの内容(文字列)
# 戻り値: マージ後の完全な settings JSON。
#   - allow/deny は既存を保持しつつ生成側の非重複分を追加（union unique）
#   - permissions以外の既存トップレベルキー、permissions配下の他キーも保持する
gs_merge_settings_json() {
  local existing="$1" generated="$2"
  local existing_allow existing_deny gen_allow gen_deny merged_allow merged_deny

  existing_allow=$(jq -c '.permissions.allow // []' <<<"$existing")
  existing_deny=$(jq -c '.permissions.deny // []' <<<"$existing")
  gen_allow=$(jq -c '.permissions.allow // []' <<<"$generated")
  gen_deny=$(jq -c '.permissions.deny // []' <<<"$generated")

  merged_allow=$(gs_union_unique_json "$existing_allow" "$gen_allow")
  merged_deny=$(gs_union_unique_json "$existing_deny" "$gen_deny")

  jq -n --argjson existing "$existing" --argjson allow "$merged_allow" --argjson deny "$merged_deny" \
    '$existing * {permissions: (($existing.permissions // {}) * {allow: $allow, deny: $deny})}'
}

# ------------------------------------------------------------------
# --input（analyze-project.sh出力）からの抽出
# ------------------------------------------------------------------

gs_extract_pm_from_input() {
  jq -r '.pm // empty' <<<"$1"
}

gs_extract_test_csv_from_input() {
  jq -r '(.stack.test // []) | join(",")' <<<"$1"
}

gs_extract_infra_csv_from_input() {
  jq -r '(.stack.infra // []) | join(",")' <<<"$1"
}

# ------------------------------------------------------------------
# main（外部I/O）
# ------------------------------------------------------------------

gs_print_usage() {
  cat >&2 <<'EOF'
使い方: generate-settings.sh [--pm <pm>] [--test <framework>]... [--infra <infra>]...
                              [--input <file|->] [--target <path>]
EOF
}

main() {
  local pm="" test_csv="" infra_csv="" input_arg="" target="./.claude/settings.json"

  while [ "$#" -gt 0 ]; do
    # 値を取るフラグが末尾で値なしのまま渡されると `shift 2` が失敗し
    # $# が減らず無限ループになるため、必ず値の有無を先にガードする。
    case "$1" in
      --pm|--test|--infra|--input|--target)
        if [ "$#" -lt 2 ]; then
          echo "Error: $1 requires a value" >&2
          gs_print_usage
          exit 1
        fi
        ;;
    esac
    case "$1" in
      --pm)
        pm="$2"
        shift 2
        ;;
      --test)
        if [ -z "$test_csv" ]; then test_csv="$2"; else test_csv="${test_csv},$2"; fi
        shift 2
        ;;
      --infra)
        if [ -z "$infra_csv" ]; then infra_csv="$2"; else infra_csv="${infra_csv},$2"; fi
        shift 2
        ;;
      --input)
        input_arg="$2"
        shift 2
        ;;
      --target)
        target="$2"
        shift 2
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        gs_print_usage
        exit 1
        ;;
    esac
  done

  if ! gs_check_jq; then
    exit 1
  fi

  if [ -n "$input_arg" ]; then
    local input_str
    if [ "$input_arg" = "-" ]; then
      input_str="$(cat)"
    else
      if [ ! -f "$input_arg" ]; then
        echo "Error: --input file not found: $input_arg" >&2
        printf '{"status":"error","error":"input file not found"}\n' >&2
        exit 1
      fi
      input_str="$(cat "$input_arg")"
    fi

    if ! jq -e . >/dev/null 2>&1 <<<"$input_str"; then
      echo "Error: --input is not valid JSON" >&2
      printf '{"status":"error","error":"invalid input json"}\n' >&2
      exit 1
    fi

    # 構文だけでなくスキーマ（.pm が文字列、.stack.test/.stack.infra が文字列配列）も
    # 検証する。型不一致のまま抽出を進めると下流のjqが失敗しうるため。
    if ! gs_validate_analyze_input_schema "$input_str"; then
      echo "Error: --input does not match expected schema (.pm must be a string, .stack.test/.stack.infra must be string arrays)" >&2
      printf '{"status":"error","error":"input json schema invalid"}\n' >&2
      exit 1
    fi

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

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local base_deny_json generated_json
  base_deny_json="$(gs_load_base_deny_json "$script_dir")"
  generated_json="$(gs_build_generated_settings_json "$pm" "$test_csv" "$infra_csv" "$base_deny_json")"

  local existed="false" final_json
  if [ -f "$target" ]; then
    existed="true"
    local existing_str
    existing_str="$(cat "$target")"
    if ! jq -e . >/dev/null 2>&1 <<<"$existing_str"; then
      echo "Error: existing target is not valid JSON: $target" >&2
      printf '{"status":"error","error":"existing target invalid json"}\n' >&2
      exit 1
    fi
    # 構文だけでなくスキーマ（permissions.allow/deny が文字列配列）も検証する。
    # 検証せずマージへ進むと下流のjqが失敗し、既存ファイルが空で
    # 上書きされる恐れがある（mvはtmp_fileの中身を検証しないため）。
    if ! gs_validate_settings_schema "$existing_str"; then
      echo "Error: existing target does not match expected schema (permissions.allow/deny must be string arrays): $target" >&2
      printf '{"status":"error","error":"existing target schema invalid"}\n' >&2
      exit 1
    fi
    final_json="$(gs_merge_settings_json "$existing_str" "$generated_json")"
  else
    final_json="$generated_json"
  fi

  # 合成/マージ結果そのものが期待スキーマを満たすことも最終防衛線として確認する
  # （純粋関数のロジック誤りで壊れたJSONを書き込まないため）。
  if ! gs_validate_settings_schema "$final_json"; then
    echo "Error: generated settings JSON failed internal schema validation (this is a bug)" >&2
    printf '{"status":"error","error":"generated settings schema invalid"}\n' >&2
    exit 1
  fi

  local target_dir tmp_file
  target_dir="$(dirname "$target")"
  if ! mkdir -p "$target_dir"; then
    echo "Error: cannot create target directory: $target_dir" >&2
    printf '{"status":"error","error":"target directory creation failed"}\n' >&2
    exit 1
  fi

  # 同一ディレクトリ内に mktemp で予測不可能な一時ファイルを作成し、
  # jq/mv 完了後に置き換える（アトミック置換）。
  # `${target}.tmp.$$` のような予測可能な名前は symlink 攻撃の対象になりうるため使わない。
  # jq/mv のいずれかが失敗した場合は既存ファイルを書き換えず、
  # status:"ok" を返さずにエラー終了する（部分書き込みで空ファイル化させない）。
  if ! tmp_file="$(mktemp "${target_dir}/.settings.json.tmp.XXXXXX" 2>/dev/null)"; then
    echo "Error: temporary file creation failed in $target_dir" >&2
    printf '{"status":"error","error":"temporary file creation failed"}\n' >&2
    exit 1
  fi
  trap 'rm -f "$tmp_file"' EXIT

  if ! jq '.' <<<"$final_json" > "$tmp_file" || ! mv "$tmp_file" "$target"; then
    echo "Error: failed to write target file: $target" >&2
    printf '{"status":"error","error":"target update failed"}\n' >&2
    exit 1
  fi
  trap - EXIT

  local allow_count deny_count created merged
  allow_count=$(jq '.permissions.allow | length' <<<"$final_json")
  deny_count=$(jq '.permissions.deny | length' <<<"$final_json")
  if [ "$existed" = "true" ]; then created="false"; merged="true"; else created="true"; merged="false"; fi

  jq -n \
    --arg target "$target" \
    --argjson created "$created" \
    --argjson merged "$merged" \
    --argjson allow_count "$allow_count" \
    --argjson deny_count "$deny_count" \
    '{status:"ok", target:$target, created:$created, merged:$merged, allow_count:$allow_count, deny_count:$deny_count}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
