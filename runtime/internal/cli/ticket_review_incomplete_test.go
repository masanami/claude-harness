package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// implement が review_incomplete（/self-review が self_review: incomplete で終わった）を返したら、レビュアーと合流できていない
// 実装を pass として PR へ進めず、コミットの前に失敗で止まる（#262 の契約を runtime でも守る。#299）。
func TestTicketStopsWhenSelfReviewIsIncomplete(t *testing.T) {
	f := newTicketFixture(t)
	h, fdir, ghDir := f.h, f.fdir, f.ghDir
	respond(t, fdir, 2, 0, claudeStructured(map[string]any{"outcome": "review_incomplete", "pr_title": "feat: add the widget", "summary": "Adds the widget.",
		"residual_findings": []map[string]string{}, "unverified": []string{"unrecovered: claude-harness:code-reviewer"},
		"cross_repo_attestation": "", "deviation_report": ""}, 4.0))

	out, errOut, code := h.run("run", "--input", "issue=42", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitFailed {
		t.Fatalf("run exit %d, want %d\n%s\n%s", code, ExitFailed, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Status != "failed" || !strings.Contains(v.Reason, "self_review_incomplete") {
		t.Fatalf("status %q reason %q", v.Status, v.Reason)
	}
	var seq []string
	for _, x := range v.Unit("main").Rounds[0].Steps {
		seq = append(seq, x.Step+":"+x.Outcome)
	}
	if want := "resolve:ok analyze:ok workspace:created implement:review_incomplete"; strings.Join(seq, " ") != want {
		t.Fatalf("steps:\n got %s\nwant %s", strings.Join(seq, " "), want)
	}
	// commit（偽の claude の 3 回目）は起動されず、PR も作られていない。
	if _, err := os.Stat(filepath.Join(fdir, "calls", "3.stdin")); !os.IsNotExist(err) {
		t.Errorf("claude was launched a 3rd time (commit): %v", err)
	}
	if calls := readFile(t, filepath.Join(ghDir, "calls")); strings.Contains(calls, "pr\tcreate") {
		t.Errorf("a PR was created:\n%s", calls)
	}
}
