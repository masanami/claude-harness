#!/bin/bash
# test-runtime-agent-structured-output.sh
# runtime の llm ステップが `agent:` で指定するエージェントが、型付きの出力を返すツール
# StructuredOutput を使えることを固定する（#282）。
#
# runtime は llm ステップを `claude -p --json-schema <schema> --agent <agent>` で起動する
# （runtime/internal/engine/llm.go）。エージェントの frontmatter の tools は許可リストで、
# StructuredOutput が無いと result に structured_output が付かず、ステップは invalid_output で終わる。
# runtime 側の --allowedTools では足せない（docs/harness-runtime-shadow.md の実測）。
#   (A-0) 判定器の自己検査（tools に無い・部分一致だけ・tools 行が無い・frontmatter を読めない・在る の 5 通り）
#   (A-1) runtime/workflows/*.yaml から agent: を 1 件以上拾える（拾えないのを pass にしない）
#   (A-2) 拾った agent がすべて plugin/agents/<name>.md に在り、StructuredOutput を使える
#
# 実行方法: bash scripts/tests/test-runtime-agent-structured-output.sh

set -u

AS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${AS_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

WORKFLOWS_DIR="${REPO_ROOT}/../runtime/workflows"
AGENTS_DIR="${REPO_ROOT}/agents"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected: ${expected}"
    echo "       actual:   ${actual}"
  fi
}

# エージェント定義が StructuredOutput を使えるなら true。frontmatter の tools 行のカンマ区切りの要素に
# 完全一致で在るときだけ true。frontmatter や tools 行が見つからなければ false（tools 行の無い定義が
# StructuredOutput を使えるかは実測していない。読めない定義を通過させない）。
allows_structured_output() {
  local file="$1" line item
  line="$(awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    infm && /^tools:/ { print; exit }
  ' "$file")"
  if [ -z "$line" ]; then
    echo "false"
    return
  fi
  IFS=',' read -r -a items <<< "${line#tools:}"
  for item in ${items+"${items[@]}"}; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [ "$item" = "StructuredOutput" ]; then
      echo "true"
      return
    fi
  done
  echo "false"
}

echo "=== (A-0) 判定器の自己検査 ==="
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-agent-so.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
printf -- '---\nname: a\ntools: Read, Bash\n---\nbody StructuredOutput\n' > "${FIXTURE_DIR}/missing.md"
printf -- '---\nname: b\ntools: Read, StructuredOutputs\n---\n' > "${FIXTURE_DIR}/partial.md"
printf -- '---\nname: c\nmodel: sonnet\n---\ntools: StructuredOutput\n' > "${FIXTURE_DIR}/notools.md"
printf -- '\n---\nname: e\ntools: StructuredOutput\n---\n' > "${FIXTURE_DIR}/nofm.md"
printf -- '---\nname: d\ntools: Read,StructuredOutput , Bash\n---\n' > "${FIXTURE_DIR}/present.md"
assert_eq "(A-0) tools に無ければ false（本文の語は数えない）" "false" "$(allows_structured_output "${FIXTURE_DIR}/missing.md")"
assert_eq "(A-0) 部分一致は数えない" "false" "$(allows_structured_output "${FIXTURE_DIR}/partial.md")"
assert_eq "(A-0) frontmatter に tools 行が無ければ false（本文の tools: は数えない）" "false" "$(allows_structured_output "${FIXTURE_DIR}/notools.md")"
assert_eq "(A-0) 1 行目が --- でなければ（frontmatter を読めなければ）false" "false" "$(allows_structured_output "${FIXTURE_DIR}/nofm.md")"
assert_eq "(A-0) 前後の空白を許して完全一致で数える" "true" "$(allows_structured_output "${FIXTURE_DIR}/present.md")"

echo "=== (A-1) runtime のワークフローから agent: を拾える ==="
# ブロック形式（`agent: x`）とフロー形式（`{ kind: llm, agent: x }`）の両方を拾う。コメントは先に落とす。
AGENTS="$(sed 's/#.*$//' "${WORKFLOWS_DIR}"/*.yaml \
  | grep -oE '(^|[{,[:space:]])agent:[[:space:]]*[^[:space:],}]+' \
  | sed -E 's/^.*agent:[[:space:]]*//; s/["'"'"']//g' | sort -u)"
assert_eq "(A-1) agent: が 1 件以上ある" "true" "$(if [ -n "$AGENTS" ]; then echo true; else echo false; fi)"

echo "=== (A-2) agent がすべて StructuredOutput を使える ==="
while IFS= read -r agent; do
  [ -n "$agent" ] || continue
  name="${agent#claude-harness:}"
  file="${AGENTS_DIR}/${name}.md"
  if [ "$name" = "$agent" ] || [ ! -f "$file" ]; then
    assert_eq "(A-2) ${agent}: plugin/agents/ に定義が在る" "true" "false"
    continue
  fi
  assert_eq "(A-2) ${agent}: tools が StructuredOutput を許す" "true" "$(allows_structured_output "$file")"
done <<< "$AGENTS"

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
