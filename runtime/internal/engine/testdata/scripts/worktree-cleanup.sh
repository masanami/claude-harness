#!/bin/bash
# テスト用の偽の worktree-cleanup.sh（plugin/scripts/worktree-cleanup.sh と同じ引数・出力の形。git を呼ばない）。FAKE_WT_DIR の下で動く。
#   cleanup.calls に引数を残す。cleanup.dirty があれば消さずに skipped、無ければディレクトリを消して removed。
set -u
dir="$FAKE_WT_DIR"
printf '%s\n' "$*" >> "$dir/cleanup.calls"
if [ -f "$dir/cleanup.dirty" ]; then
  printf '{"worktree_path":"%s","removed":false,"skipped":true,"dirty":true,"reason":"dirty_worktree_skipped"}\n' "$1"
  exit 0
fi
rm -rf "$1"
printf '{"worktree_path":"%s","removed":true,"skipped":false,"dirty":false,"reason":null}\n' "$1"
