#!/bin/bash
# test-command-spec.sh
# scripts/lib/command-spec.sh（コマンド文字列 → argv 変換と実行系の許可判定）と、
# それを使う2つのランナー（quality-check-runner.sh / mutation-run.sh）が
# **シェル解釈を挟まない**ことを固定する（Issue #223）。
#
# 検証の要点:
#   - 渡された文字列が `bash -c` に到達しない（`;` や `>` を書いても副作用が起きない）
#   - 実行系（argv 先頭トークン）が同梱 allowlist に無ければ**実行前に**拒否する
#   - ランチャーの `--env` で実行系解決（PATH 等）を差し替えられない
#
# **deny 対象コマンド（rm 等）は一切実行しない**。副作用の有無は、一時ディレクトリ内の
# カナリアファイルが `touch` されるかどうかで観測する（bash -c に渡れば作られる文字列を使い、
# 「作られないこと」を確認する）。タウトロジーを避けるため、同じ文字列が `bash -c` 経由なら
# 実際にカナリアを作ることを**先に実測**（positive control）してから、ランナー経由では
# 作られないことを確認する。
#
# 実行方法: bash scripts/tests/test-command-spec.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
QCR="${REPO_ROOT}/scripts/quality-check-runner.sh"
MUTATION_RUN="${REPO_ROOT}/scripts/mutation-run.sh"
LAUNCHER="${REPO_ROOT}/bin/claude-harness-run"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/command-spec.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-command-spec.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
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
  local description="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected to contain: ${needle}"
    echo "       actual:              ${haystack}"
  fi
}

# =============================================================================
echo "=== test: cmdspec_first_metachar（シェル解釈を要求する文字の検出） ==="
# =============================================================================

assert_eq "通常のコマンドには metachar が無い" "" "$(cmdspec_first_metachar 'npm run lint')"
assert_eq "フラグ・パス・数値を含む形も metachar 無し" \
  "" "$(cmdspec_first_metachar 'npx --no jest --maxWorkers=2 tests/a_test.ts')"
assert_eq "コマンド区切り ';' を検出" ";" "$(cmdspec_first_metachar 'true; touch x')"
assert_eq "バックグラウンド '&' を検出" "&" "$(cmdspec_first_metachar 'npm test & true')"
assert_eq "パイプ '|' を検出" "|" "$(cmdspec_first_metachar 'npm test | tail -1')"
assert_eq "リダイレクト '>' を検出" ">" "$(cmdspec_first_metachar 'npm test > out.txt')"
assert_eq "コマンド置換 '\$' を検出" "\$" "$(cmdspec_first_metachar 'npm test $(id)')"
assert_eq "バッククォートを検出" '`' "$(cmdspec_first_metachar 'npm test `id`')"
assert_eq "シングルクォートを検出" "'" "$(cmdspec_first_metachar "printf 'x'")"
assert_eq "ダブルクォートを検出" '"' "$(cmdspec_first_metachar 'printf "x"')"
assert_eq "バックスラッシュを検出" '\' "$(cmdspec_first_metachar 'printf a\ b')"
assert_eq "グロブ '*' を検出" "*" "$(cmdspec_first_metachar 'pytest tests/*.py')"
assert_eq "改行を検出" '\n' "$(cmdspec_first_metachar 'npm test
rm -rf /')"
assert_eq "非ASCII（日本語パス）は metachar ではない" \
  "" "$(cmdspec_first_metachar 'npx --no jest tests/日本語.test.ts')"

# =============================================================================
echo "=== test: cmdspec_prefix_matches（allowlist エントリは argv の前置一致） ==="
# =============================================================================

assert_eq "1トークンのエントリは argv 先頭に一致すれば可" \
  "0" "$(cmdspec_prefix_matches 'cargo' cargo clippy && echo 0 || echo 1)"
assert_eq "複数トークンのエントリは全トークンが順に一致して初めて可" \
  "0" "$(cmdspec_prefix_matches 'python3 -m' python3 -m pytest && echo 0 || echo 1)"
assert_eq "2トークン目が違えば不一致" \
  "1" "$(cmdspec_prefix_matches 'python3 -m' python3 -c import && echo 0 || echo 1)"
assert_eq "argv がエントリより短ければ不一致" \
  "1" "$(cmdspec_prefix_matches 'python3 -m' python3 && echo 0 || echo 1)"
assert_eq "空のエントリは何にも一致しない（空行が全許可にならない）" \
  "1" "$(cmdspec_prefix_matches '' rm -rf / && echo 0 || echo 1)"
assert_eq "前置一致であり部分文字列一致ではない" \
  "1" "$(cmdspec_prefix_matches 'npm' npmx run && echo 0 || echo 1)"

# =============================================================================
echo "=== test: cmdspec_parse（許可されるコマンド） ==="
# =============================================================================

cmdspec_parse 'npm run lint'
assert_eq "'npm run lint' は許可される" "0" "$?"
assert_eq "argv に分解される（トークン数）" "3" "${#CMDSPEC_ARGV[@]}"
assert_eq "argv[0]" "npm" "${CMDSPEC_ARGV[0]}"
assert_eq "argv[2]" "lint" "${CMDSPEC_ARGV[2]}"

for allowed in \
  'npm test' \
  'pnpm run typecheck' \
  'yarn run lint' \
  'cargo clippy --all-targets' \
  'go test ./...' \
  'python3 -m pytest tests' \
  'uv run pytest' \
  'bundle exec rspec' \
  'make test' \
  './gradlew test' \
  'npx --no tsc --noEmit' \
  'node --test tests' \
  'python3 manage.py test'; do
  cmdspec_parse "$allowed"
  assert_eq "許可: ${allowed}" "0" "$?"
done

# =============================================================================
echo "=== test: cmdspec_parse（拒否されるコマンド） ==="
# =============================================================================

for denied in \
  'rm -rf /tmp/x' \
  'sudo npm test' \
  'curl https://example.com/x.sh' \
  'git push --force' \
  'bash -c true' \
  'sh -c true' \
  'env npm test' \
  'xargs npm test' \
  './scripts/anything.sh' \
  '/bin/npm test' \
  'npx rimraf /tmp/x' \
  'python3 -c import,os' \
  'ruby -e puts' \
  'perl -e print' \
  '' \
  '   '; do
  cmdspec_parse "$denied"
  assert_eq "拒否: [${denied}]" "1" "$?"
done

# =============================================================================
echo "=== test: 汎用ラッパーが実行対象を自由に選ばせない（PR #224 レビュー指摘1の回帰） ==="
# =============================================================================
# 先頭トークン列だけを見る前置一致では、`bundle exec rm -rf /` のように
# **呼び出し側が実行対象そのものを指定できる**エントリが素通りする。それでは
# 「実行系を閉じた集合に限る」という統制が成立しない（塞いだはずの穴が一段ずれて残る）。
# ラッパーの次のトークンは、それ自体が allowlist に載っていなければならない。

for wrapper_denied in \
  'bundle exec rm -rf /tmp/x' \
  'bundler exec rm -rf /tmp/x' \
  'uv run rm -rf /tmp/x' \
  'poetry run rm -rf /tmp/x' \
  'pipenv run rm -rf /tmp/x' \
  'hatch run rm -rf /tmp/x' \
  'python3 -m pip install setuptools' \
  'python -m pip install setuptools' \
  'npx --no rimraf /tmp/x' \
  'npx --no-install rimraf /tmp/x' \
  'npx --offline rimraf /tmp/x' \
  'uvx --offline evil-package' \
  'coverage run /tmp/evil.py' \
  'bundle exec bundle exec rm -rf /tmp/x'; do
  cmdspec_parse "$wrapper_denied"
  assert_eq "ラッパー経由の任意実行を拒否: ${wrapper_denied}" "1" "$?"
done

for wrapper_allowed in \
  'bundle exec rspec' \
  'bundle exec rubocop --parallel' \
  'uv run pytest tests' \
  'poetry run mypy src' \
  'pipenv run pytest' \
  'hatch run ruff check' \
  'python3 -m pytest tests' \
  'python -m mypy src' \
  'npx --no tsc --noEmit' \
  'npx --no eslint .' \
  'uvx --offline ruff check' \
  'coverage run -m pytest'; do
  cmdspec_parse "$wrapper_allowed"
  assert_eq "ラッパー経由でも許可ツールなら可: ${wrapper_allowed}" "0" "$?"
done

# =============================================================================
echo "=== test: 汎用サブコマンドで任意のバイナリ／ネットワーク取得を起動できない ==="
# =============================================================================
# `cargo install` / `go install` は取得したコードをビルド時に実行し、
# `cargo run` / `go run` / `dotnet exec` / `node <file>` は呼び出し側が実行対象を選べる。
# 「プロジェクト自身の設定が定める手続きを起動する」形（`cargo test` 等）だけを許可する。

for subcmd_denied in \
  'cargo install evil-crate' \
  'cargo run' \
  'go install evil@latest' \
  'go run ./cmd/tool' \
  'dotnet exec /tmp/tool.dll' \
  'dotnet tool install evil' \
  'node /tmp/evil.js' \
  'node --require /tmp/evil.js --test' \
  'swift run' \
  'dart run /tmp/x.dart' \
  'mix run' \
  'terraform apply' \
  'helm install evil ./chart' \
  'playwright install' \
  'zig run /tmp/x.zig'; do
  cmdspec_parse "$subcmd_denied"
  assert_eq "汎用サブコマンドを拒否: ${subcmd_denied}" "1" "$?"
done

for subcmd_allowed in \
  'cargo test' \
  'cargo clippy --all-targets' \
  'go test ./...' \
  'go vet ./...' \
  'dotnet test' \
  'dotnet format' \
  'node --test tests' \
  'swift test' \
  'dart analyze' \
  'mix test' \
  'terraform validate' \
  'helm lint ./chart' \
  'playwright test' \
  'zig build test'; do
  cmdspec_parse "$subcmd_allowed"
  assert_eq "プロジェクト定義の手続き起動は可: ${subcmd_allowed}" "0" "$?"
done

# プロジェクト自身の設定が実行内容を定める形は従来どおり通す（後方互換）。
for project_defined in \
  'npm run lint' \
  'npm test' \
  'pnpm run typecheck' \
  'yarn run lint' \
  'bun run lint' \
  'deno task test' \
  'make test' \
  'just check' \
  'rake spec' \
  'tox' \
  './gradlew test' \
  'composer run test'; do
  cmdspec_parse "$project_defined"
  assert_eq "プロジェクト設定が定める手続き: ${project_defined}" "0" "$?"
done

cmdspec_parse 'npm run lint; touch /tmp/x'
assert_eq "metachar を含む形は拒否" "1" "$?"
assert_contains "拒否理由に metachar が示される" "$CMDSPEC_ERROR" "shell metacharacter"

cmdspec_parse 'rm -rf /tmp/x'
assert_contains "拒否理由に allowlist が示される" "$CMDSPEC_ERROR" "not in the command allowlist"

# =============================================================================
echo "=== test: allowlist ファイルが読めない場合は fail-closed ==="
# =============================================================================

SAVED_ALLOWLIST="$CMDSPEC_ALLOWLIST_FILE"
CMDSPEC_ALLOWLIST_FILE="${WORK_DIR}/does-not-exist.txt"
cmdspec_parse 'npm run lint'
assert_eq "allowlist が無ければ許可コマンドも拒否する（fail-closed）" "1" "$?"
CMDSPEC_ALLOWLIST_FILE="$SAVED_ALLOWLIST"

# =============================================================================
echo "=== test: allowlist ファイルのパスは環境変数から差し替えられない ==="
# =============================================================================
# 差し替えられると、ランチャーの `--env` で自前の allowlist を注入できてしまい
# 本修正の目的（deny の迂回を塞ぐ）が失われる。

EVIL_ALLOWLIST="${WORK_DIR}/evil-allowlist.txt"
printf 'touch\n' >"$EVIL_ALLOWLIST"
ENV_INJECT_OUT="$(CMDSPEC_ALLOWLIST_FILE="$EVIL_ALLOWLIST" \
  "$QCR" --lint "touch ${WORK_DIR}/env-inject-canary" 2>&1)"
assert_eq "環境変数で allowlist を差し替えても拒否される（exit 4）" "4" "$?"
assert_eq "差し替えを試みてもカナリアは作られない" \
  "absent" "$([ -e "${WORK_DIR}/env-inject-canary" ] && echo present || echo absent)"
assert_contains "拒否メッセージが出る" "$ENV_INJECT_OUT" "not in the command allowlist"

# =============================================================================
echo "=== test: quality-check-runner はコマンド文字列をシェル解釈しない ==="
# =============================================================================

# positive control: 同じ文字列は `bash -c` に渡ればカナリアを作る（テストがタウトロジーで
# ないことの実測。ここで作られなければ以降の「作られない」は何も証明していない）。
CANARY="${WORK_DIR}/qcr-canary"
PAYLOAD="true; touch ${CANARY}"
bash -c "$PAYLOAD"
assert_eq "positive control: bash -c 経由ならカナリアが作られる" \
  "present" "$([ -e "$CANARY" ] && echo present || echo absent)"
rm -f "$CANARY"

for flag in --lint --typecheck --test --auto-fix; do
  CANARY="${WORK_DIR}/qcr-canary"
  rm -f "$CANARY"
  QCR_OUT="$("$QCR" "$flag" "true; touch ${CANARY}" 2>&1)"
  QCR_EXIT=$?
  assert_eq "${flag}: シェル解釈を要求する文字列は exit 4 で拒否" "4" "$QCR_EXIT"
  assert_eq "${flag}: カナリアは作られない（bash -c に到達していない）" \
    "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"
  assert_contains "${flag}: 拒否理由が stderr に出る" "$QCR_OUT" "shell metacharacter"
done

# リダイレクトによる書き込みも成立しない。
CANARY="${WORK_DIR}/qcr-redirect-canary"
"$QCR" --lint "echo x > ${CANARY}" >/dev/null 2>&1
assert_eq "リダイレクト形も exit 4" "4" "$?"
assert_eq "リダイレクト形でもカナリアは作られない" \
  "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"

# metachar が無くても、allowlist に無い実行系は実行されない。
CANARY="${WORK_DIR}/qcr-direct-canary"
QCR_DIRECT_OUT="$("$QCR" --lint "touch ${CANARY}" 2>&1)"
assert_eq "allowlist 外の実行系は exit 4" "4" "$?"
assert_eq "allowlist 外の実行系は実行されない" \
  "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"
assert_contains "allowlist 外である旨が stderr に出る" "$QCR_DIRECT_OUT" "not in the command allowlist"

# 拒否は**どのゲートも実行する前**に起きる（1つでも実行してからでは遅い）。
CANARY="${WORK_DIR}/qcr-order-canary"
"$QCR" --lint "touch ${CANARY}" --test "true" >/dev/null 2>&1
assert_eq "1つでも拒否対象があれば他ゲートも実行せず exit 4" "4" "$?"
assert_eq "拒否時は stdout に JSON を出さない（品質 fail と混同させない）" \
  "" "$("$QCR" --lint "touch ${CANARY}" --test "true" 2>/dev/null)"

# =============================================================================
echo "=== test: 実行関数そのものがシェルを介さない（多層防御の内側の層） ==="
# =============================================================================
# 上の CLI テストは引数解析時の検証（外側の層）で止まるため、実行関数自体が
# `bash -c` に戻っても観測できない。内側の層を単体で固定する
# （多層防御は各層を個別に検証しないと、片方が壊れたことに気付けない）。

# shellcheck source=/dev/null
source "$QCR"
# shellcheck source=/dev/null
source "$MUTATION_RUN"

CANARY="${WORK_DIR}/run-command-canary"
run_command "lint" "true; touch ${CANARY}" 2>/dev/null
assert_eq "run_command: シェル構文を含むコマンドは実行しない（126）" "126" "$LAST_EXIT_CODE"
assert_eq "run_command: カナリアは作られない" \
  "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"

CANARY="${WORK_DIR}/run-command-allowlist-canary"
run_command "lint" "touch ${CANARY}" 2>/dev/null
assert_eq "run_command: allowlist 外の実行系は実行しない（126）" "126" "$LAST_EXIT_CODE"
assert_eq "run_command: allowlist 外でもカナリアは作られない" \
  "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"

run_command "lint" "true" 2>/dev/null
assert_eq "run_command: allowlist にある実行系は通常どおり実行される" "0" "$LAST_EXIT_CODE"

CANARY="${WORK_DIR}/run-test-command-canary"
run_test_command "true; touch ${CANARY}" 2>/dev/null
assert_eq "run_test_command: シェル構文を含むコマンドは実行しない（126）" "126" "$LAST_EXIT_CODE"
assert_eq "run_test_command: カナリアは作られない" \
  "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"

run_test_command "true" 2>/dev/null
assert_eq "run_test_command: allowlist にある実行系は通常どおり実行される" "0" "$LAST_EXIT_CODE"

# =============================================================================
echo "=== test: mutation-run はコマンド文字列をシェル解釈しない ==="
# =============================================================================

CANARY="${WORK_DIR}/mutation-canary"
MUTATION_OUT="$("$MUTATION_RUN" "true; touch ${CANARY}" "some-file.ts" 2>&1)"
assert_eq "mutation-run: シェル解釈を要求する test_command は exit 4" "4" "$?"
assert_eq "mutation-run: カナリアは作られない" \
  "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"
assert_contains "mutation-run: 拒否理由が stderr に出る" "$MUTATION_OUT" "shell metacharacter"

CANARY="${WORK_DIR}/mutation-direct-canary"
"$MUTATION_RUN" "touch ${CANARY}" "some-file.ts" >/dev/null 2>&1
assert_eq "mutation-run: allowlist 外の実行系は exit 4" "4" "$?"
assert_eq "mutation-run: allowlist 外の実行系は実行されない" \
  "absent" "$([ -e "$CANARY" ] && echo present || echo absent)"

# =============================================================================
echo "=== test: ランチャーの --env で実行系解決を差し替えられない ==="
# =============================================================================
# PATH を差し替えられると allowlist にある名前（npm 等）で任意のバイナリを実行できるため、
# 実行系解決に影響する環境変数はランチャー側で拒否する。

# denylist 方式では同種の変数（NODE_PATH / PYTHONPATH / GEM_PATH …）を取りこぼすため、
# **allowlist 方式**にしてある（PR #224 レビュー指摘2）。ここでは「取りこぼしがちな
# 検索パス系」を含めて、許可した名前以外がすべて拒否されることを固定する。
for evil_env in \
  'PATH=/tmp/evil' \
  'BASH_ENV=/tmp/evil.sh' \
  'NODE_OPTIONS=--require=/tmp/evil.js' \
  'NODE_PATH=/tmp/evil' \
  'PYTHONPATH=/tmp/evil' \
  'PYTHONHOME=/tmp/evil' \
  'GEM_PATH=/tmp/evil' \
  'RUBYLIB=/tmp/evil' \
  'PERL5LIB=/tmp/evil' \
  'CLASSPATH=/tmp/evil' \
  'JAVA_TOOL_OPTIONS=-javaagent:/tmp/evil.jar' \
  'DOTNET_STARTUP_HOOKS=/tmp/evil.dll' \
  'GRADLE_OPTS=-Dx=y' \
  'MAVEN_OPTS=-Dx=y' \
  'LD_PRELOAD=/tmp/evil.so' \
  'DYLD_INSERT_LIBRARIES=/tmp/evil.dylib' \
  'CLAUDE_HARNESS_ROOT=/tmp/evil' \
  'FOO=bar'; do
  LAUNCHER_OUT="$("$LAUNCHER" --env "$evil_env" --plugin-root 2>&1)"
  assert_eq "--env ${evil_env%%=*} は拒否される（exit 64）" "64" "$?"
  assert_contains "--env ${evil_env%%=*} の拒否理由が出る" "$LAUNCHER_OUT" "may not be set via --env"
done

# 許可されているのは、スキルが実際に使う（実行系の解決に影響しない）変数だけ。
for ok_env in \
  'WALKTHROUGH_PROJECT_ROOT=/abs/project' \
  'WALKTHROUGH_OUT=/abs/out' \
  'WALKTHROUGH_SLOWMO=1500' \
  'WALKTHROUGH_PAUSE_MS=5000' \
  'WALKTHROUGH_HEADED=1' \
  'BASE_URL=http://localhost:3000'; do
  LAUNCHER_OK_OUT="$(CLAUDE_HARNESS_ROOT="$REPO_ROOT" "$LAUNCHER" --env "$ok_env" --plugin-root 2>&1)"
  assert_eq "--env ${ok_env%%=*} は通る" "0" "$?"
  assert_eq "--env ${ok_env%%=*} でも --plugin-root は解決結果を返す" "$REPO_ROOT" "$LAUNCHER_OK_OUT"
done

# =============================================================================
echo "=== test: 迂回不能であることが仕様・ドキュメントに固定されている ==="
# =============================================================================

assert_file_contains() {
  local description="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected ${file} to contain: ${needle}"
  fi
}

assert_file_contains "script-launcher.md に allow の意味（deny の適用範囲）の節がある" \
  "${REPO_ROOT}/docs/script-launcher.md" \
  '## 6. このランチャーを allow することの意味'
assert_file_contains "script-launcher.md が任意コマンド実行にならない旨を明記している" \
  "${REPO_ROOT}/docs/script-launcher.md" \
  'シェルへ渡さない'
assert_file_contains "quality-check-runner の仕様に exit 4 がある" \
  "${REPO_ROOT}/scripts/specs/quality-check-runner.md" \
  'exit code 4'
assert_file_contains "mutation-run の仕様に exit 4 がある" \
  "${REPO_ROOT}/scripts/specs/mutation-run.md" \
  'exit code 4'
assert_file_contains "allowlist の正本が scripts/config にある" \
  "${REPO_ROOT}/scripts/config/command-allowlist.txt" \
  'npm run'

echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi

exit 0
