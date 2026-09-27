#!/bin/bash
# テスト用: 呼ばれるたびに --state のカウンタを 1 増やし、--outcomes（カンマ区切り）の n 番目を outcome にする
# （足りなければ最後の値を繰り返す）。受け取った引数を --log へ 1 行で追記する。
state='' outcomes='' log=''
args="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    --state) state="$2"; shift 2 ;;
    --outcomes) outcomes="$2"; shift 2 ;;
    --log) log="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
done
n=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$state"
[ -n "$log" ] && echo "counter $args" >> "$log"
IFS=',' read -r -a list <<< "$outcomes"
i=$(( n - 1 ))
[ "$i" -ge "${#list[@]}" ] && i=$(( ${#list[@]} - 1 ))
printf '{"outcome":"%s","excerpt":"fail-%d","count":%d}\n' "${list[$i]}" "$n" "$n"
