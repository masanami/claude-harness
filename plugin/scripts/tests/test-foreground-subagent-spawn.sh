#!/bin/bash
# test-foreground-subagent-spawn.sh
# `/impl` の経路（`/impl` → feature-implementer → `/self-review` → レビュアー）で、サブエージェントの
# 起動を前景（`run_in_background: false`）に固定する規約の構造テスト（Issue #262）。
#
# 背景（実測: Claude Code 2.1.283・headless）: サブエージェントの中から `run_in_background` を指定せずに
# Task（Agent）ツールを呼ぶと、結果ではなく「Async agent launched ... working in the background」という
# 起動通知が返る。サブエージェントはターンを終えた時点で呼び出し元へ返却されるため、feature-implementer が
# `/self-review` のレビュアーを起動したまま返却し、レビュアーの結果は最上位のセッションへ後から届いた。
#
# 規約は散文としてスキル・エージェント定義に置かれている（コード側の強制ではない）ため、本テストは
# 規約が成立するための構造を固定する:
#   (F-0) 起動行検査器の自己検査（検査器が壊れていたら以降の照合は無意味）
#   (F-1) 経路上の各ファイルに、前景起動の規約文が逐語で在る
#   (F-2) 経路上の各ファイルで、`subagent_type` を指定する起動行がすべて `run_in_background: false` を持つ
#         （起動箇所が増えたときに、その行だけ背景起動に戻ることを止める）
#   (F-3) 合流できなかったことを返す契約（`self_review: incomplete`）が、出す側（`/self-review`）・
#         転記する側（feature-implementer）・受け取ってやり直す側（`/impl`）の3点で接続されている
#   (F-4) 合流ゲートの正本が、起動通知の受領を終端返却と読まないことを定めている
#
# 実行方法: bash scripts/tests/test-foreground-subagent-spawn.sh

# shellcheck disable=SC2016 # 規約文内のバッククォートは Markdown のリテラル（逐語検査対象）
set -u

FG_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${FG_TEST_DIR}/../.." && pwd)"
cd "$PLUGIN_ROOT" || exit 1

SELF_REVIEW="skills/self-review/SKILL.md"
DEFECT_SWEEP="skills/self-review/references/defect-sweep.md"
FI="agents/feature-implementer.md"
IMPL="skills/impl/SKILL.md"
TW="agents/ticket-worker.md"
JOIN="skills/para-impl/references/join-gate.md"

# 規約文を逐語で持つファイル（サブエージェントを起動する主体が読むもの）
CANON_HOLDERS=("$SELF_REVIEW" "$FI" "$IMPL" "$TW")
# `subagent_type` を指定する起動行を持つ経路上のファイル
SPAWN_FILES=("$SELF_REVIEW" "$DEFECT_SWEEP" "$FI" "$IMPL" "$TW")

CANON='**Task ツールの呼び出しには必ず `run_in_background: false` を明示する。** 省略するとバックグラウンド起動になり、返るのは結果ではなく起動通知（`Async agent launched` 等）だけになる。サブエージェントの中ではターンを終えた時点で呼び出し元へ返却され、後から届く結果は自分では受け取れない。**起動通知は結果ではない** — 求めた形式の結果を含まない応答を受け取ったら、ターンを終えず、同じ委譲を `run_in_background: false` で1回だけ起動し直す。それでも結果が得られなければ「合流できなかった」として扱う（黙って結果なしで先へ進まない）。'

for f in "${SPAWN_FILES[@]}" "$JOIN"; do
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

assert_file_contains() {
  local description="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
    echo "       ${file} に次の文がありません: ${needle}"
  fi
}

# `run_in_background: false` の出現回数が `subagent_type` の出現回数より少ない行を「ファイル:行番号」で
# 列挙する。行の有無ではなく回数で比べる——1行に2つの起動（並列委譲）が並ぶ行で、片方だけが背景起動に
# 戻っても行単位の有無では検出できないため。
spawn_lines_without_flag() {
  perl -ne 'my $n = () = /subagent_type/g; my $f = () = /run_in_background: false/g; print "$ARGV:$.\n" if $n > $f;' "$1"
}

echo "=== (F-0) 起動行検査器の自己検査 ==="
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
printf '%s\n' \
  "Task ツールで \`x\`（\`subagent_type: 'a:x'\`, \`run_in_background: false\`）を委譲する" \
  "Task ツールで \`y\`（\`subagent_type: 'a:y'\`）を委譲する" \
  "\`a\`（\`subagent_type: 'a:a'\`, \`run_in_background: false\`）と \`b\`（\`subagent_type: 'a:b'\`）へ並列委譲する" \
  > "$FIXTURE_DIR/spawn.md"
assert_eq "(F-0) 背景起動に戻った起動行だけを検出する（同じ行の片方だけが戻った場合を含む）" \
  "$(printf '%s\n%s' "$FIXTURE_DIR/spawn.md:2" "$FIXTURE_DIR/spawn.md:3")" \
  "$(spawn_lines_without_flag "$FIXTURE_DIR/spawn.md")"
: > "$FIXTURE_DIR/empty.md"
assert_eq "(F-0) 起動行が無いファイルからは何も検出しない" "" \
  "$(spawn_lines_without_flag "$FIXTURE_DIR/empty.md")"

echo "=== (F-1) 前景起動の規約文が逐語で在る ==="
for f in "${CANON_HOLDERS[@]}"; do
  assert_file_contains "(F-1) ${f} に規約文が在る" "$f" "$CANON"
done

echo "=== (F-2) 起動行がすべて run_in_background: false を持つ ==="
for f in "${SPAWN_FILES[@]}"; do
  n="$(grep -c 'subagent_type' "$f")"
  if [ "$n" -eq 0 ]; then
    # 起動行が消えたなら、このファイルを SPAWN_FILES から外すかを判断する（黙って pass にしない）
    assert_eq "(F-2) ${f} に起動行が在る" "1 以上" "0"
    continue
  fi
  assert_eq "(F-2) ${f} の起動行（${n} 行）に背景起動が無い" "" "$(spawn_lines_without_flag "$f")"
done

echo "=== (F-3) self_review: incomplete の契約が3点で接続されている ==="
assert_file_contains "(F-3) /self-review が報告の先頭に状態行を出す" "$SELF_REVIEW" \
  'self_review: complete | incomplete'
assert_file_contains "(F-3) /self-review は状態行の無い報告を incomplete と読ませる" "$SELF_REVIEW" \
  '行が無い報告は `incomplete` として扱う'
assert_file_contains "(F-3) /self-review はレビュアーと合流できなければ incomplete で終了する" "$SELF_REVIEW" \
  'Step 6 の報告の先頭に `self_review: incomplete` と未回収のレビュアー名を出して終了する'
assert_file_contains "(F-3) feature-implementer は incomplete をやり直さずに明示して返す" "$FI" \
  '**`/self-review` を自分でやり直さず、e-2・e-3 へも進まずに**'
assert_file_contains "(F-3) feature-implementer の返却内容に incomplete の形が在る" "$FI" \
  '### `/self-review` が `incomplete` で終了した場合'
assert_file_contains "(F-3) /impl の例外ケースに incomplete の行が在る" "$IMPL" \
  '| `self_review: incomplete`（'
assert_file_contains "(F-3) /impl は incomplete を受けて /self-review を実行し直す" "$IMPL" \
  '**本スキルの実行主体が Skill ツールで `/self-review` を1回だけ最初から実行し直し**'

echo "=== (F-4) 合流ゲートの正本が起動通知を終端返却と読まない ==="
assert_file_contains "(F-4) 有限タスクは前景で起動する" "$JOIN" \
  '**有限タスクのサブエージェントは `run_in_background: false` を明示して起動する**'
assert_file_contains "(F-4) 起動通知の受領は合流済みにしない" "$JOIN" \
  '**起動通知の受領は終端返却ではない**（合流済みにしない）'

echo ""
echo "=== summary === pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failed tests:"
  for t in ${FAILED_TESTS+"${FAILED_TESTS[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
