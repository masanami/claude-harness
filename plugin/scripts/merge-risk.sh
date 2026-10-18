#!/bin/bash
# merge-risk.sh
# 使い方: merge-risk.sh [--ai-review done|none] [--rules <file>] < <pr-merge-preflight の出力 JSON>
# PR のマージのリスク区分（自動マージ可／人間判断）と根拠（該当したパス・規則・条件）を決定的に判定し、stdout に JSON で1個返す。
# 判定するだけで、マージはしない（マージするかは呼び出し側の承認ルールが決める）。
# 仕様の正本は scripts/specs/merge-risk.md を参照。

set -u

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" || {
  echo "Error: failed to source lib/common.sh" >&2
  exit 2
}

# 終了コード（scripts/specs/merge-risk.md と一致させること）
MERGE_RISK_EX_AUTO=0   # 自動マージ可
MERGE_RISK_EX_HUMAN=1  # 人間判断（stdout には JSON を出す）
MERGE_RISK_EX_PREREQ=2 # 実行前提の欠落（jq 不在・引数不正・入力が JSON でない・規則ファイルの書式誤り）

# リポジトリごとの上書き規則の置き場（リポジトリルートからの相対パス）。
MERGE_RISK_REPO_RULES=".claude/merge-risk-rules.txt"

# 既定規則（正本はここだけ）。1行 = `<区分> <glob>`。上から順に照合し、最初に一致した規則を採る。
# 区分: human = 人間判断 / auto = 自動マージ可 / test = 自動マージ可（ただし削除行を含む変更は人間判断）。
# どの規則にも一致しないパス（プロダクションコード等）は人間判断になる。
# glob は bash の `[[ "$path" == $glob ]]` で照合する（"*" は "/" も含めて任意の文字列に一致する）。
merge_risk_default_rules() {
  cat <<'RULES'
# CI・権限定義・エージェントの規律とプロンプト（実行権限やモデルの振る舞いに直結する）
human .github/*
human .claude/*
human CLAUDE.md
human */CLAUDE.md
human AGENTS.md
human */AGENTS.md
human skills/*
human */skills/*
human agents/*
human */agents/*
human prompts/*
human */prompts/*
# 認証情報・シークレット
human *secret*
human *credential*
human *.pem
human *.key
human *.env
human *.env.*
# スクリプト・ビルド定義（gh 等の権限で外部作用を及ぼしうる）
human *.sh
human scripts/*
human */scripts/*
human bin/*
human */bin/*
human Makefile
human */Makefile
# 契約ファイル（API・メッセージの互換性）
human *.proto
human *openapi*
human *swagger*
human *.graphql
human *.gql
human *.avsc
human contracts/*
human */contracts/*
# DB スキーマ・マイグレーション
human *migrations/*
human *migrate/*
human *.sql
human *schema.prisma
human *db/schema.rb
# インフラ
human *.tf
human *.tfvars
human *.hcl
human terraform/*
human */terraform/*
human infra/*
human */infra/*
human k8s/*
human */k8s/*
human helm/*
human */helm/*
human *Dockerfile*
human *docker-compose*
# テスト（追加だけなら自動マージ可。既存行を消す変更はテストを弱めうるので人間判断）
test *_test.go
test *.test.*
test *.spec.*
test *_spec.rb
test test_*.py
test */test_*.py
test *_test.py
test test/*
test */test/*
test tests/*
test */tests/*
test *__tests__/*
test spec/*
test */spec/*
test e2e/*
test */e2e/*
test *testdata/*
# ドキュメント
auto docs/*
auto */docs/*
auto *.md
auto *.mdx
auto *.rst
auto *.adoc
RULES
}

# ---------------------------------------------------------------------------
# 純粋関数（gh・git を呼ばない。source して直接テスト可能）
# ---------------------------------------------------------------------------

# 規則テキストを検証し、`<区分>\t<glob>\t<source>\t<行番号>` の行へ正規化する。
# 空行と "#" 始まりの行は無視する。書式誤り（区分が未知・glob が無い・余分なトークン）は stderr に行番号を出して非0 を返す
# （読めない規則を黙って捨てると、人間判断にすべきパスが自動マージ可に倒れうるため）。
# 引数: <規則テキスト> <source（default | repo）> [<表示用のファイル名>]
merge_risk_parse_rules() {
  local text="$1" source="$2" label="${3:-$2}"
  local line lineno=0 class glob extra
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r class glob extra <<<"$line"
    case "$class" in
      human | auto | test) ;;
      *)
        echo "Error: ${label}:${lineno}: unknown class '${class}' (expected human | auto | test)" >&2
        return 1
        ;;
    esac
    if [ -z "${glob:-}" ] || [ -n "${extra:-}" ]; then
      echo "Error: ${label}:${lineno}: expected '<class> <glob>' (one glob per line, no spaces in the glob)" >&2
      return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$class" "$glob" "$source" "$lineno"
  done <<<"$text"
  return 0
}

# パス 1 つを規則（merge_risk_parse_rules の出力。先頭ほど優先）と照合し、最初に一致した規則を
# `<区分>\t<glob>\t<source>` で返す。どれにも一致しなければ何も出さない。
merge_risk_match() {
  local path="$1" rules="$2" class glob source lineno
  while IFS=$'\t' read -r class glob source lineno; do
    [ -z "$class" ] && continue
    # shellcheck disable=SC2053
    if [[ "$path" == $glob ]]; then
      printf '%s\t%s\t%s' "$class" "$glob" "$source"
      return 0
    fi
  done <<<"$rules"
  return 0
}

# 変更ファイル（preflight の files: [{path, previous_path, status, additions, deletions}]）を規則で分類し、
# ファイルごとの判定を JSON 配列で返す。各要素:
#   {path, previous_path, status, deletions, verdict: "auto"|"human", class, rule, source, code}
#   class・rule・source は path が一致した規則（無ければ null）。code は human にした理由（auto なら null）。
# human にする理由は上から順に1つ:
#   rules_file_changed     規則ファイル自体の変更（上書き規則でも auto にできない。PR が自分を判定する規則を書き換えられないように）
#   path_unmatched / path_human / test_lines_deleted   path の規則による判定
#   previous_path_not_auto リネーム前のパスが auto の規則に一致しない（human やテストのファイルを docs/ へ移す変更を見逃さないため）
merge_risk_classify_files() {
  local files_json="$1" rules="$2"
  local i path prev deletions ctrl m class glob source code pm pclass rows=""
  # 判定の材料だけを bash へ渡し、判定結果は添字で元の配列へ戻す（パスを区切り文字の列へ通さない）。
  # 区切りは US（0x1f）。制御文字（タブ・改行等）を含むパスは列をずらしうるので、照合せず人間判断にする。
  while IFS=$'\x1f' read -r i path prev deletions ctrl; do
    [ -z "$i" ] && continue
    class="" glob="" source="" code=""
    if [ "$ctrl" = "1" ]; then
      code="path_unmatched"
    else
      m="$(merge_risk_match "$path" "$rules")"
      [ -n "$m" ] && IFS=$'\t' read -r class glob source <<<"$m"
      if [ "$path" = "$MERGE_RISK_REPO_RULES" ] || [ "$prev" = "$MERGE_RISK_REPO_RULES" ]; then
        code="rules_file_changed"
      elif [ -z "$class" ]; then
        code="path_unmatched"
      elif [ "$class" = "human" ]; then
        code="path_human"
      elif [ "$class" = "test" ] && [ "$deletions" -ne 0 ]; then
        code="test_lines_deleted"
      elif [ -n "$prev" ] && [ "$prev" != "$path" ]; then
        pm="$(merge_risk_match "$prev" "$rules")"
        pclass="${pm%%$'\t'*}"
        [ "$pclass" = "auto" ] || code="previous_path_not_auto"
      fi
    fi
    rows+="${i}"$'\t'"${class}"$'\t'"${glob}"$'\t'"${source}"$'\t'"${code}"$'\n'
  done < <(jq -r 'to_entries[] | .key as $i | .value
    | [($i | tostring), .path, (.previous_path // ""), ((.deletions // 0) | tostring),
       (if ((.path + (.previous_path // "")) | test("[[:cntrl:]]")) then "1" else "0" end)]
    | map(gsub("[[:cntrl:]]"; "?")) | join("\u001f")' <<<"$files_json")
  # 上の jq が失敗しても while の終了状態には出ない。取りこぼしは次の jq の件数照合（error）で失敗させる。
  # 1 回の jq で元の配列へ戻す（ファイルごとに jq を起動して配列を作り直さない）。
  printf '%s' "$rows" | jq -Rsc --argjson files "$files_json" '
    def nz: if . == "" then null else . end;
    [ split("\n")[] | select(length > 0) | split("\t") ] as $rows
    | [ $rows[] | (.[0] | tonumber) as $i | $files[$i] as $f
        | {path: $f.path, previous_path: ($f.previous_path // null), status: ($f.status // null), deletions: ($f.deletions // 0),
           verdict: (if .[4] == "" then "auto" else "human" end),
           class: (.[1] | nz), rule: (.[2] | nz), source: (.[3] | nz), code: (.[4] | nz)} ]
    | if length == ($files | length) then . else error("classified \(length) of \($files | length) files") end'
}

# 判定式。preflight の出力・ファイルごとの判定・AI レビューの実施有無から、区分と根拠を組み立てる。
# 自動マージ可になる条件の正本は scripts/specs/merge-risk.md「判定」。
# 引数: <preflight JSON> <files 判定 JSON（files が null なら null）> <ai_review: done|none> <使った規則の出所（無ければ空）>
merge_risk_decide() {
  local preflight="$1" file_verdicts="$2" ai_review="$3" repo_file="$4"
  jq -c --argjson files "$file_verdicts" --arg ai_review "$ai_review" --arg repo_file "$repo_file" '
    def detail_of($code):
      { rules_file_changed: "規則ファイル（.claude/merge-risk-rules.txt）自体の変更",
        path_unmatched: "どの規則にも一致しない（プロダクションコード等）",
        path_human: "人間判断の規則に一致",
        test_lines_deleted: "テストの既存行を消している（テストを弱めうる）",
        previous_path_not_auto: "リネーム前のパスが自動マージ可の規則に一致しない" }[$code];
    . as $p
    | ($files // []) as $fs
    | ($p.ci.status // "none") as $ci
    | (($p.reviews // []) | length) as $reviews
    | ($p.risk.files_changed // ($fs | length)) as $changed
    | ([ $fs[] | select(.verdict == "human")
         | {code, path, detail: detail_of(.code)} + (if .rule != null then {rule, source} else {} end)
         + (if .previous_path != null then {previous_path} else {} end) ]) as $path_reasons
    | ( if $files == null then [{code: "files_unavailable", detail: "変更ファイルの一覧を取得できなかった"}]
        elif ($fs | length) == 0 then [{code: "no_files", detail: "変更ファイルが無い（判定の材料が無い）"}]
        elif ($fs | length) < $changed then [{code: "files_truncated", detail: "変更ファイルを取り切れていない（\($changed) 件中 \($fs | length) 件）"}]
        else [] end ) as $files_reasons
    | ( if ($p.risk.touches_sensitive // false) == true
        then [{code: "touches_sensitive", detail: "preflight が sensitive パスへの変更を検出した（上書き規則では外せない）"}] else [] end ) as $sensitive_reasons
    | ( if $ci == "pass" then [] else [{code: "quality_gate_not_passed", detail: "品質ゲート（CI）が pass ではない: \($ci)"}] end ) as $qg_reasons
    | ( if ($reviews + (if $ai_review == "done" then 1 else 0 end)) > 0 then []
        else [{code: "no_review", detail: "レビューが1件も無い（PR のレビュー 0 件・AI レビュー未実施）"}] end ) as $review_reasons
    | ( if ($p.blocking // false) == true then [{code: "blocking", detail: "preflight が blocking: \(($p.block_reasons // []) | join(", "))"}] else [] end ) as $blocking_reasons
    | ($files_reasons + $path_reasons + $sensitive_reasons + $qg_reasons + $review_reasons + $blocking_reasons) as $reasons
    | (($reasons | length) == 0) as $auto
    | (if $auto then "自動マージ可" else "人間判断" end) as $lbl
    | {
        paths: {ok: ((($files_reasons + $path_reasons + $sensitive_reasons) | length) == 0), files_changed: $changed, files_classified: ($fs | length)},
        quality_gate: {ok: (($qg_reasons | length) == 0), ci_status: $ci},
        review: {ok: (($review_reasons | length) == 0), pr_reviews: $reviews, ai_review: $ai_review},
        blocking: {ok: (($blocking_reasons | length) == 0), block_reasons: ($p.block_reasons // [])}
      } as $conditions
    # PR に残すコメントの本文。呼び出し側はこれをそのまま投稿する（LLM が書き直すと件数への丸め・取りこぼしが起きうる）。
    | def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
      def mark: if . then "✅" else "❌" end;
      ( [ "## マージのリスク分類: \($lbl)", "",
          "| 条件 | 結果 |", "|---|---|",
          "| 変更パス | \($conditions.paths.ok | mark)（\($conditions.paths.files_classified) / \($conditions.paths.files_changed) 件を判定） |",
          "| 品質ゲート（CI） | \($conditions.quality_gate.ok | mark)（\($ci)） |",
          "| レビュー | \($conditions.review.ok | mark)（PR のレビュー \($reviews) 件・AI レビュー \($ai_review)） |",
          "| blocking | \($conditions.blocking.ok | mark) |", "" ]
        + if $auto then
            [ "### 根拠（全 \($fs | length) 件のファイルが自動マージ可の規則に一致）", "",
              "| パス | 規則 | 出所 |", "|---|---|---|" ]
            + [ $fs[] | "| `\(.path | cell)` | `\(.rule | cell)` | \(.source) |" ]
          else
            [ "### 人間判断の理由（全 \($reasons | length) 件）", "",
              "| 理由 | パス | 規則 | 内容 |", "|---|---|---|---|" ]
            + [ $reasons[] | "| `\(.code)` | \(if .path then "`\(.path | cell)`" else "" end) | \(if .rule then "`\(.rule | cell)`（\(.source)）" else "" end) | \(.detail | cell) |" ]
          end
        + [ "", "規則: \(if $repo_file == "" then "既定規則のみ" else "`\($repo_file)` と既定規則" end)。この判定はマージを実行しない（マージの承認は別に行う）。" ]
        | join("\n") ) as $comment
    | {
        status: "ok",
        classification: (if $auto then "auto_merge_ok" else "human_judgment" end),
        label: $lbl,
        reasons: $reasons,
        conditions: $conditions,
        files: $files,
        rules: {repo_file: (if $repo_file == "" then null else $repo_file end)},
        comment_markdown: $comment
      }' <<<"$preflight"
}

# ---------------------------------------------------------------------------
# 入出力
# ---------------------------------------------------------------------------

print_usage() {
  local prog
  prog="$(basename "$0")"
  cat >&2 <<EOF
Usage: ${prog} [--ai-review done|none] [--rules <file>] < <pr-merge-preflight の出力 JSON>

  --ai-review  呼び出し側が AI レビューを実施したか（既定: none）
  --rules      上書き規則のファイル（既定: origin/<base> の ${MERGE_RISK_REPO_RULES}。無ければ既定規則だけ）
  exit code: ${MERGE_RISK_EX_AUTO}=自動マージ可 / ${MERGE_RISK_EX_HUMAN}=人間判断 / ${MERGE_RISK_EX_PREREQ}=実行前提の欠落
EOF
}

prereq_error() {
  echo "Error: $1" >&2
  jq -nc --arg e "$1" '{status: "error", error: $e}' >&2 2>/dev/null || true
  exit "$MERGE_RISK_EX_PREREQ"
}

main() {
  local ai_review="none" rules_file="" rules_given=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        print_usage
        exit 0
        ;;
      --ai-review)
        [ "$#" -ge 2 ] || prereq_error "--ai-review requires a value"
        ai_review="$2"
        shift 2
        ;;
      --rules)
        [ "$#" -ge 2 ] || prereq_error "--rules requires a value"
        rules_file="$2"
        rules_given=1
        shift 2
        ;;
      *)
        print_usage
        prereq_error "unknown argument: $1"
        ;;
    esac
  done
  case "$ai_review" in
    done | none) ;;
    *) prereq_error "--ai-review must be done or none, got '${ai_review}'" ;;
  esac

  if ! check_jq '{"status":"error","error":"jq not found"}'; then
    exit "$MERGE_RISK_EX_PREREQ"
  fi

  local preflight
  preflight="$(cat)"
  if ! jq -e 'type == "object" and ((.files | type) == "array" or (has("files") and .files == null))' <<<"$preflight" >/dev/null 2>&1; then
    prereq_error "stdin must be the JSON object printed by pr-merge-preflight (with a files array, or files: null)"
  fi

  # リポジトリの規則は PR の base ブランチ（origin/<base>）の版を読む。作業ツリーの版を読むと、
  # PR のブランチを checkout しているとき PR が自分を判定する規則を書き換えられるため。
  local rules_text="" rules_label=""
  if [ "$rules_given" -eq 1 ]; then
    if [ ! -f "$rules_file" ] || [ ! -r "$rules_file" ]; then
      prereq_error "rules file not readable: ${rules_file}"
    fi
    rules_text="$(cat "$rules_file")" || prereq_error "failed to read rules file: ${rules_file}"
    rules_label="$rules_file"
  else
    local base ref
    base="$(jq -r '.base // empty' <<<"$preflight")"
    [ -n "$base" ] || prereq_error "stdin has no base (needed to read ${MERGE_RISK_REPO_RULES} from the base branch)"
    ref="origin/${base}"
    git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 ||
      prereq_error "cannot resolve ${ref} in the current repository (run git fetch origin ${base})"
    if git cat-file -e "${ref}:${MERGE_RISK_REPO_RULES}" 2>/dev/null; then
      rules_text="$(git show "${ref}:${MERGE_RISK_REPO_RULES}")" || prereq_error "failed to read ${ref}:${MERGE_RISK_REPO_RULES}"
      rules_label="${ref}:${MERGE_RISK_REPO_RULES}"
    fi
  fi

  local repo_rules="" default_rules
  if [ -n "$rules_label" ]; then
    # CRLF の規則ファイルでも glob の末尾に \r を残さない（一致しない規則を黙って作らない）。
    repo_rules="$(merge_risk_parse_rules "${rules_text//$'\r'/}" repo "$rules_label")" || exit "$MERGE_RISK_EX_PREREQ"
  fi
  default_rules="$(merge_risk_parse_rules "$(merge_risk_default_rules)" default)" || exit "$MERGE_RISK_EX_PREREQ"

  # リポジトリの規則を既定規則より先に照合する（最初に一致した規則を採るので、上書きになる）。
  local rules file_verdicts="null" result
  rules="$(printf '%s\n%s' "$repo_rules" "$default_rules")"
  if [ "$(jq -r '.files | type' <<<"$preflight")" = "array" ]; then
    file_verdicts="$(merge_risk_classify_files "$(jq -c '.files' <<<"$preflight")" "$rules")" ||
      prereq_error "failed to classify the changed files"
  fi
  # 判定に失敗したら exit 2（exit 1 は「人間判断の JSON を出した」の意味なので、空の出力で 1 を返さない）。
  result="$(merge_risk_decide "$preflight" "$file_verdicts" "$ai_review" "$rules_label")" && [ -n "$result" ] ||
    prereq_error "failed to build the classification"
  printf '%s\n' "$result"
  if [ "$(jq -r '.classification' <<<"$result")" = "auto_merge_ok" ]; then
    exit "$MERGE_RISK_EX_AUTO"
  fi
  exit "$MERGE_RISK_EX_HUMAN"
}

# `source` された場合は main を実行しない（テストからの関数直接呼び出しを可能にするため）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
