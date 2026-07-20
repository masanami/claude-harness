#!/bin/bash
# mutation-run.sh
# skills/explain-e2e/SKILL.md Phase 2 の Mutation 段階から、呼び出し元自身が
# Bash ツールで直接呼び出す決定的スクリプト（Issue #47・#114）。
#
# 背景: 従来の /explain-e2e Step 2-3（ミューテーション検証）は「注入→テスト実行→
# git checkout -- による復元→復元確認の再実行」という4段の手順をLLMの規律だけに
# 委ねており、特に「復元できたことの確認」が実行者自身の自己申告になっていた
# （幻覚報告で「注入したまま放置」を防止できない）。本スクリプトはこの機械的な部分
# （注入そのもの以外の全手順）を決定的なシェル処理に置き換え、変異エージェントの役割を
# 「意味のある変異点を選んで Edit する」だけに縮小する。
#
# 使い方:
#   scripts/mutation-run.sh <test_command> <mutated_file_1> [<mutated_file_2> ...]
#     test_command      既に注入済み（不具合を仕込んだ）状態のワーキングツリーに対し、
#                       対象テストのみを実行するシェルコマンド文字列（bash -c で実行）
#     mutated_file_*    呼び出し側（変異エージェント）が Edit で書き換え済みのファイルパス
#                       （1個以上）。絶対パス・リポジトリルート相対パスのいずれでもよい
#                       （手順0のクリーン確認では内部でルート相対へ正規化して比較する。
#                       normalize_to_repo_relative 参照）。復元スコープの検証・
#                       `git checkout --` の対象になる
#
# 手順（この順で機械的に実行する）:
#   0. クリーン確認: `git status --porcelain` の変更が mutated_file_* の範囲内に
#      収まっているかを検証する。範囲外の未コミット変更が1件でもあれば、
#      `git checkout -- <files>` では作業ツリーを完全にクリーンへ戻せない前提が崩れるため、
#      テスト実行に進まず真の異常系として exit 非0 で終了する（stdoutにJSONは出さない）。
#      mutated_file_* のいずれにも変更が無い場合（注入が実際には行われていない）も
#      同様に異常系として扱う。
#   1. test_command を実行し、失敗したか（testFailed）・失敗理由がアサーション起因らしいか
#      （failureKind: "assertion"|"other"|"none"）を出力のbest-effortパースで判定する。
#   2. `git checkout -- <mutated_file_*>` で注入を復元する。
#   3. 復元確認: `git status --porcelain -- <mutated_file_*>` が空であることを確認する
#      （restored）。
#   4. 復元できた場合のみ test_command を再実行し、パスすることを確認する（rePassed）。
#      復元できなかった場合は再実行しても意味がない（注入済み状態のままの再実行になる）ため
#      スキップし rePassed: false とする。
#
# 出力（stdout にJSON1個）:
#   {"testFailed": bool, "failureKind": "assertion"|"other"|"none", "restored": bool, "rePassed": bool}
#
# 終了コード（呼び出し側（/explain-e2e の SKILL.md Phase 2）が「JSON上の自己申告」と
# 「実際の終了コード」を突き合わせて不整合を検出できるよう、JSON内容と独立に意味を持たせる）:
#   0  restored && rePassed（復元・再パスとも確認できた「安全な」状態）
#   1  restored/rePassed のいずれかが false（要人間介入。前段の真の異常系
#      ＝クリーン確認失敗・引数不正・非gitリポジトリ等も同じ1で終了するが、
#      その場合は stdout にJSONを出さない点で区別できる）
#   2  jq 不在
#
# テスト容易性のため、外部コマンド（git/test_command）を起動する処理（run_command/main）と、
# 外部コマンドを起動しない純粋なテキスト処理（porcelain_path/classify_failure_kind/
# check_dirty_scope）を関数として分離している。純粋関数はスクリプトを source して
# 直接テストできる（scripts/tests/test-mutation-run.sh）。
#
# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。

set -u

check_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but was not found in PATH" >&2
    printf '{"error":"jq not found"}\n' >&2
    return 1
  fi
  return 0
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} <test_command> <mutated_file_1> [<mutated_file_2> ...]

  test_command      Shell command string (run via bash -c) that exercises the
                     already-mutated working tree and exits non-zero on failure.
  mutated_file_*     One or more file paths already edited (mutation injected)
                     by the caller before invoking this script. Used both to
                     scope the pre-flight dirty-tree check and to restore
                     ("git checkout --") after the test run.
EOF
}

# ---------------------------------------------------------------------------
# 純粋関数（外部コマンドを起動しない。source して直接テスト可能）
# ---------------------------------------------------------------------------

# `git status --porcelain` の1行から path 部分を取り出す（先頭2文字のステータス+空白）。
# rename ("R  old -> new") は対象外（変異対象は既存の追跡ファイルの中身編集のみを想定）。
porcelain_path() {
  local line="$1"
  printf '%s' "${line:3}"
}

# mutated_file 引数をリポジトリルート相対パスへ正規化する（check_dirty_scope の比較専用。
# `git checkout --`/`git status --porcelain -- <file>` は絶対パスのままでも正しく動作するため
# 変換しない）。
# 呼び出し契約（agents/e2e-mutation-injector.md）では変異エージェントは「実際に編集した
# ファイルの絶対パス」を返すが、`git status --porcelain`（引数無し・リポジトリ全体の手順0）が
# 返す path は常にリポジトリルート相対である。この不一致を正規化せずに比較すると、
# check_dirty_scope が常に「範囲外の変更」と誤検出し、実運用の全ミューテーションがテスト実行
# より前に打ち切られてしまう（回帰テスト: scripts/tests/test-mutation-run.sh）。
# repo_root 配下の絶対パスのみをルート相対へ変換し、それ以外（既に相対パス／repo_root取得失敗／
# repo_root 外の絶対パス）はそのまま返す（repo_root 外の絶対パスをそのまま返すのは意図的であり、
# 結果として比較不一致＝「範囲外の変更」として安全側に検出される）。
normalize_to_repo_relative() {
  local repo_root="$1"
  local file="$2"
  if [ -n "$repo_root" ] && [ "${file#/}" != "$file" ] && [ "${file#"$repo_root"/}" != "$file" ]; then
    printf '%s' "${file#"$repo_root"/}"
  else
    printf '%s' "$file"
  fi
}

# テスト出力からアサーション起因の失敗らしいかをbest-effortで判定する。
# 対応形式の例: Jest/Vitest/Playwright の "AssertionError" "expect(" 系、
# 一般的な "Expected ... Received ..." 形式。マッチしなければ "other"。
classify_failure_kind() {
  local output="$1"
  if printf '%s\n' "$output" | grep -qiE 'AssertionError|expect\(|toHaveBeenCalled|toBe\(|toEqual\(|toContain\(|toMatch\(|assert(ion)? failed|Expected[: ].*(Received|but got)'; then
    echo "assertion"
  else
    echo "other"
  fi
}

# `git status --porcelain` の出力全体（複数行）と対象ファイル一覧を受け取り、
# 対象ファイルの範囲外に変更が無いかを判定する（クリーン確認の中核）。
# 引数: porcelain_output, file...
# 結果: グローバル変数
#   OUT_OF_SCOPE_LINES  範囲外だった porcelain 行（空文字なら範囲外無し）
#   ANY_TARGET_DIRTY     "true"|"false"（対象ファイルの中に実際に変更があったか）
check_dirty_scope() {
  local porcelain_output="$1"
  shift
  local files=("$@")
  OUT_OF_SCOPE_LINES=""
  ANY_TARGET_DIRTY="false"
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local path
    path="$(porcelain_path "$line")"
    local matched="false"
    local f
    for f in "${files[@]}"; do
      if [ "$path" = "$f" ]; then
        matched="true"
        ANY_TARGET_DIRTY="true"
        break
      fi
    done
    if [ "$matched" = "false" ]; then
      OUT_OF_SCOPE_LINES="${OUT_OF_SCOPE_LINES}${line}
"
    fi
  done <<<"$porcelain_output"
}

# ---------------------------------------------------------------------------
# 外部コマンド実行（副作用あり）
# ---------------------------------------------------------------------------

# ファイルの実体パス（symlink解決込みの絶対パス）を求める。macOS標準環境には
# realpath/readlink -f が無いため、ディレクトリ部分を実際に `cd` して `pwd -P`
# （物理パスを返すシェル組み込み）を取る移植性の高いイディオムを使う。
# `git rev-parse --show-toplevel` は常に物理パスを返す（実機確認済み）一方、呼び出し側から
# 渡される mutated_file の絶対パスはシンボリックリンク経由（例: macOS の /tmp -> /private/tmp、
# /var -> /private/var。`mktemp -d` の返り値は後者に該当し、テストスイート自身にも影響する）の
# ことがあり、そのまま repo_root と前方一致比較すると常に不一致になる。この関数は
# normalize_to_repo_relative に渡す前段の正規化として main() から呼ばれる（ファイルI/Oを伴うため
# 純粋関数セクションではなくこちらに置く）。ディレクトリが解決できない場合は入力をそのまま返す
# （安全側: 比較不一致のままとなり「範囲外」として検出される）。
canonicalize_path() {
  local path="$1"
  local dir base resolved_dir
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  resolved_dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  if [ -z "$resolved_dir" ]; then
    printf '%s' "$path"
    return
  fi
  printf '%s/%s' "$resolved_dir" "$base"
}

# test_command を実行し、標準出力/標準エラーを結合してグローバル変数
# LAST_OUTPUT / LAST_EXIT_CODE に格納する。生の出力は stderr にも転記する
# （出力規約: stdoutにはJSONのみ。呼び出し側がfailureKindの手掛かりを追えるように）。
run_test_command() {
  local cmd="$1"
  echo "--- test: ${cmd} ---" >&2
  LAST_OUTPUT="$(bash -c "$cmd" 2>&1)"
  LAST_EXIT_CODE=$?
  printf '%s\n' "$LAST_OUTPUT" >&2
  echo "--- test exit: ${LAST_EXIT_CODE} ---" >&2
}

main() {
  if [ "$#" -lt 2 ]; then
    echo "Error: test_command and at least one mutated_file are required" >&2
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 2
  fi

  local test_command="$1"
  shift
  local files=("$@")

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: not a git repository (git rev-parse --git-dir failed)" >&2
    exit 1
  fi

  # 比較専用のルート相対パスを作る（git操作自体は元の files を絶対パスのまま使う。
  # normalize_to_repo_relative のコメント参照）。
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  local normalized_files=()
  local f
  for f in "${files[@]}"; do
    normalized_files+=("$(normalize_to_repo_relative "$repo_root" "$(canonicalize_path "$f")")")
  done

  # --- 手順0: クリーン確認 ---
  local porcelain_output
  porcelain_output="$(git status --porcelain 2>&1)"
  check_dirty_scope "$porcelain_output" "${normalized_files[@]}"

  if [ -n "$OUT_OF_SCOPE_LINES" ]; then
    echo "Error: uncommitted changes exist outside the mutated file(s); 'git checkout --' cannot guarantee a full restore. Offending path(s):" >&2
    printf '%s' "$OUT_OF_SCOPE_LINES" >&2
    exit 1
  fi
  if [ "$ANY_TARGET_DIRTY" = "false" ]; then
    echo "Error: none of the specified mutated file(s) show uncommitted changes; no mutation detected." >&2
    exit 1
  fi

  # --- 手順1: テスト実行＋失敗判定 ---
  run_test_command "$test_command"
  local test_exit="$LAST_EXIT_CODE"
  local test_output="$LAST_OUTPUT"

  local test_failed="false"
  local failure_kind="none"
  if [ "$test_exit" -ne 0 ]; then
    test_failed="true"
    failure_kind="$(classify_failure_kind "$test_output")"
  fi

  # --- 手順2: 復元 ---
  local restored="false"
  if git checkout -- "${files[@]}" 2>/dev/null; then
    local post_porcelain
    post_porcelain="$(git status --porcelain -- "${files[@]}" 2>&1)"
    # --- 手順3: 復元確認 ---
    if [ -z "$post_porcelain" ]; then
      restored="true"
    fi
  fi

  # --- 手順4: 復元できた場合のみ再実行してパス確認 ---
  local re_passed="false"
  if [ "$restored" = "true" ]; then
    run_test_command "$test_command"
    if [ "$LAST_EXIT_CODE" -eq 0 ]; then
      re_passed="true"
    fi
  fi

  jq -n \
    --argjson testFailed "$test_failed" \
    --arg failureKind "$failure_kind" \
    --argjson restored "$restored" \
    --argjson rePassed "$re_passed" \
    '{testFailed: $testFailed, failureKind: $failureKind, restored: $restored, rePassed: $rePassed}'

  if [ "$restored" = "true" ] && [ "$re_passed" = "true" ]; then
    exit 0
  else
    exit 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
