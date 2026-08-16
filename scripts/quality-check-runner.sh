#!/bin/bash
# quality-check-runner.sh
# 使い方: scripts/quality-check-runner.sh [--auto-fix CMD]... [--lint CMD] [--typecheck CMD] [--test CMD]（詳細は下記参照）
# 仕様の正本は scripts/specs/quality-check-runner.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 純粋関数（外部コマンドを起動しない。source して直接テスト可能）
# ---------------------------------------------------------------------------

# exit code から pass/fail を判定する。
gate_status_from_exit() {
  local exit_code="$1"
  if [ "$exit_code" -eq 0 ]; then
    echo "pass"
  else
    echo "fail"
  fi
}

# 各ゲートの status（"pass"|"fail"|"skip"）から総合判定を行う。
# いずれかが fail なら fail、それ以外（pass/skip のみ）は pass。
compute_result() {
  local s
  for s in "$@"; do
    if [ "$s" = "fail" ]; then
      echo "fail"
      return
    fi
  done
  echo "pass"
}

# 件数抽出の共通処理。対象行それぞれから1件ずつ抽出して**合算**する。
# 引数: $1 出力全体 / $2 集計対象行を絞り込む ERE（空文字なら全行が対象） /
#       $3 1行から件数だけを取り出す sed -nE の式
# 出力: 合計値。1件も抽出できなければ文字列 "null"（jq --argjson でそのまま null になる）。
#
# 最後の1行だけを採用（tail -1）していないのは、npm workspaces や cargo のように
# **1回の実行で集計行が複数回出力される**場合に実態と乖離するため（実測: 934 tests に
# 対し最後のワークスペース分の 246 だけを報告していた。Issue #154）。
# 二重計上の回避は呼び出し側が $2 で集計行を絞り込むことで担保する。
sum_line_matches() {
  local output="$1" filter="$2" extract="$3"
  local lines line value total=""

  if [ -n "$filter" ]; then
    lines="$(printf '%s\n' "$output" | grep -E "$filter")"
  else
    lines="$output"
  fi

  if [ -n "$lines" ]; then
    while IFS= read -r line; do
      value="$(printf '%s\n' "$line" | sed -nE "$extract")"
      [ -z "$value" ] && continue
      # 10# を付けて基数10で解釈する（"08" 等の先頭ゼロを8進数と解釈させない）
      total=$((${total:-0} + 10#$value))
    done <<<"$lines"
  fi

  if [ -z "$total" ]; then
    printf 'null\n'
  else
    printf '%s\n' "$total"
  fi
}

# lint 出力から errors/warnings 件数を best-effort 抽出する。
# 対応形式の例: ESLint の "X problems (Y errors, Z warnings)"
# 抽出できない場合は文字列 "null" を返す（jq --argjson でそのまま null になる）。
# 出力: "<errors> <warnings>"（スペース区切り）
#
# 数値の手前が非数字（または行頭）であることを要求するのは、貪欲マッチにより
# 複数桁の数値の末尾だけを拾ってしまう誤抽出を防ぐため（例: "138 passed" から
# "8" のみを誤って抽出しない）。
parse_lint_counts() {
  local output="$1"
  local filter="" errors warnings
  # ESLint 形式の集計行（"X problems (...)"）が在る場合はその行だけを合算対象にする。
  # 個別の指摘行を巻き込んで二重計上しないため。無い場合は全行を対象にする。
  if printf '%s\n' "$output" | grep -qE '[0-9]+ problems?'; then
    filter='[0-9]+ problems?'
  fi
  errors="$(sum_line_matches "$output" "$filter" 's/.*(^|[^0-9])([0-9]+) errors?.*/\2/p')"
  warnings="$(sum_line_matches "$output" "$filter" 's/.*(^|[^0-9])([0-9]+) warnings?.*/\2/p')"
  printf '%s %s\n' "$errors" "$warnings"
}

# 型チェック出力から errors 件数を best-effort 抽出する。
# 対応形式の例: tsc の "Found N error(s)."
# "Found " の直後は常に非数字（スペース）のため境界ガードは不要。
# 集計行（"Found N errors"）のみを対象にするため、個別の型エラー行は合算に混ざらない。
parse_typecheck_errors() {
  local output="$1"
  sum_line_matches "$output" 'Found [0-9]+ errors?' 's/.*Found ([0-9]+) errors?.*/\1/p'
}

# テスト出力から passed/failed/skipped 件数を best-effort 抽出する。
# 対応形式の例: Jest/Vitest の "Tests: N failed, M passed, K skipped, T total"、
# pytest の "M passed, N failed, K skipped in Ts"
# 出力: "<passed> <failed> <skipped>"（スペース区切り）
parse_test_counts() {
  local output="$1"
  local filter="" passed failed skipped
  # Jest/Vitest は "Test Suites:"/"Test Files"（スイート数）と "Tests:"（テスト件数）の
  # 2行を出すため、複数形 "Tests" の集計行が在る場合はその行だけを合算対象にして
  # スイート数の二重計上を防ぐ。無い場合（pytest・cargo 等）は全行を対象にする。
  local tests_marker='(^|[^A-Za-z])Tests[[:space:]:]'
  if printf '%s\n' "$output" | grep -qE "$tests_marker"; then
    filter="$tests_marker"
  fi
  passed="$(sum_line_matches "$output" "$filter" 's/.*(^|[^0-9])([0-9]+) passed.*/\2/p')"
  failed="$(sum_line_matches "$output" "$filter" 's/.*(^|[^0-9])([0-9]+) failed.*/\2/p')"
  skipped="$(sum_line_matches "$output" "$filter" 's/.*(^|[^0-9])([0-9]+) skipped.*/\2/p')"
  printf '%s %s %s\n' "$passed" "$failed" "$skipped"
}

# 複数コマンド文字列を区切り文字で連結する（auto_fix.summary 用）。
# bash 3.2 では "${arr[*]}" は IFS の先頭1文字しか区切りに使えないため、
# 複数文字の区切り（" → "）に対応するためループで連結する。
join_by() {
  local sep="$1"
  shift
  if [ "$#" -eq 0 ]; then
    return
  fi
  local first="$1"
  shift
  printf '%s' "$first"
  local item
  for item in "$@"; do
    printf '%s%s' "$sep" "$item"
  done
}

# ---------------------------------------------------------------------------
# 外部コマンド実行（副作用あり）
# ---------------------------------------------------------------------------

# 渡されたコマンド文字列を実行し、stdout/stderr を結合してグローバル変数
# LAST_OUTPUT / LAST_EXIT_CODE に格納する。
# 生の出力は stderr にも転記する（出力規約: stdout にはJSONのみ。人間/LLMが
# 失敗内容を分析できるよう、件数抽出で捨てられる詳細を stderr 側に残す）。
run_command() {
  local label="$1" cmd="$2"
  echo "--- ${label}: ${cmd} ---" >&2
  LAST_OUTPUT="$(bash -c "$cmd" 2>&1)"
  LAST_EXIT_CODE=$?
  printf '%s\n' "$LAST_OUTPUT" >&2
  echo "--- ${label} exit: ${LAST_EXIT_CODE} ---" >&2
}

# auto-fix コマンド群を検出順に1回ずつ実行する。
# 引数: auto-fix コマンド文字列の可変長リスト（0個可）
# 結果はグローバル変数 AUTO_FIX_APPLIED（"true"|"false"） / AUTO_FIX_SUMMARY に格納する。
# 個々のコマンドが失敗しても auto-fix 全体は継続する（機械的に直せる範囲の適用が
# 目的であり、型エラー・テスト失敗の修正は対象外のため。SKILL.md 手順2参照）。
run_auto_fix() {
  if [ "$#" -eq 0 ]; then
    AUTO_FIX_APPLIED="false"
    AUTO_FIX_SUMMARY=""
    return
  fi

  AUTO_FIX_APPLIED="true"
  local cmd
  for cmd in "$@"; do
    run_command "auto-fix" "$cmd"
    if [ "$LAST_EXIT_CODE" -ne 0 ]; then
      echo "Warning: auto-fix command failed (exit ${LAST_EXIT_CODE}): ${cmd}" >&2
    fi
  done
  AUTO_FIX_SUMMARY="$(join_by " → " "$@")"
}

# lint ゲートの結果JSONを組み立てる。コマンド未指定なら skip。
build_lint_gate_json() {
  local cmd="$1"
  if [ -z "$cmd" ]; then
    jq -n '{status:"skip", errors:null, warnings:null}'
    return
  fi
  run_command "lint" "$cmd"
  local status counts errors warnings
  status="$(gate_status_from_exit "$LAST_EXIT_CODE")"
  counts="$(parse_lint_counts "$LAST_OUTPUT")"
  errors="$(printf '%s' "$counts" | cut -d' ' -f1)"
  warnings="$(printf '%s' "$counts" | cut -d' ' -f2)"
  jq -n --arg status "$status" --argjson errors "$errors" --argjson warnings "$warnings" \
    '{status: $status, errors: $errors, warnings: $warnings}'
}

# 型チェックゲートの結果JSONを組み立てる。コマンド未指定なら skip。
build_typecheck_gate_json() {
  local cmd="$1"
  if [ -z "$cmd" ]; then
    jq -n '{status:"skip", errors:null}'
    return
  fi
  run_command "typecheck" "$cmd"
  local status errors
  status="$(gate_status_from_exit "$LAST_EXIT_CODE")"
  errors="$(parse_typecheck_errors "$LAST_OUTPUT")"
  jq -n --arg status "$status" --argjson errors "$errors" \
    '{status: $status, errors: $errors}'
}

# テストゲートの結果JSONを組み立てる。コマンド未指定なら skip。
build_test_gate_json() {
  local cmd="$1"
  if [ -z "$cmd" ]; then
    jq -n '{status:"skip", passed:null, failed:null, skipped:null}'
    return
  fi
  run_command "test" "$cmd"
  local status counts passed failed skipped
  status="$(gate_status_from_exit "$LAST_EXIT_CODE")"
  counts="$(parse_test_counts "$LAST_OUTPUT")"
  passed="$(printf '%s' "$counts" | cut -d' ' -f1)"
  failed="$(printf '%s' "$counts" | cut -d' ' -f2)"
  skipped="$(printf '%s' "$counts" | cut -d' ' -f3)"
  jq -n --arg status "$status" --argjson passed "$passed" --argjson failed "$failed" --argjson skipped "$skipped" \
    '{status: $status, passed: $passed, failed: $failed, skipped: $skipped}'
}

# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} [--auto-fix CMD]... [--lint CMD] [--typecheck CMD] [--test CMD]

  --auto-fix CMD   自動修正コマンド（0回以上指定可。検出順に実行）
  --lint CMD       リントコマンド（省略時は lint ゲートを skip 扱い。1回のみ指定可）
  --typecheck CMD  型チェックコマンド（省略時は typecheck ゲートを skip 扱い。1回のみ指定可）
  --test CMD       テストコマンド（省略時は test ゲートを skip 扱い。1回のみ指定可）

コマンドは呼び出し側（LLM）がプロジェクト設定（CLAUDE.md / package.json 等）から
特定した上で渡す。このスクリプトはコマンドの意味を解釈せず、実行してexit codeで
判定するだけ。
EOF
}

main() {
  local auto_fix_cmds=()
  local lint_cmd="" typecheck_cmd="" test_cmd=""
  # 値の中身（空文字か否か）でなく「フラグを見たか」を独立に追跡する。
  # lint_cmd等の非空判定で重複検出すると、1回目に空文字を渡した場合
  # （="" は skip 相当の指定）に2回目を誤って上書き許可してしまうため。
  local lint_seen="false" typecheck_seen="false" test_seen="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --auto-fix)
        if [ "$#" -lt 2 ]; then
          echo "Error: --auto-fix requires a value" >&2
          print_usage
          exit 1
        fi
        auto_fix_cmds+=("$2")
        shift 2
        ;;
      --lint)
        if [ "$#" -lt 2 ]; then
          echo "Error: --lint requires a value" >&2
          print_usage
          exit 1
        fi
        if [ "$lint_seen" = "true" ]; then
          echo "Error: --lint specified more than once" >&2
          print_usage
          exit 1
        fi
        lint_seen="true"
        lint_cmd="$2"
        shift 2
        ;;
      --typecheck)
        if [ "$#" -lt 2 ]; then
          echo "Error: --typecheck requires a value" >&2
          print_usage
          exit 1
        fi
        if [ "$typecheck_seen" = "true" ]; then
          echo "Error: --typecheck specified more than once" >&2
          print_usage
          exit 1
        fi
        typecheck_seen="true"
        typecheck_cmd="$2"
        shift 2
        ;;
      --test)
        if [ "$#" -lt 2 ]; then
          echo "Error: --test requires a value" >&2
          print_usage
          exit 1
        fi
        if [ "$test_seen" = "true" ]; then
          echo "Error: --test specified more than once" >&2
          print_usage
          exit 1
        fi
        test_seen="true"
        test_cmd="$2"
        shift 2
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        echo "Error: unknown option '$1'" >&2
        print_usage
        exit 1
        ;;
    esac
  done

  if ! check_jq; then
    exit 2
  fi

  # bash 3.2 (macOS既定) は set -u 下で空配列の "${arr[@]}" 展開が
  # unbound variable エラーになるため、"${arr[@]+"${arr[@]}"}" イディオムで回避する。
  run_auto_fix ${auto_fix_cmds[@]+"${auto_fix_cmds[@]}"}

  local lint_json typecheck_json test_json
  lint_json="$(build_lint_gate_json "$lint_cmd")"
  typecheck_json="$(build_typecheck_gate_json "$typecheck_cmd")"
  test_json="$(build_test_gate_json "$test_cmd")"

  local lint_status typecheck_status test_status result
  lint_status="$(jq -r '.status' <<<"$lint_json")"
  typecheck_status="$(jq -r '.status' <<<"$typecheck_json")"
  test_status="$(jq -r '.status' <<<"$test_json")"
  result="$(compute_result "$lint_status" "$typecheck_status" "$test_status")"

  jq -n \
    --arg result "$result" \
    --argjson auto_fix_applied "$AUTO_FIX_APPLIED" \
    --arg auto_fix_summary "$AUTO_FIX_SUMMARY" \
    --argjson lint "$lint_json" \
    --argjson typecheck "$typecheck_json" \
    --argjson test "$test_json" \
    '{
      result: $result,
      auto_fix: {applied: $auto_fix_applied, summary: $auto_fix_summary},
      gates: {lint: $lint, typecheck: $typecheck, test: $test}
    }'

  if [ "$result" = "pass" ]; then
    exit 0
  else
    exit 1
  fi
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
