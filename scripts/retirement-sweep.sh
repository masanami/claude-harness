#!/bin/bash
# retirement-sweep.sh
# 使い方: retirement-sweep.sh <退役したパス>... [--base <dir>] [--adr-dir <dir>]
# 退役（削除）した駆動文書への参照がリポジトリに残っていないかを決定的に走査し、
# {status, base, targets, excluded_dirs, counts, references, excluded, weak_matches} の
# JSON を stdout に1個返す。仕様の正本は scripts/specs/retirement-sweep.md を参照。
#
# なぜあるか:
# - 駆動文書の削除は「正本の引っ越し」であり、被参照の付け替えまでが1セットである。
#   退役手順が削除と ADR 昇格判定だけを定めていた時期に、削除済みファイルへの参照が
#   52箇所／28ファイル残った（README のリンクが 404 になり、実装コメントから設計根拠を
#   辿れなくなった）。退役の目的（エージェントの Glob/Grep から汚染源を除く）に対して
#   「辿れない参照を撒く」という逆の結果になる。
# - 「grep して直す」という散文の手順では、除外してよい参照（ADR の出所記録）の扱いが
#   担当者ごとにぶれ、消してはいけない参照まで消える。除外集合をスクリプト1箇所に持ち、
#   **除外した分も件数と一覧に出す**ことで、掃引の範囲を目視できる形にする。
#
# 設計上の要点（正本の再掲ではなく、実装を読む人向けの注記）:
# - 除外は「消してはいけない参照」の列挙であって、検査の無効化ではない。除外したヒットは
#   捨てずに `excluded` として返す（黙って範囲を狭めると、掃引漏れが 0 件に見える）。
# - 一致は**リテラル一致**（`grep -F`）で行う。正規表現を受け付けると、退役パスに含まれる
#   `.` が任意文字になり、無関係な行を「参照」として報告しうる。
# - パス形（`docs/features/x.md`）の一致だけを status の根拠にする。ファイル名だけの言及
#   （`x.md`）は同名別ファイルに当たりうるため `weak_matches` として別枠で返し、status は
#   落とさない（誤検出で退役を止めない）。ただし黙って捨てず stderr にも件数を出す
#   ——「検出したが status に出さない」ことと「検出していない」ことを区別するため。
# - 退役対象がまだ作業ツリーに在る場合は exit 2（実行前提の欠落）。本スクリプトは
#   「削除済みのパスへの参照」を数えるものであり、削除前に走らせて 0 件を得ても意味が無い。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 2
}

# 終了コード（scripts/specs/retirement-sweep.md と一致させること）
RETIREMENT_SWEEP_EX_PASS=0   # 参照は残っていない
RETIREMENT_SWEEP_EX_FAIL=1   # 付け替えるべき参照が残っている
RETIREMENT_SWEEP_EX_PREREQ=2 # 実行前提の欠落（jq 不在・引数不正・git 作業ツリーでない・対象が未削除）

# 既定の除外ディレクトリ。ADR の `宣言元は退役した <path>` は**正しい出所記録**であり、
# 退役に伴って書き換えてはいけない（実測でこの形が10箇所あった）。置き場を移している
# プロジェクトのために --adr-dir で差し替えられるようにする。
# **汎用の --exclude は設けない**。任意のパスを掃引対象から外せるフラグは、それ自体が
# 「検査していないものを 0 件に見せる」経路になり、本スクリプトが塞いでいる欠陥と同型になる。
RETIREMENT_SWEEP_DEFAULT_ADR_DIR="docs/adr/"

# 走査結果の受け皿（bash 3.2 では未代入配列の展開が set -u で落ちるため先に宣言する）
RS_REFS=()
RS_EXCLUDED=()
RS_WEAK=()
RS_TARGETS=()
RS_STILL_PRESENT=()

# 除外プレフィックス（main が --adr-dir から解決して上書きする）と、走査エラーの記録。
# 関数を直接テストする経路（source して呼ぶ）でも未定義参照にならないよう既定値を置く。
RS_ADR_PREFIX="$RETIREMENT_SWEEP_DEFAULT_ADR_DIR"
RS_SCAN_ERROR=""

# 前後の空白を除去する。
rs_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# 走査結果は「タブ区切り1行1レコード」で受け渡し、最後に jq で JSON へ組み立てる。
# ヒット行の本文は**任意の文字を含みうる**（コードのタブインデントが典型）ため、値の中の
# タブがそのまま入ると列がずれ、下流の jq が別のフィールドを読む。値は積む前にエスケープし、
# jq 側で単一パス（`\` の次の1文字を見る）で復元する。
rs_escape_field() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

# 与えたディレクトリ表記を「末尾スラッシュ付きのリポジトリルート相対プレフィックス」に正規化する。
# `docs/adr` `./docs/adr/` `docs/adr/` のいずれも `docs/adr/` になる。
rs_normalize_dir_prefix() {
  local dir
  dir="$(rs_trim "$1")"
  dir="${dir#./}"
  while [ "${dir}" != "${dir%/}" ]; do
    dir="${dir%/}"
  done
  [ -z "$dir" ] && return 0
  printf '%s/' "$dir"
}

# ヒットを1件積む。除外プレフィックスに該当するものは RS_EXCLUDED へ回す。
# 引数: <退役パス> <ヒットしたファイル> <行番号> <行本文> <一致種別 path|basename>
rs_add_hit() {
  local target="$1" file="$2" line="$3" text="$4" kind="$5"
  local record
  record="$(rs_escape_field "$target")"$'\t'"$(rs_escape_field "$file")"$'\t'"${line}"$'\t'"$(rs_escape_field "$text")"$'\t'"${kind}"

  case "$file" in
    "${RS_ADR_PREFIX}"*)
      RS_EXCLUDED+=("$record")
      return 0
      ;;
  esac

  if [ "$kind" = "basename" ]; then
    RS_WEAK+=("$record")
  else
    RS_REFS+=("$record")
  fi
  return 0
}

# パス形の一致として既に記録済みの「ファイル・行番号」かどうかを判定する。
# パス形でヒットした行は必ずファイル名も含むため、そのまま弱一致でも当たる。二重計上すると
# `weak` の件数が「パス形では拾えなかった言及」を表さなくなる（仕分けの対象が読めなくなる）。
# 除外側（ADR）も同様に既出として扱う——除外した行が weak として復活すると、除外の意味が消える。
# 引数: <ファイル> <行番号>
rs_already_seen() {
  local file="$1" line="$2" entry seen_file seen_line
  local escaped_file
  escaped_file="$(rs_escape_field "$file")"

  for entry in ${RS_REFS[@]+"${RS_REFS[@]}"} ${RS_EXCLUDED[@]+"${RS_EXCLUDED[@]}"}; do
    seen_file="$(printf '%s' "$entry" | cut -f2)"
    seen_line="$(printf '%s' "$entry" | cut -f3)"
    if [ "$seen_file" = "$escaped_file" ] && [ "$seen_line" = "$line" ]; then
      return 0
    fi
  done
  return 1
}

# 1つの検索語について、リポジトリ内のヒットを走査して積む。
# git grep はワークツリーの追跡ファイル＋未追跡（非 ignore）ファイルを対象にする。
# 引数: <リポジトリルート> <退役パス> <検索語> <一致種別 path|basename>
rs_scan_term() {
  local root="$1" target="$2" term="$3" kind="$4"
  local list_file rc file line_no text hit

  # ファイル名一覧は NUL 区切りで受け取り、**一時ファイル経由で読む**。
  # コマンド置換（`$(...)`）は NUL バイトを捨てるため、`-z` の出力を変数に入れると
  # 全ファイル名が1本に連結され、以降のループが1件も回らないまま「参照0件」になる。
  list_file="$(mktemp)" || {
    RS_SCAN_ERROR="mktemp failed"
    return 1
  }

  # -I: バイナリを除外 / -F: リテラル一致 / -l: ファイル名だけ / -z: NUL 区切り
  # --full-name: リポジトリルート相対で返す（cwd に依存させない）
  # --untracked: まだコミットしていない新規ファイルの参照も拾う（退役 PR の作業中に走らせるため）
  git -C "$root" grep --full-name -I -F -l -z --untracked -e "$term" > "$list_file" 2>/dev/null
  rc=$?
  if [ "$rc" -eq 1 ]; then
    rm -f "$list_file"
    return 0 # ヒット無し（正常）
  fi
  if [ "$rc" -gt 1 ]; then
    # 実行エラーを「ヒット無し」として黙って通さない
    rm -f "$list_file"
    RS_SCAN_ERROR="git grep failed (exit ${rc}) for term: ${term}"
    return 1
  fi

  while IFS= read -r -d '' file; do
    [ -z "$file" ] && continue
    # ファイル名にコロンを含みうるため、ファイルごとに grep -n を掛けて `行番号:本文` だけを解析する
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      line_no="${hit%%:*}"
      text="${hit#*:}"
      case "$line_no" in
        '' | *[!0-9]*) continue ;;
      esac
      if [ "$kind" = "basename" ] && rs_already_seen "$file" "$line_no"; then
        continue
      fi
      rs_add_hit "$target" "$file" "$line_no" "$text" "$kind"
    done < <(grep -n -F -e "$term" -- "${root}/${file}" 2>/dev/null)
  done < "$list_file"

  rm -f "$list_file"
  return 0
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} <退役したパス>... [--base <dir>] [--adr-dir <dir>]

  <退役したパス>  削除済みの駆動文書のパス（リポジトリルート相対）。1個以上、複数可。
  --base <dir>    走査するリポジトリの作業ツリー（既定: cwd から解決したリポジトリルート）。
  --adr-dir <dir> 除外する ADR 置き場（既定: ${RETIREMENT_SWEEP_DEFAULT_ADR_DIR}）。
                  ADR の「宣言元は退役した <path>」は正しい出所記録のため書き換えない。
  stdout に {"status":"pass"|"fail","base":...,"counts":{...},"references":[...],...} を1個出力する。
  exit code: ${RETIREMENT_SWEEP_EX_PASS}=参照なし / ${RETIREMENT_SWEEP_EX_FAIL}=参照が残っている / ${RETIREMENT_SWEEP_EX_PREREQ}=実行前提の欠落
EOF
}

main() {
  local explicit_base=""
  local adr_dir="$RETIREMENT_SWEEP_DEFAULT_ADR_DIR"
  local -a targets=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        print_usage
        exit 0
        ;;
      --base)
        if [ "$#" -lt 2 ]; then
          echo "Error: --base requires a value" >&2
          printf '%s\n' '{"status":"error","error":"--base requires a value"}' >&2
          exit "$RETIREMENT_SWEEP_EX_PREREQ"
        fi
        explicit_base="$2"
        shift 2
        ;;
      --adr-dir)
        if [ "$#" -lt 2 ]; then
          echo "Error: --adr-dir requires a value" >&2
          printf '%s\n' '{"status":"error","error":"--adr-dir requires a value"}' >&2
          exit "$RETIREMENT_SWEEP_EX_PREREQ"
        fi
        adr_dir="$2"
        shift 2
        ;;
      -*)
        echo "Error: unknown option: $1" >&2
        printf '%s\n' '{"status":"error","error":"unknown option"}' >&2
        print_usage
        exit "$RETIREMENT_SWEEP_EX_PREREQ"
        ;;
      *)
        targets+=("$1")
        shift
        ;;
    esac
  done

  if ! check_jq '{"status":"error","error":"jq not found"}'; then
    exit "$RETIREMENT_SWEEP_EX_PREREQ"
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "Error: 退役したパスを1個以上指定してください" >&2
    printf '%s\n' '{"status":"error","error":"no target given"}' >&2
    print_usage
    exit "$RETIREMENT_SWEEP_EX_PREREQ"
  fi

  local base
  if [ -n "$explicit_base" ]; then
    if [ ! -d "$explicit_base" ]; then
      echo "Error: --base のディレクトリが存在しません: ${explicit_base}" >&2
      printf '%s\n' '{"status":"error","error":"base directory not found"}' >&2
      exit "$RETIREMENT_SWEEP_EX_PREREQ"
    fi
    base="$explicit_base"
  else
    base="$(pwd)"
  fi

  local root
  if ! root="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$root" ]; then
    echo "Error: git の作業ツリーではありません: ${base}" >&2
    echo "  本スクリプトは追跡ファイル＋未追跡ファイルを git grep で走査します。退役 PR の作業ツリーで実行してください。" >&2
    printf '%s\n' '{"status":"error","error":"not a git work tree"}' >&2
    exit "$RETIREMENT_SWEEP_EX_PREREQ"
  fi
  root="$(cd "$root" && pwd)"

  RS_ADR_PREFIX="$(rs_normalize_dir_prefix "$adr_dir")"
  if [ -z "$RS_ADR_PREFIX" ]; then
    echo "Error: --adr-dir が空です（除外ディレクトリを空にすると ADR の出所記録まで掃引対象になります）" >&2
    printf '%s\n' '{"status":"error","error":"empty adr dir"}' >&2
    exit "$RETIREMENT_SWEEP_EX_PREREQ"
  fi

  # 退役対象がまだ残っていないか（削除前に走らせた 0 件を「片付いた」と読ませない）
  local t normalized
  for t in "${targets[@]}"; do
    normalized="$(rs_trim "$t")"
    normalized="${normalized#./}"
    if [ -z "$normalized" ]; then
      echo "Error: 空のパスは指定できません" >&2
      printf '%s\n' '{"status":"error","error":"empty target path"}' >&2
      exit "$RETIREMENT_SWEEP_EX_PREREQ"
    fi
    RS_TARGETS+=("$normalized")
    if [ -e "${root}/${normalized}" ]; then
      RS_STILL_PRESENT+=("$normalized")
    fi
  done

  if [ "${#RS_STILL_PRESENT[@]}" -gt 0 ]; then
    echo "Error: 退役対象がまだ作業ツリーに存在します: ${RS_STILL_PRESENT[*]}" >&2
    echo "  本スクリプトは「削除済みのパスへの参照」を数えます。削除を済ませてから実行してください（削除前の 0 件は「片付いた」ことを意味しません）。" >&2
    printf '%s\n' '{"status":"error","error":"retired path still present"}' >&2
    exit "$RETIREMENT_SWEEP_EX_PREREQ"
  fi

  RS_SCAN_ERROR=""
  local target basename_term
  for target in "${RS_TARGETS[@]}"; do
    # パス形の一致（status の根拠になるのはこちらだけ）
    if ! rs_scan_term "$root" "$target" "$target" "path"; then
      break
    fi
    # ファイル名だけの言及（同名別ファイルに当たりうるため弱一致として別枠で返す）
    basename_term="${target##*/}"
    if [ -n "$basename_term" ] && [ "$basename_term" != "$target" ]; then
      if ! rs_scan_term "$root" "$target" "$basename_term" "basename"; then
        break
      fi
    fi
  done

  if [ -n "$RS_SCAN_ERROR" ]; then
    echo "Error: 走査に失敗しました: ${RS_SCAN_ERROR}" >&2
    echo "  走査エラーを「参照 0 件」として通しません（掃引漏れが pass に見えるのを防ぐため）。" >&2
    printf '%s\n' '{"status":"error","error":"scan failed"}' >&2
    exit "$RETIREMENT_SWEEP_EX_PREREQ"
  fi

  local refs_text="" excluded_text="" weak_text="" targets_text=""
  [ "${#RS_REFS[@]}" -gt 0 ] && refs_text="$(printf '%s\n' "${RS_REFS[@]}")"
  [ "${#RS_EXCLUDED[@]}" -gt 0 ] && excluded_text="$(printf '%s\n' "${RS_EXCLUDED[@]}")"
  [ "${#RS_WEAK[@]}" -gt 0 ] && weak_text="$(printf '%s\n' "${RS_WEAK[@]}")"
  targets_text="$(printf '%s\n' "${RS_TARGETS[@]}")"

  jq -n \
    --arg base "$root" \
    --arg adr_prefix "$RS_ADR_PREFIX" \
    --arg targets "$targets_text" \
    --arg refs "$refs_text" \
    --arg excluded "$excluded_text" \
    --arg weak "$weak_text" '
      # rs_escape_field の逆変換。`\\` の次の1文字だけを見る単一パスで復元する
      def unesc: gsub("\\\\(?<c>.)"; if .c == "t" then "\t" else .c end);
      def rows($text): $text | split("\n") | map(select(length > 0) | split("\t") | map(unesc));
      def hits($text): [ rows($text)[] | {
            target: .[0],
            file: .[1],
            line: (.[2] | tonumber),
            text: .[3],
            match: .[4]
          } ];
      hits($refs) as $references
      | hits($excluded) as $excluded_hits
      | hits($weak) as $weak_hits
      | {
          status: (if ($references | length) == 0 then "pass" else "fail" end),
          base: $base,
          targets: ($targets | split("\n") | map(select(length > 0))),
          excluded_dirs: [$adr_prefix],
          counts: {
            targets: ($targets | split("\n") | map(select(length > 0)) | length),
            references: ($references | length),
            files: ($references | map(.file) | unique | length),
            excluded: ($excluded_hits | length),
            weak: ($weak_hits | length)
          },
          references: $references,
          excluded: $excluded_hits,
          weak_matches: $weak_hits
        }
    '

  if [ "${#RS_WEAK[@]}" -gt 0 ]; then
    echo "Warning: ファイル名だけの言及が ${#RS_WEAK[@]} 件あります（同名別ファイルの可能性があるため status には数えていません）。" >&2
    echo "  stdout の weak_matches を目視で仕分けし、退役した文書を指しているものは付け替えてください。" >&2
  fi

  if [ "${#RS_EXCLUDED[@]}" -gt 0 ]; then
    echo "Note: 除外ディレクトリ（${RS_ADR_PREFIX}）内の参照が ${#RS_EXCLUDED[@]} 件あります。これは退役した文書の出所記録であり、書き換えません。" >&2
  fi

  if [ "${#RS_REFS[@]}" -gt 0 ]; then
    echo "Error: 退役した文書への参照が ${#RS_REFS[@]} 件残っています。詳細は stdout の JSON を参照してください。" >&2
    exit "$RETIREMENT_SWEEP_EX_FAIL"
  fi

  exit "$RETIREMENT_SWEEP_EX_PASS"
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
