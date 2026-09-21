#!/bin/bash
# test-codex-review-runner.sh
# codex-review-runner.sh のCLI・sandbox・schema・fail-closed契約を検証する。

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
RUNNER="${REPO_ROOT}/scripts/codex-review-runner.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()
WORK_DIR="$(mktemp -d)"

cleanup() {
  [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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

assert_contains() {
  local description="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok - ${description}"
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("$description")
      echo "  NG - ${description}"
      echo "       expected to contain: ${needle}"
      echo "       actual:              ${haystack}"
      ;;
  esac
}

FAKE_BIN="${WORK_DIR}/bin"
TARGET_REPO="${WORK_DIR}/repo"
mkdir -p "$FAKE_BIN" "$TARGET_REPO"
git -C "$TARGET_REPO" init -q

DIFF_FILE="${WORK_DIR}/review.diff"
ISSUE_FILE="${WORK_DIR}/issue.json"
CONTRACT_FILE="${TARGET_REPO}/contract.md"
printf 'diff --git a/a b/a\n' >"$DIFF_FILE"
printf '{"number":200,"body":"acceptance"}\n' >"$ISSUE_FILE"
printf '# contract\n' >"$CONTRACT_FILE"

# fake codex: 引数・promptを記録し、FAKE_CODEX_FINALを -o のパスへコピーする。
cat >"${FAKE_BIN}/codex" <<'EOF'
#!/bin/bash
set -u
if [ "${1:-}" = "--version" ]; then
  echo "codex-cli test"
  exit 0
fi
printf '%s\n' "$@" >"${FAKE_CODEX_ARGS_FILE}"
cat >"${FAKE_CODEX_PROMPT_FILE}"
if [ -n "${FAKE_CODEX_STDERR:-}" ]; then
  printf '%s\n' "$FAKE_CODEX_STDERR" >&2
fi
if [ -n "${FAKE_CODEX_SLEEP:-}" ]; then
  sleep "$FAKE_CODEX_SLEEP"
fi
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
if [ -n "${FAKE_CODEX_FINAL:-}" ] && [ -n "$out" ]; then
  cp "$FAKE_CODEX_FINAL" "$out"
fi
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":101,"output_tokens":17}}'
exit "${FAKE_CODEX_EXIT:-0}"
EOF
chmod +x "${FAKE_BIN}/codex"

ARGS_FILE="${WORK_DIR}/args.txt"
PROMPT_FILE="${WORK_DIR}/prompt.txt"
export FAKE_CODEX_ARGS_FILE="$ARGS_FILE"
export FAKE_CODEX_PROMPT_FILE="$PROMPT_FILE"

write_complete_result() {
  local path="$1"
  cat >"$path" <<'EOF'
{
  "status": "complete",
  "lanes": [
    {"name":"code","status":"complete","error":null},
    {"name":"design","status":"complete","error":null}
  ],
  "verifierStatus": {"status":"not_required","attempted":0,"completed":0,"failed":0},
  "findings": [],
  "failedLanes": [],
  "summary": "no findings"
}
EOF
}

echo "=== test: complete capsule ==="
COMPLETE_RESULT="${WORK_DIR}/complete.json"
write_complete_result "$COMPLETE_RESULT"
export FAKE_CODEX_FINAL="$COMPLETE_RESULT"
export FAKE_CODEX_EXIT=0

OUT="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" \
  --repo "$TARGET_REPO" \
  --diff-file "$DIFF_FILE" \
  --base main \
  --issue-file "$ISSUE_FILE" \
  --contract "$CONTRACT_FILE" \
  --model test-model \
  --effort high)"
RC=$?

assert_eq "completeはexit 0" "0" "$RC"
assert_eq "resultはcomplete" "complete" "$(jq -r '.result' <<<"$OUT")"
assert_eq "usageをeventsから抽出" "101" "$(jq -r '.metrics.usage.input_tokens' <<<"$OUT")"
assert_eq "capsule呼び出し数を計測" "1" "$(jq -r '.metrics.capsule_calls' <<<"$OUT")"
assert_eq "agent呼び出し観測不能はnull" "null" "$(jq -r '.metrics.agent_calls' <<<"$OUT")"
assert_eq "agent自己申告数を分離" "2" "$(jq -r '.metrics.agent_calls_declared' <<<"$OUT")"
assert_eq "schema検証成功を計測" "true" "$(jq -r '.metrics.schema_valid' <<<"$OUT")"
ARGS="$(cat "$ARGS_FILE")"
assert_contains "read-only sandboxを明示" "read-only" "$ARGS"
assert_contains "output schemaを明示" "--output-schema" "$ARGS"
assert_contains "対象repoを-Cで指定" "$TARGET_REPO" "$ARGS"
assert_contains "model overrideを透過" "test-model" "$ARGS"
assert_contains "effort overrideを透過" 'reasoning.effort="high"' "$ARGS"

PROMPT="$(cat "$PROMPT_FILE")"
assert_contains "code reviewer定義を直接参照" "agents/code-reviewer.md" "$PROMPT"
assert_contains "design reviewer定義を直接参照" "agents/design-reviewer.md" "$PROMPT"
assert_contains "finding verifier定義を直接参照" "agents/finding-verifier.md" "$PROMPT"
assert_contains "diff snapshotをパスで渡す" "$DIFF_FILE" "$PROMPT"
assert_contains "Issue contextをパスで渡す" "$ISSUE_FILE" "$PROMPT"
assert_contains "既存consumer追跡を要求" "existing consumers" "$PROMPT"

echo "=== test: partial capsule ==="
PARTIAL_RESULT="${WORK_DIR}/partial.json"
cat >"$PARTIAL_RESULT" <<'EOF'
{
  "status": "complete",
  "lanes": [
    {"name":"code","status":"complete","error":null},
    {"name":"design","status":"failed","error":"agent unavailable"}
  ],
  "verifierStatus": {"status":"not_required","attempted":0,"completed":0,"failed":0},
  "findings": [],
  "failedLanes": ["design"],
  "summary": "design lane failed"
}
EOF
export FAKE_CODEX_FINAL="$PARTIAL_RESULT"
OUT="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE")"
RC=$?
assert_eq "partialはexit 3" "3" "$RC"
assert_eq "partialをcompleteへ昇格しない" "partial" "$(jq -r '.result' <<<"$OUT")"
assert_eq "inner review.statusもpartialへ正規化" "partial" "$(jq -r '.review.status' <<<"$OUT")"
assert_eq "failed laneをerrorsへ残す" "lane_design_failed" "$(jq -r '.errors[0].code' <<<"$OUT")"

echo "=== test: required lane欠損はfailed ==="
MISSING_LANE_RESULT="${WORK_DIR}/missing-lane.json"
cat >"$MISSING_LANE_RESULT" <<'EOF'
{
  "status": "complete",
  "lanes": [
    {"name":"code","status":"complete","error":null},
    {"name":"code","status":"complete","error":null}
  ],
  "verifierStatus": {"status":"not_required","attempted":0,"completed":0,"failed":0},
  "findings": [],
  "failedLanes": [],
  "summary": "invalid"
}
EOF
export FAKE_CODEX_FINAL="$MISSING_LANE_RESULT"
OUT="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE")"
RC=$?
assert_eq "required lane欠損はexit 4" "4" "$RC"
assert_eq "required lane欠損はfailed JSON" "failed" "$(jq -r '.result' <<<"$OUT")"
assert_eq "契約違反を明示" "invalid_capsule_contract" "$(jq -r '.errors[0].code' <<<"$OUT")"

echo "=== test: Codex terminal failure ==="
export FAKE_CODEX_FINAL="$COMPLETE_RESULT"
export FAKE_CODEX_EXIT=7
export FAKE_CODEX_STDERR="authentication failed"
OUT="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE")"
RC=$?
assert_eq "codex失敗はexit 4" "4" "$RC"
assert_eq "codex失敗を指摘ゼロにしない" "failed" "$(jq -r '.result' <<<"$OUT")"
assert_eq "codex exitを保持" "7" "$(jq -r '.metrics.codex_exit_code' <<<"$OUT")"
assert_contains "codex stderr診断を保持" "authentication failed" "$(jq -r '.errors[0].message' <<<"$OUT")"
unset FAKE_CODEX_STDERR

echo "=== test: hard timeout ==="
export FAKE_CODEX_FINAL="$COMPLETE_RESULT"
export FAKE_CODEX_EXIT=0
export FAKE_CODEX_SLEEP=2
export FAKE_CODEX_STDERR="timeout diagnostic"
OUT="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE" --timeout 1)"
RC=$?
assert_eq "timeoutはexit 4" "4" "$RC"
assert_eq "timeout理由を構造化" "codex_timeout" "$(jq -r '.errors[0].code' <<<"$OUT")"
assert_eq "timeoutはterminal failure" "true" "$(jq -r '.metrics.terminal_failure' <<<"$OUT")"
assert_contains "timeoutもstderr診断を保持" "timeout diagnostic" "$(jq -r '.errors[0].message' <<<"$OUT")"
unset FAKE_CODEX_SLEEP
unset FAKE_CODEX_STDERR

echo "=== test: 入力検証 ==="
PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" >/dev/null 2>&1
assert_eq "diff-file未指定はexit 64" "64" "$?"

PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "${WORK_DIR}/missing" >/dev/null 2>&1
assert_eq "diff-file欠損はexit 66" "66" "$?"

PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE" --contract "${WORK_DIR}/missing" >/dev/null 2>&1
assert_eq "contract欠損はexit 66" "66" "$?"

PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE" --timeout 0 >/dev/null 2>&1
assert_eq "timeoutは正の整数のみ" "64" "$?"

PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE" --effort 'high",sandbox="danger' >/dev/null 2>&1
assert_eq "effortへのconfig注入を拒否" "64" "$?"

echo "=== test: verifier後のverdict変更を照合 ==="
VERIFIED_RESULT="${WORK_DIR}/verified.json"
cat >"$VERIFIED_RESULT" <<'EOF'
{
  "status": "complete",
  "lanes": [
    {"name":"code","status":"complete","error":null},
    {"name":"design","status":"complete","error":null}
  ],
  "verifierStatus": {"status":"complete","attempted":1,"completed":1,"failed":0},
  "findings": [{
    "id":"f1","file":"a","line":1,"severity":"high","claim":"c","evidence":"e",
    "initialVerdict":"plausible","verdict":"confirmed","sourceLane":"code","verificationRequired":true,
    "verification":{"status":"complete","verdict":"confirmed","reason":"verified"}
  }],
  "failedLanes": [],
  "summary": "verified"
}
EOF
export FAKE_CODEX_FINAL="$VERIFIED_RESULT"
export FAKE_CODEX_EXIT=0
OUT="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE")"
RC=$?
assert_eq "verifier後にconfirmedでもcomplete" "0" "$RC"
assert_eq "verifierをagent自己申告数へ計上" "3" "$(jq -r '.metrics.agent_calls_declared' <<<"$OUT")"

assert_required_omission_rejected() {
  local description="$1" jq_filter="$2"
  local invalid_file="${WORK_DIR}/missing-required.json" output rc
  jq "$jq_filter" "$VERIFIED_RESULT" >"$invalid_file"
  export FAKE_CODEX_FINAL="$invalid_file"
  output="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE")"
  rc=$?
  assert_eq "$description" "4" "$rc"
  assert_eq "${description}: 契約違反を明示" "invalid_capsule_contract" "$(jq -r '.errors[0].code' <<<"$output")"
}

echo "=== test: nullable必須fieldの欠落を拒否 ==="
assert_required_omission_rejected "lane.error欠落を拒否" 'del(.lanes[0].error)'
assert_required_omission_rejected "finding.line欠落を拒否" 'del(.findings[0].line)'
assert_required_omission_rejected "verification.verdict欠落を拒否" 'del(.findings[0].verification.verdict)'
assert_required_omission_rejected "verification.reason欠落を拒否" 'del(.findings[0].verification.reason)'

echo "=== test: verifier集計不整合はfailed ==="
INVALID_VERIFIER_RESULT="${WORK_DIR}/invalid-verifier.json"
cat >"$INVALID_VERIFIER_RESULT" <<'EOF'
{
  "status": "complete",
  "lanes": [
    {"name":"code","status":"complete","error":null},
    {"name":"design","status":"complete","error":null}
  ],
  "verifierStatus": {"status":"not_required","attempted":0,"completed":0,"failed":0},
  "findings": [{
    "id":"f1","file":"a","line":1,"severity":"high","claim":"c","evidence":"e",
    "initialVerdict":"plausible","verdict":"confirmed","sourceLane":"code","verificationRequired":true,
    "verification":{"status":"failed","verdict":"uncertain","reason":"agent failed"}
  }],
  "failedLanes": [],
  "summary": "invalid verifier accounting"
}
EOF
export FAKE_CODEX_FINAL="$INVALID_VERIFIER_RESULT"
export FAKE_CODEX_EXIT=0
OUT="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE")"
RC=$?
assert_eq "verifier集計不整合はexit 4" "4" "$RC"
assert_eq "verifier集計不整合は契約違反" "invalid_capsule_contract" "$(jq -r '.errors[0].code' <<<"$OUT")"

echo "=== test: high/plausible verifier迂回を拒否 ==="
BYPASS_RESULT="${WORK_DIR}/bypass.json"
cat >"$BYPASS_RESULT" <<'EOF'
{
  "status": "complete",
  "lanes": [
    {"name":"code","status":"complete","error":null},
    {"name":"design","status":"complete","error":null}
  ],
  "verifierStatus": {"status":"not_required","attempted":0,"completed":0,"failed":0},
  "findings": [{
    "id":"f1","file":"a","line":1,"severity":"high","claim":"c","evidence":"e",
    "initialVerdict":"plausible","verdict":"plausible","sourceLane":"code","verificationRequired":false,
    "verification":{"status":"not_required","verdict":null,"reason":null}
  }],
  "failedLanes": [],
  "summary": "attempted bypass"
}
EOF
export FAKE_CODEX_FINAL="$BYPASS_RESULT"
OUT="$(PATH="${FAKE_BIN}:$PATH" "$RUNNER" --repo "$TARGET_REPO" --diff-file "$DIFF_FILE")"
RC=$?
assert_eq "high/plausible迂回はexit 4" "4" "$RC"
assert_eq "high/plausible迂回は契約違反" "invalid_capsule_contract" "$(jq -r '.errors[0].code' <<<"$OUT")"

echo ""
echo "=== 結果 ==="
echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "失敗したテスト:"
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi

echo "すべてのテストが成功しました。"
