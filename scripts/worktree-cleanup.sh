#!/bin/bash
# worktree-cleanup.sh
# skills/para-impl/SKILL.md Phase 11（複数Issue時のworktreeクリーンアップ）を
# 切り出した決定的スクリプト（Issue #45）。`git status --short` で確認してから
# 削除する。failure worktree（未コミット差分がある等）の保護は呼び出し側の
# 判断に委ねるフラグ設計にする（無条件削除をデフォルトにしない）。
#
# 使い方:
#   scripts/worktree-cleanup.sh <worktree_path> [--force|--skip-if-dirty]
#     フラグ省略時（既定）: worktree が dirty（未コミット差分あり）なら削除を拒否し
#       exit 非0（保護がデフォルト）
#     --force: dirty かどうかに関わらず強制削除する（`git worktree remove --force`）
#     --skip-if-dirty: dirty なら削除せず正常終了（skipped: true）。クリーンなら
#       通常どおり削除する（複数worktreeを一括処理するループから、dirtyな1件だけを
#       安全にスキップしたい場合に使う）
#
# 出力（stdout にJSON1個）:
#   {"worktree_path": "...", "removed": true|false, "skipped": true|false, "dirty": true|false, "reason": "..."|null}
#
# gh は呼ばない（gh非依存）。
#
# テスト容易性のため、git を呼ぶ処理（is_dirty/resolve_main_repo_root/remove_worktree）は
# 一時gitリポジトリ（mktemp -d）+ 実際の worktree を作成して検証する
# （scripts/tests/test-worktree-cleanup.sh）。

set -u

check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# git 呼び出し（外部作用あり）
# ---------------------------------------------------------------------------

# worktree に未コミット差分（staged/unstaged/untracked）があるかを判定する。
# 結果: "true" または "false"
is_dirty() {
  local worktree_path="$1"
  local status
  status="$(git -C "$worktree_path" status --short 2>/dev/null)"
  if [ -n "$status" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# 指定 worktree が属するメインリポジトリのルート（`git worktree remove` を
# 実行できる場所）を解決する。`-C` だけだと `git rev-parse --git-common-dir` の
# 出力が worktree_path 相対のパスで返るため、明示的に cd してから解決する。
resolve_main_repo_root() {
  local worktree_path="$1"
  local common_dir
  if ! common_dir="$(cd "$worktree_path" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)"; then
    return 1
  fi
  (cd "$worktree_path" && cd "${common_dir}/.." && pwd)
}

remove_worktree() {
  local main_root="$1" worktree_path="$2" force="$3"
  if [ "$force" = "true" ]; then
    git -C "$main_root" worktree remove --force "$worktree_path" >/dev/null 2>&1
  else
    git -C "$main_root" worktree remove "$worktree_path" >/dev/null 2>&1
  fi
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <worktree_path> [--force|--skip-if-dirty]" >&2
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local worktree_path="${1:-}" flag="${2:-}"

  if [ -z "$worktree_path" ]; then
    print_usage
    exit 1
  fi
  case "$flag" in
    ""|"--force"|"--skip-if-dirty") ;;
    *)
      echo "Error: unknown flag '${flag}' (expected --force or --skip-if-dirty)" >&2
      print_usage
      exit 1
      ;;
  esac

  if ! check_jq; then
    exit 1
  fi

  if [ ! -d "$worktree_path" ]; then
    echo "Error: worktree path does not exist: ${worktree_path}" >&2
    exit 1
  fi

  local dirty
  dirty="$(is_dirty "$worktree_path")"

  if [ "$dirty" = "true" ] && [ "$flag" != "--force" ]; then
    if [ "$flag" = "--skip-if-dirty" ]; then
      jq -n --arg wp "$worktree_path" '{worktree_path: $wp, removed: false, skipped: true, dirty: true, reason: "dirty_worktree_skipped"}'
      exit 0
    fi
    echo "Error: worktree has uncommitted changes; refusing to remove (pass --force or --skip-if-dirty): ${worktree_path}" >&2
    exit 1
  fi

  local main_root
  if ! main_root="$(resolve_main_repo_root "$worktree_path")"; then
    echo "Error: failed to resolve main repository root for worktree: ${worktree_path}" >&2
    exit 1
  fi

  local force="false"
  [ "$flag" = "--force" ] && force="true"

  if ! remove_worktree "$main_root" "$worktree_path" "$force"; then
    echo "Error: git worktree remove failed for ${worktree_path}" >&2
    exit 1
  fi

  jq -n --arg wp "$worktree_path" --argjson dirty "$dirty" \
    '{worktree_path: $wp, removed: true, skipped: false, dirty: $dirty, reason: null}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
