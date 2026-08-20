#!/bin/bash
# guarantee-index-check.sh
# 使い方: guarantee-index-check.sh [保証台帳のパス] [--base <dir>]
# 保証台帳（既定: docs/guarantees.md）のテスト対応索引を決定的に検査し、
# {status, ledger, base, counts, broken} の JSON を stdout に1個返す。
# 仕様の正本は scripts/specs/guarantee-index-check.md を参照。
#
# 検査するもの（いずれも意味判断を含まない機械チェック）:
# - 各保証のテスト参照 `<パス>::<テスト名>` について、ファイルの存在とテスト名文字列の出現
# - 保証 ID / GAP ID の重複（採番の単一経路が破れたときの検出。人間の目視に頼らない）
# - 保証見出しの ID 書式・テスト参照の書式・テスト参照を1つも持たない保証
# - 宣言元行（`- 宣言元: #<番号>` / `裁可待ち`）の存在・書式・重複
#
# 設計上の要点（正本の再掲ではなく、実装を読む人向けの注記）:
# - 意味ドリフト（約束の文言とテストの実際の検証内容の乖離）はここでは検知しない。
#   LLM 判定を必須ゲートの反復ループに入れないため、本スクリプトは決定的検査だけを担う。
# - 「保証（Guarantees）」節が見つからない台帳は pass にせず exit 2（実行前提の欠落）とする。
#   節名の変更・ファイルの取り違えで全保証が黙って未検査になり、索引ゲートが素通りする
#   （＝壊れた索引が pass に見える）事故を防ぐため。
# - コードフェンス内の記述は検査対象にしない（台帳が書式例を引用していても誤検出しない）。
# - 読み取った保証の一覧（ID・約束文・テスト参照・宣言元）を `guarantees` として出力する。
#   台帳の読み取り規則の正本を本スクリプト1箇所に集約し、呼び出し側（スキルの散文）が
#   同じ台帳を別の規則で読み直す状態（＝同じものを2つの規則で読む）を作らないため。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 2
}

# 終了コード（scripts/specs/guarantee-index-check.md と一致させること）
GUARANTEE_INDEX_CHECK_EX_PASS=0   # 索引が健全（broken なし）
GUARANTEE_INDEX_CHECK_EX_FAIL=1   # 壊れた索引・ID 重複を検出した
GUARANTEE_INDEX_CHECK_EX_PREREQ=2 # 実行前提の欠落（jq 不在・引数不正・台帳が読めない・節が無い）

GUARANTEE_INDEX_CHECK_DEFAULT_LEDGER="docs/guarantees.md"

# 正規表現は変数へ入れてから `=~` の右辺に置く（バッククォートを含むパターンを
# [[ ]] へ直接書くとコマンド置換として解釈される余地があるため）。
GIC_FENCE_RE='^[[:space:]]{0,3}(`{3,}|~{3,})[[:space:]]*(.*)$'
GIC_H2_RE='^##[[:space:]]+(.+)$'
GIC_H1_RE='^#[[:space:]]+(.+)$'
GIC_H3_RE='^###[[:space:]]+(.+)$'
GIC_GUARANTEE_ID_RE='^(G-[0-9]+-[0-9]+)[[:space:]]*(:|：)[[:space:]]*(.*)$'
GIC_TEST_FIELD_RE='^[[:space:]]*[-*][[:space:]]+\*{0,2}テスト\*{0,2}[[:space:]]*(:|：)[[:space:]]*(.+)$'
GIC_PROV_FIELD_RE='^[[:space:]]*[-*][[:space:]]+\*{0,2}宣言元\*{0,2}[[:space:]]*(:|：)[[:space:]]*(.*)$'
GIC_PROV_ISSUE_RE='^#([0-9]+)$'
GIC_GAP_RE='^[[:space:]]*[-*][[:space:]]+\[[[:space:]xX]\][[:space:]]*(GAP-[0-9]+)[[:space:]]*(:|：)'
# Gaps 節のチェックリスト行すべて。GIC_GAP_RE に合致しないものは書式違反として検出するため、
# 「GAP 行の候補」を先に広く拾う（`GAP-?-1` のような不正 ID が件数にも問題一覧にも現れず、
#  台帳が pass してしまうのを防ぐ）。
GIC_GAP_CHECKLIST_RE='^[[:space:]]*[-*][[:space:]]+\[[[:space:]xX]\][[:space:]]*(.*)$'
# shellcheck disable=SC2016 # バッククォートは正規表現リテラル（テスト参照の囲み）であり、
# コマンド置換を意図していない。単一引用符のまま保持する必要がある
GIC_BACKTICK_RE='`([^`]+)`'

# 裁可前のドラフトで宣言元の代わりに書かれる規約文字列（docs/ai-driven-development-strategy.md 5.3）
GIC_PROV_PENDING_LITERAL="裁可待ち"

# 走査結果の受け皿。bash 3.2 では未代入の配列を `"${arr[@]}"` で展開すると set -u が
# unbound variable として落とすため、トップレベルで空配列として宣言しておく。
GIC_REFS=()
GIC_ISSUES=()
GIC_GUARANTEES=()
GIC_ALL_REFS=()

# 前後の空白を除去する。
gic_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# 走査結果は「タブ区切り1行1レコード」で受け渡し、最後に jq で JSON へ組み立てる。
# 台帳由来の値（約束文・テスト参照・書式違反の見出しなど）は**任意の文字を含みうる**ため、
# 値の中のタブがそのまま入ると列がずれ、下流の jq が別のフィールドを読む・型変換に失敗して
# 出力が空になる（＝正当な台帳が不透明に落ちる）。値は積む前にエスケープし、jq 側で
# 復元する。復元は単一パス（`\` の次の1文字を見る）で行うため、`\t` を含む約束文も
# 取り違えない。
gic_escape_field() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

# 検出した問題を GIC_ISSUES へ積む。
# 引数: <保証ID（不明なら空文字）> <テスト参照（無ければ空文字）> <理由コード>
gic_add_issue() {
  GIC_ISSUES+=("$(gic_escape_field "$1")"$'\t'"$(gic_escape_field "$2")"$'\t'"$(gic_escape_field "$3")")
}

# 直前まで読んでいた保証を1件閉じる。テスト参照ゼロ件・宣言元行の欠落／書式違反を
# ここで一括して検出し、読み取り結果を GIC_GUARANTEES へ1件積む。
# 呼び出し側は本関数を呼んだ直後に current_* を初期化すること。
# 引数: <通し番号> <保証ID> <約束文> <テスト参照件数> <宣言元kind> <宣言元Issue番号>
gic_close_guarantee() {
  local seq="$1" id="$2" statement="$3" ref_count="$4" prov_kind="$5" prov_issue="$6"

  # ID 書式を満たさない見出し（malformed_guarantee_id）は seq を持たない。
  # 見出しとしては counts.guarantees に数えるが、読み取り結果には積まない。
  [ -z "$seq" ] && return 0

  if [ "$ref_count" -eq 0 ]; then
    gic_add_issue "$id" "" "missing_test_ref"
  fi

  case "$prov_kind" in
    missing) gic_add_issue "$id" "" "missing_provenance" ;;
    malformed) gic_add_issue "$id" "" "malformed_provenance" ;;
  esac

  GIC_GUARANTEES+=("${seq}"$'\t'"$(gic_escape_field "$id")"$'\t'"$(gic_escape_field "$statement")"$'\t'"${prov_kind}"$'\t'"${prov_issue}")
  return 0
}

# 台帳本文をスキャンし、結果を以下のグローバル変数へ格納する。
#   GIC_HAS_GUARANTEE_SECTION : "true" | "false"
#   GIC_GUARANTEE_COUNT / GIC_GAP_COUNT / GIC_REF_COUNT : 件数
#   GIC_REFS   : "保証ID\tテスト参照" の配列（実ファイル検査の対象）
#   GIC_ALL_REFS : "通し番号\tテスト参照" の配列（書式違反を含む全参照。出力の tests 用）
#   GIC_GUARANTEES : "通し番号\t保証ID\t約束文\t宣言元kind\t宣言元Issue番号" の配列
#   GIC_ISSUES : "保証ID\tテスト参照\t理由コード" の配列（書式・重複の問題）
# 引数: 台帳本文テキスト
gic_scan() {
  local body="$1"
  body="${body//$'\r'/}"

  local line marker_run marker fence_info heading value rest ref
  local fence_marker=""
  local fence_len=0
  local section="none" # none | guarantees | gaps | other
  local current_id=""
  local current_seq=""
  local current_statement=""
  local current_ref_count=0
  local current_prov_kind="missing" # missing | issue | pending | malformed
  local current_prov_issue=""
  local current_prov_count=0
  local guarantee_seq=0
  # bash 3.2 に連想配列が無いため、出現済み ID は改行区切りの文字列で保持する
  local seen_guarantee_ids=""
  local seen_gap_ids=""

  GIC_HAS_GUARANTEE_SECTION="false"
  GIC_GUARANTEE_COUNT=0
  GIC_GAP_COUNT=0
  GIC_REF_COUNT=0
  GIC_REFS=()
  GIC_ALL_REFS=()
  GIC_GUARANTEES=()
  GIC_ISSUES=()

  while IFS= read -r line; do
    # コードフェンス（``` / ~~~）の内側は検査対象外。閉じフェンスと認めるのは
    # 「同じ記号・開始フェンス以上の長さ・情報文字列なし」の行だけ（CommonMark と同じ規則）。
    if [[ "$line" =~ $GIC_FENCE_RE ]]; then
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

    if [[ "$line" =~ $GIC_H2_RE ]]; then
      heading="$(gic_trim "${BASH_REMATCH[1]}")"
      # 直前の保証を閉じる（テスト参照ゼロ件・宣言元の欠落／書式違反の検出）
      gic_close_guarantee "$current_seq" "$current_id" "$current_statement" \
        "$current_ref_count" "$current_prov_kind" "$current_prov_issue"
      current_id=""
      current_seq=""
      current_statement=""
      current_ref_count=0
      current_prov_kind="missing"
      current_prov_issue=""
      current_prov_count=0
      case "$heading" in
        保証*)
          # 保証節の識別規則（正本: docs/ai-driven-development-strategy.md 5.3）は
          # 「該当する見出しが2つ以上ある本文は解釈できないとして扱う」。台帳側でこれを
          # 実装するのは本スクリプトであり、2つ目以降を黙って併合しない
          # （併合すると、どちらの節を正とするか決められないまま索引が pass する）。
          if [ "$GIC_HAS_GUARANTEE_SECTION" = "true" ]; then
            gic_add_issue "$heading" "" "duplicate_guarantee_section"
          fi
          section="guarantees"
          GIC_HAS_GUARANTEE_SECTION="true"
          ;;
        Gaps* | gaps* | GAPS*)
          section="gaps"
          ;;
        *)
          section="other"
          ;;
      esac
      continue
    fi

    if [[ "$line" =~ $GIC_H1_RE ]]; then
      gic_close_guarantee "$current_seq" "$current_id" "$current_statement" \
        "$current_ref_count" "$current_prov_kind" "$current_prov_issue"
      current_id=""
      current_seq=""
      current_statement=""
      current_ref_count=0
      current_prov_kind="missing"
      current_prov_issue=""
      current_prov_count=0
      section="none"
      continue
    fi

    if [[ "$line" =~ $GIC_H3_RE ]]; then
      heading="$(gic_trim "${BASH_REMATCH[1]}")"
      gic_close_guarantee "$current_seq" "$current_id" "$current_statement" \
        "$current_ref_count" "$current_prov_kind" "$current_prov_issue"
      current_id=""
      current_seq=""
      current_statement=""
      current_ref_count=0
      current_prov_kind="missing"
      current_prov_issue=""
      current_prov_count=0

      if [ "$section" != "guarantees" ]; then
        # 「保証」節の外に置かれた保証見出しは黙って未検査にせず問題として報告する
        case "$heading" in
          G-*) gic_add_issue "$heading" "" "guarantee_outside_section" ;;
        esac
        continue
      fi

      GIC_GUARANTEE_COUNT=$((GIC_GUARANTEE_COUNT + 1))
      if [[ "$heading" =~ $GIC_GUARANTEE_ID_RE ]]; then
        current_id="${BASH_REMATCH[1]}"
        current_statement="$(gic_trim "${BASH_REMATCH[3]}")"
        guarantee_seq=$((guarantee_seq + 1))
        current_seq="$guarantee_seq"
        if printf '%s\n' "$seen_guarantee_ids" | grep -Fxq -- "$current_id"; then
          gic_add_issue "$current_id" "" "duplicate_guarantee_id"
        else
          seen_guarantee_ids="${seen_guarantee_ids}${current_id}"$'\n'
        fi
      else
        gic_add_issue "$heading" "" "malformed_guarantee_id"
        current_id=""
      fi
      continue
    fi

    if [ "$section" = "guarantees" ] && [ -n "$current_id" ] && [[ "$line" =~ $GIC_TEST_FIELD_RE ]]; then
      value="$(gic_trim "${BASH_REMATCH[2]}")"
      rest="$value"
      local found_backticked="false"
      local raw_ref
      while [[ "$rest" =~ $GIC_BACKTICK_RE ]]; do
        raw_ref="${BASH_REMATCH[1]}"
        # 消費済みの部分を落としてから記録する（gic_record_ref の中で BASH_REMATCH が
        # 書き換わっても走査位置に影響しないようにするため）
        rest="${rest#*\`"${raw_ref}"\`}"
        ref="$(gic_trim "$raw_ref")"
        found_backticked="true"
        gic_record_ref "$current_id" "$ref" "$current_seq"
        current_ref_count=$((current_ref_count + 1))
      done
      if [ "$found_backticked" = "false" ]; then
        # バッククォート囲みが無い書き方も参照としては受け付ける（装飾の欠落だけでは
        # 落とさない）。`<パス>::<テスト名>` の形になっていない場合のみ書式違反とする。
        gic_record_ref "$current_id" "$value" "$current_seq"
        current_ref_count=$((current_ref_count + 1))
      fi
      continue
    fi

    if [ "$section" = "guarantees" ] && [ -n "$current_id" ] && [[ "$line" =~ $GIC_PROV_FIELD_RE ]]; then
      value="$(gic_trim "${BASH_REMATCH[2]}")"
      current_prov_count=$((current_prov_count + 1))
      if [ "$current_prov_count" -gt 1 ]; then
        # 宣言元が2行以上ある保証は、どちらを出自とするか決められない。黙って先頭を
        # 採らず問題として報告する（同一性の未検証を残さない）。
        gic_add_issue "$current_id" "" "duplicate_provenance"
        continue
      fi
      if [[ "$value" =~ $GIC_PROV_ISSUE_RE ]]; then
        current_prov_kind="issue"
        current_prov_issue="${BASH_REMATCH[1]}"
      elif [ "$value" = "$GIC_PROV_PENDING_LITERAL" ]; then
        current_prov_kind="pending"
        current_prov_issue=""
      else
        current_prov_kind="malformed"
        current_prov_issue=""
      fi
      continue
    fi

    if [ "$section" = "gaps" ] && [[ "$line" =~ $GIC_GAP_CHECKLIST_RE ]]; then
      local gap_entry gap_id
      # 書式違反の報告に使うため、厳密判定より先に行の中身を控える
      gap_entry="$(gic_trim "${BASH_REMATCH[1]}")"
      if [[ "$line" =~ $GIC_GAP_RE ]]; then
        gap_id="${BASH_REMATCH[1]}"
        GIC_GAP_COUNT=$((GIC_GAP_COUNT + 1))
        if printf '%s\n' "$seen_gap_ids" | grep -Fxq -- "$gap_id"; then
          gic_add_issue "$gap_id" "" "duplicate_gap_id"
        else
          seen_gap_ids="${seen_gap_ids}${gap_id}"$'\n'
        fi
      else
        # Gaps 節のチェックリスト行なのに `GAP-NNN:` 書式でない（仮 ID の残留・ID の書き忘れ）
        gic_add_issue "$gap_entry" "" "malformed_gap_id"
      fi
      continue
    fi
  done <<<"$body"

  gic_close_guarantee "$current_seq" "$current_id" "$current_statement" \
    "$current_ref_count" "$current_prov_kind" "$current_prov_issue"

  return 0
}

# テスト参照を1件記録する。書式（`<パス>::<テスト名>`）を満たさないものは問題として積む。
# 書式違反も含めた「台帳にそう書かれている参照」は GIC_ALL_REFS へ積む（出力の tests は
# 台帳の記載をそのまま映し、書式違反は broken 側で別途報告する）。
# 引数: <保証ID> <テスト参照> <通し番号>
gic_record_ref() {
  local id="$1"
  local ref="$2"
  local seq="${3:-}"
  local path name

  GIC_REF_COUNT=$((GIC_REF_COUNT + 1))
  if [ -n "$seq" ]; then
    GIC_ALL_REFS+=("${seq}"$'\t'"$(gic_escape_field "$ref")")
  fi

  case "$ref" in
    *"::"*) ;;
    *)
      gic_add_issue "$id" "$ref" "malformed_test_ref"
      return 0
      ;;
  esac

  # パスにコロンは現れない前提で、最初の `::` で分割する
  path="${ref%%::*}"
  name="${ref#*::}"
  path="$(gic_trim "$path")"
  name="$(gic_trim "$name")"

  if [ -z "$path" ] || [ -z "$name" ]; then
    gic_add_issue "$id" "$ref" "malformed_test_ref"
    return 0
  fi

  GIC_REFS+=("${id}"$'\t'"${ref}")
  return 0
}

# GIC_REFS の各参照について、ファイルの存在とテスト名文字列の出現を検査する。
# 引数: <参照解決の基準ディレクトリ>
gic_check_refs() {
  local base="$1"
  local entry id ref path name target

  if [ "${#GIC_REFS[@]}" -eq 0 ]; then
    return 0
  fi

  for entry in "${GIC_REFS[@]}"; do
    id="${entry%%$'\t'*}"
    ref="${entry#*$'\t'}"
    path="$(gic_trim "${ref%%::*}")"
    name="$(gic_trim "${ref#*::}")"

    case "$path" in
      /*) target="$path" ;;
      *) target="${base}/${path}" ;;
    esac

    if [ ! -f "$target" ]; then
      gic_add_issue "$id" "$ref" "test_file_not_found"
      continue
    fi

    if ! grep -Fq -- "$name" "$target" 2>/dev/null; then
      gic_add_issue "$id" "$ref" "test_name_not_found"
    fi
  done

  return 0
}

# 参照解決の基準ディレクトリを決める。--base 指定 > 台帳のあるリポジトリのルート > cwd。
# 引数: <台帳のパス> <--base 指定値（無ければ空文字）>
gic_resolve_base() {
  local ledger="$1"
  local explicit="$2"
  local ledger_dir root

  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return 0
  fi

  ledger_dir="$(cd "$(dirname "$ledger")" && pwd)"
  if root="$(git -C "$ledger_dir" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$root" ]; then
    printf '%s' "$root"
    return 0
  fi

  pwd
  return 0
}

# `宣言元: 裁可待ち` のまま正本台帳に残っている保証を stderr に列挙する（status は変えない）。
gic_warn_pending_provenance() {
  local entry pending_ids=""
  local pending_count=0

  if [ "${#GIC_GUARANTEES[@]}" -eq 0 ]; then
    return 0
  fi

  for entry in "${GIC_GUARANTEES[@]}"; do
    case "$entry" in
      *$'\t'pending$'\t'*)
        pending_count=$((pending_count + 1))
        pending_ids="${pending_ids}$(printf '%s' "$entry" | cut -f2) "
        ;;
    esac
  done

  if [ "$pending_count" -gt 0 ]; then
    echo "Warning: 宣言元が「裁可待ち」のままの保証が ${pending_count} 件あります: ${pending_ids}" >&2
    echo "  裁可待ちは裁可前のドラフトの規約値です。正本台帳に残っている場合は、裁可した Issue / PR の番号へ差し替えてください（書式は '- 宣言元: #<番号>'）。" >&2
  fi

  return 0
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} [保証台帳のパス] [--base <dir>]

  台帳のパスを省略した場合は ${GUARANTEE_INDEX_CHECK_DEFAULT_LEDGER} を見る。
  --base はテスト参照のパスを解決する基準ディレクトリ（既定: 台帳のあるリポジトリのルート）。
  stdout に {"status":"pass"|"fail","ledger":...,"base":...,"counts":{...},"broken":[...]} を1個出力する。
  exit code: ${GUARANTEE_INDEX_CHECK_EX_PASS}=pass / ${GUARANTEE_INDEX_CHECK_EX_FAIL}=fail / ${GUARANTEE_INDEX_CHECK_EX_PREREQ}=実行前提の欠落
EOF
}

main() {
  local ledger=""
  local explicit_base=""

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
          exit "$GUARANTEE_INDEX_CHECK_EX_PREREQ"
        fi
        explicit_base="$2"
        shift 2
        ;;
      -*)
        echo "Error: unknown option: $1" >&2
        printf '%s\n' '{"status":"error","error":"unknown option"}' >&2
        print_usage
        exit "$GUARANTEE_INDEX_CHECK_EX_PREREQ"
        ;;
      *)
        if [ -n "$ledger" ]; then
          echo "Error: too many arguments: $1" >&2
          printf '%s\n' '{"status":"error","error":"too many arguments"}' >&2
          print_usage
          exit "$GUARANTEE_INDEX_CHECK_EX_PREREQ"
        fi
        ledger="$1"
        shift
        ;;
    esac
  done

  if ! check_jq '{"status":"error","error":"jq not found"}'; then
    exit "$GUARANTEE_INDEX_CHECK_EX_PREREQ"
  fi

  if [ -z "$ledger" ]; then
    ledger="$GUARANTEE_INDEX_CHECK_DEFAULT_LEDGER"
  fi

  if [ ! -f "$ledger" ] || [ ! -r "$ledger" ]; then
    echo "Error: 保証台帳が読めません: ${ledger}" >&2
    printf '%s\n' '{"status":"error","error":"ledger not readable"}' >&2
    exit "$GUARANTEE_INDEX_CHECK_EX_PREREQ"
  fi

  if [ -n "$explicit_base" ] && [ ! -d "$explicit_base" ]; then
    echo "Error: --base のディレクトリが存在しません: ${explicit_base}" >&2
    printf '%s\n' '{"status":"error","error":"base directory not found"}' >&2
    exit "$GUARANTEE_INDEX_CHECK_EX_PREREQ"
  fi

  local base
  base="$(gic_resolve_base "$ledger" "$explicit_base")"
  base="$(cd "$base" && pwd)"

  local body
  body="$(cat "$ledger")"

  gic_scan "$body"

  if [ "$GIC_HAS_GUARANTEE_SECTION" != "true" ]; then
    echo "Error: 「## 保証」節が見つかりません: ${ledger}" >&2
    echo "  台帳の書式が壊れている可能性があります。pass としては扱いません（索引ゲートの素通りを防ぐため）。" >&2
    printf '%s\n' '{"status":"error","error":"guarantee section not found"}' >&2
    exit "$GUARANTEE_INDEX_CHECK_EX_PREREQ"
  fi

  gic_check_refs "$base"

  local issues_text=""
  if [ "${#GIC_ISSUES[@]}" -gt 0 ]; then
    issues_text="$(printf '%s\n' "${GIC_ISSUES[@]}")"
  fi
  local guarantees_text=""
  if [ "${#GIC_GUARANTEES[@]}" -gt 0 ]; then
    guarantees_text="$(printf '%s\n' "${GIC_GUARANTEES[@]}")"
  fi
  local all_refs_text=""
  if [ "${#GIC_ALL_REFS[@]}" -gt 0 ]; then
    all_refs_text="$(printf '%s\n' "${GIC_ALL_REFS[@]}")"
  fi

  printf '%s' "$issues_text" | jq -R -s \
    --arg ledger "$ledger" \
    --arg base "$base" \
    --arg guarantee_rows "$guarantees_text" \
    --arg ref_rows "$all_refs_text" \
    --argjson guarantees "$GIC_GUARANTEE_COUNT" \
    --argjson refs "$GIC_REF_COUNT" \
    --argjson gaps "$GIC_GAP_COUNT" '
      # gic_escape_field の逆変換。`\\` の次の1文字だけを見る単一パスで復元する
      # （`gsub("\\\\t")` → `gsub("\\\\\\\\")` の2段階だと `\\t`（バックスラッシュ+t）を
      #  取り違えるため、必ず1回の走査で解く）。
      def unesc: gsub("\\\\(?<c>.)"; if .c == "t" then "\t" else .c end);
      def rows($text): $text | split("\n") | map(select(length > 0) | split("\t") | map(unesc));
      [ split("\n")[]
        | select(length > 0)
        | split("\t")
        | map(unesc)
        | {
            guarantee_id: .[0],
            ref: (if (.[1] // "") == "" then null else .[1] end),
            reason: .[2]
          }
      ] as $broken
      | rows($ref_rows) as $ref_list
      | [ rows($guarantee_rows)[]
          | . as $g
          | {
              guarantee_id: $g[1],
              statement: $g[2],
              tests: [ $ref_list[] | select(.[0] == $g[0]) | .[1] ],
              provenance: {
                kind: $g[3],
                issue: (if ($g[4] // "") == "" then null else ($g[4] | tonumber) end)
              }
            }
        ] as $guarantee_list
      | {
          status: (if ($broken | length) == 0 then "pass" else "fail" end),
          ledger: $ledger,
          base: $base,
          counts: {
            guarantees: $guarantees,
            refs: $refs,
            gaps: $gaps,
            broken: ($broken | length)
          },
          guarantees: $guarantee_list,
          broken: $broken
        }
    '

  if [ "${#GIC_ISSUES[@]}" -gt 0 ]; then
    echo "Error: 保証台帳の索引に ${#GIC_ISSUES[@]} 件の問題があります（${ledger}）。詳細は stdout の JSON を参照してください。" >&2
    exit "$GUARANTEE_INDEX_CHECK_EX_FAIL"
  fi

  if [ "$GIC_GUARANTEE_COUNT" -eq 0 ]; then
    echo "Warning: 保証が1件も登録されていません（${ledger}）。索引は空のため pass ですが、台帳としては未整備です。" >&2
  fi

  # 裁可待ちは「裁可前のドラフト」の規約値であり、正本台帳に残っているのは裁可経路の
  # 取りこぼし（＝出自を追跡できない約束が missing_provenance を回避して登録された状態）。
  # 書式としては正当なので status は落とさないが、黙って通さず件数を stderr に出す。
  gic_warn_pending_provenance

  exit "$GUARANTEE_INDEX_CHECK_EX_PASS"
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
