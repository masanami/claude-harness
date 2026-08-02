#!/bin/bash
# test-skeptic-discipline.sh
#
# 懐疑者系5エージェント（finding-verifier / debt-verifier / claim-advocate /
# attestation-verifier / design-deviation-verifier）の共通規律ブロックは、実行時
# コンテキストを増やさないために意図的にインライン（各ファイルへの逐語コピー）で
# 維持されている（Issue #132）。共有ファイルへの切り出しは不採用のため、代わりに
# 本テストが「正準文（各共通ブロックのドメイン置換を含まない不変フレーズ）が
# 対象ファイルに逐語で存在するか」を検査し、ドリフト（更新漏れ）を機械検出する
# （実行方法は末尾のとおりで、本リポジトリに GitHub Actions 等の CI パイプラインは
# 無いため、実行タイミングは呼び出し側の運用に委ねる。強制するのは「テストとして
# 存在し実行すれば検出できる」ことであり、自動実行のスケジュールではない）。
#
# 別種として、agents/decompose-judge.md の粒度基準ブロックは agents/ticket-decomposer.md
# （正本）の手動コピーであり、両ファイルの `<!-- granularity-criteria:start/end -->`
# マーカー間のテキストが完全一致することも検査する。
#
# 対象ファイルと正準文の対応表（◯=検査対象／×=対象外。値は検査に使う不変フレーズの通し番号）:
#
#   | # | 正準文（不変フレーズ） | finding | debt | claim | attestation | design-deviation |
#   |---|------------------------|:---:|:---:|:---:|:---:|:---:|
#   | A | のような憶測ベースの reason は禁止                                           | ◯ | ◯ | ◯ | ◯ | ◯ |
#   | B | 他の懐疑者の判定を考慮・忖度すること                                          | ◯ | ◯ | × | ◯ | ◯ |
#   | C | Task ツールには出力検証機構が無いため                                        | ◯ | ◯ | ◯ | × | × |
#   | D | フィールド一覧・型そのものは呼び出し元プロンプト側の責務であり、ここでは重複記載しません | ◯ | ◯ | ◯ | × | × |
#   | E | ## Step 0: プロジェクトコンテキストの確認（見出し）                           | ◯ | ◯ | ◯ | × | × |
#   | F | ## 禁止事項（見出し）                                                        | ◯ | ◯ | ◯ | ◯ | ◯ |
#   | G | verdict を返すこと（推測での判定禁止）                                       | ◯ | ◯ | ◯ | ◯ | ◯ |
#   | H | 機能変更（バグ修正・仕様変更の要否）                                          | ◯ | ◯ | ◯ | × | ◯ |
#   | I | スキーマに存在しない自由記述のフィールドを追加すること・JSON以外のテキストを出力に混ぜること | ◯ | ◯ | ◯ | × | × |
#
#   （B が claim-advocate で対象外な理由: claim-advocate は「あなたは1体のみで呼び出されます」
#   という単体呼び出し変種の文言を持つため、この不変フレーズの対象から除外している。
#   C・D・E が attestation-verifier / design-deviation-verifier で対象外な理由:
#   attestation-verifier には Step 0 セクション自体が無く（Step 1 から始まる）、
#   design-deviation-verifier は Step 0 の見出しが「## Step 0: 照合対象の確認」で
#   他3ファイルと異なる。出力形式もJSONではなく自然文の構造化応答（attestation-verifierは
#   「## 出力形式」セクション、design-deviation-verifierは冒頭 verdict 明記）で定義している
#   ため。H が attestation-verifier で対象外な理由: 同ファイルの禁止事項は
#   「機能変更（実装の修正要否）」という別文言のため（design-deviation-verifier は
#   finding/debt/claim と同じ「機能変更（バグ修正・仕様変更の要否）」を逐語で持つため対象）。
#   I が attestation-verifier / design-deviation-verifier で対象外な理由: 両者とも
#   出力形式の説明が独自セクションで定義されており、finding/debt/claim と同一文言の
#   「スキーマに存在しない自由記述の…」を持たないため）
#
# 新規懐疑者エージェントを追加する場合の登録手順: 上記の対応表に列を1本追加し、
# 下記 A〜I の各チェック関数呼び出しに新エージェントのファイルパスを対象として追加する
# （対象外にする不変フレーズがあれば対応表に × を明記し、そのチェックへは追加しない）。
#
# 実行方法: bash scripts/tests/test-skeptic-discipline.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "$REPO_ROOT" || exit 1

FINDING="agents/finding-verifier.md"
DEBT="agents/debt-verifier.md"
CLAIM="agents/claim-advocate.md"
ATTESTATION="agents/attestation-verifier.md"
DESIGN_DEVIATION="agents/design-deviation-verifier.md"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# assert_contains: 対象ファイルに正準文（固定文字列）が逐語で存在することを検査する。
assert_contains() {
  local description="$1" file="$2" phrase="$3"
  if grep -qF -- "$phrase" "$file"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${file}"
    echo "       phrase: ${phrase}"
  fi
}

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

echo "=== 正準文A: のような憶測ベースの reason は禁止（5ファイル共通） ==="
{
  phrase="のような憶測ベースの reason は禁止"
  assert_contains "finding-verifier に正準文Aが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Aが存在する" "$DEBT" "$phrase"
  assert_contains "claim-advocate に正準文Aが存在する" "$CLAIM" "$phrase"
  assert_contains "attestation-verifier に正準文Aが存在する" "$ATTESTATION" "$phrase"
  assert_contains "design-deviation-verifier に正準文Aが存在する" "$DESIGN_DEVIATION" "$phrase"
}

echo ""
echo "=== 正準文B: 他の懐疑者の判定を考慮・忖度すること（claim-advocateは単体呼び出し変種のため対象外） ==="
{
  phrase="他の懐疑者の判定を考慮・忖度すること"
  assert_contains "finding-verifier に正準文Bが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Bが存在する" "$DEBT" "$phrase"
  assert_contains "attestation-verifier に正準文Bが存在する" "$ATTESTATION" "$phrase"
  assert_contains "design-deviation-verifier に正準文Bが存在する" "$DESIGN_DEVIATION" "$phrase"
}

echo ""
echo "=== 正準文C: Task ツールには出力検証機構が無いため（attestation-verifier/design-deviation-verifierは対象外） ==="
{
  phrase="Task ツールには出力検証機構が無いため"
  assert_contains "finding-verifier に正準文Cが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Cが存在する" "$DEBT" "$phrase"
  assert_contains "claim-advocate に正準文Cが存在する" "$CLAIM" "$phrase"
}

echo ""
echo "=== 正準文D: フィールド一覧・型そのものは呼び出し元プロンプト側の責務であり、ここでは重複記載しません（attestation-verifier/design-deviation-verifierは対象外） ==="
{
  phrase="フィールド一覧・型そのものは呼び出し元プロンプト側の責務であり、ここでは重複記載しません"
  assert_contains "finding-verifier に正準文Dが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Dが存在する" "$DEBT" "$phrase"
  assert_contains "claim-advocate に正準文Dが存在する" "$CLAIM" "$phrase"
}

echo ""
echo "=== 正準文E: ## Step 0: プロジェクトコンテキストの確認（見出し。attestation-verifier/design-deviation-verifierは対象外） ==="
{
  phrase="## Step 0: プロジェクトコンテキストの確認"
  assert_contains "finding-verifier に正準文Eが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Eが存在する" "$DEBT" "$phrase"
  assert_contains "claim-advocate に正準文Eが存在する" "$CLAIM" "$phrase"
}

echo ""
echo "=== 正準文F: ## 禁止事項（見出し。5ファイル共通） ==="
{
  phrase="## 禁止事項"
  assert_contains "finding-verifier に正準文Fが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Fが存在する" "$DEBT" "$phrase"
  assert_contains "claim-advocate に正準文Fが存在する" "$CLAIM" "$phrase"
  assert_contains "attestation-verifier に正準文Fが存在する" "$ATTESTATION" "$phrase"
  assert_contains "design-deviation-verifier に正準文Fが存在する" "$DESIGN_DEVIATION" "$phrase"
}

echo ""
echo "=== 正準文G: verdict を返すこと（推測での判定禁止）（5ファイル共通） ==="
{
  phrase="verdict を返すこと（推測での判定禁止）"
  assert_contains "finding-verifier に正準文Gが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Gが存在する" "$DEBT" "$phrase"
  assert_contains "claim-advocate に正準文Gが存在する" "$CLAIM" "$phrase"
  assert_contains "attestation-verifier に正準文Gが存在する" "$ATTESTATION" "$phrase"
  assert_contains "design-deviation-verifier に正準文Gが存在する" "$DESIGN_DEVIATION" "$phrase"
}

echo ""
echo "=== 正準文H: 機能変更（バグ修正・仕様変更の要否）（attestation-verifierのみ対象外。禁止事項本文の実質チェック） ==="
{
  phrase="機能変更（バグ修正・仕様変更の要否）"
  assert_contains "finding-verifier に正準文Hが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Hが存在する" "$DEBT" "$phrase"
  assert_contains "claim-advocate に正準文Hが存在する" "$CLAIM" "$phrase"
  assert_contains "design-deviation-verifier に正準文Hが存在する" "$DESIGN_DEVIATION" "$phrase"
}

echo ""
echo "=== 正準文I: スキーマに存在しない自由記述のフィールドを追加すること・JSON以外のテキストを出力に混ぜること（finding/debt/claimのみ） ==="
{
  phrase="スキーマに存在しない自由記述のフィールドを追加すること・JSON以外のテキストを出力に混ぜること"
  assert_contains "finding-verifier に正準文Iが存在する" "$FINDING" "$phrase"
  assert_contains "debt-verifier に正準文Iが存在する" "$DEBT" "$phrase"
  assert_contains "claim-advocate に正準文Iが存在する" "$CLAIM" "$phrase"
}

echo ""
echo "=== 粒度基準ブロックの同期チェック（agents/ticket-decomposer.md が正本） ==="
{
  DECOMPOSER="agents/ticket-decomposer.md"
  JUDGE="agents/decompose-judge.md"
  MARKER_START="<!-- granularity-criteria:start -->"
  MARKER_END="<!-- granularity-criteria:end -->"

  extract_between_markers() {
    local file="$1"
    sed -n "/${MARKER_START}/,/${MARKER_END}/p" "$file" | sed '1d;$d'
  }

  decomposer_exit=0
  grep -qF -- "$MARKER_START" "$DECOMPOSER" && grep -qF -- "$MARKER_END" "$DECOMPOSER" || decomposer_exit=1
  judge_exit=0
  grep -qF -- "$MARKER_START" "$JUDGE" && grep -qF -- "$MARKER_END" "$JUDGE" || judge_exit=1

  if [ "$decomposer_exit" -ne 0 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("ticket-decomposer.md に granularity-criteria マーカーが存在する")
    echo "  NG - ticket-decomposer.md に granularity-criteria マーカーが存在する"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ticket-decomposer.md に granularity-criteria マーカーが存在する"
  fi

  if [ "$judge_exit" -ne 0 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("decompose-judge.md に granularity-criteria マーカーが存在する")
    echo "  NG - decompose-judge.md に granularity-criteria マーカーが存在する"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - decompose-judge.md に granularity-criteria マーカーが存在する"
  fi

  if [ "$decomposer_exit" -eq 0 ] && [ "$judge_exit" -eq 0 ]; then
    decomposer_block="$(extract_between_markers "$DECOMPOSER")"
    judge_block="$(extract_between_markers "$JUDGE")"
    assert_eq "ticket-decomposer.md と decompose-judge.md の粒度基準ブロックが完全一致する" \
      "$decomposer_block" "$judge_block"

    # 空文字同士の一致で誤ってpassしないためのガード（マーカーは存在するが中身が空という
    # 壊れたテストを検出する）。
    if [ -z "$decomposer_block" ]; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("粒度基準ブロックが空でない")
      echo "  NG - 粒度基準ブロックが空でない（マーカー間に内容が無い）"
    else
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok - 粒度基準ブロックが空でない"
    fi
  fi

  # 手動同期義務コメントがテスト参照コメントへ差し替わっていることを確認する
  # （「合わせて更新すること」という人手頼みの呼びかけが残っていないか）。
  if grep -qF -- "正本を更新した場合はこちらも合わせて更新すること" "$JUDGE"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("decompose-judge.md の手動同期義務コメントがテスト参照へ差し替わっている")
    echo "  NG - decompose-judge.md に手動同期義務コメント（「合わせて更新すること」）が残存している"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - decompose-judge.md の手動同期義務コメントがテスト参照へ差し替わっている"
  fi

  assert_contains "decompose-judge.md のコメントが本テストファイルを参照している" "$JUDGE" \
    "test-skeptic-discipline.sh"
}

echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi

exit 0
