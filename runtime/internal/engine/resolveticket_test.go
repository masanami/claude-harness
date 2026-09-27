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

// fakeBin は偽の gh・git を gh・git の名前で置いた PATH 用のディレクトリを作る（スクリプトは PATH の gh・git を呼ぶ）。
func fakeBin(t *testing.T) string {
	t.Helper()
	bin := t.TempDir()
	for name, target := range map[string]string{"gh": "fake-gh.sh", "git": "fake-git.sh"} {
		if err := os.Symlink(testdata(t, "scripts", target), filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	return bin
}

type resolved struct {
	Outcome       string `json:"outcome"`
	Issue         int    `json:"issue"`
	Title         string `json:"title"`
	Base          string `json:"base"`
	BaseKind      string `json:"base_kind"`
	BaseSource    string `json:"base_source"`
	DefaultBranch string `json:"default_branch"`
	Message       string `json:"message"`
}

// resolveTicket は runtime/workflows/scripts/resolve-ticket.sh を偽の gh・git で動かす。
func resolveTicket(t *testing.T, tl *tools, body string, args ...string) (resolved, int, string) {
	t.Helper()
	issue, _ := json.Marshal(map[string]any{"number": 42, "title": "Add the widget", "body": body, "state": "OPEN"})
	tl.write(tl.gh, "issue.json", string(issue))
	cmd := exec.Command("bash", append([]string{filepath.Join("..", "..", "workflows", "scripts", "resolve-ticket.sh"), "--issue", "42"}, args...)...)
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
	var r resolved
	if code == 0 {
		if err := json.Unmarshal(out.Bytes(), &r); err != nil {
			t.Fatalf("stdout is not JSON: %v\n%s", err, out.String())
		}
	}
	return r, code, errb.String()
}

// resolve-ticket は base を --base ＞ Base: 行 ＞ 既定ブランチの順で決め（I2）、統合ブランチが remote に無ければ base_missing（I3）。
func TestResolveTicket(t *testing.T) {
	cases := []struct {
		name     string
		body     string
		args     []string
		remote   string // remote に在るブランチ
		outcome  string
		base     string
		kind     string
		source   string
		wantMsg  string
		checkLsR bool // ls-remote を呼んだか
	}{
		{name: "no Base line: default branch", body: "## 背景\nwidget\n", outcome: "ok", base: "main", kind: "default", source: "default"},
		{name: "Base line and the branch exists", body: "Base: feat/issue-40\n\n## 背景\n", remote: "feat/issue-40", outcome: "ok", base: "feat/issue-40", kind: "integration", source: "issue", checkLsR: true},
		{name: "Base line but the branch is missing", body: "Base: feat/issue-40\n", outcome: "base_missing", base: "feat/issue-40", kind: "integration", source: "issue", wantMsg: "git push -u origin feat/issue-40", checkLsR: true},
		{name: "Base line with backticks and CRLF", body: "Base: `feat/issue-40`\r\n", remote: "feat/issue-40", outcome: "ok", base: "feat/issue-40", kind: "integration", source: "issue"},
		{name: "Base in an HTML comment is not read", body: "<!-- 統合ブランチ方式のときだけ:\nBase: feat/placeholder\n-->\n## 背景\n", outcome: "ok", base: "main", kind: "default", source: "default"},
		{name: "--base wins over the Base line", body: "Base: feat/issue-40\n", args: []string{"--base", "feat/other"}, remote: "feat/other", outcome: "ok", base: "feat/other", kind: "integration", source: "input"},
		{name: "--base of the default branch", body: "Base: feat/issue-40\n", args: []string{"--base", "main"}, outcome: "ok", base: "main", kind: "default", source: "input"},
		{name: "Base line naming the default branch", body: "Base: main\n", outcome: "ok", base: "main", kind: "default", source: "issue"},
		{name: "two different Base lines", body: "Base: feat/a\nBase: feat/b\n", remote: "feat/a", outcome: "base_missing", base: "feat/a", source: "issue", kind: "integration", wantMsg: "値の異なる Base: 行が 2 個"},
		{name: "the same Base line twice", body: "Base: feat/a\n\nBase: feat/a\n", remote: "feat/a", outcome: "ok", base: "feat/a", kind: "integration", source: "issue"},
		{name: "placeholder left in the Base line", body: "Base: {統合ブランチ}\n", outcome: "base_missing", base: "{統合ブランチ}", kind: "integration", source: "issue", wantMsg: "ブランチ名として受け付けられない"},
		{name: "Base: inside a sentence is not a Base line", body: "see the Base: line of #40\n", outcome: "ok", base: "main", kind: "default", source: "default"},
		{name: "Base in a code block is not read", body: "例:\n```\nBase: feat/example\n```\n", outcome: "ok", base: "main", kind: "default", source: "default"},
		{name: "a branch that only ends with the base is not the base", body: "Base: epic\n", remote: "feature/epic", outcome: "base_missing", base: "epic", kind: "integration", source: "issue", checkLsR: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tl := newTools(t)
			tl.write(tl.git, "remote-branches", c.remote+"\n")
			r, code, stderr := resolveTicket(t, tl, c.body, c.args...)
			if code != 0 {
				t.Fatalf("exit %d: %s", code, stderr)
			}
			if r.Outcome != c.outcome || r.Base != c.base || r.BaseKind != c.kind || r.BaseSource != c.source || r.Issue != 42 || r.Title != "Add the widget" || r.DefaultBranch != "main" {
				t.Fatalf("got %+v", r)
			}
			if c.wantMsg != "" && !strings.Contains(r.Message, c.wantMsg) {
				t.Errorf("message %q lacks %q", r.Message, c.wantMsg)
			}
			if c.outcome == "ok" && r.Message != "" {
				t.Errorf("ok with a message: %q", r.Message)
			}
			if c.checkLsR && !strings.Contains(tl.read(tl.git, "calls"), "ls-remote\t--exit-code\t--heads\torigin\trefs/heads/"+c.base+"\n") {
				t.Errorf("did not check the remote: %s", tl.read(tl.git, "calls"))
			}
		})
	}
}

// gh・git の失敗は base_missing に丸めず、非 0 で終わる（runtime は step_error にする）。
func TestResolveTicketFailures(t *testing.T) {
	t.Run("issue not found", func(t *testing.T) {
		tl := newTools(t)
		cmd := exec.Command("bash", filepath.Join("..", "..", "workflows", "scripts", "resolve-ticket.sh"), "--issue", "42")
		cmd.Env = append(os.Environ(), "PATH="+fakeBin(t)+string(os.PathListSeparator)+os.Getenv("PATH"))
		_ = tl
		if err := cmd.Run(); err == nil {
			t.Fatal("expected a failure when gh issue view fails")
		}
	})
	t.Run("ls-remote error", func(t *testing.T) {
		tl := newTools(t)
		tl.write(tl.git, "ls-remote.code", "128")
		if _, code, _ := resolveTicket(t, tl, "Base: feat/x\n"); code == 0 {
			t.Fatal("expected a failure when git ls-remote fails")
		}
	})
	t.Run("bad arguments", func(t *testing.T) {
		tl := newTools(t)
		if _, code, _ := resolveTicket(t, tl, "", "--nope"); code != 2 {
			t.Fatalf("exit %d", code)
		}
		if _, code, _ := resolveTicket(t, tl, "", "--base"); code != 2 { // 値の無い引数で止まらずに回り続けない
			t.Fatalf("exit %d", code)
		}
	})
}
