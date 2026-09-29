#!/bin/bash
# ci-wait-pr.sh --pr <番号> [--timeout <秒>] [--interval <秒>]
#
# plugin/scripts/ci-wait.sh（位置引数: <PR> [timeout] [interval]）を、command 種類の引数の形（--<名前> <値>）で呼ぶための薄い包み。
# ci-wait.sh の JSON（scripts/specs/ci-wait.md）をそのまま stdout に出す。ただし PR が見つからなかった（pr_exists: false）場合は
# CI 未設定（ci: none）と区別できないので、非 0 で終わる（PR を作った直後に呼ぶので、見つからないのは異常。fail-closed）。
# また ci: red で failure_log_excerpt が空（空白だけを含む）なら ci を red_no_log に替える（#278）。CI が実行されずに失敗した
# （例: Actions が Billing でジョブを起動しない。steps が 0 件で --log-failed が空）ものは、何を直すかの入力が無いので
# fix へ送らない。ci-wait.sh の出力（スキルも読む）は変えず、runtime の包みの中だけで区別する。
# ci-wait.sh の置き場は runtime が HARNESS_SCRIPTS_DIR で渡す。

set -u

pr=""
timeout=""
interval=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    *) echo "Error: unknown argument '$1' (usage: ci-wait-pr.sh --pr <number> [--timeout <seconds>] [--interval <seconds>])" >&2; exit 2 ;;
  esac
done
if ! [[ "$pr" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --pr must be a positive integer, got '${pr}'" >&2
  exit 2
fi
script="${HARNESS_SCRIPTS_DIR:-}/ci-wait.sh"
if [ -z "${HARNESS_SCRIPTS_DIR:-}" ] || [ ! -f "$script" ]; then
  echo "Error: ci-wait.sh not found (HARNESS_SCRIPTS_DIR='${HARNESS_SCRIPTS_DIR:-}')" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but was not found in PATH" >&2
  exit 1
fi

args=("$pr")
if [ -n "$timeout" ] || [ -n "$interval" ]; then
  args+=("${timeout:-900}")
fi
if [ -n "$interval" ]; then
  args+=("$interval")
fi

out="$(bash "$script" "${args[@]}")"
rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
if [ "$(jq -r '.pr_exists' <<<"$out" 2>/dev/null)" != "true" ]; then
  echo "Error: PR #${pr} was not found by ci-wait.sh (pr_exists is not true); not treating it as 'no CI'" >&2
  exit 1
fi
if [ "$(jq -r '.ci' <<<"$out")" = "red" ] && [ -z "$(jq -r '.failure_log_excerpt' <<<"$out" | tr -d '[:space:]')" ]; then
  out="$(jq -c '.ci = "red_no_log"' <<<"$out")" || exit 1
fi
printf '%s\n' "$out"
