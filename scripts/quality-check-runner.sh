#!/bin/bash
# quality-check-runner.sh
# /quality-check スキルの手順2-4（自動修正の事前適用 → lint/型チェック/テスト実行 →
# 機械可読JSON構築）を切り出した決定的なシェルスクリプト。
#
# コマンド特定（どのコマンドが lint/型チェック/テスト/auto-fix に当たるか）は
# プロジェクトごとに意味理解が必要なため、呼び出し側（LLM）が CLAUDE.md や
# package.json 等から特定した上で、特定済みのコマンド文字列を引数として渡す。
# このスクリプトはコマンド文字列を「実行してexit codeで判定する」だけで、
# コマンドの意味は一切解釈しない。
#
# 使い方:
#   quality-check-runner.sh [--auto-fix CMD]... [--lint CMD] [--typecheck CMD] [--test CMD]
#     --auto-fix CMD   自動修正コマンド。0回以上指定可。指定順に1回ずつ実行する
#     --lint CMD       リント（チェック用）コマンド。1回のみ指定可
#     --typecheck CMD  型チェックコマンド。1回のみ指定可
#     --test CMD       テストコマンド。1回のみ指定可
#   lint/typecheck/test は該当コマンドを特定できなかった場合、フラグごと省略する
#   （その場合そのゲートは status: "skip" として扱われ、失敗とはしない）。
#   lint/typecheck/test を2回以上指定した場合はエラー（exit 1）とする
#   （後勝ちで無言に上書きすると、呼び出し側の指定ミスに気付けないため）。
#
# 出力（stdout にJSON1個。skills/quality-check/SKILL.md の機械可読JSON契約と互換）:
#   {
#     "result": "pass" | "fail",
#     "auto_fix": {"applied": bool, "summary": "cmd1 → cmd2"},
#     "gates": {
#       "lint":      {"status": "pass"|"fail"|"skip", "errors": n|null, "warnings": n|null},
#       "typecheck": {"status": "pass"|"fail"|"skip", "errors": n|null},
#       "test":      {"status": "pass"|"fail"|"skip", "passed": n|null, "failed": n|null, "skipped": n|null}
#     }
#   }
#
# - `result` は lint/typecheck/test のいずれかが fail なら fail、それ以外は pass
# - 各ゲートの `status` は **exit code のみ**で判定する（0 -> pass、非0 -> fail、
#   コマンド未指定 -> skip）。件数フィールド（errors/warnings/passed/failed/skipped）は
#   ツールごとに出力形式が異なり完全決定化できないため best-effort 抽出とし、
#   抽出できない場合は null を返す（status の判定には使わない）
# - 終了コード: result が pass なら 0、fail なら 1（jq不在等の致命的エラー時は 2）
# - 各コマンドの生の stdout/stderr は stderr に転記する（`--- <gate>: <cmd> ---` 区切り）。
#   件数抽出で丸められる前の詳細（lintエラー箇所・型エラー内容・失敗テストのスタック
#   トレース等）は、失敗時に呼び出し側（LLM）が原因分析するために必要なため
#   （出力規約: stdout にはJSONのみ、人間/LLM向け詳細は stderr）
#
# gate 実行（外部コマンドを起動する run_command / build_*_gate_json）と、
# 出力テキストからの件数抽出・ステータス判定（parse_* / gate_status_from_exit /
# compute_result）を関数として分離している。このファイルを `source` すれば
# 外部コマンドを起動せずに purely な抽出・判定関数を直接テストできる。

set -u

# ---------------------------------------------------------------------------
# 前提チェック
# ---------------------------------------------------------------------------

check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
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
  local errors warnings
  errors="$(printf '%s\n' "$output" | sed -nE 's/.*(^|[^0-9])([0-9]+) errors?.*/\2/p' | tail -1)"
  warnings="$(printf '%s\n' "$output" | sed -nE 's/.*(^|[^0-9])([0-9]+) warnings?.*/\2/p' | tail -1)"
  [ -z "$errors" ] && errors="null"
  [ -z "$warnings" ] && warnings="null"
  printf '%s %s\n' "$errors" "$warnings"
}

# 型チェック出力から errors 件数を best-effort 抽出する。
# 対応形式の例: tsc の "Found N error(s)."
# "Found " の直後は常に非数字（スペース）のため境界ガードは不要。
parse_typecheck_errors() {
  local output="$1"
  local errors
  errors="$(printf '%s\n' "$output" | sed -nE 's/.*Found ([0-9]+) errors?.*/\1/p' | tail -1)"
  [ -z "$errors" ] && errors="null"
  printf '%s\n' "$errors"
}

# テスト出力から passed/failed/skipped 件数を best-effort 抽出する。
# 対応形式の例: Jest/Vitest の "Tests: N failed, M passed, K skipped, T total"、
# pytest の "M passed, N failed, K skipped in Ts"
# 出力: "<passed> <failed> <skipped>"（スペース区切り）
parse_test_counts() {
  local output="$1"
  local passed failed skipped
  passed="$(printf '%s\n' "$output" | sed -nE 's/.*(^|[^0-9])([0-9]+) passed.*/\2/p' | tail -1)"
  failed="$(printf '%s\n' "$output" | sed -nE 's/.*(^|[^0-9])([0-9]+) failed.*/\2/p' | tail -1)"
  skipped="$(printf '%s\n' "$output" | sed -nE 's/.*(^|[^0-9])([0-9]+) skipped.*/\2/p' | tail -1)"
  [ -z "$passed" ] && passed="null"
  [ -z "$failed" ] && failed="null"
  [ -z "$skipped" ] && skipped="null"
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
