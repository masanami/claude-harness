package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// テストバイナリ自身を harness として起動する（別プロセスの run と cancel を実際に走らせるため）。
func TestMain(m *testing.M) {
	if os.Getenv("HARNESS_CLI_TEST_MAIN") == "1" {
		os.Exit(Main(os.Args[1:], DefaultEnv()))
	}
	os.Exit(m.Run())
}

type harness struct {
	t   *testing.T
	env []string
	cwd string
}

// newHarness は状態の置き場を一時ディレクトリへ隔離する。HOME も一時ディレクトリへ向け、
// 利用者の ~/.local/state に書かないことを保証する。
func newHarness(t *testing.T, extraEnv ...string) *harness {
	t.Helper()
	home := t.TempDir()
	env := []string{"HARNESS_CLI_TEST_MAIN=1", "HOME=" + home, "PATH=" + os.Getenv("PATH")}
	env = append(env, extraEnv...)
	return &harness{t: t, env: env, cwd: t.TempDir()}
}

func (h *harness) cmd(args ...string) *exec.Cmd {
	c := exec.Command(os.Args[0], args...)
	c.Env = h.env
	c.Dir = h.cwd
	return c
}

func (h *harness) run(args ...string) (string, string, int) {
	h.t.Helper()
	c := h.cmd(args...)
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	err := c.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		h.t.Fatal(err)
	}
	return out.String(), errb.String(), code
}

func abs(t *testing.T, p string) string {
	t.Helper()
	a, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

var (
	repoWorkflows = "../../workflows"
	repoScripts   = "../../../plugin/scripts"
	testWorkflows = "../engine/testdata/workflows"
	testScripts   = "../engine/testdata/scripts"
)

func decode[T any](t *testing.T, s string) T {
	t.Helper()
	var v T
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, s)
	}
	return v
}

// command 種類だけのサンプル（runtime/workflows/list-tests.yaml）を終端まで実行し、status --json と runs --json が示す。
func TestRunSampleWorkflow(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	root := abs(t, "../../..")
	out, errOut, code := h.run("run", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "--input", "root="+root, "list-tests")
	if code != ExitOK {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	final := decode[map[string]any](t, out)
	id := final["run_id"].(string)
	if final["status"] != "succeeded" || final["reason"] != "listed" {
		t.Fatalf("final = %v %v", final["status"], final["reason"])
	}

	out, _, code = h.run("status", id, "--json")
	if code != ExitOK {
		t.Fatalf("status exit %d", code)
	}
	st := decode[struct {
		runstate.State
		RunDir string `json:"run_dir"`
	}](t, out)
	if st.RunID != id || st.Status != "succeeded" || st.RunDir != filepath.Join(state, "runs", id) {
		t.Fatalf("status = %+v", st)
	}
	u := st.Units[0]
	if u.CurrentStep != "list" || len(u.Rounds) != 1 || u.Rounds[0].Trigger.Kind != "start" || u.Rounds[0].Steps[0].Outcome != "ok" {
		t.Fatalf("unit = %+v", u)
	}
	var listed struct {
		Root   string `json:"root"`
		Counts struct {
			Total int `json:"total"`
		} `json:"counts"`
	}
	if err := json.Unmarshal(u.Outputs["list"], &listed); err != nil || listed.Root != root || listed.Counts.Total == 0 {
		t.Fatalf("output of list = %s", u.Outputs["list"])
	}

	out, _, code = h.run("runs", "--json")
	if code != ExitOK {
		t.Fatalf("runs exit %d", code)
	}
	runs := decode[[]runSummary](t, out)
	if len(runs) != 1 || runs[0].RunID != id || runs[0].Status != "succeeded" || runs[0].Workflow != "list-tests" {
		t.Fatalf("runs = %+v", runs)
	}

	// run ディレクトリだけでも現在地が分かる（state.json は events.jsonl の畳み込みと一致する）。
	fromFile, err := runstate.ReadStateFile(filepath.Join(state, "runs", id))
	if err != nil {
		t.Fatal(err)
	}
	a, _ := json.Marshal(fromFile)
	b, _ := json.Marshal(&st.State)
	if !bytes.Equal(a, b) {
		t.Fatalf("state.json differs from status --json:\n%s\n%s", a, b)
	}
}

// 状態の置き場（L2）: HARNESS_STATE_DIR ＞ XDG_STATE_HOME/claude-harness ＞ ~/.local/state/claude-harness。
func TestStateDirectory(t *testing.T) {
	json0 := `{"outcome":"ok"}`
	args := []string{"run", "--workflow-dir", abs(t, testWorkflows), "--scripts-dir", abs(t, testScripts), "--input", "json=" + json0, "--input", "code=0", "emit"}
	runIDIn := func(t *testing.T, h *harness) string {
		out, errOut, code := h.run(args...)
		if code != ExitOK {
			t.Fatalf("exit %d: %s", code, errOut)
		}
		return decode[map[string]any](t, out)["run_id"].(string)
	}
	exists := func(p string) bool { _, err := os.Stat(p); return err == nil }

	t.Run("HARNESS_STATE_DIR overrides XDG_STATE_HOME", func(t *testing.T) {
		state, xdg := t.TempDir(), t.TempDir()
		h := newHarness(t, "HARNESS_STATE_DIR="+state, "XDG_STATE_HOME="+xdg)
		id := runIDIn(t, h)
		if !exists(filepath.Join(state, "runs", id, runstate.EventsFile)) {
			t.Fatal("run is not under HARNESS_STATE_DIR")
		}
		if exists(filepath.Join(xdg, "claude-harness")) {
			t.Fatal("wrote under XDG_STATE_HOME although HARNESS_STATE_DIR is set")
		}
	})
	t.Run("XDG_STATE_HOME", func(t *testing.T) {
		xdg := t.TempDir()
		h := newHarness(t, "XDG_STATE_HOME="+xdg)
		id := runIDIn(t, h)
		if !exists(filepath.Join(xdg, "claude-harness", "runs", id, runstate.EventsFile)) {
			t.Fatal("run is not under $XDG_STATE_HOME/claude-harness")
		}
	})
	t.Run("HOME fallback", func(t *testing.T) {
		h := newHarness(t)
		id := runIDIn(t, h)
		home := strings.TrimPrefix(h.env[1], "HOME=")
		if !exists(filepath.Join(home, ".local", "state", "claude-harness", "runs", id, runstate.EventsFile)) {
			t.Fatal("run is not under ~/.local/state/claude-harness")
		}
		out, _, _ := h.run("runs", "--json")
		if runs := decode[[]runSummary](t, out); len(runs) != 1 || runs[0].RunID != id {
			t.Fatalf("runs = %+v", runs)
		}
	})
}

// cancel は別プロセスの runner に子プロセスを止めさせ、停止を記録させる。
func TestCancel(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	pidfile := filepath.Join(t.TempDir(), "pids")
	runner := h.cmd("run", "--workflow-dir", abs(t, testWorkflows), "--scripts-dir", abs(t, testScripts), "--input", "pidfile="+pidfile, "sleeper")
	var stdout, stderr bytes.Buffer
	runner.Stdout, runner.Stderr = &stdout, &stderr
	if err := runner.Start(); err != nil {
		t.Fatal(err)
	}
	defer runner.Process.Kill()
	waitFor(t, func() bool { _, err := os.Stat(pidfile); return err == nil })
	id := onlyRun(t, h)

	// 実行中の run は running で、実行中のステップと子プロセスの PID が外から見える（§5.5）。
	out, _, _ := h.run("status", "--json", id)
	st := decode[runstate.State](t, out)
	x := st.Units[0].Running()
	if st.Status != "running" || x == nil || x.Step != "sleep" || x.PID == 0 {
		t.Fatalf("status while running = %s", out)
	}
	if alive := decode[statusView](t, out).RunnerAlive; alive == nil || !*alive {
		t.Fatalf("runner_alive while running = %v", alive)
	}

	out, errOut, code := h.run("cancel", id)
	if code != ExitOK {
		t.Fatalf("cancel exit %d\n%s%s", code, out, errOut)
	}
	if err := waitExit(runner, 20*time.Second); err != nil {
		t.Fatal(err)
	}
	if got := runner.ProcessState.ExitCode(); got != ExitCancelled {
		t.Fatalf("runner exit %d, want %d\n%s", got, ExitCancelled, stderr.String())
	}
	assertDead(t, pidfile)

	out, _, _ = h.run("status", "--json", id)
	st = decode[runstate.State](t, out)
	if st.Status != "cancelled" || st.Cancelled == nil || st.Cancel == nil || st.Cancel.Actor != "cli" {
		t.Fatalf("status after cancel = %s", out)
	}
	if x := st.Units[0].Rounds[0].Steps[0]; x.Status != "cancelled" {
		t.Fatalf("step = %+v", x)
	}
	types := eventTypes(t, filepath.Join(state, "runs", id))
	if !strings.Contains(types, "cancel_requested") || !strings.HasSuffix(types, "step_finished run_cancelled") {
		t.Fatalf("events = %s", types)
	}

	// 終端の run への cancel は何もしない。
	if _, _, code := h.run("cancel", id); code != ExitOK {
		t.Fatalf("cancel of a cancelled run exit %d", code)
	}
}

// runner が落ちた run の cancel は、残った子プロセスを自分で止めて停止を記録する。
func TestCancelWithDeadRunner(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	pidfile := filepath.Join(t.TempDir(), "pids")
	runner := h.cmd("run", "--workflow-dir", abs(t, testWorkflows), "--scripts-dir", abs(t, testScripts), "--input", "pidfile="+pidfile, "sleeper")
	if err := runner.Start(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { _, err := os.Stat(pidfile); return err == nil })
	id := onlyRun(t, h)
	// step_started（子プロセスの PID）が記録されてから落とす。記録の前に落ちた場合は cancel も子を知らない（PR 本文の未検証事項）。
	waitFor(t, func() bool {
		out, _, _ := h.run("status", "--json", id)
		x := decode[runstate.State](t, out).Units[0].Running()
		return x != nil && x.PID != 0
	})
	// runner だけを SIGKILL する（子プロセスは別のプロセスグループなので残る）。
	if err := runner.Process.Signal(syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	_ = runner.Wait()
	out, _, _ := h.run("status", "--json", id)
	if alive := decode[statusView](t, out).RunnerAlive; alive == nil || *alive {
		t.Fatalf("runner_alive after the runner died = %v", alive)
	}

	out, errOut, code := h.run("cancel", id)
	if code != ExitOK {
		t.Fatalf("cancel exit %d\n%s%s", code, out, errOut)
	}
	assertDead(t, pidfile)
	out, _, _ = h.run("status", "--json", id)
	st := decode[runstate.State](t, out)
	if st.Status != "cancelled" || st.Cancelled == nil || !strings.Contains(st.Cancelled.Note, "runner was not alive") {
		t.Fatalf("status = %s", out)
	}
}

func TestCancelOfFinishedRunFails(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	_, _, code := h.run("run", "--workflow-dir", abs(t, testWorkflows), "--scripts-dir", abs(t, testScripts), "--input", `json={"outcome":"other"}`, "--input", "code=0", "emit")
	if code != ExitFailed {
		t.Fatalf("a run that fails must exit %d, got %d", ExitFailed, code)
	}
	if _, _, code := h.run("cancel", onlyRun(t, h)); code != ExitFailed {
		t.Fatalf("cancel of a failed run exit %d", code)
	}
}

func TestRunRejectsInvalidWorkflowWithoutStartingARun(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	dir := t.TempDir()
	bad := "schema: harness.workflow/v1\nid: bad\nsteps:\n  a:\n    kind: command\n    run: emit\n    when: yes\n    exit: { 0: ok }\n    on: { ok: { done: ok } }\n"
	if err := os.WriteFile(filepath.Join(dir, "bad.yaml"), []byte(bad), 0o644); err != nil {
		t.Fatal(err)
	}
	_, errOut, code := h.run("run", "--workflow-dir", dir, "--scripts-dir", abs(t, testScripts), "bad")
	if code != ExitUsage || !strings.Contains(errOut, `key "when" is a condition/expression`) {
		t.Fatalf("exit %d\n%s", code, errOut)
	}
	if _, err := os.Stat(filepath.Join(state, "runs")); !os.IsNotExist(err) {
		t.Fatal("a run directory was created for an invalid workflow")
	}
	_, errOut, code = h.run("validate", "--workflow-dir", dir, "--scripts-dir", abs(t, testScripts))
	if code != ExitFailed || !strings.Contains(errOut, "NG ") {
		t.Fatalf("validate exit %d\n%s", code, errOut)
	}
}

func TestRunChecksInputs(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	base := []string{"run", "--workflow-dir", abs(t, testWorkflows), "--scripts-dir", abs(t, testScripts)}
	for name, args := range map[string][]string{
		"missing required": {"--input", "json={}", "emit"},
		"not an integer":   {"--input", "json={}", "--input", "code=x", "emit"},
		"undeclared":       {"--input", "json={}", "--input", "code=0", "--input", "extra=1", "emit"},
	} {
		if _, errOut, code := h.run(append(base, args...)...); code != ExitUsage {
			t.Errorf("%s: exit %d\n%s", name, code, errOut)
		}
	}
}

func TestValidate(t *testing.T) {
	h := newHarness(t)
	out, errOut, code := h.run("validate", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts))
	if code != ExitOK || !strings.Contains(out, "failed=0") {
		t.Fatalf("validate of runtime/workflows exit %d\n%s%s", code, out, errOut)
	}
	// 検査対象が 1 つも無いのを通過と報告しない。
	_, _, code = h.run("validate", "--workflow-dir", t.TempDir(), "--scripts-dir", abs(t, repoScripts))
	if code != ExitFailed {
		t.Fatalf("validate of an empty directory exit %d", code)
	}
}

func TestParseArgs(t *testing.T) {
	flags, pos, err := parseArgs([]string{"x", "--json", "--input", "a=1", "--input=b=2", "y"},
		flagSpec{name: "json"}, flagSpec{name: "input", value: true, multi: true})
	if err != nil || strings.Join(pos, ",") != "x,y" || strings.Join(flags["input"], ",") != "a=1,b=2" || len(flags["json"]) != 1 {
		t.Fatalf("flags=%v pos=%v err=%v", flags, pos, err)
	}
	for _, bad := range [][]string{{"--nope"}, {"--input"}, {"--json=1"}} {
		if _, _, err := parseArgs(bad, flagSpec{name: "json"}, flagSpec{name: "input", value: true}); err == nil {
			t.Errorf("parseArgs(%v) must fail", bad)
		}
	}
}

func onlyRun(t *testing.T, h *harness) string {
	t.Helper()
	var id string
	waitFor(t, func() bool {
		out, _, code := h.run("runs", "--json")
		if code != ExitOK {
			return false
		}
		runs := decode[[]runSummary](t, out)
		if len(runs) == 1 {
			id = runs[0].RunID
			return true
		}
		return false
	})
	return id
}

func eventTypes(t *testing.T, dir string) string {
	t.Helper()
	evs, _, err := runstate.ReadEvents(filepath.Join(dir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	var types []string
	for _, ev := range evs {
		types = append(types, ev.Type)
	}
	return strings.Join(types, " ")
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("condition was not met in time")
}

func waitExit(c *exec.Cmd, d time.Duration) error {
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case <-done:
		return nil
	case <-time.After(d):
		return fmt.Errorf("process %d did not exit within %s", c.Process.Pid, d)
	}
}

func assertDead(t *testing.T, pidfile string) {
	t.Helper()
	data, err := os.ReadFile(pidfile)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range strings.Fields(string(data)) {
		var pid int
		if _, err := fmt.Sscan(f, &pid); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for runstate.Alive(pid) && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
		if runstate.Alive(pid) {
			t.Fatalf("process %d is still alive", pid)
		}
	}
}
