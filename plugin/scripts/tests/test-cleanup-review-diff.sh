#!/bin/bash
# test-cleanup-review-diff.sh
# scripts/cleanup-review-diff.sh（レビュー用一時ファイルの後始末。Issue #293）と、
# それを呼ぶスキル本文（/self-review・/codex-review）の後始末手順を固定する。
#
# 検証の要点:
#   (a) collect-review-diff.sh が実際に作った diff_file を、ランチャー経由で消せる
#   (b) 消してよい対象を絞っている（名前・置き場所・種類）。条件外が1つでも混じれば何も消さない
#   (c) スキル本文が diff_file / context ファイルを素の `rm -f` で消す指示を持たず、
#       `Bash(claude-harness-run:*)` の1行で allowlist できる形（先頭トークンが
#       `claude-harness-run`、target が裸の `cleanup-review-diff`）で後始末を指示している。
#       headless 委譲で allowlist できるのはランチャーの形だけで、素の `rm -f` は毎回拒否された
#       （docs/script-launcher.md §1 の実測規則: `:` より手前は完全一致・先頭トークンが一致しないと
#       マッチしない）
#
# 実行方法: bash scripts/tests/test-cleanup-review-diff.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_SCRIPT="${PLUGIN_ROOT}/scripts/cleanup-review-diff.sh"
COLLECT_SCRIPT="${PLUGIN_ROOT}/scripts/collect-review-diff.sh"
LAUNCHER="${PLUGIN_ROOT}/bin/claude-harness-run"
SELF_REVIEW_SKILL="${PLUGIN_ROOT}/skills/self-review/SKILL.md"
DEFECT_SWEEP_REF="${PLUGIN_ROOT}/skills/self-review/references/defect-sweep.md"
CODEX_REVIEW_SKILL="${PLUGIN_ROOT}/skills/codex-review/SKILL.md"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("$1")
  echo "  NG - $1"
  [ -n "${2:-}" ] && echo "       $2"
}

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$description"
  else
    fail "$description" "expected: ${expected} / actual: ${actual}"
  fi
}

assert_exists() {
  if [ -e "$2" ] || [ -L "$2" ]; then pass "$1"; else fail "$1" "missing: $2"; fi
}

assert_absent() {
  if [ ! -e "$2" ] && [ ! -L "$2" ]; then pass "$1"; else fail "$1" "still exists: $2"; fi
}

# 一時領域。TMPDIR をテスト専用ディレクトリへ向け、実機の $TMPDIR には何も作らない・消さない。
WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

TEST_TMP="${WORK_DIR}/tmp"
OTHER_DIR="${WORK_DIR}/other"
REPO_DIR="${WORK_DIR}/repo"
mkdir -p "$TEST_TMP" "$OTHER_DIR" "$REPO_DIR"
export TMPDIR="${TEST_TMP}/"
# 実機の ~/.claude を参照しないよう、ランチャーの設定ディレクトリを空にする
mkdir -p "${WORK_DIR}/empty-config"
export CLAUDE_CONFIG_DIR="${WORK_DIR}/empty-config"

run_cleanup() {
  OUT="$(bash "$TARGET_SCRIPT" "$@" 2>/dev/null)"
  RC=$?
}

# =============================================================================
echo "=== (a) collect-review-diff の diff_file をランチャー経由で消せる ==="
# =============================================================================
(
  cd "$REPO_DIR" || exit 1
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test User"
  echo "base" >tracked.txt
  git add tracked.txt
  git commit -q -m "initial commit"
  git checkout -q -b feature/x
  echo "changed" >tracked.txt
)
COLLECT_OUT="$(cd "$REPO_DIR" && bash "$COLLECT_SCRIPT" main 2>/dev/null)"
DIFF_FILE="$(jq -r '.diff_file' <<<"$COLLECT_OUT" 2>/dev/null)"
assert_exists "前提: collect-review-diff が diff_file を TMPDIR 配下に作る" "$DIFF_FILE"

LAUNCH_OUT="$(cd "$REPO_DIR" && CLAUDE_HARNESS_ROOT="$PLUGIN_ROOT" "$LAUNCHER" cleanup-review-diff "$DIFF_FILE" 2>/dev/null)"
LAUNCH_RC=$?
assert_eq "ランチャー経由の cleanup-review-diff が exit 0" "0" "$LAUNCH_RC"
assert_absent "diff_file が削除される" "$DIFF_FILE"
assert_eq "status は ok" "ok" "$(jq -r '.status' <<<"$LAUNCH_OUT")"
assert_eq "removed に diff_file が載る" "$DIFF_FILE" "$(jq -r '.removed[0]' <<<"$LAUNCH_OUT")"

# 既に無いファイルは成功扱い（失敗経路から二重に呼ばれても落ちない）
run_cleanup "$DIFF_FILE"
assert_eq "既に無いファイルは exit 0" "0" "$RC"
assert_eq "既に無いファイルは absent に載る" "$DIFF_FILE" "$(jq -r '.absent[0]' <<<"$OUT")"

# /codex-review の context ファイルと diff_file を1回で消せる
CTX="$(mktemp "${TMPDIR}codex-review-context.XXXXXX")"
DIFF2="$(mktemp "${TMPDIR}collect-review-diff.XXXXXX")"
run_cleanup "$DIFF2" "$CTX"
assert_eq "diff_file と context ファイルの同時指定は exit 0" "0" "$RC"
assert_absent "context ファイルが削除される" "$CTX"
assert_absent "2つ目の diff_file が削除される" "$DIFF2"

# TMPDIR 末尾 `/` の有無・二重スラッシュ（mktemp の返り値の形）を吸収する
DIFF3="$(mktemp "${TEST_TMP}/collect-review-diff.XXXXXX")"
run_cleanup "${TEST_TMP}//$(basename "$DIFF3")"
assert_eq "二重スラッシュを含むパスでも exit 0" "0" "$RC"
assert_absent "二重スラッシュを含むパスでも削除される" "$DIFF3"

# =============================================================================
echo "=== (b) 条件外の引数は何も消さずに exit 64 ==="
# =============================================================================
KEEP="$(mktemp "${TMPDIR}collect-review-diff.XXXXXX")"

expect_refused() {
  local description="$1"
  shift
  run_cleanup "$@"
  assert_eq "${description}: exit 64" "64" "$RC"
  assert_eq "${description}: status は refused" "refused" "$(jq -r '.status' <<<"$OUT" 2>/dev/null)"
}

expect_refused "引数なし"

OTHER_FILE="${OTHER_DIR}/collect-review-diff.AbC123"
: >"$OTHER_FILE"
expect_refused "TMPDIR 外の同名ファイル" "$OTHER_FILE"
assert_exists "TMPDIR 外の同名ファイルは残る" "$OTHER_FILE"

USER_FILE="${TEST_TMP}/notes.txt"
: >"$USER_FILE"
expect_refused "TMPDIR 直下でも名前が違うファイル" "$USER_FILE"
assert_exists "名前が違うファイルは残る" "$USER_FILE"

INDEX_FILE="${TEST_TMP}/collect-review-diff-index.AbC123"
: >"$INDEX_FILE"
expect_refused "collect-review-diff-index.*（collect-review-diff 自身の trap が消す対象）" "$INDEX_FILE"
assert_exists "index 一時ファイルは残る" "$INDEX_FILE"

expect_refused "相対パス" "collect-review-diff.AbC123"

LINK="${TEST_TMP}/collect-review-diff.Link12"
ln -s "$USER_FILE" "$LINK"
expect_refused "シンボリックリンク" "$LINK"
assert_exists "リンク先は残る" "$USER_FILE"

DIR_TARGET="${TEST_TMP}/collect-review-diff.Dir123"
mkdir -p "$DIR_TARGET"
expect_refused "ディレクトリ" "$DIR_TARGET"
assert_exists "ディレクトリは残る" "$DIR_TARGET"

expect_refused "TMPDIR 配下でもサブディレクトリの中" "${DIR_TARGET}/collect-review-diff.AbC123"

expect_refused "正当な引数と条件外の引数の混在" "$KEEP" "$USER_FILE"
assert_exists "混在時は正当な引数のファイルも消さない（部分実行しない）" "$KEEP"

# =============================================================================
echo "=== (c) スキル本文の後始末が allowlist できる形になっている ==="
# =============================================================================
ALLOW_PREFIX="claude-harness-run cleanup-review-diff "

# diff_file / context ファイルを素の rm で消す指示が残っていないこと
for f in "$SELF_REVIEW_SKILL" "$DEFECT_SWEEP_REF" "$CODEX_REVIEW_SKILL"; do
  rel="${f#"${PLUGIN_ROOT}"/}"
  # 「素の rm -f を使わない」という禁止文の中の言及は許す（行内に「使わない」を伴うもの）
  hits="$(grep -nE '`rm( -[a-zA-Z]+)*[ `]|rm -f "?<?(diff_file|context)' "$f" | grep -v '使わない' || true)"
  if [ -z "$hits" ]; then
    pass "${rel}: diff_file / context を素の rm で消す指示が無い"
  else
    fail "${rel}: diff_file / context を素の rm で消す指示が残っている" "$hits"
  fi

  # 後始末を指示するランチャー形が在り、先頭トークンが allowlist のルール（Bash(claude-harness-run:*)）に一致すること
  forms="$(grep -oE '`[^`]*cleanup-review-diff[^`]*`' "$f" | tr -d '`' | grep -vE '^(bash |scripts/)|^cleanup-review-diff$' || true)"
  if [ -z "$forms" ]; then
    fail "${rel}: cleanup-review-diff の実行形が見つからない"
    continue
  fi
  bad=""
  while IFS= read -r form; do
    case "$form" in
      "$ALLOW_PREFIX"\"*) ;;
      *) bad="${bad}${form}; " ;;
    esac
  done <<<"$forms"
  if [ -z "$bad" ]; then
    pass "${rel}: cleanup-review-diff の実行形はすべて '${ALLOW_PREFIX}\"<path>\"…' の形"
  else
    fail "${rel}: allowlist に一致しない cleanup-review-diff の実行形がある" "$bad"
  fi
done

# /codex-review の context ファイルが cleanup-review-diff の受け付ける名前で作られること
if grep -qF 'mktemp "${TMPDIR:-/tmp}/codex-review-context.XXXXXX"' "$CODEX_REVIEW_SKILL"; then
  pass "codex-review: context ファイルを codex-review-context.XXXXXX の名前で TMPDIR 直下に作る"
else
  fail "codex-review: context ファイルの作成形が cleanup-review-diff の受け付ける名前になっていない"
fi
# その作成形で作った名前を実際に cleanup-review-diff が受け付けること（名前規則のずれを検出する）
CTX2="$(mktemp "${TMPDIR:-/tmp}/codex-review-context.XXXXXX")"
run_cleanup "$CTX2"
assert_eq "スキル本文の作成形で作った context ファイルを消せる" "0" "$RC"
assert_absent "スキル本文の作成形で作った context ファイルが残らない" "$CTX2"

echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
