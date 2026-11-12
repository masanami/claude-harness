#!/bin/bash
# ci-trigger.sh --base <ブランチ>
# CI の運用の宣言 .claude-harness/ci.json を PR の宛先（origin/<base>）から読み、CI をいつ走らせるリポジトリかを返す（#363）。
# 仕様の正本は scripts/specs/ci-trigger.md を参照。
#
# 宣言の形: {"trigger": "per-push" | "after-merge"}
#   per-push    : PR の push のたびに CI が走る（既定。宣言・キーが無いときもこれ）
#   after-merge : PR では CI が走らず、既定ブランチへのマージの後（既定ブランチへの push）だけ走る
# 壊れた宣言（JSON として読めない・オブジェクト 1 つでない・trigger が文字列でない・知らない値）は、stderr に
# "Warning: ..." を 1 行出して per-push として扱う（受け付けない before-merge も知らない値）。CI を飛ばす側（after-merge）へは、
# 正しく宣言されたときだけ倒す。
#
# 読み手は runtime の ticket の ci の段（runtime/workflows/scripts/ci-wait-pr.sh）だけ。/pr-merge は宣言を読まない（宣言に関わらず即時マージ）。
# 宣言は品質ゲートの宣言（.claude-harness/quality-gate.json。runtime/workflows/scripts/quality-gate.sh）と同じく、
# 作業ブランチではなく PR の宛先の最新から読む（origin から base を取り直す）。
#
# stdout に JSON を 1 つ出す:
#   {"trigger": "per-push"|"after-merge", "declared": <bool>,
#    "declaration": {"path": ".claude-harness/ci.json", "ref": "origin/<base>", "commit": "<SHA>"|null},
#    "warning": "<警告。無ければ空文字>"}
# 終了コード: 0（宣言の有無・壊れ方に関わらず）/ 1（jq が無い）/ 2（引数の誤り）

set -u -o pipefail

CI_TRIGGER_DECL_PATH=".claude-harness/ci.json"
CI_TRIGGER_USAGE="usage: ci-trigger.sh --base <branch>"

ci_trigger_main() {
  local base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        if [ $# -lt 2 ]; then echo "Error: $1 needs a value ($CI_TRIGGER_USAGE)" >&2; return 2; fi
        base="$2"; shift 2 ;;
      *) echo "Error: unknown argument '$1' ($CI_TRIGGER_USAGE)" >&2; return 2 ;;
    esac
  done
  if [ -z "$base" ] || [[ "$base" == -* ]] || ! [[ "$base" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "Error: --base must be a branch name, got '${base}' ($CI_TRIGGER_USAGE)" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but was not found in PATH" >&2
    return 1
  fi

  local ref="refs/remotes/origin/${base}" commit="" trigger="per-push" declared=false warning="" decl
  # 宛先の最新を取り直す。取れなければ古い版で決めず、CI を待つ側（per-push）に倒す。
  if git fetch -q origin "+refs/heads/${base}:${ref}" >/dev/null 2>&1 &&
    commit="$(git rev-parse --verify -q "${ref}^{commit}")"; then
    if git cat-file -e "${commit}:${CI_TRIGGER_DECL_PATH}" 2>/dev/null; then
      declared=true
      if ! decl="$(git cat-file blob "${commit}:${CI_TRIGGER_DECL_PATH}" 2>/dev/null)"; then
        warning="${CI_TRIGGER_DECL_PATH} を origin/${base}（${commit}）から読めない。per-push として扱う"
      elif ! jq -s -e 'length == 1 and (.[0] | type == "object")' <<<"$decl" >/dev/null 2>&1; then
        warning="origin/${base}（${commit}）の ${CI_TRIGGER_DECL_PATH} が JSON のオブジェクト 1 つになっていない。per-push として扱う"
      else
        case "$(jq -c '.trigger' <<<"$decl")" in
          null | '"per-push"') trigger="per-push" ;;
          '"after-merge"') trigger="after-merge" ;;
          *) warning="origin/${base}（${commit}）の ${CI_TRIGGER_DECL_PATH} の trigger が知らない値（$(jq -c '.trigger' <<<"$decl")。per-push か after-merge）。per-push として扱う" ;;
        esac
      fi
    fi
  else
    commit=""
    warning="PR の宛先 '${base}' を origin から取得できない。${CI_TRIGGER_DECL_PATH} を読まずに per-push として扱う"
  fi

  if [ -n "$warning" ]; then
    echo "Warning: ${warning}" >&2
  fi
  jq -n --arg trigger "$trigger" --argjson declared "$declared" --arg path "$CI_TRIGGER_DECL_PATH" \
    --arg ref "origin/${base}" --arg commit "$commit" --arg warning "$warning" \
    '{trigger: $trigger, declared: $declared,
      declaration: {path: $path, ref: $ref, commit: (if $commit == "" then null else $commit end)},
      warning: $warning}'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ci_trigger_main "$@"
  exit $?
fi
