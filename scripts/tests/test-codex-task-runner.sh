#!/bin/bash
# test-codex-task-runner.sh
# codex-task-runner.sh の CLI・sandbox 分岐・出力契約・決定的検査・fail-closed を検証する。
#
# Codex CLI は実行環境に無いことを前提とし、PATH 先頭へ fake codex を差し込んで検証する
# （scripts/tests/test-codex-review-runner.sh と同方式）。fake codex は引数と prompt を
# ファイルへ記録し、-o のパスへ固定の最終 JSON を置く。chore の作業ツリー照合は
# mktemp -d で作った一時 git リポジトリ上で実際に git を動かして検証する
# （モックでは git status の実効果を検証できない。scripts/README.md「テスト」節）。
#
# 実行方法: bash scripts/tests/test-codex-task-runner.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
RUNNER="${REPO_ROOT}/scripts/codex-task-runner.sh"

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

assert_not_contains() {
  local description="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("$description")
      echo "  NG - ${description}"
      echo "       expected NOT to contain: ${needle}"
      ;;
    *)
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok - ${description}"
      ;;
  esac
}

FAKE_BIN="${WORK_DIR}/bin"
TARGET_REPO="${WORK_DIR}/repo"
mkdir -p "$FAKE_BIN" "$TARGET_REPO"
git -C "$TARGET_REPO" init -q
git -C "$TARGET_REPO" config user.email test@example.com
git -C "$TARGET_REPO" config user.name test
printf 'seed\n' >"${TARGET_REPO}/seed.txt"
# ignored ファイルの照合を検証するため、seed コミットに .gitignore を含める
# （reset_target_repo が seed へ戻すので、後から作ると消える）。
printf 'ignored-dir/\n*.secret\n' >"${TARGET_REPO}/.gitignore"
git -C "$TARGET_REPO" add seed.txt .gitignore
git -C "$TARGET_REPO" commit -qm seed

# 作業ツリーを seed コミット直後の状態へ戻す。commit 検出テストが HEAD を動かすため、
# 各 chore テストの前に基準状態を揃える。テストが作った一時 repo だけを対象にする。
reset_target_repo() {
  git -C "$TARGET_REPO" reset -q --hard "$SEED_SHA"
  git -C "$TARGET_REPO" clean -qfdx
}
SEED_SHA="$(git -C "$TARGET_REPO" rev-parse HEAD)"

BRIEF_FILE="${WORK_DIR}/brief.md"
INPUT_FILE="${WORK_DIR}/input.md"
BRIEF_BODY_MARKER="INVESTIGATE-THE-SEED-FILE-BODY-MARKER"
INPUT_BODY_MARKER="REFERENCE-INPUT-BODY-MARKER"
printf '# brief\n%s\n' "$BRIEF_BODY_MARKER" >"$BRIEF_FILE"
printf '# reference\n%s\n' "$INPUT_BODY_MARKER" >"$INPUT_FILE"

# fake codex: 引数・prompt を記録し、FAKE_CODEX_FINAL を -o のパスへコピーする。
# FAKE_CODEX_TOUCH（空白区切り）が指定されていれば対象 repo にそのパスを作る（chore の疑似編集）。
# FAKE_CODEX_COMMIT が非空なら commit まで行う（commit 禁止契約の違反を再現する）。
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
if [ -n "${FAKE_CODEX_TOUCH:-}" ]; then
  for path in ${FAKE_CODEX_TOUCH}; do
    mkdir -p "$(dirname "${FAKE_CODEX_REPO}/${path}")"
    printf 'edited\n' >"${FAKE_CODEX_REPO}/${path}"
  done
fi
if [ -n "${FAKE_CODEX_COMMIT:-}" ]; then
  git -C "${FAKE_CODEX_REPO}" add -A >/dev/null 2>&1
  git -C "${FAKE_CODEX_REPO}" commit -qm "codex commit" >/dev/null 2>&1
fi
if [ -n "${FAKE_CODEX_FINAL:-}" ] && [ -n "$out" ]; then
  cp "$FAKE_CODEX_FINAL" "$out"
fi
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":42,"output_tokens":7}}'
exit "${FAKE_CODEX_EXIT:-0}"
EOF
chmod +x "${FAKE_BIN}/codex"

ARGS_FILE="${WORK_DIR}/args.txt"
PROMPT_FILE="${WORK_DIR}/prompt.txt"
export FAKE_CODEX_ARGS_FILE="$ARGS_FILE"
export FAKE_CODEX_PROMPT_FILE="$PROMPT_FILE"
export FAKE_CODEX_REPO="$TARGET_REPO"
export FAKE_CODEX_TOUCH=""
export FAKE_CODEX_COMMIT=""
export FAKE_CODEX_EXIT=0

run_runner() {
  PATH="${FAKE_BIN}:$PATH" "$RUNNER" "$@"
}

write_result() {
  local path="$1" status="$2" answers="$3" changes="$4"
  jq -n \
    --arg status "$status" \
    --argjson answers "$answers" \
    --argjson changes "$changes" \
    '{status: $status, summary: "s", answers: $answers, changes: $changes,
      assumptions: [], unverified: [], followups: []}' >"$path"
}

INVESTIGATE_RESULT="${WORK_DIR}/investigate.json"
write_result "$INVESTIGATE_RESULT" complete \
  '[{"question":"q","answer":"a","evidence":"seed.txt:1"}]' '[]'

echo "=== test: investigate モード（既定） ==="
export FAKE_CODEX_FINAL="$INVESTIGATE_RESULT"
OUT="$(run_runner \
  --mode investigate \
  --repo "$TARGET_REPO" \
  --brief-file "$BRIEF_FILE" \
  --input "$INPUT_FILE" \
  --model test-model \
  --effort high)"
RC=$?
assert_eq "completeはexit 0" "0" "$RC"
assert_eq "resultはcomplete" "complete" "$(jq -r '.result' <<<"$OUT")"
assert_eq "modeを返す" "investigate" "$(jq -r '.mode' <<<"$OUT")"
assert_eq "usageをeventsから抽出" "42" "$(jq -r '.metrics.usage.input_tokens' <<<"$OUT")"
assert_eq "output_bytesを計測" "true" "$(jq -r '.metrics.output_bytes > 0' <<<"$OUT")"
assert_eq "schema検証成功を計測" "true" "$(jq -r '.metrics.schema_valid' <<<"$OUT")"
assert_eq "runnerは自動retryしない" "0" "$(jq -r '.metrics.retry_count' <<<"$OUT")"
assert_eq "task本体を返す" "a" "$(jq -r '.task.answers[0].answer' <<<"$OUT")"

ARGS="$(cat "$ARGS_FILE")"
assert_contains "investigateはread-only sandbox" "read-only" "$ARGS"
assert_not_contains "investigateでworkspace-writeへ広げない" "workspace-write" "$ARGS"
assert_not_contains "danger-full-accessを使わない" "danger-full-access" "$ARGS"
assert_contains "対象repoを-Cで明示" "$TARGET_REPO" "$ARGS"
assert_contains "output-schemaを渡す" "codex-task-result.schema.json" "$ARGS"
assert_contains "usage取得のため--jsonを渡す" "--json" "$ARGS"
assert_contains "model overrideを透過" "test-model" "$ARGS"
assert_contains "effort overrideを透過" 'reasoning.effort="high"' "$ARGS"
# sandbox の実効権限は利用者の ~/.codex/config.toml から読まれるため、起動引数で固定する。
# 固定しないと chore の安全性（対象repo外を触らない）が利用者のローカル設定次第で崩れる。
assert_contains "network accessを起動引数で無効化" 'sandbox_workspace_write.network_access=false' "$ARGS"
assert_contains "writable rootを起動引数で空に固定" 'sandbox_workspace_write.writable_roots=[]' "$ARGS"

PROMPT="$(cat "$PROMPT_FILE")"
assert_contains "briefをパスで渡す" "$BRIEF_FILE" "$PROMPT"
assert_contains "inputをパスで渡す" "$INPUT_FILE" "$PROMPT"
assert_not_contains "brief本文をpromptへ展開しない" "$BRIEF_BODY_MARKER" "$PROMPT"
assert_not_contains "input本文をpromptへ展開しない" "$INPUT_BODY_MARKER" "$PROMPT"
assert_contains "非信頼データ境界を明示" "untrusted data" "$PROMPT"
assert_contains "サイズ予算をpromptへ渡す" "20000" "$PROMPT"
assert_contains "investigateは書き込み禁止を明示" "Mode: investigate" "$PROMPT"

echo "=== test: --mode 省略時は安全側（investigate）へ倒す ==="
OUT="$(run_runner --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "mode省略でもexit 0" "0" "$RC"
assert_eq "mode省略はinvestigate" "investigate" "$(jq -r '.mode' <<<"$OUT")"
assert_contains "mode省略でもread-only sandbox" "read-only" "$(cat "$ARGS_FILE")"

echo "=== test: investigate で changes を申告したら failed ==="
BAD_RESULT="${WORK_DIR}/bad.json"
write_result "$BAD_RESULT" complete '[]' '[{"path":"a.txt","action":"modified","reason":"r"}]'
export FAKE_CODEX_FINAL="$BAD_RESULT"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "read-only下の変更申告はexit 4" "4" "$RC"
assert_eq "resultはfailed" "failed" "$(jq -r '.result' <<<"$OUT")"
assert_eq "task結果を渡さない" "null" "$(jq -r '.task' <<<"$OUT")"
assert_eq "契約違反コード" "invalid_task_contract" "$(jq -r '.errors[0].code' <<<"$OUT")"
assert_eq "契約違反はschema_validを立てない" "false" "$(jq -r '.metrics.schema_valid' <<<"$OUT")"

echo "=== test: complete なのに answers も changes も空なら failed ==="
EMPTY_RESULT="${WORK_DIR}/empty.json"
write_result "$EMPTY_RESULT" complete '[]' '[]'
export FAKE_CODEX_FINAL="$EMPTY_RESULT"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "空completeはexit 4" "4" "$RC"
assert_eq "空completeは契約違反" "invalid_task_contract" "$(jq -r '.errors[0].code' <<<"$OUT")"

echo "=== test: schema の required/型/enum/追加field を jq でも検査する ==="
assert_contract_rejected() {
  local description="$1" jq_filter="$2"
  local invalid_file="${WORK_DIR}/invalid-contract.json" output rc
  jq "$jq_filter" "$INVESTIGATE_RESULT" >"$invalid_file"
  export FAKE_CODEX_FINAL="$invalid_file"
  output="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
  rc=$?
  assert_eq "$description" "4" "$rc"
  assert_eq "${description}: 契約違反を明示" "invalid_task_contract" "$(jq -r '.errors[0].code' <<<"$output")"
}

assert_contract_rejected "required field欠落（summary）を拒否" 'del(.summary)'
assert_contract_rejected "required field欠落（followups）を拒否" 'del(.followups)'
assert_contract_rejected "answers要素のrequired欠落を拒否" 'del(.answers[0].evidence)'
assert_contract_rejected "型違反（assumptionsが配列でない）を拒否" '.assumptions = "none"'
assert_contract_rejected "型違反（unverified要素が文字列でない）を拒否" '.unverified = [1]'
assert_contract_rejected "enum違反（status）を拒否" '.status = "done"'
assert_contract_rejected "追加fieldを拒否" '. + {extra: "x"}'
assert_contract_rejected "answersの追加fieldを拒否" '.answers[0] += {note: "x"}'
# evidence は path / path:line による追跡可能な根拠を要求する。空文字を通すと
# 「根拠あり」の体裁だけが残る。schema と jq 側の両方で塞ぐ。
assert_contract_rejected "空のevidenceを拒否" '.answers[0].evidence = ""'
export FAKE_CODEX_FINAL="$INVESTIGATE_RESULT"

echo "=== test: 同梱schemaが空のevidenceを許さない ==="
assert_eq "schemaのevidenceにminLength" "1" \
  "$(jq -r '.properties.answers.items.properties.evidence.minLength // "none"' \
    "${REPO_ROOT}/scripts/schemas/codex-task-result.schema.json")"

echo "=== test: chore モードで申告と作業ツリーが一致 ==="
reset_target_repo
CHORE_RESULT="${WORK_DIR}/chore.json"
write_result "$CHORE_RESULT" complete '[]' '[{"path":"chore.txt","action":"created","reason":"r"}]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="chore.txt"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "一致すればexit 0" "0" "$RC"
assert_eq "resultはcomplete" "complete" "$(jq -r '.result' <<<"$OUT")"
assert_eq "modeはchore" "chore" "$(jq -r '.mode' <<<"$OUT")"
assert_eq "errorsは空" "0" "$(jq -r '.errors | length' <<<"$OUT")"
ARGS="$(cat "$ARGS_FILE")"
assert_contains "choreはworkspace-write sandbox" "workspace-write" "$ARGS"
assert_not_contains "choreでもdanger-full-accessを使わない" "danger-full-access" "$ARGS"
assert_contains "choreでもnetwork accessを無効化" 'sandbox_workspace_write.network_access=false' "$ARGS"
assert_contains "choreでもwritable rootを空に固定" 'sandbox_workspace_write.writable_roots=[]' "$ARGS"
PROMPT="$(cat "$PROMPT_FILE")"
assert_contains "choreはcommit/push禁止を明示" "Do not run git commit" "$PROMPT"
assert_contains "chore成果は作業ツリーに残すと明示" "working tree" "$PROMPT"
assert_eq "成果を作業ツリーに残す" "edited" "$(cat "${TARGET_REPO}/chore.txt")"
assert_eq "runnerはcommitしない" "$SEED_SHA" "$(git -C "$TARGET_REPO" rev-parse HEAD)"

echo "=== test: chore で未追跡ディレクトリ配下もファイル単位で照合する ==="
# git status は既定で未追跡ディレクトリを1行（`?? sub/`）に畳むため、ファイル単位の
# 変更申告と比較できず正当な申告が不一致になる。-uall で展開していることを固定する。
reset_target_repo
write_result "$CHORE_RESULT" complete '[]' '[{"path":"sub/dir/new.txt","action":"created","reason":"r"}]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="sub/dir/new.txt"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "未追跡ディレクトリ配下の申告一致はexit 0" "0" "$RC"
assert_eq "ディレクトリ単位に畳んで不一致にしない" "0" "$(jq -r '.errors | length' <<<"$OUT")"

echo "=== test: chore で申告に無い変更（隠れた編集）を検出 ==="
reset_target_repo
write_result "$CHORE_RESULT" complete '[]' '[{"path":"declared.txt","action":"created","reason":"r"}]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="declared.txt hidden.txt"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "隠れた編集はexit 3" "3" "$RC"
assert_eq "resultはpartial" "partial" "$(jq -r '.result' <<<"$OUT")"
assert_contains "不一致コード" "changes_mismatch" "$(jq -r '[.errors[].code] | join(",")' <<<"$OUT")"
assert_contains "未申告パスを診断へ含める" "hidden.txt" "$(jq -r '[.errors[].message] | join(" ")' <<<"$OUT")"
assert_eq "task結果自体は返す（破棄しない）" "s" "$(jq -r '.task.summary' <<<"$OUT")"
assert_eq "task.statusはouter resultへ正規化" "partial" "$(jq -r '.task.status' <<<"$OUT")"

echo "=== test: chore で作業ツリーに無い変更を申告（捏造）を検出 ==="
reset_target_repo
write_result "$CHORE_RESULT" complete '[]' '[{"path":"claimed-only.txt","action":"created","reason":"r"}]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="actual.txt"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "捏造申告はexit 3" "3" "$RC"
assert_contains "不一致コード" "changes_mismatch" "$(jq -r '[.errors[].code] | join(",")' <<<"$OUT")"
assert_contains "捏造パスを診断へ含める" "claimed-only.txt" "$(jq -r '[.errors[].message] | join(" ")' <<<"$OUT")"

echo "=== test: chore 実行前から dirty だったパスは不一致にしない ==="
reset_target_repo
printf 'pre-existing\n' >"${TARGET_REPO}/seed.txt"
write_result "$CHORE_RESULT" complete '[]' '[{"path":"seed.txt","action":"modified","reason":"r"}]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="seed.txt"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "実行前からdirtyなパスの申告はexit 0" "0" "$RC"
assert_eq "changes_mismatchを出さない" "0" "$(jq -r '.errors | length' <<<"$OUT")"
reset_target_repo

echo "=== test: chore で ignored ファイルの無申告作成を検出 ==="
# `git status --porcelain` は既定で ignored ファイルを出さない。検出できないと、
# .gitignore 対象パス（.env 等）への書き込みが照合を素通りして complete になる。
reset_target_repo
write_result "$CHORE_RESULT" complete '[{"question":"q","answer":"a","evidence":"seed.txt:1"}]' '[]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="hidden.secret"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "ignoredファイルの無申告作成はexit 3" "3" "$RC"
assert_contains "ignoredの無申告作成を不一致として検出" "changes_mismatch" "$(jq -r '[.errors[].code] | join(",")' <<<"$OUT")"
assert_contains "ignoredパスを診断へ含める" "hidden.secret" "$(jq -r '[.errors[].message] | join(" ")' <<<"$OUT")"

echo "=== test: chore で ignored ファイルの申告一致は complete ==="
reset_target_repo
write_result "$CHORE_RESULT" complete '[]' '[{"path":"declared.secret","action":"created","reason":"r"}]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="declared.secret"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "ignoredファイルの申告一致はexit 0" "0" "$RC"
assert_eq "申告一致ならerrorsは空" "0" "$(jq -r '.errors | length' <<<"$OUT")"

echo "=== test: 巨大な ignored ツリーは差分に載せない（常時 partial にしない） ==="
# node_modules/ のような ignored ディレクトリを1エントリに畳まないと、正当な作業でも
# 数百件の未申告パスが出て changes_mismatch が常時発火し、検査そのものが無意味になる。
reset_target_repo
mkdir -p "${TARGET_REPO}/ignored-dir/pkg"
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'x\n' >"${TARGET_REPO}/ignored-dir/pkg/f${i}.js"; done
write_result "$CHORE_RESULT" complete '[]' '[{"path":"normal.txt","action":"created","reason":"r"}]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="normal.txt"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "実行前から在る巨大ignoredツリーは不一致にしない" "0" "$RC"
assert_eq "ignoredツリーでerrorsを増やさない" "0" "$(jq -r '.errors | length' <<<"$OUT")"
reset_target_repo

echo "=== test: chore で commit したら検出 ==="
reset_target_repo
write_result "$CHORE_RESULT" complete '[]' '[{"path":"committed.txt","action":"created","reason":"r"}]'
export FAKE_CODEX_FINAL="$CHORE_RESULT"
export FAKE_CODEX_TOUCH="committed.txt"
export FAKE_CODEX_COMMIT="1"
OUT="$(run_runner --mode chore --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
export FAKE_CODEX_COMMIT=""
assert_eq "commit検出はexit 3" "3" "$RC"
assert_contains "commit検出コード" "commit_detected" "$(jq -r '[.errors[].code] | join(",")' <<<"$OUT")"
assert_eq "commit検出でも結果は返す" "s" "$(jq -r '.task.summary' <<<"$OUT")"
reset_target_repo
export FAKE_CODEX_TOUCH=""

echo "=== test: 出力サイズ予算超過 ==="
BIG_RESULT="${WORK_DIR}/big.json"
jq -n --arg summary "$(head -c 2000 /dev/zero | tr '\0' 'x')" \
  '{status:"complete", summary:$summary, answers:[{question:"q",answer:"a",evidence:"e"}],
    changes:[], assumptions:[], unverified:[], followups:[]}' >"$BIG_RESULT"
export FAKE_CODEX_FINAL="$BIG_RESULT"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --max-output-bytes 100)"
RC=$?
assert_eq "予算超過はexit 3" "3" "$RC"
assert_eq "予算超過コード" "output_budget_exceeded" "$(jq -r '.errors[0].code' <<<"$OUT")"
assert_eq "予算超過でも結果は破棄しない" "true" "$(jq -r '.task.summary | length > 0' <<<"$OUT")"
assert_eq "予算はpromptへも渡る" "true" "$(grep -cF '100 bytes' "$PROMPT_FILE" >/dev/null && echo true || echo false)"
export FAKE_CODEX_FINAL="$INVESTIGATE_RESULT"

echo "=== test: タスク自己申告の partial / failed を昇格しない ==="
SELF_PARTIAL="${WORK_DIR}/self-partial.json"
write_result "$SELF_PARTIAL" partial '[{"question":"q","answer":"a","evidence":"e"}]' '[]'
export FAKE_CODEX_FINAL="$SELF_PARTIAL"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "自己申告partialはexit 3" "3" "$RC"
assert_eq "自己申告partialをcompleteへ昇格しない" "partial" "$(jq -r '.result' <<<"$OUT")"

SELF_FAILED="${WORK_DIR}/self-failed.json"
write_result "$SELF_FAILED" failed '[]' '[]'
export FAKE_CODEX_FINAL="$SELF_FAILED"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "自己申告failedはexit 4" "4" "$RC"
assert_eq "自己申告failedをcompleteへ昇格しない" "failed" "$(jq -r '.result' <<<"$OUT")"
export FAKE_CODEX_FINAL="$INVESTIGATE_RESULT"

echo "=== test: codex terminal failure と不正JSON ==="
export FAKE_CODEX_EXIT=7
export FAKE_CODEX_STDERR="authentication failed"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "codex失敗はexit 4" "4" "$RC"
assert_eq "codex_failedを返す" "codex_failed" "$(jq -r '.errors[0].code' <<<"$OUT")"
assert_eq "codex exitを保持" "7" "$(jq -r '.metrics.codex_exit_code' <<<"$OUT")"
assert_contains "codex stderr診断を保持" "authentication failed" "$(jq -r '.errors[0].message' <<<"$OUT")"
assert_eq "terminal_failureを立てる" "true" "$(jq -r '.metrics.terminal_failure' <<<"$OUT")"
export FAKE_CODEX_EXIT=0
unset FAKE_CODEX_STDERR

BROKEN="${WORK_DIR}/broken.json"
printf 'not json' >"$BROKEN"
export FAKE_CODEX_FINAL="$BROKEN"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE")"
RC=$?
assert_eq "不正JSONはexit 4" "4" "$RC"
assert_eq "invalid_final_jsonを返す" "invalid_final_json" "$(jq -r '.errors[0].code' <<<"$OUT")"
export FAKE_CODEX_FINAL="$INVESTIGATE_RESULT"

echo "=== test: hard timeout ==="
export FAKE_CODEX_SLEEP=2
export FAKE_CODEX_STDERR="timeout diagnostic"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --timeout 1)"
RC=$?
assert_eq "timeoutはexit 4" "4" "$RC"
assert_eq "timeout理由を構造化" "codex_timeout" "$(jq -r '.errors[0].code' <<<"$OUT")"
assert_eq "timeoutはterminal failure" "true" "$(jq -r '.metrics.terminal_failure' <<<"$OUT")"
assert_contains "timeoutもstderr診断を保持" "timeout diagnostic" "$(jq -r '.errors[0].message' <<<"$OUT")"
unset FAKE_CODEX_SLEEP
unset FAKE_CODEX_STDERR

echo "=== test: --output-schema の差し替え（同梱契約と互換なもののみ） ==="
BUNDLED_SCHEMA="${REPO_ROOT}/scripts/schemas/codex-task-result.schema.json"
CUSTOM_SCHEMA="${WORK_DIR}/custom-schema.json"
# 同梱schemaをそのまま渡す＝互換。差し替えは「制約を厳しくする」用途のみを想定する。
cp "$BUNDLED_SCHEMA" "$CUSTOM_SCHEMA"
OUT="$(run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --output-schema "$CUSTOM_SCHEMA")"
RC=$?
assert_eq "互換schemaはexit 0" "0" "$RC"
assert_contains "差し替えschemaをcodexへ渡す" "$CUSTOM_SCHEMA" "$(cat "$ARGS_FILE")"

# 制約を厳しくする方向（pattern 追加）は互換として受け入れる。
TIGHTER_SCHEMA="${WORK_DIR}/tighter-schema.json"
jq '.properties.answers.items.properties.evidence.pattern = "^[^ ]+$"' "$BUNDLED_SCHEMA" >"$TIGHTER_SCHEMA"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --output-schema "$TIGHTER_SCHEMA" >/dev/null 2>&1
assert_eq "制約を厳しくする差し替えは受け入れる" "0" "$?"

# 契約を広げる方向は事前に拒否する。widen したまま実行すると、Codex が差し替え schema に
# 適合した JSON を返しても固定契約の検査で invalid_task_contract になり、原因が
# 実行後まで分からない。
assert_incompatible_schema() {
  local description="$1" jq_filter="$2"
  local bad_schema="${WORK_DIR}/incompatible-schema.json" rc
  jq "$jq_filter" "$BUNDLED_SCHEMA" >"$bad_schema"
  run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --output-schema "$bad_schema" >/dev/null 2>&1
  rc=$?
  assert_eq "$description" "64" "$rc"
}

assert_incompatible_schema "必須fieldを追加したschemaを拒否" \
  '.required += ["citations"] | .properties.citations = {"type":"array"}'
assert_incompatible_schema "追加fieldを許すschemaを拒否" '.additionalProperties = true'
assert_incompatible_schema "必須fieldを落としたschemaを拒否" '.required -= ["followups"]'
assert_incompatible_schema "status enumを広げたschemaを拒否" '.properties.status.enum += ["cancelled"]'
assert_incompatible_schema "action enumを広げたschemaを拒否" \
  '.properties.changes.items.properties.action.enum += ["renamed"]'
assert_incompatible_schema "answersの追加fieldを許すschemaを拒否" \
  '.properties.answers.items.additionalProperties = true'
assert_incompatible_schema "objectでないschemaを拒否" '.type = "array"'

echo "=== test: 引数・入力の検証 ==="
run_runner --repo "$TARGET_REPO" >/dev/null 2>&1
assert_eq "brief-file必須はexit 64" "64" "$?"
run_runner --mode danger-full-access --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" >/dev/null 2>&1
assert_eq "未知modeはexit 64（安全側へ倒さず拒否）" "64" "$?"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --timeout 0 >/dev/null 2>&1
assert_eq "timeoutは正の整数のみ" "64" "$?"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --max-output-bytes abc >/dev/null 2>&1
assert_eq "max-output-bytesは正の整数のみ" "64" "$?"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --effort 'high",sandbox="danger-full-access' >/dev/null 2>&1
assert_eq "effortへのconfig注入を拒否" "64" "$?"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --unknown x >/dev/null 2>&1
assert_eq "未知optionはexit 64" "64" "$?"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file >/dev/null 2>&1
assert_eq "値の無いoptionはexit 64" "64" "$?"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "${WORK_DIR}/missing.md" >/dev/null 2>&1
assert_eq "brief不在はexit 66" "66" "$?"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --input "${WORK_DIR}/missing.md" >/dev/null 2>&1
assert_eq "input不在はexit 66" "66" "$?"
run_runner --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" --output-schema "${WORK_DIR}/missing.json" >/dev/null 2>&1
assert_eq "schema不在はexit 66" "66" "$?"
run_runner --mode investigate --repo "${WORK_DIR}/nonexistent" --brief-file "$BRIEF_FILE" >/dev/null 2>&1
assert_eq "repo不在はexit 66" "66" "$?"
run_runner --mode investigate --repo "${WORK_DIR}" --brief-file "$BRIEF_FILE" >/dev/null 2>&1
assert_eq "非gitはexit 66" "66" "$?"

echo "=== test: codex 未導入は実行前提エラー ==="
# 実在ディレクトリ（/usr/bin・jq や git の在り処）を PATH に並べると、そこに codex が
# 同居している環境では `command -v codex` が成功し、exit 69 の検証ではなく実 Codex の
# 起動になる（Homebrew で jq と codex を入れた macOS はまさにこの配置になる）。
# 必要なコマンドだけを一時ディレクトリへ symlink し、codex を含まない PATH を組み立てる。
ISOLATED_BIN="${WORK_DIR}/isolated-bin"
mkdir -p "$ISOLATED_BIN"
for cmd in jq git dirname basename sed sort comm wc tr tail date mktemp rm cat; do
  cmd_path="$(command -v "$cmd" 2>/dev/null)" || continue
  ln -sf "$cmd_path" "${ISOLATED_BIN}/${cmd}"
done
if [ -e "${ISOLATED_BIN}/codex" ] || PATH="$ISOLATED_BIN" command -v codex >/dev/null 2>&1; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("隔離PATHにcodexが混入していない")
  echo "  NG - 隔離PATHにcodexが混入していない（この前提が崩れるとexit 69の検証にならない）"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 隔離PATHにcodexが混入していない"
fi
NO_CODEX_OUT="$(PATH="$ISOLATED_BIN" "$RUNNER" \
  --mode investigate --repo "$TARGET_REPO" --brief-file "$BRIEF_FILE" 2>/dev/null)"
RC=$?
assert_eq "codex未導入はexit 69" "69" "$RC"
assert_eq "codex_unavailableを返す" "codex_unavailable" "$(jq -r '.errors[0].code' <<<"$NO_CODEX_OUT")"
assert_eq "codex未導入をfailedとして返す" "failed" "$(jq -r '.result' <<<"$NO_CODEX_OUT")"

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
