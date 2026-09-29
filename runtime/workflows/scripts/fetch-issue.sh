#!/bin/bash
# fetch-issue.sh --issue <番号>
#
# conflict-predict-issue ワークフローの最初のステップ（Issue #288）。gh issue view で Issue のタイトルと本文を読み、
# stdout に JSON を 1 つ出す（schemas/fetch-issue.json）。読むだけで、Issue にも作業ツリーにも書かない。
# gh の失敗（ネットワーク・認証・Issue が無い）は stderr に理由を出して非 0 で終わる（runtime は step_error にする）。
# gh は PATH のものを使う。

set -u

issue=""
usage="usage: fetch-issue.sh --issue <number>"
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      if [ $# -lt 2 ]; then echo "Error: $1 needs a value ($usage)" >&2; exit 2; fi
      issue="$2"
      shift 2 ;;
    *) echo "Error: unknown argument '$1' ($usage)" >&2; exit 2 ;;
  esac
done

if ! [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --issue must be a positive integer, got '${issue}'" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but was not found in PATH" >&2
  exit 1
fi

if ! view="$(gh issue view "$issue" --json number,title,body,state)"; then
  echo "Error: gh issue view ${issue} failed" >&2
  exit 1
fi

jq -c --argjson issue "$issue" '{outcome: "ok", issue: $issue, title: (.title // ""), state: (.state // ""), body: (.body // "")}' <<<"$view"
