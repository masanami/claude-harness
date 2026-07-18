#!/bin/bash
# analyze-project.sh
# skills/init-project/SKILL.md Step 2（プロジェクト自動分析 2a〜2h）を決定的に実行する。
#
# 使い方:
#   scripts/analyze-project.sh [対象ディレクトリ]
#     -> 省略時はカレントディレクトリを分析する
#
# 出力（stdout にJSON1個）:
#   {
#     "status": "ok" | "error",
#     "targetDir": "...",
#     "pm": "npm" | ... | null,
#     "language": "TypeScript" | ... | null,
#     "name": "...", "nameSource": "package.json" | ... | "dirname",
#     "stack": {"frontend":[...], "backend":[...], "db":[...], "test":[...], "infra":[...]},
#     "commands": {"test":..., "lint":..., "typecheck":..., "format":..., "build":..., "dev":...},
#     "testPrereqs": {"setupFiles":[...], "pretest": "..."|null},
#     "dirTree": {"entries":[...], "depthLimit":N, "maxEntries":N, "truncated":bool},
#     "docs": {"docsDir":"docs"|null, "designDocs":[...]},
#     "testDirs": [...], "e2eDirs": [...], "colocatedTests": true|false,
#     "branchEvidence": {"status":"ok"|"not_a_git_repo", "branches":[...],
#       "recentMergeStyles":{"squash":N,"merge":N}, "contributingPath":"..."|null},
#     "axes": [ {axis:1,name:"...",standing:"auto-yes"|"auto-no"|"ask-user",evidence:"..."}, ... x9 ]
#   }
#
# 「特定できなかった」は暗黙の空文字/空配列ではなく明示フィールド（pmStatus, nameSource 等）で表現する。
# jq 必須。jq 不在時は stderr にエラーメッセージ + エラーJSONを出し exit 非0。
#
# テスト容易性のため、外部（filesystem/git）を読む fetch_*/scan_* 系関数と、
# 入力値だけから判定する純粋な classify_*/pick_*/build_*/project_name_fallback 系関数を分離している。
# このファイルを `source` すれば、両方の関数を直接呼び出してテストできる
# （BASH_SOURCE ガードにより source 時は main が自動実行されない）。

set -u

# ------------------------------------------------------------------
# 共通ヘルパー
# ------------------------------------------------------------------

check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"status":"error","error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# 空白区切りリスト $2.. の中に要素 $1 が含まれるか
_contains_word() {
  local needle="$1"
  shift
  local w
  for w in "$@"; do
    [ "$w" = "$needle" ] && return 0
  done
  return 1
}

# ------------------------------------------------------------------
# 2a. パッケージマネージャ & 言語の検出（純粋関数）
# ------------------------------------------------------------------

# 引数: ルート直下に存在するファイル名の空白区切りリスト
# 戻り値: pm文字列（npm/yarn/pnpm/bun/cargo/go/pip/bundler）を stdout に出力。
#         該当なしは空文字。
classify_pm() {
  local files="$*"
  local f
  # shellcheck disable=SC2206
  local -a arr=($files)
  if _contains_word "package-lock.json" "${arr[@]:-}"; then echo "npm"; return; fi
  if _contains_word "yarn.lock" "${arr[@]:-}"; then echo "yarn"; return; fi
  if _contains_word "pnpm-lock.yaml" "${arr[@]:-}"; then echo "pnpm"; return; fi
  if _contains_word "bun.lockb" "${arr[@]:-}"; then echo "bun"; return; fi
  if _contains_word "Cargo.toml" "${arr[@]:-}"; then echo "cargo"; return; fi
  if _contains_word "go.mod" "${arr[@]:-}"; then echo "go"; return; fi
  if _contains_word "pyproject.toml" "${arr[@]:-}"; then echo "pip"; return; fi
  if _contains_word "requirements.txt" "${arr[@]:-}"; then echo "pip"; return; fi
  if _contains_word "Gemfile" "${arr[@]:-}"; then echo "bundler"; return; fi
  echo ""
}

# 引数: pm文字列, tsconfig.jsonの有無("true"/"false"), package.jsonの有無("true"/"false")
# pm がロックファイル不在で空文字でも、package.json があれば Node.js（JS/TS）と判定する
# （PM判定＝ロックファイル起点、言語判定＝package.json起点で分離）
classify_language() {
  local pm="$1"
  local has_tsconfig="${2:-false}"
  local has_package_json="${3:-false}"
  case "$pm" in
    npm|yarn|pnpm|bun)
      if [ "$has_tsconfig" = "true" ]; then echo "TypeScript"; else echo "JavaScript"; fi
      ;;
    cargo) echo "Rust" ;;
    go) echo "Go" ;;
    pip) echo "Python" ;;
    bundler) echo "Ruby" ;;
    *)
      if [ "$has_package_json" = "true" ]; then
        if [ "$has_tsconfig" = "true" ]; then echo "TypeScript"; else echo "JavaScript"; fi
      else
        echo ""
      fi
      ;;
  esac
}

fetch_pm_and_language() {
  local dir="$1"
  local files
  files=$(cd "$dir" 2>/dev/null && find . -maxdepth 1 -mindepth 1 -type f -exec basename {} \; | tr '\n' ' ')
  local pm
  pm=$(classify_pm "$files")
  local has_tsconfig="false"
  [ -f "$dir/tsconfig.json" ] && has_tsconfig="true"
  local has_package_json="false"
  [ -f "$dir/package.json" ] && has_package_json="true"
  local language
  language=$(classify_language "$pm" "$has_tsconfig" "$has_package_json")
  PM_RESULT="$pm"
  LANGUAGE_RESULT="$language"
}

# ------------------------------------------------------------------
# 2f. プロジェクト名の検出
# ------------------------------------------------------------------

# TOML風ファイルから [section] 配下の key = "value" を抜き出す（簡易パーサ）
extract_toml_field() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || { echo ""; return; }
  awk -v section="$section" -v key="$key" '
    /^\[/ { insect = ($0 == "["section"]") ? 1 : 0; next }
    insect && $0 ~ "^"key"[[:space:]]*=" {
      line=$0
      sub("^"key"[[:space:]]*=[[:space:]]*", "", line)
      gsub(/"/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$file"
}

extract_gomod_module() {
  local file="$1"
  [ -f "$file" ] || { echo ""; return; }
  awk '/^module[[:space:]]+/ { print $2; exit }' "$file"
}

# 引数: pkg_name cargo_name pyproject_name gomod_module dirname
# 戻り値: stdout に「採用した名前」「ソース」を2行で出力する（command substitution経由でも
# 両方の値を取り出せるようにするため。グローバル変数への直接代入は行わない = 副作用のない純粋関数）。
project_name_fallback() {
  local pkg_name="$1" cargo_name="$2" pyproject_name="$3" gomod_module="$4" dirname="$5"
  if [ -n "$pkg_name" ] && [ "$pkg_name" != "null" ]; then
    printf '%s\n%s\n' "$pkg_name" "package.json"
    return
  fi
  if [ -n "$cargo_name" ]; then
    printf '%s\n%s\n' "$cargo_name" "Cargo.toml"
    return
  fi
  if [ -n "$pyproject_name" ]; then
    printf '%s\n%s\n' "$pyproject_name" "pyproject.toml"
    return
  fi
  if [ -n "$gomod_module" ]; then
    printf '%s\n%s\n' "$gomod_module" "go.mod"
    return
  fi
  printf '%s\n%s\n' "$dirname" "dirname"
}

fetch_project_name() {
  local dir="$1"
  local pkg_name="" cargo_name="" pyproject_name="" gomod_module=""
  if [ -f "$dir/package.json" ] && check_jq >/dev/null 2>&1; then
    pkg_name=$(jq -r '.name // empty' "$dir/package.json" 2>/dev/null)
  fi
  cargo_name=$(extract_toml_field "$dir/Cargo.toml" "package" "name")
  pyproject_name=$(extract_toml_field "$dir/pyproject.toml" "project" "name")
  gomod_module=$(extract_gomod_module "$dir/go.mod")
  local dirname
  dirname=$(basename "$(cd "$dir" 2>/dev/null && pwd)")
  local result
  result=$(project_name_fallback "$pkg_name" "$cargo_name" "$pyproject_name" "$gomod_module" "$dirname")
  NAME_RESULT=$(printf '%s\n' "$result" | sed -n '1p')
  NAME_SOURCE_RESULT=$(printf '%s\n' "$result" | sed -n '2p')
}

# ------------------------------------------------------------------
# 2b. 技術スタックの検出
# ------------------------------------------------------------------

# 引数: 依存パッケージ名のJSON配列（jq array of strings）
# グローバル変数 STACK_FRONTEND_JSON / STACK_BACKEND_JSON / STACK_DB_DEPS_JSON に結果を格納する純粋関数
classify_stack_from_deps() {
  local deps_json="$1"
  local frontend_candidates=(react vue next nuxt svelte astro remix "solid-js" qwik)
  local backend_candidates=(express fastify nest hono koa hapi)
  local db_candidates=(prisma typeorm sequelize "drizzle-orm" "@prisma/client" mongoose kysely knex)

  local -a frontend=() backend=() db=()
  local dep
  for dep in "${frontend_candidates[@]}"; do
    if jq -e --arg d "$dep" 'any(.[]?; . == $d)' >/dev/null 2>&1 <<<"$deps_json"; then
      frontend+=("$dep")
    fi
  done
  for dep in "${backend_candidates[@]}"; do
    if jq -e --arg d "$dep" 'any(.[]?; . == $d)' >/dev/null 2>&1 <<<"$deps_json"; then
      backend+=("$dep")
    fi
  done
  for dep in "${db_candidates[@]}"; do
    if jq -e --arg d "$dep" 'any(.[]?; . == $d)' >/dev/null 2>&1 <<<"$deps_json"; then
      db+=("$dep")
    fi
  done

  STACK_FRONTEND_JSON=$(printf '%s\n' "${frontend[@]:-}" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')
  STACK_BACKEND_JSON=$(printf '%s\n' "${backend[@]:-}" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')
  STACK_DB_DEPS_JSON=$(printf '%s\n' "${db[@]:-}" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')
}

# ルート直下の設定ファイル存在からdb/test/infraの追加証跡を検出する（純粋関数: 存在フラグ群を受け取る）
# 引数はすべて "true"/"false"
classify_config_evidence() {
  local has_prisma_dir="$1" has_drizzle_config="$2"
  local has_jest_config="$3" has_vitest_config="$4" has_playwright_config="$5" has_pytest_ini="$6"
  local has_dockerfile="$7" has_compose="$8" has_terraform="$9" has_gh_workflows="${10}"

  local -a db=() test=() infra=()
  [ "$has_prisma_dir" = "true" ] && db+=("prisma")
  [ "$has_drizzle_config" = "true" ] && db+=("drizzle")
  [ "$has_jest_config" = "true" ] && test+=("jest")
  [ "$has_vitest_config" = "true" ] && test+=("vitest")
  [ "$has_playwright_config" = "true" ] && test+=("playwright")
  [ "$has_pytest_ini" = "true" ] && test+=("pytest")
  [ "$has_dockerfile" = "true" ] && infra+=("Dockerfile")
  [ "$has_compose" = "true" ] && infra+=("docker-compose")
  [ "$has_terraform" = "true" ] && infra+=("terraform")
  [ "$has_gh_workflows" = "true" ] && infra+=("github-actions")

  CONFIG_DB_JSON=$(printf '%s\n' "${db[@]:-}" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')
  CONFIG_TEST_JSON=$(printf '%s\n' "${test[@]:-}" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')
  CONFIG_INFRA_JSON=$(printf '%s\n' "${infra[@]:-}" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')
}

fetch_stack_evidence() {
  local dir="$1"
  local pm="${2:-}"
  local deps_json="[]"
  if [ -f "$dir/package.json" ]; then
    deps_json=$(jq -c '[(.dependencies // {}), (.devDependencies // {})] | add | keys' "$dir/package.json" 2>/dev/null)
    [ -z "$deps_json" ] && deps_json="[]"
  fi
  classify_stack_from_deps "$deps_json"

  local has_prisma_dir="false" has_drizzle_config="false"
  [ -d "$dir/prisma" ] && has_prisma_dir="true"
  compgen -G "$dir/drizzle.config.*" >/dev/null 2>&1 && has_drizzle_config="true"

  local has_jest_config="false" has_vitest_config="false" has_playwright_config="false" has_pytest_ini="false"
  compgen -G "$dir/jest.config.*" >/dev/null 2>&1 && has_jest_config="true"
  compgen -G "$dir/vitest.config.*" >/dev/null 2>&1 && has_vitest_config="true"
  compgen -G "$dir/playwright.config.*" >/dev/null 2>&1 && has_playwright_config="true"
  if [ -f "$dir/pytest.ini" ] || grep -q '\[tool.pytest' "$dir/pyproject.toml" 2>/dev/null; then
    has_pytest_ini="true"
  fi

  local has_dockerfile="false" has_compose="false" has_terraform="false" has_gh_workflows="false"
  [ -f "$dir/Dockerfile" ] && has_dockerfile="true"
  [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose.yaml" ] && has_compose="true"
  [ -d "$dir/terraform" ] && has_terraform="true"
  [ -d "$dir/.github/workflows" ] && has_gh_workflows="true"

  classify_config_evidence "$has_prisma_dir" "$has_drizzle_config" \
    "$has_jest_config" "$has_vitest_config" "$has_playwright_config" "$has_pytest_ini" \
    "$has_dockerfile" "$has_compose" "$has_terraform" "$has_gh_workflows"

  # pm(言語) 由来のbackendエントリ。go.mod/Cargo.tomlのみでnpm系backend依存が
  # 無い（例: 素のGo/RustのAPIサーバ）プロジェクトが stack.backend 空配列になるのを防ぐ
  local backend_lang_json="[]"
  case "$pm" in
    go) backend_lang_json='["go"]' ;;
    cargo) backend_lang_json='["rust"]' ;;
  esac

  STACK_JSON=$(jq -n \
    --argjson frontend "$STACK_FRONTEND_JSON" \
    --argjson backend "$(jq -c -s 'add | unique' <(echo "$STACK_BACKEND_JSON") <(echo "$backend_lang_json"))" \
    --argjson db "$(jq -c -s 'add | unique' <(echo "$STACK_DB_DEPS_JSON") <(echo "$CONFIG_DB_JSON"))" \
    --argjson test "$CONFIG_TEST_JSON" \
    --argjson infra "$CONFIG_INFRA_JSON" \
    '{frontend:$frontend, backend:$backend, db:$db, test:$test, infra:$infra}')

  # OpenAPI/Swagger, ORM, E2E 判定に使う真偽値をグローバルに残す（axes構築用）
  STACK_HAS_ORM="false"
  [ "$(jq 'length' <<<"$STACK_DB_DEPS_JSON")" != "0" ] && STACK_HAS_ORM="true"
  [ "$has_prisma_dir" = "true" ] && STACK_HAS_ORM="true"
  [ "$has_drizzle_config" = "true" ] && STACK_HAS_ORM="true"
}

# ------------------------------------------------------------------
# 2c. コマンドの検出
# ------------------------------------------------------------------

# 引数: package.jsonのscripts(jq object文字列), 優先キー...
# 戻り値: 最初に一致したキー名。無ければ空文字。
pick_script_key() {
  local scripts_json="$1"
  shift
  local key
  for key in "$@"; do
    if jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1 <<<"$scripts_json"; then
      echo "$key"
      return 0
    fi
  done
  echo ""
  return 1
}

fetch_node_commands() {
  local dir="$1" pm="$2"
  local scripts_json="{}"
  [ -f "$dir/package.json" ] && scripts_json=$(jq -c '.scripts // {}' "$dir/package.json" 2>/dev/null)
  [ -z "$scripts_json" ] && scripts_json="{}"

  local runner="$pm"
  local test_key lint_key typecheck_key format_key build_key dev_key
  test_key=$(pick_script_key "$scripts_json" test test:unit test:e2e)
  lint_key=$(pick_script_key "$scripts_json" lint lint:fix)
  typecheck_key=$(pick_script_key "$scripts_json" typecheck type-check tsc)
  format_key=$(pick_script_key "$scripts_json" format fmt)
  build_key=$(pick_script_key "$scripts_json" build)
  dev_key=$(pick_script_key "$scripts_json" dev start)

  local test_cmd="null" lint_cmd="null" typecheck_cmd="null" format_cmd="null" build_cmd="null" dev_cmd="null"
  [ -n "$test_key" ] && test_cmd="\"${runner} run ${test_key}\""
  [ -n "$lint_key" ] && lint_cmd="\"${runner} run ${lint_key}\""
  [ -n "$typecheck_key" ] && typecheck_cmd="\"${runner} run ${typecheck_key}\""
  [ -n "$format_key" ] && format_cmd="\"${runner} run ${format_key}\""
  [ -n "$build_key" ] && build_cmd="\"${runner} run ${build_key}\""
  [ -n "$dev_key" ] && dev_cmd="\"${runner} run ${dev_key}\""

  COMMANDS_JSON=$(jq -n \
    --argjson test "$test_cmd" --argjson lint "$lint_cmd" --argjson typecheck "$typecheck_cmd" \
    --argjson format "$format_cmd" --argjson build "$build_cmd" --argjson dev "$dev_cmd" \
    '{test:$test, lint:$lint, typecheck:$typecheck, format:$format, build:$build, dev:$dev}')
}

fetch_non_node_commands() {
  local dir="$1" pm="$2"
  local test_cmd="null" lint_cmd="null" typecheck_cmd="null" format_cmd="null" build_cmd="null" dev_cmd="null"

  case "$pm" in
    cargo)
      test_cmd='"cargo test"'
      lint_cmd='"cargo clippy"'
      format_cmd='"cargo fmt"'
      build_cmd='"cargo build"'
      ;;
    go)
      test_cmd='"go test ./..."'
      build_cmd='"go build ./..."'
      if [ -f "$dir/.golangci.yml" ] || [ -f "$dir/.golangci.yaml" ]; then
        lint_cmd='"golangci-lint run"'
      fi
      ;;
    pip)
      if [ -f "$dir/pytest.ini" ] || grep -q '\[tool.pytest' "$dir/pyproject.toml" 2>/dev/null; then
        test_cmd='"pytest"'
      fi
      if [ -f "$dir/ruff.toml" ] || grep -q '\[tool.ruff\]' "$dir/pyproject.toml" 2>/dev/null; then
        lint_cmd='"ruff check ."'
      elif [ -f "$dir/.flake8" ]; then
        lint_cmd='"flake8"'
      fi
      if [ -f "$dir/mypy.ini" ] || grep -q '\[tool.mypy\]' "$dir/pyproject.toml" 2>/dev/null; then
        typecheck_cmd='"mypy ."'
      fi
      if grep -q '\[tool.black\]' "$dir/pyproject.toml" 2>/dev/null; then
        format_cmd='"black ."'
      fi
      ;;
    bundler)
      [ -d "$dir/spec" ] && test_cmd='"bundle exec rspec"'
      [ -f "$dir/.rubocop.yml" ] && lint_cmd='"bundle exec rubocop"'
      ;;
  esac

  COMMANDS_JSON=$(jq -n \
    --argjson test "$test_cmd" --argjson lint "$lint_cmd" --argjson typecheck "$typecheck_cmd" \
    --argjson format "$format_cmd" --argjson build "$build_cmd" --argjson dev "$dev_cmd" \
    '{test:$test, lint:$lint, typecheck:$typecheck, format:$format, build:$build, dev:$dev}')
}

fetch_commands() {
  local dir="$1" pm="$2"
  case "$pm" in
    npm|yarn|pnpm|bun) fetch_node_commands "$dir" "$pm" ;;
    cargo|go|pip|bundler) fetch_non_node_commands "$dir" "$pm" ;;
    *) COMMANDS_JSON='{"test":null,"lint":null,"typecheck":null,"format":null,"build":null,"dev":null}' ;;
  esac
}

# ------------------------------------------------------------------
# 2c-2. テスト環境の前提条件
# ------------------------------------------------------------------

fetch_test_prereqs() {
  local dir="$1"
  local -a setup_files=()
  local f
  for f in vitest.setup.ts vitest.setup.js jest.setup.ts jest.setup.js; do
    [ -f "$dir/$f" ] && setup_files+=("$f")
  done
  local setup_json
  setup_json=$(printf '%s\n' "${setup_files[@]:-}" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')

  local pretest="null"
  if [ -f "$dir/package.json" ]; then
    local pretest_val
    pretest_val=$(jq -r '.scripts.pretest // empty' "$dir/package.json" 2>/dev/null)
    [ -n "$pretest_val" ] && pretest=$(jq -n --arg v "$pretest_val" '$v')
  fi

  TEST_PREREQS_JSON=$(jq -n --argjson setupFiles "$setup_json" --argjson pretest "$pretest" \
    '{setupFiles:$setupFiles, pretest:$pretest}')
}

# ------------------------------------------------------------------
# 2d. ディレクトリ構成のスキャン
# ------------------------------------------------------------------

fetch_dir_tree() {
  local dir="$1"
  local max_depth="${2:-3}"
  local max_entries="${3:-200}"
  local all_entries
  # 除外ディレクトリは走査前に -prune で刈り込む（grep で事後除外すると大規模プロジェクトで
  # node_modules 等を全走査してメモリに積むことになり、解析時間・メモリ使用量が急増するため）
  all_entries=$(cd "$dir" 2>/dev/null && find . -mindepth 1 -maxdepth "$max_depth" \
    \( -type d \( -name .git -o -name node_modules -o -name dist -o -name .next \
       -o -name target -o -name __pycache__ -o -name .venv -o -name vendor \) \) -prune \
    -o \( -type d -o -type f \) -print 2>/dev/null \
    | sed 's|^\./||' \
    | sort)
  local total_count=0
  [ -n "$all_entries" ] && total_count=$(printf '%s\n' "$all_entries" | awk 'NF' | wc -l | tr -d ' ')
  local truncated="false"
  local entries="$all_entries"
  if [ "$total_count" -gt "$max_entries" ]; then
    truncated="true"
    entries=$(printf '%s\n' "$all_entries" | head -n "$max_entries")
  fi
  local entries_json
  entries_json=$(printf '%s\n' "$entries" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')

  DIR_TREE_JSON=$(jq -n --argjson entries "$entries_json" --argjson depthLimit "$max_depth" \
    --argjson maxEntries "$max_entries" --argjson truncated "$truncated" \
    '{entries:$entries, depthLimit:$depthLimit, maxEntries:$maxEntries, truncated:$truncated}')
}

# ------------------------------------------------------------------
# 2e. ドキュメント・テスト配置の検出
# ------------------------------------------------------------------

DESIGN_DOC_PATTERNS=(
  "architecture*" "system_design*" "system_architecture*"
  "domain_model*" "domain*" "erd*"
  "table_definition*" "schema*" "database*"
  "api_spec*" "api_specifications*" "openapi*" "swagger*"
)

# 文書・仕様ファイルとして許可する拡張子。下流（skills/init-project/SKILL.md）が
# designDocs を「整備済み」の正本として扱うため、schema.ts のような実装ファイルや
# ディレクトリ（src/domain 等）を誤って含めないよう -type f + 拡張子で限定する。
DESIGN_DOC_EXTENSIONS_REGEX='\.(md|mdx|txt|rst|adoc|yaml|yml|json|png|svg|drawio|excalidraw|puml|sql)$'

fetch_docs_evidence() {
  local dir="$1"
  local docs_dir="null"
  [ -d "$dir/docs" ] && docs_dir='"docs"'

  local -a results=()
  local pattern
  for pattern in "${DESIGN_DOC_PATTERNS[@]}"; do
    while IFS= read -r f; do
      [ -n "$f" ] && results+=("$f")
    done < <(cd "$dir" 2>/dev/null && find . \
      \( -path "./.git" -o -path "./node_modules" -o -path "./dist" -o -path "./.next" \
         -o -path "./target" -o -path "./__pycache__" -o -path "./.venv" -o -path "./vendor" \) -prune \
      -o -type f -iname "$pattern" -print 2>/dev/null \
      | sed 's|^\./||' \
      | grep -Ei "$DESIGN_DOC_EXTENSIONS_REGEX")
  done
  local design_docs_json
  design_docs_json=$(printf '%s\n' "${results[@]:-}" | awk 'NF' | sort -u | jq -R -s 'split("\n") | map(select(length>0))')

  DOCS_JSON=$(jq -n --argjson docsDir "$docs_dir" --argjson designDocs "$design_docs_json" \
    '{docsDir:$docsDir, designDocs:$designDocs}')
}

fetch_named_dirs() {
  local dir="$1"
  shift
  local -a names=("$@")
  local -a results=()
  local name
  for name in "${names[@]}"; do
    while IFS= read -r f; do
      [ -n "$f" ] && results+=("$f")
    done < <(cd "$dir" 2>/dev/null && find . \
      \( -path "./.git" -o -path "./node_modules" -o -path "./dist" -o -path "./.next" \
         -o -path "./target" -o -path "./__pycache__" -o -path "./.venv" -o -path "./vendor" \) -prune \
      -o -type d -name "$name" -print 2>/dev/null | sed 's|^\./||')
  done
  printf '%s\n' "${results[@]:-}" | awk 'NF' | sort -u | jq -R -s 'split("\n") | map(select(length>0))'
}

fetch_test_dirs() {
  local dir="$1"
  TEST_DIRS_JSON=$(fetch_named_dirs "$dir" "__tests__" "test" "tests" "spec")
}

fetch_e2e_dirs() {
  local dir="$1"
  E2E_DIRS_JSON=$(fetch_named_dirs "$dir" "e2e" "playwright" "cypress")
}

# fetch_test_dirs はディレクトリ名ベースの検出のため、src/foo.test.ts のような
# co-located（テスト対象と同じディレクトリに置く）配置を取りこぼす。
# 別フィールド colocatedTests（真偽値）で存在有無のみ補う。
fetch_colocated_tests() {
  local dir="$1"
  local hit
  hit=$(cd "$dir" 2>/dev/null && find . \
    \( -path "./.git" -o -path "./node_modules" -o -path "./dist" -o -path "./.next" \
       -o -path "./target" -o -path "./__pycache__" -o -path "./.venv" -o -path "./vendor" \) -prune \
    -o -type f \( -iname "*.test.*" -o -iname "*.spec.*" \) -print 2>/dev/null | head -1)
  if [ -n "$hit" ]; then
    COLOCATED_TESTS_JSON="true"
  else
    COLOCATED_TESTS_JSON="false"
  fi
}

# ------------------------------------------------------------------
# 2g. ブランチ運用（証拠収集のみ。戦略の推定・解釈はしない）
# ------------------------------------------------------------------

# 引数: コミットsubject 1行
# 戻り値: "merge" | "squash" | "other"
classify_merge_style_line() {
  local subject="$1"
  if [[ "$subject" =~ ^Merge\ pull\ request ]] || [[ "$subject" =~ ^Merge\ branch ]]; then
    echo "merge"
  elif [[ "$subject" =~ \(#[0-9]+\)$ ]]; then
    echo "squash"
  else
    echo "other"
  fi
}

fetch_branch_evidence() {
  local dir="$1"
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH_EVIDENCE_JSON='{"status":"not_a_git_repo","branches":[],"recentMergeStyles":{"squash":0,"merge":0},"contributingPath":null}'
    return
  fi

  local branches_raw
  branches_raw=$(git -C "$dir" branch -a --format='%(refname:short)' 2>/dev/null)
  local branches_json
  branches_json=$(printf '%s\n' "$branches_raw" | awk 'NF' | jq -R -s 'split("\n") | map(select(length>0))')

  local log_subjects
  log_subjects=$(git -C "$dir" log -n 30 --pretty=format:'%s' 2>/dev/null)

  local squash=0 merge=0
  local line style
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    style=$(classify_merge_style_line "$line")
    case "$style" in
      squash) squash=$((squash + 1)) ;;
      merge) merge=$((merge + 1)) ;;
    esac
  done <<<"$log_subjects"

  local contributing_path="null"
  if [ -f "$dir/CONTRIBUTING.md" ]; then
    contributing_path='"CONTRIBUTING.md"'
  elif [ -f "$dir/.github/CONTRIBUTING.md" ]; then
    contributing_path='".github/CONTRIBUTING.md"'
  fi

  BRANCH_EVIDENCE_JSON=$(jq -n --argjson branches "$branches_json" --argjson squash "$squash" \
    --argjson merge "$merge" --argjson contributing "$contributing_path" \
    '{status:"ok", branches:$branches, recentMergeStyles:{squash:$squash, merge:$merge}, contributingPath:$contributing}')
}

# ------------------------------------------------------------------
# 2h. 9軸仮判定表
# ------------------------------------------------------------------

ASK_USER_EVIDENCE="検出だけでは判定不能。ユーザーへの確認が必要"

# 引数: db_standing db_evidence api_standing api_evidence e2e_standing e2e_evidence
# 純粋関数。9軸すべてを漏れなく含む配列を返す。
build_axes_json() {
  local db_standing="$1" db_evidence="$2"
  local api_standing="$3" api_evidence="$4"
  local e2e_standing="$5" e2e_evidence="$6"

  jq -n \
    --arg db_standing "$db_standing" --arg db_evidence "$db_evidence" \
    --arg api_standing "$api_standing" --arg api_evidence "$api_evidence" \
    --arg e2e_standing "$e2e_standing" --arg e2e_evidence "$e2e_evidence" \
    --arg ask "$ASK_USER_EVIDENCE" \
    '[
      {axis:1, name:"規模・複雑度", standing:"ask-user", evidence:$ask},
      {axis:2, name:"ドメイン特殊性", standing:"ask-user", evidence:$ask},
      {axis:3, name:"コード規約の統一度", standing:"ask-user", evidence:$ask},
      {axis:4, name:"データの重要性", standing:"ask-user", evidence:$ask},
      {axis:5, name:"DBの中心性", standing:$db_standing, evidence:$db_evidence},
      {axis:6, name:"APIの外部公開度", standing:$api_standing, evidence:$api_evidence},
      {axis:7, name:"運用負荷", standing:"ask-user", evidence:$ask},
      {axis:8, name:"規制・コンプライアンス", standing:"ask-user", evidence:$ask},
      {axis:9, name:"テスト戦略の複雑度", standing:$e2e_standing, evidence:$e2e_evidence}
    ]'
}

fetch_axes() {
  local dir="$1"
  local has_orm="$2"       # true/false（軸5用。fetch_stack_evidence の STACK_HAS_ORM）
  local e2e_dirs_json="$3" # 軸9用

  local db_standing db_evidence
  if [ "$has_orm" = "true" ]; then
    db_standing="auto-yes"
    db_evidence="ORM設定を検出（prisma/drizzle/typeorm/sequelize 等）"
  else
    db_standing="auto-no"
    db_evidence="ORM設定を検出せず"
  fi

  local has_openapi="false"
  local openapi_hit
  openapi_hit=$(cd "$dir" 2>/dev/null && find . \
    \( -path "./.git" -o -path "./node_modules" -o -path "./dist" -o -path "./.next" \
       -o -path "./target" -o -path "./__pycache__" -o -path "./.venv" -o -path "./vendor" \) -prune \
    -o -iname "openapi*" -print -o -iname "swagger*" -print 2>/dev/null | LC_ALL=C sort | head -1)
  [ -n "$openapi_hit" ] && has_openapi="true"

  local api_standing api_evidence
  if [ "$has_openapi" = "true" ]; then
    api_standing="auto-yes"
    api_evidence="OpenAPI/Swagger定義を検出: ${openapi_hit#./}"
  else
    api_standing="auto-no"
    api_evidence="OpenAPI/Swagger定義を検出せず"
  fi

  local e2e_count
  e2e_count=$(jq 'length' <<<"$e2e_dirs_json" 2>/dev/null || echo 0)
  local e2e_standing e2e_evidence
  if [ "$e2e_count" -gt 0 ]; then
    e2e_standing="auto-yes"
    e2e_evidence="E2Eディレクトリを検出: $(jq -r 'join(", ")' <<<"$e2e_dirs_json")"
  else
    e2e_standing="auto-no"
    e2e_evidence="E2Eディレクトリを検出せず"
  fi

  AXES_JSON=$(build_axes_json "$db_standing" "$db_evidence" "$api_standing" "$api_evidence" "$e2e_standing" "$e2e_evidence")
}

# ------------------------------------------------------------------
# main
# ------------------------------------------------------------------

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} [対象ディレクトリ] (省略時はカレントディレクトリ)" >&2
}

main() {
  if ! check_jq; then
    exit 1
  fi

  local target_dir="${1:-.}"
  if [ ! -d "$target_dir" ]; then
    echo "Error: directory not found: ${target_dir}" >&2
    jq -n --arg dir "$target_dir" '{status:"error", error:"directory_not_found", targetDir:$dir}'
    exit 1
  fi

  local abs_dir
  abs_dir=$(cd "$target_dir" && pwd)

  fetch_pm_and_language "$abs_dir"
  fetch_project_name "$abs_dir"
  fetch_stack_evidence "$abs_dir" "$PM_RESULT"
  fetch_commands "$abs_dir" "$PM_RESULT"
  fetch_test_prereqs "$abs_dir"
  fetch_dir_tree "$abs_dir"
  fetch_docs_evidence "$abs_dir"
  fetch_test_dirs "$abs_dir"
  fetch_e2e_dirs "$abs_dir"
  fetch_colocated_tests "$abs_dir"
  fetch_branch_evidence "$abs_dir"
  fetch_axes "$abs_dir" "$STACK_HAS_ORM" "$E2E_DIRS_JSON"

  local pm_json="null"
  [ -n "$PM_RESULT" ] && pm_json=$(jq -n --arg v "$PM_RESULT" '$v')
  local language_json="null"
  [ -n "$LANGUAGE_RESULT" ] && language_json=$(jq -n --arg v "$LANGUAGE_RESULT" '$v')

  jq -n \
    --arg status "ok" \
    --arg targetDir "$abs_dir" \
    --argjson pm "$pm_json" \
    --argjson language "$language_json" \
    --arg name "$NAME_RESULT" \
    --arg nameSource "$NAME_SOURCE_RESULT" \
    --argjson stack "$STACK_JSON" \
    --argjson commands "$COMMANDS_JSON" \
    --argjson testPrereqs "$TEST_PREREQS_JSON" \
    --argjson dirTree "$DIR_TREE_JSON" \
    --argjson docs "$DOCS_JSON" \
    --argjson testDirs "$TEST_DIRS_JSON" \
    --argjson e2eDirs "$E2E_DIRS_JSON" \
    --argjson colocatedTests "$COLOCATED_TESTS_JSON" \
    --argjson branchEvidence "$BRANCH_EVIDENCE_JSON" \
    --argjson axes "$AXES_JSON" \
    '{
      status: $status,
      targetDir: $targetDir,
      pm: $pm,
      language: $language,
      name: $name,
      nameSource: $nameSource,
      stack: $stack,
      commands: $commands,
      testPrereqs: $testPrereqs,
      dirTree: $dirTree,
      docs: $docs,
      testDirs: $testDirs,
      e2eDirs: $e2eDirs,
      colocatedTests: $colocatedTests,
      branchEvidence: $branchEvidence,
      axes: $axes
    }'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
