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
#   claude-harness-run read-plugin-doc <プラグインルート相対パス> [--from-line N] [--max-bytes N]
#
#   例:
#     claude-harness-run read-plugin-doc skills/guarantee-audit/references/bootstrap-mode.md
#     claude-harness-run read-plugin-doc scripts/specs/list-test-files.md
#
# 出力:
#   stdout : 開始マーカー行 → 対象ファイルの中身 → 終端（END）または継続（MORE）マーカー行
#   stderr : 配送レシート（成功時）またはエラー内容と停止指示（失敗時）
#   exit   : 0=配送成功 / 64=引数不正 / 66=対象なし・空 / 69=ルート解決不能 / 74=書き込み失敗 / 77=配送対象外
#
# **マーカーを stdout に、本文の前後へ出すのはなぜか（重要）**:
#   OS レベルでは全バイトを stdout へ書けるが、**モデルが受け取るのは Bash ツールの出力**であり、
#   そこには上限がある。上限を超えると出力は先頭側を残して切り詰められ、末尾にあるものは消える。
#   つまり「stdout は本文のみ・レシートは stderr（後ろ）」という設計では、
#   大きいファイルで **exit 0 のまま本文が途中で切れ、切れた事実を伝えるものが何も残らない**。
#   これは本スクリプトが潰そうとした「沈黙する部分成功」そのものである。
#   そこで (1) 開始マーカーを本文の**前**（切り詰めを生き延びる位置）へ出し、
#   (2) 終端マーカーを本文の**後ろ**へ出して、**終端マーカーの不在を切り詰めの検査に使う**。
#   さらに (3) 1回の出力が上限に達しないよう自分で分割配送し、続きの取得コマンドを明示する。
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
RPD_EX_IOERR=74       # stdout への書き込み失敗（パイプの早期終了を含む）
RPD_EX_NOPERM=77      # 配送対象のサブツリー外

# 1回の配送で stdout へ出す本文の既定上限（バイト）。Bash ツールの出力上限に達して
# 黙って切り詰められるのを防ぐため、実測された切り詰め閾値より十分小さく取る
# （実測: 21,315 バイトは全量通過 / 29,300 バイトと 51.8KB は切り詰め）。
# 上限に達した場合は MORE マーカーと続きの取得コマンドを出す（分割配送）。
RPD_DEFAULT_MAX_BYTES=16384
RPD_MIN_MAX_BYTES=1024

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
Usage: claude-harness-run ${RPD_SELF_NAME} <プラグインルート相対パス> [--from-line N] [--max-bytes N]

  プラグイン同梱の参照ドキュメントを stdout へ配送する。
  本文の前後にマーカー行が付く（本文ではない。終端マーカーの不在＝切り詰めの検査に使う）。

    --from-line N   N 行目から配送する（既定: 1）。MORE マーカーが示す next-from-line を渡す
    --max-bytes N   1回の配送で出す本文の上限バイト数（既定: ${RPD_DEFAULT_MAX_BYTES}、最小: ${RPD_MIN_MAX_BYTES}）
    -h, --help      このヘルプを stderr に出して exit 0（本文は配送しない）

  配送対象（これ以外のパスは exit ${RPD_EX_NOPERM} で拒否する）:
    skills/<skill>/references/<name>.md
    skills/<skill>/templates/<name>
    scripts/specs/<name>.md
    scripts/README.md

  絶対パス・'..' を含むパスは受け付けない。
EOF
}

# プラグインの version を返す（取得できなければ 'unknown'）。jq があれば使い、無ければ sed で拾う。
# 配送元のバージョンをレシートへ出すのは、起動中スキルとは別バージョンの本文が
# 届いていないかを呼び出し側が確かめられるようにするため（ランチャーは
# インストール済みの最大バージョンを選ぶので、両者は自動では一致しない）。
rpd_plugin_version() {
  local manifest="${1}/.claude-plugin/plugin.json" v=""
  if [ -f "$manifest" ]; then
    if command -v jq >/dev/null 2>&1; then
      v="$(jq -r '.version // empty' "$manifest" 2>/dev/null)"
    fi
    if [ -z "$v" ]; then
      v="$(LC_ALL=C sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" 2>/dev/null | head -1)"
    fi
  fi
  printf '%s\n' "${v:-unknown}"
}

# stdout への書き込みに失敗した場合の報告。パイプの早期終了（SIGPIPE=141）は
# 「対象が無い」のではなく「読み手が受け取りを止めた」ので、事実に即した診断を出す
# （本文を分割して読もうとして `| head -N` する のは自然な行動であり、
#  それを『ファイルが存在しない』と報告すると原因の切り分けを誤らせる）。
rpd_report_write_failure() {
  local status="$1" rel="$2"
  if [ "$status" -eq 141 ]; then
    rpd_err "output pipe closed by the reader (SIGPIPE) while delivering: ${rel}"
    rpd_err "  パイプで受け取りを打ち切ると本文は不完全になる。分割して読む場合は --from-line を使うこと。"
  else
    rpd_err "failed to write the document to stdout (status ${status}): ${rel}"
  fi
  rpd_halt_notice
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
  local rel="" from_line=1 max_bytes="$RPD_DEFAULT_MAX_BYTES" positional=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        rpd_usage
        return 0
        ;;
      --from-line | --max-bytes)
        if [ "$#" -lt 2 ]; then
          rpd_err "$1 requires a value"
          rpd_usage
          rpd_halt_notice
          return "$RPD_EX_USAGE"
        fi
        case "$2" in
          '' | *[!0-9]*)
            rpd_err "$1 expects a positive integer (got: $2)"
            rpd_halt_notice
            return "$RPD_EX_USAGE"
            ;;
        esac
        if [ "$1" = "--from-line" ]; then from_line="$2"; else max_bytes="$2"; fi
        shift 2
        ;;
      -*)
        rpd_err "unknown option: $1"
        rpd_usage
        rpd_halt_notice
        return "$RPD_EX_USAGE"
        ;;
      *)
        positional=$((positional + 1))
        rel="$1"
        shift
        ;;
    esac
  done

  if [ "$positional" -ne 1 ]; then
    rpd_err "expects exactly one plugin-relative path (got ${positional})"
    rpd_usage
    rpd_halt_notice
    return "$RPD_EX_USAGE"
  fi

  if [ "$from_line" -lt 1 ]; then
    rpd_err "--from-line must be 1 or greater (got: ${from_line})"
    rpd_halt_notice
    return "$RPD_EX_USAGE"
  fi

  if [ "$max_bytes" -lt "$RPD_MIN_MAX_BYTES" ]; then
    rpd_err "--max-bytes must be ${RPD_MIN_MAX_BYTES} or greater (got: ${max_bytes})"
    rpd_halt_notice
    return "$RPD_EX_USAGE"
  fi

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

  if [ ! -r "$full" ]; then
    rpd_err "document is not readable: ${rel}"
    rpd_halt_notice
    return "$RPD_EX_NOINPUT"
  fi

  local bytes lines
  bytes="$(wc -c <"$full" | tr -d '[:space:]')"
  lines="$(wc -l <"$full" | tr -d '[:space:]')"

  # 0 バイトは「配送成功（本文ゼロ）」にしない。呼び出し側の唯一の停止条件は非0 終了なので、
  # 空を exit 0 で返すと「読めた」と判断されて手順が進む。チェックアウト破損・書き込み失敗で
  # 現実に起こりうる形であり、内容のない配送は成功ではない。
  if [ "$bytes" -eq 0 ]; then
    rpd_err "document is empty (0 bytes): ${rel}"
    rpd_err "  空の本文を配送成功として返さない（破損した取得を「読めた」と誤認させないため）。"
    rpd_halt_notice
    return "$RPD_EX_NOINPUT"
  fi

  if [ "$from_line" -gt "$lines" ]; then
    rpd_err "--from-line ${from_line} is past the end of the document (${lines} lines): ${rel}"
    rpd_halt_notice
    return "$RPD_EX_USAGE"
  fi

  # 本文の上限に収まる最終行を決める。行の途中で切ると UTF-8 の文字境界を割りうるため、
  # 分割は必ず行境界で行う。1行が単独で上限を超える場合はその行を丸ごと出す（分割できない）。
  # length() をバイト数として扱うため LC_ALL=C で走らせる。
  local end_line
  end_line="$(LC_ALL=C awk -v from="$from_line" -v budget="$max_bytes" '
    NR < from { next }
    {
      n += length($0) + 1
      if (n > budget && NR > from) { print NR - 1; found = 1; exit }
    }
    END { if (!found) print NR }
  ' "$full")"
  if [ -z "$end_line" ]; then
    rpd_err "failed to compute the delivery range for: ${rel}"
    rpd_halt_notice
    return "$RPD_EX_IOERR"
  fi

  local version
  version="$(rpd_plugin_version "$root")"

  # 開始マーカーは**本文より前**に出す。出力上限による切り詰めは先頭側を残すため、
  # 前に置いたものだけが確実に読み手へ届く（宣言バイト数・行数もここで先に渡す）。
  if ! printf '=== read-plugin-doc BEGIN path=%s bytes=%s lines=%s from-line=%s root=%s version=%s ===\n' \
      "$rel" "$bytes" "$lines" "$from_line" "$root" "$version"; then
    rpd_report_write_failure "$?" "$rel"
    return "$RPD_EX_IOERR"
  fi

  sed -n "${from_line},${end_line}p" "$full"
  local sed_status=$?
  if [ "$sed_status" -ne 0 ]; then
    rpd_report_write_failure "$sed_status" "$rel"
    return "$RPD_EX_IOERR"
  fi

  local marker_status=0 complete="false" next_line=0
  if [ "$end_line" -ge "$lines" ]; then
    complete="true"
    # 終端マーカー。呼び出し側はこの行の**不在**を「出力が切り詰められた」の検査に使う。
    printf '=== read-plugin-doc END path=%s delivered-lines=%s-%s complete ===\n' \
      "$rel" "$from_line" "$end_line" || marker_status=$?
  else
    next_line=$((end_line + 1))
    printf '=== read-plugin-doc MORE path=%s delivered-lines=%s-%s next-from-line=%s of %s ===\n' \
      "$rel" "$from_line" "$end_line" "$next_line" "$lines" || marker_status=$?
    printf '=== 続きの取得: claude-harness-run read-plugin-doc "%s" --from-line %s ===\n' \
      "$rel" "$next_line" || marker_status=$?
  fi
  if [ "$marker_status" -ne 0 ]; then
    rpd_report_write_failure "$marker_status" "$rel"
    return "$RPD_EX_IOERR"
  fi

  # 実際に出した本文のバイト数を測る（ファイル全体のバイト数ではない）。
  # レシートは本文の**後ろに来る最後の1行**であり要約として読まれやすい位置にあるため、
  # 部分配送の回にファイル全体のバイト数を「delivered」として出すと、
  # **部分成功が完全成功として報告される** — 本スクリプトが潰そうとしている欠陥そのものになる。
  # そのため完全配送と部分配送でレシートの先頭語から変え、配送済み量と全体量を必ず併記する。
  local delivered_bytes
  delivered_bytes="$(sed -n "${from_line},${end_line}p" "$full" | wc -c | tr -d '[:space:]')"

  if [ "$complete" = "true" ]; then
    rpd_err "delivered ${rel} complete: ${delivered_bytes}/${bytes} bytes (lines ${from_line}-${end_line} of ${lines}) from ${root} @${version}"
  else
    rpd_err "PARTIAL ${rel}: delivered ${delivered_bytes}/${bytes} bytes (lines ${from_line}-${end_line} of ${lines}) — 未配送の続きがある"
    rpd_err "  続きの取得: claude-harness-run read-plugin-doc \"${rel}\" --from-line ${next_line}"
    rpd_err "  この回は全量ではない。続きを取得するまで手順へ進まないこと。"
    rpd_err "  from ${root} @${version}"
  fi
  return 0
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  rpd_main "$@"
  exit "$?"
fi
