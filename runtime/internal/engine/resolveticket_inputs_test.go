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
	Outcome     string `json:"outcome"`
	Issue       int    `json:"issue"`
	Key         string `json:"key"`
	TaskFile    string `json:"task_file"`
	TaskDir     string `json:"task_dir"`
	Scope       string `json:"scope"`
	Base        string `json:"base"`
	BaseKind    string `json:"base_kind"`
	BaseSource  string `json:"base_source"`
	Integration string `json:"integration"`
	Closes      *int   `json:"closes"`
	Refs        []int  `json:"refs"`
	Message     string `json:"message"`
}

// resolveWith は resolve-ticket.sh を、渡した引数そのままで偽の gh・git で動かす（--issue を足さない）。
func resolveWith(t *testing.T, tl *tools, issueBody string, args ...string) (resolvedInputs, int, string) {
	t.Helper()
	return resolveIn(t, tl, "HARNESS_RUN_DIR="+t.TempDir(), issueBody, args...)
}

// resolveIn は run ディレクトリの環境変数（runDirEnv。"HARNESS_RUN_DIR=<パス>"）を指定して resolve-ticket.sh を動かす。
func resolveIn(t *testing.T, tl *tools, runDirEnv, issueBody string, args ...string) (resolvedInputs, int, string) {
	t.Helper()
	issue, _ := json.Marshal(map[string]any{"number": 42, "title": "Add the widget", "body": issueBody, "state": "OPEN"})
	tl.write(tl.gh, "issue.json", string(issue))
	cmd := exec.Command("bash", append([]string{filepath.Join("..", "..", "workflows", "scripts", "resolve-ticket.sh")}, args...)...)
	// TMPDIR は在りえない場所にする: 文面の写しの置き場に OS の一時ディレクトリを使っていれば、ここで失敗する
	cmd.Env = append(os.Environ(), runDirEnv, "TMPDIR="+filepath.Join(t.TempDir(), "no-such-tmp"), "PATH="+fakeBin(t)+string(os.PathListSeparator)+os.Getenv("PATH"))
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
		{name: "uses_integration が true で challenge_id が無い", args: []string{"--task_file", taskFile, "--task_id", "T-1", "--uses_integration", "true"}, outcome: "input_invalid", scope: "task_file", wantMsg: "challenge_id が無い"},
		{name: "uses_integration が true で challenge_id が無い（issue だけ）", args: []string{"--issue", "42", "--uses_integration", "true"}, outcome: "input_invalid", scope: "issue", wantMsg: "challenge_id が無い"},
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
	if r.Outcome != "ok" || r.Issue != 0 || r.Key != "task-5" || r.Base != "main" || r.BaseKind != "default" ||
		r.Closes == nil || *r.Closes != 0 || len(r.Refs) != 0 {
		t.Fatalf("got %+v", r)
	}
	// 文面のファイルは、そのファイルだけが在る新しい置き場へ写される。task_file は写しのパス、task_dir は置き場（元の親ディレクトリではない）
	if r.TaskDir == dir || filepath.Dir(r.TaskFile) != r.TaskDir || r.TaskFile == taskFile {
		t.Errorf("task_file %q task_dir %q: want a copy in a dedicated directory, not the parent %q of the original", r.TaskFile, r.TaskDir, dir)
	}
	if b, err := os.ReadFile(r.TaskFile); err != nil || string(b) != "Base: feat/ignored\n" {
		t.Errorf("the copy = %q (%v)", b, err)
	}
	if entries, err := os.ReadDir(r.TaskDir); err != nil || len(entries) != 1 {
		t.Errorf("the dedicated directory holds %v (%v), want only the copy", entries, err)
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

// 文面の写しの置き場は run ディレクトリ（HARNESS_RUN_DIR）の下の task/ で、OS の一時ディレクトリではない（レビュー待ちの間に
// 掃除されない）。写した後に元のファイルが変わっても・消えても、写しは最初の中身のまま（この段をやり直しても写し直さない）。
func TestResolveTicketKeepsTheTaskFileCopyInTheRunDirectory(t *testing.T) {
	runDir := t.TempDir()
	taskFile := filepath.Join(t.TempDir(), "task.md")
	if err := os.WriteFile(taskFile, []byte("first\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tl := newTools(t)
	r, code, stderr := resolveIn(t, tl, "HARNESS_RUN_DIR="+runDir, "", "--task_file", taskFile, "--task_id", "T-5")
	if code != 0 || r.Outcome != "ok" {
		t.Fatalf("exit %d outcome %q: %s", code, r.Outcome, stderr)
	}
	if want := filepath.Join(runDir, "task"); r.TaskDir != want || r.TaskFile != filepath.Join(want, "task.md") {
		t.Fatalf("task_dir %q task_file %q, want the copy at %s/task.md", r.TaskDir, r.TaskFile, want)
	}
	if fi, err := os.Stat(r.TaskDir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("the directory of the copy: %v (%v), want mode 0700", fi, err)
	}
	// 元のファイルを書き換えてやり直しても、run は最初の写しを読む
	if err := os.WriteFile(taskFile, []byte("second\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, code, stderr = resolveIn(t, tl, "HARNESS_RUN_DIR="+runDir, "", "--task_file", taskFile, "--task_id", "T-5")
	if code != 0 || r.Outcome != "ok" {
		t.Fatalf("rerun: exit %d outcome %q: %s", code, r.Outcome, stderr)
	}
	if b, err := os.ReadFile(r.TaskFile); err != nil || string(b) != "first\n" {
		t.Errorf("the copy after the original changed = %q (%v), want the first content", b, err)
	}
	if entries, err := os.ReadDir(r.TaskDir); err != nil || len(entries) != 1 {
		t.Errorf("the directory of the copy holds %v (%v), want only the copy", entries, err)
	}
	// 元のファイルが消えても写しは残る
	if err := os.Remove(taskFile); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(runDir, "task", "task.md")); err != nil || string(b) != "first\n" {
		t.Errorf("the copy after the original was removed = %q (%v)", b, err)
	}
}

// run ディレクトリが渡っていない（HARNESS_RUN_DIR が無い・絶対パスでない・無いディレクトリ）ときは、一時ディレクトリへ逃げずに
// 理由を出して非 0 で終わる。文面のファイルを渡していなければ run ディレクトリは要らない。task_file が読めない・絶対パスでない
// ときの input_invalid は、run ディレクトリの有無に関わらず保つ。
func TestResolveTicketNeedsTheRunDirectoryOnlyForATaskFile(t *testing.T) {
	taskFile := filepath.Join(t.TempDir(), "task.md")
	if err := os.WriteFile(taskFile, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tl := newTools(t)
	for _, env := range []string{"HARNESS_RUN_DIR=", "HARNESS_RUN_DIR=relative/dir", "HARNESS_RUN_DIR=" + filepath.Join(t.TempDir(), "missing")} {
		_, code, stderr := resolveIn(t, tl, env, "", "--task_file", taskFile, "--task_id", "T-5")
		if code == 0 || !strings.Contains(stderr, "HARNESS_RUN_DIR") {
			t.Errorf("%s: exit %d stderr %q, want a non-zero exit naming HARNESS_RUN_DIR", env, code, stderr)
		}
	}
	if r, code, stderr := resolveIn(t, tl, "HARNESS_RUN_DIR=", "body", "--issue", "42"); code != 0 || r.Outcome != "ok" || r.TaskDir != "" {
		t.Errorf("issue only without a run directory: exit %d %+v %s", code, r, stderr)
	}
	for _, bad := range []string{"relative/task.md", filepath.Join(t.TempDir(), "missing.md"), t.TempDir()} {
		for _, env := range []string{"HARNESS_RUN_DIR=", "HARNESS_RUN_DIR=" + t.TempDir()} {
			r, code, stderr := resolveIn(t, tl, env, "", "--task_file", bad, "--task_id", "T-5")
			if code != 0 || r.Outcome != "input_invalid" || r.TaskDir != "" {
				t.Errorf("task_file %q (%s): exit %d %+v %s, want input_invalid", bad, env, code, r, stderr)
			}
		}
	}
}
