#!/bin/bash
# テスト用の偽の git（実際の git を呼ばずに workspace・pull-request 種類・resolve-ticket を試す）。FAKE_GIT_DIR の下で動く。
#   calls: 受け取った argv（1 呼び出し 1 行。引数は TAB 区切り。先頭にカレントディレクトリ）
#   rev-parse --show-toplevel         → カレントに .fake-not-git があれば exit 128、.fake-top があればその中身、無ければ pwd
#   rev-parse ... --git-common-dir    → カレントの .fake-common、無ければ /fake/common
#   rev-parse --abbrev-ref HEAD       → カレントの .fake-branch、無ければ feature/issue-7-x
#   rev-parse HEAD                    → 0123abcd
#   push                              → push.code があればその終了コード
#   ls-remote --exit-code --heads origin <b> → remote-branches に <b> の行があれば 0、無ければ 2（ls-remote.code があればその値）
set -u
dir="$FAKE_GIT_DIR"
( IFS=$'\t'; printf '%s\t%s\n' "$PWD" "$*" ) >> "$dir/calls"
case "$*" in
  "rev-parse --show-toplevel")
    [ -e .fake-not-git ] && { echo "fatal: not a git repository" >&2; exit 128; }
    if [ -f .fake-top ]; then cat .fake-top; else pwd; fi ;;
  "rev-parse --path-format=absolute --git-common-dir")
    cat .fake-common 2>/dev/null || echo /fake/common ;;
  "rev-parse --abbrev-ref HEAD")
    cat .fake-branch 2>/dev/null || echo feature/issue-7-x ;;
  "rev-parse HEAD")
    echo 0123abcd ;;
  push*)
    [ -f "$dir/push.code" ] && { echo "fake git: push rejected" >&2; exit "$(cat "$dir/push.code")"; }
    exit 0 ;;
  "ls-remote --exit-code --heads origin "*)
    [ -f "$dir/ls-remote.code" ] && exit "$(cat "$dir/ls-remote.code")"
    grep -qxF "$5" "$dir/remote-branches" 2>/dev/null && exit 0
    exit 2 ;;
  *)
    echo "fake git: unsupported: $*" >&2; exit 1 ;;
esac
