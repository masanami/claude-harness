#!/bin/bash
# 偽の claude（harness setup のテスト用。本物の claude plugin を呼ばない）。
# 引数を $FAKE_CLAUDE_DIR/calls に 1 行ずつ記録し、$FAKE_CLAUDE_DIR の用意したファイルで応答する:
#   plugin marketplace list --json  → marketplaces.json
#   plugin list --json              → n 回目は plugins.<n>.json（無ければ plugins.json）
#   plugin marketplace add … / plugin install …  → 成功（fail-<add|install> があれば失敗）
set -eu
d="${FAKE_CLAUDE_DIR:?}"
echo "$*" >> "$d/calls"
case "$*" in
  "plugin marketplace list --json")
    cat "$d/marketplaces.json" ;;
  "plugin list --json")
    n=$(( $(cat "$d/list.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$d/list.count"
    if [ -f "$d/plugins.$n.json" ]; then cat "$d/plugins.$n.json"; else cat "$d/plugins.json"; fi ;;
  "plugin marketplace add "*)
    [ -f "$d/fail-add" ] && { echo "add failed" >&2; exit 1; }
    echo "Successfully added marketplace" ;;
  "plugin install "*)
    [ -f "$d/fail-install" ] && { echo "install failed" >&2; exit 1; }
    echo "Successfully installed plugin" ;;
  *)
    echo "fake claude: unexpected arguments: $*" >&2; exit 64 ;;
esac
