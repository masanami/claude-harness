#!/bin/bash
# collect-review-diff.sh
# 使い方: scripts/collect-review-diff.sh [BASE]（詳細は下記参照）
# 仕様の正本は scripts/specs/collect-review-diff.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# BASE未指定時のフォールバック解決。gh を呼ぶため純粋関数ではない。
# 引数: 呼び出し元から明示指定されたBASE（空文字なら未指定として扱う）
# 結果: RESOLVED_BASE
resolve_base() {
  local override="${1:-}"
  if [ -n "$override" ]; then
    RESOLVED_BASE="$override"
    return 0
  fi

  local base
  if base=$(gh pr view --json baseRefName -q '.baseRefName' 2>/dev/null) && [ -n "$base" ]; then
    RESOLVED_BASE="$base"
    return 0
  fi

  if base=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null) && [ -n "$base" ]; then
    RESOLVED_BASE="$base"
    return 0
  fi

  echo "Error: failed to resolve BASE branch via gh (pr view / repo view both failed). Pass BASE explicitly as an argument." >&2
  return 1
}

# origin/<base> が解決できなければ <base>（ローカルブランチ）にフォールバックする。
# git を呼ぶため純粋関数ではない（ghは呼ばない）。
# 引数: base名
# 結果: BASE_REF（"origin/main" または "main" 等）
resolve_base_ref() {
  local base="$1"
  # base が "-" 始まりだと git rev-parse にオプションとして解釈されうるため、
  # gitに渡す前に弾く（gh由来のブランチ名が"-"始まりになることは通常無いが、
  # 呼び出し元から任意文字列が渡される経路の防御として明示的に拒否する）。
  if [[ "$base" == -* ]]; then
    echo "Error: base must not start with '-', got '${base}'" >&2
    return 1
  fi

  if git rev-parse --verify --quiet "origin/${base}" >/dev/null 2>&1; then
    BASE_REF="origin/${base}"
    return 0
  fi
  if git rev-parse --verify --quiet "${base}" >/dev/null 2>&1; then
    BASE_REF="${base}"
    return 0
  fi
  echo "Error: could not resolve ref for base '${base}' (tried origin/${base} and ${base})" >&2
  return 1
}

# merge-baseを算出する。three-dot相当の意味論を作業ツリー比較で正しく再現するために使う
# （baseが進んでいる場合に上流変更が逆向きに混入しないようにするため）。
# 引数: base_ref
# 結果: MERGE_BASE
compute_merge_base() {
  local base_ref="$1"
  if ! MERGE_BASE=$(git merge-base "$base_ref" HEAD 2>/dev/null); then
    echo "Error: git merge-base failed for '${base_ref}' and HEAD" >&2
    return 1
  fi
  return 0
}

# 未追跡ファイルをintent-to-addでインデックスに登録する（内容は空のまま）。
# これにより後続の `git diff` が新規ファイルを追加として検出できるようになる。
#
# 実の `.git/index`（呼び出し元＝/self-review 実行環境のstaging状態）を汚さないため、
# 一時ファイルにコピーした index 上で `git add --intent-to-add -A` を実行する
# （CodeRabbit指摘の回帰修正。旧実装は実indexへ直接書き込んでいた）。
# 生成した一時indexのパスは呼び出し元がRESOLVED_BASE/MERGE_BASE等と同じパターンで
# 参照できるよう、グローバル変数 TMP_INDEX_FILE に格納する。後続の collect_files/
# write_diff_file にも同じ一時indexを渡す必要がある（intent-to-addで登録した
# 未追跡ファイルをそれらの `git diff` が検出するため）。
# git add 自体が失敗した場合（リポジトリ破損等）は呼び出し元に終了ステータスを伝播する。
stage_untracked_as_intent_to_add() {
  local git_dir
  if ! git_dir=$(git rev-parse --git-dir 2>/dev/null); then
    echo "Error: not a git repository (git rev-parse --git-dir failed)" >&2
    return 1
  fi

  local tmp_index
  tmp_index=$(mktemp "${TMPDIR:-/tmp}/collect-review-diff-index.XXXXXX")

  # 実indexが存在すればコピーして既存のtracked状態を引き継ぐ。存在しない場合
  # （コミット前の空リポジトリ等）は何もコピーせず、git addが新規に作る挙動に任せる。
  if [ -f "${git_dir}/index" ]; then
    cp "${git_dir}/index" "$tmp_index"
  fi

  if ! GIT_INDEX_FILE="$tmp_index" git add --intent-to-add -A 2>/dev/null; then
    echo "Error: git add --intent-to-add -A failed" >&2
    rm -f "$tmp_index"
    return 1
  fi

  TMP_INDEX_FILE="$tmp_index"
  return 0
}

# コミット一覧（oneline）をJSON配列に変換する。git を呼ぶため純粋関数ではない。
# 引数: base_ref
# 結果: COMMITS_JSON
collect_commits() {
  local base_ref="$1"
  local lines
  lines=$(git log "${base_ref}..HEAD" --oneline 2>/dev/null)
  if [ -z "$lines" ]; then
    COMMITS_JSON="[]"
    return 0
  fi
  COMMITS_JSON=$(printf '%s\n' "$lines" | jq -R -s -c 'split("\n") | map(select(length > 0))')
}

# 変更ファイル一覧（作業ツリー込み。merge_base基準）をJSON配列に変換する。
# git を呼ぶため純粋関数ではない。
# 引数: merge_base, index_file（省略可。stage_untracked_as_intent_to_add が生成した
#       一時indexのパス。渡された場合はそのindexを GIT_INDEX_FILE として使う）
# 結果: FILES_JSON
collect_files() {
  local merge_base="$1"
  local index_file="${2:-}"
  local lines
  if [ -n "$index_file" ]; then
    lines=$(GIT_INDEX_FILE="$index_file" git diff --name-only "$merge_base" 2>/dev/null)
  else
    lines=$(git diff --name-only "$merge_base" 2>/dev/null)
  fi
  if [ -z "$lines" ]; then
    FILES_JSON="[]"
    return 0
  fi
  FILES_JSON=$(printf '%s\n' "$lines" | jq -R -s -c 'split("\n") | map(select(length > 0))')
}

# 作業ツリー込みdiff本文を一時ファイルに書き出す。git を呼ぶため純粋関数ではない。
# 引数: merge_base, index_file（省略可。collect_files と同様の一時index指定）
# 結果: DIFF_FILE（書き出した一時ファイルの絶対パス）
write_diff_file() {
  local merge_base="$1"
  local index_file="${2:-}"
  local out
  out=$(mktemp "${TMPDIR:-/tmp}/collect-review-diff.XXXXXX")
  if [ -n "$index_file" ]; then
    if ! GIT_INDEX_FILE="$index_file" git diff "$merge_base" >"$out" 2>/dev/null; then
      echo "Error: git diff failed for merge-base '${merge_base}'" >&2
      rm -f "$out"
      return 1
    fi
  else
    if ! git diff "$merge_base" >"$out" 2>/dev/null; then
      echo "Error: git diff failed for merge-base '${merge_base}'" >&2
      rm -f "$out"
      return 1
    fi
  fi
  DIFF_FILE="$out"
  return 0
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} [BASE]" >&2
}

main() {
  local override_base="${1:-}"

  if ! check_jq; then
    exit 1
  fi

  if ! resolve_base "$override_base"; then
    exit 1
  fi
  local base="$RESOLVED_BASE"

  if ! resolve_base_ref "$base"; then
    exit 1
  fi
  local base_ref="$BASE_REF"

  if ! compute_merge_base "$base_ref"; then
    exit 1
  fi
  local merge_base="$MERGE_BASE"

  if ! stage_untracked_as_intent_to_add; then
    exit 1
  fi
  # 一時indexは全終了経路（成功・失敗いずれも）で確実に削除する。
  # TMP_INDEX_FILE はグローバル変数のため、trap登録以降に上書きされない限りそのまま参照できる。
  trap 'rm -f "$TMP_INDEX_FILE"' EXIT

  collect_commits "$base_ref"
  local commits_json="$COMMITS_JSON"

  collect_files "$merge_base" "$TMP_INDEX_FILE"
  local files_json="$FILES_JSON"

  if ! write_diff_file "$merge_base" "$TMP_INDEX_FILE"; then
    exit 1
  fi
  local diff_file="$DIFF_FILE"

  jq -n \
    --arg base "$base" \
    --arg merge_base "$merge_base" \
    --argjson commits "$commits_json" \
    --argjson files "$files_json" \
    --arg diff_file "$diff_file" \
    '{base: $base, merge_base: $merge_base, commits: $commits, files: $files, diff_file: $diff_file}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
