#!/bin/bash
# test-merge-risk.sh
# scripts/merge-risk.sh（マージのリスク分類）の判定を gh 非依存で固定する。
#
#  (1) 既定規則の分類表: 代表的なパスが想定の区分（auto / test / human / 未分類）に落ちること
#  (2) 判定式の真理値表: 自動マージ可の基準ケースから条件を1つずつ崩すと、必ず人間判断になり、崩した条件の理由コードが出ること
#  (3) リポジトリごとの上書き: 規則ファイルが既定より先に照合されること・既定の置き場から自動で読まれること
#  (4) 契約: exit code と classification が一致すること・前提の欠落は exit 2 になること
#  (5) 語彙の一致: spec の理由コード表とスクリプトが出しうるコードが一致すること
#
# 実行方法: bash scripts/tests/test-merge-risk.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

MR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MR_REPO_ROOT="$(cd "${MR_TEST_DIR}/../.." && pwd)"
TARGET_SCRIPT="${MR_REPO_ROOT}/scripts/merge-risk.sh"
SPEC_FILE="${MR_REPO_ROOT}/scripts/specs/merge-risk.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "NG - jq が見つからないためテストを実行できません（検査不能を pass にはしない）" >&2
  exit 1
fi
if [ ! -r "$SPEC_FILE" ]; then
  echo "NG - spec を読めません（検査不能を pass にはしない）: ${SPEC_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-merge-risk.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# 規則ファイルを持たない base（origin/main）だけがある一時リポジトリ。既定規則だけの判定はここを cwd にして走らせる。
new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
}
MR_CWD="${WORK_DIR}/plain"
new_repo "$MR_CWD"
mr() { (cd "$MR_CWD" && bash "$TARGET_SCRIPT" "$@"); }

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       expected: ${expected}"
    echo "       actual:   ${actual}"
  fi
}

# 既定規則だけで 1 ファイルを分類し、"<verdict> <class>" を返す（未分類の class は null）。
classify_one() {
  local path="$1" deletions="${2:-0}" rules
  rules="$(merge_risk_parse_rules "$(merge_risk_default_rules)" default)"
  merge_risk_classify_files "$(jq -nc --arg p "$path" --argjson d "$deletions" '[{path: $p, previous_path: null, status: "modified", additions: 1, deletions: $d}]')" "$rules" |
    jq -r '.[0] | "\(.verdict) \(.class)"'
}

# スクリプトを実行し、"<exit code> <classification> <理由コードの並び>" を返す。
run_mr() {
  local input="$1"
  shift
  local out code
  out="$(printf '%s' "$input" | mr "$@" 2>/dev/null)"
  code=$?
  printf '%s %s %s' "$code" "$(jq -r '.classification // "-"' <<<"$out" 2>/dev/null)" \
    "$(jq -r '[.reasons[]?.code] | join(",")' <<<"$out" 2>/dev/null)"
}

# 自動マージ可の基準ケース（docs の変更とテストの追加だけ・CI pass・レビュー 1 件・blocking なし）。
BASE='{"base":"main","ci":{"status":"pass"},"reviews":[{"author":"bot","state":"COMMENTED"}],"blocking":false,"block_reasons":[],
"risk":{"files_changed":2,"touches_sensitive":false},
"files":[{"path":"docs/guide.md","additions":3,"deletions":2},{"path":"src/widget_test.go","additions":10,"deletions":0}]}'

echo "=== (1) 既定規則の分類表 ==="
assert_eq "docs 配下 -> auto" "auto auto" "$(classify_one docs/guide.md 5)"
assert_eq "README.md -> auto" "auto auto" "$(classify_one README.md 5)"
assert_eq "テストの追加だけ -> auto（test）" "auto test" "$(classify_one src/widget_test.go 0)"
assert_eq "テストの既存行を消す -> human（test）" "human test" "$(classify_one src/widget_test.go 1)"
assert_eq "tests/ 配下の追加 -> auto（test）" "auto test" "$(classify_one app/tests/test_x.py 0)"
assert_eq "latest/ のような部分一致を tests と誤認しない" "human null" "$(classify_one src/latest/x.go 0)"
assert_eq "プロダクションコード -> 未分類（human）" "human null" "$(classify_one src/app.ts 0)"
assert_eq "スクリプト -> human" "human human" "$(classify_one scripts/deploy.sh 0)"
assert_eq "テスト配下でもスクリプトは human（human が test より先）" "human human" "$(classify_one plugin/scripts/tests/test-x.sh 0)"
assert_eq "権限定義 .claude/settings.json -> human" "human human" "$(classify_one .claude/settings.json 0)"
assert_eq "CLAUDE.md は *.md より先に human" "human human" "$(classify_one CLAUDE.md 0)"
assert_eq "サブディレクトリの CLAUDE.md -> human" "human human" "$(classify_one pkg/CLAUDE.md 0)"
assert_eq "CI ワークフロー -> human" "human human" "$(classify_one .github/workflows/ci.yml 0)"
assert_eq "契約ファイル（proto） -> human" "human human" "$(classify_one api/v1/widget.proto 0)"
assert_eq "契約ファイル（OpenAPI） -> human" "human human" "$(classify_one api/openapi.yaml 0)"
assert_eq "DB マイグレーション -> human" "human human" "$(classify_one db/migrations/001_init.rb 0)"
assert_eq "DB スキーマ（prisma） -> human" "human human" "$(classify_one prisma/schema.prisma 0)"
assert_eq "インフラ（Terraform） -> human" "human human" "$(classify_one infra/main.tf 0)"
assert_eq "インフラ（Dockerfile） -> human" "human human" "$(classify_one Dockerfile 0)"
assert_eq "シークレット -> human" "human human" "$(classify_one config/.env 0)"
assert_eq "スキル定義（モデルが読むプロンプト）は *.md より先に human" "human human" "$(classify_one plugin/skills/pr-merge/SKILL.md 0)"
assert_eq "エージェント定義 -> human" "human human" "$(classify_one plugin/agents/code-reviewer.md 0)"
assert_eq "runtime のプロンプト -> human" "human human" "$(classify_one runtime/workflows/prompts/ticket-implement.md 0)"

echo "=== (2) 判定式の真理値表 ==="
assert_eq "基準ケース -> 自動マージ可（exit 0・理由なし）" "0 auto_merge_ok " "$(run_mr "$BASE")"
assert_eq "PR のレビュー 0 件でも AI レビュー実施なら自動マージ可" "0 auto_merge_ok " \
  "$(run_mr "$(jq -c '.reviews = []' <<<"$BASE")" --ai-review done)"
assert_eq "レビューゼロ（PR 0 件・AI レビュー未指定）-> 人間判断 no_review" "1 human_judgment no_review" \
  "$(run_mr "$(jq -c '.reviews = []' <<<"$BASE")")"
assert_eq "レビューゼロ（--ai-review none）-> 人間判断 no_review" "1 human_judgment no_review" \
  "$(run_mr "$(jq -c '.reviews = []' <<<"$BASE")" --ai-review none)"
for ci in fail pending none; do
  assert_eq "CI ${ci} -> 人間判断 quality_gate_not_passed" "1 human_judgment quality_gate_not_passed" \
    "$(run_mr "$(jq -c --arg c "$ci" '.ci.status = $c' <<<"$BASE")")"
done
assert_eq "blocking -> 人間判断 blocking" "1 human_judgment blocking" \
  "$(run_mr "$(jq -c '.blocking = true | .block_reasons = ["conflicting"]' <<<"$BASE")")"
assert_eq "人間判断の規則に一致するパス -> path_human" "1 human_judgment path_human" \
  "$(run_mr "$(jq -c '.files += [{path: "db/migrations/2.sql", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")")"
assert_eq "未分類のパス -> path_unmatched" "1 human_judgment path_unmatched" \
  "$(run_mr "$(jq -c '.files += [{path: "src/app.ts", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")")"
assert_eq "テストの既存行を消す -> test_lines_deleted" "1 human_judgment test_lines_deleted" \
  "$(run_mr "$(jq -c '.files[1].deletions = 4' <<<"$BASE")")"
assert_eq "変更ファイル 0 件 -> no_files（空虚に自動マージ可にしない）" "1 human_judgment no_files" \
  "$(run_mr "$(jq -c '.files = [] | .risk.files_changed = 0' <<<"$BASE")")"
assert_eq "変更ファイルを取り切れていない -> files_truncated" "1 human_judgment files_truncated" \
  "$(run_mr "$(jq -c '.risk.files_changed = 150' <<<"$BASE")")"
assert_eq "複数の条件が崩れたら理由をすべて出す" "1 human_judgment path_unmatched,quality_gate_not_passed,no_review" \
  "$(run_mr "$(jq -c '.reviews = [] | .ci.status = "fail" | .files += [{path: "src/app.ts", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")")"
OUT="$(printf '%s' "$(jq -c '.files += [{path: "infra/main.tf", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")" | mr 2>/dev/null)"
assert_eq "根拠に該当したパスと規則と出所が載る" "infra/main.tf *.tf default" \
  "$(jq -r '.reasons[0] | "\(.path) \(.rule) \(.source)"' <<<"$OUT")"
assert_eq "人間判断のラベル" "人間判断" "$(jq -r '.label' <<<"$OUT")"
assert_eq "ファイルごとの判定が全件載る" "3" "$(jq -r '.files | length' <<<"$OUT")"

assert_eq "sensitive パス（preflight の touches_sensitive）-> touches_sensitive" "1 human_judgment touches_sensitive" \
  "$(run_mr "$(jq -c '.risk.touches_sensitive = true' <<<"$BASE")")"
assert_eq "files が null（取得失敗）-> files_unavailable" "1 human_judgment files_unavailable" \
  "$(run_mr "$(jq -c '.files = null' <<<"$BASE")")"
assert_eq "human のファイルを docs/ へリネーム -> previous_path_not_auto" "1 human_judgment previous_path_not_auto" \
  "$(run_mr "$(jq -c '.files[0] += {previous_path: ".github/workflows/security.yml", status: "renamed", deletions: 0}' <<<"$BASE")")"
assert_eq "テストを docs/ へリネーム（削除行 0）-> previous_path_not_auto" "1 human_judgment previous_path_not_auto" \
  "$(run_mr "$(jq -c '.files[0] += {previous_path: "tests/test_auth.py", status: "renamed", deletions: 0}' <<<"$BASE")")"
assert_eq "docs 内のリネーム -> 自動マージ可" "0 auto_merge_ok " \
  "$(run_mr "$(jq -c '.files[0] += {previous_path: "docs/old.md", status: "renamed"}' <<<"$BASE")")"
OUT="$(printf '%s' "$(jq -c '.files += [{path: "infra/main.tf", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")" | mr 2>/dev/null)"
CM="$(jq -r '.comment_markdown' <<<"$OUT")"
assert_eq "コメント本文: 見出しに区分が載る" "1" "$(grep -cF '## マージのリスク分類: 人間判断' <<<"$CM")"
assert_eq "コメント本文: 理由の行に code・path・rule・出所が載る" "1" "$(grep -cF '| `path_human` | `infra/main.tf` | `*.tf`（default） |' <<<"$CM")"
assert_eq "コメント本文: 理由の件数が reasons と一致する" "1" "$(grep -cF "### 人間判断の理由（全 $(jq -r '.reasons | length' <<<"$OUT") 件）" <<<"$CM")"
CM="$(printf '%s' "$BASE" | mr 2>/dev/null | jq -r '.comment_markdown')"
assert_eq "コメント本文: 自動マージ可なら全ファイルの規則を根拠として載せる" "2" "$(grep -cE '^\| `(docs/guide.md|src/widget_test.go)` \|' <<<"$CM")"
CM="$(printf '%s' "$(jq -c '.files[0].path = "docs/a|b.md"' <<<"$BASE")" | mr 2>/dev/null | jq -r '.comment_markdown')"
assert_eq "コメント本文: パスの | は表を壊さないようエスケープする" "1" "$(grep -cF '`docs/a\|b.md`' <<<"$CM")"

assert_eq "タブを含むパスで列をずらさない（照合せず人間判断）" "1 human_judgment path_unmatched" \
  "$(run_mr "$(jq -c '.files[0] += {path: "src/a\tb\tc.go", previous_path: "0", status: "renamed"}' <<<"$BASE")")"
assert_eq "改行を含むパスで列をずらさない（照合せず人間判断）" "1 human_judgment path_unmatched" \
  "$(run_mr "$(jq -c '.files[0].path = "docs/a\nb.md"' <<<"$BASE")")"
OUT="$(printf '%s' "$(jq -c '.files[0].path = "docs/a\tb.md"' <<<"$BASE")" | mr 2>/dev/null)"
assert_eq "制御文字を含むパスも出力には元のまま載る" "docs/a	b.md" "$(jq -r '.files[0].path' <<<"$OUT")"

echo "=== (3) リポジトリごとの上書き ==="
RULES_FILE="${WORK_DIR}/rules.txt"
cat >"$RULES_FILE" <<'EOF'
# このリポジトリでは UI 配下は自動マージ可、ADR は人間判断
auto src/ui/*
human docs/adr/*
EOF
assert_eq "上書き規則で未分類のパスを auto にできる" "0 auto_merge_ok " \
  "$(run_mr "$(jq -c '.files += [{path: "src/ui/button.tsx", additions: 1, deletions: 3}] | .risk.files_changed = 3' <<<"$BASE")" --rules "$RULES_FILE")"
OUT="$(printf '%s' "$(jq -c '.files += [{path: "docs/adr/0002.md", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")" | mr --rules "$RULES_FILE" 2>/dev/null)"
assert_eq "上書き規則が既定（docs/* = auto）より先に照合される" "human_judgment path_human docs/adr/* repo" \
  "$(jq -r '"\(.classification) \(.reasons[0].code) \(.reasons[0].rule) \(.reasons[0].source)"' <<<"$OUT")"
assert_eq "使った規則ファイルが出力に載る" "$RULES_FILE" "$(jq -r '.rules.repo_file' <<<"$OUT")"

REPO_DIR="${WORK_DIR}/repo"
new_repo "$REPO_DIR"
mkdir -p "${REPO_DIR}/.claude" "${REPO_DIR}/sub"
cp "$RULES_FILE" "${REPO_DIR}/.claude/merge-risk-rules.txt"
git -C "$REPO_DIR" add -f .claude/merge-risk-rules.txt
git -C "$REPO_DIR" -c user.name=t -c user.email=t@example.invalid commit -q -m rules
git -C "$REPO_DIR" update-ref refs/remotes/origin/main HEAD
# 作業ツリーの規則は PR 側が書き換えた版（全部 auto）。base の版が使われなければならない。
printf 'auto *\n' >"${REPO_DIR}/.claude/merge-risk-rules.txt"
INPUT_UI="$(jq -c '.files += [{path: "src/ui/button.tsx", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")"
OUT="$(cd "${REPO_DIR}/sub" && printf '%s' "$INPUT_UI" | bash "$TARGET_SCRIPT" 2>/dev/null)"
assert_eq "既定の置き場は base（origin/<base>）の .claude/merge-risk-rules.txt" \
  "auto_merge_ok origin/main:.claude/merge-risk-rules.txt" "$(jq -r '"\(.classification) \(.rules.repo_file)"' <<<"$OUT")"
OUT="$(cd "$REPO_DIR" && printf '%s' "$(jq -c '.files += [{path: "src/app.ts", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")" | bash "$TARGET_SCRIPT" 2>/dev/null)"
assert_eq "作業ツリーで書き換えた規則（auto *）は使わない" "human_judgment path_unmatched" \
  "$(jq -r '"\(.classification) \(.reasons[0].code)"' <<<"$OUT")"
assert_eq "規則ファイルが無ければ既定規則だけ（repo_file は null）" "null" "$(printf '%s' "$BASE" | mr 2>/dev/null | jq -r '.rules.repo_file')"
printf 'auto *\n' >"${WORK_DIR}/all-auto.txt"
assert_eq "規則ファイル自体の変更は上書き規則（auto *）でも人間判断" "1 human_judgment rules_file_changed" \
  "$(run_mr "$(jq -c '.files += [{path: ".claude/merge-risk-rules.txt", additions: 1, deletions: 0}] | .risk.files_changed = 3' <<<"$BASE")" --rules "${WORK_DIR}/all-auto.txt")"
assert_eq "sensitive パスは上書き規則（auto *）でも人間判断" "1 human_judgment touches_sensitive" \
  "$(run_mr "$(jq -c '.files += [{path: ".github/workflows/ci.yml", additions: 1, deletions: 0}] | .risk.files_changed = 3 | .risk.touches_sensitive = true' <<<"$BASE")" --rules "${WORK_DIR}/all-auto.txt")"
printf 'human docs/adr/*\r\n' >"${WORK_DIR}/crlf.txt"
assert_eq "CRLF の規則ファイルでも規則が効く" "1 human_judgment path_human" \
  "$(run_mr "$(jq -c '.files[0].path = "docs/adr/0003.md"' <<<"$BASE")" --rules "${WORK_DIR}/crlf.txt")"

echo "=== (4) 契約 ==="
BAD_RULES="${WORK_DIR}/bad.txt"
printf 'auto docs/*\nallow src/*\n' >"$BAD_RULES"
ERR="$(printf '%s' "$BASE" | mr --rules "$BAD_RULES" 2>&1 >/dev/null)"
CODE=$?
assert_eq "規則ファイルの未知の区分 -> exit 2" "2" "$CODE"
assert_eq "書式誤りは行番号付きで報告する" "1" "$(grep -c "bad.txt:2: unknown class 'allow'" <<<"$ERR")"
printf 'auto docs/* extra\n' >"$BAD_RULES"
printf '%s' "$BASE" | mr --rules "$BAD_RULES" >/dev/null 2>&1
assert_eq "1 行に glob が 2 つ -> exit 2" "2" "$?"
printf '%s' "$BASE" | mr --rules "${WORK_DIR}/missing.txt" >/dev/null 2>&1
assert_eq "指定した規則ファイルが無い -> exit 2" "2" "$?"
printf '%s' "$BASE" | mr --rules "$WORK_DIR" >/dev/null 2>&1
assert_eq "--rules にディレクトリ -> exit 2" "2" "$?"
printf '%s' "$(jq -c '.files[0].path = 5' <<<"$BASE")" | mr >/dev/null 2>&1
assert_eq "判定の途中で失敗した（path が文字列でない）-> exit 2（空の出力で 1 を返さない）" "2" "$?"
printf '%s' "$(jq -c 'del(.base)' <<<"$BASE")" | mr >/dev/null 2>&1
assert_eq "base が無い（規則を base から読めない）-> exit 2" "2" "$?"
NOREF="${WORK_DIR}/noref"
mkdir -p "$NOREF" && git -C "$NOREF" init -q
printf '%s' "$BASE" | (cd "$NOREF" && bash "$TARGET_SCRIPT") >/dev/null 2>&1
assert_eq "origin/<base> を解決できない -> exit 2" "2" "$?"
printf 'not json' | mr >/dev/null 2>&1
assert_eq "stdin が JSON でない -> exit 2" "2" "$?"
printf '{"ci":{"status":"pass"}}' | mr >/dev/null 2>&1
assert_eq "files が無い（preflight の出力ではない）-> exit 2" "2" "$?"
printf '%s' "$BASE" | mr --ai-review yes >/dev/null 2>&1
assert_eq "--ai-review の値が不正 -> exit 2" "2" "$?"
assert_eq "既定規則は書式どおりに読める" "0" "$(merge_risk_parse_rules "$(merge_risk_default_rules)" default >/dev/null 2>&1; echo $?)"

echo "=== (5) 語彙の一致（spec の理由コード表 ⇔ スクリプト） ==="
# 理由コードの表は「理由コード:」の行から次の見出しまで（区分の表・出力の表を拾わない）。
SPEC_CODES="$(sed -n '/^理由コード:$/,/^## /p' "$SPEC_FILE" | grep -oE '^\| `[a-z_]+` \|' | sed -E 's/^\| `([a-z_]+)` \|$/\1/' | sort -u)"
# スクリプト側のコードは、判定式の `code: "..."` と、ファイルごとの理由の説明表（detail_of）のキー。
SCRIPT_CODES="$( {
  grep -oE 'code: "[a-z_]+"' "$TARGET_SCRIPT" | sed -E 's/code: "([a-z_]+)"/\1/'
  sed -n '/def detail_of/,/}\[\$code\]/p' "$TARGET_SCRIPT" | grep -oE '[a-z_]+: "' | sed -E 's/: "$//'
} | sort -u)"
assert_eq "spec の理由コード表とスクリプトの理由コードが一致する" "$SCRIPT_CODES" "$SPEC_CODES"
assert_eq "理由コードが 1 件以上ある（空虚な一致にしない）" "1" "$([ -n "$SCRIPT_CODES" ] && echo 1 || echo 0)"

echo "=== (6) /pr-merge への接続（節スコープ） ==="
SKILL_FILE="${MR_REPO_ROOT}/skills/pr-merge/SKILL.md"
# 見出しは ASCII の接頭辞で区切る（sed の範囲指定。日本語の一致判定に awk の == を使わない）。
P35="$(sed -n '/^### Phase 3\.5:/,/^### Phase 4:/p' "$SKILL_FILE")"
P4="$(sed -n '/^### Phase 4:/,/^## /p' "$SKILL_FILE")"
REPORT="$(sed -n '/^## 作業完了時/,$p' "$SKILL_FILE")"
assert_eq "Phase 3.5 がランチャー経由で merge-risk を呼ぶ" "1" \
  "$(grep -cF 'claude-harness-run merge-risk --ai-review "$AI_REVIEW" <<<"$PREFLIGHT"' <<<"$P35")"
assert_eq "Phase 3.5 が区分は承認ゲートを変えないと明記する" "1" \
  "$(grep -cF '**区分は Phase 4 の承認ゲートを変えない**' <<<"$P35")"
assert_eq "Phase 3.5 が規則を読む前に base を fetch する" "1" "$(grep -cF 'git fetch origin "$BASE"' <<<"$P35")"
assert_eq "Phase 3.5 がスクリプトの本文を --body-file で PR に残す" "1" \
  "$(grep -cF 'gh pr comment "$PR_NUM" --body-file "$BODY_DIR/merge-risk.md"' <<<"$P35")"
assert_eq "Phase 3.5 は本文をスクリプトの comment_markdown から作る" "1" "$(grep -cF "jq -r '.comment_markdown'" <<<"$P35")"
# Phase 3 の 3 分岐すべてが、問題が無ければ Phase 3.5 へ進む（Phase 4 へ直行して分類を飛ばさない）。
P3="$(sed -n '/^### Phase 3:/,/^### Phase 3\.5:/p' "$SKILL_FILE")"
assert_eq "Phase 3 の 3 分岐が Phase 3.5 へ進む" "3" "$(grep -c 'Phase 3\.5 へ進む' <<<"$P3")"
assert_eq "Phase 3 から Phase 4 へ直行する分岐が無い" "0" "$(grep -c '無ければ Phase 4 へ進む\|後始末して Phase 4 へ進む' <<<"$P3")"
assert_eq "Phase 3.5 が 0・1 以外の終了を人間判断として扱う" "1" "$(grep -cF 'それ以外の終了（2 = 判定できなかった、ランチャーの失敗等）は stderr を報告し、`人間判断` として扱う' <<<"$P35")"
assert_eq "Phase 4（マージ）は区分を参照しない（自動マージの経路を作らない）" "0" "$(grep -c 'merge-risk\|MERGE_RISK\|自動マージ可' <<<"$P4")"
assert_eq "完了報告にリスク区分と根拠の項目が在る" "1" "$(grep -cF 'マージのリスク区分と根拠' <<<"$REPORT")"

echo ""
echo "=============================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "結果: ${PASS_COUNT}/${TOTAL} passed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "失敗したテスト:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi
exit 0
