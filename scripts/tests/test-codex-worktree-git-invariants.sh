#!/bin/bash
# test-codex-worktree-git-invariants.sh
# docs/codex-write-approval-boundary.md §6.1 が主張する「runner が worktree に対して
# git を実行するときの安全条件」を、実際の git で固定する。
#
# 主張は散文では守られない（安全性の断定は、その形でなければ壊れる理由ごとテストにする）。
# ここで固定するのは runner の実装ではなく **git 自身の挙動** であり、git のバージョンが
# 上がって前提が変わったらこのテストが落ちる。落ちたら設計文書の §6.1 / §8.3 を見直すこと。
#
# 固定する不変条件:
#   (I1) worktree の `.git` はファイルであり、書き換えると素の `git -C <worktree>` は
#        攻撃者の gitdir を参照する（迂回が成立する。負例）
#   (I2) GIT_DIR / GIT_WORK_TREE を明示すると `.git` ファイルは参照されない（M1）
#   (I3) M1 だけでは足りない。正規の config チェーン（global/system）にドライバが在ると、
#        worktree 内の `.gitattributes` がそれを選択して runner の権限で実行される（負例）
#   (I4) M1 + GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_SYSTEM=/dev/null なら、
#        hooksPath / fsmonitor / filter / external diff のいずれも実行されない
#   (I5) 残余リスク: 共有 `.git/config`（= runner 側）にドライバが在れば、
#        worktree の `.gitattributes` はそれを別のパスへ再適用できる
#
# 実行方法: bash scripts/tests/test-codex-worktree-git-invariants.sh

set -u

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

# macOS の mktemp は /var/folders 配下（/private 実体）を返す。git は内部でパスを
# 実体解決して記録するため、素朴に組み立てた文字列と食い違う。物理パスへ正規化する
# （scripts/worktree-setup.sh の canonicalize_path と同じ考え方）。
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
cleanup_all() { rm -rf "$TMP_ROOT"; }
trap cleanup_all EXIT

MAIN="${TMP_ROOT}/main"
WT="${TMP_ROOT}/wt1"
MARKS="${TMP_ROOT}/marks"

git init -q -b main "$MAIN"
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test User"
git -C "$MAIN" commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$WT" -b probe
GITDIR="${MAIN}/.git/worktrees/wt1"

mkdir -p "$MARKS"

# 実行されたら痕跡を残すだけのペイロード。破壊的なことは何もしない。
# 第2引数で「git がこのプログラムに何を期待するか」を分ける。取り違えると
# stdin 待ちでテストが停止する（clean は stdin を読むが textconv は引数のファイルを読む）。
#   stdin   : clean フィルタ（stdin → stdout のパススルー）
#   argfile : textconv / external diff（引数のファイルを stdout へ）
#   none    : fsmonitor / hook（stdin も stdout も使わない）
make_payload() {
  local name="$1" kind="$2" path="${TMP_ROOT}/payload-${1}.sh"
  {
    printf '#!/bin/sh\n'
    printf 'touch "%s/%s"\n' "$MARKS" "$name"
    case "$kind" in
      stdin) printf 'cat\n' ;;
      argfile) printf 'cat "$1" 2>/dev/null\nexit 0\n' ;;
      none) printf 'exit 0\n' ;;
    esac
  } >"$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

marks() {
  local found
  found="$(ls "$MARKS" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')"
  printf '%s\n' "${found:-none}"
}
clear_marks() { rm -f "${MARKS:?}"/* 2>/dev/null || true; }

# 個別の痕跡の有無を見る。集合の完全一致で判定しない——git は fsmonitor の結果を
# キャッシュするため、同じ操作でも fsmonitor が呼ばれたり呼ばれなかったりする
# （完全一致で書くと不安定なテストになる。実測で 4 回中 1 回落ちた）。
has_mark() { [ -e "${MARKS}/$1" ] && echo yes || echo no; }

echo "=== (I1) worktree の .git はファイルであり、書き換えると素の git が攻撃者の gitdir を見る ==="

assert_eq ".git は通常ファイル（ディレクトリではない）" \
  "file" \
  "$([ -f "${WT}/.git" ] && echo file || echo other)"

# Codex は worktree 内に書けるので、この書き換えは実際に可能な操作である。
cp "${WT}/.git" "${TMP_ROOT}/dot-git.orig"
EVIL_REPO="${WT}/.evilgit"
git init -q "$EVIL_REPO"
git -C "$EVIL_REPO" config core.worktree "$WT"
printf 'gitdir: %s/.git\n' "$EVIL_REPO" >"${WT}/.git"

assert_eq "素の git -C <worktree> は攻撃者の gitdir を参照する" \
  "${EVIL_REPO}/.git" \
  "$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)"

echo ""
echo "=== (I2) M1: GIT_DIR / GIT_WORK_TREE を明示すると .git ファイルは参照されない ==="

assert_eq "M1 は正規の gitdir を使う（.git ファイルの書き換えを無視する）" \
  "$GITDIR" \
  "$(GIT_DIR="$GITDIR" GIT_WORK_TREE="$WT" git rev-parse --absolute-git-dir 2>/dev/null)"

# 以降のケースでは .git ファイルの書き換えを元に戻す（バックアップからの上書き）。
cp "${TMP_ROOT}/dot-git.orig" "${WT}/.git"
rm -rf "$EVIL_REPO"

echo ""
echo "=== (I3) M1 だけでは足りない: 正規 config のドライバを .gitattributes が選択できる ==="

FAKE_GLOBAL="${TMP_ROOT}/fake-global.gitconfig"
: >"$FAKE_GLOBAL"
CLEAN_PAYLOAD="$(make_payload clean stdin)"
TEXTCONV_PAYLOAD="$(make_payload textconv argfile)"
FSMONITOR_PAYLOAD="$(make_payload fsmonitor none)"
HOOKS_DIR="${TMP_ROOT}/hooks"
mkdir -p "$HOOKS_DIR"
{
  printf '#!/bin/sh\n'
  printf 'touch "%s/hook"\n' "$MARKS"
} >"${HOOKS_DIR}/pre-commit"
chmod +x "${HOOKS_DIR}/pre-commit"

# operator の ~/.gitconfig 側に「既にドライバが定義されている」状況を模す。
git config --file "$FAKE_GLOBAL" filter.probe.clean "$CLEAN_PAYLOAD"
git config --file "$FAKE_GLOBAL" diff.probe.textconv "$TEXTCONV_PAYLOAD"
git config --file "$FAKE_GLOBAL" core.hooksPath "$HOOKS_DIR"
git config --file "$FAKE_GLOBAL" core.fsmonitor "$FSMONITOR_PAYLOAD"
git config --file "$FAKE_GLOBAL" user.name "Test User"
git config --file "$FAKE_GLOBAL" user.email "test@example.com"

# 攻撃者（= worktree 内に書ける主体）が置けるのは .gitattributes だけ。
printf '* filter=probe diff=probe\n' >"${WT}/.gitattributes"
printf 'hello\n' >"${WT}/f.txt"

git_m1_only() {
  env GIT_DIR="$GITDIR" GIT_WORK_TREE="$WT" \
    GIT_CONFIG_GLOBAL="$FAKE_GLOBAL" GIT_CONFIG_SYSTEM=/dev/null \
    git "$@" </dev/null
}

assert_eq "worktree の .gitattributes が filter ドライバを選択できている" \
  "probe" \
  "$(git_m1_only check-attr filter -- f.txt 2>/dev/null | sed 's/.*: //')"

clear_marks
git_m1_only add -A >/dev/null 2>&1
assert_eq "M1 のみ: git add で clean フィルタが runner の権限で実行される" \
  "yes" "$(has_mark clean)"

clear_marks
git_m1_only commit -q -m probe >/dev/null 2>&1
assert_eq "M1 のみ: git commit で hooksPath の hook が実行される" \
  "yes" "$(has_mark hook)"

printf 'world\n' >>"${WT}/f.txt"
clear_marks
git_m1_only --no-pager diff >/dev/null 2>&1
assert_eq "M1 のみ: git diff で textconv が実行される" \
  "yes" "$(has_mark textconv)"

echo ""
echo "=== (I4) M1 + global/system config の無効化で、いずれも実行されない ==="

git_hardened() {
  env GIT_DIR="$GITDIR" GIT_WORK_TREE="$WT" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -c user.name="Test User" -c user.email="test@example.com" "$@" </dev/null
}

assert_eq "無効化後もドライバ選択自体は残る（.gitattributes は消していない）" \
  "probe" \
  "$(git_hardened check-attr filter -- f.txt 2>/dev/null | sed 's/.*: //')"

assert_eq "無効化後はドライバの定義が存在しない" \
  "" \
  "$(git_hardened config --get filter.probe.clean 2>/dev/null)"

clear_marks
git_hardened add -A >/dev/null 2>&1
assert_eq "hardened: git add で何も実行されない" "none" "$(marks)"

clear_marks
git_hardened commit -q -m hardened >/dev/null 2>&1
assert_eq "hardened: git commit で何も実行されない" "none" "$(marks)"

printf 'again\n' >>"${WT}/f.txt"
clear_marks
git_hardened --no-pager diff >/dev/null 2>&1
assert_eq "hardened: git diff で何も実行されない" "none" "$(marks)"

clear_marks
git_hardened --no-pager diff --ext-diff >/dev/null 2>&1
assert_eq "hardened: git diff --ext-diff で何も実行されない" "none" "$(marks)"

clear_marks
git_hardened status --porcelain >/dev/null 2>&1
assert_eq "hardened: git status で fsmonitor が実行されない" "none" "$(marks)"

echo ""
echo "=== (I5) 残余リスク: 共有 .git/config にドライバが在れば .gitattributes で再適用できる ==="

# ここは「守られていない」ことを固定するテストである。共有 .git/config は Codex から
# 書けない（設計文書 実測2）が、runner／利用側プロジェクトがそこにドライバを定義していれば、
# worktree の .gitattributes がそれを別のパスへ向けられる。
RESIDUAL_PAYLOAD="$(make_payload residual stdin)"
git -C "$MAIN" config filter.residual.clean "$RESIDUAL_PAYLOAD"
printf '* filter=residual\n' >"${WT}/.gitattributes"
printf 'payload-target\n' >"${WT}/g.txt"

clear_marks
git_hardened add -A >/dev/null 2>&1
assert_eq "共有 .git/config のドライバは hardened でも .gitattributes から再適用できる" \
  "yes" "$(has_mark residual)"

echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
