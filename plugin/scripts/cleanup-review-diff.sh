#!/bin/bash
# cleanup-review-diff.sh
# 使い方: scripts/cleanup-review-diff.sh <path> [<path>...]
# 仕様の正本は scripts/specs/collect-review-diff.md（「cleanup-review-diff.sh」節）を参照。
#
# /self-review・/codex-review が使い終えたレビュー用一時ファイル（collect-review-diff の
# diff_file と、/codex-review の context ファイル）を削除する。スキル本文の素の `rm -f` は
# allowlist できず headless 委譲で毎回拒否されるため、ランチャー経由
# （`claude-harness-run cleanup-review-diff "<path>"`）で後始末を完結させる（Issue #293）。
#
# ランチャーを allow すると permission の deny はこの向こう側に及ばない（docs/script-launcher.md §6）。
# そのため「任意のファイルを消せる rm」にはせず、消してよい対象を次の 3 条件すべてで絞る:
#   1. 絶対パスであること
#   2. basename が `collect-review-diff.<6文字以上の英数字>` または
#      `codex-review-context.<6文字以上の英数字>`（mktemp の XXXXXX が作る形）であること
#   3. 置き場所（親ディレクトリの実体）が `${TMPDIR:-/tmp}` の実体と一致すること
# 加えて、存在するならシンボリックリンクではない通常ファイルであること。
# 1 つでも条件を満たさない引数があれば、**何も消さずに** exit 64 で拒否する（部分実行しない）。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# 消してよい basename の形。collect-review-diff-index.* は collect-review-diff.sh 自身の
# trap が消すため対象外（`.` が prefix の直後に来ることを要求して区別する）。
CLEANUP_NAME_RE='^(collect-review-diff|codex-review-context)\.[A-Za-z0-9]{6,}$'

# ディレクトリの実体パスを返す（macOS の /var → /private/var や TMPDIR の末尾 `/` を吸収する）。
# 引数: ディレクトリパス
# 結果: stdout に実体パス。解決できなければ非0
canonical_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# 1 引数を検査する。純粋ではない（ファイルシステムを見る）。
# 引数: path, 許可ディレクトリの実体パス
# 結果: 削除してよければ 0、拒否なら 1 を返し REFUSE_REASON に理由を入れる
check_cleanup_target() {
  local path="$1" allowed_dir="$2"
  REFUSE_REASON=""

  if [ -z "$path" ]; then
    REFUSE_REASON="empty path"
    return 1
  fi
  if [[ "$path" != /* ]]; then
    REFUSE_REASON="not an absolute path"
    return 1
  fi

  local name dir real_dir
  name="$(basename "$path")"
  if ! [[ "$name" =~ $CLEANUP_NAME_RE ]]; then
    REFUSE_REASON="file name is not a review temp file (collect-review-diff.* / codex-review-context.*)"
    return 1
  fi

  dir="$(dirname "$path")"
  if ! real_dir="$(canonical_dir "$dir")"; then
    REFUSE_REASON="parent directory does not exist"
    return 1
  fi
  if [ "$real_dir" != "$allowed_dir" ]; then
    REFUSE_REASON="not under the temp directory (${allowed_dir})"
    return 1
  fi

  if [ -L "$path" ]; then
    REFUSE_REASON="is a symbolic link"
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    REFUSE_REASON="not a regular file"
    return 1
  fi
  return 0
}

print_usage() {
  echo "Usage: $(basename "$0") <path> [<path>...]" >&2
}

main() {
  if ! check_jq; then
    exit 1
  fi

  if [ "$#" -eq 0 ]; then
    print_usage
    jq -n -c '{status: "refused", removed: [], absent: [], refused: [{path: "", reason: "no path given"}]}'
    exit 64
  fi

  local allowed_dir
  if ! allowed_dir="$(canonical_dir "${TMPDIR:-/tmp}")"; then
    echo "Error: temp directory '${TMPDIR:-/tmp}' does not exist" >&2
    jq -n -c '{status: "error", removed: [], absent: [], refused: []}'
    exit 1
  fi

  # 先に全引数を検査し、1 つでも拒否があれば何も消さない。
  local refused_json="[]" path
  for path in "$@"; do
    if ! check_cleanup_target "$path" "$allowed_dir"; then
      echo "Error: refused '${path}': ${REFUSE_REASON}" >&2
      refused_json="$(jq -c --arg p "$path" --arg r "$REFUSE_REASON" '. + [{path: $p, reason: $r}]' <<<"$refused_json")"
    fi
  done
  if [ "$refused_json" != "[]" ]; then
    jq -n -c --argjson refused "$refused_json" '{status: "refused", removed: [], absent: [], refused: $refused}'
    exit 64
  fi

  # 既に無いものは成功扱い（後始末は冪等にする。失敗経路から二重に呼ばれても落ちない）。
  local removed_json="[]" absent_json="[]" failed=0
  for path in "$@"; do
    if [ ! -e "$path" ]; then
      absent_json="$(jq -c --arg p "$path" '. + [$p]' <<<"$absent_json")"
      continue
    fi
    if rm -f -- "$path"; then
      removed_json="$(jq -c --arg p "$path" '. + [$p]' <<<"$removed_json")"
    else
      echo "Error: failed to remove '${path}'" >&2
      failed=1
    fi
  done

  local status="ok"
  [ "$failed" -eq 1 ] && status="error"
  jq -n -c --arg s "$status" --argjson removed "$removed_json" --argjson absent "$absent_json" \
    '{status: $s, removed: $removed, absent: $absent, refused: []}'
  [ "$failed" -eq 1 ] && exit 1
  exit 0
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
