#!/bin/bash
# detect-dev-phase.sh
# 使い方: detect-dev-phase.sh [CLAUDE.md のパス]
# 導入先プロジェクトの CLAUDE.md に宣言された開発フェーズ（SDD期 / GDD期）を決定的に判定し、
# {phase, reason, source} の JSON を stdout に1個返す。
# 仕様の正本は scripts/specs/detect-dev-phase.md を参照。
#
# 設計上の要点（正本の再掲ではなく、実装を読む人向けの注記）:
# - 宣言が無い場合のみ SDD期 とみなす（後方互換）。宣言が不正な場合は SDD期 へ黙って
#   フォールバックせず phase: "invalid" を返す（GDD のゲート群が暗黙に無効化される事故を防ぐ）。
# - コードフェンス内の記述は判定対象にしない（CLAUDE.md が宣言書式の例を引用していても
#   誤判定しないため）。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 2
}

# 終了コード（scripts/specs/detect-dev-phase.md と一致させること）
DETECT_DEV_PHASE_EX_OK=0        # phase が sdd / gdd として確定した
DETECT_DEV_PHASE_EX_INVALID=1   # phase: "invalid"（宣言が不正。要人間判定）
DETECT_DEV_PHASE_EX_PREREQ=2    # 実行前提の欠落（jq 不在・引数不正・指定パスが読めない）

DETECT_DEV_PHASE_HEADING="開発フェーズ"
DETECT_DEV_PHASE_VALUE_SDD="SDD期"
DETECT_DEV_PHASE_VALUE_GDD="GDD期"

# 正規表現は変数へ入れてから `=~` の右辺に置く（バッククォートを含むパターンを
# [[ ]] へ直接書くとコマンド置換として解釈される余地があるため）。
# フェンス行。開始記号の連なり（3個以上）と、その後ろの情報文字列を捕捉する。
DETECT_DEV_PHASE_FENCE_RE='^[[:space:]]{0,3}(`{3,}|~{3,})[[:space:]]*(.*)$'
DETECT_DEV_PHASE_ANY_HEADING_RE='^#{1,6}[[:space:]]'
# 「- **フェーズ**: GDD期」の行。太字の有無・全角コロンは許容し、値は後段で正規化する。
DETECT_DEV_PHASE_FIELD_RE='^[[:space:]]*[-*][[:space:]]+\*{0,2}フェーズ\*{0,2}[[:space:]]*(:|：)[[:space:]]*(.+)$'

# 前後の空白・囲みの装飾（`**` / バッククォート）を除去する。
# 装飾は入れ子になりうる（`` `**GDD期**` `` / `` **`GDD期`** ``）ため、除去順に依存させず
# 値が変化しなくなるまで反復する。
dev_phase_trim() {
  local value="$1"
  local previous=""
  while [ "$value" != "$previous" ]; do
    previous="$value"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [ ${#value} -ge 4 ] && [[ "$value" == '**'*'**' ]]; then
      value="${value:2:${#value}-4}"
    elif [ ${#value} -ge 2 ] && [[ "$value" == '`'*'`' ]]; then
      value="${value:1:${#value}-2}"
    fi
  done
  printf '%s' "$value"
}

# CLAUDE.md 本文をスキャンし、判定結果を以下のグローバル変数へ格納する。
#   DEV_PHASE_PHASE  : "sdd" | "gdd" | "invalid"
#   DEV_PHASE_REASON : 理由コード（語彙は spec 参照）
#   DEV_PHASE_DETAIL : 人間向けの補足（stderr 用。無い場合は空文字列）
# 引数: 本文テキスト
detect_dev_phase_scan() {
  local body="$1"
  body="${body//$'\r'/}"

  local line
  local marker_run marker fence_info
  local fence_marker=""
  local fence_len=0
  local heading_level2=0
  local heading_other_level=0
  local in_section="false"
  local -a phase_values=()
  local heading_re="^(#{1,6})[[:space:]]+${DETECT_DEV_PHASE_HEADING}[[:space:]]*$"

  while IFS= read -r line; do
    # コードフェンス（``` / ~~~）の内側は判定対象外。
    # 閉じフェンスは「同じ記号・開始フェンス以上の長さ・情報文字列なし」の行だけとする
    # （4個のフェンス内に現れる3個のバッククォートで閉じてしまい、以降の本文を
    #   判定対象に戻してしまうのを防ぐ）。
    if [[ "$line" =~ $DETECT_DEV_PHASE_FENCE_RE ]]; then
      marker_run="${BASH_REMATCH[1]}"
      fence_info="${BASH_REMATCH[2]}"
      marker="${marker_run:0:1}"
      if [ -z "$fence_marker" ]; then
        fence_marker="$marker"
        fence_len="${#marker_run}"
      elif [ "$fence_marker" = "$marker" ] && [ "${#marker_run}" -ge "$fence_len" ] && [ -z "$fence_info" ]; then
        fence_marker=""
        fence_len=0
      fi
      continue
    fi
    [ -n "$fence_marker" ] && continue

    if [[ "$line" =~ $heading_re ]]; then
      if [ "${#BASH_REMATCH[1]}" -eq 2 ]; then
        heading_level2=$((heading_level2 + 1))
        in_section="true"
      else
        heading_other_level=$((heading_other_level + 1))
        in_section="false"
      fi
      continue
    fi

    # 見出しの出現でセクションは終わる（サブ見出し配下の記述は宣言とみなさない）
    if [[ "$line" =~ $DETECT_DEV_PHASE_ANY_HEADING_RE ]]; then
      in_section="false"
      continue
    fi

    if [ "$in_section" = "true" ] && [[ "$line" =~ $DETECT_DEV_PHASE_FIELD_RE ]]; then
      phase_values+=("$(dev_phase_trim "${BASH_REMATCH[2]}")")
    fi
  done <<<"$body"

  DEV_PHASE_DETAIL=""

  if [ "$heading_other_level" -gt 0 ]; then
    DEV_PHASE_PHASE="invalid"
    DEV_PHASE_REASON="malformed_phase_heading"
    DEV_PHASE_DETAIL="「${DETECT_DEV_PHASE_HEADING}」見出しの階層が '## ' ではありません（フェーズ宣言として認識できません）"
    return 0
  fi

  if [ "$heading_level2" -eq 0 ]; then
    DEV_PHASE_PHASE="sdd"
    DEV_PHASE_REASON="no_phase_section"
    return 0
  fi

  if [ "$heading_level2" -gt 1 ]; then
    DEV_PHASE_PHASE="invalid"
    DEV_PHASE_REASON="duplicate_phase_section"
    DEV_PHASE_DETAIL="「## ${DETECT_DEV_PHASE_HEADING}」見出しが ${heading_level2} 個あります（1個だけにしてください）"
    return 0
  fi

  if [ "${#phase_values[@]}" -eq 0 ]; then
    DEV_PHASE_PHASE="invalid"
    DEV_PHASE_REASON="missing_phase_field"
    DEV_PHASE_DETAIL="「## ${DETECT_DEV_PHASE_HEADING}」セクションに「- **フェーズ**: ${DETECT_DEV_PHASE_VALUE_SDD}|${DETECT_DEV_PHASE_VALUE_GDD}」の行がありません"
    return 0
  fi

  if [ "${#phase_values[@]}" -gt 1 ]; then
    DEV_PHASE_PHASE="invalid"
    DEV_PHASE_REASON="duplicate_phase_field"
    DEV_PHASE_DETAIL="「フェーズ」行が ${#phase_values[@]} 行あります（1行だけにしてください）"
    return 0
  fi

  local value="${phase_values[0]}"

  if [[ "$value" == *"{"* || "$value" == *"}"* ]]; then
    DEV_PHASE_PHASE="invalid"
    DEV_PHASE_REASON="unreplaced_placeholder"
    DEV_PHASE_DETAIL="フェーズの値がテンプレートのプレースホルダのままです: ${value}"
    return 0
  fi

  case "$value" in
    "$DETECT_DEV_PHASE_VALUE_SDD")
      DEV_PHASE_PHASE="sdd"
      DEV_PHASE_REASON="declared_sdd"
      ;;
    "$DETECT_DEV_PHASE_VALUE_GDD")
      DEV_PHASE_PHASE="gdd"
      DEV_PHASE_REASON="declared_gdd"
      ;;
    *)
      DEV_PHASE_PHASE="invalid"
      DEV_PHASE_REASON="unknown_phase_value"
      DEV_PHASE_DETAIL="フェーズの値が許容値（${DETECT_DEV_PHASE_VALUE_SDD} / ${DETECT_DEV_PHASE_VALUE_GDD}）ではありません: ${value}"
      ;;
  esac
  return 0
}

# 判定対象の CLAUDE.md を解決し、パスを stdout に出す。
# 引数省略時は cwd → git リポジトリルート の順に探す（サブディレクトリからの実行で
# 宣言を見落とし、GDD期のプロジェクトを SDD期 と誤判定しないため）。
# 見つからない場合は非0を返す（宣言なし = SDD期 として扱うのは呼び出し側の責務）。
dev_phase_resolve_source() {
  local explicit="${1:-}"
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return 0
  fi
  if [ -f "CLAUDE.md" ]; then
    printf '%s' "CLAUDE.md"
    return 0
  fi
  local root
  if root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$root" ] && [ -f "${root}/CLAUDE.md" ]; then
    printf '%s' "${root}/CLAUDE.md"
    return 0
  fi
  return 1
}

dev_phase_emit() {
  local phase="$1" reason="$2" source_path="$3"
  local source_json
  if [ -z "$source_path" ]; then
    source_json="null"
  else
    source_json="$(jq -n --arg s "$source_path" '$s')"
  fi
  jq -n --arg phase "$phase" --arg reason "$reason" --argjson source "$source_json" \
    '{phase: $phase, reason: $reason, source: $source}'
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} [CLAUDE.md のパス]

  引数を省略した場合は cwd の CLAUDE.md、無ければ git リポジトリルートの CLAUDE.md を見る。
  stdout に {"phase":"sdd"|"gdd"|"invalid","reason":"...","source":"..."|null} を1個出力する。
  exit code: ${DETECT_DEV_PHASE_EX_OK}=sdd/gdd 確定 / ${DETECT_DEV_PHASE_EX_INVALID}=invalid（要人間判定） / ${DETECT_DEV_PHASE_EX_PREREQ}=実行前提の欠落
EOF
}

main() {
  local explicit=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        print_usage
        exit 0
        ;;
      -*)
        echo "Error: unknown option: $1" >&2
        printf '%s\n' '{"status":"error","error":"unknown option"}' >&2
        print_usage
        exit "$DETECT_DEV_PHASE_EX_PREREQ"
        ;;
      *)
        if [ -n "$explicit" ]; then
          echo "Error: too many arguments: $1" >&2
          printf '%s\n' '{"status":"error","error":"too many arguments"}' >&2
          print_usage
          exit "$DETECT_DEV_PHASE_EX_PREREQ"
        fi
        explicit="$1"
        shift
        ;;
    esac
  done

  if ! check_jq '{"status":"error","error":"jq not found"}'; then
    exit "$DETECT_DEV_PHASE_EX_PREREQ"
  fi

  local source_path
  if ! source_path="$(dev_phase_resolve_source "$explicit")"; then
    # CLAUDE.md 自体が無い = 宣言が無い。後方互換のため SDD期 とみなす
    dev_phase_emit "sdd" "no_claude_md" ""
    exit "$DETECT_DEV_PHASE_EX_OK"
  fi

  if [ ! -f "$source_path" ] || [ ! -r "$source_path" ]; then
    echo "Error: CLAUDE.md not readable: ${source_path}" >&2
    printf '%s\n' '{"status":"error","error":"CLAUDE.md not readable"}' >&2
    exit "$DETECT_DEV_PHASE_EX_PREREQ"
  fi

  local body
  body="$(cat "$source_path")"

  detect_dev_phase_scan "$body"

  dev_phase_emit "$DEV_PHASE_PHASE" "$DEV_PHASE_REASON" "$source_path"

  if [ "$DEV_PHASE_PHASE" = "invalid" ]; then
    echo "Error: 開発フェーズ宣言が不正です（${source_path}）: ${DEV_PHASE_DETAIL}" >&2
    echo "  SDD期 へのフォールバックは行いません。人間が宣言を修正するまでフェーズ依存の処理を進めないでください。" >&2
    exit "$DETECT_DEV_PHASE_EX_INVALID"
  fi

  exit "$DETECT_DEV_PHASE_EX_OK"
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
