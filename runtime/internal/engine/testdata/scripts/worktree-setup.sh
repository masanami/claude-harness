#!/bin/bash
# テスト用の偽の worktree-setup.sh（plugin/scripts/worktree-setup.sh と同じ引数・出力の形。git を呼ばない）。FAKE_WT_DIR の下で動く。
#   setup.calls に引数を残す。setup.stderr があればそれを stderr に出して setup.code（既定 1）で失敗する。
#   setup.reused があれば reused: true、無ければ created: true。worktree は FAKE_WT_DIR/wt に作る。
set -u
dir="$FAKE_WT_DIR"
printf '%s\n' "$*" >> "$dir/setup.calls"
if [ -f "$dir/setup.stderr" ]; then cat "$dir/setup.stderr" >&2; exit "$(cat "$dir/setup.code" 2>/dev/null || echo 1)"; fi
mkdir -p "$dir/wt"
wt=$(cd "$dir/wt" && pwd -P)
if [ -f "$dir/setup.reused" ]; then c=false; r=true; else c=true; r=false; fi
printf '{"issue":%s,"branch":"%s","base":"%s","worktree_path":"%s","created":%s,"reused":%s,"branch_existed":false}\n' "$1" "$2" "$3" "$wt" "$c" "$r"
