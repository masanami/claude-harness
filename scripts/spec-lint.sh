#!/bin/bash
# spec-lint.sh
# 使い方: scripts/spec-lint.sh <spec-file-path>（詳細は下記参照）
# 仕様の正本は scripts/specs/spec-lint.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 1
}

# 曖昧語辞書（単一定義）。severity判定はしない候補列挙のみのため、多少広めに定義してよい。
SPEC_LINT_AMBIGUOUS_WORDS=(
  "適切に"
  "必要に応じて"
  "など"
  "等"
  "柔軟に"
  "基本的に"
  "できるだけ"
  "なるべく"
  "状況に応じて"
  "一般的に"
)

# 本文テキストを曖昧語辞書でスキャンし、結果をグローバル変数 AMBIGUOUS_JSON に格納する。
# 引数: 本文テキスト
detect_ambiguous_words() {
  local body="$1"
  local result="[]"
  local lineno=0
  local line
  local word
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    for word in "${SPEC_LINT_AMBIGUOUS_WORDS[@]}"; do
      if [[ "$line" == *"$word"* ]]; then
        result=$(jq -c --argjson line "$lineno" --arg word "$word" --arg text "$line" \
          '. + [{"line": $line, "word": $word, "text": $text}]' <<<"$result")
      fi
    done
  done <<<"$body"
  AMBIGUOUS_JSON="$result"
}

# 本文テキストから `{...}` 形式（中身が空でない）のテンプレートプレースホルダ残骸を検出し、
# 結果をグローバル変数 PLACEHOLDERS_JSON に格納する。
# 引数: 本文テキスト
detect_template_placeholders() {
  local body="$1"
  local result="[]"
  local lineno=0
  local line
  local remaining
  local match
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    remaining="$line"
    while [[ "$remaining" =~ \{[^{}]+\} ]]; do
      match="${BASH_REMATCH[0]}"
      result=$(jq -c --argjson line "$lineno" --arg text "$match" \
        '. + [{"line": $line, "text": $text}]' <<<"$result")
      # $match をクォートせずに ${remaining/$match/} と書くと、$match が glob
      # パターンとして解釈される（例: "[id]" を含む値は文字クラスとして扱われ、
      # リテラル一致に失敗して remaining が縮まらず無限ループする）。クォートして
      # リテラル置換を強制する（実運用ではNext.jsの動的ルート `[id]` 等で頻出）。
      remaining="${remaining/"$match"/}"
    done
  done <<<"$body"
  PLACEHOLDERS_JSON="$result"
}

# spec ファイルの位置からリポジトリルートを解決する。
# git rev-parse --show-toplevel が使える場合はそれを、使えない場合は spec ファイルの
# ディレクトリを返す（フォールバック。エラーにはしない）。
# 引数: spec ファイルの絶対パス（推奨）
resolve_repo_root() {
  local spec_file="$1"
  local dir
  dir="$(cd "$(dirname "$spec_file")" 2>/dev/null && pwd)"
  if [ -z "$dir" ]; then
    dir="."
  fi
  local root
  if root="$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$root" ]; then
    printf '%s' "$root"
  else
    printf '%s' "$dir"
  fi
}

# 本文テキストからバッククォート囲みの相対パス参照を抽出し、repo_root起点で存在確認する。
# 存在しないパスのみ結果に含め、グローバル変数 BROKEN_REFS_JSON に格納する。
# 引数: 本文テキスト、repo_root（絶対パス）
detect_broken_references() {
  local body="$1"
  local repo_root="$2"
  local result="[]"
  local lineno=0
  local line
  local remaining
  local full_match
  local candidate
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    remaining="$line"
    while [[ "$remaining" =~ \`([^\`]+)\` ]]; do
      candidate="${BASH_REMATCH[1]}"
      full_match="${BASH_REMATCH[0]}"
      # 同上の理由で $full_match をクォートしてリテラル置換を強制する
      # （globメタ文字を含むパス、例: `src/app/[id]/page.tsx` での無限ループ回帰防止）。
      remaining="${remaining/"$full_match"/}"

      # プレースホルダ由来（{...}を含む）は除外
      if [[ "$candidate" == *"{"* || "$candidate" == *"}"* ]]; then
        continue
      fi
      # パスらしくないもの（"/"を含まない、空白を含む）は除外
      if [[ "$candidate" != */* ]]; then
        continue
      fi
      if [[ "$candidate" =~ [[:space:]] ]]; then
        continue
      fi
      # URIスキーム付き文字列（https:, http:, mailto: 等）は相対パス参照ではないため除外。
      # 除外しないと `` `https://example.com/path` `` のようなURIが `/` を含むため
      # <repo_root>/https://... として存在確認され broken_references に誤検出される。
      if [[ "$candidate" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]]; then
        continue
      fi
      # "/" で始まる絶対パスも相対パス参照のファイル存在チェック対象外として除外
      if [[ "$candidate" == /* ]]; then
        continue
      fi

      if [ -f "${repo_root}/${candidate}" ]; then
        continue
      fi

      result=$(jq -c --argjson line "$lineno" --arg path "$candidate" --argjson exists false \
        '. + [{"line": $line, "path": $path, "exists": $exists}]' <<<"$result")
    done
  done <<<"$body"
  BROKEN_REFS_JSON="$result"
}

# 「## 機能要件」「## 受入基準」セクション配下のリスト項目（`- ` 始まり）のうち、
# `- [ ] ` / `- [x] ` / `- [X] ` 形式になっていない行を検出し、
# 結果をグローバル変数 CHECKLIST_ISSUES_JSON に格納する。
# 引数: 本文テキスト
detect_checklist_format_issues() {
  local body="$1"
  local result="[]"
  local lineno=0
  local line
  local section=""
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if [[ "$line" =~ ^##[[:space:]]+(機能要件|受入基準)[[:space:]]*$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      section=""
      continue
    fi
    if [ -n "$section" ] && [[ "$line" =~ ^-[[:space:]] ]]; then
      if ! [[ "$line" =~ ^-\ \[[xX\ ]\][[:space:]] ]]; then
        result=$(jq -c --argjson line "$lineno" --arg section "$section" --arg text "$line" \
          '. + [{"line": $line, "section": $section, "text": $text}]' <<<"$result")
      fi
    fi
  done <<<"$body"
  CHECKLIST_ISSUES_JSON="$result"
}

print_usage() {
  local prog
  prog="$(basename "$0")"
  echo "Usage: ${prog} <spec-file-path>" >&2
}

main() {
  local spec_file="${1:-}"

  if [ -z "$spec_file" ]; then
    print_usage
    exit 1
  fi

  if ! check_jq; then
    exit 1
  fi

  if [ ! -f "$spec_file" ]; then
    echo "Error: spec file not found: ${spec_file}" >&2
    exit 1
  fi

  local body
  body="$(cat "$spec_file")"
  body="${body//$'\r'/}"

  local repo_root
  repo_root="$(resolve_repo_root "$spec_file")"

  detect_ambiguous_words "$body"
  detect_template_placeholders "$body"
  detect_broken_references "$body" "$repo_root"
  detect_checklist_format_issues "$body"

  jq -n \
    --arg spec_file "$spec_file" \
    --argjson ambiguous_words "$AMBIGUOUS_JSON" \
    --argjson template_placeholders "$PLACEHOLDERS_JSON" \
    --argjson broken_references "$BROKEN_REFS_JSON" \
    --argjson checklist_format_issues "$CHECKLIST_ISSUES_JSON" \
    '{
      spec_file: $spec_file,
      ambiguous_words: $ambiguous_words,
      template_placeholders: $template_placeholders,
      broken_references: $broken_references,
      checklist_format_issues: $checklist_format_issues
    }'
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
