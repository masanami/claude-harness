#!/bin/bash
# test-surface-audit.sh
#
# `/surface-audit`（公開面 × テスト担保の診断）の構造不変条件テスト。
# 散文の手順書には型検査もテストも効かないため、**規約が成立するための構造**を機械で固定する:
#
#   (A) 保証台帳（GDD）由来の経路・ファイルが残っていない（削除の完了）
#   (B) 実行時ファイル（skills/ agents/）に、モデルの行動を変えない情報が混ざっていない
#   (C) GAP 検出が主機能として成立している（公開面の列挙 → 突き合わせ → 種別）
#   (D) 読み書きしない契約が、**1つの文字列ではなく禁止パターンの集合**で守られている
#   (E) 機械可読契約が「未解析」を「0件・正常」へ丸めない（工程ごとの status・null・等式の適用条件）
#   (F) 定期実行の呼び出し元が必要とする3点が機械可読に出る
#   (G) fan-out の規律（非信頼データの分離・チャンク・同一性による完全性 join）
#   (H) 抽出エージェントの契約（状態値・assertion・全件返却）
#
# 逐語照合は**可変部を含まない一文まるごと**で行う（意味を反転しても部分一致は通るため）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。
#
# 実行方法: bash scripts/tests/test-surface-audit.sh

set -u

SA_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SA_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

SKILL_FILE="${REPO_ROOT}/skills/surface-audit/SKILL.md"
AGENT_FILE="${REPO_ROOT}/agents/surface-auditor.md"

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

# 固定文字列がファイルに逐語で存在すること。読めないファイルは pass にしない。
assert_file_contains() {
  local description="$1" file="$2" phrase="$3"
  if [ ! -r "$file" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}（ファイルを読めない: ${file}）"
    return
  fi
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

# 固定文字列がファイルに存在**しない**こと。読めないファイルは「無い」で通さず失敗させる。
assert_file_lacks() {
  local description="$1" file="$2" phrase="$3"
  if [ ! -r "$file" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}（ファイルを読めない: ${file}）"
    return
  fi
  if grep -qF -- "$phrase" "$file"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${file}"
    echo "       phrase: ${phrase}（残っている）"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  fi
}

echo "=== 前提: 対象ファイルを読める（読めない状態を pass にしない） ==="

for f in "$SKILL_FILE" "$AGENT_FILE"; do
  assert_eq "読める: ${f#${REPO_ROOT}/}" "true" \
    "$(if [ -r "$f" ]; then echo true; else echo false; fi)"
done

# 単一ファイルのスキルであること（参照ファイルへの配送を挟まない＝配送失敗で手順が欠ける経路が無い）
assert_eq "スキルは SKILL.md 1本で完結している（references/ を持たない）" "false" \
  "$(if [ -e "${REPO_ROOT}/skills/surface-audit/references" ]; then echo true; else echo false; fi)"

echo ""
echo "=== (A) 保証台帳（GDD）由来の経路・ファイルが残っていない ==="

for gone in \
  'skills/guarantee-audit' \
  'skills/surface-audit/references/drift-mode.md' \
  'skills/surface-audit/references/bootstrap-mode.md' \
  'agents/guarantee-auditor.md' \
  'scripts/guarantee-index-check.sh' \
  'scripts/specs/guarantee-index-check.md' \
  'scripts/tests/test-guarantee-index-check.sh' \
  'scripts/detect-dev-phase.sh' \
  'scripts/specs/detect-dev-phase.md' \
  'scripts/tests/test-detect-dev-phase.sh'; do
  assert_eq "(A) 削除済み: ${gone}" "false" \
    "$(if [ -e "${REPO_ROOT}/${gone}" ]; then echo true; else echo false; fi)"
done

# 実行時ファイルとスクリプト（テストを除く）から、削除した経路への参照が消えていること。
# テスト自身は削除対象の名前を**検出キー**として持つため走査対象から外す。
dangling="$(grep -rlE 'guarantee-index-check|detect-dev-phase|guarantee-auditor|guarantee-audit|drift-mode\.md|bootstrap-mode\.md' \
  skills agents scripts --include='*.md' --include='*.sh' 2>/dev/null | grep -v '^scripts/tests/')"
dangling_rc=$?
assert_eq "(A) grep が実行エラーを起こしていない" "true" \
  "$(if [ "$dangling_rc" -le 1 ]; then echo true; else echo false; fi)"
assert_eq "(A) skills/ agents/ scripts/ に削除した経路への参照が残っていない" "" "$dangling"

echo ""
echo "=== (B) 実行時ファイルに、モデルの行動を変えない情報が混ざっていない ==="

# skills/ と agents/ は実行のたびにモデルが読む面。用語の言い換え・経緯・出典・課題番号は
# 行動を変えないぶんコンテキストを食い、判断のノイズになる（理由や経緯は docs/ と PR 本文へ置く）。
for f in "$SKILL_FILE" "$AGENT_FILE"; do
  short="$(basename "$f")"
  for term in 'GDD' '保証台帳' '台帳' '凍結' 'ADR' 'Issue #' '#194' '#159' '再位置づけ' '実測'; do
    assert_file_lacks "(B) ${short} に不要語が無い: ${term}" "$f" "$term"
  done
done

echo ""
echo "=== (C) GAP 検出が主機能として成立している ==="

assert_file_contains "(C) 公開面をカテゴリ側から列挙する工程が在る" "$SKILL_FILE" \
  '## Step 2: 公開面の列挙（カテゴリ別）'
assert_file_contains "(C) 突き合わせ（GAP 判定）の工程が在る" "$SKILL_FILE" \
  '## Step 4: 突き合わせ（GAP 候補の判定）'
assert_file_contains "(C) カテゴリ側からの列挙が唯一の検出経路だと説明している" "$SKILL_FILE" \
  'これが「テストが1件も無い公開面」を見つけられる唯一の経路である'
assert_file_contains "(C) GAP 種別: テストが無い" "$SKILL_FILE" '`kind: "no_test"`'
assert_file_contains "(C) GAP 種別: テストはあるが担保していない" "$SKILL_FILE" '`kind: "vacuous_test"`'
assert_file_contains "(C) すべて vacuous の場合だけ GAP とする" "$SKILL_FILE" \
  '**そのすべてが `assertion: "vacuous"`**'
# 診断は全量。差分に絞ると「差分に現れない未担保公開面」が原理的に落ちる。
assert_file_contains "(C) 診断が全量であることを明記している" "$SKILL_FILE" \
  '**診断は常に全量で行います。**'
assert_file_contains "(C) 出力がトリアージ前提の候補だと明記している" "$SKILL_FILE" \
  '**GAP は「確定した不足」ではなく「トリアージ対象の候補」です。**'
# 精度の緩さを、検査していない範囲の隠蔽に流用させない（この2つは別物）。
assert_file_contains "(C) 精度の緩さが未解析の隠蔽に流用されないよう限定している" "$SKILL_FILE" \
  '**ただし、これは判定の当たり外れの話であり、「検査していない範囲を検査済みとして出してよい」ことは意味しません。**'

echo ""
echo "=== (D) 読み書きしない契約が禁止パターンの集合で守られている ==="

# 「1つの文字列だけを拒否する」検査は、別の言い回しで書き込みを指示されたら素通りする。
# ここでは (1) 禁止の明示 (2) 書き込み・起票・台帳を指示しうる表現の不在 の両方を見る。
assert_file_contains "(D) ファイルを書かないと明記している" "$SKILL_FILE" \
  '- **ファイルの生成・書き込み**（診断結果もファイルには書き出さず、最終応答に出す）'
assert_file_contains "(D) Issue を起票しないと明記している" "$SKILL_FILE" \
  'コミット・ブランチ操作・PR 作成・**Issue 起票**'
assert_file_contains "(D) 報告先が最終応答だと明記している" "$SKILL_FILE" \
  '**ファイルには書き出さない。**'
assert_file_contains "(D) エージェント側もファイルを変更しないと明記している" "$AGENT_FILE" \
  '**あなたはファイルを一切変更しません。**'

# 書き込み・起票・台帳生成を指示しうる表現が本文に無いこと（言い回しを変えた指示の混入を検出）。
for f in "$SKILL_FILE" "$AGENT_FILE"; do
  short="$(basename "$f")"
  for forbidden in 'Write ツール' 'Write で' 'docs/guarantees' '.draft' 'gh issue create' 'gh pr create' \
                   'git commit' 'git add' 'へ書き出す' 'を新規作成する' 'を追記する'; do
    assert_file_lacks "(D) ${short} に書き込み系の指示が無い: ${forbidden}" "$f" "$forbidden"
  done
done

# エージェントの許可ツールが読み取り専用であること（散文の禁止だけに頼らない）
agent_tools="$(grep -m1 '^tools:' "$AGENT_FILE")"
assert_eq "(D) エージェントの tools 行を取り出せる" "true" \
  "$(if [ -n "$agent_tools" ]; then echo true; else echo false; fi)"
assert_eq "(D) エージェントの tools は読み取り専用（Read, Glob, Grep）" "tools: Read, Glob, Grep" "$agent_tools"

echo ""
echo "=== (E) 機械可読契約が未解析を「0件・正常」へ丸めない ==="

for step_field in test_enumeration surface_enumeration behavior_extraction gap_detection; do
  assert_file_contains "(E) 工程ごとの status が在る: ${step_field}" "$SKILL_FILE" "\"${step_field}\""
done

assert_file_contains "(E) 未解析の工程が産む値を null にする規約が在る" "$SKILL_FILE" \
  '**未解析の工程が産む値は `null` にする（`0` にしない）。**'
# 未解析時に null にすべきフィールドを**個別に**固定する（`counts.gaps` だけを直す片手落ちを防ぐ）。
for nullable in 'counts.gaps' 'counts.gaps_no_test' 'counts.gaps_vacuous_test' 'counts.covered_elements' \
                'counts.unmatched_public_behaviors' 'steps.gap_detection.elements_checked' \
                'counts.uncertain_behaviors' 'counts.internal_behaviors'; do
  assert_file_contains "(E) 未解析時に null にする対象へ含まれている: ${nullable}" "$SKILL_FILE" "\`${nullable}\`"
done

# 等式は「その工程を実行したとき」だけ成立する。実行していない工程へ等式を要求すると、
# 検査していない要素を「checked」と報告するしかなくなる（未解析の隠蔽）。
assert_file_contains "(E) 等式の検算を実行した工程に限定している" "$SKILL_FILE" \
  '**等式の検算は、その工程を実行したときだけ行う**（`not_analyzed` の工程に対して等式を要求しない）'
assert_file_contains "(E) 抽出の等式に適用条件が付いている" "$SKILL_FILE" \
  '`behavior_extraction` が `analyzed` / `partial` のとき: `files_analyzed` ＋ `failed` の件数 ＝ `files_total`'
assert_file_contains "(E) 突き合わせの等式に適用条件が付いている" "$SKILL_FILE" \
  '`gap_detection` が `analyzed` / `partial` のとき: Step 4 手順3 の2つの等式'
assert_file_contains "(E) 要素の勘定が合うことの不変条件が在る" "$SKILL_FILE" \
  '**`gaps` の件数 ＋ `covered_elements` ＋ 要人間判定へ回した要素の件数 ＝ `elements_checked`**'
# 「列挙できなかった」と「列挙して0件だった」を件数側でも取り違えないこと。
assert_file_contains "(E) 列挙0件と列挙不能を件数で区別している" "$SKILL_FILE" \
  '`no_test_files_found` は列挙自体は実行できているため `files_total` は `0` と書く'

assert_file_contains "(E) 総合状態は最悪値であると定めている" "$SKILL_FILE" \
  '4工程の `status` のうち**最も悪いもの**'
assert_file_contains "(E) 個別工程の未解析を全体の analyzed へ丸めないと明記している" "$SKILL_FILE" \
  '**個別工程の未解析を全体の `analyzed` へ丸めない**'
# 要人間判定を最終判定へ接続する（判断が付かない項目が残る状態を「全件検査済み」と読ませない）
assert_file_contains "(E) 要人間判定が非空なら analyzed にしない" "$SKILL_FILE" \
  '**`human_review_required` が非空なら `analyzed` にしない（最低でも `partial`）**'

# 空集合での全称が空虚に真になる経路を塞いでいること
assert_file_contains "(E) 突き合わせの前提条件（両集合が空でない）が在る" "$SKILL_FILE" \
  '**GAP 候補も件数も出力しない**'
assert_file_contains "(E) 空虚に真になることを根拠にしている" "$SKILL_FILE" \
  '**判定の全件が空虚に真**'
assert_file_contains "(E) 全カテゴリ analyzed かつ要素0件を analyzed にしない" "$SKILL_FILE" \
  '**「全カテゴリ analyzed かつ要素0件」を `analyzed` にしないこと**'
assert_file_contains "(E) テスト列挙0件から GAP を出さない" "$SKILL_FILE" \
  '**この状態から GAP 候補を出さない**'
assert_file_contains "(E) public が0件のときの全件 GAP を無説明で出さない" "$SKILL_FILE" \
  '**全件 GAP という結果を根拠の説明なしに出さない**'

# 不完全さの誤差の向き（過剰／過少）を「下限」で一括りにしない
assert_file_contains "(E) 誤検出の向き（過剰）を明記している" "$SKILL_FILE" \
  '**誤検出（過剰）**。見ていないテストが担保している公開面が GAP 候補に紛れ込む'
assert_file_contains "(E) 検出漏れの向き（過少）を明記している" "$SKILL_FILE" \
  '**検出漏れ（過少）**。列挙できなかったカテゴリの GAP は最初から現れない'
assert_file_contains "(E) status の引き下げが一方向であると明記している" "$SKILL_FILE" \
  'ここで `analyzed` へ戻さない（引き下げは一方向）'

echo ""
echo "=== (F) 定期実行の呼び出し元が必要とする3点が出る ==="

assert_file_contains "(F) 呼び出し元向けの対応表が在る" "$SKILL_FILE" \
  '| 呼び出し元が必要とするもの | 本スキルの出力 |'
assert_file_contains "(F) 工程ごとの解析状態を出す" "$SKILL_FILE" \
  '| 工程ごとの解析状態（解析済み／部分／未解析） |'
assert_file_contains "(F) 検出件数を出す" "$SKILL_FILE" '| 検出件数 |'
assert_file_contains "(F) 要人間判定の有無を出す" "$SKILL_FILE" '| 要人間判定の有無 |'
assert_file_contains "(F) 変換は呼び出し元の責務だと切っている" "$SKILL_FILE" \
  '**呼び出し元が使う中立形式への変換は呼び出し元の責務**であり、本スキルは変換先の形式を知らない'

echo ""
echo "=== (G) fan-out の規律 ==="

assert_file_contains "(G) 非信頼データをデリミタで分離する規約が在る" "$SKILL_FILE" \
  '---"DATA-START"---'
assert_file_contains "(G) テストコード本文をプロンプトへ埋め込まない" "$SKILL_FILE" \
  '**テストコード本文をプロンプトに埋め込まない**'
assert_file_contains "(G) チャンクサイズと逐次バリアが定義されている" "$SKILL_FILE" \
  'fan-out は **10件ずつ**のチャンクに区切り'
# 件数一致だけの join は、別のパスが返っても取りこぼしを検出できない（同一性を見ない検査）
assert_file_contains "(G) 完全性 join をパスの一致で行う" "$SKILL_FILE" \
  '**件数の一致だけを根拠にしない**'
assert_file_contains "(G) 委譲先が claude-harness 名前空間で指定されている" "$SKILL_FILE" \
  "subagent_type: 'claude-harness:surface-auditor'"

echo ""
echo "=== (H) 抽出エージェントの契約 ==="

assert_file_contains "(H) 解析済みと未解析を別状態で返させている" "$AGENT_FILE" \
  '**「正常に解析して振る舞い0件」と「解析できなかった」は必ず別状態で返してください。**'
assert_file_contains "(H) 振る舞い0件でも analyzed とする" "$AGENT_FILE" \
  '**振る舞いが0件でも `analyzed`**'
assert_file_contains "(H) 部分列挙を analyzed へ切り上げない" "$AGENT_FILE" \
  '`status` を `analyzed` に切り上げない'
assert_file_contains "(H) 全ファイルを1件ずつ返させている" "$AGENT_FILE" \
  '**`files` には渡された全ファイルを必ず1件ずつ含めてください**'
assert_file_contains "(H) assertion を全件で返させている" "$AGENT_FILE" \
  '- `assertion`: `"asserted"` | `"vacuous"`（**全件で必ず返す**。省略しない）'
assert_file_contains "(H) vacuous の定義が限定列挙である" "$AGENT_FILE" \
  '次の**いずれかに明確に当てはまる**場合のみ'
assert_file_contains "(H) 判断が付かないときは asserted に倒す" "$AGENT_FILE" \
  '**判断が付かないときは `asserted` にしてください**'
assert_file_contains "(H) 迷ったら uncertain にする" "$AGENT_FILE" \
  '**迷ったらどちらかへ倒さず `uncertain`**'
assert_file_contains "(H) 空配列を「調べられなかった」に使わせない" "$AGENT_FILE" \
  '**空配列は「調べた結果なかった」を意味するものとしてのみ返し、「調べられなかった」には使わない**'

echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do
    echo "  - ${t}"
  done
  exit 1
fi
exit 0
