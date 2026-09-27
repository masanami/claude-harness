#!/bin/bash
# テスト用: --json の文字列をそのまま stdout へ出し、--code の終了コードで終わる。
json='' code=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json="$2"; shift 2 ;;
    --code) code="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
done
printf '%s\n' "$json"
echo "emit: exiting with $code" >&2
exit "$code"
