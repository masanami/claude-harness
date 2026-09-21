#!/bin/bash
# mutation-run.sh
# 使い方: scripts/mutation-run.sh <test_command> <mutated_file_1> [<mutated_file_2> ...]（詳細は下記参照）
# 仕様の正本は scripts/specs/mutation-run.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/command-spec.sh" || {
  echo "Error: failed to source lib/command-spec.sh" >&2
  exit 1
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} <test_command> <mutated_file_1> [<mutated_file_2> ...]

  test_command      Command that exercises the already-mutated working tree and
                     exits non-zero on failure. It is executed **without a shell**:
                     shell syntax (; && | > \$() \` quotes globs) is rejected, and the
                     leading tokens must match scripts/config/command-allowlist.txt.
                     A rejected command exits 4 without running anything (Issue #223).
  mutated_file_*     One or more file paths already edited (mutation injected)
                     by the caller before invoking this script. Used both to
                     scope the pre-flight dirty-tree check and to restore
                     ("git checkout --") after the test run.
EOF
}

# ---------------------------------------------------------------------------
# 純粋関数（外部コマンドを起動しない。source して直接テスト可能）
# ---------------------------------------------------------------------------

# `git status --porcelain` の1行から path 部分を取り出す（先頭2文字のステータス+空白）。
# rename ("R  old -> new") は対象外（変異対象は既存の追跡ファイルの中身編集のみを想定）。
porcelain_path() {
  local line="$1"
  printf '%s' "${line:3}"
}

# mutated_file 引数をリポジトリルート相対パスへ正規化する（check_dirty_scope の比較専用。
# `git checkout --`/`git status --porcelain -- <file>` は絶対パスのままでも正しく動作するため
# 変換しない）。
# 呼び出し契約（agents/e2e-mutation-injector.md）では変異エージェントは「実際に編集した
# ファイルの絶対パス」を返すが、`git status --porcelain`（引数無し・リポジトリ全体の手順0）が
# 返す path は常にリポジトリルート相対である。この不一致を正規化せずに比較すると、
# check_dirty_scope が常に「範囲外の変更」と誤検出し、実運用の全ミューテーションがテスト実行
# より前に打ち切られてしまう（回帰テスト: scripts/tests/test-mutation-run.sh）。
# repo_root 配下の絶対パスのみをルート相対へ変換し、それ以外（既に相対パス／repo_root取得失敗／
# repo_root 外の絶対パス）はそのまま返す（repo_root 外の絶対パスをそのまま返すのは意図的であり、
# 結果として比較不一致＝「範囲外の変更」として安全側に検出される）。
normalize_to_repo_relative() {
  local repo_root="$1"
  local file="$2"
  if [ -n "$repo_root" ] && [ "${file#/}" != "$file" ] && [ "${file#"$repo_root"/}" != "$file" ]; then
    printf '%s' "${file#"$repo_root"/}"
  else
    printf '%s' "$file"
  fi
}

# テスト出力からアサーション起因の失敗らしいかをbest-effortで判定する。
# 対応形式の例: Jest/Vitest/Playwright の "AssertionError" "expect(" 系、
# 一般的な "Expected ... Received ..." 形式。マッチしなければ "other"。
classify_failure_kind() {
  local output="$1"
  if printf '%s\n' "$output" | grep -qiE 'AssertionError|expect\(|toHaveBeenCalled|toBe\(|toEqual\(|toContain\(|toMatch\(|assert(ion)? failed|Expected[: ].*(Received|but got)'; then
    echo "assertion"
  else
    echo "other"
  fi
}

# `git status --porcelain` の出力全体（複数行）と対象ファイル一覧を受け取り、
# 対象ファイルの範囲外に変更が無いかを判定する（クリーン確認の中核）。
# 引数: porcelain_output, file...
# 結果: グローバル変数
#   OUT_OF_SCOPE_LINES  範囲外だった porcelain 行（空文字なら範囲外無し）
#   ANY_TARGET_DIRTY     "true"|"false"（対象ファイルの中に実際に変更があったか）
check_dirty_scope() {
  local porcelain_output="$1"
  shift
  local files=("$@")
  OUT_OF_SCOPE_LINES=""
  ANY_TARGET_DIRTY="false"
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local path
    path="$(porcelain_path "$line")"
    local matched="false"
    local f
    for f in "${files[@]}"; do
      if [ "$path" = "$f" ]; then
        matched="true"
        ANY_TARGET_DIRTY="true"
        break
      fi
    done
    if [ "$matched" = "false" ]; then
      OUT_OF_SCOPE_LINES="${OUT_OF_SCOPE_LINES}${line}
"
    fi
  done <<<"$porcelain_output"
}

# ---------------------------------------------------------------------------
# 外部コマンド実行（副作用あり）
# ---------------------------------------------------------------------------

# ファイルの実体パス（symlink解決込みの絶対パス）を求める。macOS標準環境には
# realpath/readlink -f が無いため、ディレクトリ部分を実際に `cd` して `pwd -P`
# （物理パスを返すシェル組み込み）を取る移植性の高いイディオムを使う。
# `git rev-parse --show-toplevel` は常に物理パスを返す（実機確認済み）一方、呼び出し側から
# 渡される mutated_file の絶対パスはシンボリックリンク経由（例: macOS の /tmp -> /private/tmp、
# /var -> /private/var。`mktemp -d` の返り値は後者に該当し、テストスイート自身にも影響する）の
# ことがあり、そのまま repo_root と前方一致比較すると常に不一致になる。この関数は
# normalize_to_repo_relative に渡す前段の正規化として main() から呼ばれる（ファイルI/Oを伴うため
# 純粋関数セクションではなくこちらに置く）。ディレクトリが解決できない場合は入力をそのまま返す
# （安全側: 比較不一致のままとなり「範囲外」として検出される）。
canonicalize_path() {
  local path="$1"
  local dir base resolved_dir
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  resolved_dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  if [ -z "$resolved_dir" ]; then
    printf '%s' "$path"
    return
  fi
  printf '%s/%s' "$resolved_dir" "$base"
}

# test_command を実行し、標準出力/標準エラーを結合してグローバル変数
# LAST_OUTPUT / LAST_EXIT_CODE に格納する。生の出力は stderr にも転記する
# （出力規約: stdoutにはJSONのみ。呼び出し側がfailureKindの手掛かりを追えるように）。
# test_command はバックグラウンドで起動し `wait` で待ち受ける（`$(...)` コマンド置換で
# 前面待機すると、bash はフォアグラウンドジョブ完了までシグナルの trap 実行を遅延させるため、
# SIGTERM/SIGINT を受けてもタイムアウトによる強制終了までトラップが発火しない。`wait` は
# シグナル到着時に即座に中断してトラップを実行できるため、この構成で早期に捕捉できる）。
# 実行中の test_command の PID は CURRENT_TEST_PID に保持し、シグナル受信時に
# terminate_on_signal から子プロセスの終了を試みる。
CURRENT_TEST_PID=""

run_test_command() {
  local cmd="$1"
  echo "--- test: ${cmd} ---" >&2
  # シェルを介さず argv を直接実行する（Issue #223）。検証は main() で済ませてあり、
  # ここへ到達する時点で合格している（再パース失敗時は実行せず 126 = fail-closed）。
  if ! cmdspec_parse "$cmd"; then
    LAST_OUTPUT="rejected command: ${CMDSPEC_ERROR}"
    LAST_EXIT_CODE=126
    printf '%s\n' "$LAST_OUTPUT" >&2
    echo "--- test exit: ${LAST_EXIT_CODE} ---" >&2
    return
  fi
  if [ -n "$CMDSPEC_RESOLVED" ]; then
    echo "--- test resolved: ${CMDSPEC_RESOLVED} ---" >&2
  fi
  local tmp_out
  tmp_out="$(mktemp)" || { LAST_OUTPUT=""; LAST_EXIT_CODE=1; return; }
  "${CMDSPEC_ARGV[@]}" >"$tmp_out" 2>&1 &
  CURRENT_TEST_PID=$!
  wait "$CURRENT_TEST_PID"
  LAST_EXIT_CODE=$?
  CURRENT_TEST_PID=""
  LAST_OUTPUT="$(cat "$tmp_out" 2>/dev/null)"
  rm -f "$tmp_out"
  printf '%s\n' "$LAST_OUTPUT" >&2
  echo "--- test exit: ${LAST_EXIT_CODE} ---" >&2
}

# ---------------------------------------------------------------------------
# EXIT / シグナルトラップ（安全網）
# ---------------------------------------------------------------------------

# main() が呼び出し引数から確定させる復元対象ファイル一覧。trap ハンドラは
# main() の local 変数を参照できないため、グローバル配列として保持する。
MUTATION_FILES=()

# jq不在・事前チェック失敗・test_command 実行中のシグナル/タイムアウトによる中断など、
# 通常の手順2（復元）に到達しない早期終了パスでも、変異対象を可能な限り復元する安全網。
# 通常経路（手順2〜4）で既に復元済みの場合、ここでの再実行は冪等（`git checkout --` は
# 対象ファイルが既にクリーンなら no-op）。exit を呼ばないため、元の終了コード（$?）は
# そのまま維持される。
restore_on_exit() {
  if [ "${#MUTATION_FILES[@]}" -gt 0 ] && git rev-parse --git-dir >/dev/null 2>&1; then
    git checkout -- "${MUTATION_FILES[@]}" 2>/dev/null || true
  fi
}

# SIGTERM/SIGINT（`timeout` コマンドの既定シグナルを含む）受信時のハンドラ。
# 実行中の test_command（バックグラウンドジョブ）があれば終了させたうえで、明示的に
# exit することで EXIT トラップ（restore_on_exit）を発火させ、復元後に非0終了する。
# SIGKILL はプロセスを即座に終了させるため捕捉不可能（OS上の制約であり対処不能）。
terminate_on_signal() {
  local code="$1"
  if [ -n "$CURRENT_TEST_PID" ]; then
    kill -TERM "$CURRENT_TEST_PID" 2>/dev/null || true
  fi
  exit "$code"
}

main() {
  if [ "$#" -lt 2 ]; then
    echo "Error: test_command and at least one mutated_file are required" >&2
    print_usage
    exit 1
  fi

  local test_command="$1"
  shift
  local files=("$@")
  MUTATION_FILES=("${files[@]}")
  trap restore_on_exit EXIT
  trap 'terminate_on_signal 143' TERM
  trap 'terminate_on_signal 130' INT

  # test_command の検証（Issue #223）。テスト実行より前に行い、拒否された場合は
  # 何も実行せず exit 4 で終える（EXIT トラップは登録済みのため、注入済みの変異は
  # 安全網で復元される）。0/1/2/130/143 のいずれとも重ならない値を使い、
  # 呼び出し側が「テストが落ちた」と誤読できないようにする。
  if ! cmdspec_parse "$test_command"; then
    cmdspec_reject_message "test_command" "$test_command"
    exit 4
  fi

  if ! check_jq; then
    exit 2
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: not a git repository (git rev-parse --git-dir failed)" >&2
    exit 1
  fi

  # 比較専用のルート相対パスを作る（git操作自体は元の files を絶対パスのまま使う。
  # normalize_to_repo_relative のコメント参照）。
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  local normalized_files=()
  local f
  for f in "${files[@]}"; do
    normalized_files+=("$(normalize_to_repo_relative "$repo_root" "$(canonicalize_path "$f")")")
  done

  # --- 手順0: クリーン確認 ---
  local porcelain_output
  porcelain_output="$(git status --porcelain 2>&1)"
  check_dirty_scope "$porcelain_output" "${normalized_files[@]}"

  if [ -n "$OUT_OF_SCOPE_LINES" ]; then
    echo "Error: uncommitted changes exist outside the mutated file(s); 'git checkout --' cannot guarantee a full restore. Offending path(s):" >&2
    printf '%s' "$OUT_OF_SCOPE_LINES" >&2
    exit 1
  fi
  if [ "$ANY_TARGET_DIRTY" = "false" ]; then
    echo "Error: none of the specified mutated file(s) show uncommitted changes; no mutation detected." >&2
    exit 1
  fi

  # --- 手順1: テスト実行＋失敗判定 ---
  run_test_command "$test_command"
  local test_exit="$LAST_EXIT_CODE"
  local test_output="$LAST_OUTPUT"

  local test_failed="false"
  local failure_kind="none"
  if [ "$test_exit" -ne 0 ]; then
    test_failed="true"
    failure_kind="$(classify_failure_kind "$test_output")"
  fi

  # --- 手順2: 復元 ---
  local restored="false"
  if git checkout -- "${files[@]}" 2>/dev/null; then
    local post_porcelain
    post_porcelain="$(git status --porcelain -- "${files[@]}" 2>&1)"
    # --- 手順3: 復元確認 ---
    if [ -z "$post_porcelain" ]; then
      restored="true"
    fi
  fi

  # --- 手順4: 復元できた場合のみ再実行してパス確認 ---
  local re_passed="false"
  if [ "$restored" = "true" ]; then
    run_test_command "$test_command"
    if [ "$LAST_EXIT_CODE" -eq 0 ]; then
      re_passed="true"
    fi
  fi

  jq -n \
    --argjson testFailed "$test_failed" \
    --arg failureKind "$failure_kind" \
    --argjson restored "$restored" \
    --argjson rePassed "$re_passed" \
    '{testFailed: $testFailed, failureKind: $failureKind, restored: $restored, rePassed: $rePassed}'

  if [ "$restored" = "true" ] && [ "$re_passed" = "true" ]; then
    exit 0
  else
    exit 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
