#!/bin/bash
# test-demo-e2e-out.sh
# scripts/demo-e2e-out.sh の純粋関数（trim_whitespace/classify_case_id_blank/
# sanitize_case_id/compute_case_hash8/compute_safe_case_id/compute_next_attempt/
# resolve_project_root_raw/check_gitignore_warning）と、main() のエンドツーエンド挙動
# （一時gitリポジトリ上での実地検証）を検証する。
#
# 実行方法: bash scripts/tests/test-demo-e2e-out.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../demo-e2e-out.sh"

# shellcheck source=/dev/null
source "$TARGET_SCRIPT"

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

assert_true() {
  local description="$1" cond="$2" # "true" or "false"
  if [ "$cond" = "true" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok - ${description}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$description")
    echo "  NG - ${description}"
  fi
}

echo "=== trim_whitespace / classify_case_id_blank ==="
{
  assert_eq "trim_whitespace: 前後空白を除去" "abc" "$(trim_whitespace "  abc  ")"
  assert_eq "trim_whitespace: タブ・空白混在も除去" "abc" "$(trim_whitespace $'\t abc \t')"
  assert_eq "classify_case_id_blank: 空文字は blank" "blank" "$(classify_case_id_blank "")"
  assert_eq "classify_case_id_blank: 空白のみは blank" "blank" "$(classify_case_id_blank "   ")"
  assert_eq "classify_case_id_blank: タブのみは blank" "blank" "$(classify_case_id_blank $'\t\t')"
  assert_eq "classify_case_id_blank: 通常値は non-blank" "non-blank" "$(classify_case_id_blank "CASE-101")"
  assert_eq "classify_case_id_blank: 前後空白ありの通常値は non-blank" "non-blank" "$(classify_case_id_blank "  CASE-101  ")"
  # 回帰: [[:space:]]パターンマッチがロケール依存で、全角スペース等の非ASCII空白を
  # trimするかどうかが呼び出し環境のロケール設定次第でブレていた(self-review指摘)。
  # trim_whitespace内でLC_ALL=Cに固定しているため、ロケール設定を変えても結果は同じになる。
  fullwidth_space="$(printf '\xe3\x80\x80CASE-1')" # U+3000 IDEOGRAPHIC SPACE
  trim_locale1="$(LC_ALL=en_US.UTF-8 trim_whitespace "$fullwidth_space" 2>/dev/null || true)"
  trim_locale2="$(LC_ALL=C trim_whitespace "$fullwidth_space" 2>/dev/null || true)"
  assert_eq "全角スペースを含む値のtrim結果は呼び出し環境のロケール設定に依存しない" "$trim_locale2" "$trim_locale1"
}

echo ""
echo "=== sanitize_case_id ==="
{
  assert_eq "英数字・._-はそのまま" "CASE-101" "$(sanitize_case_id "CASE-101")"
  assert_eq "/ は _ に置換" "A_B" "$(sanitize_case_id "A/B")"
  assert_eq "既にファイルシステム安全な値はそのまま" "A_B" "$(sanitize_case_id "A_B")"
  assert_eq "複数の不正文字を一括置換" ".._.._etc_passwd" "$(sanitize_case_id "../../etc/passwd")"
  assert_eq "単体の . はそのまま(サニタイズ部のみでは判定しない)" "." "$(sanitize_case_id ".")"
  assert_eq "単体の .. はそのまま(サニタイズ部のみでは判定しない)" ".." "$(sanitize_case_id "..")"
  # 回帰: sedは行単位処理のため、素朴な実装だと改行が置換されず素通りしてしまう
  # （self-reviewで検出。code-reviewer指摘）。改行も他の不正文字と同様に "_" に置換されること。
  assert_eq "改行を含む値は改行も _ に置換される(sedの行単位処理の落とし穴を回避)" "CASE_101" "$(sanitize_case_id "$(printf 'CASE\n101')")"
  # 回帰: ロケール依存でマルチバイト文字の置換結果がブレる問題(self-review指摘)。
  # LC_ALL=Cに固定しているため、ロケール設定を変えても結果は同じになる。
  hash_locale_ja1="$(LC_ALL=en_US.UTF-8 sanitize_case_id "ケース1" 2>/dev/null || true)"
  hash_locale_ja2="$(LC_ALL=C sanitize_case_id "ケース1" 2>/dev/null || true)"
  assert_eq "マルチバイト文字の置換結果は呼び出し環境のロケール設定に依存しない" "$hash_locale_ja2" "$hash_locale_ja1"
}

echo ""
echo "=== compute_case_hash8 ==="
{
  hash1="$(compute_case_hash8 "A/B")"
  hash2="$(compute_case_hash8 "A/B")"
  assert_eq "同じ入力からは同じハッシュ(決定的)" "$hash1" "$hash2"
  assert_true "8桁の16進数文字列" "$([[ "$hash1" =~ ^[0-9a-f]{8}$ ]] && echo true || echo false)"

  hash_ab="$(compute_case_hash8 "A_B")"
  assert_true "元のCASE_IDが違えばハッシュも異なる(A/B vs A_B)" "$([ "$hash1" != "$hash_ab" ] && echo true || echo false)"
}

echo ""
echo "=== compute_safe_case_id: 単射性(一律エンコード、条件付きハッシュにしない) ==="
{
  safe_slash="$(compute_safe_case_id "A/B")"
  safe_underscore="$(compute_safe_case_id "A_B")"
  assert_true "A/B と A_B は異なる safe_case_id になる(単射性)" "$([ "$safe_slash" != "$safe_underscore" ] && echo true || echo false)"
  assert_true "safe_case_id(A/B) は 'A_B-' で始まる(サニタイズ済み可読部+ハッシュ)" "$([[ "$safe_slash" == A_B-* ]] && echo true || echo false)"
  assert_true "safe_case_id(A_B) も 'A_B-' で始まる(可読部が同じでもハッシュで区別)" "$([[ "$safe_underscore" == A_B-* ]] && echo true || echo false)"

  # 置換が発生しない既存安全な値にも常にハッシュが付く(一律規則)
  safe_plain="$(compute_safe_case_id "CASE-101")"
  assert_true "置換が発生しない値にも常にハッシュが付加される" "$([[ "$safe_plain" =~ ^CASE-101-[0-9a-f]{8}$ ]] && echo true || echo false)"
}

echo ""
echo "=== main(): 前後空白のtrim一貫性(空判定と成果物パス導出の基準を揃える) ==="
{
  # 回帰: main()の空判定はtrim後の値で行うのに、safe_case_id導出はtrim前の生値を
  # 使っていたため、同じ論理ケースでも前後空白の有無だけでsafe_case_idが分裂していた
  # (self-review指摘。code-reviewer/design-reviewer双方でCONFIRMED)。
  TRIM_TMP="$(mktemp -d)"
  trim_e2e_cleanup() { rm -rf "$TRIM_TMP"; }
  trap trim_e2e_cleanup EXIT

  TRIM_REPO="${TRIM_TMP}/repo"
  mkdir -p "$TRIM_REPO"
  (
    cd "$TRIM_REPO" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "hello" >README.md
    git add README.md
    git commit -q -m "initial"
  )

  output_plain="$(cd "$TRIM_REPO" && bash "$TARGET_SCRIPT" "CASE-101")"
  safe_plain_e2e="$(jq -r '.safe_case_id' <<<"$output_plain")"
  # demo-e2e-out.sh 自体は成果物ディレクトリを作らない(実際に作るのは呼び出し元の
  # run-walkthrough.mjs)ため、attempt連番の継続を検証するには前回分のディレクトリを
  # テスト側で用意する必要がある。
  mkdir -p "${TRIM_REPO}/demo-e2e-artifacts/${safe_plain_e2e}/attempt-1"

  output_padded="$(cd "$TRIM_REPO" && bash "$TARGET_SCRIPT" "  CASE-101  ")"
  safe_padded_e2e="$(jq -r '.safe_case_id' <<<"$output_padded")"
  assert_eq "前後空白ありのCASE_IDも、trim後の値と同じsafe_case_idになる" "$safe_plain_e2e" "$safe_padded_e2e"
  assert_eq "前後空白ありのCASE_IDは attempt採番でも同じケースとして扱われる(attempt=2)" "2" "$(jq -r '.attempt' <<<"$output_padded")"

  trim_e2e_cleanup
  trap - EXIT
}

echo ""
echo "=== compute_safe_case_id: traversal安全化 ==="
{
  safe_dot="$(compute_safe_case_id ".")"
  assert_true "'.' は '.' そのものにならない" "$([ "$safe_dot" != "." ] && echo true || echo false)"
  assert_true "'.' の結果に / を含まない" "$([[ "$safe_dot" != *"/"* ]] && echo true || echo false)"

  safe_dotdot="$(compute_safe_case_id "..")"
  assert_true "'..' は '..' そのものにならない" "$([ "$safe_dotdot" != ".." ] && echo true || echo false)"
  assert_true "'..' の結果に / を含まない" "$([[ "$safe_dotdot" != *"/"* ]] && echo true || echo false)"

  safe_traversal="$(compute_safe_case_id "../../etc/passwd")"
  assert_true "'../../etc/passwd' の結果に / を含まない" "$([[ "$safe_traversal" != *"/"* ]] && echo true || echo false)"
  assert_true "'../../etc/passwd' は '.' でも '..' でもない" "$([ "$safe_traversal" != "." ] && [ "$safe_traversal" != ".." ] && echo true || echo false)"
}

echo ""
echo "=== compute_next_attempt ==="
{
  ATTEMPT_TMP="$(mktemp -d)"
  attempt_cleanup() { rm -rf "$ATTEMPT_TMP"; }
  trap attempt_cleanup EXIT

  no_dir_attempt="$(compute_next_attempt "${ATTEMPT_TMP}/nonexistent")"
  assert_eq "ディレクトリが無ければ attempt=1" "1" "$no_dir_attempt"

  empty_case_dir="${ATTEMPT_TMP}/empty-case"
  mkdir -p "$empty_case_dir"
  empty_attempt="$(compute_next_attempt "$empty_case_dir")"
  assert_eq "attempt-*が1件も無ければ attempt=1" "1" "$empty_attempt"

  case_dir="${ATTEMPT_TMP}/some-case"
  mkdir -p "${case_dir}/attempt-1" "${case_dir}/attempt-2"
  next_attempt="$(compute_next_attempt "$case_dir")"
  assert_eq "attempt-1,attempt-2 が存在すれば attempt=3" "3" "$next_attempt"

  # 桁の異なる番号でも数値として最大を判定する
  mkdir -p "${case_dir}/attempt-10"
  next_attempt2="$(compute_next_attempt "$case_dir")"
  assert_eq "attempt-10 が存在すれば attempt=11(文字列順ではなく数値順)" "11" "$next_attempt2"

  # 回帰: ゼロ埋めされたattempt-*ディレクトリ(本スクリプト以外が作った可能性がある外部状態)
  # があると、bashの算術評価が先頭ゼロを8進数と誤解釈しエラー終了していた(self-review指摘)。
  zero_padded_dir="${ATTEMPT_TMP}/zero-padded-case"
  mkdir -p "${zero_padded_dir}/attempt-08" "${zero_padded_dir}/attempt-09"
  zero_padded_attempt="$(compute_next_attempt "$zero_padded_dir")"
  zero_padded_rc=$?
  assert_eq "ゼロ埋めのattempt-08,attempt-09があってもエラーにならず attempt=10 になる" "10" "$zero_padded_attempt"
  assert_eq "ゼロ埋めディレクトリ走査は正常終了する(0進数誤解釈によるエラー終了なし)" "0" "$zero_padded_rc"

  attempt_cleanup
  trap - EXIT
}

echo ""
echo "=== resolve_project_root_raw ==="
{
  RESOLVE_TMP="$(mktemp -d)"
  resolve_cleanup() { rm -rf "$RESOLVE_TMP"; unset WALKTHROUGH_PROJECT_ROOT; }
  trap resolve_cleanup EXIT

  # shellcheck disable=SC2034 # resolve_project_root_raw（sourceしたTARGET_SCRIPT側の関数）が参照する
  WALKTHROUGH_PROJECT_ROOT="${RESOLVE_TMP}/explicit-root"
  assert_eq "WALKTHROUGH_PROJECT_ROOT指定時はその値を返す" "${RESOLVE_TMP}/explicit-root" "$(resolve_project_root_raw)"
  unset WALKTHROUGH_PROJECT_ROOT

  GITROOT_DIR="${RESOLVE_TMP}/gitroot"
  mkdir -p "$GITROOT_DIR"
  (
    cd "$GITROOT_DIR" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
  )
  git_toplevel_physical="$(cd "$GITROOT_DIR" && git rev-parse --show-toplevel)"
  resolved="$(cd "$GITROOT_DIR" && resolve_project_root_raw)"
  assert_eq "未設定時はgit rev-parse --show-toplevelの結果を返す" "$git_toplevel_physical" "$resolved"

  resolve_cleanup
  trap - EXIT
}

echo ""
echo "=== check_gitignore_warning ==="
{
  GI_TMP="$(mktemp -d)"
  gi_cleanup() { rm -rf "$GI_TMP"; }
  trap gi_cleanup EXIT

  GI_REPO_COVERED="${GI_TMP}/repo-covered"
  mkdir -p "$GI_REPO_COVERED"
  (
    cd "$GI_REPO_COVERED" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "demo-e2e-artifacts" >.gitignore
    git add .gitignore
    git commit -q -m "add gitignore"
  )
  assert_eq ".gitignoreがdemo-e2e-artifactsをカバー -> false(警告なし)" "false" "$(check_gitignore_warning "$GI_REPO_COVERED")"

  GI_REPO_UNCOVERED="${GI_TMP}/repo-uncovered"
  mkdir -p "$GI_REPO_UNCOVERED"
  (
    cd "$GI_REPO_UNCOVERED" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "node_modules" >.gitignore
    git add .gitignore
    git commit -q -m "add gitignore"
  )
  assert_eq ".gitignoreがdemo-e2e-artifactsをカバーしない -> true(警告あり)" "true" "$(check_gitignore_warning "$GI_REPO_UNCOVERED")"

  GI_NON_REPO="${GI_TMP}/not-a-repo"
  mkdir -p "$GI_NON_REPO"
  assert_eq "gitリポジトリでない場合は安全側でtrue" "true" "$(check_gitignore_warning "$GI_NON_REPO")"

  gi_cleanup
  trap - EXIT
}

echo ""
echo "=== main(): 空/空白のみのCASE_IDは拒否 ==="
{
  empty_stdout="$(bash "$TARGET_SCRIPT" "" 2>/dev/null)"
  empty_rc=$?
  assert_eq "空文字は非0 exit" "1" "$empty_rc"
  assert_eq "空文字はstdoutが空" "" "$empty_stdout"

  blank_stdout="$(bash "$TARGET_SCRIPT" "   " 2>/dev/null)"
  blank_rc=$?
  assert_eq "空白のみは非0 exit" "1" "$blank_rc"
  assert_eq "空白のみはstdoutが空" "" "$blank_stdout"

  noarg_stdout="$(bash "$TARGET_SCRIPT" 2>/dev/null)"
  noarg_rc=$?
  assert_eq "引数無しは非0 exit" "1" "$noarg_rc"
  assert_eq "引数無しはstdoutが空" "" "$noarg_stdout"

  usage_stderr="$(bash "$TARGET_SCRIPT" "" 2>&1 1>/dev/null)"
  assert_true "使用方法がstderrに出力される" "$(echo "$usage_stderr" | grep -qi "usage" && echo true || echo false)"
}

echo ""
echo "=== main(): エンドツーエンド(一時gitリポジトリ) ==="
{
  MAIN_TMP="$(mktemp -d)"
  main_cleanup() { rm -rf "$MAIN_TMP"; unset WALKTHROUGH_PROJECT_ROOT; }
  trap main_cleanup EXIT

  MAIN_REPO="${MAIN_TMP}/repo"
  mkdir -p "$MAIN_REPO"
  (
    cd "$MAIN_REPO" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "demo-e2e-artifacts" >.gitignore
    git add .gitignore
    git commit -q -m "initial"
  )

  output1="$(cd "$MAIN_REPO" && bash "$TARGET_SCRIPT" "CASE-101")"
  rc1=$?
  assert_eq "正常系: exit 0" "0" "$rc1"
  assert_eq "正常系: 1行のJSONが出力される(改行を除いて1行)" "1" "$(echo "$output1" | wc -l | tr -d ' ')"
  safe1="$(jq -r '.safe_case_id' <<<"$output1")"
  assert_true "safe_case_id は 'CASE-101-' で始まる" "$([[ "$safe1" == CASE-101-* ]] && echo true || echo false)"
  assert_eq "初回attempt: attempt=1" "1" "$(jq -r '.attempt' <<<"$output1")"
  assert_eq "初回attempt: out_dirはprojectRoot相対" "demo-e2e-artifacts/${safe1}/attempt-1" "$(jq -r '.out_dir' <<<"$output1")"
  assert_eq "gitignoreカバー済み: gitignore_warning=false" "false" "$(jq -r '.gitignore_warning' <<<"$output1")"

  # 成果物ディレクトリを実際に作って再実行 -> attempt連番が進む
  mkdir -p "${MAIN_REPO}/demo-e2e-artifacts/${safe1}/attempt-1" "${MAIN_REPO}/demo-e2e-artifacts/${safe1}/attempt-2"
  output2="$(cd "$MAIN_REPO" && bash "$TARGET_SCRIPT" "CASE-101")"
  assert_eq "既存attempt-1,attempt-2がある場合: attempt=3" "3" "$(jq -r '.attempt' <<<"$output2")"
  assert_eq "既存attempt-1,attempt-2がある場合: out_dirにattempt-3" "demo-e2e-artifacts/${safe1}/attempt-3" "$(jq -r '.out_dir' <<<"$output2")"

  # 単射性のエンドツーエンド確認: A/B と A_B で異なる safe_case_id
  output_slash="$(cd "$MAIN_REPO" && bash "$TARGET_SCRIPT" "A/B")"
  output_underscore="$(cd "$MAIN_REPO" && bash "$TARGET_SCRIPT" "A_B")"
  safe_slash_e2e="$(jq -r '.safe_case_id' <<<"$output_slash")"
  safe_underscore_e2e="$(jq -r '.safe_case_id' <<<"$output_underscore")"
  assert_true "main() 経由でも A/B と A_B は異なるsafe_case_idになる" "$([ "$safe_slash_e2e" != "$safe_underscore_e2e" ] && echo true || echo false)"

  # traversal安全化のエンドツーエンド確認(design-reviewer指摘): out_dirが常に
  # demo-e2e-artifacts/ 配下(projectRoot外へ出ない)に収まることを、単体関数の
  # 性質からの間接確認だけでなくmain()の出力そのもので直接検証する
  output_traversal="$(cd "$MAIN_REPO" && bash "$TARGET_SCRIPT" "../../etc/passwd")"
  out_dir_traversal="$(jq -r '.out_dir' <<<"$output_traversal")"
  assert_true "traversal入力でもout_dirは常に demo-e2e-artifacts/ で始まる" "$([[ "$out_dir_traversal" == demo-e2e-artifacts/* ]] && echo true || echo false)"
  # 安全性の本質は「/区切りの各セグメントが単独で '.' または '..' にならない」こと
  # (可読部の文字列に部分文字列として ".." が含まれること自体は、単独セグメントで
  # なければ path.resolve() 上の親ディレクトリ参照にはならないため無害)。
  traversal_unsafe_segment="false"
  IFS='/' read -r -a traversal_segments <<<"$out_dir_traversal"
  for seg in "${traversal_segments[@]}"; do
    if [ "$seg" = "." ] || [ "$seg" = ".." ]; then
      traversal_unsafe_segment="true"
    fi
  done
  assert_eq "traversal入力でもout_dirの各セグメントは単独で '.' や '..' にならない" "false" "$traversal_unsafe_segment"

  # gitignore未カバーのリポジトリでは warning=true
  MAIN_REPO_NOGITIGNORE="${MAIN_TMP}/repo-nogitignore"
  mkdir -p "$MAIN_REPO_NOGITIGNORE"
  (
    cd "$MAIN_REPO_NOGITIGNORE" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "hello" >README.md
    git add README.md
    git commit -q -m "initial"
  )
  output_nogi="$(cd "$MAIN_REPO_NOGITIGNORE" && bash "$TARGET_SCRIPT" "CASE-201")"
  assert_eq "gitignore未カバー: gitignore_warning=true" "true" "$(jq -r '.gitignore_warning' <<<"$output_nogi")"

  # WALKTHROUGH_PROJECT_ROOT指定時は指定ディレクトリを基準にスキャンする(gitルートとは別)
  ALT_ROOT="${MAIN_TMP}/alt-root"
  mkdir -p "${ALT_ROOT}/demo-e2e-artifacts"
  # まずgitルート(MAIN_REPO)基準のsafe_case_idを求め、ALT_ROOT側に同名のattemptディレクトリを用意する
  base_output="$(cd "$MAIN_REPO" && WALKTHROUGH_PROJECT_ROOT="$ALT_ROOT" bash "$TARGET_SCRIPT" "CASE-301")"
  safe_301="$(jq -r '.safe_case_id' <<<"$base_output")"
  assert_eq "WALKTHROUGH_PROJECT_ROOT指定時: 初回はattempt=1" "1" "$(jq -r '.attempt' <<<"$base_output")"

  mkdir -p "${ALT_ROOT}/demo-e2e-artifacts/${safe_301}/attempt-1"
  base_output2="$(cd "$MAIN_REPO" && WALKTHROUGH_PROJECT_ROOT="$ALT_ROOT" bash "$TARGET_SCRIPT" "CASE-301")"
  assert_eq "WALKTHROUGH_PROJECT_ROOT指定時: ALT_ROOT配下のattemptを見てattempt=2になる(gitルートではなく指定ディレクトリ基準)" "2" "$(jq -r '.attempt' <<<"$base_output2")"
  # gitルート(MAIN_REPO)側には同名ディレクトリを作っていないため、gitルート基準ならattempt=1のはず
  assert_true "ALT_ROOT基準のattemptはMAIN_REPO直下のdemo-e2e-artifactsには影響しない" "$([ ! -d "${MAIN_REPO}/demo-e2e-artifacts/${safe_301}" ] && echo true || echo false)"

  main_cleanup
  trap - EXIT
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
