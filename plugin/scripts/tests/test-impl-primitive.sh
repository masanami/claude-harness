#!/bin/bash
# test-impl-primitive.sh
# `/impl` を1チケット実装フローの primitive として切り出し、`/para-impl` を fan-out に
# 徹させた構造（Issue #233）の回帰テスト。
#
# 背景: ADR 0001 決定4「賢い調整層は常に1つ」に反し、調整層が2つあった——上位層
# （claude-flywheel の run-cycle 手順2）が着手順を決め、`/para-impl` が衝突予測から
# 並列度・直列化を決めていた。結果、全体の並列度・予算を見ている主体が居らず、
# 上位層が 3 repo へ並列委譲 → 各 para-impl が N worker へ扇形展開 → 上限なしで
# 3×N エージェントが同時に走りうる状態だった。
#
# 本テストが固定する不変条件は4系統。**散文仕様は型検査が効かない**ため、
# 「正準文の逐語照合」＋「構造（節スコープ）」＋「集合の双方向一致」＋「真理値表」で守る:
#
#   (A) 正本の単一性: 実装フローの手順・分岐は runtime の `ticket` ワークフロー
#       （`runtime/workflows/ticket.yaml`）**だけ**が持つ（#299 で `/impl` は CLI を呼ぶ薄いスキルになった）。
#       旧 `/impl` の Phase 見出しがどの実行時ファイル（skills/ agents/）にも戻っていないこと（散文の
#       制御フローの再流入）と、`/impl` が `ticket` を呼ぶことを確かめる。
#   (B) `/impl` が通常のスキルであること: frontmatter のキー集合を**許可リストとの完全一致**で
#       固定する（fail-closed）。サブエージェント実行を指示するキーが将来足されたら落ちる。
#       Task ネスト深度は現行3（ticket-worker→feature-implementer→code-reviewer。CI の差し戻し）であり、
#       `/impl` をサブエージェント化すると4段目が spawn できなくなる（実測: PR 本文参照）。
#   (C) 呼び出し元の明示と接続: 単一Issue経路（リード）・並列経路（ticket-worker）の
#       双方について、`/impl` 側の経路表と**呼び出し元ファイル側の呼び出し規定**が
#       揃っていることを語彙駆動で確かめる（片側だけの記述＝接続漏れを検出）。
#   (E) 薄い `/impl` の返り方（#299・設計 §11.4 U2）: `--worktree` の経路では `review` ゲートで通常完了として
#       返し run を残す・他のゲートと失敗の写し方・CLI への版と permission mode の渡し方・合流してから返すこと。
#   (D) 並列度・直列化の決定権: `--max-parallel` の有無で決定権が分岐する規律を、
#       参照実装による**真理値表**で固定する。後方互換（引数なし＝従来どおり自分で決める）を
#       必須ケースとして含み、「上限を超える方向へ動かせる」退行と
#       「同一周のラウンドトリップ」を否定検査で塞ぐ。
#
# **節スコープで照合する理由（空虚性検査）**: ファイル全体への `grep -F` は、規定を
# 効力の無い節（禁止事項・注記・コメント）へ移設しても通ってしまう。規律は
# 「どの節に在るか」まで含めて意味を持つため、見出しで区切った**節の本文**に対して照合する。
#
# 実行方法: bash scripts/tests/test-impl-primitive.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。

# shellcheck disable=SC2016 # 正準文内のバッククォートは Markdown のリテラル
# （スキル本文の逐語検査対象）であり、シェル展開を意図していない
set -u

IMPLP_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${IMPLP_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

IMPL_FILE="skills/impl/SKILL.md"
TICKET_WF="../runtime/workflows/ticket.yaml"
PARA_FILE="skills/para-impl/SKILL.md"
STAR_FILE="skills/para-impl/references/star-parallel.md"
TW_FILE="agents/ticket-worker.md"
PRED_FILE="agents/issue-conflict-predictor.md"

for f in "$IMPL_FILE" "$PARA_FILE" "$STAR_FILE" "$TW_FILE" "$PRED_FILE" "$TICKET_WF"; do
  if [ ! -r "$f" ]; then
    echo "NG - 検査対象ファイルを読めません（検査不能を pass にはしない）: ${f}" >&2
    exit 1
  fi
done

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

assert_contains() {
  local description="$1" haystack="$2" phrase="$3"
  if printf '%s' "$haystack" | grep -qF -- "$phrase"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       phrase: ${phrase}"
  fi
}

assert_not_contains() {
  local description="$1" haystack="$2" phrase="$3"
  if printf '%s' "$haystack" | grep -qF -- "$phrase"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       禁止語が在る: ${phrase}"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  fi
}

# 見出し行（$2 に完全一致する行）から、同レベル以上の次の見出しの直前までを本文として返す。
# 見出しが無ければ空を返す（呼び出し側が「節が消えた」として落とす）。
section_body() {
  local file="$1" heading="$2"
  # 見出しレベル＝先頭の `#` の連続数。`${heading%%[! #]*}` のような glob で数えると
  # `#` の直後の空白まで数に入り、下位の小節を「次の節」と誤判定する（節が途中で切れ、
  # 節スコープ照合が空虚に落ちる）。1文字ずつ数える。
  local depth=0
  while [ "${heading:$depth:1}" = "#" ]; do
    depth=$((depth + 1))
  done
  # **見出しの一致判定に awk の `==` を使わない**: macOS 標準 awk は非 ASCII 文字列の `==` を
  # 誤って真にするため（scripts/README.md「テスト」節）、日本語見出しでは無関係な見出しにも
  # 一致してしまい、節が終わらない／存在しない見出しでも本文が返る（本テストの (0) 自己検査が
  # 実際にこれを検出した）。比較はバイト厳密な bash の文字列比較で行う。
  local inside=0 line n
  while IFS= read -r line; do
    case "$line" in
      '#'*)
        n=0
        while [ "${line:$n:1}" = "#" ]; do
          n=$((n + 1))
        done
        if [ "$inside" -eq 1 ] && [ "$n" -le "$depth" ]; then
          inside=0
        fi
        if [ "$line" = "$heading" ]; then
          inside=1
          continue
        fi
        ;;
    esac
    if [ "$inside" -eq 1 ]; then
      printf '%s\n' "$line"
    fi
  done < "$file"
  return 0
}

# 節スコープ照合の自己検査（検出器が壊れていたら以降の ok は空虚になる）
SELFCHECK_TMP="$(mktemp "${TMPDIR:-/tmp}/test-impl-primitive.XXXXXX")"
trap 'rm -f "$SELFCHECK_TMP"' EXIT
cat > "$SELFCHECK_TMP" <<'FIXTURE'
## 甲
甲の本文
### 甲の小節
小節の本文
## 乙
乙の本文
FIXTURE

echo "=== (0) 節抽出器の自己検査 ==="
assert_contains "(0) 節の本文を取れる" "$(section_body "$SELFCHECK_TMP" '## 甲')" '甲の本文'
assert_contains "(0) 下位の小節は同じ節に含まれる" "$(section_body "$SELFCHECK_TMP" '## 甲')" '小節の本文'
assert_not_contains "(0) 次の同レベル見出し以降は含まれない" "$(section_body "$SELFCHECK_TMP" '## 甲')" '乙の本文'
assert_eq "(0) 存在しない見出しは空を返す（移設を pass にしない）" "" "$(section_body "$SELFCHECK_TMP" '## 丙')"

echo ""
echo "=== (A) 実装フローの正本が runtime の ticket ワークフローちょうど1本 ==="

# 旧 /impl の Phase 見出し（散文の制御フロー）を持つ実行時ファイルが無いこと。どこかへ戻したら落ちる。
PHASE_HEADINGS=(
  '### Phase 3: ブランチ準備'
  '### Phase 4: 設計＋TDD実装＋必須ゲート＋セルフレビュー（一気通貫）'
  '### Phase 5: コミット'
  '### Phase 6: E2E実装と独立検証（E2E対象の場合）'
  '### Phase 7: プッシュ・PR作成'
  '### Phase 8: CI確認（必須ゲート）'
)
for heading in "${PHASE_HEADINGS[@]}"; do
  holders="$(grep -rlF -- "$heading" skills agents | LC_ALL=C sort | tr '\n' ',' | sed 's/,$//')"
  assert_eq "(A) 「${heading}」を持つ実行時ファイルが無い（散文の制御フローを戻さない）" "" "$holders"
done

# /impl は手順を持たず、ticket ワークフローを呼ぶ。実装・PR 作成・CI 確認を自分で行う手順を持たない。
IMPL_ALL="$(cat "$IMPL_FILE")"
assert_contains "(A) /impl が ticket ワークフローを呼ぶ" "$IMPL_ALL" 'harness run --input issue={番号} ticket'
assert_contains "(A) /impl が手順を持たないと明記している" "$IMPL_ALL" '本スキルは手順を持たず、**起動・合流・結果の読み取りと返却だけ**を行う'
assert_contains "(A) /impl が harness の無いときに自分でフローを進めない" "$IMPL_ALL" \
  '**`harness` が使えないときに、実装フローを自分で組み立てて代わりに進めない**'
for proc in 'gh pr create' 'git checkout -b' 'gh pr checks' 'subagent_type'; do
  assert_not_contains "(A) /impl が実装フローの手順（${proc}）を持たない" "$IMPL_ALL" "$proc"
done
# 呼ばれる側（ticket.yaml）が流れの各段を持つ（正本が空になっていない）
for step in implement commit e2e publish ci review; do
  assert_eq "(A) ticket ワークフローに「${step}」ステップが在る" "1" "$(grep -cE "^  ${step}:( |\$)" "$TICKET_WF")"
done

# para-impl 側は手順を1つも持たない（切り出したら片方から消す）
PARA_ALL="$(cat "$PARA_FILE")"
assert_not_contains "(A) para-impl は Phase 4 の手順見出しを持たない" "$PARA_ALL" '### Phase 4:'
assert_not_contains "(A) para-impl は feature-implementer の委譲手順を持たない" "$PARA_ALL" \
  '`feature-implementer` エージェントを **一度だけ呼び出し**'
assert_not_contains "(A) para-impl は PR 作成コマンドの手順を持たない" "$PARA_ALL" 'gh pr create --title'

# para-impl が /impl を正本として名指ししていること（消したら fan-out 先が消える）
PARA_FLOW="$(section_body "$PARA_FILE" '## 1チケットの実装フロー ── 正本は `/impl`')"
assert_contains "(A) para-impl が実装フローの正本を /impl と名指ししている" "$PARA_FLOW" \
  'の正本は `/impl` スキルであり、本スキルは手順を持たない。'
assert_contains "(A) para-impl が手順の再掲・注入を禁じている" "$PARA_FLOW" \
  '手順を再掲・注入せず `/impl` を呼ぶ'

echo ""
echo "=== (B) /impl は通常のスキル（サブエージェントで走らない） ==="

# frontmatter のキー集合を許可リストと**完全一致**で固定する（fail-closed）。
# サブエージェント実行を指示するキーが足されたらここで落ちる。
impl_fm_keys="$(awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f && /^[a-zA-Z][a-zA-Z0-9_-]*:/{sub(/:.*/,"");print}' "$IMPL_FILE" | LC_ALL=C sort | tr '\n' ',' | sed 's/,$//')"
assert_eq "(B) /impl の frontmatter キーは通常スキルの集合ちょうど（未知キーが増えたら落ちる）" \
  "argument-hint,description,effort,model,name" "$impl_fm_keys"

assert_eq "(B) /impl は skills/ 直下の通常スキルとして配置されている" "true" \
  "$(if [ -f "$IMPL_FILE" ] && [ ! -e "skills/impl/agent.md" ]; then echo true; else echo false; fi)"

# ネスト深度の規定が、呼び出し元の双方に届いていること（散文でしか守れない部分）
assert_contains "(B) para-impl がネスト深度を消費しない旨を明記している" "$PARA_FLOW" \
  '`/impl` は**通常のスキル**（サブエージェントで走らない）であり、**その呼び出しは Task ネスト深度を消費しない**'
assert_contains "(B) para-impl が深度が増えた場合の失敗（最深段が spawn できない）を明示している" "$PARA_FLOW" \
  '最深段のエージェントを spawn できなくなる'
assert_contains "(B) ticket-worker がネスト深度を消費しない旨を明記している" "$(cat "$TW_FILE")" \
  '**`/impl` の呼び出しは Task ネスト深度を消費しない**'

echo ""
echo "=== (C) 呼び出し元の明示（単一Issue経路・並列経路の双方が接続されている） ==="

IMPL_CALLERS="$(section_body "$IMPL_FILE" '## 呼び出し元（実行主体）')"
assert_eq "(C) /impl に「呼び出し元（実行主体）」節が在る" "true" \
  "$(if [ -n "$(printf '%s' "$IMPL_CALLERS" | tr -d '[:space:]')" ]; then echo true; else echo false; fi)"

# 語彙駆動の接続検査: 経路ごとに (1) /impl の経路表に実行主体が在る
# (2) 呼び出し元ファイル側にも /impl を呼ぶ規定が在る、の両方を要求する。
# 片側だけだと「呼び出し元が明示されている」が空虚になる（これが Issue #233 の元の症状）。
#   route_key|/impl 経路表に在るべき実行主体|呼び出し元ファイル|呼び出し元側に在るべき呼び出し規定
ROUTES=(
  '単一Issue経路|リードエージェント|skills/para-impl/SKILL.md|`/impl {番号} [--base {base}]`'
  '並列経路|`ticket-worker` サブエージェント|agents/ticket-worker.md|/impl {Issue番号} --base {base} --worktree {worktreeの絶対パス}'
)
for route in "${ROUTES[@]}"; do
  IFS='|' read -r rname rsubject rcaller rcall <<<"$route"
  assert_contains "(C) ${rname}: /impl の経路表に実行主体が書かれている" "$IMPL_CALLERS" "$rsubject"
  assert_contains "(C) ${rname}: 呼び出し元 ${rcaller} 側にも /impl の呼び出し規定が在る" \
    "$(cat "$rcaller")" "$rcall"
done

# 経路の分岐材料が1つであること（2つ目の判定材料を持たない＝ずれない）
assert_contains "(C) 経路の分岐は --worktree の有無ただ1つ" "$IMPL_CALLERS" \
  '**経路の分岐は `--worktree` の有無ただ1つで決まる**'

# ticket-worker / star-parallel が手順注入をやめていること（否定検査）
assert_not_contains "(C) star-parallel の spawn 必須項目が Phase 4〜8 の手順注入を求めていない" \
  "$(cat "$STAR_FILE")" 'の Phase 4〜8 の手順（Phase 3 はリードが worktree 作成で実施済み'
assert_contains "(C) star-parallel の spawn 必須項目が /impl の呼び出し形を渡す形になっている" \
  "$(section_body "$STAR_FILE" '### worker への委譲')" \
  '実装フローの手順そのものは**注入しない**'
assert_contains "(C) ticket-worker が spawn プロンプトの手順再掲を正本として扱わない" \
  "$(cat "$TW_FILE")" \
  '**spawn プロンプトに手順が注入されていても、それを正本として扱わない。**'

echo ""
echo "=== (E) 薄い /impl の返り方と CLI への受け渡し（#299） ==="

IMPL_RESULT="$(section_body "$IMPL_FILE" '### 5. 結果の読み取り')"
# 状態ごとの扱いの表: --worktree ありの列が ticket-worker の返却分類（通常完了 / 判断待ち / failure）へ写る
assert_contains "(E) review ゲートは --worktree の経路で通常完了" "$IMPL_RESULT" \
  '| `waiting` で `review` ゲート | **通常完了**として返す |'
assert_contains "(E) design-deviation は判断待ち" "$IMPL_RESULT" \
  '| `waiting` で `design-deviation` ゲート | **判断待ち**として返す'
assert_contains "(E) ci-pending は failure" "$IMPL_RESULT" \
  '| `waiting` で `ci-pending` ゲート | **`failure`** として返す'
assert_contains "(E) failed は failure（理由を添える）" "$IMPL_RESULT" \
  '| `failed` | **`failure`** として返す（`reason` を添える）'
assert_contains "(E) human ゲートを自分で解決しない" "$IMPL_RESULT" \
  '**`decider: human` のゲート（`requires_tty: true`）を自分で解決しない**'
assert_contains "(E) review に ready を自動で渡さない" "$IMPL_RESULT" \
  '**`review` ゲートに `ready` を自動で渡さない**'

IMPL_REPORT="$(section_body "$IMPL_FILE" '## 完了報告 / 呼び出し元への返却')"
assert_contains "(E) --worktree の経路で CI の差し戻しを runtime の中で済ませたと明記させる" "$IMPL_REPORT" \
  '「CI の red の差し戻しは runtime の中で最大3回まで済ませた'
assert_contains "(E) run を review ゲートで待たせたまま残す" "$IMPL_REPORT" \
  'run は `review` ゲートで待たせたまま残す（取り消さない）'
assert_contains "(E) --worktree が無い経路では harness の再開手段を案内する" "$IMPL_REPORT" \
  '`harness resume {run-id} --input respond`'
assert_contains "(E) /explain-e2e は実施せず案内する" "$IMPL_REPORT" \
  '`/explain-e2e`（テストシナリオ解説と独立検証。本スキルは実施しない）'
# 差し戻しの上限 3 は ticket.yaml の rework が持つ（/impl の文言と数がずれたら落ちる）
assert_eq "(E) 文言の「最大3回」と ticket.yaml の rework の上限が一致する" "1" \
  "$(grep -cE '^  rework: 3( |$)' "$TICKET_WF")"

IMPL_START="$(section_body "$IMPL_FILE" '### 3. 起動')"
assert_contains "(E) 自分のプラグイン版を CLI へ渡す（版の照合。§7.3）" "$IMPL_START" 'HARNESS_PLUGIN_VERSION="{プラグイン版}"'
assert_contains "(E) 子の permission mode は既定 auto・利用者の設定で上書きできる" "$IMPL_START" \
  'HARNESS_CLAUDE_PERMISSION_MODE="${HARNESS_CLAUDE_PERMISSION_MODE:-auto}"'
assert_contains "(E) 前面の Bash の上限を超えるのでバックグラウンドで起動する" "$IMPL_START" '**`run_in_background: true`**'
assert_contains "(E) 版の不一致（終了コード 5）で止まる" "$IMPL_START" '| 5 | プラグインと CLI の版が合わない |'
IMPL_JOIN="$(section_body "$IMPL_FILE" '### 4. 合流（run がゲートか終端に達するまでターンを終えない）')"
assert_contains "(E) 合流してから返す" "$IMPL_JOIN" '**`harness run` が終わる前に最終応答・返却をしない**'
assert_contains "(E) 合流の待ちは上限付きの until ループ（先頭が sleep のコマンドは拒否される）" "$IMPL_JOIN" \
  'until [ "$(harness status {run-id} --json | jq -r .status)" != running ]'

echo ""
echo "=== (D) 並列度・直列化の決定権（--max-parallel の有無で分岐する真理値表） ==="

PARA_P2="$(section_body "$PARA_FILE" '## Phase 2: 並列度と直列化 ── 決定権の所在')"
assert_eq "(D) para-impl に「Phase 2: 並列度と直列化」節が在る" "true" \
  "$(if [ -n "$(printf '%s' "$PARA_P2" | tr -d '[:space:]')" ]; then echo true; else echo false; fi)"

# 引数の綴りが frontmatter の argument-hint と本文（節スコープ）で一致していること
for flag in '--max-parallel' '--serial'; do
  assert_contains "(D) argument-hint が ${flag} を宣言している" \
    "$(grep '^argument-hint:' "$PARA_FILE")" "$flag"
  assert_contains "(D) パース方法が ${flag} を定義している" \
    "$(section_body "$PARA_FILE" '### パース方法')" "$flag"
done

# --- 決定表の参照実装 ---
# 文書が定める規律を実行可能な形で写したもの。真理値表で全状態を通し、
# 「後方互換（引数なし）」と「予測は天井を下回る方向にのみ効く」を必須ケースとして固定する。
#   $1: max_parallel（"none" or 正の整数）
#   $2: 予測が追加衝突を検出したか（yes/no）
#   $3: 起動したい worker 数
# 出力: "<決定主体>:<同時起動数>:<報告義務>"
parallelism_decision() {
  local maxp="$1" extra_conflict="$2" want="$3"
  local ceiling owner report
  if [ "$maxp" = "none" ]; then
    # 後方互換: 単独利用は従来どおり本スキルが決める
    owner="self"; ceiling="$want"; report="none"
  else
    owner="upstream"
    ceiling="$maxp"
    [ "$want" -lt "$ceiling" ] && ceiling="$want"
    if [ "$extra_conflict" = "yes" ]; then
      # 天井を**下回る方向にのみ**内側で追加直列化してよい。報告は必須
      ceiling=$((ceiling - 1))
      [ "$ceiling" -lt 1 ] && ceiling=1
      report="required"
    else
      report="none-declared"
    fi
  fi
  printf '%s:%s:%s' "$owner" "$ceiling" "$report"
}

#            max_parallel 予測 want  期待
TRUTH_TABLE=(
  'none|no|3|self:3:none'          # 後方互換（必須ケース）: 引数なしは従来どおり自分で決める
  'none|yes|3|self:3:none'         # 引数なしなら予測が出ても決定主体は変わらない
  '2|no|3|upstream:2:none-declared' # 天井が effective（3 本走らせない）＋「追加なし」の明示義務
  '2|yes|3|upstream:1:required'    # 予測は天井を**下回る**方向にのみ効き、報告が要る
  '4|no|2|upstream:2:none-declared' # 天井は目標ではない（下回る本数で走ってよい）
  '1|yes|5|upstream:1:required'    # 追加直列化が 0 本未満へ落ちない
)
for row in "${TRUTH_TABLE[@]}"; do
  IFS='|' read -r t_max t_conf t_want t_expect <<<"$row"
  assert_eq "(D) 決定表 max-parallel=${t_max} 予測=${t_conf} want=${t_want}" \
    "$t_expect" "$(parallelism_decision "$t_max" "$t_conf" "$t_want")"
done

# 参照実装が文書の規律と同じことを言っているか（正準文の逐語照合で結び付ける）
assert_contains "(D) 上位層からの起動では判断し直さない" "$PARA_P2" \
  '受け取った天井と直列化グループの**とおりに fan-out する**。判断し直さない'
assert_contains "(D) 引数なしは従来どおり自分で決める（後方互換）" "$PARA_P2" \
  '**本スキル自身**（従来どおりの単独利用。後方互換）'
assert_contains "(D) 受け取った直列化グループを必ず守る" "$PARA_P2" \
  '**受け取った直列化グループ（`--serial`）は必ず守る**（緩めない・組み替えない・解除しない）'
assert_contains "(D) 同時起動数は --max-parallel を超えない" "$PARA_P2" \
  '**同時に起動する `ticket-worker` は `--max-parallel` の値を超えない**'
assert_contains "(D) 同一周のラウンドトリップをしない" "$PARA_P2" \
  '**同一周のラウンドトリップをしない**'
assert_contains "(D) 予測は天井を下回る方向にのみ効く" "$PARA_P2" \
  '`--max-parallel` を下回る方向にのみ内側で追加直列化してよい'
assert_contains "(D) 追加直列化の事実と理由の報告が義務" "$PARA_P2" \
  '**追加直列化した事実と理由（どの Issue 対を、どの予測交差を根拠に直列化したか）を完了報告に必ず含める**'

# 否定検査: 決定権が para-impl 側へ戻る／上位層へ聞きに行く退行を塞ぐ
for phrase in '上位層に問い合わせ' '上位層へ問い合わせて' '天井を引き上げてよい' '`--serial` を解除してよい'; do
  assert_not_contains "(D) 退行語彙が Phase 2 節に無い: ${phrase}" "$PARA_P2" "$phrase"
done

# 報告義務が完了報告（Phase 9）まで接続されていること。規律を書いても
# 報告面に接続されていなければ上位層には届かない（次周の実行計画の入力が欠ける）。
PARA_P9="$(section_body "$PARA_FILE" '## Phase 9: 完了報告')"
assert_contains "(D) 完了報告に追加直列化の報告項目が接続されている" "$PARA_P9" \
  '内側で追加直列化した場合は、その事実と理由'
assert_contains "(D) 追加直列化 0 件でも明記させる（黙らせない）" "$PARA_P9" \
  '追加直列化が0件だった場合も「追加直列化なし」と明記する'
assert_contains "(D) star 型の完了報告にも天井・直列化の出所と追加直列化が在る" \
  "$(section_body "$STAR_FILE" '### 複数Issueの場合（star 型並列実装完了後）')" \
  '内側で追加直列化した組・その理由'

# 予測エージェント自体が決定権を持たないこと（予測は入力であって決定ではない）
assert_contains "(D) issue-conflict-predictor は決定権を持たず呼び出し元の判定入力に留まる" \
  "$(cat "$PRED_FILE")" '並列実装時の衝突可能性を判定するヒントとして使われます'
assert_contains "(D) star-parallel が予測に決定権が無いことを明示している" \
  "$(section_body "$STAR_FILE" '### 衝突予測ヒント（Issue数が5件以上の場合のみ）')" \
  '**予測は直列化の決定権を持たない。**'

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
