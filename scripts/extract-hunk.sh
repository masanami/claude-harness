#!/bin/bash
# extract-hunk.sh
# /self-review（skills/self-review/SKILL.md）の Step 3（懐疑的検証）が、finding の
# {file, line} から該当 diff hunk（＋前後N行）を切り出すために呼び出す決定的スクリプト。
# 懐疑者（finding-verifier）3体×指摘数に全diffを配る事態を構造的に避けるための入力スライス。
#
# 使い方:
#   scripts/extract-hunk.sh <diff_file> <file> <line> [context_lines=3]
#     diff_file: collect-review-diff.sh が出力した diff_file のパス
#     file/line: findingの対象ファイルパス・行番号（new側の行番号を想定）
#     context_lines: 該当hunkの前後に付与する追加コンテキスト行数（省略時3）
#
# 出力（stdout にJSON1個）:
#   {"file": "...", "line": N, "found": true|false, "snippet": "..."}
#
# found=false の場合、snippet には最も近いhunk（行番号が最も近いhunk。同一ファイル内に
# hunkが1つも無ければ空文字）が入る。懐疑者（finding-verifier）にはRead/Grepを残しているため、
# hunk外のコンテキストが必要な場合や本スクリプトの一次スライスで不十分な場合は
# 懐疑者自身がファイルを読むことを想定する。
#
# 純粋なテキスト処理のみで完結する（gh/git を呼ばない。diff_fileの中身だけを見る）。
#
# テスト容易性のため、テキスト処理本体（extract_hunk_from_diff）を関数として分離している。
# `source` すればgh/gitを呼ばずに直接テストできる（scripts/tests/test-extract-hunk.sh）。
#
# `source` された場合は main を実行しない。

set -u

check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

# diff_fileの中からtarget_file/target_lineに該当するhunk（＋前後context_lines行）を
# 抜き出す純粋なテキスト処理。gh/gitを呼ばない。
#
# アルゴリズム:
#   1. "diff --git a/<file> b/<file>" ヘッダで対象ファイルのセクションを特定する
#   2. セクション内の各hunk（"@@ -o,ol +n,nl @@"）について、ヘッダから
#      new側の行範囲 [nstart, nstart+nlen-1] を算出する
#   3. target_line がその範囲に収まるhunkを「該当hunk」とする
#   4. 該当hunkが見つかれば、context_lines > 0 の場合、直前/直後のhunk本文の
#      末尾/先頭 context_lines 行を "..." 区切りで前後に付与する
#   5. 該当hunkが見つからなければ、行番号距離が最も近いhunkを「最も近いhunk」として返す
#      （見つからない旨は found=false で表現する）
#
# 引数: diff_file target_file target_line context_lines
# 結果: EXTRACT_FOUND ("0"|"1"), EXTRACT_SNIPPET
extract_hunk_from_diff() {
  local diff_file="$1" target_file="$2" target_line="$3" context_lines="$4"
  local raw
  raw=$(awk -v target_file="$target_file" -v target_line="$target_line" -v ctx="$context_lines" '
    function is_file_header(line_text,   want) {
      want = "diff --git a/" target_file " b/" target_file
      return (index(line_text, want) == 1)
    }
    {
      if ($0 ~ /^diff --git /) {
        in_section = is_file_header($0) ? 1 : 0
        next
      }
      if (in_section) {
        if ($0 ~ /^@@ /) {
          nhunks++
          line_copy = $0
          if (match(line_copy, /\+[0-9]+(,[0-9]+)?/)) {
            seg = substr(line_copy, RSTART+1, RLENGTH-1)
            split(seg, parts, ",")
            nstart[nhunks] = parts[1]+0
            if (parts[2] != "") { nlen[nhunks] = parts[2]+0 } else { nlen[nhunks] = 1 }
          } else {
            nstart[nhunks] = 0
            nlen[nhunks] = 0
          }
          nend[nhunks] = nstart[nhunks] + (nlen[nhunks] > 0 ? nlen[nhunks]-1 : 0)
          body[nhunks] = $0 "\n"
        } else if (nhunks > 0) {
          body[nhunks] = body[nhunks] $0 "\n"
        }
      }
    }
    END {
      matched = 0
      for (i = 1; i <= nhunks; i++) {
        if (target_line >= nstart[i] && target_line <= nend[i]) {
          matched = i
          break
        }
      }
      if (matched == 0) {
        best = 0; bestdist = -1
        for (i = 1; i <= nhunks; i++) {
          if (target_line < nstart[i]) { d = nstart[i]-target_line }
          else if (target_line > nend[i]) { d = target_line-nend[i] }
          else { d = 0 }
          if (bestdist == -1 || d < bestdist) { bestdist = d; best = i }
        }
        print "FOUND=0"
        print "---SNIPPET---"
        if (best > 0) { printf "%s", body[best] }
        exit
      }
      print "FOUND=1"
      print "---SNIPPET---"
      if (matched > 1 && ctx > 0) {
        prev = body[matched-1]
        n = split(prev, plines, "\n")
        start_idx = n - ctx
        if (start_idx < 1) start_idx = 1
        for (k = start_idx; k < n; k++) printf "%s\n", plines[k]
        printf "...\n"
      }
      printf "%s", body[matched]
      if (matched < nhunks && ctx > 0) {
        printf "...\n"
        nxt = body[matched+1]
        n2 = split(nxt, nlines2, "\n")
        end_idx = ctx
        if (end_idx > n2-1) end_idx = n2-1
        for (k = 1; k <= end_idx; k++) printf "%s\n", nlines2[k]
      }
    }
  ' "$diff_file")

  local found_line
  found_line=$(printf '%s\n' "$raw" | sed -n '1p')
  EXTRACT_FOUND="0"
  if [ "$found_line" = "FOUND=1" ]; then
    EXTRACT_FOUND="1"
  fi
  EXTRACT_SNIPPET=$(printf '%s\n' "$raw" | sed '1,2d')
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <diff_file> <file> <line> [context_lines=3]" >&2
}

main() {
  local diff_file="${1:-}" target_file="${2:-}" target_line="${3:-}" context_lines="${4:-3}"

  if [ -z "$diff_file" ] || [ -z "$target_file" ] || [ -z "$target_line" ]; then
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  if [ ! -f "$diff_file" ]; then
    echo "Error: diff file not found: ${diff_file}" >&2
    exit 1
  fi

  if ! [[ "$target_line" =~ ^[0-9]+$ ]]; then
    echo "Error: line must be numeric, got '${target_line}'" >&2
    exit 1
  fi

  if ! [[ "$context_lines" =~ ^[0-9]+$ ]]; then
    echo "Error: context_lines must be numeric, got '${context_lines}'" >&2
    exit 1
  fi

  extract_hunk_from_diff "$diff_file" "$target_file" "$target_line" "$context_lines"

  local found_bool="false"
  [ "$EXTRACT_FOUND" = "1" ] && found_bool="true"

  jq -n \
    --arg file "$target_file" \
    --argjson line "$target_line" \
    --argjson found "$found_bool" \
    --arg snippet "$EXTRACT_SNIPPET" \
    '{file: $file, line: $line, found: $found, snippet: $snippet}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
