#!/bin/bash
# テスト用の偽の claude（実際の claude を呼ばずに llm 種類を試す）。FAKE_CLAUDE_DIR の下で動く。
#   responses/<n>（無ければ responses/default）を n 回目の応答にする: 1 行目が終了コード、2 行目以降が stdout。
#     応答中の @SID@ は --session-id / --resume に渡された session id に置き換える。
#   responses/<n>.sleep があれば、自分の PID を pids へ書いて眠る（runner が落ちる場合を作る）。
#   受け取った argv を calls/<n>.argv（1 行 1 引数）、stdin を calls/<n>.stdin に残す。
#   FAKE_CLAUDE_EVENTS が指す events.jsonl に、起動した時点で session id が記録されていたかを calls/<n>.recorded に残す。
set -u
dir="$FAKE_CLAUDE_DIR"
mkdir -p "$dir/calls"
n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$dir/count"
printf '%s\n' "$@" > "$dir/calls/$n.argv"
cat > "$dir/calls/$n.stdin"
sid=''
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CLAUDE_EVENTS:-}" ]; then
  if grep -q "\"session_id\":\"$sid\"" "$FAKE_CLAUDE_EVENTS" 2>/dev/null; then echo recorded; else echo missing; fi > "$dir/calls/$n.recorded"
fi
if [ -e "$dir/responses/$n.sleep" ]; then
  echo $$ >> "$dir/pids"
  sleep 60 &
  wait
  exit 0
fi
resp="$dir/responses/$n"
[ -f "$resp" ] || resp="$dir/responses/default"
code=$(head -n 1 "$resp")
tail -n +2 "$resp" | sed "s/@SID@/$sid/g"
exit "$code"
