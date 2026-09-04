#!/bin/bash
# test-claude-harness-run.sh
# bin/claude-harness-run（PATH 上へ導入するランチャー）の契約を検証する。
# - target 解決（短縮名 / プラグインルート相対パス / 拡張子ディスパッチ）
# - 引数・終了コード・cwd・stdin の透過
# - プラグインルートの解決順（CLAUDE_HARNESS_ROOT / 自己配置 / installed_plugins.json / cache 走査）
# - 不正入力の拒否（絶対パス・'..'・未知フラグ・存在しない target）
#
# 実機の ~/.claude には一切触れず、mktemp -d 配下に偽のプラグインツリーと
# 偽の設定ディレクトリ（CLAUDE_CONFIG_DIR）を作って検証する。
#
# 実行方法: bash scripts/tests/test-claude-harness-run.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
LAUNCHER="${REPO_ROOT}/bin/claude-harness-run"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup() {
  [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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

assert_contains() {
  local description="$1"
  local needle="$2"
  local haystack="$3"

  case "$haystack" in
    *"$needle"*)
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok - ${description}"
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("$description")
      echo "  NG - ${description}"
      echo "       expected to contain: ${needle}"
      echo "       actual:              ${haystack}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 偽プラグインツリーの作成
# ---------------------------------------------------------------------------

# $1: ルートディレクトリ / $2: version
make_fake_plugin() {
  local root="$1" version="$2"
  mkdir -p "${root}/.claude-plugin" "${root}/scripts" "${root}/skills/demo/scripts"
  cat >"${root}/.claude-plugin/plugin.json" <<EOF
{"name": "claude-harness", "version": "${version}"}
EOF
  # 引数・cwd・環境変数・stdin をそのまま報告するだけのスクリプト
  cat >"${root}/scripts/echo-args.sh" <<'EOF'
#!/bin/bash
echo "version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$(dirname "$0")/../.claude-plugin/plugin.json")"
echo "cwd=$(pwd)"
echo "env=${TEST_LAUNCHER_ENV:-UNSET}"
for a in "$@"; do echo "arg=${a}"; done
EOF
  cat >"${root}/scripts/exit-with.sh" <<'EOF'
#!/bin/bash
exit "${1:-0}"
EOF
  cat >"${root}/scripts/read-stdin.sh" <<'EOF'
#!/bin/bash
while IFS= read -r line; do echo "stdin=${line}"; done
EOF
  cat >"${root}/skills/demo/scripts/nested.sh" <<'EOF'
#!/bin/bash
echo "nested-ok $*"
EOF
  cat >"${root}/skills/demo/scripts/hello.mjs" <<'EOF'
console.log("mjs-ok " + process.argv.slice(2).join(","));
EOF
}

PLUGIN_ROOT="${WORK_DIR}/plugin-9.9.9"
make_fake_plugin "$PLUGIN_ROOT" "9.9.9"

# 実機の ~/.claude を絶対に参照しないよう、既定で空の設定ディレクトリを向ける
EMPTY_CONFIG="${WORK_DIR}/empty-config"
mkdir -p "$EMPTY_CONFIG"
export CLAUDE_CONFIG_DIR="$EMPTY_CONFIG"

# =============================================================================
echo "=== test: target 解決（短縮名・相対パス・拡張子ディスパッチ） ==="
# =============================================================================

OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" echo-args a b 2>&1)"
assert_contains "短縮名は scripts/<name>.sh に解決される" "version=9.9.9" "$OUT"
assert_contains "引数がそのまま渡る（1個目）" "arg=a" "$OUT"
assert_contains "引数がそのまま渡る（2個目）" "arg=b" "$OUT"

OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" echo-args.sh x 2>&1)"
assert_contains ".sh 付きの短縮名も同じスクリプトに解決される" "arg=x" "$OUT"

OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" skills/demo/scripts/nested.sh y 2>&1)"
assert_contains "プラグインルート相対パスで skills/ 配下も実行できる" "nested-ok y" "$OUT"

if command -v node >/dev/null 2>&1; then
  OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" skills/demo/scripts/hello.mjs p q 2>&1)"
  assert_contains ".mjs は node で実行される" "mjs-ok p,q" "$OUT"
else
  echo "  skip - .mjs ディスパッチ（node 未インストール）"
fi

# =============================================================================
echo "=== test: 引数・終了コード・cwd・stdin の透過 ==="
# =============================================================================

OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" echo-args "sp ace" 'q"uote' 2>&1)"
assert_contains "空白を含む引数が1引数のまま渡る" "arg=sp ace" "$OUT"
assert_contains "引用符を含む引数がそのまま渡る" 'arg=q"uote' "$OUT"

CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" exit-with 3 >/dev/null 2>&1
assert_eq "対象スクリプトの終了コードを透過する" "3" "$?"

OUT="$(cd "$WORK_DIR" && CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" echo-args 2>&1)"
assert_contains "cwd を変更しない（呼び出し元の cwd のまま実行）" "cwd=$(cd "$WORK_DIR" && pwd)" "$OUT"

OUT="$(printf 'line1\n' | CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" read-stdin 2>&1)"
assert_contains "stdin を透過する" "stdin=line1" "$OUT"

# =============================================================================
echo "=== test: --env ==="
# =============================================================================

OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" --env TEST_LAUNCHER_ENV=hello echo-args 2>&1)"
assert_contains "--env で環境変数を渡せる" "env=hello" "$OUT"

OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" --env TEST_LAUNCHER_ENV="a b" echo-args 2>&1)"
assert_contains "--env の値に空白を含められる" "env=a b" "$OUT"

CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" --env NOT_AN_ASSIGNMENT echo-args >/dev/null 2>&1
assert_eq "--env が KEY=VALUE 形式でない場合は exit 64" "64" "$?"

CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" --env >/dev/null 2>&1
assert_eq "--env の値が無い場合は exit 64" "64" "$?"

# =============================================================================
echo "=== test: 不正入力の拒否 ==="
# =============================================================================

CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" /etc/passwd >/dev/null 2>&1
assert_eq "絶対パスの target は exit 64" "64" "$?"

CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" ../../etc/passwd >/dev/null 2>&1
assert_eq "'..' を含む target は exit 64" "64" "$?"

CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" scripts/../scripts/echo-args.sh >/dev/null 2>&1
assert_eq "パス中間の '..' も exit 64" "64" "$?"

CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" --unknown-flag echo-args >/dev/null 2>&1
assert_eq "未知のフラグは exit 64" "64" "$?"

CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" >/dev/null 2>&1
assert_eq "target 未指定は exit 64" "64" "$?"

ERR="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" no-such-script 2>&1)"
NOINPUT_EXIT=$?
assert_eq "存在しない target は exit 66" "66" "$NOINPUT_EXIT"
assert_contains "存在しない target のエラーは --list を案内する" "--list" "$ERR"

ERR="$(CLAUDE_HARNESS_ROOT="${WORK_DIR}/not-a-plugin" "$LAUNCHER" echo-args 2>&1)"
BAD_ROOT_EXIT=$?
assert_eq "CLAUDE_HARNESS_ROOT が不正なら exit 69（黙って他の解決へフォールバックしない）" "69" "$BAD_ROOT_EXIT"
assert_contains "不正な CLAUDE_HARNESS_ROOT はその旨を報告する" "CLAUDE_HARNESS_ROOT" "$ERR"

# =============================================================================
echo "=== test: プラグインルートの解決順 ==="
# =============================================================================

# (2) 自己配置: プラグインツリー内の bin/ から直接起動した場合はそのツリーを使う
mkdir -p "${PLUGIN_ROOT}/bin"
cp "$LAUNCHER" "${PLUGIN_ROOT}/bin/claude-harness-run"
OUT="$("${PLUGIN_ROOT}/bin/claude-harness-run" --plugin-root 2>&1)"
assert_eq "プラグインツリー内から起動した場合は自ツリーを解決する" "$PLUGIN_ROOT" "$OUT"

# 以降 (3)(4) は「PATH 上へコピーされた（プラグインツリー外の）ランチャー」を模す。
# ツリー内から起動すると (2) の自己配置解決が先に効いてしまうため。
STANDALONE_BIN="${WORK_DIR}/standalone-bin"
mkdir -p "$STANDALONE_BIN"
cp "$LAUNCHER" "${STANDALONE_BIN}/claude-harness-run"
STANDALONE="${STANDALONE_BIN}/claude-harness-run"

OUT="$(CLAUDE_CONFIG_DIR="$EMPTY_CONFIG" "$STANDALONE" --plugin-root 2>&1)"
assert_contains "ツリー外のコピーは自己配置では解決しない（実機の ~/.claude も参照しない）" \
  "could not locate" "$OUT"

# (3) installed_plugins.json: 現行版の正本
JSON_CONFIG="${WORK_DIR}/json-config"
mkdir -p "${JSON_CONFIG}/plugins"
INSTALLED_ROOT="${WORK_DIR}/installed-3.2.0"
make_fake_plugin "$INSTALLED_ROOT" "3.2.0"
cat >"${JSON_CONFIG}/plugins/installed_plugins.json" <<EOF
{
  "version": 2,
  "plugins": {
    "claude-harness@masanami-harness": [
      {"scope": "user", "installPath": "${INSTALLED_ROOT}", "version": "3.2.0"}
    ],
    "other-plugin@somewhere": [
      {"scope": "user", "installPath": "${WORK_DIR}/nonexistent", "version": "1.0.0"}
    ]
  }
}
EOF
OUT="$(CLAUDE_CONFIG_DIR="$JSON_CONFIG" "$STANDALONE" --plugin-root 2>&1)"
assert_eq "installed_plugins.json の installPath を解決する" "$INSTALLED_ROOT" "$OUT"

# installPath が実在しないエントリは無視して cache 走査へ落ちる
BROKEN_CONFIG="${WORK_DIR}/broken-config"
mkdir -p "${BROKEN_CONFIG}/plugins/cache/masanami-harness/claude-harness"
CACHE_OLD="${BROKEN_CONFIG}/plugins/cache/masanami-harness/claude-harness/3.9.0"
CACHE_NEW="${BROKEN_CONFIG}/plugins/cache/masanami-harness/claude-harness/3.10.0"
make_fake_plugin "$CACHE_OLD" "3.9.0"
make_fake_plugin "$CACHE_NEW" "3.10.0"
cat >"${BROKEN_CONFIG}/plugins/installed_plugins.json" <<EOF
{"version": 2, "plugins": {"claude-harness@masanami-harness": [{"installPath": "${WORK_DIR}/gone", "version": "3.2.0"}]}}
EOF
OUT="$(CLAUDE_CONFIG_DIR="$BROKEN_CONFIG" "$STANDALONE" --plugin-root 2>&1)"
assert_eq "installPath が実在しない場合は cache 走査へフォールバックする" "$CACHE_NEW" "$OUT"

# (4) cache 走査: 数値としての最大バージョンを選ぶ（辞書順では 3.9.0 > 3.10.0 になる）
CACHE_CONFIG="${WORK_DIR}/cache-config"
mkdir -p "${CACHE_CONFIG}/plugins/cache/masanami-harness/claude-harness"
CACHE2_OLD="${CACHE_CONFIG}/plugins/cache/masanami-harness/claude-harness/3.9.0"
CACHE2_NEW="${CACHE_CONFIG}/plugins/cache/masanami-harness/claude-harness/3.10.0"
make_fake_plugin "$CACHE2_OLD" "3.9.0"
make_fake_plugin "$CACHE2_NEW" "3.10.0"
OUT="$(CLAUDE_CONFIG_DIR="$CACHE_CONFIG" "$STANDALONE" --plugin-root 2>&1)"
assert_eq "cache 走査は辞書順でなく数値としての最大バージョンを選ぶ" "$CACHE2_NEW" "$OUT"

# 解決不能
ERR="$(CLAUDE_CONFIG_DIR="$EMPTY_CONFIG" "$STANDALONE" --plugin-root 2>&1)"
UNRESOLVED_EXIT=$?
assert_eq "どこからも解決できない場合は exit 69" "69" "$UNRESOLVED_EXIT"
assert_contains "解決失敗時は導入方法を案内する" "CLAUDE_HARNESS_ROOT" "$ERR"

# =============================================================================
echo "=== test: --list / --plugin-root ==="
# =============================================================================

OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" --list 2>&1)"
assert_contains "--list は scripts/ 配下を列挙する" "scripts/echo-args.sh" "$OUT"
assert_contains "--list は skills/*/scripts/ 配下も列挙する" "skills/demo/scripts/nested.sh" "$OUT"

OUT="$(CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" --plugin-root 2>&1)"
assert_eq "--plugin-root は解決したルートを stdout に出す" "$PLUGIN_ROOT" "$OUT"

# =============================================================================
echo "=== test: 実プラグイン（このリポジトリ）に対する疎通 ==="
# =============================================================================

OUT="$(CLAUDE_HARNESS_ROOT="$REPO_ROOT" "$LAUNCHER" quality-check-runner --lint "true" 2>/dev/null)"
assert_eq "実スクリプト（quality-check-runner）をランチャー経由で実行できる" \
  "pass" "$(printf '%s' "$OUT" | jq -r '.result')"

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
