package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 散文の /para-impl の worker（ticket-worker）が呼ぶ薄い /impl の経路（#299・設計 §10 PR-7 の確かめる事項）:
// リードが worktree-setup で作った作業ツリー（リードが決めたブランチ）の中から、--input worktree=<その絶対パス> で
// ticket を起動する。runtime はその作業ツリーを workspace の provided で受け、リードのブランチのまま PR を作り、
// CI の後の review ゲートで止まる（/impl はここで通常完了として返す）。作業ツリーは消さない。
func TestTicketRunsInAWorktreeProvidedByTheLead(t *testing.T) {
	f := newTicketFixture(t)
	h, root, repo, ghDir, write := f.h, f.root, f.repo, f.ghDir, f.write
	write("checks.1", check("test", "pass"))
	write("checks", check("test", "pass"))

	leadBranch := "feat/issue-42-from-the-lead" // analyze が提案するブランチ（f.branch）とは別の名前
	wt := filepath.Join(root, "repo-worktrees", "issue-42")
	git(t, repo, "worktree", "add", "-q", "-b", leadBranch, wt, "origin/main")
	h.cwd = wt // worker は worktree の中で /impl を実行する

	out, errOut, code := h.run("run", "--input", "issue=42", "--input", "worktree="+wt,
		"--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	u := v.Unit("main")
	var seq []string
	for _, x := range u.Rounds[0].Steps {
		seq = append(seq, x.Step+":"+x.Outcome)
	}
	if want := "resolve:ok analyze:ok workspace:provided implement:pass commit:committed e2e-route:no publish:opened ci:green"; strings.Join(seq, " ") != want {
		t.Fatalf("steps:\n got %s\nwant %s", strings.Join(seq, " "), want)
	}
	ws := u.Workspace
	if ws == nil || ws.ProvidedBy != "caller" || ws.Created || ws.WorktreePath != wt || ws.Branch != leadBranch || ws.PRURL == "" {
		t.Fatalf("workspace = %+v", ws)
	}
	// PR はリードのブランチから作られている（analyze が提案したブランチではない）。
	if calls := readFile(t, filepath.Join(ghDir, "calls")); !strings.Contains(calls, "--head\t"+leadBranch) {
		t.Errorf("the PR was not opened from the lead's branch:\n%s", calls)
	}
	if fi, err := os.Stat(wt); err != nil || !fi.IsDir() {
		t.Errorf("the provided worktree is gone: %v", err)
	}
}
