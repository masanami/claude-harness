#!/bin/bash
# テスト用の偽の gh（predict-conflicts 用。Issue ごとに別の本文を返す）。FAKE_GH_DIR の下で動く。
#   calls: 受け取った argv（1 呼び出し 1 行。引数は TAB 区切り）
#   issue view <n> → issue.<n>.json（無ければ exit 1）
#   repo view      → repo（無ければ o/r。-q の加工は済んだ値として出す）
set -u
dir="$FAKE_GH_DIR"
( IFS=$'\t'; printf '%s\n' "$*" ) >> "$dir/calls"
case "$1 ${2:-}" in
  "issue view")
    [ -f "$dir/issue.$3.json" ] || { echo "fake gh: could not resolve to an issue: $3" >&2; exit 1; }
    cat "$dir/issue.$3.json" ;;
  "repo view")
    cat "$dir/repo" 2>/dev/null || echo o/r ;;
  *)
    echo "fake gh: unsupported: $*" >&2; exit 1 ;;
esac
