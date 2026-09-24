#!/bin/bash
# テスト用: 受け取った引数を --log へ 1 行で追記し、outcome pass を返す。
log='' args="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) log="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "recorder $args" >> "$log"
printf '{"outcome":"pass"}\n'
