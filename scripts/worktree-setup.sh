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
# worktreeロック（Issue #45 CodeRabbit指摘の追修正）: star型並列実装では複数チケットの
# `scripts/worktree-setup.sh`/`scripts/worktree-cleanup.sh` 呼び出しが理論上同時に走りうる
# ため、両スクリプトの `git fetch`/`git worktree add`/`git worktree remove` が同じ共有 .git
# を同時に触る可能性がある（レースの一次的な防止策は呼び出し側=リードが各Issueについて
# 逐次呼び出しする運用規律。skills/para-impl/references/star-parallel.md 参照）。本ロックは
# その運用規律が守られなかった場合の防御第二層。macOS標準ではない flock は使わず、
# mkdir のatomic性を使った簡易ロックで直列化する。ロック先はリポジトリの
# git-common-dir配下（mainリポジトリ・全worktreeから共有される単一の実体ディレクトリ）に
# 固定名で置き、setup/cleanup 両スクリプトが同一のロックディレクトリを取り合う
# （worktree-cleanup.sh に同名の定数・同名の関数を複製している。「同じロックファイルを
# 使う」という契約を守るため、ロック名は変更する場合は両ファイル同時に変更すること）。
# ---------------------------------------------------------------------------

WORKTREE_LOCK_NAME="claude-harness-worktree-ops.lock"
WORKTREE_LOCK_STALE_SECONDS=120  # このロック保持時間を超えたら他プロセスがstaleと判断し奪取する
WORKTREE_LOCK_WAIT_SECONDS=60    # ロック取得を諦めるまでの最大待機秒数（テストからは短縮して上書きしてよい）

# start_dir を起点に、リポジトリの共有git-common-dir配下のロックディレクトリの絶対パスを
# 解決する（実在するかどうかは問わない。取得はacquire_worktree_lock側の責務）。
# メインリポジトリ・worktreeのどちらを起点にしても、git-common-dirは常に
# メインリポジトリの実体 .git を指すため、setup/cleanup 双方から同一パスが得られる。
resolve_worktree_lock_dir() {
  local start_dir="${1:-.}"
  local common_dir common_dir_abs
  common_dir="$(cd "$start_dir" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  # pwd -P（symlink解決済みの物理パス）で正規化する。git-common-dirはメインリポジトリからの
  # 呼び出しでは相対パス（例: ".git"。startdir由来の論理パスのまま）、worktreeからの
  # 呼び出しではgitが内部記録済みの絶対パス（既に物理パスに解決済み）を返すため、素の
  # pwdのままだと呼び出し元によって論理/物理パスが混在し、同一リポジトリなのに
  # setup.sh/cleanup.sh双方から異なる文字列（例: macOSの/var -> /private/var）に解決されて
  # しまい「同じロックファイルを取り合う」契約が壊れる（実機で確認した不具合）。
  common_dir_abs="$(cd "$start_dir" && cd "$common_dir" 2>/dev/null && pwd -P)" || return 1
  echo "${common_dir_abs}/${WORKTREE_LOCK_NAME}"
}

# mkdirのatomic性を使ったロック取得。取得できたら0、待機上限に達したら1を返す。
# stale判定: ロックディレクトリ内の acquired_at（epoch秒）が WORKTREE_LOCK_STALE_SECONDS を
# 超えていれば、他プロセスが異常終了（クラッシュ・強制終了等）して解放し忘れたものとみなし
# 奪取する（保持し続けるプロセスが本当に生きている場合でも、上限時間を超えた保持は
# 想定外の長時間ブロックとして扱い、奪取を優先する設計判断）。
acquire_worktree_lock() {
  local lock_dir="$1"
  local waited=0
  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$$" >"${lock_dir}/pid" 2>/dev/null || true
      date +%s >"${lock_dir}/acquired_at" 2>/dev/null || true
      return 0
    fi
    if [ -f "${lock_dir}/acquired_at" ]; then
      local acquired_at now age
      acquired_at="$(cat "${lock_dir}/acquired_at" 2>/dev/null || echo 0)"
      now="$(date +%s)"
      age=$((now - acquired_at))
      if [ "$age" -ge "$WORKTREE_LOCK_STALE_SECONDS" ]; then
        rm -rf "$lock_dir" 2>/dev/null || true
        continue
      fi
    fi
    if [ "$waited" -ge "$WORKTREE_LOCK_WAIT_SECONDS" ]; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

release_worktree_lock() {
  local lock_dir="$1"
  rm -rf "$lock_dir" 2>/dev/null || true
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

  # 以降、git fetch / git worktree add を含む共有 .git への書き込み区間をロックで
  # 保護する（trap EXIT により、この後のどの exit 経路でも確実に解放される）。
  # 注意: lock_dir は意図的に local にしない。main() が exit を呼ばずに正常return
  # する経路（新規worktree作成成功時）では、trap EXIT の発火はこの関数フレームを
  # 抜けた後（プロセス/サブシェルの自然終了時）になるため、local変数だと
  # trap発火時点で既にスコープ外（set -u下でunbound variableエラー）になり、
  # release_worktree_lock が実行されずロックがリークする（実機で確認した不具合）。
  lock_dir=""
  if ! lock_dir="$(resolve_worktree_lock_dir "$repo_root")"; then
    echo "Error: failed to resolve worktree lock directory" >&2
    exit 1
  fi
  if ! acquire_worktree_lock "$lock_dir"; then
    echo "Error: timed out waiting for worktree lock (another worktree-setup.sh/worktree-cleanup.sh run may be holding it): ${lock_dir}" >&2
    exit 1
  fi
  trap 'release_worktree_lock "$lock_dir"' EXIT

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
