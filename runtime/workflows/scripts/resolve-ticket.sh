#!/bin/bash
# resolve-ticket.sh [--issue <番号>] [--base <ブランチ>] [--task_file <絶対パス>] [--task_id T-<番号>] [--uses_integration true|false]
#
# ticket ワークフローの最初のステップ（docs/harness-runtime-design.md §3.3・§3.4・§5.6.2。/impl の「base の決定」I2・I3 を切り出したもの）。
#   0. 入力どうしの条件を確かめる（YAML の文法は持たない。§3.1）。満たさなければ input_invalid、uses_integration が true なら
#      integration_unsupported（gh・git は呼ばない）
#   1. gh issue view で Issue を読む（--issue があるときだけ）
#   2. base を決める: --base ＞ Issue 本文の `Base:` 行（--task_file が無いときだけ） ＞ リポジトリの既定ブランチ
#   3. base が既定ブランチ以外（統合ブランチ）なら、remote（origin）に在るかを確かめる
#   4. PR 本文に書く Issue 参照を決める（#305）: Issue 本文の `Refs: #N[, #M]` 行を refs に、`Closes: なし` 行があれば
#      closes を 0（closing キーワードを書かない）にする。どちらの行も無ければ closes は Issue 自身、refs は空（従来どおり）
#
# stdout に JSON を 1 つ出す（schemas/resolve-ticket.json）。outcome は ok | base_missing | links_invalid | input_invalid |
# integration_unsupported。key は名前の鍵（task-<n> か issue-<n>。作業ツリーの場所とブランチの名前に使う）、scope は作業の範囲の正本
# （task_file があれば task_file、無ければ issue）。--task_file があるときは、文面のファイルが範囲の正本で、Issue は PR が閉じる
# 対象としてだけ読む（Refs:・Closes: 行だけ。Base: 行は読まない）。文面のファイルは解釈せず、在ることだけを確かめる。
#   input_invalid: 入力の組み合わせ・形が誤り（issue も task_file も無い／task_file が絶対パスでない・読めない／task_id が T-<1 以上の整数>
#     でない／issue も task_id も無い／uses_integration が true・false 以外）
#   integration_unsupported: uses_integration が true（統合先を作る道はまだ無い）
#   base_missing: 統合ブランチが remote に無い・Base 行の値がブランチ名として不正・Base 行が食い違う。message に作り方を載せる
#   links_invalid: Refs: 行に #<番号> 以外の値がある・Closes: 行の値が「なし」以外。message に直し方を載せる
# gh・git の失敗（ネットワーク・認証・Issue が無い）は stderr に理由を出して非 0 で終わる（runtime は step_error にする）。
# gh と git は PATH のものを使う。

set -u

issue=""
issue_given=false
base_in=""
base_given=false
task_file=""
task_id=""
uses_integration=""
usage="usage: resolve-ticket.sh [--issue <number>] [--base <branch>] [--task_file <absolute path>] [--task_id T-<number>] [--uses_integration true|false]"
while [ $# -gt 0 ]; do
  case "$1" in
    --issue|--base|--task_file|--task_id|--uses_integration)
      if [ $# -lt 2 ]; then echo "Error: $1 needs a value ($usage)" >&2; exit 2; fi
      case "$1" in
        --issue) issue="$2"; issue_given=true ;;
        --base) base_in="$2"; base_given=true ;;
        --task_file) task_file="$2" ;;
        --task_id) task_id="$2" ;;
        --uses_integration) uses_integration="$2" ;;
      esac
      shift 2 ;;
    *) echo "Error: unknown argument '$1' ($usage)" >&2; exit 2 ;;
  esac
done

if [ "$issue_given" = true ] && ! [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --issue must be a positive integer, got '${issue}'" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but was not found in PATH" >&2
  exit 1
fi
[ "$issue_given" = true ] || issue=0

# 名前の鍵と作業の範囲の正本。key は入力が正しいときだけ意味を持つ（誤りのときは空文字）。
key=""
scope="issue"
task_dir=""
if [ -n "$task_file" ]; then
  scope="task_file"
  task_dir="$(dirname -- "$task_file")" # 文面のファイルのあるフォルダ。LLM の段に --add-dir で渡す（作業ツリーの外でも読めるように。§5.6.2）
fi

# emit_early は gh・git を呼ばずに出す出力（input_invalid・integration_unsupported）。
emit_early() {
  jq -n \
    --arg outcome "$1" \
    --arg message "$2" \
    --argjson issue "$issue" \
    --arg key "$key" \
    --arg task_file "$task_file" \
    --arg scope "$scope" \
    --arg task_dir "$task_dir" \
    '{outcome: $outcome, issue: $issue, key: $key, task_file: $task_file, task_dir: $task_dir, scope: $scope, title: "", state: "", base: "",
      base_kind: "default", base_source: "default", default_branch: "", closes: 0, refs: [], message: $message}'
  exit 0
}

# 入力どうしの条件（docs/harness-runtime-design.md §5.6.2）。上から順に、最初に当たったものを返す。
if [ "$issue_given" != true ] && [ -z "$task_file" ]; then
  emit_early input_invalid "issue も task_file も無い。作業の範囲を決める入力（issue か task_file）の少なくとも片方を渡してから再実行する"
fi
if [ -n "$task_file" ]; then
  if [[ "$task_file" != /* ]]; then
    emit_early input_invalid "task_file '${task_file}' は絶対パスでない。タスクの文面のファイルは絶対パスで渡してから再実行する"
  fi
  if [ ! -f "$task_file" ] || [ ! -r "$task_file" ]; then
    emit_early input_invalid "task_file '${task_file}' は読めるファイルでない（無い・ディレクトリ・読み取り権限が無い）。直してから再実行する"
  fi
fi
if [ -n "$task_id" ] && ! [[ "$task_id" =~ ^T-[1-9][0-9]*$ ]]; then
  emit_early input_invalid "task_id '${task_id}' は T-<1 以上の整数>（例: T-12）の形でない。直してから再実行する"
fi
if [ "$issue_given" != true ] && [ -z "$task_id" ]; then
  emit_early input_invalid "issue も task_id も無く、作業ツリーとブランチの名前の鍵を決められない。issue か task_id を渡してから再実行する"
fi
case "$uses_integration" in
  ""|true|false) ;;
  *) emit_early input_invalid "uses_integration '${uses_integration}' は true・false のどちらでもない。直してから再実行する" ;;
esac
if [ -n "$task_id" ]; then key="task-${task_id#T-}"; else key="issue-${issue}"; fi
if [ "$uses_integration" = true ]; then
  emit_early integration_unsupported "uses_integration が true だが、統合先を作る道はまだ無い（この版では扱えない）。uses_integration を外して再実行する"
fi

# valid_branch はブランチ名として受け付ける形か（空白・制御文字・`..`・先頭の `-`・末尾の `/` や `.lock` を拒否する）。
valid_branch() {
  local b="$1"
  [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$b" == -* || "$b" == */ || "$b" == *..* || "$b" == *.lock || "$b" == /* ]] && return 1
  return 0
}

# key_lines は本文から `<key> <値>` 行の値を列挙する（key は awk の正規表現。例: `Base:`）。HTML コメントとコードブロック
# 〔``` / ~~~〕の中は読まない。前後の空白と ` を除く。
key_lines() {
  tr -d '\r' | awk -v key="$1" '
    {
      line = $0
      out = ""
      while (length(line) > 0) {
        if (incomment) {
          i = index(line, "-->")
          if (i == 0) { line = ""; break }
          line = substr(line, i + 3); incomment = 0
        } else {
          i = index(line, "<!--")
          if (i == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, i - 1); line = substr(line, i + 4); incomment = 1
        }
      }
      if (!incomment && out ~ /^[ \t]*(```|~~~)/) { infence = !infence; next }
      if (infence) next
      if (out ~ ("^[ \t]*" key)) {
        sub("^[ \t]*" key "[ \t]*", "", out)
        sub(/[ \t]+$/, "", out)
        gsub(/`/, "", out)
        print out
      }
    }'
}

title=""
state=""
body=""
if [ "$issue_given" = true ]; then
  if ! view="$(gh issue view "$issue" --json number,title,body,state)"; then
    echo "Error: gh issue view ${issue} failed" >&2
    exit 1
  fi
  title="$(jq -r '.title // ""' <<<"$view")"
  state="$(jq -r '.state // ""' <<<"$view")"
  body="$(jq -r '.body // ""' <<<"$view")"
fi

if ! default_branch="$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')" || [ -z "$default_branch" ]; then
  echo "Error: cannot read the repository's default branch (gh repo view)" >&2
  exit 1
fi

outcome="ok"
message=""
if [ "$base_given" = true ]; then
  base="$base_in"
  source="input"
elif [ -n "$task_file" ]; then
  # 文面のファイルがあるときは Base: 行を読まない（宛先は base の入力か既定ブランチ。統合先は uses_integration で決める）
  base="$default_branch"
  source="default"
else
  lines="$(printf '%s\n' "$body" | key_lines 'Base:' | awk 'NF' | sort -u)"
  count="$(printf '%s' "$lines" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    base="$default_branch"
    source="default"
  else
    base="$(printf '%s\n' "$lines" | head -n 1)"
    source="issue"
    if [ "$count" -gt 1 ]; then
      outcome="base_missing"
      message="Issue #${issue} の本文に値の異なる Base: 行が ${count} 個ある（$(printf '%s' "$lines" | tr '\n' ' ')）。どれが base かを決められないので止まる。Base: 行を 1 つにしてから再実行する"
    fi
  fi
fi

if [ "$outcome" = "ok" ] && ! valid_branch "$base"; then
  outcome="base_missing"
  message="base '${base}'（${source}）はブランチ名として受け付けられない。Issue の Base: 行か --base を直してから再実行する"
fi

if [ "$base" = "$default_branch" ]; then
  base_kind="default"
else
  base_kind="integration"
fi

if [ "$outcome" = "ok" ] && [ "$base_kind" = "integration" ]; then
  # パターンは refs/heads/<base> で完全に指す（ls-remote は末尾一致なので、素の <base> だと feature/<base> にも一致する）。
  git ls-remote --exit-code --heads origin "refs/heads/${base}" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) ;;
    2)
      outcome="base_missing"
      message="統合ブランチ ${base} が remote（origin）に存在しない。先に作成してから再実行する: git checkout -b ${base} origin/${default_branch} && git push -u origin ${base}"
      ;;
    *)
      echo "Error: git ls-remote origin ${base} failed (exit ${rc})" >&2
      exit 1
      ;;
  esac
fi

# Issue 参照（#305）。Refs: 行・Closes: 行は Base: 行と同じ読み方をする（コロンは全角も受ける）。Refs: 行が複数あれば
# 和をとる（並びは初出順・重複は除く）。Closes: 行は値が「なし」（無し・none も同じ）のものだけを受け、ほかの値は止める。
closes="$issue"
refs=()
links_msg=""
while IFS= read -r v; do
  read -r -a toks <<<"$(printf '%s' "$v" | sed -e 's/、/ /g' -e 's/，/ /g' -e 's/,/ /g' -e 's/　/ /g')"
  for tok in ${toks[@]+"${toks[@]}"}; do
    if [[ "$tok" =~ ^#([1-9][0-9]*)$ ]]; then
      n="${BASH_REMATCH[1]}"
      dup=false
      for r in ${refs[@]+"${refs[@]}"}; do [ "$r" = "$n" ] && dup=true; done
      [ "$dup" = true ] || refs+=("$n")
    else
      links_msg="Issue #${issue} の本文の Refs: 行に Issue 番号として読めない値 '${tok}' がある。Refs: 行は「Refs: #12, #34」の形（#<番号> をカンマか空白で区切る。他リポジトリの参照・注記は書けない）に直してから再実行する"
      break 2
    fi
  done
done < <(printf '%s\n' "$body" | key_lines 'Refs(:|：)' | awk 'NF')
if [ -z "$links_msg" ]; then
  while IFS= read -r v; do
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
      なし|無し|none) closes=0 ;;
      *)
        links_msg="Issue #${issue} の本文の Closes: 行の値 '${v}' は受け付けない（受け付けるのは「Closes: なし」だけ。PR 本文は既定で Closes #${issue} を書く）。行を消すか「Closes: なし」に直してから再実行する"
        break ;;
    esac
  done < <(printf '%s\n' "$body" | key_lines 'Closes(:|：)' | awk 'NF' | sort -u)
fi
if [ -n "$links_msg" ] && [ "$outcome" = "ok" ]; then
  outcome="links_invalid"
  message="$links_msg"
fi
refs_json='[]'
for r in ${refs[@]+"${refs[@]}"}; do
  [ "$r" = "$closes" ] && continue # Closes する Issue を Refs にも重ねて書かない
  refs_json="$(jq -c --argjson n "$r" '. + [$n]' <<<"$refs_json")"
done

jq -n \
  --arg outcome "$outcome" \
  --argjson issue "$issue" \
  --arg key "$key" \
  --arg task_file "$task_file" \
  --arg scope "$scope" \
  --arg task_dir "$task_dir" \
  --arg title "$title" \
  --arg state "$state" \
  --arg base "$base" \
  --arg base_kind "$base_kind" \
  --arg base_source "$source" \
  --arg default_branch "$default_branch" \
  --argjson closes "$closes" \
  --argjson refs "$refs_json" \
  --arg message "$message" \
  '{outcome: $outcome, issue: $issue, key: $key, task_file: $task_file, task_dir: $task_dir, scope: $scope, title: $title, state: $state, base: $base, base_kind: $base_kind,
    base_source: $base_source, default_branch: $default_branch, closes: $closes, refs: $refs, message: $message}'
