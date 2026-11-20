package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 統合先を使う ticket の実行（docs/harness-runtime-design.md §5.6.3 の S3b-1）: 統合ブランチを確かめて作り、PR の宛先と成果物の印に反映する。

type integrationRun struct {
	f   *ticketFixture
	out statusView
	id  string
}

// startIntegration は task_file と task_id を渡して ticket を最初のゲートまで通す。extra は足す入力（NAME=VALUE）。
func startIntegration(t *testing.T, f *ticketFixture, taskID string, extra ...string) integrationRun {
	t.Helper()
	taskFile := filepath.Join(t.TempDir(), "task.md")
	if err := os.WriteFile(taskFile, []byte("# タスク\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	args := append([]string{"run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts),
		"--input", "task_file=" + taskFile, "--input", "task_id=" + taskID, "--input", "issue=42"}, flagInputs(extra)...)
	out, errOut, code := f.h.run(append(args, "ticket")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	return integrationRun{f: f, out: v, id: v.RunID}
}

func flagInputs(in []string) []string {
	var out []string
	for _, i := range in {
		out = append(out, "--input", i)
	}
	return out
}

func countRole(arts []artifact, kind, role string) (n int, ref string) {
	for _, a := range arts {
		if a.Kind == kind && a.Role == role {
			n++
			ref = a.Ref
		}
	}
	return n, ref
}

func TestTicketIntegrationTargetsTheIntegrationBranch(t *testing.T) {
	f := newTicketFixture(t)
	f.setAnalyzeBranch("feature/task-1-add-widget")
	run := startIntegration(t, f, "T-1", "uses_integration=true", "challenge_id=C-12")

	// 統合ブランチは既定ブランチの先頭から origin に作られ、PR の宛先になる
	mainHead := git(t, f.repo, "rev-parse", "refs/remotes/origin/main")
	if got := git(t, f.origin, "rev-parse", "refs/heads/integration/c-12"); got != mainHead {
		t.Fatalf("integration/c-12 = %s, want the head of main %s", got, mainHead)
	}
	calls := readFile(t, filepath.Join(f.ghDir, "calls"))
	if !strings.Contains(calls, "--base\tintegration/c-12") {
		t.Errorf("the PR was not created against the integration branch:\n%s", calls)
	}
	u := run.out.Unit("main")
	if u.Workspace == nil || u.Workspace.IntegrationBranch != "integration/c-12" || u.Workspace.IntegrationHead != mainHead {
		t.Fatalf("workspace = %+v", u.Workspace)
	}
	if got := u.Rounds[0].Steps[0].Step + " " + u.Rounds[0].Steps[1].Step + ":" + u.Rounds[0].Steps[1].Outcome + " " + u.Rounds[0].Steps[2].Step + ":" + u.Rounds[0].Steps[2].Outcome; got != "resolve integration-route:create integration:created" {
		t.Errorf("steps: %s", got)
	}

	// 成果物: role の付いた branch と commit が 1 つずつ。role の無い commit はちょうど 1 つ。作業ブランチの branch も出る
	cd, _ := f.h.contractNow("status", run.id)
	if n, ref := countRole(cd.Artifacts, "branch", "integration"); n != 1 || ref != "integration/c-12" {
		t.Errorf("integration branch artifacts = %d %q: %+v", n, ref, cd.Artifacts)
	}
	if n, ref := countRole(cd.Artifacts, "commit", "integration"); n != 1 || ref != mainHead {
		t.Errorf("integration commit artifacts = %d %q: %+v", n, ref, cd.Artifacts)
	}
	if n, _ := countRole(cd.Artifacts, "commit", ""); n != 1 {
		t.Errorf("commit artifacts without a role = %d: %+v", n, cd.Artifacts)
	}
	if n, ref := countRole(cd.Artifacts, "branch", ""); n != 1 || ref != "feature/task-1-add-widget" {
		t.Errorf("the working branch artifact = %d %q: %+v", n, ref, cd.Artifacts)
	}
}

// 同じ challenge_id の 2 本は、同じ名前の統合ブランチを使う（2 本目は在るものを動かさない）。
func TestTicketIntegrationTwoTasksOfOneChallengeShareTheBranch(t *testing.T) {
	f := newTicketFixture(t)
	f.setAnalyzeBranch("feature/task-1-a")
	startIntegration(t, f, "T-1", "uses_integration=true", "challenge_id=C-12")
	first := git(t, f.origin, "rev-parse", "refs/heads/integration/c-12")

	f.setAnalyzeBranchAt(6, "feature/task-2-b")
	f.respondRest(7)
	run2 := startIntegration(t, f, "T-2", "uses_integration=true", "challenge_id=c-12")
	u := run2.out.Unit("main")
	if u.Workspace == nil || u.Workspace.IntegrationBranch != "integration/c-12" || u.Workspace.IntegrationHead != first {
		t.Fatalf("2nd run workspace = %+v, want integration/c-12 at %s", u.Workspace, first)
	}
	var integration string
	for _, s := range u.Rounds[0].Steps {
		if s.Step == "integration" {
			integration = s.Outcome
		}
	}
	if integration != "existing" {
		t.Errorf("2nd run integration outcome = %q, want existing", integration)
	}
	if got := git(t, f.origin, "rev-parse", "refs/heads/integration/c-12"); got != first {
		t.Errorf("integration/c-12 moved: %s -> %s", first, got)
	}
}

// uses_integration を渡さない実行は、段が 1 つ（integration-route）増えるだけで、成果物に role を持つ要素は出ない。
// base に人が作った統合ブランチを渡した実行も同じ。
func TestTicketWithoutUsesIntegrationHasNoRoleArtifacts(t *testing.T) {
	for _, c := range []struct {
		name  string
		extra []string
		prep  func(t *testing.T, f *ticketFixture)
		base  string
	}{
		{name: "no uses_integration", base: "main"},
		{name: "uses_integration false (challenge_id is only received)", extra: []string{"uses_integration=false", "challenge_id=C-12"}, base: "main"},
		{name: "a human-made integration branch passed as base", extra: []string{"base=feat/issue-40"}, base: "feat/issue-40",
			prep: func(t *testing.T, f *ticketFixture) {
				git(t, f.repo, "push", "-q", "origin", "main:refs/heads/feat/issue-40")
			}},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newTicketFixture(t)
			f.setAnalyzeBranch("feature/task-1-add-widget")
			if c.prep != nil {
				c.prep(t, f)
			}
			run := startIntegration(t, f, "T-1", c.extra...)
			cd, _ := f.h.contractNow("status", run.id)
			for _, a := range cd.Artifacts {
				if a.Role != "" {
					t.Errorf("an artifact has a role: %+v", cd.Artifacts)
				}
			}
			if n, _ := countRole(cd.Artifacts, "commit", ""); n != 1 {
				t.Errorf("commit artifacts = %d: %+v", n, cd.Artifacts)
			}
			var routed string
			for _, s := range run.out.Unit("main").Rounds[0].Steps {
				if s.Step == "integration-route" {
					routed = s.Outcome
				}
				if s.Step == "integration" {
					t.Errorf("the ensure-base step ran")
				}
			}
			if routed != "none" {
				t.Errorf("integration-route = %q, want none", routed)
			}
			if got := git(t, f.origin, "for-each-ref", "refs/heads/integration"); got != "" {
				t.Errorf("an integration branch was created: %s", got)
			}
			raw, _ := json.Marshal(cd.Artifacts)
			if strings.Contains(string(raw), `"role"`) {
				t.Errorf("artifacts carry a role: %s", raw)
			}
			if !strings.Contains(readFile(t, filepath.Join(f.ghDir, "calls")), "--base\t"+c.base) {
				t.Errorf("the PR base is not %s", c.base)
			}
		})
	}
}

// 統合ブランチを作れない（origin が拒む）→ integration_create_failed。作業ツリーも claude の費用も使わない。
func TestTicketIntegrationCreateRefused(t *testing.T) {
	f := newTicketFixture(t)
	git(t, f.repo, "push", "-q", "origin", "main:refs/heads/integration")
	taskFile := filepath.Join(t.TempDir(), "task.md")
	if err := os.WriteFile(taskFile, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, errOut, code := f.h.run("run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts),
		"--input", "task_file="+taskFile, "--input", "task_id=T-1", "--input", "uses_integration=true", "--input", "challenge_id=C-12", "ticket")
	if code != ExitFailed {
		t.Fatalf("exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Reason != "integration_create_failed" || v.Unit("main").Workspace != nil && v.Unit("main").Workspace.WorktreePath != "" {
		t.Fatalf("reason %s workspace %+v", v.Reason, v.Unit("main").Workspace)
	}
	if _, err := os.Stat(filepath.Join(f.fdir, "count")); err == nil {
		t.Errorf("claude was launched although the integration branch could not be created")
	}
}
