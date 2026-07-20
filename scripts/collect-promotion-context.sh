#!/bin/bash
# collect-promotion-context.sh
# skills/promote-verify/SKILL.md（Step 3）が Bash ツールで直接実行する決定的スクリプト
# （Issue #110 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し、呼び出し元自身の
# 直接実行に一本化した）。統合ブランチ→main 昇格前検証パッケージの一部として、base ブランチと
# 統合ブランチの間の diff コンテキストを取得する（Issue #52）。
#
# collect-review-diff.sh と同じ設計思想（gh非依存・純粋な git 操作・関数分離によるテスト容易性・
# diff本文は一時ファイル書き出し）を踏襲するが、対象は「merge-base → 作業ツリー」ではなく
# 「base ブランチ ↔ 統合ブランチ」という2つの名前付きブランチ間（three-dot diff）である点が異なる。
#
# 使い方:
#   scripts/collect-promotion-context.sh <base_branch> <integration_branch>
#     例: scripts/collect-promotion-context.sh main feat/issue-52-promotion-verify
#
# 出力（stdout にJSON1個）:
#   {
#     "base": "main",
#     "integration": "feat/issue-52-promotion-verify",
#     "merge_base": "<sha>",
#     "diff_stat": "path/a.js | +12 -3\n...",
#     "name_status": [{"status": "M", "path": "path/a.js"}, ...],
#     "diff_file": "/path/to/tmpfile"
#   }
#
# name_status の各要素:
#   - 通常（M/A/D等）: {"status": "M", "path": "..."}
#   - rename（`R100\told\tnew` のような3カラム行）: {"status": "R100", "path": "<new>", "oldPath": "<old>"}
#
# diff_file の中身は「base_ref...integration_ref」（three-dot。merge-baseから統合ブランチ側への
# 差分）の unified diff 全文。呼び出し側はdiff本文をプロンプトに直貼りせず、このパスを
# エージェントに渡してReadさせること（collect-review-diff.sh の diff_file と同じ思想。
# コンテキスト削減のため）。
#
# ref解決（resolve_ref）:
#   base/integration いずれも、`origin/<name>` が解決できなければ `<name>`（ローカルブランチ）に
#   フォールバックする（collect-review-diff.sh の resolve_base_ref と同じフォールバック方式を
#   汎用化し、両方の引数に使い回す）。
#
# fetch（重要。テスト容易性のための設計）:
#   `git fetch origin` は main() からのみ呼ばれる別関数 fetch_origin に分離している。
#   ref解決・merge-base算出・diff系の関数からは呼ばない。fetch は best-effort とし、
#   失敗しても stderr に警告を出すのみで処理を継続する（ローカルに既に fetch 済みの ref が
#   あれば動作を継続できるようにするため）。これにより、テストは fetch を経由せず
#   ref解決・merge-base・diff系の関数を直接呼んでローカル一時gitリポジトリで検証できる
#   （`origin` リモートを用意しない。scripts/tests/test-collect-promotion-context.sh）。
#
# jq 不在時・git操作失敗時は stderr にエラー + exit非0（scripts/README.md の出力規約に従う）。
#
# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。

set -u

# jq の有無をチェックする。無ければ stderr にエラーメッセージ + エラーJSONを出す。
check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# git fetch origin を best-effort で実行する（gh を呼ばない。git のみ）。
# main() からのみ呼ばれる。失敗してもエラー終了せず、stderr に警告を出して続行する
# （ローカルに既に fetch 済みの ref があれば動作を継続できるようにするため）。
fetch_origin() {
  if ! git fetch origin >/dev/null 2>&1; then
    echo "Warning: git fetch origin failed; proceeding with locally available refs" >&2
  fi
  return 0
}

# `origin/<name>` が解決できなければ `<name>`（ローカルブランチ）にフォールバックする。
# git を呼ぶため純粋関数ではない（ghは呼ばない・fetchも呼ばない）。base/integration
# いずれの引数にも使い回せるよう汎用化している（collect-review-diff.sh の
# resolve_base_ref と同じフォールバック方式）。
# 引数: ref名
# 結果: RESOLVED_REF（"origin/main" または "main" 等）
resolve_ref() {
  local name="$1"
  # name が "-" 始まりだと git rev-parse にオプションとして解釈されうるため、
  # gitに渡す前に弾く（オプション注入対策）。
  if [[ "$name" == -* ]]; then
    echo "Error: ref name must not start with '-', got '${name}'" >&2
    return 1
  fi

  if git rev-parse --verify --quiet "origin/${name}" >/dev/null 2>&1; then
    RESOLVED_REF="origin/${name}"
    return 0
  fi
  if git rev-parse --verify --quiet "${name}" >/dev/null 2>&1; then
    RESOLVED_REF="${name}"
    return 0
  fi
  echo "Error: could not resolve ref for '${name}' (tried origin/${name} and ${name})" >&2
  return 1
}

# base_ref と integration_ref の merge-base を算出する。
# 引数: base_ref, integration_ref
# 結果: MERGE_BASE
compute_merge_base() {
  local base_ref="$1" integration_ref="$2"
  if ! MERGE_BASE=$(git merge-base "$base_ref" "$integration_ref" 2>/dev/null); then
    echo "Error: git merge-base failed for '${base_ref}' and '${integration_ref}'" >&2
    return 1
  fi
  return 0
}

# `git diff --stat <base_ref>...<integration_ref>`（three-dot。merge-baseから統合ブランチ側への
# 差分）の出力をテキストとして取得する。
# 引数: base_ref, integration_ref
# 結果: DIFF_STAT
compute_diff_stat() {
  local base_ref="$1" integration_ref="$2"
  if ! DIFF_STAT=$(git diff --stat "${base_ref}...${integration_ref}" 2>/dev/null); then
    echo "Error: git diff --stat failed for '${base_ref}...${integration_ref}'" >&2
    return 1
  fi
  return 0
}

# `git diff --name-status <base_ref>...<integration_ref>` の生テキスト出力を取得する。
# git を呼ぶため純粋関数ではない。
# 引数: base_ref, integration_ref
# 結果: NAME_STATUS_RAW
collect_name_status_raw() {
  local base_ref="$1" integration_ref="$2"
  if ! NAME_STATUS_RAW=$(git diff --name-status "${base_ref}...${integration_ref}" 2>/dev/null); then
    echo "Error: git diff --name-status failed for '${base_ref}...${integration_ref}'" >&2
    return 1
  fi
  return 0
}

# `git diff --name-status` の生テキストをJSON配列へパースする純粋関数（git を呼ばない）。
# 通常行（例: "M\tpath/a.js"）は {"status": "M", "path": "path/a.js"}。
# rename行（3カラム。例: "R100\told/path.js\tnew/path.js"）は
# {"status": "R100", "path": "new/path.js", "oldPath": "old/path.js"} として扱う。
# 引数: raw_text（省略時は標準入力から読む）
# 結果: NAME_STATUS_JSON
parse_name_status() {
  local raw
  if [ "$#" -ge 1 ]; then
    raw="$1"
  else
    raw="$(cat)"
  fi

  local json="[]"
  local status field2 field3
  while IFS=$'\t' read -r status field2 field3; do
    [ -z "$status" ] && continue
    if [ -n "$field3" ]; then
      # 3カラム行（rename/copy等）。status例: R100
      json=$(jq -c --arg status "$status" --arg path "$field3" --arg oldPath "$field2" \
        '. + [{"status": $status, "path": $path, "oldPath": $oldPath}]' <<<"$json")
    else
      json=$(jq -c --arg status "$status" --arg path "$field2" \
        '. + [{"status": $status, "path": $path}]' <<<"$json")
    fi
  done <<<"$raw"

  NAME_STATUS_JSON="$json"
}

# base_ref から integration_ref への unified diff 全文（three-dot）を一時ファイルに書き出す。
# git を呼ぶため純粋関数ではない。
# 引数: base_ref, integration_ref
# 結果: DIFF_FILE（書き出した一時ファイルの絶対パス）
write_diff_file() {
  local base_ref="$1" integration_ref="$2"
  local out
  out=$(mktemp "${TMPDIR:-/tmp}/collect-promotion-context.XXXXXX")
  if ! git diff "${base_ref}...${integration_ref}" >"$out" 2>/dev/null; then
    echo "Error: git diff failed for '${base_ref}...${integration_ref}'" >&2
    rm -f "$out"
    return 1
  fi
  DIFF_FILE="$out"
  return 0
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <base_branch> <integration_branch>" >&2
}

main() {
  local base="${1:-}" integration="${2:-}"

  if [ -z "$base" ] || [ -z "$integration" ]; then
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  # best-effort。失敗しても続行する（fetch_origin 内で警告を出す）。
  fetch_origin

  if ! resolve_ref "$base"; then
    exit 1
  fi
  local base_ref="$RESOLVED_REF"

  if ! resolve_ref "$integration"; then
    exit 1
  fi
  local integration_ref="$RESOLVED_REF"

  if ! compute_merge_base "$base_ref" "$integration_ref"; then
    exit 1
  fi
  local merge_base="$MERGE_BASE"

  if ! compute_diff_stat "$base_ref" "$integration_ref"; then
    exit 1
  fi
  local diff_stat="$DIFF_STAT"

  if ! collect_name_status_raw "$base_ref" "$integration_ref"; then
    exit 1
  fi
  parse_name_status "$NAME_STATUS_RAW"
  local name_status_json="$NAME_STATUS_JSON"

  if ! write_diff_file "$base_ref" "$integration_ref"; then
    exit 1
  fi
  local diff_file="$DIFF_FILE"

  jq -n \
    --arg base "$base" \
    --arg integration "$integration" \
    --arg merge_base "$merge_base" \
    --arg diff_stat "$diff_stat" \
    --argjson name_status "$name_status_json" \
    --arg diff_file "$diff_file" \
    '{base: $base, integration: $integration, merge_base: $merge_base, diff_stat: $diff_stat, name_status: $name_status, diff_file: $diff_file}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
