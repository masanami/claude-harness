#!/bin/bash
# test-doc-discovery-fallback.sh
# 実行時テキスト（skills/ agents/）が設計ドキュメントへ到達する手段を持つことの
# 構造不変条件テスト。
#
# 背景（Issue #241）: `/init-project` が生成する `CLAUDE.md` から
# 「ドキュメントマップ」「開発原則」「技術スタック」「ディレクトリ構成」の各節が削除された
# （Issue #237 の棚卸し。scripts/tests/test-claude-md-template.sh (A) が節の不在を固定している）。
# 節を前提に「`CLAUDE.md` のドキュメントマップから設計書を読む」とだけ書かれた実行時テキストは、
# **新規生成物では到達手段を1つも持たない**。この失敗は沈黙する — 読めなかったことは
# 「設計ドキュメントが無い」と区別できないまま「確認済み」として報告されるため。
#
# 本テストが固定するのは文言そのものではなく、**到達手段が在ること**である:
#   (A-1) 設計ドキュメントへの到達を責務に含むファイルが、探索フォールバックの不変コアを持つ
#   (A-2) 同じファイルが、技術スタック・ディレクトリ構成をマニフェストと実ディレクトリから
#         得る指示の不変コアを持つ
#   (A-3) 同じファイルが、開発原則についての読み替え禁止と `docs/adr/` 導線を持つ。(A-2) とは
#         **別の assert にする** — 導出先が実体に従って分かれるため（マニフェストは技術スタックの
#         実体だが開発原則の実体ではない）。3項目を1つの導出指示に束ねると、導ける2つに
#         引きずられて導けない1つが誤った導出先を与えられる
#   (B)   `ドキュメントマップ` に言及する実行時ファイルの**全称条件**。(A-1) のファイル群か、
#         節の不在を既定として扱う許可リストのどちらかに属すること。新しく節依存の記述を
#         足したファイルは、どちらにも属さないため落ちる
#   (C)   旧来の硬直依存 `ドキュメントマップから` の再出現（節が唯一の入口である書き方）
#   (D)   `開発原則` に言及する実行時ファイルが、節の不在に対する**読み替え禁止**を伴うこと。
#         導出指示（(A-2)）で代替させない — 「記載が無いことを理由に停止しない」は停止を
#         防ぐだけで、「原則が無い」という読み替えを禁じていない。塞いでいる穴が別物のため、
#         選言（どちらか一方）にすると読み替え禁止を持たないファイルが素通りする
#   (E)   ADR 置き場の解決が、節が無くても既定 `docs/adr/` へフォールバックして成立すること
#   (F)   旧世代の生成物（節を持つプロジェクト）を切り捨てていないこと。フォールバックは
#         「節が在ればそれを使う」を保ったうえでの**追加**であり、置換ではない
#   (G)   探索の判定が**閉じた列挙ではなく「形」**で書かれていること。ファイル名のキーワード
#         一致で選ばせると構造的に取りこぼす（実測と根拠は docs/adr/0005 — 実行時テキストには
#         置かない。根拠は行動を変えないため → docs/plugin-path-conventions.md (h)）。
#         本節は**列挙が実行時テキストに無いこと**を直接固定する。以前は「列挙を書くなら
#         非網羅の明記を伴え」という条件付きだったが、それは**列挙の保存を前提にした形**で
#         あり、打ち消しの文をもう一往復ぶん実行時テキストへ載せていた。列挙を消せば
#         打ち消しも要らない。sentinel を使った自己検査も不要になる（列挙が無いのだから
#         空振りが正常状態になり、自己検査自体が矛盾する）。
#         探索先ディレクトリも同様に `docs/` 決め打ちにしない——同じ穴が一段上に開く。
#   (H)   実行時テキストの**厚みが役割に応じて分かれている**こと。設計ドキュメントを実際に
#         探して読む消費ステップを持つファイルだけが探索手順を持ち、持たないファイル
#         （`code-reviewer` は Step 1 が native の方法論・観点 A〜G が CLAUDE.md と差分起点で、
#         設計ドキュメントを読むステップが無い）は読み替え禁止のガードだけを持つ。
#         全ファイルに同じ厚さを配らない。
#
# 不変コアは可変部を含まない一文で照合する（部分一致は意味を反転させても通るため）。
# 非 ASCII の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。照合は grep -F（バイト厳密）で行う。
#
# 実行方法: bash scripts/tests/test-doc-discovery-fallback.sh

set -u

DDF_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DDF_TEST_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

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

has_literal() {
  # $1=file $2=literal
  [ -f "$1" ] && grep -Fq "$2" "$1" && echo true || echo false
}

# ------------------------------------------------------------------
# 不変コア（可変部を含まない一文）
# ------------------------------------------------------------------

# 探索フォールバックの中核。「節が無ければ探索する」と「無いことを不在と読み替えない」の2文。
# 前者だけだと探索を飛ばして「無い」と結論づける経路が残るため、両方を必須にする。
DDF_EXPLORE='**無ければ探索する**'
# 厚い版と軽量版の双方に現れる共通コア（言い回しは役割に応じて違ってよい）。
DDF_NO_REINTERPRET='「設計ドキュメントが無い」と読み替え'
# 節が在る旧世代の生成物を切り捨てていないこと（フォールバックは追加であって置換ではない）。
DDF_USE_IF_PRESENT='`CLAUDE.md` に設計ドキュメントの一覧（ドキュメントマップ等）があればそれを使う。'
# 技術スタック・ディレクトリ構成をコードベース側から得る指示。
# **開発原則をここに束ねない** — マニフェストと実ディレクトリはこの2項目の実体だが、
# 開発原則の実体ではない（package.json に設計原則は書かれていない）。開発原則は DDF_INTENT が扱う。
DDF_DERIVE='技術スタック・ディレクトリ構成は `CLAUDE.md` に書かれないのが既定。'
DDF_NO_HALT='**記載が無いことを理由に停止しない**'
# 探索の判定を「形」で持たせる不変コア。
DDF_FORM='**対象の実装が従うべきことを書いた文書**'
DDF_RECALL='**迷ったら読む側に倒す**'
DDF_PATH_BOTH='**ディレクトリ名とファイル名の両方**'
DDF_ENUMERATE_ALL='を Glob で**全件列挙**し'
# 探索先ディレクトリも形で持つ（`docs/` 決め打ちにしない）。厚い版・軽量版の双方に在る。
DDF_DIR_FORM='`docs/` が典型だが**名前は問わない**'
# (G-4) で実行時テキストから不在を確かめる、ファイル名パターンの列挙語。
# バッククォート付きで照合する（surface-audit の散文中の `OpenAPI 定義` を誤検出しないため）。
DDF_BANNED_ENUM=('`system-design`' '`domain-model`' '`api-spec`' '`openapi`' '`erd`' '`system_design`' '`swagger`')

# 開発原則の節の不在に対する読み替え禁止と、意図的な設計判断の正本（docs/adr/）への導線。
# 全実行時ファイルで逐語同一にしてあるため、1つの literal で全称条件を張れる。
DDF_INTENT='**無いことを「原則が無い」と読み替えない**'
DDF_INTENT_ADR='意図的な設計判断は `docs/adr/` があればそこを読み、無ければ既存コードの実装パターンから読み取る。'

# 設計ドキュメントを実際に探して読む消費ステップを持つファイル（厚い版）。
DDF_DISCOVERY_FILES=(
  "agents/design-reviewer.md"       # Step 1「設計ドキュメントの確認」
  "agents/doc-verifier.md"          # Step 1「対象機能の特定」＝要件定義と設計書の突合せ
  "agents/feature-implementer.md"   # Step a-3「既存コード・既存設計の理解」
  "skills/define-feature/SKILL.md"  # 手順1「プロジェクト理解」＋手順3-2でパスを下流へ渡す
)

# 設計ドキュメントを読む消費ステップを持たないファイル（軽量版＝ガードのみ）。
# 厚い版を配ると、使わない手順が毎回配送される（→ (h) の判定軸）。
DDF_GUARD_FILES=(
  "agents/code-reviewer.md"
)

# `CLAUDE.md` を読んで規約を把握する全ファイル（厚み分けの対象外。(A-2)(A-3) 用）。
DDF_CLAUDE_MD_FILES=( "${DDF_DISCOVERY_FILES[@]}" "${DDF_GUARD_FILES[@]}" )

# `ドキュメントマップ` に言及してよいが探索フォールバックは持たないファイル。
# いずれも「節が無いのが既定」を前提に書かれており、節そのものを入口にしていない。
DDF_DOCMAP_ALLOWLIST=(
  "skills/init-project/SKILL.md"            # preflight の advisory 指摘の列挙
  "skills/create-adr/SKILL.md"              # 節がある場合のみの反映（(E) で別途検査）
  "skills/create-adr/references/record-mode.md"   # 完了報告の分岐（表が無いため未追記）
  "skills/create-adr/references/promote-mode.md"  # 同上
)

in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [ "$x" = "$needle" ] && { echo true; return; }; done
  echo false
}

# ------------------------------------------------------------------
# (A) 到達を責務に含むファイルが不変コアを持つ
# ------------------------------------------------------------------
echo "== (A) 設計ドキュメントへの到達手段 =="

for f in "${DDF_DISCOVERY_FILES[@]}"; do
  assert_eq "(A-1) ${f}: 探索フォールバックが在る" "true" "$(has_literal "$f" "$DDF_EXPLORE")"
done

# 読み替え禁止のガードは厚い版・軽量版の**両方**が持つ（これが最後の歯止めのため）。
for f in "${DDF_CLAUDE_MD_FILES[@]}"; do
  assert_eq "(A-1) ${f}: 不在を「無い」と読み替えない規則が在る" "true" \
    "$(has_literal "$f" "$DDF_NO_REINTERPRET")"
done

for f in "${DDF_CLAUDE_MD_FILES[@]}"; do
  assert_eq "(A-2) ${f}: 技術スタック・ディレクトリ構成をコードベースから得る指示が在る" "true" \
    "$(has_literal "$f" "$DDF_DERIVE")"
  assert_eq "(A-2) ${f}: 記載が無いことを理由に停止しない規則が在る" "true" \
    "$(has_literal "$f" "$DDF_NO_HALT")"
  # (A-3) は (D) の全称条件と重ならない。(D) は「開発原則に言及するなら読み替え禁止を伴え」で
  # あり、言及そのものが消えた場合は発火しない。主力ファイルから開発原則の導線が
  # 黙って落ちる経路を塞ぐため、必須リスト側からも固定する。
  assert_eq "(A-3) ${f}: 開発原則の読み替え禁止が在る" "true" \
    "$(has_literal "$f" "$DDF_INTENT")"
  assert_eq "(A-3) ${f}: 開発原則の文脈から docs/adr/ への導線が在る" "true" \
    "$(has_literal "$f" "$DDF_INTENT_ADR")"
done

# ------------------------------------------------------------------
# (B) ドキュメントマップ言及の全称条件
# ------------------------------------------------------------------
echo "== (B) ドキュメントマップに言及するファイルの全称条件 =="

DDF_UNCOVERED=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # 厚い版・ガード版のどちらも到達手段を持つ（ガード版は「読み替えるな＋辿り方」）。
  [ "$(in_list "$f" "${DDF_CLAUDE_MD_FILES[@]}")" = "true" ] && continue
  [ "$(in_list "$f" "${DDF_DOCMAP_ALLOWLIST[@]}")" = "true" ] && continue
  DDF_UNCOVERED="${DDF_UNCOVERED}${f} "
done < <(grep -rlF 'ドキュメントマップ' agents/ skills/ 2>/dev/null | sort)

assert_eq "(B) 到達手段も許可リストも持たないファイルが無い" "" "$DDF_UNCOVERED"

# 許可リストが実在ファイルだけを指すこと（消えたファイルを許可したまま残さない）。
DDF_STALE=""
for f in "${DDF_DOCMAP_ALLOWLIST[@]}"; do
  grep -qlF 'ドキュメントマップ' "$f" 2>/dev/null || DDF_STALE="${DDF_STALE}${f} "
done
assert_eq "(B) 許可リストに不要な項目が無い（逆方向）" "" "$DDF_STALE"

# ------------------------------------------------------------------
# (C) 旧来の硬直依存の再出現
# ------------------------------------------------------------------
echo "== (C) 節を唯一の入口にする書き方の再出現 =="

DDF_HARD="$(grep -rnF 'ドキュメントマップから' agents/ skills/ 2>/dev/null | tr '\n' ' ')"
assert_eq "(C) 「ドキュメントマップから」が実行時テキストに無い" "" "$DDF_HARD"

# ------------------------------------------------------------------
# (D) 開発原則への言及が読み替え禁止を伴う
# ------------------------------------------------------------------
echo "== (D) 開発原則の節の不在 =="

# init-project は生成側であり、「書かない」ことを定める側なので対象外。
DDF_PRINCIPLE_ALLOWLIST=("skills/init-project/SKILL.md")

# 読み替え禁止（DDF_INTENT）を**必須**にする。導出指示（DDF_DERIVE）での代替は認めない
# ——塞いでいる穴が別物であり、選言にすると変種が分岐して配分が崩れても検出できない。
DDF_BARE=""
DDF_NO_ADR=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$(in_list "$f" "${DDF_PRINCIPLE_ALLOWLIST[@]}")" = "true" ] && continue
  [ "$(has_literal "$f" "$DDF_INTENT")" = "true" ] || DDF_BARE="${DDF_BARE}${f} "
  [ "$(has_literal "$f" "$DDF_INTENT_ADR")" = "true" ] || DDF_NO_ADR="${DDF_NO_ADR}${f} "
done < <(grep -rlF '開発原則' agents/ skills/ 2>/dev/null | sort)

assert_eq "(D) 読み替え禁止を伴わない開発原則の言及が無い" "" "$DDF_BARE"
assert_eq "(D) docs/adr/ 導線を伴わない開発原則の言及が無い" "" "$DDF_NO_ADR"

# ------------------------------------------------------------------
# (E) ADR 置き場が節なしでも既定へフォールバックする
# ------------------------------------------------------------------
echo "== (E) ADR 置き場の解決 =="

DDF_ADR="skills/create-adr/SKILL.md"
assert_eq "(E) 既定 docs/adr/ へのフォールバックが明記されている" "true" \
  "$(has_literal "$DDF_ADR" 'どちらも無ければ既定の `docs/adr/` を採る')"
assert_eq "(E) 記載が無いことで停止しない規則が在る" "true" \
  "$(has_literal "$DDF_ADR" '**`CLAUDE.md` に記載が無いことは別パスの証拠でも、置き場を決められない理由でもない**')"
assert_eq "(E) 節の不在を欠落として報告しない規則が在る" "true" \
  "$(has_literal "$DDF_ADR" '節が無いのが既定であり、欠落・不備として報告しない**')"

# ------------------------------------------------------------------
# (F) 旧世代の生成物（節を持つプロジェクト）を切り捨てていない
# ------------------------------------------------------------------
echo "== (F) 節が在る場合の経路が残っている =="

for f in "${DDF_DISCOVERY_FILES[@]}"; do
  assert_eq "(F) ${f}: 節が在ればそれを使う経路が残っている" "true" \
    "$(has_literal "$f" "$DDF_USE_IF_PRESENT")"
done

# create-adr は節が在る旧世代の生成物に対して従来どおり1行追記する。
assert_eq "(F) create-adr: 節が在る場合の追記が残っている" "true" \
  "$(has_literal "$DDF_ADR" '**そのプロジェクトに既にドキュメントマップ節があり、かつ初めて ADR を作成した場合のみ**')"

# ------------------------------------------------------------------
# (G) 判定が「形」で書かれ、閉じた列挙が実行時テキストに無い
# ------------------------------------------------------------------
echo "== (G) 探索の判定が「形」で書かれている =="

for f in "${DDF_DISCOVERY_FILES[@]}"; do
  assert_eq "(G-1) ${f}: 形の基準（従うべきことを書いた文書）が在る" "true" \
    "$(has_literal "$f" "$DDF_FORM")"
  assert_eq "(G-2) ${f}: リコール優先（迷ったら読む）が在る" "true" \
    "$(has_literal "$f" "$DDF_RECALL")"
  assert_eq "(G-3) ${f}: 全件列挙が既定である" "true" \
    "$(has_literal "$f" "$DDF_ENUMERATE_ALL")"
  assert_eq "(G-3) ${f}: パスの判断材料がディレクトリ名とファイル名の両方である" "true" \
    "$(has_literal "$f" "$DDF_PATH_BOTH")"
done

# 探索先ディレクトリを `docs/` 決め打ちにしない（同じ「閉じた列挙」の穴が一段上に開く）。
for f in "${DDF_CLAUDE_MD_FILES[@]}"; do
  assert_eq "(G-3) ${f}: 探索先ディレクトリが形で書かれている" "true" \
    "$(has_literal "$f" "$DDF_DIR_FORM")"
done

# (G-4) 実行時テキストにファイル名パターンの列挙が無いこと。
# 条件付き（「列挙を書くなら非網羅の明記を伴え」）ではなく**直接の不在**で固定する
# ——条件付きは列挙の保存を前提にしてしまい、打ち消しの文を実行時テキストへ載せ続ける。
DDF_ENUM_HITS=""
for tok in "${DDF_BANNED_ENUM[@]}"; do
  while IFS= read -r f; do
    [ -n "$f" ] && DDF_ENUM_HITS="${DDF_ENUM_HITS}${f}:${tok} "
  done < <(grep -rlF "$tok" agents/ skills/ 2>/dev/null | sort)
done
assert_eq "(G-4) ファイル名パターンの列挙が実行時テキストに無い" "" "$DDF_ENUM_HITS"

# 検出器の自己検査: 検出パターンが実際に列挙形を捕まえること（既知の違反形で確かめる）。
DDF_PROBE="$(printf '%s\n' '`architecture` / `system-design` / `erd` をファイル名に含むもの')"
DDF_PROBE_HIT=false
for tok in "${DDF_BANNED_ENUM[@]}"; do
  printf '%s' "$DDF_PROBE" | grep -qF "$tok" && DDF_PROBE_HIT=true
done
assert_eq "(G-4) 検出パターンが既知の違反形を捕捉する（自己検査）" "true" "$DDF_PROBE_HIT"

# ------------------------------------------------------------------
# (H) 厚みが役割に応じて分かれている
# ------------------------------------------------------------------
echo "== (H) 厚みの分離 =="

# ガード側は探索手順を持たない（持つと、使わない手順が毎回配送される）。
for f in "${DDF_GUARD_FILES[@]}"; do
  assert_eq "(H) ${f}: 探索手順を持たない（ガードのみ）" "false" \
    "$(has_literal "$f" "$DDF_ENUMERATE_ALL")"
  assert_eq "(H) ${f}: リコール優先の手順を持たない（ガードのみ）" "false" \
    "$(has_literal "$f" "$DDF_RECALL")"
done

# 2集合が素であること（同じファイルを両方に置くと (H) が自己矛盾する）。
DDF_OVERLAP=""
for f in "${DDF_GUARD_FILES[@]}"; do
  [ "$(in_list "$f" "${DDF_DISCOVERY_FILES[@]}")" = "true" ] && DDF_OVERLAP="${DDF_OVERLAP}${f} "
done
assert_eq "(H) 厚い版とガード版の集合が素である" "" "$DDF_OVERLAP"

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
