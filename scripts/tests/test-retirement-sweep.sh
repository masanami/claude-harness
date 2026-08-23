#!/bin/bash
# test-retirement-sweep.sh
# scripts/retirement-sweep.sh の走査（パス形／弱一致／除外）と CLI 契約
# （stdout JSON / exit code / 実行前提の欠落）をテストする。gh 非依存。
#
# 実行方法: bash scripts/tests/test-retirement-sweep.sh
# 失敗時は非0 exitし、失敗したテスト名を要約として出力する。
#
# 日本語を含む文字列の一致判定に awk の `==` は使わない（macOS 標準 awk が誤って真にする。
# scripts/README.md「テスト」節）。比較は assert_eq（bash の `=`）と grep -F で行う。

set -u

RS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${RS_TEST_DIR}/../retirement-sweep.sh"
REPO_ROOT="$(cd "${RS_TEST_DIR}/../.." && pwd)"

# main() を実行させずに関数だけを読み込む
# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

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

TMP_ROOT="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup_tmp_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_tmp_root EXIT

# 走査対象のフィクスチャリポジトリを作る。退役対象は**作らない**（既に削除済みの状態）。
WS="${TMP_ROOT}/repo"
mkdir -p "${WS}/docs/adr" "${WS}/docs/features" "${WS}/src" "${WS}/web" "${WS}/sub/deep"
printf '# app\n詳細は [日報](docs/features/daily-report.md) を参照。\n' > "${WS}/README.md"
printf '// 設計根拠: docs/features/daily-report.md の 3.2 節\nexport const x = 1;\n\t// タブ始まり docs/features/daily-report.md\n' > "${WS}/src/report.ts"
printf '# ADR 0007\n宣言元は退役した docs/features/daily-report.md\n' > "${WS}/docs/adr/0007-report.md"
printf '無関係な daily-report.md という言及だけの行\n' > "${WS}/web/note.md"
printf '別の退役対象 docs/features/work-log.md を指す\n' > "${WS}/sub/deep/impl.ts"
# リテラル一致であることの検証用（`.` を任意文字として扱うと当たってしまう行）
printf 'docs/features/daily-reportXmd は別物\n' > "${WS}/src/regex-bait.ts"
(
  cd "$WS" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  git add -A
  git commit -qm init
)

run_sweep() {
  # 引数をそのまま渡し、stdout を返す。exit code は呼び出し側が $? で受ける。
  (cd "$WS" && bash "$TARGET_SCRIPT" "$@" 2>/dev/null)
}

echo "=== test: 削除済み文書への参照を全件拾う ==="
OUT="$(run_sweep docs/features/daily-report.md)"
EXIT_CODE=$?
assert_eq "参照が残っていれば exit 1" "1" "$EXIT_CODE"
assert_eq "status が fail" "fail" "$(jq -r '.status' <<<"$OUT")"
# NUL 区切りの一覧をコマンド置換で受けると全ファイル名が1本に連結され、1件も回らないまま
# 「参照0件」になる（実測した回帰）。複数ファイル・複数行を確実に数えることで固定する。
assert_eq "複数ファイルに跨るヒットを取りこぼさない（NUL 連結の回帰防止）" "3" \
  "$(jq -r '.counts.references' <<<"$OUT")"
assert_eq "ユニークファイル数を数える" "2" "$(jq -r '.counts.files' <<<"$OUT")"
assert_eq "参照のファイルはリポジトリルート相対" "README.md,src/report.ts,src/report.ts" \
  "$(jq -r '[.references[].file] | join(",")' <<<"$OUT")"
assert_eq "行番号は数値で返す" "2,1,3" "$(jq -r '[.references[].line | tostring] | join(",")' <<<"$OUT")"
assert_eq "match はすべて path" "path,path,path" "$(jq -r '[.references[].match] | join(",")' <<<"$OUT")"
assert_eq "targets を返す" "docs/features/daily-report.md" "$(jq -r '.targets | join(",")' <<<"$OUT")"

echo "=== test: ヒット行の本文を記載どおり返す（タブで列がずれない） ==="
assert_eq "タブを含む行をそのまま返す" \
  "$(printf '\t// タブ始まり docs/features/daily-report.md')" \
  "$(jq -r '[.references[] | select(.line == 3) | .text][0]' <<<"$OUT")"

echo "=== test: ADR の出所記録は除外するが、黙って捨てない ==="
assert_eq "ADR 配下のヒットは references に入らない" "0" \
  "$(jq -r '[.references[] | select(.file | startswith("docs/adr/"))] | length' <<<"$OUT")"
assert_eq "ADR 配下のヒットは excluded に入る" "1" "$(jq -r '.counts.excluded' <<<"$OUT")"
assert_eq "excluded のファイルを特定できる" "docs/adr/0007-report.md" \
  "$(jq -r '.excluded[0].file' <<<"$OUT")"
assert_eq "excluded_dirs を出力する（掃引範囲を目視できる）" "docs/adr/" \
  "$(jq -r '.excluded_dirs | join(",")' <<<"$OUT")"

echo "=== test: ファイル名だけの言及は弱一致（status を落とさない） ==="
assert_eq "弱一致を1件検出する" "1" "$(jq -r '.counts.weak' <<<"$OUT")"
assert_eq "弱一致のファイル" "web/note.md" "$(jq -r '.weak_matches[0].file' <<<"$OUT")"
assert_eq "弱一致の match は basename" "basename" "$(jq -r '.weak_matches[0].match' <<<"$OUT")"
# パス形で拾った行はファイル名も含むため弱一致でも当たる。二重に数えると
# counts.weak が「パス形では拾えなかった言及」を表さなくなる。
assert_eq "パス形で拾った行を弱一致として二重計上しない" "0" \
  "$(jq -r '[.weak_matches[] | select(.file == "src/report.ts" or .file == "README.md")] | length' <<<"$OUT")"
assert_eq "除外した行も弱一致として復活させない" "0" \
  "$(jq -r '[.weak_matches[] | select(.file | startswith("docs/adr/"))] | length' <<<"$OUT")"

echo "=== test: リテラル一致（正規表現として解釈しない） ==="
assert_eq 'ドット（.）を任意文字として扱わない（regex-bait に当たらない）' "0" \
  "$(jq -r '[.references[], .weak_matches[] | select(.file == "src/regex-bait.ts")] | length' <<<"$OUT")"

echo "=== test: 弱一致だけなら pass（誤検出で退役を止めない） ==="
WEAK_ONLY_WS="${TMP_ROOT}/weakonly"
mkdir -p "${WEAK_ONLY_WS}/docs/features" "${WEAK_ONLY_WS}/src"
printf '同名の別ファイル daily-report.md について\n' > "${WEAK_ONLY_WS}/src/other.ts"
(
  cd "$WEAK_ONLY_WS" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  git add -A
  git commit -qm init
)
WEAK_OUT="$(cd "$WEAK_ONLY_WS" && bash "$TARGET_SCRIPT" docs/features/daily-report.md 2>/dev/null)"
WEAK_EXIT=$?
assert_eq "弱一致だけなら exit 0" "0" "$WEAK_EXIT"
assert_eq "弱一致だけなら status は pass" "pass" "$(jq -r '.status' <<<"$WEAK_OUT")"
assert_eq "弱一致は件数として残る（検出していないと区別できる）" "1" \
  "$(jq -r '.counts.weak' <<<"$WEAK_OUT")"
WEAK_ERR="$(cd "$WEAK_ONLY_WS" && bash "$TARGET_SCRIPT" docs/features/daily-report.md 2>&1 >/dev/null)"
assert_eq "弱一致は stderr にも警告を出す（黙って捨てない）" "true" \
  "$(if printf '%s' "$WEAK_ERR" | grep -qF -- "weak_matches"; then echo true; else echo false; fi)"

echo "=== test: 参照が1件も無ければ pass ==="
CLEAN_OUT="$(run_sweep docs/features/never-referenced.md)"
CLEAN_EXIT=$?
assert_eq "参照なしは exit 0" "0" "$CLEAN_EXIT"
assert_eq "参照なしは status pass" "pass" "$(jq -r '.status' <<<"$CLEAN_OUT")"
assert_eq "参照なしでも counts.targets は数える" "1" "$(jq -r '.counts.targets' <<<"$CLEAN_OUT")"

echo "=== test: 複数の退役パスをまとめて走査できる ==="
MULTI_OUT="$(run_sweep docs/features/daily-report.md docs/features/work-log.md)"
MULTI_EXIT=$?
assert_eq "複数指定でも exit 1" "1" "$MULTI_EXIT"
assert_eq "対象は2件" "2" "$(jq -r '.counts.targets' <<<"$MULTI_OUT")"
assert_eq "2件目の参照も拾う" "1" \
  "$(jq -r '[.references[] | select(.target == "docs/features/work-log.md")] | length' <<<"$MULTI_OUT")"
assert_eq "参照は退役パスごとに target を持つ" "sub/deep/impl.ts" \
  "$(jq -r '[.references[] | select(.target == "docs/features/work-log.md") | .file][0]' <<<"$MULTI_OUT")"

echo "=== test: 未追跡ファイル（コミット前）の参照も拾う ==="
printf '新規ファイルからの参照 docs/features/daily-report.md\n' > "${WS}/src/untracked.ts"
UNTRACKED_OUT="$(run_sweep docs/features/daily-report.md)"
assert_eq "未追跡ファイルの参照を拾う（退役 PR の作業中に走らせるため）" "1" \
  "$(jq -r '[.references[] | select(.file == "src/untracked.ts")] | length' <<<"$UNTRACKED_OUT")"
rm -f "${WS}/src/untracked.ts"

echo "=== test: 退役対象がまだ存在するなら exit 2（削除前の 0 件を pass にしない） ==="
printf 'まだ消していない\n' > "${WS}/docs/features/still-here.md"
STILL_OUT="$(run_sweep docs/features/still-here.md)"
STILL_EXIT=$?
assert_eq "未削除は exit 2" "2" "$STILL_EXIT"
assert_eq "未削除時の stdout は空" "" "$STILL_OUT"
STILL_ERR="$(cd "$WS" && bash "$TARGET_SCRIPT" docs/features/still-here.md 2>&1 >/dev/null)"
assert_eq "エラー JSON の error は retired path still present" "true" \
  "$(if printf '%s' "$STILL_ERR" | grep -qF -- '"error":"retired path still present"'; then echo true; else echo false; fi)"
rm -f "${WS}/docs/features/still-here.md"

echo "=== test: 実行前提の欠落はすべて exit 2 で stdout が空 ==="
NOARG_OUT="$(run_sweep)"
NOARG_EXIT=$?
assert_eq "対象0個は exit 2" "2" "$NOARG_EXIT"
assert_eq "対象0個の stdout は空" "" "$NOARG_OUT"

UNKNOWN_OUT="$(run_sweep --bogus docs/features/daily-report.md)"
UNKNOWN_EXIT=$?
assert_eq "未知オプションは exit 2" "2" "$UNKNOWN_EXIT"
assert_eq "未知オプション時の stdout は空" "" "$UNKNOWN_OUT"

NOVAL_OUT="$(run_sweep docs/features/daily-report.md --adr-dir)"
NOVAL_EXIT=$?
assert_eq "--adr-dir に値が無ければ exit 2" "2" "$NOVAL_EXIT"
assert_eq "その場合の stdout は空" "" "$NOVAL_OUT"

EMPTY_ADR_OUT="$(run_sweep docs/features/daily-report.md --adr-dir "")"
EMPTY_ADR_EXIT=$?
assert_eq "--adr-dir が空文字なら exit 2（除外を空にできない）" "2" "$EMPTY_ADR_EXIT"
assert_eq "その場合の stdout は空" "" "$EMPTY_ADR_OUT"

EMPTY_TARGET_OUT="$(run_sweep "")"
EMPTY_TARGET_EXIT=$?
assert_eq "空のパスは exit 2" "2" "$EMPTY_TARGET_EXIT"
assert_eq "その場合の stdout は空" "" "$EMPTY_TARGET_OUT"

BAD_BASE_OUT="$(run_sweep docs/features/daily-report.md --base "${TMP_ROOT}/nonexistent")"
BAD_BASE_EXIT=$?
assert_eq "--base のディレクトリが無ければ exit 2" "2" "$BAD_BASE_EXIT"
assert_eq "その場合の stdout は空" "" "$BAD_BASE_OUT"

NOGIT_DIR="${TMP_ROOT}/nogit"
mkdir -p "$NOGIT_DIR"
NOGIT_OUT="$(cd "$NOGIT_DIR" && bash "$TARGET_SCRIPT" docs/features/daily-report.md 2>/dev/null)"
NOGIT_EXIT=$?
assert_eq "git 作業ツリーでなければ exit 2" "2" "$NOGIT_EXIT"
assert_eq "その場合の stdout は空" "" "$NOGIT_OUT"

echo "=== test: --base / サブディレクトリからの実行でもリポジトリルート基準で走査する ==="
SUBDIR_OUT="$(cd "${WS}/sub/deep" && bash "$TARGET_SCRIPT" docs/features/daily-report.md 2>/dev/null)"
SUBDIR_EXIT=$?
assert_eq "サブディレクトリからでも参照を見失わない" "1" "$SUBDIR_EXIT"
assert_eq "base はリポジトリルート" "$(cd "$WS" && pwd -P)" "$(jq -r '.base' <<<"$SUBDIR_OUT")"
assert_eq "サブディレクトリからでも件数は同じ" "3" "$(jq -r '.counts.references' <<<"$SUBDIR_OUT")"

BASE_OUT="$(cd "$TMP_ROOT" && bash "$TARGET_SCRIPT" docs/features/daily-report.md --base "$WS" 2>/dev/null)"
assert_eq "--base で走査対象のリポジトリを明示できる" "3" "$(jq -r '.counts.references' <<<"$BASE_OUT")"

echo "=== test: --adr-dir の正規化と差し替え ==="
assert_eq "末尾スラッシュ無しを正規化する" "docs/adr/" "$(rs_normalize_dir_prefix "docs/adr")"
assert_eq "先頭の ./ を落とす" "docs/adr/" "$(rs_normalize_dir_prefix "./docs/adr/")"
assert_eq "末尾スラッシュの重複を1つに畳む" "docs/adr/" "$(rs_normalize_dir_prefix "docs/adr///")"
assert_eq "空文字は空のまま返す（呼び出し側が exit 2 にする）" "" "$(rs_normalize_dir_prefix "")"

# 置き場を差し替えると、既定の docs/adr は除外されなくなる（＝ references 側へ回る）
MOVED_OUT="$(run_sweep docs/features/daily-report.md --adr-dir "docs/decisions")"
assert_eq "--adr-dir を差し替えると docs/adr は除外されない" "1" \
  "$(jq -r '[.references[] | select(.file | startswith("docs/adr/"))] | length' <<<"$MOVED_OUT")"
assert_eq "差し替え後の excluded_dirs を出力に反映する" "docs/decisions/" \
  "$(jq -r '.excluded_dirs | join(",")' <<<"$MOVED_OUT")"

echo "=== test: ルート直下の退役パスは弱一致を走らせない（自明な重複を作らない） ==="
ROOT_WS="${TMP_ROOT}/rootws"
mkdir -p "${ROOT_WS}/src"
printf '参照 OLD-NOTES.md がある\n' > "${ROOT_WS}/src/a.ts"
(
  cd "$ROOT_WS" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  git add -A
  git commit -qm init
)
ROOT_OUT="$(cd "$ROOT_WS" && bash "$TARGET_SCRIPT" OLD-NOTES.md 2>/dev/null)"
assert_eq "ルート直下の対象はパス形で1件だけ数える" "1" "$(jq -r '.counts.references' <<<"$ROOT_OUT")"
assert_eq "同じ行を弱一致として重ねない" "0" "$(jq -r '.counts.weak' <<<"$ROOT_OUT")"

echo "=== test: 走査エラーを「参照0件」として通さない（CodeRabbit #189 Major 1） ==="

# git grep の rc は判定していたが、ファイルごとの grep -n はプロセス置換で rc を捨てていた。
# rc≥2（読み取り不能・走査中の消失など）のファイルは「ヒット0件」に化け、他に参照が無ければ
# status: "pass" になる——git grep が一致を報告したファイルなので、これは掃引漏れである。
# 仕様が禁じている「実行エラーをヒット無しとして通す」と同型のため、非0で落ちることを固定する。
# 注入は PATH スタブで行う（実ファイルの権限で rc≥2 を安定に再現できないため）。
STUB_DIR="${TMP_ROOT}/stub-grep"
mkdir -p "$STUB_DIR"
printf '#!/bin/bash\nexit 2\n' > "${STUB_DIR}/grep"
chmod +x "${STUB_DIR}/grep"

GREPFAIL_OUT="$(cd "$WS" && PATH="${STUB_DIR}:$PATH" bash "$TARGET_SCRIPT" docs/features/daily-report.md 2>/dev/null)"
GREPFAIL_EXIT=$?
assert_eq "ファイルごとの grep が rc≥2 なら exit 2（pass にしない）" "2" "$GREPFAIL_EXIT"
assert_eq "その場合の stdout は空（参照0件の JSON を出さない）" "" "$GREPFAIL_OUT"
GREPFAIL_ERR="$(cd "$WS" && PATH="${STUB_DIR}:$PATH" bash "$TARGET_SCRIPT" docs/features/daily-report.md 2>&1 >/dev/null)"
assert_eq "エラー JSON の error は scan failed" "true" \
  "$(if printf '%s' "$GREPFAIL_ERR" | grep -qF -- '"error":"scan failed"'; then echo true; else echo false; fi)"
assert_eq "stderr が失敗したファイルを特定できる" "true" \
  "$(if printf '%s' "$GREPFAIL_ERR" | grep -qF -- 'grep failed (exit 2) for file:'; then echo true; else echo false; fi)"

# 受理方向: rc=1（一致なし）は正常であり、走査エラーとして扱わない
STUB_NOMATCH="${TMP_ROOT}/stub-grep-nomatch"
mkdir -p "$STUB_NOMATCH"
printf '#!/bin/bash\nexit 1\n' > "${STUB_NOMATCH}/grep"
chmod +x "${STUB_NOMATCH}/grep"
NOMATCH_OUT="$(cd "$WS" && PATH="${STUB_NOMATCH}:$PATH" bash "$TARGET_SCRIPT" docs/features/daily-report.md 2>/dev/null)"
NOMATCH_EXIT=$?
assert_eq "grep の rc=1（一致なし）は走査エラーにしない" "0" "$NOMATCH_EXIT"
assert_eq "その場合は参照0件の JSON を出す" "pass" "$(jq -r '.status' <<<"$NOMATCH_OUT")"

echo "=== test: 結果 JSON の組み立てに失敗したら stdout へ出さない（CodeRabbit #189 Major 2） ==="

# set -e は有効でないため、jq の失敗を検査しないと stdout が空のまま先へ進む。
# 参照0件なら exit 0 になり、呼び出し側は「JSON の無い exit 0」を受け取る
# （仕様の「stdout に JSON を1個出す」契約が破れる）。
STUB_JQ="${TMP_ROOT}/stub-jq"
mkdir -p "$STUB_JQ"
printf '#!/bin/bash\nexit 1\n' > "${STUB_JQ}/jq"
chmod +x "${STUB_JQ}/jq"

JQFAIL_OUT="$(cd "$WS" && PATH="${STUB_JQ}:$PATH" bash "$TARGET_SCRIPT" docs/features/never-referenced.md 2>/dev/null)"
JQFAIL_EXIT=$?
assert_eq "jq が失敗したら exit 2（参照0件でも exit 0 にしない）" "2" "$JQFAIL_EXIT"
assert_eq "その場合の stdout は空（不完全な JSON を出さない）" "" "$JQFAIL_OUT"
JQFAIL_ERR="$(cd "$WS" && PATH="${STUB_JQ}:$PATH" bash "$TARGET_SCRIPT" docs/features/never-referenced.md 2>&1 >/dev/null)"
assert_eq "エラー JSON の error は json build failed" "true" \
  "$(if printf '%s' "$JQFAIL_ERR" | grep -qF -- '"error":"json build failed"'; then echo true; else echo false; fi)"

# 参照が残るケースでも同じ（references を読めないまま exit 1 にしない）
JQFAIL_REF_OUT="$(cd "$WS" && PATH="${STUB_JQ}:$PATH" bash "$TARGET_SCRIPT" docs/features/daily-report.md 2>/dev/null)"
JQFAIL_REF_EXIT=$?
assert_eq "参照が残るケースでも jq 失敗は exit 2（exit 1 にしない）" "2" "$JQFAIL_REF_EXIT"
assert_eq "その場合の stdout も空" "" "$JQFAIL_REF_OUT"

echo "=== test: 二重計上の判定は退役パスごとに行う（CodeRabbit #189 Minor 1） ==="

# 1行が2つの退役文書に言及し、片方はパス形・もう片方はファイル名だけ、という行がある。
# 既出判定に target を含めないと、パス形のヒットが**別 target の弱一致を落とす**
# （仕分け候補が出力から消える）。複数パスの一括掃引は本スクリプトの通常運用。
MULTI_WS="${TMP_ROOT}/multitarget"
mkdir -p "${MULTI_WS}/docs/a" "${MULTI_WS}/docs/b" "${MULTI_WS}/src"
printf 'see docs/a/x.md and also y.md\n' > "${MULTI_WS}/src/both.ts"
(
  cd "$MULTI_WS" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  git add -A
  git commit -qm init
)
MT_OUT="$(cd "$MULTI_WS" && bash "$TARGET_SCRIPT" docs/a/x.md docs/b/y.md 2>/dev/null)"
assert_eq "A のパス形ヒットは references に入る" "1" \
  "$(jq -r '[.references[] | select(.target == "docs/a/x.md" and .file == "src/both.ts")] | length' <<<"$MT_OUT")"
assert_eq "同じ行にある B の弱一致が A のヒットに落とされない" "1" \
  "$(jq -r '[.weak_matches[] | select(.target == "docs/b/y.md" and .file == "src/both.ts")] | length' <<<"$MT_OUT")"
assert_eq "A 自身はパス形で拾った行を弱一致として重ねない" "0" \
  "$(jq -r '[.weak_matches[] | select(.target == "docs/a/x.md" and .file == "src/both.ts")] | length' <<<"$MT_OUT")"

echo "=== test: 変更履歴（CHANGELOG）の削除告知は除外するが、黙って捨てない ==="

# 変更履歴の破壊的変更節は「<path> を削除した」と書く場所であり、ADR の出所記録と同じく
# **削除された事実の記録**であって被参照ではない。除外しないと、削除した PR 自身が
# 恒久的な fail の原因を作り、「参照 0 件」を exit code で判定できなくなる。
# 既存フィクスチャ（WS）は CHANGELOG.md を持たない＝「無くても壊れない」側の検証を兼ねるため、
# 変更履歴の検証は別フィクスチャで行う（WS の既存の件数アサーションを動かさない）。
CL_WS="${TMP_ROOT}/changelog"
mkdir -p "${CL_WS}/docs/adr" "${CL_WS}/src"
# shellcheck disable=SC2016 # バッククォートは markdown のインラインコード（展開させない）
printf '# 変更履歴\n\n## 2.0.0\n\n- `docs/features/gone.md` を削除した\n- 旧 gone.md の内容は ADR 0001 へ移した\n- `docs/features/only-cl.md` を削除した\n' > "${CL_WS}/CHANGELOG.md"
printf '// 設計根拠: docs/features/gone.md の 1 節\n' > "${CL_WS}/src/real.ts"
printf '# ADR 0001\n宣言元は退役した docs/features/gone.md\n' > "${CL_WS}/docs/adr/0001-x.md"
(
  cd "$CL_WS" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  git add -A
  git commit -qm init
)
run_cl() { (cd "$CL_WS" && bash "$TARGET_SCRIPT" "$@" 2>/dev/null); }

CL_OUT="$(run_cl docs/features/gone.md)"
CL_EXIT=$?
assert_eq "変更履歴のヒットは references に入らない" "0" \
  "$(jq -r '[.references[] | select(.file == "CHANGELOG.md")] | length' <<<"$CL_OUT")"
assert_eq "本物の参照は references に残る（除外が広がっていない）" "src/real.ts" \
  "$(jq -r '[.references[].file] | join(",")' <<<"$CL_OUT")"
assert_eq "本物の参照が残るので exit 1" "1" "$CL_EXIT"
assert_eq "変更履歴のヒットは excluded に入る（ADR の1件と合わせて3件）" "3" \
  "$(jq -r '.counts.excluded' <<<"$CL_OUT")"
assert_eq "excluded に CHANGELOG.md のヒットが含まれる" "2" \
  "$(jq -r '[.excluded[] | select(.file == "CHANGELOG.md")] | length' <<<"$CL_OUT")"
assert_eq "excluded_files を出力する（掃引範囲を目視できる）" "CHANGELOG.md" \
  "$(jq -r '.excluded_files | join(",")' <<<"$CL_OUT")"
# 変更履歴内のファイル名だけの言及（`gone.md`）も excluded へ回す。weak へ落とすと
# 「除外した」と「弱一致として仕分け対象に出した」が混ざり、除外の意味が消える。
assert_eq "変更履歴内の弱一致も weak ではなく excluded へ回す" "0" \
  "$(jq -r '[.weak_matches[] | select(.file == "CHANGELOG.md")] | length' <<<"$CL_OUT")"

echo "=== test: 変更履歴にしか参照が無ければ pass（削除した PR が自分で fail を作らない） ==="
CLONLY_OUT="$(run_cl docs/features/only-cl.md)"
CLONLY_EXIT=$?
assert_eq "変更履歴だけのヒットなら exit 0" "0" "$CLONLY_EXIT"
assert_eq "status は pass" "pass" "$(jq -r '.status' <<<"$CLONLY_OUT")"
assert_eq "references は0件" "0" "$(jq -r '.counts.references' <<<"$CLONLY_OUT")"
assert_eq "ただし黙って捨てず excluded に数える" "1" "$(jq -r '.counts.excluded' <<<"$CLONLY_OUT")"

echo "=== test: 除外した件数を stderr にも出す ==="
CL_STDERR="$( (cd "$CL_WS" && bash "$TARGET_SCRIPT" docs/features/only-cl.md 2>&1 >/dev/null) )"
assert_eq "stderr に除外の件数と対象を出す" "true" \
  "$(if printf '%s' "$CL_STDERR" | grep -qF -- 'CHANGELOG.md' && printf '%s' "$CL_STDERR" | grep -qF -- '1 件'; then echo true; else echo false; fi)"

echo "=== test: 除外は汎用化していない（任意のパスを外せない） ==="
# (a) 差し替えると既定の CHANGELOG.md は除外されなくなる＝除外は名指しの1ファイルだけに効く
CL_MOVED="$(run_cl docs/features/only-cl.md --changelog "docs/HISTORY.md")"
CL_MOVED_EXIT=$?
assert_eq "--changelog を差し替えると CHANGELOG.md は除外されない" "1" \
  "$(jq -r '[.references[] | select(.file == "CHANGELOG.md")] | length' <<<"$CL_MOVED")"
assert_eq "その結果 status は fail（未知のパスは黙って除外されない）" "1" "$CL_MOVED_EXIT"
assert_eq "差し替え後の excluded_files を出力に反映する" "docs/HISTORY.md" \
  "$(jq -r '.excluded_files | join(",")' <<<"$CL_MOVED")"
# (b) ディレクトリは受け付けない（木ごと外せる形にすると汎用 --exclude と同じになる）
CL_DIR_OUT="$(run_cl docs/features/gone.md --changelog "src/")"
CL_DIR_EXIT=$?
assert_eq "--changelog にディレクトリを渡すと exit 2" "2" "$CL_DIR_EXIT"
assert_eq "その場合の stdout は空" "" "$CL_DIR_OUT"
CL_DIR_ERR="$( (cd "$CL_WS" && bash "$TARGET_SCRIPT" docs/features/gone.md --changelog "src/" 2>&1 >/dev/null) )"
assert_eq "エラー JSON の error は changelog path is a directory" "true" \
  "$(if printf '%s' "$CL_DIR_ERR" | grep -qF -- '"error":"changelog path is a directory"'; then echo true; else echo false; fi)"
# (c) 除外を空にして無効化することもできない（--adr-dir と同じ規定）
CL_EMPTY_OUT="$(run_cl docs/features/gone.md --changelog "")"
CL_EMPTY_EXIT=$?
assert_eq "--changelog が空文字なら exit 2（除外を空にできない）" "2" "$CL_EMPTY_EXIT"
assert_eq "その場合の stdout は空" "" "$CL_EMPTY_OUT"
CL_NOVAL_OUT="$(run_cl docs/features/gone.md --changelog)"
CL_NOVAL_EXIT=$?
assert_eq "--changelog に値が無ければ exit 2" "2" "$CL_NOVAL_EXIT"
assert_eq "その場合の stdout は空" "" "$CL_NOVAL_OUT"

echo "=== test: 変更履歴の照合は完全一致（前置き一致にすると木ごと外せてしまう） ==="

# 除外を前置き一致で実装すると、`--changelog docs` のような指定で **docs/ 配下を丸ごと**
# 掃引対象から外せる＝設けないと決めた汎用 --exclude と同じものになる。末尾スラッシュの
# 拒否だけでは防げない（`docs` にはスラッシュが無い）ため、照合形そのものを固定する。
PFX_WS="${TMP_ROOT}/prefix"
mkdir -p "${PFX_WS}/src"
# shellcheck disable=SC2016 # 同上。`--` は書式が - 始まりのため
printf -- '- `docs/features/gone.md` を削除した\n' > "${PFX_WS}/CHANGELOG.md"
printf '退避コピー: docs/features/gone.md への参照\n' > "${PFX_WS}/CHANGELOG.md.bak"
printf '// 設計根拠: docs/features/gone.md\n' > "${PFX_WS}/src/real.ts"
(
  cd "$PFX_WS" || exit 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  git add -A
  git commit -qm init
)
PFX_OUT="$(cd "$PFX_WS" && bash "$TARGET_SCRIPT" docs/features/gone.md 2>/dev/null)"
assert_eq "除外するのは名指しした CHANGELOG.md だけ" "1" \
  "$(jq -r '.counts.excluded' <<<"$PFX_OUT")"
# 前置き一致だと CHANGELOG.md.bak まで除外され、この件数が 1 に落ちる。
assert_eq "前置きが一致するだけの別ファイル（CHANGELOG.md.bak）は除外しない" "1" \
  "$(jq -r '[.references[] | select(.file == "CHANGELOG.md.bak")] | length' <<<"$PFX_OUT")"
assert_eq "本物の参照は2件とも references に残る" "2" \
  "$(jq -r '.counts.references' <<<"$PFX_OUT")"

# ディレクトリ名（末尾スラッシュ無し）を渡しても木は外せない。
PFX_DIR_OUT="$(cd "$PFX_WS" && bash "$TARGET_SCRIPT" docs/features/gone.md --changelog "src" 2>/dev/null)"
PFX_DIR_EXIT=$?
assert_eq "--changelog にディレクトリ名を渡しても src/ 配下は除外されない" "1" \
  "$(jq -r '[.references[] | select(.file == "src/real.ts")] | length' <<<"$PFX_DIR_OUT")"
assert_eq "その場合 status は fail のまま（黙って 0 件に見せない）" "1" "$PFX_DIR_EXIT"
assert_eq "名指しが外れたので CHANGELOG.md も references へ回る" "1" \
  "$(jq -r '[.references[] | select(.file == "CHANGELOG.md")] | length' <<<"$PFX_DIR_OUT")"

echo "=== test: 変更履歴が無いリポジトリでも壊れない ==="
# WS は CHANGELOG.md を持たない。既定値のままでも走査は成立し、件数は変わらない。
assert_eq "CHANGELOG.md が無くても走査は成立する" "3" "$(jq -r '.counts.references' <<<"$OUT")"
assert_eq "無くても excluded_files は既定値を返す（掃引範囲の宣言）" "CHANGELOG.md" \
  "$(jq -r '.excluded_files | join(",")' <<<"$OUT")"

echo "=== test: rs_normalize_file_path（単一ファイル限定の担保） ==="
assert_eq "先頭の ./ を落とす" "CHANGELOG.md" "$(rs_normalize_file_path "./CHANGELOG.md")"
assert_eq "前後の空白を落とす" "CHANGELOG.md" "$(rs_normalize_file_path "  CHANGELOG.md  ")"
assert_eq "そのままのパスは変えない" "docs/HISTORY.md" "$(rs_normalize_file_path "docs/HISTORY.md")"
# 末尾スラッシュを畳まないのは、呼び出し側が「ディレクトリを渡された」と判定して弾けるようにするため。
# 畳むと docs/ が docs へ化け、ディレクトリ指定が「docs という名のファイル」として黙って通る。
assert_eq "末尾スラッシュは畳まない（ディレクトリ判定を main に残す）" "docs/" "$(rs_normalize_file_path "docs/")"
assert_eq "空文字は空のまま返す（呼び出し側が exit 2 にする）" "" "$(rs_normalize_file_path "")"

echo "=== test: 手順の正本が本スクリプトを退役手順に組み込んでいる ==="

# 散文の手順（正本）とスクリプトが乖離しないよう、手順側が「スイープを必須ステップとして
# 呼ぶこと」と「除外は ADR 置き場であること」を書いていることを固定する。
# 手順に書かれていないスクリプトは実行されず、掃引が実施されないまま退役が完了しうる。
STRATEGY_FILE="${REPO_ROOT}/docs/ai-driven-development-strategy.md"
assert_eq "戦略ドキュメントを読める（読めない状態を pass にしない）" "true" \
  "$(if [ -r "$STRATEGY_FILE" ]; then echo true; else echo false; fi)"
assert_eq "退役手順がスイープスクリプトを名指ししている" "true" \
  "$(if grep -qF -- "retirement-sweep" "$STRATEGY_FILE"; then echo true; else echo false; fi)"
assert_eq "退役手順が除外先（ADR 置き場）に触れている" "true" \
  "$(if grep -qF -- "docs/adr" "$STRATEGY_FILE"; then echo true; else echo false; fi)"

# 既定の除外ディレクトリはスクリプトと仕様の2箇所に現れる。片方だけ動かしても
# 落ちない状態にしない（ずれても誰も検出しない散文の約束にしない）。
SPEC_FILE="${RS_TEST_DIR}/../specs/retirement-sweep.md"
assert_eq "仕様書を読める" "true" \
  "$(if [ -r "$SPEC_FILE" ]; then echo true; else echo false; fi)"
assert_eq "仕様書が既定の除外ディレクトリをスクリプトと同じ値で書いている" "true" \
  "$(if grep -qF -- "既定: \`${RETIREMENT_SWEEP_DEFAULT_ADR_DIR}\`" "$SPEC_FILE"; then echo true; else echo false; fi)"
assert_eq "仕様書が既定の除外ファイルをスクリプトと同じ値で書いている" "true" \
  "$(if grep -qF -- "既定: \`${RETIREMENT_SWEEP_DEFAULT_CHANGELOG}\`" "$SPEC_FILE"; then echo true; else echo false; fi)"
# 除外集合の正本は仕様の列挙。除外を増やすときに「理由つきで列挙する」規約が
# 守られているかを、列挙表の見出し語で機械的に固定する（黙って除外だけ増やさせない）。
assert_eq "仕様書が除外集合を理由つきの表として列挙している" "true" \
  "$(if grep -qF -- "| 何を書いている場所か | 消してはいけない理由 |" "$SPEC_FILE"; then echo true; else echo false; fi)"

# exit 2 の error 語彙は呼び出し側が分岐に使う契約。スクリプトが出す値が仕様に載っていない
# 状態を残さない（載っていない値は「呼び出し側が知らない値」になる）。
for code in "scan failed" "json build failed" "retired path still present" "not a git work tree" \
  "empty changelog path" "changelog path is a directory" "--changelog requires a value"; do
  assert_eq "仕様書が error 語彙 '${code}' を載せている" "true" \
    "$(if grep -qF -- "\`${code}\`" "$SPEC_FILE"; then echo true; else echo false; fi)"
done

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
