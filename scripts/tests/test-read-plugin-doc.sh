#!/bin/bash
# test-read-plugin-doc.sh
# scripts/read-plugin-doc.sh の契約を検証する。
# - 開始／終端マーカーで本文を挟み、マーカーを除いた本文が原本とバイト同一であること
# - 大きいファイルの分割配送（MORE マーカー・--from-line での続き取得・再結合のバイト一致）
# - 失敗が必ず非0 終了で伝わる（沈黙しない）。失敗時 stdout は空
# - cwd 非依存（プラグイン外のどこから呼んでも同じ結果になる）
# - 配送対象サブツリーの fail-closed な allowlist（判定関数の自己検査を含む）
# - 絶対パス・'..'・シンボリックリンク・ルート外へ抜けるパスの拒否
# - プラグインルート解決不能（インストール破損）の検出
# - 0 バイト・パイプ早期終了・範囲外 --from-line が「配送成功」に化けないこと
#
# **stdout / stderr の分離そのものは不変条件にしない**: Bash ツールは両者を1つのテキストに
# まとめてモデルへ渡すため、OS の fd 上での分離は配送境界で消える。モデルから見て本文と
# 制御情報を区別できる根拠は**マーカーによる framing** であり、そちらを固定する。
#
# 実機の ~/.claude には一切触れず、実ファイル検証はこのリポジトリ自身を、
# 異常系は mktemp -d 配下に作った偽のプラグインツリーを対象に行う。
#
# 実行方法: bash scripts/tests/test-read-plugin-doc.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
TARGET_SCRIPT="${REPO_ROOT}/scripts/read-plugin-doc.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2329 # trap 経由で呼ばれるため直接呼び出しが無くても false positive
cleanup() {
  [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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
  local description="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      PASS_COUNT=$((PASS_COUNT + 1))
      echo "  ok - ${description}"
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("$description")
      echo "  NG - ${description}"
      echo "       expected to contain: ${needle}"
      echo "       actual:              ${haystack}"
      ;;
  esac
}

OUT_FILE="${WORK_DIR}/stdout.txt"
ERR_FILE="${WORK_DIR}/stderr.txt"
LAST_STATUS=0

# 対象スクリプトを実行し、stdout/stderr をファイルへ、終了コードを LAST_STATUS へ。
# 第1引数に実行時の cwd を取る（cwd 非依存の検証に使う）。
run_rpd() {
  local cwd="$1"
  shift
  local script="${RPD_SCRIPT_UNDER_TEST:-$TARGET_SCRIPT}"
  (cd "$cwd" && bash "$script" "$@") >"$OUT_FILE" 2>"$ERR_FILE"
  LAST_STATUS=$?
}

# ---------------------------------------------------------------------------
# 1. 正常系: 実ファイルのバイト同一配送
# ---------------------------------------------------------------------------
echo "=== (1) 実ファイルのバイト同一配送 ==="

SAMPLE_REL="skills/pr-merge/references/conflict-resolution.md"
run_rpd "$REPO_ROOT" "$SAMPLE_REL"
assert_eq "配送に成功する (exit 0)" "0" "$LAST_STATUS"

# 開始マーカーは**本文より前**に出ていること。出力上限による切り詰めは先頭側を残すため、
# 前に置いたものだけが確実に読み手へ届く（後ろに置いた情報は大きいファイルで消える）。
assert_contains "1行目が BEGIN マーカーである" \
  "=== read-plugin-doc BEGIN path=${SAMPLE_REL}" "$(head -1 "$OUT_FILE")"
assert_contains "BEGIN マーカーに全体バイト数が入る" "bytes=2544" "$(head -1 "$OUT_FILE")"
assert_contains "BEGIN マーカーに配送元 root が入る" "root=${REPO_ROOT}" "$(head -1 "$OUT_FILE")"
assert_contains "BEGIN マーカーに version が入る" "version=" "$(head -1 "$OUT_FILE")"

# 終端マーカーは本文の後ろ。呼び出し側はこの**不在**を切り詰めの検査に使う。
assert_contains "最終行が END マーカー（complete）である" \
  "=== read-plugin-doc END path=${SAMPLE_REL} delivered-lines=1-41 complete ===" "$(tail -1 "$OUT_FILE")"

# マーカー行を除いた本文が原本とバイト同一であること
sed '1d;$d' "$OUT_FILE" > "${WORK_DIR}/body.txt"
if cmp -s "${WORK_DIR}/body.txt" "${REPO_ROOT}/${SAMPLE_REL}"; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - マーカーを除いた本文が対象ファイルとバイト同一である"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("マーカーを除いた本文が対象ファイルとバイト同一である")
  echo "  NG - マーカーを除いた本文が対象ファイルとバイト同一である"
fi

# レシートには配送元 root と version が入ること。ランチャーはインストール済みの
# 最大バージョンを選ぶため、起動中スキルと配送元が自動では一致しない。
# 一致を呼び出し側が確かめられる材料をレシートが持っていることを固定する。
assert_contains "レシートが stderr に出る" "delivered ${SAMPLE_REL}" "$(cat "$ERR_FILE")"
assert_contains "レシートに配送元 root が入る" "from ${REPO_ROOT}" "$(cat "$ERR_FILE")"
assert_contains "レシートに version が入る" "@" "$(cat "$ERR_FILE")"

# **本文（マーカー行の内側）に制御情報が混入していないこと**を固定する。
# 旧テストは「リダイレクトした stdout ファイルにレシートが混ざらないこと」を検証していたが、
# それは OS の fd 分離を見ているだけで、Bash ツールが stdout と stderr を1つのテキストへ
# まとめる配送境界では消える不変条件だった。モデルから見て意味があるのは
# 「マーカーで囲まれた内側が本文そのものであること」なので、そちらを検査する。
if grep -Fq "read-plugin-doc" "${WORK_DIR}/body.txt"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("マーカーの内側に制御情報が混入していない")
  echo "  NG - マーカーの内側に制御情報が混入していない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - マーカーの内側に制御情報が混入していない"
fi

# ---------------------------------------------------------------------------
# 2. cwd 非依存
# ---------------------------------------------------------------------------
echo ""
echo "=== (2) cwd 非依存 ==="

# 配送経路の目的は「導入先プロジェクトの cwd から、プラグイン配下の文書を読む」ことなので、
# cwd がプラグイン外でも同じ結果にならなければ意味がない。
run_rpd "$WORK_DIR" "$SAMPLE_REL"
assert_eq "プラグイン外の cwd から呼んでも成功する" "0" "$LAST_STATUS"
sed '1d;$d' "$OUT_FILE" > "${WORK_DIR}/body.txt"
if cmp -s "${WORK_DIR}/body.txt" "${REPO_ROOT}/${SAMPLE_REL}"; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - プラグイン外の cwd でも本文が同一である"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("プラグイン外の cwd でも本文が同一である")
  echo "  NG - プラグイン外の cwd でも本文が同一である"
fi

# 導入先プロジェクトに同名パスが存在しても、そちらを読まないこと（裸の相対パス解決との違い）
mkdir -p "${WORK_DIR}/decoy/skills/pr-merge/references"
printf 'DECOY - 導入先プロジェクト側の同名ファイル\n' \
  >"${WORK_DIR}/decoy/skills/pr-merge/references/conflict-resolution.md"
run_rpd "${WORK_DIR}/decoy" "$SAMPLE_REL"
assert_eq "cwd 側の同名ファイルがあっても成功する" "0" "$LAST_STATUS"
if grep -Fq "DECOY" "$OUT_FILE"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("cwd 側の同名ファイルを読まない")
  echo "  NG - cwd 側の同名ファイルを読まない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - cwd 側の同名ファイルを読まない"
fi

# ---------------------------------------------------------------------------
# 3. 引数不正の拒否（exit 64）
# ---------------------------------------------------------------------------
echo ""
echo "=== (3) 引数不正の拒否 ==="

run_rpd "$REPO_ROOT"
assert_eq "引数なしは exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "$SAMPLE_REL" extra
assert_eq "引数が2個は exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" ""
assert_eq "空文字は exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "/etc/passwd"
assert_eq "絶対パスは exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "skills/../../etc/passwd"
assert_eq "'..' を含むパスは exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "skills/pr-merge/references/../../../README.md"
assert_eq "途中に '..' を含むパスも exit 64" "64" "$LAST_STATUS"

# 失敗時に stdout を空に保つ（部分的な本文が「読めた」ように見えないため）
if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("引数不正時の stdout は空である")
  echo "  NG - 引数不正時の stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 引数不正時の stdout は空である"
fi

# 失敗は必ず「停止して報告せよ」という行動指示を伴う（沈黙で続行させないため）
assert_contains "失敗時の stderr に停止指示が含まれる" "停止して" "$(cat "$ERR_FILE")"

# ---------------------------------------------------------------------------
# 4. 配送対象外の拒否（exit 77）
# ---------------------------------------------------------------------------
echo ""
echo "=== (4) 配送対象外の拒否 ==="

run_rpd "$REPO_ROOT" "docs/plugin-path-conventions.md"
assert_eq "docs/ 配下は配送対象外 (exit 77)" "77" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "bin/claude-harness-run"
assert_eq "bin/ 配下は配送対象外 (exit 77)" "77" "$LAST_STATUS"

run_rpd "$REPO_ROOT" ".claude-plugin/plugin.json"
assert_eq ".claude-plugin/ 配下は配送対象外 (exit 77)" "77" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "scripts/read-plugin-doc.sh"
assert_eq "scripts/ 直下のスクリプトは配送対象外 (exit 77)" "77" "$LAST_STATUS"

if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("配送対象外の stdout は空である")
  echo "  NG - 配送対象外の stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 配送対象外の stdout は空である"
fi

# ---------------------------------------------------------------------------
# 5. 対象なしの拒否（exit 66）
# ---------------------------------------------------------------------------
echo ""
echo "=== (5) 対象なしの拒否 ==="

run_rpd "$REPO_ROOT" "skills/pr-merge/references/does-not-exist.md"
assert_eq "存在しない参照ファイルは exit 66" "66" "$LAST_STATUS"
assert_contains "存在しない場合も停止指示を伴う" "停止して" "$(cat "$ERR_FILE")"

if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("対象なしの stdout は空である")
  echo "  NG - 対象なしの stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 対象なしの stdout は空である"
fi

# ---------------------------------------------------------------------------
# 6. --help
# ---------------------------------------------------------------------------
echo ""
echo "=== (6) --help ==="

run_rpd "$REPO_ROOT" --help
assert_eq "--help は exit 0" "0" "$LAST_STATUS"
assert_contains "--help は配送対象を案内する" "skills/<skill>/references/" "$(cat "$ERR_FILE")"

# --help も exit 0 を返すため、exit code だけでは「本文が届いたか」を判定できない。
# 判定基準を BEGIN マーカーの有無に寄せてあるので、--help では stdout が空であることを固定する。
if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("--help の stdout は空である")
  echo "  NG - --help の stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - --help の stdout は空である（exit 0 でも BEGIN マーカーが無い＝未配送）"
fi

# ---------------------------------------------------------------------------
# 7. 偽プラグインツリーでの境界検証
# ---------------------------------------------------------------------------
echo ""
echo "=== (7) 偽プラグインツリーでの境界検証 ==="

FAKE_ROOT="${WORK_DIR}/fake-plugin"
OUTSIDE_DIR="${WORK_DIR}/outside"
mkdir -p "${FAKE_ROOT}/.claude-plugin" "${FAKE_ROOT}/scripts" \
  "${FAKE_ROOT}/skills/demo/references" "${OUTSIDE_DIR}"
printf '{"name":"claude-harness"}\n' >"${FAKE_ROOT}/.claude-plugin/plugin.json"
cp "$TARGET_SCRIPT" "${FAKE_ROOT}/scripts/read-plugin-doc.sh"
printf 'plain content\n' >"${FAKE_ROOT}/skills/demo/references/plain.md"
printf 'SECRET OUTSIDE\n' >"${OUTSIDE_DIR}/secret.md"
ln -s "${OUTSIDE_DIR}/secret.md" "${FAKE_ROOT}/skills/demo/references/link.md"
ln -s "$OUTSIDE_DIR" "${FAKE_ROOT}/skills/demo/templates"

RPD_SCRIPT_UNDER_TEST="${FAKE_ROOT}/scripts/read-plugin-doc.sh"

run_rpd "$WORK_DIR" "skills/demo/references/plain.md"
assert_eq "偽ツリーでも実体ファイルは配送できる" "0" "$LAST_STATUS"

# 配送対象パターンに合致していても、通常ファイルでなければ「読めた」にしない
mkdir -p "${FAKE_ROOT}/skills/demo/references/a-directory.md"
run_rpd "$WORK_DIR" "skills/demo/references/a-directory.md"
assert_eq "配送対象パターンに合致するディレクトリは exit 66" "66" "$LAST_STATUS"

run_rpd "$WORK_DIR" "skills/demo/references/link.md"
assert_eq "シンボリックリンクは配送しない (exit 77)" "77" "$LAST_STATUS"
if grep -Fq "SECRET OUTSIDE" "$OUT_FILE"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("リンク先の中身を出力しない")
  echo "  NG - リンク先の中身を出力しない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - リンク先の中身を出力しない"
fi

# 親ディレクトリ側がリンクでプラグイン外へ抜ける形（パス文字列上はサブツリー内に見える）
run_rpd "$WORK_DIR" "skills/demo/templates/secret.md"
assert_eq "親ディレクトリのリンク経由でルート外へ抜ける形を拒否する (exit 77)" "77" "$LAST_STATUS"
if grep -Fq "SECRET OUTSIDE" "$OUT_FILE"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("ディレクトリリンク経由でも中身を出力しない")
  echo "  NG - ディレクトリリンク経由でも中身を出力しない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - ディレクトリリンク経由でも中身を出力しない"
fi

# プラグインルートを解決できない配置（インストール破損）
BROKEN_ROOT="${WORK_DIR}/broken"
mkdir -p "${BROKEN_ROOT}/scripts"
cp "$TARGET_SCRIPT" "${BROKEN_ROOT}/scripts/read-plugin-doc.sh"
RPD_SCRIPT_UNDER_TEST="${BROKEN_ROOT}/scripts/read-plugin-doc.sh"
run_rpd "$WORK_DIR" "skills/demo/references/plain.md"
assert_eq "プラグインルート不在は exit 69" "69" "$LAST_STATUS"

unset RPD_SCRIPT_UNDER_TEST

# ---------------------------------------------------------------------------
# 7b. 分割配送（出力上限による沈黙する部分成功の封じ込め）
# ---------------------------------------------------------------------------
echo ""
echo "=== (7b) 分割配送 ==="

# 本 PR の目的は「沈黙する失敗を潰す」ことだが、モデルが受け取るのは Bash ツールの出力で
# あり、そこには上限がある。上限超過時に exit 0 のまま本文が途中で切れると、
# 潰したはずの「9割正しい成果物」がそのまま再現する。自分で分割して MORE マーカーと
# 続きの取得コマンドを出すことで、切り詰めに到達させない／到達しても検知できるようにする。

BIG_REL="skills/para-impl/references/star-parallel.md"
BIG_BYTES="$(wc -c <"${REPO_ROOT}/${BIG_REL}" | tr -d '[:space:]')"

run_rpd "$REPO_ROOT" "$BIG_REL"
assert_eq "大きいファイルでも exit 0 で返る" "0" "$LAST_STATUS"

chunk_bytes="$(wc -c <"$OUT_FILE" | tr -d '[:space:]')"
if [ "$chunk_bytes" -lt "$BIG_BYTES" ] && [ "$chunk_bytes" -lt 20000 ]; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 1回の出力が上限より十分小さく抑えられている（${chunk_bytes} / 全体 ${BIG_BYTES} バイト）"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("1回の出力が上限より十分小さく抑えられている")
  echo "  NG - 1回の出力が抑えられていない（${chunk_bytes} バイト）"
fi

assert_contains "続きがある場合は MORE マーカーが出る" \
  "=== read-plugin-doc MORE path=${BIG_REL}" "$(tail -2 "$OUT_FILE" | head -1)"
assert_contains "続きの取得コマンドをそのまま提示する" \
  "claude-harness-run read-plugin-doc \"${BIG_REL}\" --from-line" "$(tail -1 "$OUT_FILE")"

# 続きがある回では END（complete）を出さない。END を出してしまうと
# 「本文は完結している」という誤った判定材料を渡すことになる。
if grep -Fq "complete ===" "$OUT_FILE"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("続きがある回に END(complete) を出さない")
  echo "  NG - 続きがある回に END(complete) を出さない"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 続きがある回に END(complete) を出さない"
fi

# 全チャンクを順に取得して再結合し、原本とバイト一致することを確認する。
# 分割は行境界で行っているので、UTF-8 の文字境界を割らない。
: > "${WORK_DIR}/reassembled.txt"
chunk_from=1
chunk_count=0
reassemble_status="ok"
while [ "$chunk_count" -lt 30 ]; do
  run_rpd "$REPO_ROOT" "$BIG_REL" --from-line "$chunk_from"
  if [ "$LAST_STATUS" -ne 0 ]; then reassemble_status="exit ${LAST_STATUS}"; break; fi
  chunk_count=$((chunk_count + 1))
  last_line="$(tail -1 "$OUT_FILE")"
  case "$last_line" in
    *"complete ==="*)
      sed '1d;$d' "$OUT_FILE" >> "${WORK_DIR}/reassembled.txt"
      break
      ;;
    *"続きの取得"*)
      # BEGIN(1行) と MORE + 続きの取得(末尾2行) を除いた範囲が本文
      sed '1d;$d' "$OUT_FILE" | sed '$d' >> "${WORK_DIR}/reassembled.txt"
      chunk_from="$(tail -2 "$OUT_FILE" | head -1 | sed -n 's/.*next-from-line=\([0-9]*\) .*/\1/p')"
      if [ -z "$chunk_from" ]; then reassemble_status="next-from-line を読み取れない"; break; fi
      ;;
    *)
      reassemble_status="想定外の最終行: ${last_line}"
      break
      ;;
  esac
done

if [ "$reassemble_status" != "ok" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("全チャンクを取得できる")
  echo "  NG - 全チャンクを取得できる（${reassemble_status}）"
elif [ "$chunk_count" -lt 2 ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("大きいファイルが実際に複数チャンクへ分かれる")
  echo "  NG - 大きいファイルが実際に複数チャンクへ分かれる（chunk=${chunk_count}）"
elif cmp -s "${WORK_DIR}/reassembled.txt" "${REPO_ROOT}/${BIG_REL}"; then
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 全チャンク（${chunk_count} 個）の再結合が原本とバイト一致する"
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("全チャンクの再結合が原本とバイト一致する")
  echo "  NG - 全チャンクの再結合が原本とバイト一致する"
fi

# 最終チャンクは END(complete) で閉じること（終端マーカーの不在＝切り詰めの検査が成立する前提）
assert_contains "最終チャンクは END(complete) で閉じる" "complete ===" "$(tail -1 "$OUT_FILE")"

# --- 部分配送のレシートが「全量を配送した」と読めないこと ---
# レシートは本文の**後ろに来る最後の1行**であり、要約として読まれやすい位置にある。
# ここで完全配送と同じ文言・同じバイト数を出すと、直前の MORE マーカーが正確でも
# **部分成功が完全成功として報告される**（本スクリプトが潰そうとしている欠陥そのもの）。
# 区別が機械的にも人間にも付くことを固定する。

run_rpd "$REPO_ROOT" "$BIG_REL"
partial_receipt="$(cat "$ERR_FILE")"
run_rpd "$REPO_ROOT" "$SAMPLE_REL"
complete_receipt="$(cat "$ERR_FILE")"

assert_contains "部分配送のレシートは PARTIAL で始まる" \
  "read-plugin-doc: PARTIAL ${BIG_REL}" "$partial_receipt"
assert_contains "部分配送のレシートは配送済み量と全体量を併記する" \
  "/${BIG_BYTES} bytes" "$partial_receipt"
assert_contains "部分配送のレシートは続きの取得コマンドを示す" \
  "--from-line" "$partial_receipt"
assert_contains "完全配送のレシートは complete と明示する" "complete:" "$complete_receipt"

# 部分配送の回に、ファイル全体のバイト数を「配送した量」として出していないこと。
# （旧実装は `delivered <path> (53017 bytes)` と出しており、53,017 バイトは配送されていなかった）
case "$partial_receipt" in
  *"delivered ${BIG_BYTES}/"*)
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("部分配送で全体量を配送済みとして出さない")
    echo "  NG - 部分配送で全体量を配送済みとして出している"
    ;;
  *)
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - 部分配送で全体量を配送済みとして出さない"
    ;;
esac

# 部分配送の回に完全配送の目印（complete）を出さないこと
case "$partial_receipt" in
  *"complete:"*)
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("部分配送のレシートに complete を出さない")
    echo "  NG - 部分配送のレシートに complete を出している"
    ;;
  *)
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - 部分配送のレシートに complete を出さない"
    ;;
esac

# 両者を「パスと数値を伏せた形」まで正規化しても一致しないこと。
# 文言そのものが違うことを要求する（数値だけの違いだと、要約として読んだときに区別が付かない）。
printf '%s\n' "$partial_receipt" | sed 's/[0-9][0-9]*/N/g; s#[A-Za-z0-9_./-]*\.md#PATH#g' > "${WORK_DIR}/p.norm"
printf '%s\n' "$complete_receipt" | sed 's/[0-9][0-9]*/N/g; s#[A-Za-z0-9_./-]*\.md#PATH#g' > "${WORK_DIR}/c.norm"
if cmp -s "${WORK_DIR}/p.norm" "${WORK_DIR}/c.norm"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("部分配送と完全配送のレシートが同一形にならない")
  echo "  NG - 部分配送と完全配送のレシートが（数値を伏せると）同一形になっている"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 部分配送と完全配送のレシートは正規化しても別形である"
fi

# 完全配送では配送済み量と全体量が一致すること（併記が飾りでないことの確認）
sample_bytes="$(wc -c <"${REPO_ROOT}/${SAMPLE_REL}" | tr -d '[:space:]')"
assert_contains "完全配送では配送済み量＝全体量" \
  "${sample_bytes}/${sample_bytes} bytes" "$complete_receipt"

# --max-bytes で分割幅を変えられること（既定に依存せず検証できるようにする）
run_rpd "$REPO_ROOT" "$SAMPLE_REL" --max-bytes 1024
assert_eq "--max-bytes で小さく刻んでも exit 0" "0" "$LAST_STATUS"
assert_contains "--max-bytes を小さくすると分割される" "MORE path=" "$(tail -2 "$OUT_FILE" | head -1)"

run_rpd "$REPO_ROOT" "$SAMPLE_REL" --max-bytes 100
assert_eq "--max-bytes が下限未満なら exit 64" "64" "$LAST_STATUS"

run_rpd "$REPO_ROOT" "$SAMPLE_REL" --from-line 99999
assert_eq "--from-line が行数を超えたら exit 64" "64" "$LAST_STATUS"
if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("範囲外 --from-line の stdout は空である")
  echo "  NG - 範囲外 --from-line の stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 範囲外 --from-line の stdout は空である"
fi

run_rpd "$REPO_ROOT" "$SAMPLE_REL" --from-line abc
assert_eq "--from-line が非数値なら exit 64" "64" "$LAST_STATUS"
run_rpd "$REPO_ROOT" "$SAMPLE_REL" --bogus
assert_eq "未知のフラグは exit 64" "64" "$LAST_STATUS"

# ---------------------------------------------------------------------------
# 7c. 0 バイト・パイプ早期終了
# ---------------------------------------------------------------------------
echo ""
echo "=== (7c) 0 バイト・パイプ早期終了 ==="

: > "${FAKE_ROOT}/skills/demo/references/empty.md"
RPD_SCRIPT_UNDER_TEST="${FAKE_ROOT}/scripts/read-plugin-doc.sh"

# 0 バイトを exit 0 で返すと、呼び出し側の唯一の停止条件（非0 終了）をすり抜けて
# 「読めた」と判断される。チェックアウト破損・書き込み失敗で現実に起こりうる形。
run_rpd "$WORK_DIR" "skills/demo/references/empty.md"
assert_eq "0 バイトの参照ファイルは exit 66" "66" "$LAST_STATUS"
assert_contains "0 バイトでも停止指示を伴う" "停止して" "$(cat "$ERR_FILE")"
if [ -s "$OUT_FILE" ]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("0 バイト時の stdout は空である")
  echo "  NG - 0 バイト時の stdout は空である"
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ok - 0 バイト時の stdout は空である（BEGIN マーカーも出さない）"
fi
unset RPD_SCRIPT_UNDER_TEST

# パイプの早期終了は「対象が無い」ではない。本文を分割して読もうとして `| head -N` するのは
# 自然な行動であり、それを「ファイルが存在しない」と診断すると原因の切り分けを誤らせる。
(cd "$REPO_ROOT" && bash "$TARGET_SCRIPT" "$BIG_REL" 2>"${WORK_DIR}/pipe.err" | head -1 >/dev/null)
pipe_err="$(cat "${WORK_DIR}/pipe.err")"
case "$pipe_err" in
  *"SIGPIPE"*)
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - パイプ早期終了を SIGPIPE として診断する（「対象なし」と誤診しない）"
    ;;
  *)
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("パイプ早期終了を SIGPIPE として診断する")
    echo "  NG - パイプ早期終了を SIGPIPE として診断する（actual: ${pipe_err}）"
    ;;
esac
case "$pipe_err" in
  *"document not found"*)
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("パイプ早期終了を「対象なし」と報告しない")
    echo "  NG - パイプ早期終了を「対象なし」と報告している"
    ;;
  *)
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - パイプ早期終了を「対象なし」と報告しない"
    ;;
esac

# ---------------------------------------------------------------------------
# 8. 配送対象 allowlist の自己検査
# ---------------------------------------------------------------------------
echo ""
echo "=== (8) 配送対象 allowlist の自己検査 ==="

# 判定を一箇所（rpd_is_deliverable）に閉じ込めてあるので、その関数を直接叩いて
# 「許すべき形」「拒むべき形」の両方を確認する。パターンが壊れたときに、
# 通るはずのものが通らない／通ってはいけないものが通る、のどちらも検出できるようにする。
# shellcheck source=../read-plugin-doc.sh
source "$TARGET_SCRIPT"

assert_deliverable() {
  local description="$1" expected="$2" path="$3"
  local actual="no"
  rpd_is_deliverable "$path" && actual="yes"
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("配送対象判定の自己検査: ${description}")
    echo "  NG - ${description}（expected=${expected} actual=${actual} path=${path}）"
  fi
}

assert_deliverable "許可: skills/*/references/*.md" yes "skills/guarantee-audit/references/bootstrap-mode.md"
assert_deliverable "許可: skills/*/templates/*" yes "skills/define-feature/templates/feature-spec.md"
assert_deliverable "許可: 拡張子なしの templates 配下も許可" yes "skills/init-project/templates/CLAUDE.md.template"
assert_deliverable "許可: scripts/specs/*.md" yes "scripts/specs/list-test-files.md"
assert_deliverable "許可: scripts/README.md" yes "scripts/README.md"
assert_deliverable "拒否: docs/ 配下" no "docs/plugin-path-conventions.md"
assert_deliverable "拒否: bin/ 配下" no "bin/claude-harness-run"
assert_deliverable "拒否: scripts/ 直下のスクリプト" no "scripts/read-plugin-doc.sh"
assert_deliverable "拒否: scripts/config/ 配下" no "scripts/config/sensitive-paths.txt"
assert_deliverable "拒否: SKILL.md 本体（注入済みで配送不要）" no "skills/pr-merge/SKILL.md"
assert_deliverable "拒否: references 配下でも .md 以外" no "skills/demo/references/secret.env"
assert_deliverable "拒否: ルート直下の任意ファイル" no "README.md"
assert_deliverable "拒否: .claude-plugin 配下" no ".claude-plugin/plugin.json"

# ---------------------------------------------------------------------------
echo ""
echo "=== summary ==="
echo "pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "失敗した検証:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi
exit 0
