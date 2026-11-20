package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 文面のファイルと task_id だけ（Issue 無し）の run が、PR を作るところまで進む（#388 S3-1）。作業ツリーとブランチの名前は
// 鍵 task-<番号> で決まり、analyze・implement は文面のファイルのパスを受け取り、PR は何も閉じない。空の入力は「無い」と読む。
func TestTicketWorkflowFromATaskFileAndTaskID(t *testing.T) {
	f := newTicketFixture(t)
	taskFile := filepath.Join(t.TempDir(), "task.md")
	if err := os.WriteFile(taskFile, []byte("# T-12 widget を足す\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	branch := "feature/task-12-add-widget"
	f.setAnalyzeBranch(branch)
	out, errOut, code := f.h.run("run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts),
		"--input", "issue=", "--input", "base=", "--input", "worktree=", "--input", "challenge_id=",
		"--input", "task_file="+taskFile, "--input", "task_id=T-12", "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	u := v.Unit("main")
	wt := filepath.Join(f.root, "repo-worktrees", "task-12")
	if u.Workspace == nil || u.Workspace.WorktreePath != wt || u.Workspace.Branch != branch || !u.Workspace.Created {
		t.Fatalf("workspace = %+v, want %s on %s", u.Workspace, wt, branch)
	}
	var resolved struct {
		Issue    int    `json:"issue"`
		Key      string `json:"key"`
		TaskFile string `json:"task_file"`
		Scope    string `json:"scope"`
	}
	if err := json.Unmarshal(u.Outputs["resolve"], &resolved); err != nil || resolved.Issue != 0 || resolved.Key != "task-12" || resolved.TaskFile != taskFile || resolved.Scope != "task_file" {
		t.Fatalf("resolve output %s (%v)", u.Outputs["resolve"], err)
	}
	// 空の入力は run_started.inputs に入らない
	for _, name := range []string{"issue", "base", "worktree", "challenge_id"} {
		if _, ok := v.Inputs[name]; ok {
			t.Errorf("the empty input %q was recorded: %s", name, v.Inputs[name])
		}
	}
	// analyze・implement は文面のファイルのパスと鍵を受け取る（添付データの inputs）
	if in := readFile(t, filepath.Join(f.fdir, "calls", "1.stdin")); !strings.Contains(in, taskFile) || !strings.Contains(in, `"key": "task-12"`) {
		t.Errorf("analyze did not receive the task file and the key: %s", in)
	}
	if in := readFile(t, filepath.Join(f.fdir, "calls", "2.stdin")); !strings.Contains(in, taskFile) {
		t.Errorf("implement did not receive the task file: %s", in)
	}
	// 文面のファイルのあるフォルダを --add-dir で渡す（作業ツリーの外でも LLM の段が Read できるように。§5.6.2）。
	// analyze（1 回目）・implement（2 回目）に付き、複数の add-dir にならない。
	for _, n := range []int{1, 2} {
		argv := readFile(t, filepath.Join(f.fdir, "calls", fmt.Sprintf("%d.argv", n)))
		if want := "--add-dir\n" + filepath.Dir(taskFile) + "\n"; strings.Count(argv, "--add-dir\n") != 1 || !strings.Contains(argv, want) {
			t.Errorf("claude call %d: argv lacks %q exactly once:\n%s", n, want, argv)
		}
	}
	// PR は何も閉じず、Refs も書かない
	body := readFile(t, filepath.Join(f.ghDir, "body.1.md"))
	if strings.Contains(body, "Closes") || strings.Contains(body, "Refs") {
		t.Errorf("the PR body names an issue:\n%s", body)
	}
	if strings.Contains(readFile(t, filepath.Join(f.ghDir, "calls")), "issue\tview") {
		t.Errorf("gh issue view was called without an issue")
	}
}

// 同じ Issue を取り込み元に持つタスクが task_id を変えて 2 本走っても、別の作業ツリーと別のブランチになり、重ならない。
func TestTicketWorkflowTwoTasksOfTheSameIssueDoNotOverlap(t *testing.T) {
	f := newTicketFixture(t)
	taskFile := filepath.Join(t.TempDir(), "task.md")
	if err := os.WriteFile(taskFile, []byte("# widget\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var paths, branches []string
	for i, id := range []string{"T-1", "T-2"} {
		n := fmt.Sprintf("task-%d", i+1)
		f.setAnalyzeBranchAt(i*5+1, "feature/"+n+"-add-widget")
		f.respondRest(i*5 + 2)
		out, errOut, code := f.h.run("run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts),
			"--input", "issue=42", "--input", "task_file="+taskFile, "--input", "task_id="+id, "ticket")
		if code != ExitWaiting {
			t.Fatalf("%s: run exit %d\n%s\n%s", id, code, out, errOut)
		}
		w := decode[statusView](t, out).Unit("main").Workspace
		if w == nil {
			t.Fatalf("%s: no workspace", id)
		}
		paths, branches = append(paths, w.WorktreePath), append(branches, w.Branch)
		if want := filepath.Join(f.root, "repo-worktrees", n); w.WorktreePath != want {
			t.Errorf("%s: worktree %s, want %s", id, w.WorktreePath, want)
		}
	}
	if paths[0] == paths[1] || branches[0] == branches[1] {
		t.Errorf("the two tasks share a worktree or a branch: %v %v", paths, branches)
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("worktree %s: %v", p, err)
		}
	}
}

// issue だけの run は、いままでと同じ場所（<root>/issue-<n>）と名前（{type}/issue-<n>-{説明}）になる。
func TestTicketWorkflowIssueOnlyKeepsThePlaceAndTheName(t *testing.T) {
	f := newTicketFixture(t)
	out, errOut, code := f.h.run("run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--input", "issue=42", "ticket")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	u := decode[statusView](t, out).Unit("main")
	if w := u.Workspace; w == nil || w.WorktreePath != filepath.Join(f.root, "repo-worktrees", "issue-42") || w.Branch != "feature/issue-42-add-widget" {
		t.Fatalf("workspace = %+v", w)
	}
	var resolved struct {
		Key, Scope string
	}
	if err := json.Unmarshal(u.Outputs["resolve"], &resolved); err != nil || resolved.Key != "issue-42" || resolved.Scope != "issue" {
		t.Fatalf("resolve output %s", u.Outputs["resolve"])
	}
	// 文面のファイルが無いときは --add-dir を付けない（task_dir は空文字）
	calls, _ := filepath.Glob(filepath.Join(f.fdir, "calls", "*.argv"))
	if len(calls) == 0 {
		t.Fatal("claude was not called")
	}
	for _, c := range calls {
		if argv := readFile(t, c); strings.Contains(argv, "--add-dir") {
			t.Errorf("%s: an issue-only run passed --add-dir:\n%s", filepath.Base(c), argv)
		}
	}
}

// 入力が誤りなら run は始まってすぐ failed になり（start では止めない）、claude も作業ツリーも起動しない。
func TestTicketWorkflowStopsOnInvalidInputs(t *testing.T) {
	taskFile := filepath.Join(t.TempDir(), "task.md")
	if err := os.WriteFile(taskFile, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, reason string
		inputs       []string
	}{
		{"nothing", "input_invalid", nil},
		{"relative task_file", "input_invalid", []string{"task_file=task.md", "task_id=T-1"}},
		{"bad task_id", "input_invalid", []string{"task_file=" + taskFile, "task_id=1"}},
		{"no key", "input_invalid", []string{"task_file=" + taskFile}},
		{"uses_integration is yes", "input_invalid", []string{"task_file=" + taskFile, "task_id=T-1", "uses_integration=yes"}},
		{"uses_integration is true", "integration_unsupported", []string{"task_file=" + taskFile, "task_id=T-1", "uses_integration=true"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newTicketFixture(t)
			args := []string{"run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts)}
			for _, in := range c.inputs {
				args = append(args, "--input", in)
			}
			out, errOut, code := f.h.run(append(args, "ticket")...)
			if code != ExitFailed {
				t.Fatalf("exit %d\n%s\n%s", code, out, errOut)
			}
			v := decode[statusView](t, out)
			if v.Reason != c.reason || v.Unit("main").Workspace != nil {
				t.Fatalf("reason %s workspace %+v", v.Reason, v.Unit("main").Workspace)
			}
			if _, err := os.Stat(filepath.Join(f.fdir, "count")); err == nil {
				t.Errorf("claude was launched for invalid inputs")
			}
		})
	}
}
