#!/bin/bash
# テスト用の偽の claude（predict-conflicts 用。並列に起動されるので、応答は起動順でなく Issue 番号で引く）。
# FAKE_CLAUDE_DIR の下で動く。stdin（プロンプト）の添付データの "issue": <n> を読み、
#   responses/<n> を応答にする: 1 行目が終了コード、2 行目以降が stdout（@SID@ は --session-id の値に置き換える）。
#   受け取った argv を calls/<n>.argv（1 行 1 引数）、stdin を calls/<n>.stdin、カレントディレクトリを calls/<n>.pwd に残す。
set -u
dir="$FAKE_CLAUDE_DIR"
mkdir -p "$dir/calls"
stdin="$(cat)"
n="$(printf '%s\n' "$stdin" | grep -o '"issue": [0-9]*' | head -n 1 | tr -dc '0-9')"
[ -n "$n" ] || { echo "fake claude: no issue in the prompt" >&2; exit 1; }
printf '%s\n' "$@" > "$dir/calls/$n.argv"
printf '%s\n' "$stdin" > "$dir/calls/$n.stdin"
pwd -P > "$dir/calls/$n.pwd"
sid=''
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
resp="$dir/responses/$n"
[ -f "$resp" ] || { echo "fake claude: no response for issue $n" >&2; exit 1; }
code=$(head -n 1 "$resp")
tail -n +2 "$resp" | sed "s/@SID@/$sid/g"
exit "$code"
