#!/bin/bash
# quality-gate.sh --base <ブランチ>
#
# ticket ワークフローの quality（#326）。push するコミットに対して品質ゲートを機械で回し、結果をコミットの SHA と一緒に返す。
#   1. 作業ツリーに未コミットの変更が無いことを確かめ、HEAD を控える（検査したものとコミットを一致させる）
#   2. 宣言 .claude-harness/quality-gate.json を PR の宛先（origin/<base>）から読む。作業ツリーからは読まない
#      （実装した子が同じ PR の中で宣言を書き換えてゲートを弱められないようにするため。宣言を足す PR 自身では効かない）
#   3. 宣言の lint・typecheck・test を plugin/scripts/quality-check-runner.sh に --auto-fix なしで渡す（コミットの後に作業ツリーを変えない）
#   4. 実行の後も HEAD と作業ツリーが変わっていないことを確かめる
#
# 宣言の形: {"lint": "<コマンド>", "typecheck": "<コマンド>", "test": "<コマンド>"}（どれも省略可。値は runner と同じ約束:
# シェルを介さず、plugin/scripts/config/command-allowlist.txt に載った実行系だけ）。このリポジトリでは {"test": "make check"}。
#
# stdout に JSON を 1 つ出す（schemas/quality-gate.json）。result は pass | fail | undeclared。ゲートが落ちても exit 0。
#   fail: ゲートが落ちた。failure_excerpt に、落ちたゲートの出力の末尾（4000 バイトまで）を載せる（fix へ渡す）
#   undeclared: 宣言が無い・JSON として読めない・知らないキーや文字列でない値がある・ゲートが 1 つも走らない（runner の exit 3）・
#               コマンドの形が拒否された（runner の exit 4）。message に直し方を載せる
# 実行のエラー（未コミットの変更・base を取得できない・runner が JSON を返さない・実行中に HEAD や作業ツリーが変わった）は
# stderr に理由を出して非 0 で終わる（runtime は step_error にする。fail-closed）。
# runner の置き場は runtime が HARNESS_SCRIPTS_DIR で渡す。git は PATH のものを使う。

set -u

decl_path=".claude-harness/quality-gate.json"
excerpt_bytes=4000
base=""
usage="usage: quality-gate.sh --base <branch>"
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      if [ $# -lt 2 ]; then echo "Error: $1 needs a value ($usage)" >&2; exit 2; fi
      base="$2"; shift 2 ;;
    *) echo "Error: unknown argument '$1' ($usage)" >&2; exit 2 ;;
  esac
done
if [ -z "$base" ] || [[ "$base" == -* ]] || ! [[ "$base" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: --base must be a branch name, got '${base}'" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but was not found in PATH" >&2
  exit 1
fi
runner="${HARNESS_SCRIPTS_DIR:-}/quality-check-runner.sh"
if [ -z "${HARNESS_SCRIPTS_DIR:-}" ] || [ ! -f "$runner" ]; then
  echo "Error: quality-check-runner.sh not found (HARNESS_SCRIPTS_DIR='${HARNESS_SCRIPTS_DIR:-}')" >&2
  exit 1
fi

# sha256 は stdin の sha256（macOS は shasum、Linux は sha256sum）。
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# failed_output は runner の stderr から、落ちたゲート（gates.<名前>.status が fail）の区間だけを取り出す。runner はゲートごとに
# `--- <名前>: <コマンド> ---` から `--- <名前> exit: <N> ---` までに出力を書き、1 つが落ちても残りのゲートを実行するので、
# 末尾だけを取ると、後に通ったゲートの出力で落ちたゲートの出力が押し出される。区間が見つからなければ stderr 全体を返す。
failed_output() {
  local gates_json="$1" file="$2" names
  names="$(jq -r '.gates | to_entries[] | select(.value.status == "fail") | .key' <<<"$gates_json" | tr '\n' ' ')"
  local out
  out="$(awk -v names=" ${names}" '
    /^--- [a-z]+: / { label = substr($2, 1, length($2) - 1); inside = (index(names, " " label " ") > 0) }
    inside { print }
    /^--- [a-z]+ exit: [0-9]+ ---$/ { inside = 0 }
  ' "$file")"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    cat "$file"
  fi
}

# tree_state は HEAD と、未コミットの変更（追跡外のファイルを含む。.gitignore のものは除く）の一覧。
tree_state() {
  git rev-parse HEAD && git status --porcelain --untracked-files=all
}

head="$(git rev-parse --verify -q HEAD)" || { echo "Error: cannot read HEAD in $(pwd)" >&2; exit 1; }
before="$(tree_state)" || { echo "Error: cannot read the working tree state" >&2; exit 1; }
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "Error: the working tree has uncommitted changes; the quality gate checks a commit, so commit them first:" >&2
  git status --short --untracked-files=all >&2
  exit 1
fi

# 宣言は PR の宛先の最新から読む（remote の base を取り直す。取れなければ古い版で黙って続けない）。
ref="refs/remotes/origin/${base}"
if ! git fetch -q origin "+refs/heads/${base}:${ref}" >&2; then
  echo "Error: cannot fetch the base '${base}' from origin" >&2
  exit 1
fi
base_commit="$(git rev-parse --verify -q "${ref}^{commit}")" || { echo "Error: ${ref} is not a commit" >&2; exit 1; }

emit() {
  # emit <result> <decl_sha256> <gates JSON または null> <failure_excerpt> <message>
  jq -n --arg result "$1" --arg sha "$head" --arg base "$base" \
    --arg path "$decl_path" --arg ref "origin/${base}" --arg commit "$base_commit" --arg dsha "$2" \
    --argjson gates "$3" --arg excerpt "$4" --arg message "$5" \
    '{result: $result, commit_sha: $sha, base: $base,
      declaration: {path: $path, ref: $ref, commit: $commit, sha256: $dsha},
      gates: $gates, failure_excerpt: $excerpt, message: $message}'
}

how_to="宣言を置く（例: {\"test\": \"make check\"}。値はシェルを介さずに実行され、plugin/scripts/config/command-allowlist.txt に載った実行系だけが通る）か、pre-commit 等で同じゲートが既に回るなら、ワークフローの上書き（.claude-harness/overrides/ticket.yaml）で quality を省く（docs/harness-runtime-overrides.md §5.2）。宣言は PR の宛先から読むので、宣言を足すコミットを先に ${base} へ入れてから再実行する"

if ! git cat-file -e "${base_commit}:${decl_path}" 2>/dev/null; then
  emit undeclared "" null "" "品質ゲートのコマンドの宣言 ${decl_path} が PR の宛先 origin/${base}（${base_commit}）に無い。${how_to}"
  exit 0
fi
decl="$(git cat-file blob "${base_commit}:${decl_path}")" || { echo "Error: cannot read ${decl_path} at ${base_commit}" >&2; exit 1; }
decl_sha="$(git cat-file blob "${base_commit}:${decl_path}" | sha256)"
if ! jq -e 'type == "object" and ((keys - ["lint", "typecheck", "test"]) | length == 0) and all(.[]; type == "string")' <<<"$decl" >/dev/null 2>&1; then
  emit undeclared "$decl_sha" null "" "origin/${base}（${base_commit}）の ${decl_path} が宣言の形になっていない（JSON のオブジェクトで、キーは lint・typecheck・test、値は文字列だけ）。${how_to}"
  exit 0
fi

args=()
for gate in lint typecheck test; do
  cmd="$(jq -r --arg g "$gate" '.[$g] // ""' <<<"$decl")"
  if [ -n "$cmd" ]; then
    args+=("--${gate}" "$cmd")
  fi
done

errf="$(mktemp "${TMPDIR:-/tmp}/quality-gate.XXXXXX")" || { echo "Error: cannot create a temporary file" >&2; exit 1; }
trap 'rm -f "$errf"' EXIT
out="$(bash "$runner" ${args[@]+"${args[@]}"} 2>"$errf")"
rc=$?
cat "$errf" >&2

after="$(tree_state)" || { echo "Error: cannot read the working tree state after the gates" >&2; exit 1; }
if [ "$after" != "$before" ]; then
  echo "Error: the quality gates changed HEAD or the working tree (before: ${head}); the result would not belong to the commit:" >&2
  git status --short --untracked-files=all >&2
  exit 1
fi

gates="null"
if [ -n "$out" ] && jq -e 'type == "object" and has("result")' <<<"$out" >/dev/null 2>&1; then
  gates="$out"
fi
case "$rc" in
  0)
    if [ "$gates" = "null" ] || [ "$(jq -r '.result' <<<"$gates")" != "pass" ]; then
      echo "Error: quality-check-runner.sh exited 0 without a pass result" >&2
      exit 1
    fi
    emit pass "$decl_sha" "$gates" "" ""
    ;;
  1)
    if [ "$gates" = "null" ] || [ "$(jq -r '.result' <<<"$gates")" != "fail" ]; then
      echo "Error: quality-check-runner.sh exited 1 without a fail result (an argument error?)" >&2
      exit 1
    fi
    emit fail "$decl_sha" "$gates" "$(failed_output "$gates" "$errf" | tail -c "$excerpt_bytes")" ""
    ;;
  3)
    emit undeclared "$decl_sha" "$gates" "" "origin/${base}（${base_commit}）の ${decl_path} に、実行するゲート（lint・typecheck・test）が 1 つも無い。何も検査していない状態を通過とは扱わない。${how_to}"
    ;;
  4)
    emit undeclared "$decl_sha" null "" "origin/${base}（${base_commit}）の ${decl_path} のコマンドが拒否された: $(tail -c "$excerpt_bytes" "$errf" | tr '\n' ' ')。${how_to}"
    ;;
  *)
    echo "Error: quality-check-runner.sh failed (exit ${rc})" >&2
    exit 1
    ;;
esac
