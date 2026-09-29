package cli

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// CI が実行されずに失敗した（fail のチェックはあるが失敗ログが空。例: Actions が Billing でジョブを起動しない）ときは、
// 何を直すかの入力が無いので fix へ送らず ci-pending で止まり、recheck で CI の再確認から続けられる（Issue #278）。
func TestTicketCIRedWithoutLogStopsAtCIPending(t *testing.T) {
	t.Run("working tree definitions", func(t *testing.T) { ticketCIRedWithoutLog(t, false) })
	t.Run("embedded definitions", func(t *testing.T) { ticketCIRedWithoutLog(t, true) })
}

func ticketCIRedWithoutLog(t *testing.T, embedded bool) {
	f := newTicketFixture(t)
	h, fdir, write := f.h, f.fdir, f.write
	write("run-log-empty", "")
	args := []string{"run", "--input", "issue=42", "ticket"}
	if !embedded {
		args = append(args, "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts))
	}

	out, errOut, code := h.run(args...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "ci-pending" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	u := v.Unit("main")
	var seq []string
	for _, x := range u.Rounds[0].Steps {
		seq = append(seq, x.Step+":"+x.Outcome)
	}
	want := "resolve:ok analyze:ok workspace:created implement:pass commit:committed e2e-route:no publish:opened ci:red_no_log"
	if strings.Join(seq, " ") != want {
		t.Fatalf("round 1 steps:\n got %s\nwant %s", strings.Join(seq, " "), want)
	}
	if u.LimitsUsed["rework"] != 0 {
		t.Errorf("rework used = %d, want 0 (nothing was sent to fix)", u.LimitsUsed["rework"])
	}
	// fix（偽の claude の 4 回目）は起動されていない。
	if _, err := os.Stat(filepath.Join(fdir, "calls", "4.stdin")); !os.IsNotExist(err) {
		t.Errorf("claude was launched a 4th time (fix): %v", err)
	}

	// CI を直して（再実行して）から recheck → green → レビュー待ち。
	write("checks", check("test", "pass"))
	out, errOut, code = h.run("resume", v.RunID, "--input", "recheck")
	if code != ExitWaiting {
		t.Fatalf("resume recheck exit %d\n%s\n%s", code, out, errOut)
	}
	v = decode[statusView](t, out)
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "review" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	if r2 := v.Unit("main").Rounds[1]; len(r2.Steps) != 1 || r2.Steps[0].Step != "ci" || r2.Steps[0].Outcome != "green" {
		t.Fatalf("round 2 = %+v", r2)
	}
}

// ci-wait-pr.sh は ci-wait.sh の red のうち、失敗ログが空（空白だけを含む）のものだけを red_no_log に替える。
// ほかの値と、ログのある red はそのまま出す（Issue #278）。
func TestCIWaitPRMarksRedWithoutLog(t *testing.T) {
	cases := []struct {
		name, ci, excerpt, want string
	}{
		{"red with an empty log", "red", "", "red_no_log"},
		{"red with a whitespace-only log", "red", " \n\t\n", "red_no_log"},
		{"red with a log", "red", "--- run 1 ---\nassertion failed", "red"},
		{"green", "green", "", "green"},
		{"timeout", "timeout", "", "timeout"},
		{"none", "none", "", "none"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			in := filepath.Join(dir, "out.json")
			doc := map[string]any{"ci": c.ci, "failed_checks": []any{}, "failure_log_excerpt": c.excerpt,
				"pr_url": "https://github.com/o/r/pull/7", "pr_number": 7, "pr_exists": true}
			b, _ := json.Marshal(doc)
			if err := os.WriteFile(in, b, 0o644); err != nil {
				t.Fatal(err)
			}
			// 偽の ci-wait.sh: 用意した JSON をそのまま出す。
			fake := "#!/bin/bash\ncat \"" + in + "\"\n"
			if err := os.WriteFile(filepath.Join(dir, "ci-wait.sh"), []byte(fake), 0o755); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("bash", abs(t, repoWorkflows+"/scripts/ci-wait-pr.sh"), "--pr", "7")
			cmd.Env = append(os.Environ(), "HARNESS_SCRIPTS_DIR="+dir)
			out, err := cmd.Output()
			if err != nil {
				t.Fatalf("ci-wait-pr.sh: %v\n%s", err, out)
			}
			got := decode[map[string]any](t, string(out))
			if got["ci"] != c.want {
				t.Fatalf("ci = %v, want %s\n%s", got["ci"], c.want, out)
			}
			if got["failure_log_excerpt"] != c.excerpt || got["pr_number"] != float64(7) {
				t.Errorf("the other fields changed: %s", out)
			}
		})
	}
}
