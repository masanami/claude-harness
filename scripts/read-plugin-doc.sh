#!/bin/bash
# read-plugin-doc.sh
# プラグイン同梱の参照ドキュメント（skills/*/references/, skills/*/templates/,
# scripts/specs/, scripts/README.md）を **stdout へそのまま出力**して配送する。
#
# なぜ Read ツールではなくこの経路が要るか:
#   プラグイン配下は利用側プロジェクトの作業ディレクトリの外にあるため、Read ツールでの
#   読み出しは利用側の allow 設定が無い限り拒否される。対話セッションでは人間が都度許可
#   できるが、headless 委譲（`claude -p`）には許可する相手がいないため **拒否がそのまま
#   「読めない」で確定する**。しかもモデルは読めないまま手順を推測して完走できてしまい、
#   書式・停止条件だけが外れた成果物が「成功」に見える（実測: /guarantee-audit bootstrap が
#   references/bootstrap-mode.md を読めないまま完走し、検証器の exit 2 で初めて発覚した）。
#   本スクリプトはランチャー経由（`Bash(claude-harness-run:*)` の1行で allowlist 済みの経路）で
#   同じ内容を配送するため、追加の allow 設定なしに headless でも本文が届く。
#   加えて **配送できない場合は必ず非0 終了する**ので、失敗が沈黙しない。
#
# 使い方:
#   claude-harness-run read-plugin-doc <プラグインルート相対パス>
#
#   例:
#     claude-harness-run read-plugin-doc skills/guarantee-audit/references/bootstrap-mode.md
#     claude-harness-run read-plugin-doc scripts/specs/list-test-files.md
#
# 出力:
#   stdout : 対象ファイルの中身をバイト単位でそのまま（付加なし）
#   stderr : 配送レシート（成功時）またはエラー内容と停止指示（失敗時）
#   exit   : 0=配送成功 / 64=引数不正 / 66=対象なし / 69=プラグインルート解決不能 / 77=配送対象外
#
# **stdout に JSON を1個だけ出す** という scripts/README.md の出力規約には意図的に従わない。
# 本スクリプトの成果物は機械可読なステータスではなく **モデルが読む本文そのもの**であり、
# JSON でエスケープすると読み手にとって著しく劣化するため。成否は exit code と stderr で表す。
# 仕様の正本は scripts/specs/read-plugin-doc.md。

set -u

RPD_SELF_NAME="read-plugin-doc"

# sysexits 準拠。ランチャー（bin/claude-harness-run）の割り当てと揃える。
RPD_EX_USAGE=64       # 引数不正（絶対パス・'..' を含む・引数の数が違う）
RPD_EX_NOINPUT=66     # 対象ファイルが存在しない／通常ファイルでない
RPD_EX_UNAVAILABLE=69 # プラグインルートを解決できない（インストール破損）
RPD_EX_NOPERM=77      # 配送対象のサブツリー外

rpd_err() {
  printf '%s: %s\n' "$RPD_SELF_NAME" "$*" >&2
}

# 配送できなかったことを、呼び出し元のモデルに対する行動指示として明示する。
# 「読めなかった」を「読まなくてよかった」に読み替えさせないための、実行時側の歯止め。
rpd_halt_notice() {
  rpd_err "本文は配送されていない。推測で手順を補完せず、その場で停止してユーザーに報告すること。"
}

rpd_usage() {
  cat >&2 <<EOF
Usage: claude-harness-run ${RPD_SELF_NAME} <プラグインルート相対パス>

  プラグイン同梱の参照ドキュメントを stdout へそのまま出力する。

  配送対象（これ以外のパスは exit ${RPD_EX_NOPERM} で拒否する）:
    skills/<skill>/references/<name>.md
    skills/<skill>/templates/<name>
    scripts/specs/<name>.md
    scripts/README.md

  絶対パス・'..' を含むパスは受け付けない。
EOF
}

# 配送を許すサブツリーか判定する。汎用の cat にしないための fail-closed な allowlist。
# （プラグインルートがローカルチェックアウトの場合、配下には .env 等の非公開ファイルが
#  存在しうる。用途をドキュメント配送に限定し、任意ファイル読み出しの手段にしない）
rpd_is_deliverable() {
  case "$1" in
    scripts/README.md) return 0 ;;
    scripts/specs/*.md) return 0 ;;
    skills/*/references/*.md) return 0 ;;
    skills/*/templates/*) return 0 ;;
    *) return 1 ;;
  esac
}

rpd_main() {
  if [ "$#" -eq 1 ]; then
    case "$1" in
      -h | --help)
        rpd_usage
        return 0
        ;;
    esac
  fi

  if [ "$#" -ne 1 ]; then
    rpd_err "expects exactly one plugin-relative path (got $#)"
    rpd_usage
    rpd_halt_notice
    return "$RPD_EX_USAGE"
  fi

  local rel="$1"

  case "$rel" in
    "")
      rpd_err "path must not be empty"
      rpd_halt_notice
      return "$RPD_EX_USAGE"
      ;;
    /*)
      rpd_err "path must be plugin-relative, not absolute: ${rel}"
      rpd_halt_notice
      return "$RPD_EX_USAGE"
      ;;
    .. | ../* | */.. | */../*)
      rpd_err "path must not contain '..': ${rel}"
      rpd_halt_notice
      return "$RPD_EX_USAGE"
      ;;
  esac

  # プラグインルートは自身の配置位置から解決する（本スクリプトはプラグイン同梱であり、
  # ${CLAUDE_PLUGIN_ROOT} は Bash 環境変数として存在しない — 実機検証済み）。
  local script_dir root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || script_dir=""
  if [ -n "$script_dir" ]; then
    root="$(cd "${script_dir}/.." 2>/dev/null && pwd -P)" || root=""
  else
    root=""
  fi
  if [ -z "$root" ] || [ ! -f "${root}/.claude-plugin/plugin.json" ]; then
    rpd_err "could not locate the plugin root from this script's location (installation broken)"
    rpd_halt_notice
    return "$RPD_EX_UNAVAILABLE"
  fi

  if ! rpd_is_deliverable "$rel"; then
    rpd_err "not a deliverable document path: ${rel}"
    rpd_usage
    rpd_halt_notice
    return "$RPD_EX_NOPERM"
  fi

  local full="${root}/${rel}"

  # シンボリックリンクは配送しない。プラグイン同梱ドキュメントは実体ファイルであり、
  # リンク経由でプラグイン外を指す形を許すとサブツリー制限が意味を失うため。
  if [ -L "$full" ]; then
    rpd_err "refusing to deliver a symlink: ${rel}"
    rpd_halt_notice
    return "$RPD_EX_NOPERM"
  fi

  if [ ! -f "$full" ]; then
    rpd_err "document not found: ${rel}"
    rpd_err "  plugin root: ${root}"
    rpd_halt_notice
    return "$RPD_EX_NOINPUT"
  fi

  # 親ディレクトリ側がリンクでプラグイン外へ抜けていないことを、物理パスで確認する。
  local phys_dir
  phys_dir="$(cd "$(dirname "$full")" 2>/dev/null && pwd -P)" || phys_dir=""
  case "${phys_dir}/" in
    "${root}/"*) ;;
    *)
      rpd_err "resolved path escapes the plugin root: ${rel}"
      rpd_halt_notice
      return "$RPD_EX_NOPERM"
      ;;
  esac

  if ! cat "$full"; then
    rpd_err "failed to read: ${rel}"
    rpd_halt_notice
    return "$RPD_EX_NOINPUT"
  fi

  local bytes
  bytes="$(wc -c <"$full" | tr -d '[:space:]')"
  rpd_err "delivered ${rel} (${bytes} bytes)"
  return 0
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  rpd_main "$@"
  exit "$?"
fi
