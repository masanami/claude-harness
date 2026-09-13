#!/bin/bash
# test-claude-md-template.sh
# skills/init-project/templates/CLAUDE.md.template の**分量と節構成**を固定する。
#
# なぜあるか:
#   公式の memory ガイドは「1 ファイル 200 行未満」を目標に挙げ、超えると追従率が下がると
#   明示している。テンプレートは置換前が短くても、**置換後**に表や自由記述が膨らむため、
#   固定すべきは「置換後の行数」である（Issue #237）。散文の規約では守られないので機械で測る。
#
# 本テストが固定するもの:
#   (A) 節構成: 棚卸しで削った節が復活していないこと（否定検査）と、残す節が在ること
#   (B) 代表的なプロジェクト形状（Node/TS の Web アプリ）で置換した実測行数が 200 行未満
#   (C) フィクスチャがテンプレートの**全プレースホルダを覆う**こと
#       （テンプレートにプレースホルダを足すと未知トークンとして落ちる）
#   (D) 行数の budget: 全プレースホルダに 12 行ずつ与えた上限見積りでも 200 行未満
#   (E) (B)(D) の検算が空虚でないこと（節を足したコピーで実際に落ちる＝変異注入）
#   (F) 末尾の `/doctor` 案内が在り、そこに harness 固有語が混ざっていないこと
#
# 変異注入は**原本を書き換えない**。一時ディレクトリにコピーを作り、コピーへ注入する。
#
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。文字列一致は grep -F / bash の文字列比較で行う。
#
# 実行方法: bash scripts/tests/test-claude-md-template.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

set -u

TT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TT_REPO_ROOT="$(cd "${TT_TEST_DIR}/../.." && pwd -P)"
TT_TEMPLATE="${TT_REPO_ROOT}/skills/init-project/templates/CLAUDE.md.template"

# 公式の memory ガイドが挙げる目標値。ここが唯一の正本（散文へ書き写さない）。
TT_MAX_LINES=200
# 上限見積りで1プレースホルダに与える行数。
TT_GENEROUS_LINES=12

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

if ! TT_TMP_DIR="$(mktemp -d)"; then
  echo "Failed to create test temporary directory" >&2
  exit 1
fi
trap 'rm -rf "$TT_TMP_DIR"' EXIT

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  FAIL - ${description}"
    echo "      expected: ${expected}"
    echo "      actual:   ${actual}"
  fi
}

assert_true() {
  assert_eq "$1" "true" "$2"
}

# ------------------------------------------------------------------
# 置換（代表的なプロジェクト形状: Node/TS の Web アプリ）
# ------------------------------------------------------------------

# 引数: プレースホルダ（`{TOKEN}` 形式）→ 代表値。未知のトークンは非0で返す
# （黙って空文字に丸めると、テンプレートへプレースホルダを足しても行数が増えず検査が抜ける）。
tt_value() {
  case "$1" in
    '{PROJECT_NAME}')      printf '%s' 'acme-web' ;;
    '{BRANCH_STRATEGY}')   printf '%s' 'GitHub Flow' ;;
    '{BRANCH_FORMAT}')     printf '%s' '<type>/<ticket-id>-<説明>' ;;
    '{COMMIT_LANGUAGE}')   printf '%s' '日本語' ;;
    '{SCOPES}')            printf '%s' 'api, web, db, ci' ;;
    '{MAX_PR_LINES}')      printf '%s' '400' ;;
    '{MERGE_STRATEGY}')    printf '%s' 'squash マージ' ;;
    '{NEW_FILE_PLACEMENT}')
      printf '%s\n' '- API ハンドラは `src/routes/` に 1 エンドポイント 1 ファイルで置く'
      printf '%s'   '- 共有の型定義は `src/types/` に置き、機能ディレクトリ内には置かない' ;;
    '{TEST_APPROACH}')     printf '%s' 'ユニットは vitest、E2E は Playwright。E2E は課金フローとサインアップのみ' ;;
    '{MOCK_TARGETS}')      printf '%s' '外部決済 API、メール送信' ;;
    '{NO_MOCK_TARGETS}')   printf '%s' 'DB（テスト用 PostgreSQL コンテナを使う）、自前のドメインロジック' ;;
    '{QUALITY_POLICY}')
      printf '%s\n' 'npm run lint'
      printf '%s\n' 'npm run typecheck'
      printf '%s\n' 'npm test -- --coverage'
      printf '%s'   'カバレッジ: src/domain 配下は 80% 以上' ;;
    '{COMMON_COMMANDS}')
      printf '%s\n' 'npm run dev'
      printf '%s\n' 'npm run build'
      printf '%s\n' 'npm test'
      printf '%s\n' 'npm run lint'
      printf '%s'   'docker compose up -d db' ;;
    *) return 1 ;;
  esac
}

# 引数: プレースホルダ → 上限見積り用の値（TT_GENEROUS_LINES 行）。
tt_generous_value() {
  local i=1
  while [ "$i" -lt "$TT_GENEROUS_LINES" ]; do
    printf '%s\n' "$1 行 ${i}"
    i=$((i + 1))
  done
  printf '%s' "$1 行 ${TT_GENEROUS_LINES}"
}

tt_tokens() {
  grep -o '{[A-Za-z0-9_]*}' "$1" 2>/dev/null | LC_ALL=C sort -u
}

# 引数: テンプレート, 値を返す関数名 → 置換後の本文。
# 置換対象は**テンプレートから抽出したトークンだけ**を走査する（行を再スキャンして
# 置き換えると、値の中の `{...}` を拾って無限ループになりうる）。
# 未知のトークンは `<<UNKNOWN:...>>` として残し、(C) が検出する。
tt_render() {
  local template="$1" valuefn="$2" tokens line token value
  tokens="$(tt_tokens "$template")"
  while IFS= read -r line || [ -n "$line" ]; do
    while IFS= read -r token; do
      [ -z "$token" ] && continue
      case "$line" in *"$token"*) : ;; *) continue ;; esac
      if ! value="$("$valuefn" "$token")"; then
        value="<<UNKNOWN:${token}>>"
      fi
      line="${line//$token/$value}"
    done <<EOF
$tokens
EOF
    printf '%s\n' "$line"
  done < "$template"
}

echo "=== test: CLAUDE.md.template の分量と節構成 ==="

assert_true "テンプレートが実在する" "$([ -f "$TT_TEMPLATE" ] && echo true || echo false)"

# ------------------------------------------------------------------
# (A) 節構成
# ------------------------------------------------------------------
echo "== (A) 節構成 =="

tt_has_section() {
  grep -Fxq "$1" "$TT_TEMPLATE" && echo true || echo false
}

# 残す節: コードベースから導けない判断、またはツール既定と異なる規約
assert_eq "残す節: 開発規約" "true" "$(tt_has_section '## 開発規約')"
assert_eq "残す節: テスト方針" "true" "$(tt_has_section '## テスト方針')"
assert_eq "残す節: 品質方針（具体的なゲート）" "true" "$(tt_has_section '## 品質方針')"
assert_eq "残す節: よく使うコマンド" "true" "$(tt_has_section '## よく使うコマンド')"

# 削った節（否定検査）: コードベースから導ける内容 / 一般論で検証できない指示
assert_eq "削った節が復活していない: プロジェクト概要（architecture overview）" "false" \
  "$(tt_has_section '## プロジェクト概要')"
assert_eq "削った節が復活していない: 開発原則（YAGNI/KISS/DRY の一般論）" "false" \
  "$(tt_has_section '## 開発原則')"
assert_eq "削った節が復活していない: 技術スタック（dependency list）" "false" \
  "$(tt_has_section '## 技術スタック')"
assert_eq "削った節が復活していない: ドキュメントマップ（directory layout）" "false" \
  "$(tt_has_section '## ドキュメントマップ')"

# 節を増やすときは意図的に本テストを更新させる（黙って膨らませない）。
assert_eq "H2 の節は4つ" "4" "$(grep -c '^## ' "$TT_TEMPLATE" | tr -d ' ')"

# 命名スタイルの表は既存コードから導けるため落とした（否定検査）。
assert_eq "命名スタイルの表が残っていない" "false" \
  "$(grep -q 'FILE_NAMING\|COMPONENT_NAMING\|CONST_NAMING' "$TT_TEMPLATE" && echo true || echo false)"

# ------------------------------------------------------------------
# (B)(C) 代表的なプロジェクト形状での実測
# ------------------------------------------------------------------
echo "== (B)(C) 代表形状での置換後の行数 =="

TT_RENDERED="${TT_TMP_DIR}/rendered.md"
tt_render "$TT_TEMPLATE" tt_value > "$TT_RENDERED"
TT_RENDERED_LINES="$(grep -c '' "$TT_RENDERED" | tr -d ' ')"
echo "  -- 実測: 置換前 $(grep -c '' "$TT_TEMPLATE" | tr -d ' ') 行 / 置換後 ${TT_RENDERED_LINES} 行（上限 ${TT_MAX_LINES}）"

assert_true "置換が実際に行われている（切り出し失敗を pass にしない）" \
  "$([ "$TT_RENDERED_LINES" -gt 0 ] && echo true || echo false)"
assert_true "代表形状の置換後は ${TT_MAX_LINES} 行未満" \
  "$([ "$TT_RENDERED_LINES" -lt "$TT_MAX_LINES" ] && echo true || echo false)"

assert_eq "未置換のプレースホルダが残らない" "0" \
  "$(grep -c -o '{[A-Za-z0-9_]*}' "$TT_RENDERED" | tr -d ' ')"
assert_eq "フィクスチャがテンプレートの全プレースホルダを覆う（未知トークンが無い）" "false" \
  "$(grep -Fq '<<UNKNOWN:' "$TT_RENDERED" && echo true || echo false)"

# ------------------------------------------------------------------
# (D) 上限見積り
# ------------------------------------------------------------------
echo "== (D) 上限見積り =="

TT_GENEROUS="${TT_TMP_DIR}/generous.md"
tt_render "$TT_TEMPLATE" tt_generous_value > "$TT_GENEROUS"
TT_GENEROUS_TOTAL="$(grep -c '' "$TT_GENEROUS" | tr -d ' ')"
echo "  -- 実測: 全プレースホルダに ${TT_GENEROUS_LINES} 行ずつ与えた上限見積り ${TT_GENEROUS_TOTAL} 行（上限 ${TT_MAX_LINES}）"
assert_true "上限見積りでも ${TT_MAX_LINES} 行未満（プレースホルダを増やす余地の担保）" \
  "$([ "$TT_GENEROUS_TOTAL" -lt "$TT_MAX_LINES" ] && echo true || echo false)"

# ------------------------------------------------------------------
# (E) 検算が空虚でないこと（変異注入。原本は書き換えない）
# ------------------------------------------------------------------
echo "== (E) 変異注入 =="

TT_MUTANT="${TT_TMP_DIR}/mutant.template"
cp "$TT_TEMPLATE" "$TT_MUTANT"
i=1
while [ "$i" -le 200 ]; do
  printf '\n## 追加の節 %s\n\n本文\n' "$i" >> "$TT_MUTANT"
  i=$((i + 1))
done
assert_true "変異注入が実際に効いている（注入失敗を pass にしない）" \
  "$([ "$(grep -c '^## ' "$TT_MUTANT" | tr -d ' ')" -gt 4 ] && echo true || echo false)"

TT_MUT_RENDERED="${TT_TMP_DIR}/mutant-rendered.md"
tt_render "$TT_MUTANT" tt_value > "$TT_MUT_RENDERED"
TT_MUT_LINES="$(grep -c '' "$TT_MUT_RENDERED" | tr -d ' ')"
assert_true "膨らませたテンプレートは行数の検査に落とされる（検査が空虚に真でない）" \
  "$([ "$TT_MUT_LINES" -ge "$TT_MAX_LINES" ] && echo true || echo false)"

TT_MUTANT2="${TT_TMP_DIR}/mutant2.template"
cp "$TT_TEMPLATE" "$TT_MUTANT2"
printf '\n{NEW_UNCOVERED_PLACEHOLDER}\n' >> "$TT_MUTANT2"
TT_MUT2_RENDERED="${TT_TMP_DIR}/mutant2-rendered.md"
tt_render "$TT_MUTANT2" tt_value > "$TT_MUT2_RENDERED"
assert_eq "フィクスチャが覆わないプレースホルダは未知トークンとして検出される" "true" \
  "$(grep -Fq '<<UNKNOWN:{NEW_UNCOVERED_PLACEHOLDER}>>' "$TT_MUT2_RENDERED" && echo true || echo false)"

# ------------------------------------------------------------------
# (F) 末尾の /doctor 案内
# ------------------------------------------------------------------
echo "== (F) /doctor 案内 =="

TT_LAST_LINE="$(tail -1 "$TT_TEMPLATE")"
assert_eq "末尾の行が /doctor を案内する" "true" \
  "$(printf '%s' "$TT_LAST_LINE" | grep -Fq '/doctor' && echo true || echo false)"
assert_eq "案内が 200 行の目標値に言及する" "true" \
  "$(printf '%s' "$TT_LAST_LINE" | grep -Fq "$TT_MAX_LINES" && echo true || echo false)"
# 案内は Claude Code 本体のセッションコマンドを指す。同名の同梱スクリプト
# （claude-harness-run preflight）を指してしまうと、生成物へ harness 固有語が入る。
assert_eq "案内に harness 固有語（ランチャー名）が混ざっていない（否定検査）" "false" \
  "$(grep -Fq 'claude-harness' "$TT_TEMPLATE" && echo true || echo false)"

# ------------------------------------------------------------------
# 要約
# ------------------------------------------------------------------
echo ""
echo "==================================="
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "  失敗したテスト:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "    - ${t}"
  done
  echo "==================================="
  exit 1
fi
echo "==================================="
exit 0
