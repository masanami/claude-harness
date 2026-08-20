#!/bin/bash
# test-read-plugin-doc.sh
# scripts/read-plugin-doc.sh の契約を検証する。
# - 実ファイルをバイト同一で stdout へ配送する／レシートは stderr へ出す
# - cwd 非依存（プラグイン外のどこから呼んでも同じ結果になる）
# - 失敗が必ず非0 終了で伝わる（沈黙しない）。失敗時 stdout は空
# - 配送対象サブツリーの fail-closed な allowlist（判定関数の自己検査を含む）
# - 絶対パス・'..'・シンボリックリンク・ルート外へ抜けるパスの拒否
# - プラグインルート解決不能（インストール破損）の検出
#
# 実機の ~/.claude には一切触れず、実ファイル検証はこのリポジトリ自身を、
# 異常系は mktemp -d 配下に作った偽のプラグインツリーを対象に行う。
#
# 実行方法: bash scripts/tests/test-read-plugin-doc.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
TARGET_SCRIPT="${REPO_ROOT}/scripts/read-plugin-doc.sh"

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

assert_contains() {
  local description="$1" needle="$2" haystack="$3"
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

OUT_FILE="${WORK_DIR}/stdout.txt"
ERR_FILE="${WORK_DIR}/stderr.txt"
LAST_STATUS=0

# 対象スクリプトを実行し、stdout/stderr をファイルへ、終了コードを LAST_STATUS へ。
# 第1引数に実行時の cwd を取る（cwd 非依存の検証に使う）。
run_rpd() {
  local cwd="$1"
  shift
  local script="${RPD_SCRIPT_UNDER_TEST:-$TARGET_SCRIPT}"
  (cd "$cwd" && bash "$script" "$@") >"$OUT_FILE" 2>"$ERR_FILE"
  LAST_STATUS=$?
}

# ---------------------------------------------------------------------------
# 1. 正常系: 実ファイルのバイト同一配送
# ---------------------------------------------------------------------------
echo "=== (1) 実ファイルのバイト同一配送 ==="

SAMPLE_REL="skills/pr-merge/references/conflict-resolution.md"
run_rpd "$REPO_ROOT" "$SAMPLE_REL"
assert_eq "配送に成功する (exit 0)" "0" "$LAST_STATUS"

if cmp -s "$OUT_FILE" "${REPO_ROOT}/${SAMPLE_REL}"; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - stdout が対象ファイルとバイト同一である"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("stdout が対象ファイルとバイト同一である")
  echo "  NG - stdout が対象ファイルとバイト同一である"
fi

assert_contains "レシートが stderr に出る" "delivered ${SAMPLE_REL}" "$(cat "$ERR_FILE")"

# レシートが stdout を汚していないこと（汚すと本文の一部として読まれる）
if grep -Fq "read-plugin-doc: delivered" "$OUT_FILE"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("レシートが stdout を汚していない")
  echo "  NG - レシートが stdout を汚していない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - レシートが stdout を汚していない"
fi

# ---------------------------------------------------------------------------
# 2. cwd 非依存
# ---------------------------------------------------------------------------
echo ""
echo "=== (2) cwd 非依存 ==="

# 配送経路の目的は「導入先プロジェクトの cwd から、プラグイン配下の文書を読む」ことなので、
# cwd がプラグイン外でも同じ結果にならなければ意味がない。
run_rpd "$WORK_DIR" "$SAMPLE_REL"
assert_eq "プラグイン外の cwd から呼んでも成功する" "0" "$LAST_STATUS"
if cmp -s "$OUT_FILE" "${REPO_ROOT}/${SAMPLE_REL}"; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - プラグイン外の cwd でも本文が同一である"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("プラグイン外の cwd でも本文が同一である")
  echo "  NG - プラグイン外の cwd でも本文が同一である"
fi

# 導入先プロジェクトに同名パスが存在しても、そちらを読まないこと（裸の相対パス解決との違い）
mkdir -p "${WORK_DIR}/decoy/skills/pr-merge/references"
printf 'DECOY - 導入先プロジェクト側の同名ファイル\n' \
  >"${WORK_DIR}/decoy/skills/pr-merge/references/conflict-resolution.md"
run_rpd "${WORK_DIR}/decoy" "$SAMPLE_REL"
assert_eq "cwd 側の同名ファイルがあっても成功する" "0" "$LAST_STATUS"
if grep -Fq "DECOY" "$OUT_FILE"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("cwd 側の同名ファイルを読まない")
  echo "  NG - cwd 側の同名ファイルを読まない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - cwd 側の同名ファイルを読まない"
fi

# ---------------------------------------------------------------------------
# 3. 引数不正の拒否（exit 64）
# ---------------------------------------------------------------------------
echo ""
echo "=== (3) 引数不正の拒否 ==="

run_rpd "$REPO_ROOT"
assert_eq "引数なしは exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "$SAMPLE_REL" extra
assert_eq "引数が2個は exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" ""
assert_eq "空文字は exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "/etc/passwd"
assert_eq "絶対パスは exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "skills/../../etc/passwd"
assert_eq "'..' を含むパスは exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "skills/pr-merge/references/../../../README.md"
assert_eq "途中に '..' を含むパスも exit 64" "64" "$LAST_STATUS"

# 失敗時に stdout を空に保つ（部分的な本文が「読めた」ように見えないため）
if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("引数不正時の stdout は空である")
  echo "  NG - 引数不正時の stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 引数不正時の stdout は空である"
fi

# 失敗は必ず「停止して報告せよ」という行動指示を伴う（沈黙で続行させないため）
assert_contains "失敗時の stderr に停止指示が含まれる" "停止して" "$(cat "$ERR_FILE")"

# ---------------------------------------------------------------------------
# 4. 配送対象外の拒否（exit 77）
# ---------------------------------------------------------------------------
echo ""
echo "=== (4) 配送対象外の拒否 ==="

run_rpd "$REPO_ROOT" "docs/plugin-path-conventions.md"
assert_eq "docs/ 配下は配送対象外 (exit 77)" "77" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "bin/claude-harness-run"
assert_eq "bin/ 配下は配送対象外 (exit 77)" "77" "$LAST_STATUS"

run_rpd "$REPO_ROOT" ".claude-plugin/plugin.json"
assert_eq ".claude-plugin/ 配下は配送対象外 (exit 77)" "77" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "scripts/read-plugin-doc.sh"
assert_eq "scripts/ 直下のスクリプトは配送対象外 (exit 77)" "77" "$LAST_STATUS"

if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("配送対象外の stdout は空である")
  echo "  NG - 配送対象外の stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 配送対象外の stdout は空である"
fi

# ---------------------------------------------------------------------------
# 5. 対象なしの拒否（exit 66）
# ---------------------------------------------------------------------------
echo ""
echo "=== (5) 対象なしの拒否 ==="

run_rpd "$REPO_ROOT" "skills/pr-merge/references/does-not-exist.md"
assert_eq "存在しない参照ファイルは exit 66" "66" "$LAST_STATUS"
assert_contains "存在しない場合も停止指示を伴う" "停止して" "$(cat "$ERR_FILE")"

if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("対象なしの stdout は空である")
  echo "  NG - 対象なしの stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 対象なしの stdout は空である"
fi

# ---------------------------------------------------------------------------
# 6. --help
# ---------------------------------------------------------------------------
echo ""
echo "=== (6) --help ==="

run_rpd "$REPO_ROOT" --help
assert_eq "--help は exit 0" "0" "$LAST_STATUS"
assert_contains "--help は配送対象を案内する" "skills/<skill>/references/" "$(cat "$ERR_FILE")"

# ---------------------------------------------------------------------------
# 7. 偽プラグインツリーでの境界検証
# ---------------------------------------------------------------------------
echo ""
echo "=== (7) 偽プラグインツリーでの境界検証 ==="

FAKE_ROOT="${WORK_DIR}/fake-plugin"
OUTSIDE_DIR="${WORK_DIR}/outside"
mkdir -p "${FAKE_ROOT}/.claude-plugin" "${FAKE_ROOT}/scripts" \
  "${FAKE_ROOT}/skills/demo/references" "${OUTSIDE_DIR}"
printf '{"name":"claude-harness"}\n' >"${FAKE_ROOT}/.claude-plugin/plugin.json"
cp "$TARGET_SCRIPT" "${FAKE_ROOT}/scripts/read-plugin-doc.sh"
printf 'plain content\n' >"${FAKE_ROOT}/skills/demo/references/plain.md"
printf 'SECRET OUTSIDE\n' >"${OUTSIDE_DIR}/secret.md"
ln -s "${OUTSIDE_DIR}/secret.md" "${FAKE_ROOT}/skills/demo/references/link.md"
ln -s "$OUTSIDE_DIR" "${FAKE_ROOT}/skills/demo/templates"

RPD_SCRIPT_UNDER_TEST="${FAKE_ROOT}/scripts/read-plugin-doc.sh"

run_rpd "$WORK_DIR" "skills/demo/references/plain.md"
assert_eq "偽ツリーでも実体ファイルは配送できる" "0" "$LAST_STATUS"

# 配送対象パターンに合致していても、通常ファイルでなければ「読めた」にしない
mkdir -p "${FAKE_ROOT}/skills/demo/references/a-directory.md"
run_rpd "$WORK_DIR" "skills/demo/references/a-directory.md"
assert_eq "配送対象パターンに合致するディレクトリは exit 66" "66" "$LAST_STATUS"

run_rpd "$WORK_DIR" "skills/demo/references/link.md"
assert_eq "シンボリックリンクは配送しない (exit 77)" "77" "$LAST_STATUS"
if grep -Fq "SECRET OUTSIDE" "$OUT_FILE"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("リンク先の中身を出力しない")
  echo "  NG - リンク先の中身を出力しない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - リンク先の中身を出力しない"
fi

# 親ディレクトリ側がリンクでプラグイン外へ抜ける形（パス文字列上はサブツリー内に見える）
run_rpd "$WORK_DIR" "skills/demo/templates/secret.md"
assert_eq "親ディレクトリのリンク経由でルート外へ抜ける形を拒否する (exit 77)" "77" "$LAST_STATUS"
if grep -Fq "SECRET OUTSIDE" "$OUT_FILE"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("ディレクトリリンク経由でも中身を出力しない")
  echo "  NG - ディレクトリリンク経由でも中身を出力しない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - ディレクトリリンク経由でも中身を出力しない"
fi

# プラグインルートを解決できない配置（インストール破損）
BROKEN_ROOT="${WORK_DIR}/broken"
mkdir -p "${BROKEN_ROOT}/scripts"
cp "$TARGET_SCRIPT" "${BROKEN_ROOT}/scripts/read-plugin-doc.sh"
RPD_SCRIPT_UNDER_TEST="${BROKEN_ROOT}/scripts/read-plugin-doc.sh"
run_rpd "$WORK_DIR" "skills/demo/references/plain.md"
assert_eq "プラグインルート不在は exit 69" "69" "$LAST_STATUS"

unset RPD_SCRIPT_UNDER_TEST

# ---------------------------------------------------------------------------
# 8. 配送対象 allowlist の自己検査
# ---------------------------------------------------------------------------
echo ""
echo "=== (8) 配送対象 allowlist の自己検査 ==="

# 判定を一箇所（rpd_is_deliverable）に閉じ込めてあるので、その関数を直接叩いて
# 「許すべき形」「拒むべき形」の両方を確認する。パターンが壊れたときに、
# 通るはずのものが通らない／通ってはいけないものが通る、のどちらも検出できるようにする。
# shellcheck source=../read-plugin-doc.sh
source "$TARGET_SCRIPT"

assert_deliverable() {
  local description="$1" expected="$2" path="$3"
  local actual="no"
  rpd_is_deliverable "$path" && actual="yes"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("配送対象判定の自己検査: ${description}")
    echo "  NG - ${description}（expected=${expected} actual=${actual} path=${path}）"
  fi
}

assert_deliverable "許可: skills/*/references/*.md" yes "skills/guarantee-audit/references/bootstrap-mode.md"
assert_deliverable "許可: skills/*/templates/*" yes "skills/define-feature/templates/feature-spec.md"
assert_deliverable "許可: 拡張子なしの templates 配下も許可" yes "skills/init-project/templates/CLAUDE.md.template"
assert_deliverable "許可: scripts/specs/*.md" yes "scripts/specs/list-test-files.md"
assert_deliverable "許可: scripts/README.md" yes "scripts/README.md"
assert_deliverable "拒否: docs/ 配下" no "docs/plugin-path-conventions.md"
assert_deliverable "拒否: bin/ 配下" no "bin/claude-harness-run"
assert_deliverable "拒否: scripts/ 直下のスクリプト" no "scripts/read-plugin-doc.sh"
assert_deliverable "拒否: scripts/config/ 配下" no "scripts/config/sensitive-paths.txt"
assert_deliverable "拒否: SKILL.md 本体（注入済みで配送不要）" no "skills/pr-merge/SKILL.md"
assert_deliverable "拒否: references 配下でも .md 以外" no "skills/demo/references/secret.env"
assert_deliverable "拒否: ルート直下の任意ファイル" no "README.md"
assert_deliverable "拒否: .claude-plugin 配下" no ".claude-plugin/plugin.json"

# ---------------------------------------------------------------------------
echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "失敗した検証:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi
exit 0
