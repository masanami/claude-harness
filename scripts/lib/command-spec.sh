#!/bin/bash
# scripts/lib/command-spec.sh
# 呼び出し側（LLM）から受け取った「コマンド文字列」を、**シェルを介さずに実行できる
# argv 配列**へ変換し、実行してよいコマンドかどうかを判定するライブラリ（Issue #223）。
#
# 各スクリプトはスクリプト自身の位置起点で source する（呼び出し元の cwd に依存させないため）:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/command-spec.sh"
#
# ■ 背景（何を塞いでいるか）
# `quality-check-runner.sh` / `mutation-run.sh` は受け取った文字列を `bash -c "$cmd"` で
# 実行していた。Claude Code の Bash permission マッチャは外側の `claude-harness-run ...` しか
# 見ないため、`Bash(claude-harness-run:*)` を allow した利用側では **その settings.json の
# deny（`Bash(rm -r:*)` 等）を迂回して任意コマンドを実行できた**。doctor の
# `settings_launcher_allow` はこの allow を是正として提示するため、doctor に従うほど
# deny が無効化される状態だった。
#
# ■ 2段の防御（片方だけでは塞がらない）
#   1. **シェルを介さない**: `bash -c` を廃し、argv 配列をそのまま実行する。`;` `|` `>` `$(...)`
#      といったシェル構文は解釈されない。ただし解釈されないだけでは不十分で、`rm -rf /` を
#      argv として実行できれば迂回は成立する。よって——
#   2. **実行系を閉じた集合に限る**: argv の先頭トークン列を `scripts/config/command-allowlist.txt`
#      と前置一致で照合し、一致しなければ実行前に拒否する。**これが実質的な統制点**。
#
# ■ 拡張路を用意しない
# allowlist ファイルのパスは本ファイルの位置から**無条件に**決める（環境変数・CLI フラグを
# 見ない）。ランチャーは `--env KEY=VALUE` で子プロセスへ任意の環境変数を渡せるため、
# 環境変数で差し替え可能にすると allowlist 自体を注入できてしまい、本ライブラリの目的が
# 失われる（「設定できると便利」を理由に抜け道を残さない）。
#
# ■ 提供する関数・変数
#   - CMDSPEC_ALLOWLIST_FILE  allowlist の絶対パス（source 時に無条件で決定）
#   - CMDSPEC_ARGV            cmdspec_parse が成功した場合の argv 配列
#   - CMDSPEC_ERROR           cmdspec_parse が失敗した場合の理由（人間/LLM 向け1行）
#   - cmdspec_first_metachar <str>   シェル解釈を要求する最初の文字を出力（無ければ空）
#   - cmdspec_prefix_matches <entry> <argv...>  allowlist エントリが argv に前置一致するか
#   - cmdspec_allowed <argv...>      argv が allowlist のいずれかに一致するか
#   - cmdspec_parse <str>            検証して CMDSPEC_ARGV を設定（失敗時は非0＋CMDSPEC_ERROR）
#   - cmdspec_reject_message <label> <str>  拒否時に stderr へ出す複数行メッセージ

# source 時に無条件で決定する（環境変数の値を引き継がない＝注入されない）。
CMDSPEC_ALLOWLIST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" 2>/dev/null && pwd)/command-allowlist.txt"

CMDSPEC_ARGV=()
CMDSPEC_ERROR=""

# シェル解釈を要求する文字が含まれていれば、その最初の1文字を出力して 0 を返す。
# 含まれていなければ何も出力せず 1 を返す。
#
# シェルを介さない実装ではこれらの文字は「ただのリテラル」になるため、素通しすると
# 呼び出し側が意図した意味（`a; b` は2コマンド）と実際の挙動（`;` を含む1引数）が黙って
# 食い違う。**黙って別物を実行するより、その場で落として呼び出し側に書き直させる**。
# セキュリティ上の統制点は allowlist 側であり、この検査は意味の食い違いを防ぐためのもの。
#
# 非ASCII文字は対象にしない（日本語を含むテストファイル名などは正当な引数であり、
# シェル解釈とは無関係のため）。
cmdspec_first_metachar() {
  local s="$1"
  # 1文字ずつ足すのは、この集合を1つのリテラルで書くと引用が読めなくなるため
  # （バックスラッシュ・両クォートを含む）。
  local metachars=';&|<>$(){}[]*?!#~'
  metachars="${metachars}"'`'  # バッククォート（コマンド置換）
  metachars="${metachars}"'\'  # バックスラッシュ（エスケープ）
  metachars="${metachars}"'"'  # ダブルクォート
  metachars="${metachars}'"    # シングルクォート

  case "$s" in
    *$'\n'*)
      printf '\\n'
      return 0
      ;;
  esac
  case "$s" in
    *$'\r'*)
      printf '\\r'
      return 0
      ;;
  esac

  local i=0 len="${#s}" ch
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    case "$metachars" in
      *"$ch"*)
        printf '%s' "$ch"
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# allowlist の1エントリ（空白区切りのトークン列）が argv に前置一致するかを判定する。
# 引数: entry, argv...
# 空エントリは何にも一致させない（allowlist の空行・コメント行が「全許可」にならないため）。
cmdspec_prefix_matches() {
  local entry="$1"
  shift

  local want=()
  # read -a はグロブ展開を行わないため、`*` を含むトークンも安全に分解できる。
  # 末尾に改行が無い here-string では read が非0を返すが、配列は設定されるため無視する。
  read -r -a want <<<"$entry" || true

  local n="${#want[@]}"
  [ "$n" -gt 0 ] || return 1
  [ "$#" -ge "$n" ] || return 1

  local got=("$@")
  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${want[$i]}" != "${got[$i]}" ]; then
      return 1
    fi
    i=$((i + 1))
  done
  return 0
}

# argv が allowlist のいずれかのエントリに前置一致するかを判定する。
# allowlist ファイルが読めない場合は **fail-closed**（何も実行させない）。
# 「一覧が壊れていたら全部通す」は、統制が消えたことに気付けない最悪の失敗形になる。
cmdspec_allowed() {
  [ "$#" -gt 0 ] || return 1
  [ -f "$CMDSPEC_ALLOWLIST_FILE" ] || return 1

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "$line" ] || continue
    if cmdspec_prefix_matches "$line" "$@"; then
      return 0
    fi
  done <"$CMDSPEC_ALLOWLIST_FILE"
  return 1
}

# コマンド文字列を検証し、成功時は CMDSPEC_ARGV に argv を設定して 0 を返す。
# 失敗時は CMDSPEC_ERROR に理由を設定して 1 を返す（CMDSPEC_ARGV は空）。
cmdspec_parse() {
  local cmd="$1"
  CMDSPEC_ARGV=()
  CMDSPEC_ERROR=""

  local bad
  if bad="$(cmdspec_first_metachar "$cmd")"; then
    CMDSPEC_ERROR="shell metacharacter '${bad}' is not allowed (the command is executed without a shell)"
    return 1
  fi

  read -r -a CMDSPEC_ARGV <<<"$cmd" || true
  if [ "${#CMDSPEC_ARGV[@]}" -eq 0 ]; then
    CMDSPEC_ERROR="empty command"
    return 1
  fi

  if ! cmdspec_allowed "${CMDSPEC_ARGV[@]}"; then
    if [ ! -f "$CMDSPEC_ALLOWLIST_FILE" ]; then
      CMDSPEC_ERROR="command allowlist not found: ${CMDSPEC_ALLOWLIST_FILE} (refusing to run anything)"
    else
      CMDSPEC_ERROR="'${CMDSPEC_ARGV[0]}' is not in the command allowlist"
    fi
    CMDSPEC_ARGV=()
    return 1
  fi

  return 0
}

# 拒否時に stderr へ出す説明。呼び出し側（LLM）がその場で書き直せるよう、
# 何が拒否されたか・どう書けばよいか・正本はどこかまでを含める。
cmdspec_reject_message() {
  local label="$1" cmd="$2"
  cat >&2 <<EOF
Error: rejected ${label} command: ${cmd}
       reason: ${CMDSPEC_ERROR}
       This runner executes the command directly (no shell), and only commands whose
       leading tokens match the bundled allowlist may run. This is what makes
       'Bash(claude-harness-run:*)' safe to allow: it must not become a way to run
       arbitrary commands and bypass the project's deny rules.
       - Do not use shell syntax (; && | > \$() \` quotes globs). Chain steps in the
         project's own script instead (e.g. a package.json script or a Makefile target),
         and pass that single command here.
       - Pass environment variables via 'claude-harness-run --env KEY=VALUE', not 'KEY=V cmd'.
       - Allowed commands: ${CMDSPEC_ALLOWLIST_FILE}
       - Rationale: docs/script-launcher.md「6. このランチャーを allow することの意味」
EOF
}
