#!/bin/bash
# resolve-ticket.sh --issue <番号> [--base <ブランチ>]
#
# ticket ワークフローの最初のステップ（docs/harness-runtime-design.md §3.3・§3.4。/impl の「base の決定」I2・I3 を切り出したもの）。
#   1. gh issue view で Issue を読む
#   2. base を決める: --base ＞ Issue 本文の `Base: <ブランチ>` 行 ＞ リポジトリの既定ブランチ
#   3. base が既定ブランチ以外（統合ブランチ）なら、remote（origin）に在るかを確かめる
#
# stdout に JSON を 1 つ出す（schemas/resolve-ticket.json）。outcome は ok | base_missing。
#   base_missing: 統合ブランチが remote に無い・Base 行の値がブランチ名として不正・Base 行が食い違う。message に作り方を載せる
# gh・git の失敗（ネットワーク・認証・Issue が無い）は stderr に理由を出して非 0 で終わる（runtime は step_error にする）。
# gh と git は PATH のものを使う。

set -u

issue=""
base_in=""
base_given=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="${2:-}"; shift 2 ;;
    --base) base_in="${2:-}"; base_given=true; shift 2 ;;
    *) echo "Error: unknown argument '$1' (usage: resolve-ticket.sh --issue <number> [--base <branch>])" >&2; exit 2 ;;
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

# valid_branch はブランチ名として受け付ける形か（空白・制御文字・`..`・先頭の `-`・末尾の `/` や `.lock` を拒否する）。
valid_branch() {
  local b="$1"
  [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$b" == -* || "$b" == */ || "$b" == *..* || "$b" == *.lock || "$b" == /* ]] && return 1
  return 0
}

# base_lines は本文から `Base: <値>` 行の値を列挙する（HTML コメントの中は読まない。前後の空白と ` を除く）。
base_lines() {
  tr -d '\r' | awk '
    {
      line = $0
      out = ""
      while (length(line) > 0) {
        if (incomment) {
          i = index(line, "-->")
          if (i == 0) { line = ""; break }
          line = substr(line, i + 3); incomment = 0
        } else {
          i = index(line, "<!--")
          if (i == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, i - 1); line = substr(line, i + 4); incomment = 1
        }
      }
      if (out ~ /^[ \t]*Base:[ \t]*/) {
        sub(/^[ \t]*Base:[ \t]*/, "", out)
        sub(/[ \t]+$/, "", out)
        gsub(/`/, "", out)
        print out
      }
    }'
}

if ! view="$(gh issue view "$issue" --json number,title,body,state)"; then
  echo "Error: gh issue view ${issue} failed" >&2
  exit 1
fi
title="$(jq -r '.title // ""' <<<"$view")"
state="$(jq -r '.state // ""' <<<"$view")"
body="$(jq -r '.body // ""' <<<"$view")"

if ! default_branch="$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')" || [ -z "$default_branch" ]; then
  echo "Error: cannot read the repository's default branch (gh repo view)" >&2
  exit 1
fi

outcome="ok"
message=""
if [ "$base_given" = true ]; then
  base="$base_in"
  source="input"
else
  lines="$(printf '%s\n' "$body" | base_lines | awk 'NF' | sort -u)"
  count="$(printf '%s' "$lines" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    base="$default_branch"
    source="default"
  else
    base="$(printf '%s\n' "$lines" | head -n 1)"
    source="issue"
    if [ "$count" -gt 1 ]; then
      outcome="base_missing"
      message="Issue #${issue} の本文に値の異なる Base: 行が ${count} 個ある（$(printf '%s' "$lines" | tr '\n' ' ')）。どれが base かを決められないので止まる。Base: 行を 1 つにしてから再実行する"
    fi
  fi
fi

if [ "$outcome" = "ok" ] && ! valid_branch "$base"; then
  outcome="base_missing"
  message="base '${base}'（${source}）はブランチ名として受け付けられない。Issue の Base: 行か --base を直してから再実行する"
fi

if [ "$base" = "$default_branch" ]; then
  base_kind="default"
else
  base_kind="integration"
fi

if [ "$outcome" = "ok" ] && [ "$base_kind" = "integration" ]; then
  git ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) ;;
    2)
      outcome="base_missing"
      message="統合ブランチ ${base} が remote（origin）に存在しない。先に作成してから再実行する: git checkout -b ${base} origin/${default_branch} && git push -u origin ${base}"
      ;;
    *)
      echo "Error: git ls-remote origin ${base} failed (exit ${rc})" >&2
      exit 1
      ;;
  esac
fi

jq -n \
  --arg outcome "$outcome" \
  --argjson issue "$issue" \
  --arg title "$title" \
  --arg state "$state" \
  --arg base "$base" \
  --arg base_kind "$base_kind" \
  --arg base_source "$source" \
  --arg default_branch "$default_branch" \
  --arg message "$message" \
  '{outcome: $outcome, issue: $issue, title: $title, state: $state, base: $base, base_kind: $base_kind,
    base_source: $base_source, default_branch: $default_branch, message: $message}'
