#!/bin/bash
# test-define-feature-gdd.sh
# GDD P3・define-feature 系統（機能仕様テンプレートの「宣言予定の保証」節・完了報告への
# 退役の案内。Issue #158・docs/gdd-design-draft.md §5.2 の GDD 部分）の回帰テスト。3部構成:
#
#  (A) 統合が依存するスクリプト契約の回帰テスト
#      /define-feature の SKILL.md は detect-dev-phase.sh の exit code と phase の語彙に
#      依存して分岐する。ここでは散文が前提にしている語彙（gdd / sdd / invalid、exit 0/1）を
#      フィクスチャで固定する。スクリプト単体の網羅は test-detect-dev-phase.sh の担当であり、
#      ここでは重複させない。
#
#  (B) SKILL.md / 参照ファイル / テンプレートの契約文（正準文）の存在検査と cross-file 逐語照合
#      フェーズ分岐・「宣言予定の保証」節の書式・保証 ID の採番禁止・退役の案内は
#      skills/define-feature 配下の手順として実装されている（コード側の強制ではない）ため、
#      正準文が逐語で存在することを grep で検査し、手順のドリフト（更新漏れ・緩和）を機械検出
#      する（test-create-ticket-gdd-gate.sh / test-para-impl-gdd-gate.sh と同じ方式）。
#      共有する文法（フェーズ判定の定型文・約束文の形・公開面の1問・AC 対応注記）は
#      正本側のファイルとの逐語照合で「同じものを2つの規則で読まない」ことを固定する。
#
#  (C) 構造不変条件と受理方向テスト
#      「宣言予定の保証」の見出しが下流 /create-ticket の保証節識別（フェンス外の
#      `## 保証` で始まる H2・接頭辞一致）と衝突しないこと（衝突すると要件モードが
#      duplicate_guarantee_section で Issue 作成を中断する）を、下流の識別規則の参照実装で
#      「生成側の正規形が受理される」方向と「衝突形なら検出される」方向の両方から検査する。
#
# 実行方法: bash scripts/tests/test-define-feature-gdd.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # 正準文・フィクスチャ内のバッククォートは Markdown のリテラル
# （参照ファイルの逐語検査対象）であり、シェル展開を意図していない
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DETECT_SCRIPT="${REPO_ROOT}/scripts/detect-dev-phase.sh"
EXTRACT_SCRIPT="${REPO_ROOT}/scripts/extract-acceptance-criteria.sh"
SKILL_FILE="${REPO_ROOT}/skills/define-feature/SKILL.md"
REF_FILE="${REPO_ROOT}/skills/define-feature/references/planned-guarantees.md"
TPL_FILE="${REPO_ROOT}/skills/define-feature/templates/feature-spec.md"
# 下流の消費側（機能仕様を逐語転記し保証節を組み立てる側）。書式の食い違いを cross-file で検出する。
CONSUMER_FILE="${REPO_ROOT}/skills/create-ticket/references/guarantee-section.md"
# 下流の消費側2（Issue の保証節の AC 対応注記を機械的に読む側）。
GATE_FILE="${REPO_ROOT}/skills/para-impl/references/guarantee-gate.md"
# 他の適用先（定型文の逐語一致の比較対象）。
PARA_SKILL_FILE="${REPO_ROOT}/skills/para-impl/SKILL.md"
# 規律の正本。
STRATEGY_FILE="${REPO_ROOT}/docs/ai-driven-development-strategy.md"
DRAFT_FILE="${REPO_ROOT}/docs/gdd-design-draft.md"
AC_SPEC_FILE="${REPO_ROOT}/scripts/specs/extract-acceptance-criteria.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "NG - jq が見つからないためテストを実行できません（検査不能を pass にはしない）" >&2
  exit 1
fi

for f in "$DETECT_SCRIPT" "$EXTRACT_SCRIPT" "$SKILL_FILE" "$REF_FILE" "$TPL_FILE" "$CONSUMER_FILE" "$GATE_FILE" "$PARA_SKILL_FILE" "$STRATEGY_FILE" "$DRAFT_FILE" "$AC_SPEC_FILE"; do
  if [ ! -r "$f" ]; then
    echo "NG - 検査対象ファイルを読めません（検査不能を pass にはしない）: ${f}" >&2
    exit 1
  fi
done

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

assert_eq() {
  local description="$1"
  local expected="$2"
  local actual="$3"

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

# 指定ファイルに正準文（固定文字列）が逐語で存在することを検査する。
assert_file_contains() {
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

assert_file_not_contains() {
  local description="$1" file="$2" phrase="$3"
  if grep -qF -- "$phrase" "$file"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       file:   ${file}"
    echo "       phrase: ${phrase}"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  fi
}

assert_skill_contains() { assert_file_contains "$1" "$SKILL_FILE" "$2"; }
assert_ref_contains() { assert_file_contains "$1" "$REF_FILE" "$2"; }
assert_tpl_contains() { assert_file_contains "$1" "$TPL_FILE" "$2"; }

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

# ---------------------------------------------------------------------------
# 下流 /create-ticket の保証節識別の参照実装
# （正本: docs/ai-driven-development-strategy.md 5.3「保証節の識別規則」——
#   コードフェンスの外にある `## 保証` で始まる H2 見出しを接頭辞一致で数える。
#   フェンスの扱いは guarantee-section.md 共通-2 (a) と同じ:
#   ``` / ~~~・行頭スペース3個まで・閉じは同記号かつ開始以上の長さかつ情報文字列なし）
# ---------------------------------------------------------------------------
DF_FENCE_RE='^[[:space:]]{0,3}(`{3,}|~{3,})[[:space:]]*(.*)$'
DF_GUARANTEE_H2_RE='^##[[:space:]]+保証'

df_count_guarantee_h2() {
  local body="$1"
  local line marker_run marker fence_info
  local fence_marker="" fence_len=0
  local count=0

  body="${body//$'\r'/}"

  while IFS= read -r line; do
    if [[ "$line" =~ $DF_FENCE_RE ]]; then
      marker_run="${BASH_REMATCH[1]}"
      fence_info="${BASH_REMATCH[2]}"
      marker="${marker_run:0:1}"
      if [ -z "$fence_marker" ]; then
        fence_marker="$marker"
        fence_len="${#marker_run}"
      elif [ "$fence_marker" = "$marker" ] && [ "${#marker_run}" -ge "$fence_len" ] && [ -z "$fence_info" ]; then
        fence_marker=""
        fence_len=0
      fi
      continue
    fi
    [ -n "$fence_marker" ] && continue

    if [[ "$line" =~ $DF_GUARANTEE_H2_RE ]]; then
      count=$((count + 1))
    fi
  done <<<"$body"

  echo "$count"
}

# ---------------------------------------------------------------------------
echo "=== (A) スクリプト契約: SKILL.md が依存する detect-dev-phase の語彙 ==="
# ---------------------------------------------------------------------------

fixture_dir="${TMP_ROOT}/phase-fixtures"
mkdir -p "$fixture_dir"

cat >"${fixture_dir}/CLAUDE-gdd.md" <<'EOF'
# プロジェクト

## 開発フェーズ

- **フェーズ**: GDD期
- 駆動文書: docs/guarantees.md
EOF

cat >"${fixture_dir}/CLAUDE-nosection.md" <<'EOF'
# プロジェクト

## 概要

フェーズ宣言なし。
EOF

cat >"${fixture_dir}/CLAUDE-invalid.md" <<'EOF'
# プロジェクト

## 開発フェーズ

- **フェーズ**: {DEV_PHASE}
EOF

out="$(bash "$DETECT_SCRIPT" "${fixture_dir}/CLAUDE-gdd.md" 2>/dev/null)"
rc=$?
assert_eq "(A-1) GDD 宣言は exit 0" "0" "$rc"
assert_eq "(A-1) GDD 宣言は phase=gdd" "gdd" "$(printf '%s' "$out" | jq -r '.phase')"

out="$(bash "$DETECT_SCRIPT" "${fixture_dir}/CLAUDE-nosection.md" 2>/dev/null)"
rc=$?
assert_eq "(A-2) 宣言なしは exit 0（後方互換で sdd）" "0" "$rc"
assert_eq "(A-2) 宣言なしは phase=sdd" "sdd" "$(printf '%s' "$out" | jq -r '.phase')"

out="$(bash "$DETECT_SCRIPT" "${fixture_dir}/CLAUDE-invalid.md" 2>/dev/null)"
rc=$?
assert_eq "(A-3) 未置換プレースホルダは exit 1（sdd に読み替えない）" "1" "$rc"
assert_eq "(A-3) 未置換プレースホルダは phase=invalid" "invalid" "$(printf '%s' "$out" | jq -r '.phase')"

# (A-4) 引数なしの既定解決は cwd の CLAUDE.md を最優先で読むため、フェーズ節を持たない
# サブディレクトリ CLAUDE.md がルートの GDD 宣言を影に隠す（SKILL.md Step 1.5 が
# 「ルートの CLAUDE.md を明示引数で渡す」と規定する根拠の実演。sdd は正常系 exit 0 で
# 返るため、規定なしではスキップが黙って起こる）。
shadow_root="${TMP_ROOT}/shadow-repo"
shadow_sub="${shadow_root}/subdir"
mkdir -p "$shadow_sub"
cp "${fixture_dir}/CLAUDE-gdd.md" "${shadow_root}/CLAUDE.md"
cp "${fixture_dir}/CLAUDE-nosection.md" "${shadow_sub}/CLAUDE.md"

out="$(cd "$shadow_sub" && bash "$DETECT_SCRIPT" 2>/dev/null)"
rc=$?
assert_eq "(A-4) 引数なし実行はサブディレクトリの CLAUDE.md に隠され sdd を返す（危険側の実演）" \
  "0:sdd:no_phase_section" "${rc}:$(printf '%s' "$out" | jq -r '.phase'):$(printf '%s' "$out" | jq -r '.reason')"

out="$(cd "$shadow_sub" && bash "$DETECT_SCRIPT" "${shadow_root}/CLAUDE.md" 2>/dev/null)"
rc=$?
assert_eq "(A-4) ルートの CLAUDE.md を明示引数で渡すと gdd を正しく返す（規定形）" \
  "0:gdd" "${rc}:$(printf '%s' "$out" | jq -r '.phase')"

# (A-5) AC 通し番号の採番規則: 参照ファイルの「要点の転記」が主張する規則
# （列0のチェックリスト行のみ・「## 完了条件」も同一連番）がスクリプトの実挙動と
# 一致することをフィクスチャで固定する（散文とスクリプトの2規則化の検出）。
ac_fixture="$(cat <<'EOF'
## 受入基準

- [ ] 親A
  - [ ] 子A-1
- [ ] B

## 完了条件

- [ ] C
EOF
)"
ac_out="$(printf '%s\n' "$ac_fixture" | bash "$EXTRACT_SCRIPT" --stdin 2>/dev/null)"
assert_eq "(A-5) ネスト行は数えない・完了条件も同一連番（件数=3）" "3" \
  "$(printf '%s' "$ac_out" | jq -r '.criteria | length')"
assert_eq "(A-5) 2番目の対象行はネストを飛ばした B（AC-2）" "AC-2:B" \
  "$(printf '%s' "$ac_out" | jq -r '.criteria[1] | "\(.id):\(.text)"')"
assert_eq "(A-5) 「## 完了条件」配下の C は AC-3" "AC-3:C" \
  "$(printf '%s' "$ac_out" | jq -r '.criteria[2] | "\(.id):\(.text)"')"

# ---------------------------------------------------------------------------
echo ""
echo "=== (B-1) SKILL.md: フェーズ判定の定型文と分岐の正準文 ==="
# ---------------------------------------------------------------------------

phase_boilerplate='フェーズは必ず `claude-harness-run detect-dev-phase` の出力だけで判定し、`CLAUDE.md` を自分で grep しないこと（判定規約の重複実装を防ぐため）'
assert_skill_contains "SKILL.md が定型文の中核文を持つ" "$phase_boilerplate"
assert_file_contains "戦略ドキュメント（定型文の正本）にも同じ文が存在する" "$STRATEGY_FILE" "$phase_boilerplate"

# 定型文の行全体が他の適用先（para-impl）と逐語一致していること（定型文は「そのままコピー」が規約）。
skill_bp_line="$(grep -F '> **開発フェーズの判定（重要）**' "$SKILL_FILE")"
para_bp_line="$(grep -F '> **開発フェーズの判定（重要）**' "$PARA_SKILL_FILE")"
assert_eq "(B-1) 定型文の行全体が para-impl SKILL.md と逐語一致する" "true" \
  "$([ -n "$skill_bp_line" ] && [ "$skill_bp_line" = "$para_bp_line" ] && echo true || echo false)"

assert_skill_contains "SKILL.md に定型文の正本コメントがある" \
  '<!-- 正本: docs/ai-driven-development-strategy.md 5.2 / docs/plugin-path-conventions.md -->'

# 判定入力の基準（本スキル固有の判断）が根拠付きで記録されている。
assert_skill_contains "SKILL.md が判定器への入力をリポジトリルートの明示引数と規定する" \
  '**判定器への入力は「手元 checkout のリポジトリルートの `CLAUDE.md`」を明示引数で渡す（本スキル固有・重要）**'
assert_skill_contains "SKILL.md が手元基準の根拠（到達先 base が存在しない）を明記する" \
  '「実装が到達する base」がまだ存在しない（対象 Issue・base ブランチとも未確定）'
assert_skill_contains "SKILL.md がルート明示の根拠（cwd 優先解決による陰り）を明記する" \
  'リポジトリルートの GDD 宣言が影に隠れて `sdd`（`no_phase_section`）と**正常系のまま誤判定され、GDD の追加挙動が黙ってスキップされる**'
assert_skill_contains "SKILL.md がルート解決の方法を規定する" \
  '`git rev-parse --show-toplevel` でリポジトリルートを解決する。解決できない場合（git リポジトリでない等）のみ引数なしで実行し'
assert_skill_contains "SKILL.md がルートに CLAUDE.md が無い場合を no_claude_md と同義に規定する" \
  '判定器の `no_claude_md` と同じ意味（宣言なし＝`sdd`）として扱い、従来どおり進む'
assert_skill_contains "SKILL.md が明示引数のランチャー実行形を規定する" \
  'claude-harness-run detect-dev-phase "<リポジトリルート>/CLAUDE.md"'
assert_skill_contains "SKILL.md が判定器を迂回しない原則を維持する" \
  '**判定器を迂回しない**——フェーズの解釈は常にスクリプトの出力のみであり、ここで決めるのは判定器への入力だけ'

# フェーズ別の分岐（default-OFF・invalid の停止・gdd の参照ファイル）。
assert_skill_contains "SKILL.md: sdd は追加挙動なし（参照ファイルも Read しない）" \
  '追加挙動なし。以降の手順は従来どおり行う（GDD の参照ファイルも Read しない）'
assert_skill_contains "SKILL.md: gdd は参照ファイルを Read して上乗せする" \
  '${CLAUDE_PLUGIN_ROOT}/skills/define-feature/references/planned-guarantees.md'
assert_skill_contains "SKILL.md: invalid・実行不能は作成せず停止する" \
  '機能仕様ドキュメントを作成せず停止し、要人間判定として報告する'

# Step 6 / Step 7 の GDD 分岐（sdd の不変を明記）。
assert_skill_contains "SKILL.md Step 6: GDD期のみセクションを残して作成する" \
  'テンプレートの「## 宣言予定の保証」セクションを削除せずに残し、参照ファイル `references/planned-guarantees.md`（節-1）に従って作成する'
assert_skill_contains "SKILL.md Step 6: sdd ではセクションごと削除して従来どおり" \
  '当該セクションは「該当しないセクション」としてセクションごと削除する（従来どおりの成果物になる）'
assert_skill_contains "SKILL.md Step 7: GDD期のみ退役の1行を加える" \
  'リリース後にこの機能仕様の退役（台帳・ADR へ吸収して削除）が待っている旨の1行を加える（書式は参照ファイル `references/planned-guarantees.md`（節-2）が正本）'
assert_skill_contains "SKILL.md Step 7: sdd では報告は従来のみ" \
  '`sdd`（フェーズ宣言なしを含む）では本項を実行せず、報告は上記のみとする'

# 戦略ドキュメント側の適用状態。
assert_file_contains "戦略ドキュメントの適用先に /define-feature が適用済みとして登録されている" "$STRATEGY_FILE" \
  '`/define-feature`（適用済み）'
assert_file_not_contains "戦略ドキュメントに define-feature 未導入の記述が残っていない" "$STRATEGY_FILE" \
  '（`/define-feature` の GDD 挙動）は未導入'
assert_file_contains "設計ドラフトのステータスが P3 全系統実装済みに更新されている" "$DRAFT_FILE" \
  'P3（§6・Issue #158）は**全系統実装済み**'
assert_file_not_contains "設計ドラフトに define-feature 未着手の記述が残っていない" "$DRAFT_FILE" \
  'define-feature（§5.2 の GDD 部分）は未着手'

# 掃引の再発防止（範囲限定）: 「CLAUDE.md の宣言が GDD期/SDD期」型の既知の1言い回しの不在
# だけを検査する（直読み表現全般の網羅ではない。直読みの一次防衛は上の定型文の逐語 assert と、
# リポジトリ横断の同型掃引 test-create-ticket-gdd-gate.sh (A-13) が担う。パターンを広げると
# 正当な記述——定型文自身の「CLAUDE.md を自分で grep しないこと」やスクリプト既定動作の説明——を
# 誤検出するため、語彙は広げず assert 名を検査範囲に合わせて縮小した）。
leak_re='CLAUDE\.md (の)?(フェーズ)?宣言が (GDD期|SDD期)'
phase_grep_leak="$(grep -rn -E "$leak_re" "${REPO_ROOT}/skills/define-feature" || true)"
assert_eq "(B-1) define-feature 配下に「CLAUDE.md の宣言が GDD期/SDD期」型の直読み表現が無い" "" "$phase_grep_leak"
# 検出器の自己検査（パターンが壊れて全件素通り＝空虚な真になっていないこと）。
if printf '%s\n' 'CLAUDE.md のフェーズ宣言が GDD期 なら' | grep -qE "$leak_re"; then
  leak_detector="works"
else
  leak_detector="broken"
fi
assert_eq "(B-1) 直読み表現の検出器が既知の言い回しに一致する（自己検査）" "works" "$leak_detector"

# ---------------------------------------------------------------------------
echo ""
echo "=== (B-2) テンプレート: 「宣言予定の保証」節の正準文 ==="
# ---------------------------------------------------------------------------

assert_tpl_contains "テンプレートに gdd 限定の条件コメントがある" \
  '開発フェーズの判定が gdd のときのみ、次の「## 宣言予定の保証」セクションを残して作成する'
assert_tpl_contains "テンプレートに sdd での削除指示がある" \
  '判定が sdd（フェーズ宣言なしを含む）のときはこのセクションをセクションごと削除する。'
assert_tpl_contains "テンプレートが書き方の正本（参照ファイル）を指す" \
  'skills/define-feature/references/planned-guarantees.md'
assert_tpl_contains "テンプレートが材料としての位置づけと採番の下流委譲を明記する" \
  '保証 ID の採番・公開面の最終判定・裁可は `/create-ticket` 以降の手順が担う'
assert_tpl_contains "テンプレートが自動転記・引き継ぎ機構の不在を明記する（下流挙動の過剰主張をしない）" \
  '**参照できる材料**（自動転記・引き継ぎの機構は無い）'
assert_tpl_contains "テンプレートが保証 ID の記入を禁止する" \
  '**保証 ID（`G-...`）はここに書かない**'
assert_tpl_contains "テンプレートの行書式が AC 対応注記を持つ" \
  '- {約束文}（受入基準 AC-{通し番号} に対応）'
assert_tpl_contains "テンプレートに判定保留候補の行書式がある" \
  '- 判定保留候補: {公開面か内部実装か判断が付かなかった振る舞い}（{迷った理由}）'
assert_tpl_contains "テンプレートに0件時の「- なし」規約（削除と区別）がある" \
  '確定した公開面（約束文の行）が無い場合は `- なし` の行を書く（セクションは削除しない。「調べた結果0件」と「調べていない」を区別するため）。'
assert_tpl_contains "テンプレートが「- なし」と判定保留候補の共存（併記）を規定する" \
  '判定保留候補の行がある場合も `- なし` を省略せず併記する'

# 実 ID がテンプレートに現れない（採番の単一経路をテンプレートが破らない）。
tpl_real_ids="$(grep -n -E 'G-[0-9]+-[0-9]+' "$TPL_FILE" || true)"
assert_eq "(B-2) テンプレートに実在形式の保証 ID（G-数字-数字）が無い" "" "$tpl_real_ids"

# ---------------------------------------------------------------------------
echo ""
echo "=== (B-3) 参照ファイル: 手順の正準文と cross-file 逐語照合 ==="
# ---------------------------------------------------------------------------

assert_ref_contains "参照ファイルに前提（フェーズ判定は SKILL.md 側で完了）の注記がある" \
  '**`sdd`（フェーズ宣言なしを含む）で本ファイルの手順を一切実行しない規律と、`invalid`・判定不能で中断する規律は SKILL.md が正本**'
assert_ref_contains "参照ファイルが D-10（短命な作業文書としての再定義）を持つ" \
  '「リリースまでの**短命な作業文書**」'
assert_file_contains "戦略ドキュメント（位置づけの正本）にも短命な作業文書の再定義がある" "$STRATEGY_FILE" \
  '短命な作業文書'
assert_ref_contains "参照ファイルに節-1（節の作成）がある" '### 節-1. 「## 宣言予定の保証」節の作成（Step 6）'
assert_ref_contains "参照ファイルに節-2（完了報告への追記）がある" '### 節-2. 完了報告への追記（Step 7）'

# 見出しの衝突回避（下流 duplicate_guarantee_section との接続）。
assert_ref_contains "参照ファイルが見出しの完全一致形を規定する" \
  '節の見出しは **`## 宣言予定の保証`**（完全一致）とする。'
assert_ref_contains "参照ファイルが「## 保証」で始まる見出しの禁止を規定する" \
  '**機能仕様ドキュメントのどこにも、コードフェンスの外に「`## 保証` で始まる H2 見出し」を書かないこと**'
assert_ref_contains "参照ファイルが下流の中断（duplicate_guarantee_section）へ接続する" \
  '**Issue を作成せずに中断する**（`duplicate_guarantee_section`'
assert_file_contains "下流（guarantee-section.md）に同じ中断理由コードが定義されている" "$CONSUMER_FILE" \
  '| `duplicate_guarantee_section` | 要件モード |'
assert_ref_contains "参照ファイルが接頭辞一致の識別（読む側の規則）を明記する" \
  '読む側は完全一致ではなく**接頭辞一致**で識別する'
assert_ref_contains "参照ファイルが識別規則の正本を HTML コメントで指す（実行時ファイルの docs/ 参照規約）" \
  '<!-- 識別規則の正本: docs/ai-driven-development-strategy.md 5.3「保証節の識別規則」 -->'

# 約束文の形: 生成側（本参照ファイル）と消費側（guarantee-section.md 要件-1）で逐語一致。
promise_grammar='約束文の形（「何が・どういう条件で・どうなる」の1文）'
assert_ref_contains "参照ファイルが約束文の形を持つ" "$promise_grammar"
assert_file_contains "消費側（guarantee-section.md 要件-1）にも同じ約束文の形が存在する" "$CONSUMER_FILE" "$promise_grammar"

# 公開面の1問: 正本（戦略ドキュメント 5.3）と逐語一致。
public_question='その振る舞いが変わったとき、リポジトリの外の誰か（エンドユーザー・他システム・他リポジトリ・運用者）が気付き得るか'
assert_ref_contains "参照ファイルが公開面の1問を持つ" "$public_question"
assert_file_contains "戦略ドキュメント（線引きの正本）にも同じ1問が存在する" "$STRATEGY_FILE" "$public_question"
assert_file_contains "消費側（guarantee-section.md 共通-3）にも同じ1問が存在する" "$CONSUMER_FILE" "$public_question"

# AC 対応注記: 採番規則の正本参照・要点の逐語転記・複数 AC 列挙形が下流の受理形と一致。
assert_ref_contains "参照ファイルが AC 採番規則の正本（スクリプト入出力仕様）を指す" \
  '**採番規則の正本はスクリプトの入出力仕様 `scripts/specs/extract-acceptance-criteria.md`**'
# 要点の転記は正本と逐語で一致させる（散文とスクリプトで2規則を作らない。実挙動は A-5 で固定）。
ac_scope_grammar='「## 受入基準」または「## 完了条件」セクション配下の `- [ ]` / `- [x]` チェックリスト行（インデント付きのネスト行は対象外）'
assert_ref_contains "参照ファイルの採番対象（列0のみ・完了条件を含む）が正本と逐語一致する" "$ac_scope_grammar"
assert_file_contains "AC 採番規則の正本にも同じ採番対象の記述が存在する" "$AC_SPEC_FILE" "$ac_scope_grammar"
ac_serial_grammar='両セクションが同一本文に存在する場合は連番で通しIDを振る'
assert_ref_contains "参照ファイルの通し連番規則が正本と逐語一致する" "$ac_serial_grammar"
assert_file_contains "AC 採番規則の正本にも同じ通し連番規則が存在する" "$AC_SPEC_FILE" "$ac_serial_grammar"
ac_multi='（受入基準 AC-1, AC-2 に対応）'
assert_ref_contains "参照ファイルの複数 AC 列挙の例が下流の受理形と同形" "$ac_multi"
assert_file_contains "下流（guarantee-gate.md）が同じ複数 AC 列挙形を受理する" "$GATE_FILE" "$ac_multi"
assert_ref_contains "参照ファイルが受入基準の編集時に注記の振り直しを義務付ける" \
  '**受入基準・完了条件のチェックリストを追加・削除・並べ替え・ネスト変更したら、この注記の番号を必ず振り直す**'

# 採番の単一経路・迷いの扱い・0件の扱い・機械処理対象外の明示。
assert_ref_contains "参照ファイルが保証 ID の記入を禁止し採番の単一経路を指す" \
  '**保証 ID（`G-...`）を書かない**。採番は宣言元 Issue の裁可が唯一の経路であり（採番の単一経路）'
assert_ref_contains "参照ファイルが迷った場合の判定保留候補（どちらへも倒さない）を規定する" \
  '**判断に迷ったものはどちらへも倒さず**、`- 判定保留候補: {内容}（{迷った理由}）` の1行として節内に残す'
assert_ref_contains "参照ファイルが判定保留候補の自動引き継ぎ機構の不在を明記する（下流挙動を断定しない）" \
  '**材料として参照できる**が、**自動で引き継がれる機構は無い**（下流は独自に公開面判定を行う）'
assert_ref_contains "参照ファイルが節の位置づけ（参照できる材料・引き継ぎ機構なし）を明記する" \
  '**参照できる材料**である（**自動転記・引き継ぎの機構は無い**。下流は保証節を受入基準・台帳・公開面判定から独自に組み立てる規定であり'
assert_ref_contains "参照ファイルが0件時の「- なし」（削除しない・空欄にしない）を規定する" \
  '**確定した公開面（約束文の行）が1件も無い場合は `- なし` の行を書く**（節を削除しない・空欄にしない。「調べた結果0件」と「調べていない」を区別する）'
assert_ref_contains "参照ファイルが「- なし」と判定保留候補の共存（確定0件でも保留候補を削らない）を規定する" \
  '**`- なし` と判定保留候補の行は共存できる**——確定0件で迷いだけが残る場合は `- なし` と判定保留候補の両方を書く'
assert_ref_contains "参照ファイルが本節を機械処理の対象外と明示する（下流の自動読取を約束しない）" \
  'この節は下流の**機械処理の対象ではない**'

# 退役の案内（節-2）: 生成物にはプラグイン内部の docs/ パスを書かず、正本は HTML コメントで指す。
assert_ref_contains "参照ファイルに退役の1行（完了報告への追記文）がある" \
  '# 4. リリース（main 昇格）後: この機能仕様を退役する（ADR 昇格の要否判定 → 保証台帳・ADR へ吸収してファイルごと削除）'
assert_ref_contains "参照ファイルが退役行に導入先に無いパスを書かない規律を明記する" \
  '導入先プロジェクトに存在しない本プラグイン内部のドキュメントパスを報告に書かない'
assert_ref_contains "参照ファイルが退役手順の正本を HTML コメントで指す" \
  '<!-- 退役手順の正本: docs/ai-driven-development-strategy.md 5.5 手順4 -->'
assert_file_contains "戦略ドキュメント 5.5 に退役手順（手順4）が存在する" "$STRATEGY_FILE" \
  '**機能仕様の退役**: `docs/features/` の各ドキュメントを次のいずれかに片付ける。'

# ---------------------------------------------------------------------------
echo ""
echo "=== (C) 構造不変条件と受理方向テスト（下流識別規則の参照実装） ==="
# ---------------------------------------------------------------------------

# 検出器の自己検査（検出器が壊れて全件0を返す「空虚な真」を防ぐ）。
detector_hit="$(df_count_guarantee_h2 '## 保証（Guarantees）')"
assert_eq "(C-1) 検出器: フェンス外の ## 保証（Guarantees） を1件と数える" "1" "$detector_hit"
detector_prefix="$(df_count_guarantee_h2 '## 保証ポリシー')"
assert_eq "(C-1) 検出器: 接頭辞一致（## 保証ポリシー）も1件と数える" "1" "$detector_prefix"
detector_fenced="$(df_count_guarantee_h2 "$(printf '%s\n%s\n%s\n' '```markdown' '## 保証（Guarantees）' '```')")"
assert_eq "(C-1) 検出器: フェンス内の見出しは数えない" "0" "$detector_fenced"

# テンプレート自体の不変条件: フェンス外に `## 保証` で始まる H2 が無く、
# 「## 宣言予定の保証」がちょうど1つある（逐語生成された機能仕様が下流の
# duplicate_guarantee_section を構造的に踏まないこと）。
tpl_body="$(cat "$TPL_FILE")"
tpl_guarantee_h2="$(df_count_guarantee_h2 "$tpl_body")"
assert_eq "(C-2) テンプレートのフェンス外に「## 保証」で始まる H2 が無い" "0" "$tpl_guarantee_h2"
tpl_planned_count="$(grep -c '^## 宣言予定の保証$' "$TPL_FILE")"
assert_eq "(C-2) テンプレートの「## 宣言予定の保証」見出しはちょうど1つ" "1" "$tpl_planned_count"

# 受理方向: GDD期に生成される正規形の機能仕様（宣言予定の保証つき）を /create-ticket が
# 逐語転記しても、追記前チェック（フェンス外の ## 保証 で始まる H2 の不在）を通過し、
# 保証節を追記した後はちょうど1節になる。
spec_fixture="$(cat <<'EOF'
# サンプル機能

## 概要

サンプル。

## 受入基準

- [ ] POST /api/contact が JSON パース不能時に 400 を返す
- [ ] 管理画面に監査ログが表示される

## 宣言予定の保証

- POST /api/contact は JSON パース不能時に 400 と {"error":"invalid_json"} を返す（受入基準 AC-1 に対応）
- 判定保留候補: 監査ログの表示形式（他システムが読むか不明）
EOF
)"
pre_append="$(df_count_guarantee_h2 "$spec_fixture")"
assert_eq "(C-3) 正規形の機能仕様は追記前チェックを通過する（## 保証 系 H2 が0件）" "0" "$pre_append"

issue_fixture="$(printf '%s\n\n%s\n\n%s\n' "$spec_fixture" '## 保証（Guarantees）' '- なし')"
post_append="$(df_count_guarantee_h2 "$issue_fixture")"
assert_eq "(C-3) 保証節を追記した Issue 本文の保証節はちょうど1つ" "1" "$post_append"

# 拒否方向: 見出しを `## 保証（宣言予定）` に変えると接頭辞一致で衝突し、
# 追記前チェックに掛かる（見出し名の変更がなぜ禁止かの参照実装）。
# 注: bash 3.2 の ${var/pat/rep} はマルチバイト文字列の置換に失敗するため、独立フィクスチャで書く。
collide_fixture="$(cat <<'EOF'
# サンプル機能

## 受入基準

- [ ] POST /api/contact が JSON パース不能時に 400 を返す

## 保証（宣言予定）

- POST /api/contact は JSON パース不能時に 400 と {"error":"invalid_json"} を返す（受入基準 AC-1 に対応）
EOF
)"
pre_append_collide="$(df_count_guarantee_h2 "$collide_fixture")"
assert_eq "(C-4) 「## 保証」で始まる見出しに変えると追記前チェックに掛かる（1件検出）" "1" "$pre_append_collide"

# 宣言予定の保証の行はチェックボックスにしない（受入基準の通しID抽出・裁可対象と紛れない）。
assert_ref_contains "参照ファイルが行書式のチェックボックス禁止を規定する" \
  'チェックボックス（`- [ ]`）にはしない'

# ---------------------------------------------------------------------------
echo ""
echo "=== 結果 ==="
# ---------------------------------------------------------------------------

echo "pass: ${PASS_COUNT} / fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "失敗したテスト:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi
exit 0
