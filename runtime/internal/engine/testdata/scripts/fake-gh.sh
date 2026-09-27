#!/bin/bash
# テスト用の偽の gh（実際の gh を呼ばずに pull-request 種類・pr-state の観測・resolve-ticket・ci-wait を試す）。FAKE_GH_DIR の下で動く。
#   calls: 受け取った argv（1 呼び出し 1 行。引数は TAB 区切り）
#   issue view            → issue.json（無ければ exit 1）
#   repo view             → default-branch（無ければ main）
#   pr list               → pr-list（無ければ []）
#   pr create             → create.code があればその終了コードで失敗。--body-file の中身を body.<n>.md に写し、PR の URL を出す。
#                           以後の pr list が作った PR を返すよう pr-list を書く
#   pr view <n>           → pr-missing があれば exit 1。state は pr-state（無ければ OPEN）
#   pr checks             → checks.<n>（n 回目の呼び出し）、無ければ checks（無ければ []）
#   run view <id>         → 失敗ログの代わりの 1 行
set -u
dir="$FAKE_GH_DIR"
( IFS=$'\t'; printf '%s\n' "$*" ) >> "$dir/calls"
case "$1 ${2:-}" in
  "issue view")
    [ -f "$dir/issue.json" ] || { echo "fake gh: no issue.json" >&2; exit 1; }
    cat "$dir/issue.json" ;;
  "repo view")
    cat "$dir/default-branch" 2>/dev/null || echo main ;;
  "pr list")
    cat "$dir/pr-list" 2>/dev/null || echo '[]' ;;
  "pr create")
    if [ -f "$dir/create.code" ]; then echo "fake gh: create failed" >&2; exit "$(cat "$dir/create.code")"; fi
    n=$(( $(cat "$dir/create.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$dir/create.count"
    base='' body=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --base) base="$2"; shift 2 ;;
        --body-file) body="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cp "$body" "$dir/body.$n.md"
    num=$(cat "$dir/pr-number" 2>/dev/null || echo 7)
    printf '[{"number":%s,"url":"https://github.com/o/r/pull/%s","baseRefName":"%s"}]\n' "$num" "$num" "$base" > "$dir/pr-list"
    echo "https://github.com/o/r/pull/$num" ;;
  "pr view")
    [ -f "$dir/pr-missing" ] && { echo "fake gh: no pull requests found" >&2; exit 1; }
    state=$(cat "$dir/pr-state" 2>/dev/null || echo OPEN)
    printf '{"number":%s,"url":"https://github.com/o/r/pull/%s","state":"%s","mergedAt":null,"baseRefName":"main"}\n' "$3" "$3" "$state" ;;
  "pr checks")
    n=$(( $(cat "$dir/checks.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$dir/checks.count"
    if [ -f "$dir/checks.$n" ]; then cat "$dir/checks.$n"; else cat "$dir/checks" 2>/dev/null || echo '[]'; fi ;;
  "run view")
    echo "log of run $3: assertion failed in test_widget" ;;
  *)
    echo "fake gh: unsupported: $*" >&2; exit 1 ;;
esac
