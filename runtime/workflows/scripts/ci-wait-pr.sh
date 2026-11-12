#!/bin/bash
# ci-wait-pr.sh --pr <番号> [--base <ブランチ>] [--timeout <秒>] [--interval <秒>]
#
# plugin/scripts/ci-wait.sh（位置引数: <PR> [timeout] [interval]）を、command 種類の引数の形（--<名前> <値>）で呼ぶための薄い包み。
# ci-wait.sh の JSON（scripts/specs/ci-wait.md）をそのまま stdout に出す。ただし PR が見つからなかった（pr_exists: false）場合は
# CI 未設定（ci: none）と区別できないので、非 0 で終わる（PR を作った直後に呼ぶので、見つからないのは異常。fail-closed）。
# また ci: red で failure_log_excerpt が空（空白だけを含む）なら ci を red_no_log に替える（#278）。CI が実行されずに失敗した
# （例: Actions が Billing でジョブを起動しない。steps が 0 件で --log-failed が空）ものは、何を直すかの入力が無いので
# fix へ送らない。ci-wait.sh の出力（スキルも読む）は変えず、runtime の包みの中だけで区別する。
# --base を渡すと、CI の運用の宣言 .claude-harness/ci.json を PR の宛先（origin/<base>）から plugin/scripts/ci-trigger.sh で読む
# （#363）。{"trigger": "after-merge"}（PR では CI が走らず、既定ブランチへのマージの後だけ走る）なら ci-wait.sh を呼ばず
# （ポーリングも、チェック 0 件を約 2 分待つ none の確定〔#341〕もしない）、PR の存在だけを確かめて ci: skipped を出す（none とは
# 別の値。run の記録で見分ける）。宣言が無い・per-push・壊れた宣言（ci-trigger.sh が警告を出して per-push を返す）・読み手が
# 失敗したときは、今までどおり ci-wait.sh を同じ引数で呼ぶ。CI を飛ばすのは after-merge と正しく読めたときだけ。
# ci-wait.sh・ci-trigger.sh の置き場は runtime が HARNESS_SCRIPTS_DIR で渡す。

set -u

pr=""
base=""
timeout=""
interval=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    *) echo "Error: unknown argument '$1' (usage: ci-wait-pr.sh --pr <number> [--base <branch>] [--timeout <seconds>] [--interval <seconds>])" >&2; exit 2 ;;
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

# CI の運用の宣言（#363）。読めなければ（読み手の失敗を含む）CI を待つ側に倒す。
trigger="per-push"
if [ -n "$base" ]; then
  reader="${HARNESS_SCRIPTS_DIR}/ci-trigger.sh"
  if [ ! -f "$reader" ]; then
    echo "Warning: ci-trigger.sh not found in HARNESS_SCRIPTS_DIR; waiting for CI as per-push" >&2
  elif ! decl_out="$(bash "$reader" --base "$base")"; then
    echo "Warning: ci-trigger.sh failed; waiting for CI as per-push" >&2
  else
    trigger="$(jq -r '.trigger // "per-push"' <<<"$decl_out" 2>/dev/null || echo per-push)"
  fi
fi
if [ "$trigger" = "after-merge" ]; then
  if ! view="$(gh pr view "$pr" --json number,url 2>/dev/null)" || [ "$(jq -r '.number' <<<"$view" 2>/dev/null)" != "$pr" ]; then
    echo "Error: PR #${pr} was not found (gh pr view failed); not treating it as a skipped CI" >&2
    exit 1
  fi
  jq -c '{ci: "skipped", failed_checks: [], failure_log_excerpt: "", pr_url: .url, pr_number: .number, pr_exists: true}' <<<"$view"
  exit 0
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
