#!/bin/bash
# テスト用の偽の gh（実際の gh を呼ばずに pull-request 種類・pr-state の観測・resolve-ticket・ci-wait を試す）。FAKE_GH_DIR の下で動く。
#   calls: 受け取った argv（1 呼び出し 1 行。引数は TAB 区切り）
#   issue view            → issue.json（無ければ exit 1）
#   repo view             → default-branch（無ければ main）。--json に nameWithOwner があれば（reflect の adopt）、repo-view.json の中身
#                           （無ければ o/r・https://github.com/o/r・default-branch から作る）
#   pr view <url> --json ...isCrossRepository...（reflect の adopt） → adopt.json の中身（無ければ exit 1）
#   pr list               → pr-list（無ければ []）
#   pr create             → create.code があればその終了コードで失敗。--body-file の中身を body.<n>.md に写し、PR の URL を出す。
#                           以後の pr list が作った PR を返すよう pr-list を書く
#   pr view <n>           → pr-missing があれば exit 1。pr-view.<n 回目の呼び出し> か pr-view.json があればその中身（land の試験用に、
#                           state・headRefOid・baseRefName・mergeCommit・isDraft を持つ JSON）。無ければ state は pr-state（無ければ OPEN）
#                           pr-head-ref があれば、その pr-view.json の headRefOid を、pr-head-ref の参照（1 行目: git ディレクトリ、
#                           2 行目: 参照）の先頭に置き換える
#   pr merge <n> ...      → merge.code があればその終了コードで失敗（標準エラーに merge.err の中身）。通ったら merge.then の中身を
#                           pr-view.json に写し（入った後の PR を見せる）、merge.kill があれば呼び出し元（harness）を SIGKILL する
#   pr checks             → checks.<n>（n 回目の呼び出し）、無ければ checks（無ければ []）。checks.none があれば、実物の gh が
#                           チェック 0 件のときの振る舞い（標準出力は空、標準エラーに "no checks reported"、終了コード 1）
#   run view <id>         → 失敗ログの代わりの 1 行（run-log-empty があれば何も出さない＝CI が実行されずに失敗した）
set -u
dir="$FAKE_GH_DIR"
( IFS=$'\t'; printf '%s\n' "$*" ) >> "$dir/calls"
case "$1 ${2:-}" in
  "issue view")
    [ -f "$dir/issue.json" ] || { echo "fake gh: no issue.json" >&2; exit 1; }
    cat "$dir/issue.json" ;;
  "repo view")
    case "$*" in
      *nameWithOwner*)
        if [ -f "$dir/repo-view.json" ]; then cat "$dir/repo-view.json"; else
          printf '{"nameWithOwner":"o/r","url":"https://github.com/o/r","defaultBranchRef":{"name":"%s"}}\n' "$(cat "$dir/default-branch" 2>/dev/null || echo main)"
        fi ;;
      *) cat "$dir/default-branch" 2>/dev/null || echo main ;;
    esac ;;
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
    case "$*" in
      *isCrossRepository*)
        [ -f "$dir/adopt.json" ] || { echo "fake gh: no adopt.json" >&2; exit 1; }
        cat "$dir/adopt.json"; exit 0 ;;
    esac
    [ -f "$dir/pr-missing" ] && { echo "fake gh: no pull requests found" >&2; exit 1; }
    n=$(( $(cat "$dir/pr-view.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$dir/pr-view.count"
    if [ -f "$dir/pr-view.$n" ]; then cat "$dir/pr-view.$n"; exit 0; fi
    if [ -f "$dir/pr-view.json" ]; then
      # pr-head-ref（1 行目: git ディレクトリ、2 行目: 参照）があれば、headRefOid をその参照の先頭にする（実物の PR の先頭は、
      # harness が push した後は新しい先頭を指す）。
      if [ -f "$dir/pr-head-ref" ]; then
        h=$(git --git-dir="$(sed -n 1p "$dir/pr-head-ref")" rev-parse "$(sed -n 2p "$dir/pr-head-ref")")
        sed "s/\"headRefOid\":\"[^\"]*\"/\"headRefOid\":\"$h\"/" "$dir/pr-view.json"
      else
        cat "$dir/pr-view.json"
      fi
      exit 0
    fi
    state=$(cat "$dir/pr-state" 2>/dev/null || echo OPEN)
    printf '{"number":%s,"url":"https://github.com/o/r/pull/%s","state":"%s","mergedAt":null,"baseRefName":"main"}\n' "$3" "$3" "$state" ;;
  "pr merge")
    if [ -f "$dir/merge.code" ]; then cat "$dir/merge.err" >&2 2>/dev/null; exit "$(cat "$dir/merge.code")"; fi
    [ -f "$dir/merge.then" ] && cp "$dir/merge.then" "$dir/pr-view.json"
    [ -f "$dir/merge.kill" ] && kill -9 "$PPID"
    exit 0 ;;
  "pr checks")
    if [ -f "$dir/checks.none" ]; then echo "no checks reported on the 'feature/x' branch" >&2; exit 1; fi
    n=$(( $(cat "$dir/checks.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$dir/checks.count"
    if [ -f "$dir/checks.$n" ]; then cat "$dir/checks.$n"; else cat "$dir/checks" 2>/dev/null || echo '[]'; fi ;;
  "run view")
    [ -f "$dir/run-log-empty" ] && exit 0
    echo "log of run $3: assertion failed in test_widget" ;;
  *)
    echo "fake gh: unsupported: $*" >&2; exit 1 ;;
esac
