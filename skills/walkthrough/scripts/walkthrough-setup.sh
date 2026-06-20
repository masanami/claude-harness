#!/usr/bin/env bash
# walkthrough-setup.sh
# /walkthrough（AI動作確認）のための Playwright(Headed) 環境セットアップ。
#
# やること:
#   1. プロジェクトの Playwright で chromium を導入（mac/Linux 共通）
#   2. OS を判定し、Linux のみ OS 依存ライブラリの不足を ldd で検出
#   3. 不足があれば「実行すべきコマンド」を表示して正常終了（sudo を勝手に実行しない）
#
# 設計方針:
#   - macOS では依存導入ステップを丸ごとスキップする（install-deps は Linux 専用）
#   - sudo をスクリプト内で実行しない。非対話環境で固まらせないため案内のみ行う
#   - 機械可読なステータス行 `WALKTHROUGH_SETUP_STATUS=<ready|deps-missing|error>` を最後に出力
#   - 不足検出時も exit 0（スクリプト自体は正常完了。アクションは呼び出し側が判断）
#
# 環境変数:
#   WALKTHROUGH_PROJECT_ROOT  Playwright を導入するプロジェクトroot（既定: git root か PWD）

set -uo pipefail

log()  { printf '\033[36m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[setup]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[setup]\033[0m %s\n' "$*" >&2; }

finish() {
  # $1: status (ready|deps-missing|error)
  echo
  echo "WALKTHROUGH_SETUP_STATUS=$1"
  # 不足/エラーでも「スクリプトとしては正常終了」させ、非対話環境で固まらせない
  exit 0
}

# --- プロジェクトroot を決定 -------------------------------------------------
PROJECT_ROOT="${WALKTHROUGH_PROJECT_ROOT:-}"
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$PROJECT_ROOT" || { err "プロジェクトroot に移動できません: $PROJECT_ROOT"; finish error; }
log "プロジェクトroot: $PROJECT_ROOT"

# --- Playwright CLI を解決 ---------------------------------------------------
# プロジェクトの Playwright を優先（バージョン不一致でブラウザが見つからない事故を避ける）
PW=()
if [ -x "$PROJECT_ROOT/node_modules/.bin/playwright" ]; then
  PW=("$PROJECT_ROOT/node_modules/.bin/playwright")
elif command -v pnpm &>/dev/null && [ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]; then
  PW=(pnpm exec playwright)
elif command -v npx &>/dev/null; then
  PW=(npx --no-install playwright)
else
  err "playwright CLI が見つかりません。プロジェクトに @playwright/test を導入してください。"
  err "  例: pnpm add -D @playwright/test  /  npm i -D @playwright/test"
  finish error
fi
log "Playwright CLI: ${PW[*]}"

# --- 1. chromium 本体を導入（mac/Linux 共通） --------------------------------
log "chromium を導入します（playwright install chromium）..."
if ! "${PW[@]}" install chromium; then
  err "chromium の導入に失敗しました。上のログを確認してください。"
  finish error
fi
log "chromium の導入が完了しました。"

# --- 2. OS 判定 --------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Darwin)
    log "macOS を検出。OS 依存ライブラリは chromium に同梱されており install-deps は不要のためスキップします。"
    log "Headed 表示はネイティブにウィンドウ表示されます。"
    finish ready
    ;;
  Linux)
    : # 後続の依存チェックへ
    ;;
  *)
    warn "未知の OS ($OS)。依存チェックはスキップします。Headed 起動に失敗する場合は手動で依存を導入してください。"
    finish ready
    ;;
esac

# --- WSL 判定（Headed 表示の案内） ------------------------------------------
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
  log "WSL を検出。Headed 表示には WSLg（DISPLAY=${DISPLAY:-未設定}）が必要です。"
  if [ -z "${DISPLAY:-}" ]; then
    warn "DISPLAY が未設定です。Headed 表示できない場合は WALKTHROUGH_HEADED=false で headless + スクショにフォールバックできます。"
  fi
fi

# --- 3. OS 依存ライブラリの不足を ldd で検出（Linux） ------------------------
# Headed が主目的のため、headless_shell ではなく full chromium(chrome) を対象に ldd する
# （両者は必要ライブラリが異なる。headed は GTK/X11 系を要する）。
CACHE_DIR="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
CHROME_BIN=""
for cand in "$CACHE_DIR"/chromium-*/chrome-linux/chrome; do
  if [ -x "$cand" ]; then CHROME_BIN="$cand"; break; fi
done

if [ -z "$CHROME_BIN" ]; then
  warn "headed 用 chromium(chrome) を特定できませんでした（$CACHE_DIR）。"
  warn "Headed 起動に失敗する場合は次を実行してください: sudo ${PW[*]} install-deps chromium"
  # ldd で確定できないため ready 即断はせず、案内付きで終了する
  finish deps-missing
fi
log "chromium 実行ファイル: $CHROME_BIN"

if ! command -v ldd &>/dev/null; then
  warn "ldd が無いため依存チェックをスキップします。起動失敗時は: sudo ${PW[*]} install-deps chromium"
  finish ready
fi

# 注意: chromium は一部ライブラリを dlopen するため、ldd で "not found" が出なくても
# headed 起動が落ちることがある。その場合は下記 install-deps を実行すること。
MISSING="$(ldd "$CHROME_BIN" 2>/dev/null | awk '/not found/{print $1}' | sort -u)"
if [ -z "$MISSING" ]; then
  log "ldd 上の OS 依存ライブラリの不足はありません（dlopen 分は検出対象外）。"
  finish ready
fi

# --- 不足あり: sudo を実行せず案内のみ --------------------------------------
echo
err "OS 依存ライブラリが不足しています（chromium が起動できません）:"
while IFS= read -r lib; do err "  - $lib"; done <<< "$MISSING"
echo
warn "次のコマンドを手動で実行してください（root 権限が必要なため、このスクリプトでは実行しません）:"
echo
echo "    sudo ${PW[*]} install-deps chromium"
echo
warn "Debian/Ubuntu 以外で install-deps が網羅しない場合は、上記の不足ライブラリを"
warn "パッケージマネージャで個別に導入してください（例: libnspr4 libnss3 libasound2 ）。"
finish deps-missing
