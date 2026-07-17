#!/bin/bash
# test-analyze-project.sh
# scripts/analyze-project.sh の純粋関数（classify_*/pick_*/build_*/project_name_fallback）と
# fetch_*/scan_* 系関数（一時フィクスチャディレクトリを使う）を検証する。
#
# 実行方法: bash scripts/tests/test-analyze-project.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../analyze-project.sh"

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

# --- 一時フィクスチャディレクトリ ---

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# ====================================================================
# 純粋関数: classify_pm
# ====================================================================

echo "=== test: classify_pm ==="
assert_eq "package-lock.json -> npm" "npm" "$(classify_pm "package-lock.json")"
assert_eq "yarn.lock -> yarn" "yarn" "$(classify_pm "yarn.lock")"
assert_eq "pnpm-lock.yaml -> pnpm" "pnpm" "$(classify_pm "pnpm-lock.yaml")"
assert_eq "bun.lockb -> bun" "bun" "$(classify_pm "bun.lockb")"
assert_eq "Cargo.toml -> cargo" "cargo" "$(classify_pm "Cargo.toml")"
assert_eq "go.mod -> go" "go" "$(classify_pm "go.mod")"
assert_eq "pyproject.toml -> pip" "pip" "$(classify_pm "pyproject.toml")"
assert_eq "requirements.txt -> pip" "pip" "$(classify_pm "requirements.txt")"
assert_eq "Gemfile -> bundler" "bundler" "$(classify_pm "Gemfile")"
assert_eq "該当ファイル無し -> 空文字" "" "$(classify_pm "README.md LICENSE")"
assert_eq "優先順位: package-lock.jsonがyarn.lockより優先" "npm" "$(classify_pm "yarn.lock package-lock.json")"
assert_eq "空文字列入力でもクラッシュせず空文字を返す(set -u下のempty array展開バグ回帰)" "" "$(classify_pm "")"

# ====================================================================
# 純粋関数: classify_language
# ====================================================================

echo "=== test: classify_language ==="
assert_eq "npm + tsconfig無し -> JavaScript" "JavaScript" "$(classify_language "npm" "false")"
assert_eq "npm + tsconfig有り -> TypeScript" "TypeScript" "$(classify_language "npm" "true")"
assert_eq "cargo -> Rust" "Rust" "$(classify_language "cargo" "false")"
assert_eq "go -> Go" "Go" "$(classify_language "go" "false")"
assert_eq "pip -> Python" "Python" "$(classify_language "pip" "false")"
assert_eq "bundler -> Ruby" "Ruby" "$(classify_language "bundler" "false")"
assert_eq "pm空 -> 空文字" "" "$(classify_language "" "false")"

# ====================================================================
# 純粋関数: project_name_fallback
# ====================================================================

echo "=== test: project_name_fallback ==="
RESULT=$(project_name_fallback "pkg-name" "cargo-name" "py-name" "go-module" "dirfallback")
assert_eq "pkg_nameが最優先" "pkg-name" "$(printf '%s' "$RESULT" | sed -n '1p')"
assert_eq "sourceがpackage.json" "package.json" "$(printf '%s' "$RESULT" | sed -n '2p')"

RESULT=$(project_name_fallback "" "cargo-name" "py-name" "go-module" "dirfallback")
assert_eq "pkg無しならcargo_name" "cargo-name" "$(printf '%s' "$RESULT" | sed -n '1p')"
assert_eq "sourceがCargo.toml" "Cargo.toml" "$(printf '%s' "$RESULT" | sed -n '2p')"

RESULT=$(project_name_fallback "" "" "py-name" "go-module" "dirfallback")
assert_eq "pkg/cargo無しならpyproject_name" "py-name" "$(printf '%s' "$RESULT" | sed -n '1p')"
assert_eq "sourceがpyproject.toml" "pyproject.toml" "$(printf '%s' "$RESULT" | sed -n '2p')"

RESULT=$(project_name_fallback "" "" "" "go-module" "dirfallback")
assert_eq "残り無しならgo_module" "go-module" "$(printf '%s' "$RESULT" | sed -n '1p')"
assert_eq "sourceがgo.mod" "go.mod" "$(printf '%s' "$RESULT" | sed -n '2p')"

RESULT=$(project_name_fallback "" "" "" "" "dirfallback")
assert_eq "全部無しならdirname" "dirfallback" "$(printf '%s' "$RESULT" | sed -n '1p')"
assert_eq "sourceがdirname" "dirname" "$(printf '%s' "$RESULT" | sed -n '2p')"

RESULT=$(project_name_fallback "null" "" "" "" "dirfallback")
assert_eq "pkg_nameがnull文字列なら次にフォールバック" "dirfallback" "$(printf '%s' "$RESULT" | sed -n '1p')"

# ====================================================================
# 純粋関数: pick_script_key
# ====================================================================

echo "=== test: pick_script_key ==="
SCRIPTS='{"test":"vitest run","lint":"eslint .","build":"tsc -b"}'
assert_eq "testキーが存在すれば返す" "test" "$(pick_script_key "$SCRIPTS" test test:unit test:e2e)"
assert_eq "typecheck系キーが無ければ空文字" "" "$(pick_script_key "$SCRIPTS" typecheck type-check tsc)"
SCRIPTS2='{"test:unit":"jest"}'
assert_eq "優先1位が無ければ2位を返す" "test:unit" "$(pick_script_key "$SCRIPTS2" test test:unit test:e2e)"

# ====================================================================
# 純粋関数: classify_stack_from_deps
# ====================================================================

echo "=== test: classify_stack_from_deps ==="
DEPS='["react","express","prisma","lodash"]'
classify_stack_from_deps "$DEPS"
assert_eq "frontendにreactが含まれる" "react" "$(jq -r '.[0]' <<<"$STACK_FRONTEND_JSON")"
assert_eq "backendにexpressが含まれる" "express" "$(jq -r '.[0]' <<<"$STACK_BACKEND_JSON")"
assert_eq "dbにprismaが含まれる" "prisma" "$(jq -r '.[0]' <<<"$STACK_DB_DEPS_JSON")"

DEPS_EMPTY='[]'
classify_stack_from_deps "$DEPS_EMPTY"
assert_eq "依存無しならfrontendは空配列" "0" "$(jq 'length' <<<"$STACK_FRONTEND_JSON")"
assert_eq "依存無しならbackendは空配列" "0" "$(jq 'length' <<<"$STACK_BACKEND_JSON")"
assert_eq "依存無しならdbは空配列" "0" "$(jq 'length' <<<"$STACK_DB_DEPS_JSON")"

# ====================================================================
# 純粋関数: classify_merge_style_line
# ====================================================================

echo "=== test: classify_merge_style_line ==="
assert_eq "'Merge pull request #12 ...' -> merge" "merge" "$(classify_merge_style_line "Merge pull request #12 from foo/bar")"
assert_eq "'Merge branch main' -> merge" "merge" "$(classify_merge_style_line "Merge branch 'main' into feature")"
assert_eq "'feat: foo (#42)' -> squash" "squash" "$(classify_merge_style_line "feat: foo (#42)")"
assert_eq "'feat: foo' (末尾にPR番号無し) -> other" "other" "$(classify_merge_style_line "feat: foo")"

# ====================================================================
# 純粋関数: build_axes_json（9軸の全数性検証）
# ====================================================================

echo "=== test: build_axes_json ==="
AXES=$(build_axes_json "auto-yes" "orm detected" "auto-no" "no openapi" "auto-yes" "e2e dir found")
assert_eq "9軸すべて含まれる" "9" "$(jq 'length' <<<"$AXES")"
assert_eq "axis番号が1から9まで漏れなく連番" "1 2 3 4 5 6 7 8 9" "$(jq -r '[.[].axis] | join(" ")' <<<"$AXES")"
assert_eq "axis1はask-user固定" "ask-user" "$(jq -r '.[0].standing' <<<"$AXES")"
assert_eq "axis5(DB中心性)は引数のstanding" "auto-yes" "$(jq -r '.[4].standing' <<<"$AXES")"
assert_eq "axis5のevidenceが引数どおり" "orm detected" "$(jq -r '.[4].evidence' <<<"$AXES")"
assert_eq "axis6(API外部公開度)は引数のstanding" "auto-no" "$(jq -r '.[5].standing' <<<"$AXES")"
assert_eq "axis9(テスト戦略複雑度)は引数のstanding" "auto-yes" "$(jq -r '.[8].standing' <<<"$AXES")"
assert_eq "axis2はask-user固定" "ask-user" "$(jq -r '.[1].standing' <<<"$AXES")"
assert_eq "axis3はask-user固定" "ask-user" "$(jq -r '.[2].standing' <<<"$AXES")"
assert_eq "axis4はask-user固定" "ask-user" "$(jq -r '.[3].standing' <<<"$AXES")"
assert_eq "axis7はask-user固定" "ask-user" "$(jq -r '.[6].standing' <<<"$AXES")"
assert_eq "axis8はask-user固定" "ask-user" "$(jq -r '.[7].standing' <<<"$AXES")"
assert_eq "axis名: 5=DBの中心性" "DBの中心性" "$(jq -r '.[4].name' <<<"$AXES")"
assert_eq "axis名: 6=APIの外部公開度" "APIの外部公開度" "$(jq -r '.[5].name' <<<"$AXES")"
assert_eq "axis名: 9=テスト戦略の複雑度" "テスト戦略の複雑度" "$(jq -r '.[8].name' <<<"$AXES")"

# ====================================================================
# fetch系: Node/npm/react/express/prisma プロジェクトのフィクスチャ
# ====================================================================

echo "=== test: fetch_pm_and_language (npm + TypeScript) ==="
NODE_DIR="${TMP_ROOT}/node-project"
mkdir -p "$NODE_DIR"
cat > "$NODE_DIR/package.json" <<'EOF'
{
  "name": "sample-node-app",
  "dependencies": {"react": "^18.0.0", "express": "^4.0.0"},
  "devDependencies": {"prisma": "^5.0.0", "jest": "^29.0.0"},
  "scripts": {
    "test": "jest",
    "lint": "eslint .",
    "typecheck": "tsc --noEmit",
    "format": "prettier --write .",
    "build": "tsc -b",
    "dev": "next dev"
  }
}
EOF
: > "$NODE_DIR/package-lock.json"
: > "$NODE_DIR/tsconfig.json"
: > "$NODE_DIR/jest.config.js"

fetch_pm_and_language "$NODE_DIR"
assert_eq "npm検出" "npm" "$PM_RESULT"
assert_eq "tsconfig.json有りでTypeScript判定" "TypeScript" "$LANGUAGE_RESULT"

echo "=== test: fetch_project_name (package.json優先) ==="
fetch_project_name "$NODE_DIR"
assert_eq "package.jsonのnameを採用" "sample-node-app" "$NAME_RESULT"
assert_eq "nameSourceがpackage.json" "package.json" "$NAME_SOURCE_RESULT"

echo "=== test: fetch_stack_evidence (Node fixture) ==="
fetch_stack_evidence "$NODE_DIR"
assert_eq "stack.frontendにreact" "react" "$(jq -r '.frontend[0]' <<<"$STACK_JSON")"
assert_eq "stack.backendにexpress" "express" "$(jq -r '.backend[0]' <<<"$STACK_JSON")"
assert_eq "stack.dbにprismaを含む(dependency経由)" "true" "$(jq '.db | any(. == "prisma")' <<<"$STACK_JSON")"
assert_eq "stack.testにjestを含む(jest.config.js検出)" "true" "$(jq '.test | any(. == "jest")' <<<"$STACK_JSON")"
assert_eq "軸5用ORM検出フラグがtrue" "true" "$STACK_HAS_ORM"

echo "=== test: fetch_commands (Node fixture) ==="
fetch_commands "$NODE_DIR" "npm"
assert_eq "test コマンドが npm run test" "npm run test" "$(jq -r '.test' <<<"$COMMANDS_JSON")"
assert_eq "lint コマンドが npm run lint" "npm run lint" "$(jq -r '.lint' <<<"$COMMANDS_JSON")"
assert_eq "typecheck コマンドが npm run typecheck" "npm run typecheck" "$(jq -r '.typecheck' <<<"$COMMANDS_JSON")"
assert_eq "build コマンドが npm run build" "npm run build" "$(jq -r '.build' <<<"$COMMANDS_JSON")"

echo "=== test: fetch_test_prereqs (pretestスクリプト検出) ==="
cat > "$NODE_DIR/package.json" <<'EOF'
{
  "name": "sample-node-app",
  "scripts": { "pretest": "docker compose up -d", "test": "jest" }
}
EOF
: > "$NODE_DIR/vitest.setup.ts"
fetch_test_prereqs "$NODE_DIR"
assert_eq "setupFilesにvitest.setup.tsを検出" "vitest.setup.ts" "$(jq -r '.setupFiles[0]' <<<"$TEST_PREREQS_JSON")"
assert_eq "pretestスクリプトを検出" "docker compose up -d" "$(jq -r '.pretest' <<<"$TEST_PREREQS_JSON")"

# ====================================================================
# fetch系: Python プロジェクトのフィクスチャ
# ====================================================================

echo "=== test: Python プロジェクト (pip) ==="
PY_DIR="${TMP_ROOT}/python-project"
mkdir -p "$PY_DIR"
cat > "$PY_DIR/pyproject.toml" <<'EOF'
[project]
name = "sample-python-app"
version = "0.1.0"

[tool.pytest]

[tool.ruff]

[tool.mypy]

[tool.black]
EOF
: > "$PY_DIR/pytest.ini"

fetch_pm_and_language "$PY_DIR"
assert_eq "pip検出" "pip" "$PM_RESULT"
assert_eq "Python言語判定" "Python" "$LANGUAGE_RESULT"

fetch_project_name "$PY_DIR"
assert_eq "pyproject.tomlのnameを採用" "sample-python-app" "$NAME_RESULT"
assert_eq "nameSourceがpyproject.toml" "pyproject.toml" "$NAME_SOURCE_RESULT"

fetch_commands "$PY_DIR" "pip"
assert_eq "Pythonのtestコマンドがpytest" "pytest" "$(jq -r '.test' <<<"$COMMANDS_JSON")"
assert_eq "Pythonのlintコマンドがruff" "ruff check ." "$(jq -r '.lint' <<<"$COMMANDS_JSON")"
assert_eq "Pythonのtypecheckコマンドがmypy" "mypy ." "$(jq -r '.typecheck' <<<"$COMMANDS_JSON")"
assert_eq "Pythonのformatコマンドがblack" "black ." "$(jq -r '.format' <<<"$COMMANDS_JSON")"

# ====================================================================
# fetch系: Rust プロジェクトのフィクスチャ
# ====================================================================

echo "=== test: Rust プロジェクト (cargo) ==="
RUST_DIR="${TMP_ROOT}/rust-project"
mkdir -p "$RUST_DIR"
cat > "$RUST_DIR/Cargo.toml" <<'EOF'
[package]
name = "sample-rust-app"
version = "0.1.0"
EOF

fetch_pm_and_language "$RUST_DIR"
assert_eq "cargo検出" "cargo" "$PM_RESULT"
assert_eq "Rust言語判定" "Rust" "$LANGUAGE_RESULT"

fetch_project_name "$RUST_DIR"
assert_eq "Cargo.tomlのnameを採用" "sample-rust-app" "$NAME_RESULT"

fetch_commands "$RUST_DIR" "cargo"
assert_eq "Rustのtestコマンドがcargo test" "cargo test" "$(jq -r '.test' <<<"$COMMANDS_JSON")"
assert_eq "Rustのlintコマンドがcargo clippy" "cargo clippy" "$(jq -r '.lint' <<<"$COMMANDS_JSON")"
assert_eq "Rustのformatコマンドがcargo fmt" "cargo fmt" "$(jq -r '.format' <<<"$COMMANDS_JSON")"
assert_eq "Rustのbuildコマンドがcargo build" "cargo build" "$(jq -r '.build' <<<"$COMMANDS_JSON")"

# ====================================================================
# fetch系: Go プロジェクトのフィクスチャ
# ====================================================================

echo "=== test: Go プロジェクト ==="
GO_DIR="${TMP_ROOT}/go-project"
mkdir -p "$GO_DIR"
cat > "$GO_DIR/go.mod" <<'EOF'
module github.com/example/sample-go-app

go 1.21
EOF
: > "$GO_DIR/.golangci.yml"

fetch_pm_and_language "$GO_DIR"
assert_eq "go検出" "go" "$PM_RESULT"
assert_eq "Go言語判定" "Go" "$LANGUAGE_RESULT"

fetch_project_name "$GO_DIR"
assert_eq "go.modのmodule名を採用" "github.com/example/sample-go-app" "$NAME_RESULT"
assert_eq "nameSourceがgo.mod" "go.mod" "$NAME_SOURCE_RESULT"

fetch_commands "$GO_DIR" "go"
assert_eq "Goのtestコマンド" "go test ./..." "$(jq -r '.test' <<<"$COMMANDS_JSON")"
assert_eq ".golangci.yml検出でlintコマンド設定" "golangci-lint run" "$(jq -r '.lint' <<<"$COMMANDS_JSON")"

# ====================================================================
# fetch系: ディレクトリ構成スキャン（除外・深さ制限・truncated）
# ====================================================================

echo "=== test: fetch_dir_tree (除外パターン) ==="
TREE_DIR="${TMP_ROOT}/tree-project"
mkdir -p "$TREE_DIR/src" "$TREE_DIR/node_modules/foo" "$TREE_DIR/.git" "$TREE_DIR/dist"
: > "$TREE_DIR/src/index.ts"
: > "$TREE_DIR/node_modules/foo/pkg.js"
: > "$TREE_DIR/dist/bundle.js"

fetch_dir_tree "$TREE_DIR" 3 200
assert_eq "node_modulesが除外される" "false" "$(jq '[.entries[] | select(startswith("node_modules"))] | length > 0' <<<"$DIR_TREE_JSON")"
assert_eq "distが除外される" "false" "$(jq '[.entries[] | select(startswith("dist"))] | length > 0' <<<"$DIR_TREE_JSON")"
assert_eq "srcは含まれる" "true" "$(jq '[.entries[] | select(startswith("src"))] | length > 0' <<<"$DIR_TREE_JSON")"
assert_eq "truncatedはfalse" "false" "$(jq -r '.truncated' <<<"$DIR_TREE_JSON")"

echo "=== test: fetch_dir_tree (件数上限でtruncated) ==="
MANY_DIR="${TMP_ROOT}/many-files"
mkdir -p "$MANY_DIR"
for i in $(seq 1 10); do : > "$MANY_DIR/file${i}.txt"; done
fetch_dir_tree "$MANY_DIR" 3 5
assert_eq "上限5件でtruncated=true" "true" "$(jq -r '.truncated' <<<"$DIR_TREE_JSON")"
assert_eq "entriesが上限5件に切り詰められる" "5" "$(jq '.entries | length' <<<"$DIR_TREE_JSON")"

# ====================================================================
# fetch系: ドキュメント/テスト/E2E配置
# ====================================================================

echo "=== test: fetch_docs_evidence ==="
DOCS_DIR_FIXTURE="${TMP_ROOT}/docs-project"
mkdir -p "$DOCS_DIR_FIXTURE/docs"
: > "$DOCS_DIR_FIXTURE/architecture.md"
: > "$DOCS_DIR_FIXTURE/docs/api_spec.yaml"
: > "$DOCS_DIR_FIXTURE/docs/openapi.json"

fetch_docs_evidence "$DOCS_DIR_FIXTURE"
assert_eq "docsDirが検出される" "docs" "$(jq -r '.docsDir' <<<"$DOCS_JSON")"
assert_eq "architecture.mdがdesignDocsに含まれる" "true" "$(jq '.designDocs | any(. == "architecture.md")' <<<"$DOCS_JSON")"
assert_eq "docs/api_spec.yamlがdesignDocsに含まれる" "true" "$(jq '.designDocs | any(. == "docs/api_spec.yaml")' <<<"$DOCS_JSON")"

echo "=== test: fetch_docs_evidence (docs無し) ==="
NO_DOCS_DIR="${TMP_ROOT}/no-docs-project"
mkdir -p "$NO_DOCS_DIR"
fetch_docs_evidence "$NO_DOCS_DIR"
assert_eq "docsDirがnull" "null" "$(jq -r '.docsDir' <<<"$DOCS_JSON")"
assert_eq "designDocsが空配列" "0" "$(jq '.designDocs | length' <<<"$DOCS_JSON")"

echo "=== test: fetch_test_dirs / fetch_e2e_dirs ==="
TEST_E2E_DIR="${TMP_ROOT}/test-e2e-project"
mkdir -p "$TEST_E2E_DIR/__tests__" "$TEST_E2E_DIR/e2e" "$TEST_E2E_DIR/src/playwright"
fetch_test_dirs "$TEST_E2E_DIR"
fetch_e2e_dirs "$TEST_E2E_DIR"
assert_eq "__tests__がtestDirsに含まれる" "true" "$(jq 'any(. == "__tests__")' <<<"$TEST_DIRS_JSON")"
assert_eq "e2eがe2eDirsに含まれる" "true" "$(jq 'any(. == "e2e")' <<<"$E2E_DIRS_JSON")"
assert_eq "src/playwrightがe2eDirsに含まれる" "true" "$(jq 'any(. == "src/playwright")' <<<"$E2E_DIRS_JSON")"

echo "=== test: fetch_e2e_dirs (対象無し) ==="
NO_E2E_DIR="${TMP_ROOT}/no-e2e-project"
mkdir -p "$NO_E2E_DIR"
fetch_e2e_dirs "$NO_E2E_DIR"
assert_eq "e2eDirsが空配列" "0" "$(jq 'length' <<<"$E2E_DIRS_JSON")"

# ====================================================================
# fetch系: ブランチ運用の証拠収集
# ====================================================================

echo "=== test: fetch_branch_evidence (gitリポジトリでない) ==="
NON_GIT_DIR="${TMP_ROOT}/non-git-project"
mkdir -p "$NON_GIT_DIR"
fetch_branch_evidence "$NON_GIT_DIR"
assert_eq "statusがnot_a_git_repo" "not_a_git_repo" "$(jq -r '.status' <<<"$BRANCH_EVIDENCE_JSON")"
assert_eq "branchesが空配列" "0" "$(jq '.branches | length' <<<"$BRANCH_EVIDENCE_JSON")"

echo "=== test: fetch_branch_evidence (gitリポジトリ、squash/merge集計) ==="
GIT_DIR="${TMP_ROOT}/git-project"
mkdir -p "$GIT_DIR"
git -C "$GIT_DIR" init -q -b main
git -C "$GIT_DIR" config user.email "test@example.com"
git -C "$GIT_DIR" config user.name "Test User"
: > "$GIT_DIR/file1.txt"
git -C "$GIT_DIR" add file1.txt
git -C "$GIT_DIR" commit -q -m "feat: add file1 (#1)"
: > "$GIT_DIR/file2.txt"
git -C "$GIT_DIR" add file2.txt
git -C "$GIT_DIR" commit -q -m "feat: add file2 (#2)"
git -C "$GIT_DIR" checkout -q -b feature/tmp
: > "$GIT_DIR/file3.txt"
git -C "$GIT_DIR" add file3.txt
git -C "$GIT_DIR" commit -q -m "wip"
git -C "$GIT_DIR" checkout -q main
git -C "$GIT_DIR" merge --no-ff -q -m "Merge branch 'feature/tmp'" feature/tmp
: > "$GIT_DIR/CONTRIBUTING.md"

fetch_branch_evidence "$GIT_DIR"
assert_eq "statusがok" "ok" "$(jq -r '.status' <<<"$BRANCH_EVIDENCE_JSON")"
assert_eq "mainブランチが含まれる" "true" "$(jq '.branches | any(. == "main")' <<<"$BRANCH_EVIDENCE_JSON")"
assert_eq "squashカウントが2" "2" "$(jq -r '.recentMergeStyles.squash' <<<"$BRANCH_EVIDENCE_JSON")"
assert_eq "mergeカウントが1" "1" "$(jq -r '.recentMergeStyles.merge' <<<"$BRANCH_EVIDENCE_JSON")"
assert_eq "contributingPathを検出" "CONTRIBUTING.md" "$(jq -r '.contributingPath' <<<"$BRANCH_EVIDENCE_JSON")"

# ====================================================================
# fetch系: 9軸のうち検出ベースの軸5/6/9
# ====================================================================

echo "=== test: fetch_axes (ORM検出→軸5 auto-yes) ==="
AXES_DIR="${TMP_ROOT}/axes-project"
mkdir -p "$AXES_DIR/prisma"
fetch_e2e_dirs "$AXES_DIR"
fetch_axes "$AXES_DIR" "true" "$E2E_DIRS_JSON"
assert_eq "軸5がauto-yes" "auto-yes" "$(jq -r '.[4].standing' <<<"$AXES_JSON")"
assert_eq "軸9がauto-no(e2e無し)" "auto-no" "$(jq -r '.[8].standing' <<<"$AXES_JSON")"
assert_eq "9軸すべて存在" "9" "$(jq 'length' <<<"$AXES_JSON")"

echo "=== test: fetch_axes (OpenAPI検出→軸6 auto-yes, E2E検出→軸9 auto-yes) ==="
AXES_DIR2="${TMP_ROOT}/axes-project2"
mkdir -p "$AXES_DIR2/e2e"
: > "$AXES_DIR2/openapi.yaml"
fetch_e2e_dirs "$AXES_DIR2"
fetch_axes "$AXES_DIR2" "false" "$E2E_DIRS_JSON"
assert_eq "軸5がauto-no(ORM無し)" "auto-no" "$(jq -r '.[4].standing' <<<"$AXES_JSON")"
assert_eq "軸6がauto-yes(openapi.yaml検出)" "auto-yes" "$(jq -r '.[5].standing' <<<"$AXES_JSON")"
assert_eq "軸9がauto-yes(e2e/検出)" "auto-yes" "$(jq -r '.[8].standing' <<<"$AXES_JSON")"

# ====================================================================
# CLIレベル（統合）: フルスクリプト実行での全体構造検証
# ====================================================================

echo "=== test: CLIレベル フルJSON構造検証 (Node fixture) ==="
CLI_OUTPUT=$("$TARGET_SCRIPT" "$NODE_DIR")
CLI_EXIT=$?
assert_eq "exit code が 0" "0" "$CLI_EXIT"
assert_eq "statusがok" "ok" "$(jq -r '.status' <<<"$CLI_OUTPUT")"
assert_eq "pmがnpm" "npm" "$(jq -r '.pm' <<<"$CLI_OUTPUT")"
assert_eq "axesが9件" "9" "$(jq '.axes | length' <<<"$CLI_OUTPUT")"

REQUIRED_KEYS="status targetDir pm language name nameSource stack commands testPrereqs dirTree docs testDirs e2eDirs branchEvidence axes"
MISSING_KEYS=""
for k in $REQUIRED_KEYS; do
  has_key=$(jq --arg k "$k" 'has($k)' <<<"$CLI_OUTPUT")
  if [ "$has_key" != "true" ]; then
    MISSING_KEYS="${MISSING_KEYS} ${k}"
  fi
done
assert_eq "トップレベルキーの欠落なし" "" "$MISSING_KEYS"

echo "=== test: CLIレベル 完全に空のディレクトリ(set -u下のempty array展開バグ回帰) ==="
EMPTY_DIR="${TMP_ROOT}/completely-empty-project"
mkdir -p "$EMPTY_DIR"
EMPTY_STDERR_FILE="$(mktemp)"
EMPTY_OUTPUT=$("$TARGET_SCRIPT" "$EMPTY_DIR" 2>"$EMPTY_STDERR_FILE")
EMPTY_EXIT=$?
assert_eq "空ディレクトリでもexit code 0" "0" "$EMPTY_EXIT"
assert_eq "空ディレクトリでもstdoutはJSON1個のまま(stderrノイズ無し)" "" "$(cat "$EMPTY_STDERR_FILE")"
assert_eq "空ディレクトリでもstatusがok" "ok" "$(jq -r '.status' <<<"$EMPTY_OUTPUT")"
assert_eq "空ディレクトリではpmがnull" "null" "$(jq -r '.pm' <<<"$EMPTY_OUTPUT")"
rm -f "$EMPTY_STDERR_FILE"

echo "=== test: CLIレベル 存在しないディレクトリ ==="
NONEXISTENT_OUTPUT=$("$TARGET_SCRIPT" "/nonexistent/path/should/not/exist" 2>/dev/null)
NONEXISTENT_EXIT=$?
assert_eq "存在しないディレクトリはexit非0" "1" "$NONEXISTENT_EXIT"
assert_eq "statusがerror" "error" "$(jq -r '.status' <<<"$NONEXISTENT_OUTPUT")"

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
