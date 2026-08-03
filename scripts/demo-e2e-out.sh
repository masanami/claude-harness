#!/bin/bash
# demo-e2e-out.sh
# 使い方: scripts/demo-e2e-out.sh <CASE_ID>（詳細は下記参照）
# 仕様の正本は scripts/specs/demo-e2e-out.md を参照。
#
# /demo-e2e（skills/demo-e2e/SKILL.md Step 2-2）の成果物パス規則（SAFE_CASE_ID導出・
# attempt採番）を、実行のたびのLLMアドホック再実装から決定的スクリプトへ切り出したもの
# （Issue #147）。エンコード規則は PR #146 4ラウンド目レビューで確定した「一律エンコード
# （条件付きハッシュにしない。常にサニタイズ済み可読部+元CASE_IDのハッシュを付与）」を採用する。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 純粋関数（外部コマンドを起動しない）
# ---------------------------------------------------------------------------

# 前後の空白（space/tab/newline等）を取り除く。
# `[[:space:]]` パターンマッチはロケール依存（呼び出し環境のLC_ALL/LC_CTYPE次第で
# 全角スペース等の非ASCII文字を空白とみなすかどうかがブレる）ため、`local LC_ALL=C`
# でこの関数の実行中のみロケールをCへ固定し、呼び出し環境に関わらず結果を決定的にする
# （self-review指摘の回帰修正）。
trim_whitespace() {
  local LC_ALL=C
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# trim後に空文字なら "blank"、そうでなければ "non-blank" を返す。
classify_case_id_blank() {
  local case_id="$1"
  local trimmed
  trimmed="$(trim_whitespace "$case_id")"
  if [ -z "$trimmed" ]; then
    echo "blank"
  else
    echo "non-blank"
  fi
}

# CASE_ID 中の [A-Za-z0-9._-] 以外の文字を "_" に置換した「サニタイズ済み可読部」を返す。
# これ単体はファイルシステム上安全とは限らない（"."/".." 等）。安全化は
# compute_safe_case_id 側でハッシュを常に付加することで担保する。
# 実装上の注意（self-review指摘の回帰修正）:
#   - 改行はsed（行単位処理）を通しても`_`に置換されず素通りするため、sedに渡す前に
#     bashのパラメータ展開で明示的に`_`へ置換しておく（sedは行区切りとしての改行自体を
#     パターンスペース内の文字として扱わないため、文字クラスにマッチさせられない）
#   - ロケール依存でマルチバイト文字の置換結果がブレる（UTF-8ロケールでは1文字=1つの
#     `_`、Cロケールでは1バイト=1つの`_`になる）ほか、不正なバイト列を含むとmacOSの
#     sedがロケール依存で`illegal byte sequence`エラーを起こし可読部が消失しうるため、
#     `LC_ALL=C`でバイト単位の決定的な置換に固定する（実行環境のロケール設定に
#     safe_case_idが左右されないようにする）
sanitize_case_id() {
  local case_id="$1"
  case_id="${case_id//$'\n'/_}"
  printf '%s' "$case_id" | LC_ALL=C sed -E 's/[^A-Za-z0-9._-]/_/g'
}

# ---------------------------------------------------------------------------
# ハッシュ・エンコード（shasum/sha256sum に依存するため副作用ありセクションに置く）
# ---------------------------------------------------------------------------

# 元のCASE_ID（サニタイズ前）のSHA-256先頭8文字（16進数小文字）を返す。
# shasum（macOS標準）・sha256sum（coreutils）のどちらかがあれば動く
# （両方とも同じダイジェスト値を返すためプラットフォーム間で結果が一致する）。
compute_case_hash8() {
  local case_id="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$case_id" | shasum -a 256 | cut -c1-8
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$case_id" | sha256sum | cut -c1-8
  else
    echo "Error: neither shasum nor sha256sum found in PATH" >&2
    return 1
  fi
}

# 一律エンコード規則（単射）: <サニタイズ済み可読部>-<元CASE_IDのハッシュ8文字>。
# 非空の CASE_ID すべてに対して常にこの1つの規則を適用する（置換が発生した場合のみ
# ハッシュを付けるような条件分岐にはしない。PR #146 4ラウンド目レビューで確定した仕様）。
# サニタイズ済み可読部が同じでも、元のCASE_IDが異なればハッシュも異なるため衝突しない。
# "." や ".." もこの規則で常にハッシュが付き自然に安全な文字列になるため、
# 特別なフォールバック分岐は不要。
compute_safe_case_id() {
  local case_id="$1"
  local sanitized hash
  sanitized="$(sanitize_case_id "$case_id")"
  hash="$(compute_case_hash8 "$case_id")" || return 1
  printf '%s-%s' "$sanitized" "$hash"
}

# ---------------------------------------------------------------------------
# プロジェクトroot解決（skills/demo/scripts/run-walkthrough.mjs の
# resolveProjectRoot と同一規則。WALKTHROUGH_PROJECT_ROOT優先、無ければ
# git rev-parse --show-toplevel、それも失敗すればcwd）。
# ---------------------------------------------------------------------------

resolve_project_root_raw() {
  if [ -n "${WALKTHROUGH_PROJECT_ROOT:-}" ]; then
    printf '%s' "$WALKTHROUGH_PROJECT_ROOT"
    return 0
  fi
  local root
  if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s' "$root"
  else
    pwd
  fi
}

# ---------------------------------------------------------------------------
# attempt 採番（実ファイルシステムを参照する読み取り専用スキャン）
# ---------------------------------------------------------------------------

# <case_dir>（projectRootAbs 配下の demo-e2e-artifacts/<safe_case_id>）配下の
# attempt-<数字> ディレクトリの最大番号+1を返す。該当ディレクトリが無い、または
# attempt-* が1件も無ければ 1（初回）。
# 実装上の注意（self-review指摘の回帰修正）: attempt-08 のようにゼロ埋めされた既存
# ディレクトリ（人間の手動作成・別ツール由来等、本スクリプト以外が作った名前の可能性が
# ある）が存在すると、bashの算術評価（`$(( ))`）は先頭ゼロの数値を8進数として解釈し
# `08`/`09` で "value too great for base" エラーになる。`10#` プレフィックスを付けて
# 常に10進数として解釈させる。
compute_next_attempt() {
  local case_dir="$1"
  local max=0
  if [ -d "$case_dir" ]; then
    local d name n
    while IFS= read -r -d '' d; do
      name="$(basename "$d")"
      if [[ "$name" =~ ^attempt-([0-9]+)$ ]]; then
        n=$((10#${BASH_REMATCH[1]}))
        if [ "$n" -gt "$max" ]; then
          max="$n"
        fi
      fi
    done < <(find "$case_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
  echo $((max + 1))
}

# ---------------------------------------------------------------------------
# gitignore 警告（git呼び出し）
# ---------------------------------------------------------------------------

# projectRoot の .gitignore（git管理下）が demo-e2e-artifacts をカバーしていなければ
# "true"（警告あり）、カバーしていれば "false" を返す。独自にgitignoreパターンを
# パースせず git check-ignore に判定させる。非gitリポジトリ等で判定不能な場合は
# 安全側に倒し "true" を返す。
check_gitignore_warning() {
  local project_root="$1"
  local rc
  git -C "$project_root" check-ignore -q "demo-e2e-artifacts" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "false"
  else
    echo "true"
  fi
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <CASE_ID>" >&2
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local case_id_raw="${1:-}"

  if [ "$(classify_case_id_blank "$case_id_raw")" = "blank" ]; then
    echo "Error: CASE_ID must not be empty or whitespace-only" >&2
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  # 前後の空白は識別子の一部とみなさない（trim後の値をsafe_case_id導出にも使う。
  # self-review指摘の回帰修正: 空判定はtrim後で行うのに導出は生値のままだと、
  # 前後空白の有無だけで別ケース扱いになりattempt連番が分裂していた）。
  local case_id
  case_id="$(trim_whitespace "$case_id_raw")"

  local safe_case_id
  if ! safe_case_id="$(compute_safe_case_id "$case_id")"; then
    exit 1
  fi

  local project_root_raw
  project_root_raw="$(resolve_project_root_raw)"
  if [ ! -d "$project_root_raw" ]; then
    echo "Error: project root directory does not exist: ${project_root_raw}" >&2
    exit 1
  fi
  local project_root_abs
  project_root_abs="$(cd "$project_root_raw" && pwd)"

  local case_dir="${project_root_abs}/demo-e2e-artifacts/${safe_case_id}"
  local attempt
  attempt="$(compute_next_attempt "$case_dir")"

  local out_dir="demo-e2e-artifacts/${safe_case_id}/attempt-${attempt}"

  local gitignore_warning
  gitignore_warning="$(check_gitignore_warning "$project_root_abs")"

  jq -n -c \
    --arg safe_case_id "$safe_case_id" \
    --arg out_dir "$out_dir" \
    --argjson attempt "$attempt" \
    --argjson gitignore_warning "$gitignore_warning" \
    '{safe_case_id: $safe_case_id, out_dir: $out_dir, attempt: $attempt, gitignore_warning: $gitignore_warning}'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
