package engine

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

type resolvedInputs struct {
	Outcome  string `json:"outcome"`
	Issue    int    `json:"issue"`
	Key      string `json:"key"`
	TaskFile string `json:"task_file"`
	Scope    string `json:"scope"`
	Base     string `json:"base"`
	BaseKind string `json:"base_kind"`
	Closes   *int   `json:"closes"`
	Refs     []int  `json:"refs"`
	Message  string `json:"message"`
}

// resolveWith は resolve-ticket.sh を、渡した引数そのままで偽の gh・git で動かす（--issue を足さない）。
func resolveWith(t *testing.T, tl *tools, issueBody string, args ...string) (resolvedInputs, int, string) {
	t.Helper()
	issue, _ := json.Marshal(map[string]any{"number": 42, "title": "Add the widget", "body": issueBody, "state": "OPEN"})
	tl.write(tl.gh, "issue.json", string(issue))
	cmd := exec.Command("bash", append([]string{filepath.Join("..", "..", "workflows", "scripts", "resolve-ticket.sh")}, args...)...)
	cmd.Env = append(os.Environ(), "PATH="+fakeBin(t)+string(os.PathListSeparator)+os.Getenv("PATH"))
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	var r resolvedInputs
	if code == 0 {
		if err := json.Unmarshal(out.Bytes(), &r); err != nil {
			t.Fatalf("stdout is not JSON: %v\n%s", err, out.String())
		}
	}
	return r, code, errb.String()
}

// 入力どうしの条件の表（docs/harness-runtime-design.md §5.6.2）の全行。誤りは gh・git を呼ばずに input_invalid で止める。
func TestResolveTicketInputTable(t *testing.T) {
	dir := t.TempDir()
	taskFile := filepath.Join(dir, "task.md")
	if err := os.WriteFile(taskFile, []byte("# タスク\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name    string
		args    []string
		outcome string
		key     string
		scope   string
		wantMsg string
	}{
		{name: "issue も task_file も無い", args: []string{"--task_id", "T-1"}, outcome: "input_invalid", wantMsg: "issue も task_file も無い"},
		{name: "何も無い", args: nil, outcome: "input_invalid", wantMsg: "issue も task_file も無い"},
		{name: "task_file が相対パス", args: []string{"--task_file", "task.md", "--task_id", "T-1"}, outcome: "input_invalid", scope: "task_file", wantMsg: "絶対パスでない"},
		{name: "task_file が無いファイル", args: []string{"--task_file", filepath.Join(dir, "nope.md"), "--task_id", "T-1"}, outcome: "input_invalid", scope: "task_file", wantMsg: "読めるファイルでない"},
		{name: "task_file がディレクトリ", args: []string{"--task_file", dir, "--task_id", "T-1"}, outcome: "input_invalid", scope: "task_file", wantMsg: "読めるファイルでない"},
		{name: "task_id が T- でない", args: []string{"--task_file", taskFile, "--task_id", "12"}, outcome: "input_invalid", scope: "task_file", wantMsg: "T-<1 以上の整数>"},
		{name: "task_id が T-0", args: []string{"--task_file", taskFile, "--task_id", "T-0"}, outcome: "input_invalid", scope: "task_file", wantMsg: "T-<1 以上の整数>"},
		{name: "task_id が T-01", args: []string{"--task_file", taskFile, "--task_id", "T-01"}, outcome: "input_invalid", scope: "task_file", wantMsg: "T-<1 以上の整数>"},
		{name: "task_id が T-x", args: []string{"--task_file", taskFile, "--task_id", "T-x"}, outcome: "input_invalid", scope: "task_file", wantMsg: "T-<1 以上の整数>"},
		{name: "task_id が T-1 の後ろに続く", args: []string{"--task_file", taskFile, "--task_id", "T-1x"}, outcome: "input_invalid", scope: "task_file", wantMsg: "T-<1 以上の整数>"},
		{name: "issue も task_id も無い（鍵が無い）", args: []string{"--task_file", taskFile}, outcome: "input_invalid", scope: "task_file", wantMsg: "鍵を決められない"},
		{name: "uses_integration が true・false 以外", args: []string{"--task_file", taskFile, "--task_id", "T-1", "--uses_integration", "yes"}, outcome: "input_invalid", key: "", scope: "task_file", wantMsg: "uses_integration"},
		{name: "uses_integration が大文字", args: []string{"--task_file", taskFile, "--task_id", "T-1", "--uses_integration", "True"}, outcome: "input_invalid", scope: "task_file", wantMsg: "uses_integration"},
		{name: "uses_integration が true", args: []string{"--task_file", taskFile, "--task_id", "T-1", "--uses_integration", "true"}, outcome: "integration_unsupported", key: "task-1", scope: "task_file", wantMsg: "uses_integration"},
		{name: "uses_integration が true で issue だけ", args: []string{"--issue", "42", "--uses_integration", "true"}, outcome: "integration_unsupported", key: "issue-42", scope: "issue", wantMsg: "uses_integration"},
		{name: "uses_integration が false は通る", args: []string{"--task_file", taskFile, "--task_id", "T-1", "--uses_integration", "false"}, outcome: "ok", key: "task-1", scope: "task_file"},
		{name: "task_file と task_id だけ", args: []string{"--task_file", taskFile, "--task_id", "T-12"}, outcome: "ok", key: "task-12", scope: "task_file"},
		{name: "issue だけ", args: []string{"--issue", "42"}, outcome: "ok", key: "issue-42", scope: "issue"},
		{name: "issue と task_id（task_file 無し）は task の鍵", args: []string{"--issue", "42", "--task_id", "T-3"}, outcome: "ok", key: "task-3", scope: "issue"},
		{name: "issue と task_file と task_id", args: []string{"--issue", "42", "--task_file", taskFile, "--task_id", "T-3"}, outcome: "ok", key: "task-3", scope: "task_file"},
		{name: "issue と task_file（task_id 無し）は issue の鍵", args: []string{"--issue", "42", "--task_file", taskFile}, outcome: "ok", key: "issue-42", scope: "task_file"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tl := newTools(t)
			r, code, stderr := resolveWith(t, tl, "", c.args...)
			if code != 0 {
				t.Fatalf("exit %d: %s", code, stderr)
			}
			if r.Outcome != c.outcome || r.Key != c.key {
				t.Fatalf("got %+v", r)
			}
			if c.scope != "" && r.Scope != c.scope {
				t.Errorf("scope %q, want %q", r.Scope, c.scope)
			}
			if c.wantMsg != "" && !strings.Contains(r.Message, c.wantMsg) {
				t.Errorf("message %q lacks %q", r.Message, c.wantMsg)
			}
			if c.outcome == "ok" && r.Message != "" {
				t.Errorf("ok with a message: %q", r.Message)
			}
			if c.outcome != "ok" {
				if calls := tl.read(tl.gh, "calls") + tl.read(tl.git, "calls"); calls != "" {
					t.Errorf("a failed input check called gh or git: %s", calls)
				}
			}
		})
	}
}

// task_file だけ（issue 無し）の run は gh issue view を呼ばず、issue は 0・closes は 0・refs は空。base は --base ＞ 既定ブランチ。
func TestResolveTicketTaskFileOnly(t *testing.T) {
	dir := t.TempDir()
	taskFile := filepath.Join(dir, "task.md")
	if err := os.WriteFile(taskFile, []byte("Base: feat/ignored\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tl := newTools(t)
	r, code, stderr := resolveWith(t, tl, "", "--task_file", taskFile, "--task_id", "T-5")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if r.Outcome != "ok" || r.Issue != 0 || r.Key != "task-5" || r.TaskFile != taskFile || r.Base != "main" || r.BaseKind != "default" ||
		r.Closes == nil || *r.Closes != 0 || len(r.Refs) != 0 {
		t.Fatalf("got %+v", r)
	}
	if strings.Contains(tl.read(tl.gh, "calls"), "issue\tview") {
		t.Errorf("read an issue that was not given: %s", tl.read(tl.gh, "calls"))
	}
	// --base の統合ブランチは remote に在るかを確かめる
	r, _, _ = resolveWith(t, tl, "", "--task_file", taskFile, "--task_id", "T-5", "--base", "feat/x")
	if r.Outcome != "base_missing" || r.Base != "feat/x" {
		t.Fatalf("got %+v", r)
	}
}

// issue と task_file が両方あるとき、Issue は PR が閉じる対象としてだけ読む: Refs:・Closes: なし 行は読み、Base: 行は読まない。
// task_file が無いときは、いまと同じく Base: 行を読む。
func TestResolveTicketIssueWithTaskFile(t *testing.T) {
	dir := t.TempDir()
	taskFile := filepath.Join(dir, "task.md")
	if err := os.WriteFile(taskFile, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	body := "Base: feat/issue-40\nRefs: #7\nCloses: なし\n"
	tl := newTools(t)
	tl.write(tl.git, "remote-branches", "feat/issue-40\n")
	r, code, stderr := resolveWith(t, tl, body, "--issue", "42", "--task_file", taskFile, "--task_id", "T-2")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if r.Outcome != "ok" || r.Base != "main" || r.BaseKind != "default" || r.Closes == nil || *r.Closes != 0 || len(r.Refs) != 1 || r.Refs[0] != 7 || r.Issue != 42 || r.Scope != "task_file" {
		t.Fatalf("with task_file: got %+v", r)
	}
	r, _, _ = resolveWith(t, tl, body, "--issue", "42")
	if r.Outcome != "ok" || r.Base != "feat/issue-40" || r.BaseKind != "integration" || r.Scope != "issue" {
		t.Fatalf("without task_file the Base: line is read as before: got %+v", r)
	}
	// Refs: の誤りは task_file があっても links_invalid
	r, _, _ = resolveWith(t, tl, "Refs: abc\n", "--issue", "42", "--task_file", taskFile, "--task_id", "T-2")
	if r.Outcome != "links_invalid" {
		t.Fatalf("got %+v", r)
	}
}
