#!/bin/bash
# テスト用の偽の worktree-setup.sh（plugin/scripts/worktree-setup.sh と同じ引数・出力の形。git を呼ばない）。FAKE_WT_DIR の下で動く。
#   setup.calls に引数を残す。setup.stderr があればそれを stderr に出して setup.code（既定 1）で失敗する。
#   worktree（FAKE_WT_DIR/wt）が既に在れば reused: true（同じブランチの登録済み worktree の再利用）、無ければ作って created: true。
set -u
dir="$FAKE_WT_DIR"
printf '%s\n' "$*" >> "$dir/setup.calls"
if [ -f "$dir/setup.stderr" ]; then cat "$dir/setup.stderr" >&2; exit "$(cat "$dir/setup.code" 2>/dev/null || echo 1)"; fi
if [ -d "$dir/wt" ]; then c=false; r=true; else c=true; r=false; mkdir -p "$dir/wt"; fi
wt=$(cd "$dir/wt" && pwd -P)
printf '{"issue":%s,"branch":"%s","base":"%s","worktree_path":"%s","created":%s,"reused":%s,"branch_existed":false}\n' "$1" "$2" "$3" "$wt" "$c" "$r"
