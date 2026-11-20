package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// refreshTimeout は、status が PR の先頭を読む gh の上限（status が長く止まらないように）。
const refreshTimeout = 30 * time.Second

// RefreshHeads は、refresh: pr-head の印のあるゲートで待っている unit の PR の先頭を gh で読み直し、記録と違えば
// workspace イベント（action: head）を足す（§5.6.2）。落ちた runner の後始末（Interrupt）と同じく、status が書く。
//
// gh はロックの外で呼ぶ。書き込みは AppendIf の中で、同じ unit が同じゲートで同じ opened_at のまま待っているときだけ行う
// （読んでいる間にゲートが解かれた・解かれた後に同じゲートへ戻ってきた、のどちらでも書かない）。読めなければ何も書かず、
// 理由を warn へ出して、いまの記録のまま返す。印の無いゲートでは gh を呼ばない。
func RefreshHeads(ctx context.Context, run *runstate.Run, st *runstate.State, ghBin, cwd string, warn io.Writer) *runstate.State {
	if runstate.Terminal(st.Status) {
		return st
	}
	if ghBin == "" {
		ghBin = "gh"
	}
	for _, u := range st.Units {
		if u.Gate == nil || u.Gate.Refresh != workflow.RefreshPRHead || u.Running() != nil || u.Workspace == nil || u.Workspace.PRNumber <= 0 {
			continue
		}
		key, gate, openedAt, pr := u.Key, u.Gate.Gate, u.Gate.OpenedAt, u.Workspace.PRNumber
		dir := cwd
		if p := u.ActiveWorkspace(); p != "" {
			if _, err := os.Stat(p); err == nil {
				dir = p
			}
		}
		head, err := readPRHead(ctx, ghBin, dir, pr)
		if err != nil {
			fmt.Fprintf(warn, "harness: warning: cannot refresh the PR head of unit %s (the recorded head is shown): %v\n", key, err)
			continue
		}
		if head == u.Workspace.HeadSHA {
			continue
		}
		next, err := run.AppendIf(func(cur *runstate.State) ([]runstate.Event, error) {
			cu := cur.Unit(key)
			if runstate.Terminal(cur.Status) || cu == nil || cu.Running() != nil || cu.Gate == nil ||
				cu.Gate.Gate != gate || cu.Gate.OpenedAt != openedAt || cu.Workspace == nil || cu.Workspace.PRNumber != pr {
				return nil, nil
			}
			if cu.Workspace.HeadSHA == head {
				return nil, nil
			}
			return []runstate.Event{{Type: runstate.EvWorkspace, Workspace: &runstate.WorkspaceEvent{Unit: key, Action: runstate.WorkspaceHead, HeadSHA: head}}}, nil
		})
		if err != nil {
			fmt.Fprintf(warn, "harness: warning: cannot record the PR head of unit %s: %v\n", key, err)
			continue
		}
		st = next
	}
	return st
}

// readPRHead は gh pr view で PR のいまの先頭（headRefOid）を読む。
func readPRHead(ctx context.Context, ghBin, dir string, pr int) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, refreshTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, ghBin, "pr", "view", strconv.Itoa(pr), "--json", "headRefOid")
	cmd.Dir = dir
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("gh pr view %d: %v: %s", pr, err, strings.TrimSpace(errb.String()))
	}
	var v struct {
		HeadRefOid string `json:"headRefOid"`
	}
	if err := json.Unmarshal(out.Bytes(), &v); err != nil {
		return "", fmt.Errorf("gh pr view %d: output is not JSON: %v", pr, err)
	}
	if v.HeadRefOid == "" {
		return "", fmt.Errorf("gh pr view %d: no headRefOid in the output", pr)
	}
	return v.HeadRefOid, nil
}
