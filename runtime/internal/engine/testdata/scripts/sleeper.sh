#!/bin/bash
# テスト用: 孫プロセス（sleep）を起動して待つ。自分と孫の PID を --pidfile へ書く。
pidfile=''
while [ $# -gt 0 ]; do
  case "$1" in
    --pidfile) pidfile="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
done
sleep 60 &
child=$!
printf '%s %s\n' "$$" "$child" > "$pidfile.tmp" && mv "$pidfile.tmp" "$pidfile"
wait "$child"
printf '{"outcome":"finished"}\n'
