#!/bin/bash
# test-ci-trigger.sh
# scripts/ci-trigger.sh（CI の運用の宣言 .claude-harness/ci.json を PR の宛先 origin/<base> から読む。#363）を、
# 一時 git リポジトリ（bare の origin と clone）の上で実際に動かして検証する。
#   - 宣言が無い・trigger キーが無い -> per-push（警告なし）
#   - per-push / before-merge -> その値（警告なし）
#   - 壊れた JSON・知らない値・オブジェクトでない・文字列でない -> 警告を 1 つ出して per-push
#   - 作業ブランチではなく origin/<base> から読む（作業ツリー・HEAD の宣言は使わない）
#   - origin から base を取れない -> 警告を出して per-push（CI を飛ばす側には倒さない）
#   - 引数の誤りは exit 2
#
# 実行方法: bash scripts/tests/test-ci-trigger.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${TEST_DIR}/../ci-trigger.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-ci-trigger.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
ORIGIN="$WORK/origin.git"
REPO="$WORK/repo"
git init -q --bare "$ORIGIN"
git init -q -b main "$REPO"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" push -q origin main

# set_base_decl <内容 | -（宣言を消す）>: origin/main の宣言を差し替える（作業ブランチとは別に main へ積んで push する）。
set_base_decl() {
  local content="$1"
  git -C "$REPO" checkout -q main
  if [ "$content" = "-" ]; then
    git -C "$REPO" rm -q --ignore-unmatch .claude-harness/ci.json >/dev/null
  else
    mkdir -p "$REPO/.claude-harness"
    printf '%s\n' "$content" >"$REPO/.claude-harness/ci.json"
    git -C "$REPO" add .claude-harness/ci.json
  fi
  git -C "$REPO" commit -q --allow-empty -m "decl"
  git -C "$REPO" push -q origin main
}

# run_trigger <base>: REPO の中で ci-trigger.sh を走らせ、stdout を OUT、stderr を ERR、終了コードを RC に入れる。
run_trigger() {
  RC=0
  OUT="$(cd "$REPO" && bash "$TARGET_SCRIPT" --base "$1" 2>"$WORK/err")" || RC=$?
  ERR="$(cat "$WORK/err")"
}

warning_count() { grep -c '^Warning:' <<<"$ERR" || true; }

echo "=== 宣言が無い・キーが無い -> per-push（警告なし） ==="
{
  set_base_decl "-"
  run_trigger main
  assert_eq "宣言なし: exit 0" "0" "$RC"
  assert_eq "宣言なし: trigger は per-push" "per-push" "$(jq -r '.trigger' <<<"$OUT")"
  assert_eq "宣言なし: declared は false" "false" "$(jq -r '.declared' <<<"$OUT")"
  assert_eq "宣言なし: 警告なし" "0" "$(warning_count)"
  assert_eq "宣言なし: 読んだ版の ref" "origin/main" "$(jq -r '.declaration.ref' <<<"$OUT")"
  assert_eq "宣言なし: 読んだ版の commit は origin/main" "$(git -C "$REPO" rev-parse origin/main)" "$(jq -r '.declaration.commit' <<<"$OUT")"

  set_base_decl '{}'
  run_trigger main
  assert_eq "キーなし ({}): trigger は per-push" "per-push" "$(jq -r '.trigger' <<<"$OUT")"
  assert_eq "キーなし ({}): declared は true" "true" "$(jq -r '.declared' <<<"$OUT")"
  assert_eq "キーなし ({}): 警告なし" "0" "$(warning_count)"
}

echo ""
echo "=== per-push / before-merge -> その値（警告なし） ==="
{
  set_base_decl '{"trigger": "per-push"}'
  run_trigger main
  assert_eq "per-push: trigger" "per-push" "$(jq -r '.trigger' <<<"$OUT")"
  assert_eq "per-push: 警告なし" "0" "$(warning_count)"

  set_base_decl '{"trigger": "before-merge"}'
  run_trigger main
  assert_eq "before-merge: exit 0" "0" "$RC"
  assert_eq "before-merge: trigger" "before-merge" "$(jq -r '.trigger' <<<"$OUT")"
  assert_eq "before-merge: declared" "true" "$(jq -r '.declared' <<<"$OUT")"
  assert_eq "before-merge: warning は空" "" "$(jq -r '.warning' <<<"$OUT")"
  assert_eq "before-merge: 警告なし" "0" "$(warning_count)"
  assert_eq "before-merge: stdout は JSON 1 つ" "1" "$(jq -s 'length' <<<"$OUT")"
}

echo ""
echo "=== 壊れた宣言 -> 警告を 1 つ出して per-push ==="
{
  for bad in '{"trigger": "before-merge"' '{"trigger": "nightly"}' '["before-merge"]' '{"trigger": true}' '{"trigger": "before-merge"} {"trigger": "per-push"}' '{"trigger": "Before-Merge"}'; do
    set_base_decl "$bad"
    run_trigger main
    assert_eq "壊れた宣言 [${bad}]: exit 0" "0" "$RC"
    assert_eq "壊れた宣言 [${bad}]: trigger は per-push" "per-push" "$(jq -r '.trigger' <<<"$OUT")"
    assert_eq "壊れた宣言 [${bad}]: 警告は 1 つ" "1" "$(warning_count)"
    assert_eq "壊れた宣言 [${bad}]: JSON の warning も空でない" "true" "$(jq -r '.warning != ""' <<<"$OUT")"
  done
  # 知らないキーは無視する（trigger だけを読む）。キーが増えた将来の宣言を古い版が読んでも per-push に落ちないように。
  set_base_decl '{"trigger": "before-merge", "note": "x"}'
  run_trigger main
  assert_eq "知らないキーは無視: trigger は before-merge" "before-merge" "$(jq -r '.trigger' <<<"$OUT")"
  assert_eq "知らないキーは無視: 警告なし" "0" "$(warning_count)"
}

echo ""
echo "=== 作業ブランチではなく origin/<base> から読む ==="
{
  set_base_decl "-"
  git -C "$REPO" checkout -q -b feature/x
  mkdir -p "$REPO/.claude-harness"
  printf '%s\n' '{"trigger": "before-merge"}' >"$REPO/.claude-harness/ci.json"
  git -C "$REPO" add .claude-harness/ci.json
  git -C "$REPO" commit -q -m "branch decl"
  run_trigger main
  assert_eq "作業ブランチに before-merge・宛先に宣言なし -> per-push" "per-push" "$(jq -r '.trigger' <<<"$OUT")"

  # 宛先に before-merge・作業ブランチ（HEAD）に per-push -> before-merge。
  git -C "$REPO" checkout -q main
  set_base_decl '{"trigger": "before-merge"}'
  git -C "$REPO" checkout -q feature/x
  printf '%s\n' '{"trigger": "per-push"}' >"$REPO/.claude-harness/ci.json"
  git -C "$REPO" commit -q -am "branch per-push"
  run_trigger main
  assert_eq "宛先に before-merge・作業ブランチに per-push -> before-merge" "before-merge" "$(jq -r '.trigger' <<<"$OUT")"

  # 手元の origin/main が古くても、remote の最新を取り直して読む。
  git -C "$REPO" checkout -q main
  set_base_decl '{"trigger": "per-push"}'
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD~1   # 手元の追跡ブランチを 1 つ前（before-merge）へ戻す
  run_trigger main
  assert_eq "手元の origin/main が古くても、取り直した最新（per-push）を読む" "per-push" "$(jq -r '.trigger' <<<"$OUT")"
}

echo ""
echo "=== base を取れない -> 警告を出して per-push ==="
{
  run_trigger no-such-branch
  assert_eq "存在しない base: exit 0" "0" "$RC"
  assert_eq "存在しない base: trigger は per-push" "per-push" "$(jq -r '.trigger' <<<"$OUT")"
  assert_eq "存在しない base: 警告は 1 つ" "1" "$(warning_count)"
}

echo ""
echo "=== 引数の誤り -> exit 2 ==="
{
  RC=0; (cd "$REPO" && bash "$TARGET_SCRIPT" >/dev/null 2>&1) || RC=$?
  assert_eq "--base なし -> exit 2" "2" "$RC"
  RC=0; (cd "$REPO" && bash "$TARGET_SCRIPT" --base '-x' >/dev/null 2>&1) || RC=$?
  assert_eq "--base が - で始まる -> exit 2" "2" "$RC"
  RC=0; (cd "$REPO" && bash "$TARGET_SCRIPT" --base 'a b' >/dev/null 2>&1) || RC=$?
  assert_eq "--base に空白 -> exit 2" "2" "$RC"
  RC=0; (cd "$REPO" && bash "$TARGET_SCRIPT" --nope >/dev/null 2>&1) || RC=$?
  assert_eq "知らない引数 -> exit 2" "2" "$RC"
}

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
