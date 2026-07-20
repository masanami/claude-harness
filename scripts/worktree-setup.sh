#!/bin/bash
# worktree-setup.sh
# skills/para-impl/SKILL.md Phase 3（複数Issue時、リードが Issue ごとに worktree・
# 作業ブランチを作成する）を切り出した決定的スクリプト（Issue #45）。
# base の存在確認（git ls-remote）→ fetch → git worktree add までを担う。
#
# 使い方:
#   scripts/worktree-setup.sh <issue番号> <branch名> <base> [worktree_root]
#     worktree_root省略時は「リポジトリの1つ上の階層の <リポジトリ名>-worktrees」を使う
#     （例: /path/to/claude-harness -> /path/to/claude-harness-worktrees）。
#
#   ブランチ名は `{type}/issue-{issue番号}-{説明}` 形式でなければならない
#   （type は feature/fix/refactor/docs/hotfix のいずれか。説明はケバブケース）。
#   ブランチ種別・スラグ自体の意味的な決定（Issueの内容から何と命名するか）は
#   呼び出し側（LLM）の責務。本スクリプトは命名規約のパターン検証のみを行う。
#
# 出力（stdout にJSON1個）:
#   {
#     "issue": 45,
#     "branch": "feature/issue-45-xxx",
#     "base": "main",
#     "worktree_path": "/path/to/xxx-worktrees/issue-45",
#     "created": true,
#     "reused": false,
#     "branch_existed": false
#   }
#
# 冪等挙動（設計判断。Issue #45 本文の指示に基づく）:
#   - worktree_path が既に **同一ブランチの登録済み worktree** であれば、新規作成せず
#     そのまま再利用する（created: false, reused: true）。resume 時に前回作成済みの
#     worktree をそのまま使い続けられるようにするため
#   - worktree_path が既存だが **別ブランチの登録済み worktree**、または
#     **git worktree に未登録の任意のディレクトリ**（stale等）である場合は、
#     衝突を自動解決せず致命的エラーとして exit 非0 にする（無条件の上書き・削除は
#     行わない。呼び出し側の判断に委ねる）
#   - 指定ブランチが既にローカル/リモートに存在する場合（前回の途中失敗で
#     ブランチだけ作成済み等）は `-b` で新規作成せず、既存ブランチをそのまま
#     checkout する worktree を作る（branch_existed: true として可視化する）
#
# gh は呼ばない（gh非依存。base の存在確認は git ls-remote のみで行う）。
#
# テスト容易性のため、git を呼ぶ処理（verify_base_remote/fetch_base/
# local_branch_exists/remote_branch_exists/find_registered_worktree_branch/
# create_worktree_new_branch/create_worktree_existing_branch）と、
# 外部コマンドを呼ばない純粋関数（validate_branch_name/compute_worktree_path/
# default_worktree_root）を分離している。git操作を伴う分岐は一時gitリポジトリ
# （mktemp -d、bare remote付き）を作成して検証する（scripts/tests/test-worktree-setup.sh）。

set -u

WORKTREE_SETUP_BRANCH_TYPES="feature fix refactor docs hotfix"

check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 純粋関数（git/ghを呼ばない）
# ---------------------------------------------------------------------------

# ブランチ名が `{type}/issue-{issue番号}-{ケバブケース説明}` 形式かを検証する。
# 結果: "valid" または "invalid"
validate_branch_name() {
  local issue="$1" branch="$2"
  local type_pattern
  type_pattern="$(echo "$WORKTREE_SETUP_BRANCH_TYPES" | tr ' ' '|')"
  if [[ "$branch" =~ ^(${type_pattern})/issue-${issue}-[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "valid"
  else
    echo "invalid"
  fi
}

compute_worktree_path() {
  local worktree_root="$1" issue="$2"
  echo "${worktree_root%/}/issue-${issue}"
}

default_worktree_root() {
  local repo_root="$1"
  local parent base
  parent="$(dirname "$repo_root")"
  base="$(basename "$repo_root")"
  echo "${parent}/${base}-worktrees"
}

# パスの実体パス（symlink解決済み）を求める。TMPDIRがsymlink経由（macOSの
# /tmp -> /private/tmp・/var -> /private/var 等）だと、`git worktree list` が
# 返すパス（gitは内部的に実体パスへ解決して記録する）と、素朴に組み立てた
# worktree_path文字列が食い違い、冪等判定（find_registered_worktree_branchでの
# 文字列比較）が偽陰性になる。存在しないパス（これから作成するworktree_path）にも
# 対応するため、実在する最も長い祖先ディレクトリまで遡って解決し、残りの
# パス要素をそのまま付け直す（scripts/mutation-run.sh の canonicalize_path と
# 同じ考え方。scripts/README.md 参照）。
canonicalize_path() {
  local path="$1"
  if [ -e "$path" ]; then
    (cd "$path" && pwd -P)
    return
  fi
  local existing="$path"
  local suffix=""
  while [ ! -d "$existing" ] && [ "$existing" != "/" ] && [ "$existing" != "." ]; do
    suffix="/$(basename "$existing")${suffix}"
    existing="$(dirname "$existing")"
  done
  if [ -d "$existing" ]; then
    echo "$(cd "$existing" && pwd -P)${suffix}"
  else
    echo "$path"
  fi
}

# ---------------------------------------------------------------------------
# git 呼び出し（外部作用あり。gh は呼ばない）
# ---------------------------------------------------------------------------

verify_base_remote() {
  local base="$1"
  git ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1
}

fetch_base() {
  local base="$1"
  git fetch origin "$base" >/dev/null 2>&1
}

fetch_branch() {
  local branch="$1"
  git fetch origin "$branch" >/dev/null 2>&1
}

local_branch_exists() {
  local branch="$1"
  git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null 2>&1
}

remote_branch_exists() {
  local branch="$1"
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

# 指定パスが git worktree として登録済みなら、その worktree の branch名を返す
# （refs/heads/ prefixは剥がす）。未登録なら空文字を返す。
# worktree パスは空白を含みうるため、$2（空白区切りの第2フィールド）ではなく
# 行全体から "worktree " プレフィックスを除去した残り全体を使う（self-review 指摘の
# 回帰修正。旧実装は $2 のみを見ており、空白を含むパスで先頭トークンしか取得できず
# 冪等再利用の判定が偽陰性になっていた）。
find_registered_worktree_branch() {
  local target="$1"
  git worktree list --porcelain | awk -v target="$target" '
    /^worktree / { wt=$0; sub(/^worktree /, "", wt) }
    /^branch / {
      br=$0
      sub(/^branch /, "", br)
      sub(/^refs\/heads\//, "", br)
      if (wt == target) { print br; exit }
    }
  '
}

create_worktree_new_branch() {
  local path="$1" branch="$2" base="$3"
  git worktree add "$path" -b "$branch" "origin/${base}" >/dev/null 2>&1
}

create_worktree_existing_local_branch() {
  local path="$1" branch="$2"
  git worktree add "$path" "$branch" >/dev/null 2>&1
}

create_worktree_existing_remote_branch() {
  local path="$1" branch="$2"
  git worktree add "$path" -b "$branch" "origin/${branch}" >/dev/null 2>&1
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <issue番号> <branch名> <base> [worktree_root]" >&2
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local issue="${1:-}" branch="${2:-}" base="${3:-}" worktree_root="${4:-}"

  if [ -z "$issue" ] || [ -z "$branch" ] || [ -z "$base" ]; then
    print_usage
    exit 1
  fi
  if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
    echo "Error: issue number must be numeric, got '${issue}'" >&2
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  if [ "$(validate_branch_name "$issue" "$branch")" != "valid" ]; then
    echo "Error: branch name '${branch}' does not match required pattern '{type}/issue-${issue}-{description}' (type in: ${WORKTREE_SETUP_BRANCH_TYPES})" >&2
    exit 1
  fi

  local repo_root
  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "Error: not inside a git repository" >&2
    exit 1
  fi

  if [ -z "$worktree_root" ]; then
    worktree_root="$(default_worktree_root "$repo_root")"
  fi
  local worktree_path
  worktree_path="$(compute_worktree_path "$worktree_root" "$issue")"
  worktree_path="$(canonicalize_path "$worktree_path")"

  if ! verify_base_remote "$base"; then
    echo "Error: base branch '${base}' does not exist on remote 'origin'" >&2
    exit 1
  fi
  if ! fetch_base "$base"; then
    echo "Error: git fetch origin '${base}' failed" >&2
    exit 1
  fi

  local existing_branch
  existing_branch="$(find_registered_worktree_branch "$worktree_path")"

  if [ -n "$existing_branch" ]; then
    if [ "$existing_branch" = "$branch" ]; then
      jq -n \
        --argjson issue "$issue" \
        --arg branch "$branch" \
        --arg base "$base" \
        --arg worktree_path "$worktree_path" \
        '{issue: $issue, branch: $branch, base: $base, worktree_path: $worktree_path, created: false, reused: true, branch_existed: true}'
      exit 0
    fi
    echo "Error: worktree path '${worktree_path}' is already registered for a different branch ('${existing_branch}', expected '${branch}'). Refusing to overwrite; resolve manually." >&2
    exit 1
  fi

  if [ -e "$worktree_path" ]; then
    echo "Error: worktree path '${worktree_path}' already exists but is not a registered git worktree (stale directory?). Refusing to overwrite; resolve manually." >&2
    exit 1
  fi

  local branch_existed="false"
  if local_branch_exists "$branch"; then
    branch_existed="true"
    if ! create_worktree_existing_local_branch "$worktree_path" "$branch"; then
      echo "Error: git worktree add failed for existing local branch '${branch}'" >&2
      exit 1
    fi
  elif remote_branch_exists "$branch"; then
    branch_existed="true"
    fetch_branch "$branch" || true
    if ! create_worktree_existing_remote_branch "$worktree_path" "$branch"; then
      echo "Error: git worktree add failed for existing remote branch '${branch}'" >&2
      exit 1
    fi
  else
    if ! create_worktree_new_branch "$worktree_path" "$branch" "$base"; then
      echo "Error: git worktree add failed for new branch '${branch}' from 'origin/${base}'" >&2
      exit 1
    fi
  fi

  jq -n \
    --argjson issue "$issue" \
    --arg branch "$branch" \
    --arg base "$base" \
    --arg worktree_path "$worktree_path" \
    --argjson branch_existed "$branch_existed" \
    '{issue: $issue, branch: $branch, base: $base, worktree_path: $worktree_path, created: true, reused: false, branch_existed: $branch_existed}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
