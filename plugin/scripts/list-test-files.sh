#!/bin/bash
# list-test-files.sh
# 使い方: list-test-files.sh [--root <dir>] [--include <glob>]... [--exclude <glob>]...
#                            [--e2e <glob>]... [--integration <glob>]...
# リポジトリ内のテストファイルを決定的に列挙し、E2E / 結合 / 単体の区分を付けて
# {status, root, source, counts, files} の JSON を stdout に1個返す。
# 仕様の正本は scripts/specs/list-test-files.md を参照。
#
# 設計上の要点（正本の再掲ではなく、実装を読む人向けの注記）:
# - 列挙は決定的でなければならない（同じ入力から常に同じ出力）。列挙元は git ls-files を
#   第一手とし（追跡対象のみ・ignore 済みを自動除外）、非 git 環境でのみ find へ落ちる。
#   出力は LC_ALL=C のパス昇順で固定する。
# - 「テストファイルか」の判定と「E2E / 結合 / 単体のどれか」の判定は別段階。前者に漏れると
#   /surface-audit が担保済みの公開面を GAP と誤報するため、判定規則は広めに取り、除外は
#   フィクスチャ・モック・設定ファイル等の「テスト本体ではないことが確実なもの」に限る。
# - プロジェクト固有のレイアウト（例: e2e が tests/browser/ にある）はオプションで上書きする。
#   スクリプト側が CLAUDE.md を読んで推測することはしない（決定的処理と意味判断の分離）。
# - 判定結果を返す関数は「戻り値 + グローバル変数」で受け渡す（コマンド置換や
#   プロセス置換はサブシェルになり、関数内で設定したグローバル変数が呼び出し元へ
#   伝搬しないため。scripts/README.md「テスト」節の既知の落とし穴）。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 2
}

# 終了コード（scripts/specs/list-test-files.md と一致させること）
LIST_TEST_FILES_EX_OK=0     # 列挙に成功した（0件の場合も status で表現し exit 0）
LIST_TEST_FILES_EX_PREREQ=2 # 実行前提の欠落（jq 不在・引数不正・root が読めない）

# 除外するディレクトリ名（テスト本体が置かれないことが確実なもの）。
LIST_TEST_FILES_EXCLUDED_DIRS="node_modules vendor dist build out target coverage .git .venv venv __pycache__ __snapshots__ __mocks__ snapshots fixtures __fixtures__ testdata"

# テストファイルとみなす拡張子（ディレクトリ規則で拾う場合の絞り込みに使う）。
LIST_TEST_FILES_CODE_EXTS="js jsx ts tsx mjs cjs py rb go java kt rs php cs swift scala sh feature"

# テストディレクトリ名（この配下のコードファイルをテストとみなす）。
LIST_TEST_FILES_TEST_DIRS="test tests __tests__ spec specs e2e cypress playwright"

# 分類（E2E）に使うディレクトリ名。
LIST_TEST_FILES_E2E_DIRS="e2e E2E cypress playwright acceptance uitest"

# 分類（結合）に使うディレクトリ名。'it' のような短すぎる名前は誤検出するため採らない。
LIST_TEST_FILES_INTEGRATION_DIRS="integration integrations integration-test integration-tests integration_test integration_tests"

# 呼び出し側から渡された glob（bash 3.2 に連想配列が無いため配列で保持する）
LTF_INCLUDE_GLOBS=()
LTF_EXCLUDE_GLOBS=()
LTF_E2E_GLOBS=()
LTF_INTEGRATION_GLOBS=()

# パスが glob 配列のいずれかにマッチするか。マッチした glob は LTF_MATCHED_GLOB へ格納する。
# 引数: <パス> <glob...>
ltf_match_any() {
  local path="$1"
  shift
  local glob
  LTF_MATCHED_GLOB=""
  for glob in "$@"; do
    [ -z "$glob" ] && continue
    # 右辺は glob として解釈させるため意図的に引用しない
    # shellcheck disable=SC2053
    if [[ "$path" == $glob ]]; then
      LTF_MATCHED_GLOB="$glob"
      return 0
    fi
  done
  return 1
}

# パスのディレクトリ部分に、空白区切りリスト中の名前がひとつでも含まれるか。
# マッチしたディレクトリ名は LTF_MATCHED_DIR へ格納する。
# 引数: <パス> <空白区切りのディレクトリ名リスト>
ltf_has_dir_component() {
  local path="$1"
  local names="$2"
  local dir_part="${path%/*}"
  local name
  LTF_MATCHED_DIR=""
  # ファイル名しか無い（ディレクトリ部分が無い）場合は対象外
  [ "$dir_part" = "$path" ] && return 1
  for name in $names; do
    case "/${dir_part}/" in
      */"${name}"/*)
        LTF_MATCHED_DIR="$name"
        return 0
        ;;
    esac
  done
  return 1
}

# 除外対象か（除外ディレクトリ配下・設定ファイル・型定義ファイル・--exclude 指定）。
# --exclude は --include より優先する（除外は「見たくないもの」の最終指定であるため）。
ltf_is_excluded() {
  local path="$1"
  local base="${path##*/}"

  if ltf_has_dir_component "$path" "$LIST_TEST_FILES_EXCLUDED_DIRS"; then
    return 0
  fi

  case "$base" in
    *.d.ts) return 0 ;;
    jest.config.* | vitest.config.* | playwright.config.* | cypress.config.* | karma.conf.* | *.setup.ts | *.setup.js) return 0 ;;
  esac

  if [ "${#LTF_EXCLUDE_GLOBS[@]}" -gt 0 ] && ltf_match_any "$path" "${LTF_EXCLUDE_GLOBS[@]}"; then
    return 0
  fi

  return 1
}

# テストファイルか。判定に使った規則を LTF_TEST_RULE へ格納する。
ltf_is_test_file() {
  local path="$1"
  local base="${path##*/}"
  local ext="${base##*.}"
  local stem="${base%.*}"
  local code_ext

  LTF_TEST_RULE=""

  if [ "${#LTF_INCLUDE_GLOBS[@]}" -gt 0 ] && ltf_match_any "$path" "${LTF_INCLUDE_GLOBS[@]}"; then
    LTF_TEST_RULE="option:include(${LTF_MATCHED_GLOB})"
    return 0
  fi

  # ファイル名規則: foo.test.ts / foo_test.go / foo-spec.js / user_spec.rb / test_foo.py 等
  case "$base" in
    *[._-][Tt]est.* | *[._-][Ss]pec.* | [Tt]est[._-]* | [Ss]pec[._-]*)
      LTF_TEST_RULE="name:test-or-spec"
      return 0
      ;;
  esac

  # クラス名規則: FooTest.java / FooTests.cs / FooTestCase.php 等
  case "$stem" in
    *Test | *Tests | *TestCase | *Spec)
      LTF_TEST_RULE="name:class-suffix"
      return 0
      ;;
  esac

  # Gherkin のフィーチャファイルは常にテスト（振る舞い記述そのもの）
  if [ "$ext" = "feature" ]; then
    LTF_TEST_RULE="ext:feature"
    return 0
  fi

  # ディレクトリ規則: テストディレクトリ配下のコードファイル
  if ltf_has_dir_component "$path" "$LIST_TEST_FILES_TEST_DIRS"; then
    for code_ext in $LIST_TEST_FILES_CODE_EXTS; do
      if [ "$ext" = "$code_ext" ]; then
        LTF_TEST_RULE="dir:${LTF_MATCHED_DIR}"
        return 0
      fi
    done
  fi

  return 1
}

# E2E / 結合 / 単体 の分類。結果を LTF_CATEGORY、判定規則を LTF_CATEGORY_RULE へ格納する
# （コマンド置換で受け取るとサブシェルになり LTF_CATEGORY_RULE が伝搬しないため、
#  戻り値ではなくグローバル変数で返す）。
# 優先順位: --e2e / --integration の明示指定 > ディレクトリ・ファイル名規則 > 単体（既定）
ltf_classify() {
  local path="$1"
  local base="${path##*/}"
  local ext="${base##*.}"

  if [ "${#LTF_E2E_GLOBS[@]}" -gt 0 ] && ltf_match_any "$path" "${LTF_E2E_GLOBS[@]}"; then
    LTF_CATEGORY="e2e"
    LTF_CATEGORY_RULE="option:e2e(${LTF_MATCHED_GLOB})"
    return 0
  fi

  if [ "${#LTF_INTEGRATION_GLOBS[@]}" -gt 0 ] && ltf_match_any "$path" "${LTF_INTEGRATION_GLOBS[@]}"; then
    LTF_CATEGORY="integration"
    LTF_CATEGORY_RULE="option:integration(${LTF_MATCHED_GLOB})"
    return 0
  fi

  if ltf_has_dir_component "$path" "$LIST_TEST_FILES_E2E_DIRS"; then
    LTF_CATEGORY="e2e"
    LTF_CATEGORY_RULE="dir:${LTF_MATCHED_DIR}"
    return 0
  fi

  case "$base" in
    *[._-]e2e[._-]* | e2e[._-]*)
      LTF_CATEGORY="e2e"
      LTF_CATEGORY_RULE="name:e2e"
      return 0
      ;;
  esac

  if [ "$ext" = "feature" ]; then
    LTF_CATEGORY="e2e"
    LTF_CATEGORY_RULE="ext:feature"
    return 0
  fi

  if ltf_has_dir_component "$path" "$LIST_TEST_FILES_INTEGRATION_DIRS"; then
    LTF_CATEGORY="integration"
    LTF_CATEGORY_RULE="dir:${LTF_MATCHED_DIR}"
    return 0
  fi

  case "$base" in
    *[._-]integration[._-]* | integration[._-]* | *[._-]int[._-]*)
      LTF_CATEGORY="integration"
      LTF_CATEGORY_RULE="name:integration"
      return 0
      ;;
  esac

  LTF_CATEGORY="unit"
  LTF_CATEGORY_RULE="default:unit"
  return 0
}

# 列挙元（git / find）を判定して LTF_SOURCE へ格納する。
# ltf_enumerate はプロセス置換（サブシェル）で呼ばれるため、列挙元の判定はここで
# 別途行い、呼び出し元のコンテキストで値を確定させる。
ltf_detect_source() {
  local root="$1"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    LTF_SOURCE="git"
  else
    LTF_SOURCE="find"
  fi
}

# 列挙元の候補ファイルを root 相対パスの NUL 区切りで stdout に流す。
# 引数: <root の絶対パス> <列挙元（git|find）>
ltf_enumerate() {
  local root="$1"
  local source="$2"
  local prune_expr=()
  local name found

  if [ "$source" = "git" ]; then
    # --others --exclude-standard を付けて未追跡ファイルも拾う（追跡済みだけを見ると、
    # まだコミットしていない新しいテストを黙って取りこぼす）。ignore 済みは除外される。
    git -C "$root" ls-files -z --cached --others --exclude-standard 2>/dev/null
    return 0
  fi

  for name in $LIST_TEST_FILES_EXCLUDED_DIRS; do
    if [ "${#prune_expr[@]}" -gt 0 ]; then
      prune_expr+=(-o)
    fi
    prune_expr+=(-name "$name")
  done

  (
    cd "$root" || exit 1
    find . \( "${prune_expr[@]}" \) -type d -prune -o -type f -print0 2>/dev/null |
      while IFS= read -r -d '' found; do
        printf '%s\0' "${found#./}"
      done
  )
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} [--root <dir>] [--include <glob>]... [--exclude <glob>]...
       ${prog} [--e2e <glob>]... [--integration <glob>]...

  --root <dir>          列挙の起点（既定: cwd）
  --include <glob>      テストファイルとして追加で扱う glob（繰り返し可）
  --exclude <glob>      列挙から除外する glob（繰り返し可・--include より優先）
  --e2e <glob>          E2E に分類する glob（繰り返し可・既定規則より優先）
  --integration <glob>  結合に分類する glob（繰り返し可・既定規則より優先）

  glob は root からの相対パスに対して評価する（\`*\` は \`/\` にもマッチする）。
  stdout に {"status":...,"root":...,"source":...,"counts":{...},"files":[...]} を1個出力する。
  exit code: ${LIST_TEST_FILES_EX_OK}=列挙成功（0件の場合も含む） / ${LIST_TEST_FILES_EX_PREREQ}=実行前提の欠落
EOF
}

# 値を1つ取るオプションの引数チェック（不足時は exit する）
ltf_require_value() {
  local option="$1"
  local count="$2"
  if [ "$count" -lt 2 ]; then
    echo "Error: ${option} requires a value" >&2
    printf '{"status":"error","error":"%s requires a value"}\n' "$option" >&2
    exit "$LIST_TEST_FILES_EX_PREREQ"
  fi
}

main() {
  local root=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        print_usage
        exit 0
        ;;
      --root)
        ltf_require_value "--root" "$#"
        root="$2"
        shift 2
        ;;
      --include)
        ltf_require_value "--include" "$#"
        LTF_INCLUDE_GLOBS+=("$2")
        shift 2
        ;;
      --exclude)
        ltf_require_value "--exclude" "$#"
        LTF_EXCLUDE_GLOBS+=("$2")
        shift 2
        ;;
      --e2e)
        ltf_require_value "--e2e" "$#"
        LTF_E2E_GLOBS+=("$2")
        shift 2
        ;;
      --integration)
        ltf_require_value "--integration" "$#"
        LTF_INTEGRATION_GLOBS+=("$2")
        shift 2
        ;;
      -*)
        echo "Error: unknown option: $1" >&2
        printf '%s\n' '{"status":"error","error":"unknown option"}' >&2
        print_usage
        exit "$LIST_TEST_FILES_EX_PREREQ"
        ;;
      *)
        echo "Error: unexpected argument: $1" >&2
        printf '%s\n' '{"status":"error","error":"unexpected argument"}' >&2
        print_usage
        exit "$LIST_TEST_FILES_EX_PREREQ"
        ;;
    esac
  done

  if ! check_jq '{"status":"error","error":"jq not found"}'; then
    exit "$LIST_TEST_FILES_EX_PREREQ"
  fi

  if [ -z "$root" ]; then
    root="$(pwd)"
  fi
  if [ ! -d "$root" ]; then
    echo "Error: root directory not found: ${root}" >&2
    printf '%s\n' '{"status":"error","error":"root directory not found"}' >&2
    exit "$LIST_TEST_FILES_EX_PREREQ"
  fi
  root="$(cd "$root" && pwd)"

  ltf_detect_source "$root"

  local rows=()
  local skipped=0
  local path

  while IFS= read -r -d '' path; do
    [ -z "$path" ] && continue
    case "$path" in
      *$'\t'* | *$'\n'*)
        # タブ・改行を含むパスは TSV 中間表現（タブ区切り・行区切り）の境界を壊し、
        # 1件のファイルが複数の不正なエントリに割れる。黙って落とさず件数として報告する。
        skipped=$((skipped + 1))
        echo "Warning: skipped path containing a tab or newline character: ${path}" >&2
        continue
        ;;
    esac
    # git ls-files は worktree から消えた追跡ファイルも返すため、実体の存在を確認する
    [ -f "${root}/${path}" ] || continue
    ltf_is_excluded "$path" && continue
    ltf_is_test_file "$path" || continue
    ltf_classify "$path"
    rows+=("${path}"$'\t'"${LTF_CATEGORY}"$'\t'"${LTF_TEST_RULE}|${LTF_CATEGORY_RULE}")
  done < <(ltf_enumerate "$root" "$LTF_SOURCE")

  local rows_text=""
  if [ "${#rows[@]}" -gt 0 ]; then
    rows_text="$(printf '%s\n' "${rows[@]}" | LC_ALL=C sort)"
  fi

  printf '%s' "$rows_text" | jq -R -s -c \
    --arg root "$root" \
    --arg source "$LTF_SOURCE" \
    --argjson skipped "$skipped" '
      [ split("\n")[]
        | select(length > 0)
        | split("\t")
        | {path: .[0], category: .[1], rule: .[2]}
      ] as $files
      | {
          status: (if ($files | length) == 0 then "no_test_files_found" else "ok" end),
          root: $root,
          source: $source,
          counts: {
            e2e: ([$files[] | select(.category == "e2e")] | length),
            integration: ([$files[] | select(.category == "integration")] | length),
            unit: ([$files[] | select(.category == "unit")] | length),
            total: ($files | length),
            skipped: $skipped
          },
          files: $files
        }
    '

  exit "$LIST_TEST_FILES_EX_OK"
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
