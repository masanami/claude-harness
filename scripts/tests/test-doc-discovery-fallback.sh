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
#   (G)   探索の判定が**閉じたキーワード列挙ではなく「形」**で書かれていること。ファイル名の
#         キーワード一致で選ばせると構造的に取りこぼす（実測: 本ハーネスが統治する4リポジトリの
#         `docs/` 27 件のうち `architecture` / `system-design` / `domain-model` / `erd` /
#         `schema` / `database` / `api-spec` / `openapi` に一致するのは 3 件だけで、
#         `requirements.md`〔要件定義そのもの〕`settings-governance.md`〔権限設計の正本〕が落ちた）。
#         失敗形が非対称であることが理由である——**取りこぼしは沈黙し、余分に読む費用はトークンだけ**。
#         かつ `docs/**/*.md` は既に全件列挙しているので、キーワードは候補を減らす方向にしか働かない。
#         本節が固定するのは列挙の中身ではなく、(G-1) 形の基準が在ること (G-2) 列挙が**網羅でないと
#         明記**されていること (G-3) リコール優先 (G-4) キーワード絞り込みが既定ではなく逃げ道で
#         あること (G-5) ディレクトリ名も手がかりに含むこと、および (G-6) **列挙語を書くなら
#         非網羅の明記を伴う**という全称条件。**列挙そのものを literal で固定しない**
#         ——固定すると、列挙をやめる変更をテストが妨げる
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
DDF_EXPLORE='**無ければ `docs/` 配下を探索する**'
DDF_NO_REINTERPRET='**一覧が無いことを「設計ドキュメントが無い」と読み替えないこと**'
# 節が在る旧世代の生成物を切り捨てていないこと（フォールバックは追加であって置換ではない）。
DDF_USE_IF_PRESENT='`CLAUDE.md` に設計ドキュメントの一覧（ドキュメントマップ等）があればそれを使う。'
# 技術スタック・ディレクトリ構成をコードベース側から得る指示。
# **開発原則をここに束ねない** — マニフェストと実ディレクトリはこの2項目の実体だが、
# 開発原則の実体ではない（package.json に設計原則は書かれていない）。開発原則は DDF_INTENT が扱う。
DDF_DERIVE='技術スタック・ディレクトリ構成は `CLAUDE.md` に書かれないのが既定。'
DDF_NO_HALT='**記載が無いことを理由に停止しない**'
# 探索の判定を「形」で持たせる不変コア。列挙の中身は可変部であり、ここでは固定しない。
DDF_FORM='**判定は「その文書が何を述べているか」で行い、ファイル名のキーワード一致で行わない。**'
DDF_NOT_EXHAUSTIVE='**網羅ではない手がかりの例示**であり、**どれにも一致しないことは除外の理由にならない**'
DDF_RECALL='**迷ったら読む側に倒す**'
DDF_ORDER='**この順序を逆にしない**'
DDF_DIRNAME='ディレクトリ名も手がかりに含める'
DDF_ENUMERATE_ALL='を Glob で**全件列挙**し'
# (G-6) の起点。列挙語のうち、例示以外の文脈で現れない語を1つ選ぶ。
DDF_ENUM_SENTINEL='`erd` / `schema`'

# 開発原則の節の不在に対する読み替え禁止と、意図的な設計判断の正本（docs/adr/）への導線。
# 全実行時ファイルで逐語同一にしてあるため、1つの literal で全称条件を張れる。
DDF_INTENT='**無いことを「原則が無い」と読み替えない**'
DDF_INTENT_ADR='意図的な設計判断は `docs/adr/` があればそこを読み、無ければ既存コードの実装パターンから読み取る。'

# 設計ドキュメントへの到達を責務に含む実行時ファイル。
DDF_DISCOVERY_FILES=(
  "agents/code-reviewer.md"
  "agents/design-reviewer.md"
  "agents/doc-verifier.md"
  "agents/feature-implementer.md"
  "skills/define-feature/SKILL.md"
)

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
  assert_eq "(A-1) ${f}: 不在を「無い」と読み替えない規則が在る" "true" \
    "$(has_literal "$f" "$DDF_NO_REINTERPRET")"
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
  [ "$(in_list "$f" "${DDF_DISCOVERY_FILES[@]}")" = "true" ] && continue
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
# (G) 判定が閉じたキーワード列挙になっていない
# ------------------------------------------------------------------
echo "== (G) 探索の判定が「形」で書かれている =="

for f in "${DDF_DISCOVERY_FILES[@]}"; do
  assert_eq "(G-1) ${f}: 形の基準（何を述べているかで選ぶ）が在る" "true" \
    "$(has_literal "$f" "$DDF_FORM")"
  assert_eq "(G-2) ${f}: 列挙が網羅でないと明記されている" "true" \
    "$(has_literal "$f" "$DDF_NOT_EXHAUSTIVE")"
  assert_eq "(G-3) ${f}: リコール優先（迷ったら読む）が在る" "true" \
    "$(has_literal "$f" "$DDF_RECALL")"
  assert_eq "(G-4) ${f}: キーワード絞り込みが既定でない（順序の固定）が在る" "true" \
    "$(has_literal "$f" "$DDF_ORDER")"
  assert_eq "(G-5) ${f}: ディレクトリ名も手がかりに含む指示が在る" "true" \
    "$(has_literal "$f" "$DDF_DIRNAME")"
  assert_eq "(G-5) ${f}: 全件列挙が既定である" "true" \
    "$(has_literal "$f" "$DDF_ENUMERATE_ALL")"
done

# (G-6) 全称条件: 列挙語を書いているファイルは、非網羅の明記を必ず伴う。
# 列挙そのものは禁じない（手がかりとして有用）。禁じるのは**網羅のように見せること**。
DDF_BARE_ENUM=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$(has_literal "$f" "$DDF_NOT_EXHAUSTIVE")" = "true" ] && continue
  DDF_BARE_ENUM="${DDF_BARE_ENUM}${f} "
done < <(grep -rlF "$DDF_ENUM_SENTINEL" agents/ skills/ 2>/dev/null | sort)

assert_eq "(G-6) 非網羅の明記を伴わないキーワード列挙が無い" "" "$DDF_BARE_ENUM"

# 検出器の自己検査: sentinel が実際に列挙を捕まえていること（0 件なら全称条件が空回りする）。
assert_eq "(G-6) sentinel が列挙を捕捉している（空回りの検出）" "true" \
  "$([ "$(grep -rlF "$DDF_ENUM_SENTINEL" agents/ skills/ 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] \
    && echo true || echo false)"

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
