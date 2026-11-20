#!/bin/bash
# テスト用: 衝突して止まっているマージを、--mode に従って終える（sync の「衝突を直す段」の代わり）。
#   ok    衝突のファイルを直して git add し、git commit --no-edit でマージを終える
#   extra ok と同じに終えた後、別のコミットを足す（取り込みのコミットの外に変更を足した）
#   none  何もしない（マージの途中のまま）
set -eu
mode=ok
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
done
case "$mode" in
  ok | extra)
    echo resolved > conflict.txt
    git add conflict.txt
    git commit -q --no-edit
    if [ "$mode" = extra ]; then
      echo extra > extra.txt
      git add extra.txt
      git commit -q -m "extra"
    fi ;;
  none) ;;
  *) echo "unknown mode $mode" >&2; exit 64 ;;
esac
echo '{"outcome":"pass"}'
